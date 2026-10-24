-- Windows mpv + LuaJIT: Discord Rich Presence over local IPC, no helper process.
-- Application ID and asset names use the public tnychn/mpv-discord application:
-- https://github.com/tnychn/mpv-discord (replace client_id for your own app).
-- Ctrl+d toggles for this mpv instance. Never sends a full path or media URL.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local o = {
    enabled = true,
    key = 'Ctrl+d',
    client_id = '737663962677510245',
    show_title = true,
    activity_type = 3,
    cover_art = true,
    language = 'zh',                 -- 'zh' (Chinese) or 'en' (English)
    title_preference = 'translated', -- 'translated' (译名) or 'original' (原名)
    hide_duration_on_play = true,    -- hide duration in state line when playing
    details_use_anime_title = false, -- use matched anime title in details line if available
    update_interval = 15,
    min_update_interval = 5,
    reconnect_interval = 5,
    log_updates = false,
    pipe_prefix = 'discord-ipc-',
}
options.read_options(o, 'anime_presence')
options.read_options(o, 'discord_presence')
local I18N = {
    zh = {
        playing = '播放中',
        paused = '已暂停',
        buffering = '缓冲中',
        watching_video = '正在观看视频',
        online_video = '在线视频',
        osd_enabled = 'Discord 状态：开启',
        osd_disabled = 'Discord 状态：关闭',
        duration_prefix = '时长 ',
    },
    en = {
        playing = 'Playing',
        paused = 'Paused',
        buffering = 'Buffering',
        watching_video = 'Watching Video',
        online_video = 'Online Video',
        osd_enabled = 'Discord Presence: Enabled',
        osd_disabled = 'Discord Presence: Disabled',
        duration_prefix = 'Duration ',
    }
}
local function tr(key)
    local dict = I18N[o.language] or I18N.zh
    return dict[key] or I18N.en[key] or key
end
local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Windows' then
    mp.msg.warn('Discord presence requires Windows mpv with LuaJIT; playback is unaffected.')
    return
end
ffi.cdef[[
void * __stdcall CreateFileA(const char *, unsigned long, unsigned long, void *, unsigned long, unsigned long, void *);
int __stdcall SetNamedPipeHandleState(void *, unsigned long *, unsigned long *, unsigned long *);
int __stdcall PeekNamedPipe(void *, void *, unsigned long, unsigned long *, unsigned long *, unsigned long *);
int __stdcall ReadFile(void *, void *, unsigned long, unsigned long *, void *);
int __stdcall WriteFile(void *, const void *, unsigned long, unsigned long *, void *);
int __stdcall CloseHandle(void *);
unsigned long __stdcall GetLastError(void);
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, wchar_t *, int);
int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const wchar_t *, int, char *, int, const char *, int *);
int __stdcall LCMapStringEx(const wchar_t *, unsigned long, const wchar_t *, int, wchar_t *, int, void *, void *, intptr_t);
]]
local win = ffi.load('kernel32')
local INVALID_HANDLE = ffi.cast('void *', -1)
local handle, ready, rx, pending = nil, false, '', {}
local enabled, file_loaded, sent_active = o.enabled, false, false
local retry_at, handshake_at, last_sent = 0, 0, -100
local current_cover_url, current_cover_title = nil, nil
local cover_generation = 0 -- stale asynchronous lookups must not change a newer file's cover
local cover_cache = {}
local activity_writes = {} -- rolling window; reserve one of five slots for clearing
local dirty, sequence, stopped = true, 0, false
local pid = utils.getpid()
local status = {
    enabled = enabled, connected = false, status = 'waiting',
    set_ack_count = 0, clear_ack_count = 0,
}
local function expose()
    status.enabled, status.connected = enabled, ready
    mp.set_property_native('user-data/discord-presence', status)
end
local function log(s)
    if o.log_updates then mp.msg.info(s) end
end
local function pack32(n)
    return string.char(n % 256, math.floor(n/256) % 256,
        math.floor(n/65536) % 256, math.floor(n/16777216) % 256)
end
local function unpack32(s, at)
    local a,b,c,d = s:byte(at, at+3)
    return a + b*256 + c*65536 + d*16777216
end
local function disconnect(reason)
    local was_ready = ready
    if handle then win.CloseHandle(handle) end
    handle, ready, rx, pending = nil, false, '', {}
    sent_active, dirty = false, true
    retry_at = mp.get_time() + math.max(1, o.reconnect_interval)
    status.status = enabled and 'waiting' or 'disabled'
    if reason then status.last_error = reason end
    expose()
    if was_ready and reason then mp.msg.info('Discord IPC disconnected; retrying automatically.') end
