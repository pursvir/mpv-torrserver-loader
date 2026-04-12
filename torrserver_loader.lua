-- Lua script for MPV to load external subtitles and audios based on the current video series M3U info from TorrServer.
--
-- Requires **curl** to be installed in your OS.

local utils = require "mp.utils"
local input = require "mp.input"

local options = {
    scheme = "http",
    host = "127.0.0.1",
    port = "8090",
    use_edl = true
}
require "mp.options".read_options(options, "torrserver-loader")

local TORRSERVER = options.scheme .. "://" .. options.host .. ":" .. options.port

local current_torrent
local playing_pos = 1
local loadings = {}

local show_torrents

-- https://github.com/YouROK/TorrServer/blob/master/server/utils/filetypes.go#L10
local VIDEO_EXTS = {
    ["3g2"] = true,
    ["3gp"] = true,
    aaf = true,
    asf = true,
    avchd = true,
    avi = true,
    drc = true,
    flv = true,
    m2ts = true,
    m2v = true,
    m4p = true,
    m4v = true,
    mkv = true,
    mng = true,
    mov = true,
    mp2 = true,
    mp4 = true,
    mpe = true,
    mpeg = true,
    mpg = true,
    mpv = true,
    mts = true,
    mxf = true,
    nsv = true,
    ogv = true,
    qt = true,
    rm = true,
    rmvb = true,
    roq = true,
    svi = true,
    ts = true,
    vob = true,
    webm = true,
    wmv = true,
    yuv = true
}
local AUDIO_EXTS = {
    aac = true,
    aiff = true,
    ape = true,
    au = true,
    dff = true,
    dsd = true,
    dsf = true,
    flac = true,
    gsm = true,
    it = true,
    m3u = true,
    m4a = true,
    mid = true,
    mod = true,
    mp3 = true,
    mpa = true,
    mpga = true,
    oga = true,
    ogg = true,
    opus = true,
    pls = true,
    ra = true,
    s3m = true,
    sid = true,
    spx = true,
    wav = true,
    wma = true,
    xm = true,
    ac3 = true,
    aif = true,
    amr = true,
    mka = true
}

local function curl(url, data, dont_show_osd)
    if not dont_show_osd then
        mp.osd_message("Requesting TorrServer's API...", 99)
    end
    local args
    if data then
        args = {
            "curl",
            "-s",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", data,
            url
        }
    else
        args = {
            "curl",
            "-s",
            url
        }
    end

    local result = utils.subprocess({ args = args, capture_stdout = true, capture_stderr = true, cancellable = false })
    if result.status ~= 0 then
        local error_msg = result.stderr or result.error_string or "unknown error"
        if result.stdout and string.len(tostring(result.stdout)) > 0 then
            error_msg = error_msg .. " | stdout: " .. string.sub(tostring(result.stdout), 1, 200)
        end
        mp.osd_message("Curl error: " .. tostring(error_msg) .. " status code: " .. result.status, 7)
        return
    end

    local response = result.stdout
    if not response then
        mp.osd_message("No response from TorrServer's API!", 7)
        return
    end

    response = utils.parse_json(response)

    if not dont_show_osd then
        mp.osd_message("")
    end

    return response
end

local function is_buffering(cache_time)
    if not cache_time then
        cache_time = mp.get_property_number("demuxer-cache-duration", 0)
    end
    return cache_time < 1 or (not options.use_edl and next(loadings))
end

local function show_torrent_load_info(torr, p_pos)
    local function convert_bytes_to_gb(bytes)
        return string.format("%.2f", bytes / (1024 ^ 3))
    end

    local function humanize_speed(speed)
        if not speed or speed == 0 then return "0 bps" end

        local bps = speed * 8
        local units = { "bps", "kbps", "Mbps", "Gbps", "Tbps" }
        local i = math.floor(math.log(bps) / math.log(1000))
        if i > #units then i = #units end

        local value = bps / (1000 ^ i)
        return string.format("%.2f %s", value, units[i + 1])
    end

    local dcd = mp.get_property_number("demuxer-cache-duration", nil)
    local current_state_loading
    if not dcd then
        current_state_loading = "opening"
    elseif dcd < 1.0 then
        current_state_loading = "caching"
    end

    local download_speed = humanize_speed(torr.download_speed or 0)

    local preloaded_gb = convert_bytes_to_gb(torr.loaded_size or 0)
    local total_gb = convert_bytes_to_gb(torr.capacity or 0)

    local peers_info = string.format("%d / %d · %d", torr.active_peers or 0, torr.total_peers or 0,
        torr.connected_seeders or 0)

    local ext_files = ""
    local filename = torr.file_stats[torr.main_files[p_pos]]
    local timeout
    if options.use_edl then
        if filename.ext_tracks_count > 0 then
            ext_files = "Connected " .. filename.ext_tracks_count .. " external files"
        end
    else
        ext_files = string.format(
            "Connected %d / %d external files, Errors: %d", filename.loaded_ext_files or 0,
            filename.ext_tracks_count, filename.error_ext_files or 0
        )
        if next(loadings) then
            timeout = 99
            if #current_state_loading > 0 then
                current_state_loading = current_state_loading .. " / connecting external files"
            else
                current_state_loading = "connecting external files"
            end
        end
    end

    local message = string.format([[
Loading %s...
Current state: %s
Torrent load info:
Speed: %s
Cache: %s / %s GB
Peers·Seeders: %s

%s]], filename.filename, current_state_loading, download_speed, preloaded_gb, total_gb, peers_info, ext_files)
    mp.osd_message(message, timeout)
