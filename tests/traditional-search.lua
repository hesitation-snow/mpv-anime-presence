-- Run: mpv --no-config --load-scripts=no --idle=yes --script=tests/traditional-search.lua
-- Optional real API check: --script-opts=traditional_search_tests-live=yes
-- No Discord activity is published by this test runner.
local real_mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local test_options = {live=false}
options.read_options(test_options, 'traditional_search_tests')
local script_dir = real_mp.get_script_directory() or utils.split_path(debug.getinfo(1, 'S').source:sub(2))
local root = script_dir .. '/..'
local input = assert(io.open(root .. '/scripts/anime_presence.lua', 'rb'))
local source = input:read('*a'); input:close()
local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed+1
end
local function instance(settings)
    settings = settings or {}
    local requests, events = {}, {}
    local properties = {
        ['media-title']='[ANi] 學生會也有洞！ - 03 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4',
        ['filename/no-ext']='[ANi] 學生會也有洞！ - 03 [1080P][Baha][WEB-DL][AAC AVC][CHT]',
        path='V:/Anime/example.mp4', speed=1, duration=1422, ['time-pos']=21,
    }
    local mock = {
        msg=real_mp.msg, get_time=real_mp.get_time,
        register_event=function(name, cb) events[name]=cb end,
        add_key_binding=function() end, register_script_message=function() end,
        observe_property=function() end, add_periodic_timer=function() end,
        set_property_native=function() end, osd_message=function() end,
        get_property=function(name, default) local v=properties[name]; if v==nil then return default end; return v end,
        get_property_number=function(name, default) return tonumber(properties[name]) or default end,
        get_property_bool=function(name, default) if properties[name]==nil then return default end; return properties[name] end,
    }
    mock.command_native_async=function(spec, cb)
        requests[#requests+1]={spec=spec, cb=cb}
        if settings.live then return real_mp.command_native_async(spec,cb) end
        return #requests
    end
    local env = setmetatable({require=function(name)
        if name=='mp' then return mock end
        if name=='mp.options' then return {read_options=function(o)
            o.enabled=false -- tests never connect to Discord
            o.details_use_anime_title=true
            o.title_preference=settings.preference or 'translated'
        end} end
        return require(name)
    end}, {__index=_G})
    local chunk=assert(loadstring(source .. '\nreturn {clean=clean_anime_title,simplify=simplified_search_title,fetch=fetch_cover,activity=build_activity,encode=url_encode,options=o}\n', '@anime_presence.lua'))
    setfenv(chunk,env)
    local api=chunk()
    local function reply(index, body, success, status)
        requests[index].cb(success~=false,{status=status or 0,stdout=utils.format_json(body)})
    end
    return {api=api,requests=requests,events=events,properties=properties,reply=reply}
end
local subject={id=554779,name='生徒会にも穴はある！',name_cn='学生会也有洞！',
    images={large='http://lain.bgm.tv/pic/cover/l/17/c7/554779_oPitO.jpg'}}
local traditional='學生會也有洞！'
local simplified='学生会也有洞！'
local function unit_tests()
    local t=instance()
    check(t.api.clean(t.properties['media-title'])==traditional,'Clean exact ANi filename')
    check(t.api.simplify(traditional)==simplified,'Windows NLS traditional -> simplified')
    check(t.api.simplify('Re Zero kara Hajimeru Isekai Seikatsu')=='Re Zero kara Hajimeru Isekai Seikatsu','ASCII unchanged')
    check(t.api.simplify(simplified)==simplified,'Simplified text unchanged')
    check(t.api.simplify('')=='','Empty title supported')
    check(t.api.simplify('\255')=='\255','Invalid UTF-8 falls back without crashing')
    local filenames={
        {'[LoliHouse] Yani Neko - 01 [WebRip 1080p HEVC-10bit].mkv','Yani Neko'},
        {'[hyakuhuyu&LoliHouse] Re Zero kara Hajimeru Isekai Seikatsu - 75 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv','Re Zero kara Hajimeru Isekai Seikatsu'},
        {'[Nekomoe kissaten&LoliHouse] Sono Bisque Doll wa Koi wo Suru - 15 [WebRip 1080p].mkv','Sono Bisque Doll wa Koi wo Suru'},
        {'[DBD-Raws][新吊带袜天使][01][1080P].mkv','新吊带袜天使'},
    }
    for _,f in ipairs(filenames) do check(t.api.clean(f[1])==f[2],'Filename regression: '..f[2]) end
    t.api.fetch(traditional)
    check(#t.requests==1 and t.requests[1].spec.args[#t.requests[1].spec.args]:find(t.api.encode(traditional),1,true),'Search original spelling first')
    t.reply(1,{error='Not Found'})
    check(#t.requests==2 and t.requests[2].spec.args[#t.requests[2].spec.args]:find(t.api.encode(simplified),1,true),'Retry simplified spelling before AniList')
    t.reply(2,{results=2,list={subject}})
    local activity=t.api.activity()
    check(activity.details==subject.name_cn,'Matched translated title')
    check(activity.assets.large_image=='https://lain.bgm.tv/pic/cover/l/17/c7/554779_oPitO.jpg','HTTPS cover selected')
    check(activity.state=='播放中','Duration remains deduplicated')
    t.api.options.details_use_anime_title=false
    check(t.api.activity().details:find('學生會',1,true),'Displayed filename remains traditional')
    t.api.fetch(traditional); t.api.fetch(simplified)
    check(#t.requests==2,'Both search spellings reuse cache')
    local original=instance({preference='original'})
    original.api.fetch(traditional); original.reply(1,{results=0,list={}}); original.reply(2,{list={subject}})
    check(original.api.activity().details==subject.name,'Original-title preference preserved')
    local jp=instance()
    jp.api.fetch('生徒会にも穴はある！'); jp.reply(1,{list={subject}})
    check(#jp.requests==1,'Japanese original result is never replaced by converted search')
    local roman=instance()
    roman.api.fetch('Unmatched Romaji'); roman.reply(1,{results=0,list={}})
    check(#roman.requests==2 and roman.requests[2].spec.args[#roman.requests[2].spec.args]=='https://graphql.anilist.co','AniList fallback retained and duplicate search avoided')
    roman.reply(2,{data={Media={title={native='作品',romaji='Unmatched Romaji'},coverImage={large='https://example.org/cover.jpg'}}}})
    check(roman.api.activity().assets.large_image=='https://example.org/cover.jpg','AniList cover still applied')
    local stale=instance()
    stale.api.fetch(traditional)
    stale.events['end-file']()
    stale.reply(1,{list={subject}})
    check(stale.api.activity().assets.large_image=='mpv','Previous-file response cannot replace next cover')
    local offline=instance()
    offline.api.fetch(traditional)
    offline.reply(1,{},false,28); offline.reply(2,{},false,28); offline.reply(3,{},false,28)
    local count=#offline.requests
    offline.api.fetch(traditional)
    check(#offline.requests==count+1,'Network errors are not cached permanently')
    real_mp.msg.info('PASS: '..passed..' regression assertions')
end
local function live_test()
    local t=instance({live=true})
    local start=real_mp.get_time()
    t.api.fetch(t.api.clean(t.properties['media-title']))
    local timer
    timer=real_mp.add_periodic_timer(0.1,function()
        local image=t.api.activity().assets.large_image
        if image:find('/554779_',1,true) then
            timer:kill()
            real_mp.msg.info('PASS: live Bangumi lookup matched subject 554779 after '..#t.requests..' requests')
            real_mp.commandv('quit',0)
        elseif real_mp.get_time()-start>22 then
            timer:kill(); real_mp.msg.error('Live query timed out'); real_mp.commandv('quit',1)
        end
    end)
end
real_mp.add_timeout(0.1,function()
    local success,err=pcall(unit_tests)
    if not success then real_mp.msg.error(tostring(err)); real_mp.commandv('quit',1); return end
    if test_options.live then live_test() else real_mp.commandv('quit',0) end
end)
