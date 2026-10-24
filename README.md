<h1 align="center">mpv-anime-presence</h1>

<p align="center">
  <b>🎈 Lightweight, zero-dependency Discord Rich Presence for mpv with automatic anime cover art matching (Bangumi & AniList).</b>
  <br>
  <sub>基于纯 LuaJIT 的零外部依赖 mpv Discord 状态插件，支持 Bangumi / AniList 番剧海报与原名/译名自动匹配。</sub>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Windows-blue?style=flat-square">
  <img alt="mpv" src="https://img.shields.io/badge/mpv-v0.34+-purple?style=flat-square">
  <img alt="Dependencies" src="https://img.shields.io/badge/Dependencies-Zero-brightgreen?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-orange?style=flat-square">
</p>

---

[English](#english) | [中文说明](#中文说明)

---

<a name="english"></a>
## Features

* 🚀 **Zero External Dependencies**: Pure LuaJIT FFI implementation connecting directly to Windows Named Pipes (`\\.\pipe\discord-ipc-*`). No Python, Node.js, C DLLs, or external `.exe` companion daemons required.
* 🎨 **Dual-Engine Anime Cover Art**: Automatically cleans release group tags, video parameters, and season numbers, then asynchronously fetches official high-res key visual posters from **Bangumi (bgm.tv)** with **AniList (anilist.co)** fallback.
* 🌐 **Bilingual (English & Chinese)**: Full internationalization support with configurable original Japanese names (e.g. `ヤニねこ`) or localized translated names (e.g. `抽烟猫`).
* ⏱️ **De-duplicated Progress**: Removes redundant total duration text during playback to perfectly match Discord's native media player progress bar; retains precise timestamps when paused.
* ⌨️ **Hotkeys & On-the-Fly Toggle**: Easily toggle Rich Presence on or off at any time using `Ctrl+d` with on-screen OSD notifications.
* 🔒 **Privacy First**: Local absolute file paths and stream tokens are strictly sanitized; only clean filenames or generic placeholders are shared.
* 🧹 **Clean State Management**: Sends explicit `activity: null` clears upon file unload, stopping, or exiting. Never leaves a stuck "Playing" status on your profile.

---

## Installation

1. Download or clone this repository.
2. Copy the files into your mpv configuration directory (`portable_config` for portable builds, or `%APPDATA%\mpv`):

```text
portable_config/
├── scripts/
│   └── anime_presence.lua
└── script-opts/
    └── anime_presence.conf
```

3. Launch mpv and open any video!

---

## Configuration (`anime_presence.conf`)

| Option | Default | Choices | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `yes` | `yes`, `no` | Enable or disable Rich Presence on startup |
| `key` | `Ctrl+d` | string | Hotkey to toggle presence on the fly |
| `language` | `zh` | `zh`, `en` | Display language for status text and OSD |
| `title_preference` | `translated` | `translated`, `original` | Display localized name or original Japanese title |
| `hide_duration_on_play` | `yes` | `yes`, `no` | Hide duration text when playing (avoids duplication with Discord bar) |
| `details_use_anime_title` | `no` | `yes`, `no` | Replace raw filename in details line with clean anime title |
| `cover_art` | `yes` | `yes`, `no` | Enable automatic Bangumi & AniList cover fetching |
| `show_title` | `yes` | `yes`, `no` | Show video title (set `no` for "Watching Video" privacy mode) |
| `update_interval` | `15` | integer | Regular refresh interval in seconds |
| `min_update_interval` | `5` | integer | Minimum cooldown between state changes (rate limit protection) |

---

<a name="中文说明"></a>
## 中文说明

### 核心亮点

1. **纯原生零依赖**：利用 Windows 命名管道和 LuaJIT FFI 原生直连本机 Discord，不需要安装 Python、不需要 `pypresence`，更不需要后台挂着第三方的 `.exe` 守护进程。
2. **动漫海报自动匹配（双引擎）**：智能剔除压制组标签（如 `[VCB-Studio]`、`[LoliHouse]`、`【幻樱】`）、分辨率规格与季度前缀，支持日文原名、罗马音与中文译名检索。优先拉取 **Bangumi（番组计划）** CDN，搜不到时自动无缝兜底检索 **AniList**。
3. **播放进度去重**：播放中自动剔除多余的时长文字，完美契合 Discord 底部的原生实时进度条与倒计时；暂停时保留精准时间点（如 `已暂停 · 00:15 / 23:42`）。
4. **原名/译名自由切换**：支持自由选择在封面悬停与详情中展示日文原名（如 `その着せ替え人形は恋をする`）或中文译名（如 `更衣人偶坠入爱河`）。
5. **隐私脱敏**：彻底过滤本地绝对路径（不会泄露如 `D:\Downloads\...`），网络流媒体自动过滤 Token 与查询参数。
6. **优雅清空与热键**：停止播放或退出时秒级清空状态，不卡残留；随时可用 `Ctrl + d` 单键开关。

### 安装方法

1. 下载本仓库压缩包或克隆代码。
2. 将 `scripts/anime_presence.lua` 和 `script-opts/anime_presence.conf` 复制到你的 mpv 配置目录（如 `portable_config` 或 `AppData\roaming\mpv`）中对应的子文件夹下。
3. 打开 mpv 播放动漫即可自动生效！

---

## License

MIT License © 2026.