end

local update_timer
local TIMER_TIMEOUT = 0.5
local function init_torrent_loading_timer()
    if not current_torrent or not is_buffering() then
        if update_timer then
            update_timer:kill()
            update_timer = nil
        end
        return
    elseif not update_timer then
        update_timer = mp.add_periodic_timer(TIMER_TIMEOUT, init_torrent_loading_timer)
    end
    local cache = curl(TORRSERVER .. "/cache", '{"action":"get","hash":"' .. current_torrent.hash .. '"}', true)
    if not cache then return end
    current_torrent.capacity = cache.Capacity
    if cache.Torrent then
        current_torrent.download_speed = cache.Torrent.download_speed
        current_torrent.loaded_size = cache.Torrent.loaded_size
        current_torrent.active_peers = cache.Torrent.active_peers
        current_torrent.total_peers = cache.Torrent.total_peers
        current_torrent.connected_seeders = cache.Torrent.connected_seeders
    end
    show_torrent_load_info(current_torrent, playing_pos)
end


local M3U_COMMENT = "# Generated by TorrServer-Loader"

local function generate_m3u(torrent)
    -- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst

    -- Portions of this code are derived from https://github.com/dyphire/mpv-scripts/blob/main/mpv-torrserver.lua#L123
    -- Copyright (c) <2022> dyphire
    -- Licensed under the MIT License https://github.com/dyphire/mpv-scripts/blob/main/LICENSE

    local function format_external_filename(basename, filename_path, torrent_name)
        local function remove_substr(str, needle)
            local i, j = str:find(needle, 1, true)
            if i then
                str = str:sub(1, i - 1) .. str:sub(j + 1)
            end
            return str
        end

        local function remove_duplicate_words(str)
            local seen = {}
            local result = {}

            for word in str:gmatch("%S+") do
                -- Removing all [], (), "" and spaces inside, and reducing them to lowercase
                local cleaned = word:gsub("[%[%]()\"]", ""):gsub("%s+", ""):lower()
                if cleaned and not seen[cleaned] then
                    seen[cleaned] = true
                    table.insert(result, word) -- Inserting the original word with quotes/brackets
                end
            end

            return table.concat(result, " ")
        end

        -- Removing the file extension
        local name = filename_path:match("^(.*)%.%w+$")
        name = remove_substr(name, basename)
        name = remove_substr(name, torrent_name)
        name = name:gsub("[./]", " ")
        name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        name = remove_duplicate_words(name)

        if name == "" then return nil end

        return name
    end

    local function extend_with_extra_info(fileinfo)
        fileinfo.filename = fileinfo.path:match("^.+[\\/](.+)$") or fileinfo.path
        fileinfo.name, fileinfo.ext = fileinfo.filename:match("^(.*)%.([^%.]+)$")
    end

    local function edlencode(url)
        return "%" .. string.len(url) .. "%" .. url
    end

    local playlist = { "#EXTM3U", M3U_COMMENT }
    local count = 0
    torrent.main_files = {}

    for i, fileinfo in ipairs(torrent.file_stats) do
        fileinfo.ext_tracks_count = 0
        if not fileinfo.filename then extend_with_extra_info(fileinfo) end

        if not fileinfo.processed and VIDEO_EXTS[fileinfo.ext] then
            fileinfo.processed = true

            table.insert(playlist, "#EXTINF:0," .. fileinfo.name)
            table.insert(torrent.main_files, i)

            local url = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. fileinfo.id .. "&play"
            local hdr = { "!new_stream", "!no_clip", edlencode(url) }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"

            if not fileinfo.ext_files then fileinfo.ext_files = {} end
            count = count + 1
            --mp.msg.info("Attached main file: " .. fileinfo.name)
            for j, extra_fileinfo in ipairs(torrent.file_stats) do
                if not extra_fileinfo.filename then extend_with_extra_info(extra_fileinfo) end

                if not extra_fileinfo.processed
                    and not VIDEO_EXTS[extra_fileinfo.ext]
                    and string.find(extra_fileinfo.name, fileinfo.name, 1, true) then
                    --mp.msg.info("Attached external track: " .. fileinfo2.name)
                    extra_fileinfo.title = format_external_filename(
                        fileinfo.name, extra_fileinfo.path, torrent.name
                    ) or (
                        "Unknown name (Index " .. extra_fileinfo.id .. ")"
                    )
                    table.insert(fileinfo.ext_files, j)
                    if not extra_fileinfo.type then
                        extra_fileinfo.type = AUDIO_EXTS[extra_fileinfo.ext] and "audio" or "sub"
                    end
                    if options.use_edl then
                        url = TORRSERVER ..
                            "/stream?link=" .. torrent.hash .. "&index=" .. extra_fileinfo.id .. "&play"
                        hdr = {
                            "!new_stream", "!no_clip", "!no_chapters",
                            "!delay_open,media_type=" .. extra_fileinfo.type,
                            "!track_meta,title=" .. edlencode(extra_fileinfo.title .. " [external]"),
                            edlencode(url)
                        }
                        edl = edl .. table.concat(hdr, ";") .. ";"
                    end
                    extra_fileinfo.processed = true
                    count = count + 1
                    fileinfo.ext_tracks_count = fileinfo.ext_tracks_count + 1
                end
            end

            if not options.use_edl or fileinfo.ext_tracks_count == 0 then
                table.insert(playlist, url)
            else
                table.insert(playlist, edl)
            end
        end
    end

    -- If this playlist is audio only
    if #torrent.file_stats > count then
        for i, fileinfo in ipairs(torrent.file_stats) do
            if not fileinfo.processed and AUDIO_EXTS[fileinfo.ext] then
                fileinfo.processed = true
                table.insert(torrent.main_files, i)
                table.insert(playlist, "#EXTINF:0," .. fileinfo.name)
                --mp.msg.info("Attached main file: " .. fileinfo.name)
                local url = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. fileinfo.id .. "&play"
                table.insert(playlist, url)
            end
        end
    end

    torrent.playlist = table.concat(playlist, '\n')