end
local function write_raw_packet(op, body)
    if not handle or not body then return false end
    local frame = pack32(op) .. pack32(#body) .. body
    local count = ffi.new('unsigned long[1]')
    local written = win.WriteFile(handle, frame, #frame, count, nil)
    if written == 0 or tonumber(count[0]) ~= #frame then
        local code = tonumber(win.GetLastError())
        -- A short nonblocking write leaves a truncated frame: close instead of interleaving.
        disconnect('IPC write failed or short write: ' .. code)
        return false
    end
    return true
end
local function write_packet(op, data)
    return write_raw_packet(op, utils.format_json(data))
end
local function send_activity(activity, label)
    if not ready then return false end
    local now = mp.get_time()
    while activity_writes[1] and now-activity_writes[1] >= 20.1 do table.remove(activity_writes, 1) end
    local limit = activity and 4 or 5
    if #activity_writes >= limit then return false end
    if activity and next(pending) then return false end -- coalesce until acknowledgement
    sequence = sequence + 1
    local nonce = tostring(pid) .. '-' .. tostring(sequence)
    pending[nonce] = {label=label, at=mp.get_time()}
    -- JSON null (not an empty object) is required to clear presence.
    local activity_json = activity and utils.format_json(activity) or 'null'
    local body = string.format('{"cmd":"SET_ACTIVITY","args":{"pid":%d,"activity":%s},"nonce":%s}',
        pid, activity_json, utils.format_json(nonce))
    if not write_raw_packet(1, body) then return false end
    last_sent = mp.get_time()
    activity_writes[#activity_writes+1] = last_sent
    sent_active = activity ~= nil
    status.status, status.last_sent = label, label
    expose()
    log('SET_ACTIVITY sent: ' .. label)
    return true
end
local function clear()
    if ready and sent_active then send_activity(nil, 'cleared') end
end
local function connect()
    if handle or not enabled then return end
    retry_at = mp.get_time() + math.max(1, o.reconnect_interval)
    for i=0,9 do
        local name = '\\\\.\\pipe\\' .. o.pipe_prefix .. tostring(i)
        local h = win.CreateFileA(name, 0xC0000000, 0, nil, 3, 0, nil)
        if h ~= INVALID_HANDLE then
            local mode = ffi.new('unsigned long[1]', 1) -- PIPE_NOWAIT, byte read mode
            if win.SetNamedPipeHandleState(h, mode, nil, nil) ~= 0 then
                handle, handshake_at, rx = h, mp.get_time(), ''
                write_packet(0, {v=1, client_id=tostring(o.client_id)})
                return
            end
            win.CloseHandle(h)
        end
    end
end
local function handle_message(op, body)
    if op == 3 then -- Discord PING: echo the exact bytes, including non-object payloads.
        write_raw_packet(4, body)
        return
    end
    local value = utils.parse_json(body)
    if op == 2 then
        disconnect('Discord closed the connection')
        return
    elseif op ~= 1 or type(value) ~= 'table' then
        return
    end
    if value.cmd == 'DISPATCH' and value.evt == 'READY' then
        ready, dirty = true, true
        status.status, status.last_error = 'connected', nil
        expose()
        mp.msg.info('Discord Rich Presence connected.')
        return
    end
    local request = value.nonce and pending[value.nonce]
    if not request then return end
    if value.evt == 'ERROR' then
        pending[value.nonce] = nil
        status.last_error = 'Discord rejected activity: ' .. tostring(value.data and value.data.message or 'unknown error')
        status.status = 'error'
        expose()
        mp.msg.warn(status.last_error)
        return
    end
    if value.cmd == 'SET_ACTIVITY' then
        pending[value.nonce] = nil
        local key = request.label == 'cleared' and 'clear_ack_count' or 'set_ack_count'
        status[key] = status[key] + 1
        status.last_ack = request.label
        expose()
        log('SET_ACTIVITY acknowledged: ' .. request.label)
    end
end
local function receive()
    if not handle then return end
    local available = ffi.new('unsigned long[1]')
    if win.PeekNamedPipe(handle, nil, 0, nil, available, nil) == 0 then
        disconnect('IPC peer disconnected')
        return
    end
    local size = math.min(tonumber(available[0]), 16384)
    if size > 0 then
        local buf, count = ffi.new('uint8_t[?]', size), ffi.new('unsigned long[1]')
        if win.ReadFile(handle, buf, size, count, nil) == 0 then
            disconnect('IPC read failed')
            return
        end
        rx = rx .. ffi.string(buf, tonumber(count[0]))
    end
    while handle and #rx >= 8 do
        local op, len = unpack32(rx, 1), unpack32(rx, 5)
        if len > 65536 then disconnect('IPC frame exceeded size limit'); return end
        if #rx < len+8 then break end
        local body = rx:sub(9, len+8)
        rx = rx:sub(len+9)
        handle_message(op, body)
    end
end
local function clip(s, limit)
    s = tostring(s or ''):gsub('[%z\1-\31\127]', ' ')
    if #s <= limit then return s end
    local n = limit
    local following = s:byte(n+1)
    if following and following >= 128 and following < 192 then
        while n > 0 and s:byte(n) >= 128 and s:byte(n) < 192 do n = n-1 end
        n = n-1
    end
    return s:sub(1, math.max(0,n))
end
local function media_title()
    if not o.show_title then return tr('watching_video') end
    if o.details_use_anime_title and current_cover_title and current_cover_title ~= '' then
        return clip(current_cover_title, 120)
    end
    local path = mp.get_property('path', '')
    local title = mp.get_property('media-title', '')
    if title == '' then title = mp.get_property('filename/no-ext', '') end
    -- Mask online stream URLs, magnet URIs, data URIs and queries
    if path:find('^%a[%a%d+.-]*://') or path:find('^magnet:') or path:find('^data:') or (path:find('^%a[%a%d+.-]*:') and not path:find('^%a:[/\\]')) then
        if title == path or title:find('^%a[%a%d+.-]*://') or title:find('^magnet:') or title:find('[?&=]') then
            return tr('online_video')
        end
    end
    if title:find('://', 1, true) or title:find('^magnet:') or title:find('^data:') or title:find('^[a-zA-Z0-9_-]+%?.*=') then
        return tr('online_video')
    end
    title = title:gsub('\\', '/'):match('([^/]+)/*$') or ''
    if title == '' then title = tr('watching_video') end
    return clip(title, 120)
end
local function clean_anime_title(raw)
    if not raw or raw == '' then return '' end
    local s = raw:gsub('%.%w+$', '') -- strip extension

    -- Multi-bracket format: [Group][Title] or 【Group】[Title]
    local g, t = s:match('^%s*[%[【]([^%]】]+)[%]】]%s*[%[【]([^%]】]+)[%]】]')
    if g and t then
        local lower_t = t:lower()
        if not lower_t:match('^%d+$') and not lower_t:match('^1080[pi]?$') and not lower_t:match('^720[pi]?$')
           and not lower_t:match('^hevc') and not lower_t:match('^x26[45]') and not lower_t:match('^bdr?ip') then
            s = t
        end
    end

    local rest = s:match('^%s*[%[【][^%]】]+[%]】]%s*(.+)$')
    if rest then s = rest end

    local before_bracket = s:match('^(.-)%s*%[')
    if not before_bracket then before_bracket = s:match('^(.-)%s*【') end
    if before_bracket and before_bracket:match('%S') then s = before_bracket end

    -- Remove season and episode tags at the end:
    s = s:gsub('%s*[%-_]%s*[sS]%d+%s*[%-_]%s*%d+%s*$', '')
    s = s:gsub('%s*[%-_]%s*[eE]?[pP]?%d+%s*$', '')
    s = s:gsub('%s*[sS]%d+%s*[%-_]%s*%d+%s*$', '')
    s = s:gsub('%s*[sS]%d+%s*$', '')
    s = s:gsub('%s*[sS]eason%s*%d+%s*$', '')
    s = s:gsub('%s*[eE][pP]%d+%s*$', '')
    s = s:gsub('%s*第%s*%d+.*$', '')
    s = s:gsub('^%s*(.-)%s*$', '%1')
    return s
end
local function url_encode(str)
    if not str then return '' end
    return str:gsub('([^%w_%-%.~])', function(c)
        return string.format('%%%02X', string.byte(c))
    end)
end
-- Convert search keywords only. Keep filenames, metadata and display-title preferences intact.
-- Windows NLS is already available on supported systems; no bundled character table or helper.
local function simplified_search_title(text)
    if type(text) ~= 'string' or text == '' then return text end
    local success, converted = pcall(function()
        local length = win.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
        if length <= 0 then return text end
        local wide = ffi.new('wchar_t[?]', length)
        if win.MultiByteToWideChar(65001, 8, text, #text, wide, length) ~= length then return text end
        local locale = ffi.new('wchar_t[1]', 0) -- invariant locale
        local count = win.LCMapStringEx(locale, 0x02000000, wide, length, nil, 0, nil, nil, 0)
        if count <= 0 then return text end
        local mapped = ffi.new('wchar_t[?]', count)
        if win.LCMapStringEx(locale, 0x02000000, wide, length, mapped, count, nil, nil, 0) ~= count then return text end
        local bytes = win.WideCharToMultiByte(65001, 0, mapped, count, nil, 0, nil, nil)
        if bytes <= 0 then return text end
        local utf8 = ffi.new('char[?]', bytes)
        if win.WideCharToMultiByte(65001, 0, mapped, count, utf8, bytes, nil, nil) ~= bytes then return text end
        return ffi.string(utf8, bytes)
    end)
    return success and converted or text
end
local function apply_cover(entry, generation)
    if generation ~= cover_generation then return end
    current_cover_url = entry.url
    current_cover_title = entry.translated
    if o.title_preference == 'original' or o.title_preference == 'native' or o.title_preference == 'jp' then
        current_cover_title = entry.original
    end
    dirty = true
end
local function fetch_anilist(query, generation)
    local body = utils.format_json({
        query = 'query ($s: String) { Media(search: $s, type: ANIME) { id title { romaji english native } coverImage { extraLarge large } } }',
        variables = { s = query }
    })
    mp.command_native_async({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = true,
        args = {
            'curl.exe', '-s', '-L', '-m', '6',
            '-H', 'Content-Type: application/json',
            '-H', 'User-Agent: mpv-discord/1.0',
            '-d', body,
            'https://graphql.anilist.co'
        }
    }, function(success, res, err)
        if generation ~= cover_generation then return end
        if not success or not res or res.status ~= 0 or not res.stdout then
            -- A transient network error should be retried on the next file, not cached forever.
            return
        end
        local data = utils.parse_json(res.stdout)
        local media = data and data.data and data.data.Media
        if media and media.coverImage and (media.coverImage.extraLarge or media.coverImage.large) then
            local img = media.coverImage.extraLarge or media.coverImage.large
            local orig_name = (media.title and media.title.native and media.title.native ~= '') and media.title.native or media.title.romaji
            local trans_name = (media.title and media.title.romaji and media.title.romaji ~= '') and media.title.romaji or orig_name
            local chosen_name = (o.title_preference == 'original' or o.title_preference == 'native' or o.title_preference == 'jp') and orig_name or trans_name
            cover_cache[query] = { url = img, original = orig_name, translated = trans_name, title = chosen_name }
            apply_cover(cover_cache[query], generation)
            log('AniList cover fallback loaded: ' .. tostring(chosen_name) .. ' -> ' .. img)
            return
        end
        cover_cache[query] = false
    end)
end
local function fetch_cover(query)
    if not o.cover_art or not query or query == '' then return end
    local generation = cover_generation
    if cover_cache[query] ~= nil then
        if cover_cache[query] then apply_cover(cover_cache[query], generation) end
        return
    end
    -- Search the exact title first: Chinese conversion can alter Japanese kanji.
    -- Retry the simplified keyword only when the original lookup has no usable result.
    local candidates = {query}
    local simplified = simplified_search_title(query)
    if simplified ~= query and simplified ~= '' then candidates[#candidates+1] = simplified end
    local function search(index)
        if generation ~= cover_generation then return end
        local keyword = candidates[index]
        if not keyword then fetch_anilist(query, generation); return end
        local cached = cover_cache[keyword]
        if cached then
            cover_cache[query] = cached
            apply_cover(cached, generation)
            return
        end
        local url = 'https://api.bgm.tv/search/subject/' .. url_encode(keyword) .. '?type=2'
        mp.command_native_async({
            name = 'subprocess', playback_only = false, capture_stdout = true,
            args = {'curl.exe', '-f', '-sS', '-L', '--connect-timeout', '3', '-m', '6',
                '-H', 'User-Agent: mpv-anime-presence/1.0', url}
        }, function(success, res, err)
            if generation ~= cover_generation then return end
            local data = success and res and res.status == 0 and utils.parse_json(res.stdout or '')
            local first = type(data) == 'table' and type(data.list) == 'table' and data.list[1]
            local img = type(first) == 'table' and type(first.images) == 'table'
                and (first.images.large or first.images.common)
            if type(img) == 'string' and img ~= '' then
                local original = (first.name and first.name ~= '') and first.name or first.name_cn
                local translated = (first.name_cn and first.name_cn ~= '') and first.name_cn or first.name
                local entry = {url=img:gsub('^http://', 'https://'), original=original, translated=translated}
                cover_cache[query], cover_cache[keyword] = entry, entry
                apply_cover(entry, generation)
                log('Bangumi cover loaded: ' .. tostring(current_cover_title) .. ' -> ' .. entry.url)
                return
            end
            search(index+1)
        end)
    end
    search(1)
end
local function clock(n)
    n = math.max(0, math.floor(n or 0))
    if n >= 3600 then return string.format('%d:%02d:%02d', math.floor(n/3600), math.floor(n/60)%60, n%60) end
    return string.format('%02d:%02d', math.floor(n/60), n%60)
end
local function playing_media()
    return file_loaded and not mp.get_property_bool('idle-active', true)
        and not mp.get_property_bool('eof-reached', false)
end
local function build_activity()
    local paused = mp.get_property_bool('pause', false)
    local buffering = mp.get_property_bool('paused-for-cache', false)
    local position = math.max(0, mp.get_property_number('time-pos', 0))
    local duration = mp.get_property_number('duration', 0)
    local speed = math.max(0.01, mp.get_property_number('speed', 1))
    local label = buffering and 'buffering' or paused and 'paused' or 'playing'
    local status_text = buffering and tr('buffering') or paused and tr('paused') or tr('playing')
    local state = status_text
    if paused or buffering then
        state = state .. ' · ' .. clock(position)
        if duration > 0 then state = state .. ' / ' .. clock(duration) end
    elseif duration > 0 and not o.hide_duration_on_play then
        state = state .. ' · ' .. tr('duration_prefix') .. clock(duration)
    end
    if speed ~= 1 then state = state .. string.format(' · %.2gx', speed) end
    local activity = {
        type=o.activity_type,
        details=media_title(), state=clip(state,120), instance=false,
        assets={
            large_image=current_cover_url or 'mpv',
            large_text=clip(current_cover_title or media_title(), 120),
            small_image=buffering and 'buffer' or paused and 'pause' or 'play',
            small_text=status_text
        },
    }
    if not paused and not buffering then
        local now = os.time()
        activity.timestamps = {start=math.floor(now-position/speed)}
        if duration > 0 and duration > position then
            activity.timestamps['end'] = math.floor(now+(duration-position)/speed)
        end
    end
    return activity, label
end
local function tick()
    if stopped or not enabled then return end
    if not handle and mp.get_time() >= retry_at and playing_media() then connect() end
    receive()
    if handle and not ready and mp.get_time()-handshake_at > 5 then
        disconnect('Discord handshake timed out')
    end
    if not ready then return end
    for _, request in pairs(pending) do
        if mp.get_time()-request.at > 10 then disconnect('Activity acknowledgement timed out'); return end
    end
    if not playing_media() then clear(); return end
    local elapsed = mp.get_time()-last_sent
    if elapsed >= math.max(2,o.min_update_interval) and (dirty or elapsed >= math.max(5,o.update_interval)) then
        local activity, label = build_activity()
        if send_activity(activity, label) then dirty = false end
    end
end
local function safe_tick()
    local success, err = pcall(tick)
    if not success then
        mp.msg.warn('Discord presence recovered from an error: ' .. tostring(err))
        disconnect('Local script error')
    end
end
local function toggle()
    enabled = not enabled
    if not enabled then
        if ready and sent_active then
            send_activity(nil, 'cleared')
            mp.add_timeout(0.3, function()
                if not enabled then disconnect() end
            end)
        else
            disconnect()
        end
    else
        dirty, retry_at, last_sent = true, 0, -100
    end
    expose()
    mp.osd_message(enabled and tr('osd_enabled') or tr('osd_disabled'))
end
mp.register_script_message('toggle-discord-presence', toggle)
mp.add_key_binding(o.key, 'toggle-discord-presence', toggle)
mp.register_event('file-loaded', function()
    cover_generation = cover_generation + 1
    file_loaded, dirty = true, true
    current_cover_url = nil
    current_cover_title = nil
    if o.cover_art then
        local raw = mp.get_property('filename/no-ext', '')
        if raw == '' then raw = mp.get_property('media-title', '') end
        local search_title = clean_anime_title(raw)
        if search_title ~= '' then fetch_cover(search_title) end
    end
    safe_tick()
end)
mp.register_event('end-file', function()
    cover_generation = cover_generation + 1
    file_loaded = false
    current_cover_url = nil
    current_cover_title = nil
    clear()
end)
mp.register_event('seek', function() dirty = true end)
mp.register_event('playback-restart', function() dirty = true end)
for _, property in ipairs({'pause','paused-for-cache','speed','duration','media-title','eof-reached','idle-active'}) do
    mp.observe_property(property, 'native', function() dirty = true end)
end
mp.register_event('shutdown', function()
    stopped = true
    clear()
    if handle then win.CloseHandle(handle); handle = nil end
end)
mp.add_periodic_timer(0.25, safe_tick)
expose()