end

local function play_from_playlist(torrent_menu, index)
    current_torrent = torrent_menu
    playing_pos = index

    show_torrent_load_info(current_torrent, playing_pos)

    mp.commandv("loadlist", "memory://" .. current_torrent.playlist)
    mp.set_property_number("playlist-pos-1", index)
end

-- A temporary solution to the problem described here: https://github.com/mpv-player/mpv/pull/17256
-- TODO: remove this after a stable release of MPV where it'll be fixed
local function input_select(args)
    mp.add_timeout(0.01, function()
        input.select(args)
    end)
end

local function show_torrent_files(torrent_menu, torrent_index)
    if not torrent_menu.file_stats then
        torrent_menu = curl(TORRSERVER .. "/stream?link=" .. torrent_menu.hash .. "&stat")
        if not torrent_menu then return end
    end

    local viewed_list = curl(TORRSERVER .. "/viewed", '{"action":"list","hash":"' .. torrent_menu.hash .. '"}')
    if not viewed_list then viewed_list = {} end

    generate_m3u(torrent_menu)

    local items = {}
    local last_viewed
    for i, entry in ipairs(torrent_menu.main_files) do
        local filename = torrent_menu.file_stats[entry]
        for _, viewed in ipairs(viewed_list) do
            if viewed.file_index == filename.id then
                last_viewed = i
                break
            end
        end
        if i == last_viewed then
            table.insert(items, "x " .. filename.path)
        else
            table.insert(items, "   " .. filename.path)
        end
    end

    local selected = false
    input_select({
        prompt = "Select an entry of torrent:",
        items = items,
        default_item = last_viewed,

        submit = function(index)
            selected = true
            play_from_playlist(torrent_menu, index)
        end,
        closed = function()
            if selected then return end

            show_torrents(torrent_index)
        end,
    })
end

show_torrents = function(default_item)
    local torrents = curl(TORRSERVER .. "/torrents", '{"action":"list"}')
    if not torrents then return end

    local items = {}
    for i, entry in ipairs(torrents) do
        items[i] = entry.name or entry.title
    end

    input_select({
        prompt = "Select a torrent:",
        items = items,
        default_item = default_item,

        submit = function(index)
            show_torrent_files(torrents[index], index)
        end,
    })
end

local LOCAL_HOSTS = { "127.0.0.1", "[::1]", "localhost" }

local torrserver_is_localhost = false
for _, host in ipairs(LOCAL_HOSTS) do
    if options.host == host then
        torrserver_is_localhost = true
        break
    end
end

local function is_torrserver(path)
    if torrserver_is_localhost then
        for _, host in ipairs(LOCAL_HOSTS) do
            if path:find(options.scheme .. "://" .. host .. ":" .. options.port, 1, true) then
                return true
            end
        end
        return false
    else
        return path:find(TORRSERVER, 1, true)
    end
end


local function connect_external_assets()
    if not current_torrent then return end

    if options.use_edl then return end

    local main_fileinfo = current_torrent.file_stats[current_torrent.main_files[playing_pos]]
    main_fileinfo.loaded_ext_files = 0
    main_fileinfo.error_ext_files = 0
    for _, i_ext in ipairs(main_fileinfo.ext_files) do
        local ext_fileinfo = current_torrent.file_stats[i_ext]
        local url_ext = TORRSERVER .. "/stream?link=" .. current_torrent.hash .. "&index=" .. ext_fileinfo.id .. "&play"
        local cmd = ext_fileinfo.type == "audio" and "audio-add" or "sub-add"

        local request_id
        request_id = mp.command_native_async({ cmd, url_ext, "auto", ext_fileinfo.title }, function(success)
            loadings[request_id] = nil

            if success then
                main_fileinfo.loaded_ext_files = main_fileinfo.loaded_ext_files + 1
            else
                main_fileinfo.error_ext_files = main_fileinfo.error_ext_files + 1
            end

            show_torrent_load_info(current_torrent, playing_pos)
        end)

        loadings[request_id] = true
    end
end

local function observe_demuxer_cache(_, value)
    if not value or update_timer or not current_torrent or not is_buffering(value) then
        return
    end
    init_torrent_loading_timer()
end

local function abort_loadings()
    mp.unobserve_property(observe_demuxer_cache)

    for request_id in pairs(loadings) do
        mp.abort_async_command(request_id)
    end
    loadings = {}
end

local function load_external_assets()
    local path = mp.get_property("path", "")
    if not is_torrserver(path) then
        current_torrent = nil
        return
    end

    mp.observe_property("demuxer-cache-duration", "number", observe_demuxer_cache)
    playing_pos = mp.get_property_number("playlist-pos-1", 1)

    if mp.get_property("playlist-path", ""):find(M3U_COMMENT, 1, true) then
        connect_external_assets()
        init_torrent_loading_timer()
        return
    end
    local btih = path:match("%link=(" .. string.rep("[a-fA-F0-9]", 40) .. ")")
    if not btih then
        current_torrent = nil
        mp.osd_message("Invalid BTIH extracted from path!", 7)
        return
    end

    if current_torrent and current_torrent.hash ~= btih then
        current_torrent = nil
    end

    if not current_torrent or not current_torrent.file_stats then
        current_torrent = curl(TORRSERVER .. "/stream?link=" .. btih .. "&stat")
        if not current_torrent then return end
    end

    if not current_torrent.playlist then
        generate_m3u(current_torrent)
    end

    -- finding pos of playlist
    local play_index = 1
    local found_pos = false
    local file_index = tonumber(path:match("index=(%d+)"))
    for i, entry in ipairs(current_torrent.main_files) do
        local fileinfo = current_torrent.file_stats[entry]
        if fileinfo.id == file_index then
            found_pos = true
            play_index = i
            break
        end
    end
    if not found_pos then
        mp.msg.warn("Couldn't find playlist position")
    end

    mp.commandv("loadlist", "memory://" .. current_torrent.playlist)
    mp.set_property_number("playlist-pos-1", play_index)
end

-- By default, edl inserts a chapter with a link in the name, we fix this by deleting it.
-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst#implicit-chapters
local function fix_edl_chapters()
    if not current_torrent then return end

    local chapters = mp.get_property_native("chapter-list")
    if not chapters then return end

    local found = false
    for i = #chapters, 1, -1 do
        local ch = chapters[i]
        if ch.time == 0 and ch.title and is_torrserver(ch.title) then
            table.remove(chapters, i)
            found = true
            break
        end
    end
    if not found then return end

    mp.set_property_native("chapter-list", chapters)
end

mp.add_hook("on_load", 5, function()
    abort_loadings()
    load_external_assets()
end)
mp.add_hook("on_preloaded", 5, fix_edl_chapters)
mp.add_key_binding("Ctrl+t", "torr_open", show_torrents)
