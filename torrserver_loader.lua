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

local torrent
local file_index = 1
local loadings = {}

local show_torrents

-- https://github.com/YouROK/TorrServer/blob/master/server/utils/filetypes.go#L10
local VIDEO_EXTS = {
    ['3g2'] = true,
    ['3gp'] = true,
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
    if cache_time < 1 then
        return true
    elseif not options.use_edl and next(loadings) then
        return true
    end
    return false
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

local function bytes_to_gb(bytes)
    return string.format("%.2f", bytes / (1024 ^ 3))
end

local function show_torrent_load_info(torr, file_ind)
    local dcd = mp.get_property_number("demuxer-cache-duration", nil)
    local current_state_loading = ''
    if not dcd then
        current_state_loading = 'Opening'
    elseif dcd < 1.0 then
        current_state_loading = 'Caching'
    end

    local download_speed = humanize_speed(torr.download_speed or 0)

    local preloaded_gb = bytes_to_gb(torr.loaded_size or 0)
    local total_gb = bytes_to_gb(torr.capacity or 0)

    local peers_info = string.format("%d / %d · %d", torr.active_peers or 0, torr.total_peers or 0,
        torr.connected_seeders or 0)

    local ext_files
    local filename = torr.file_stats[file_ind]
    local timeout
    if options.use_edl then
        ext_files = "Connected " .. filename.count_ext_tracks .. " external files"
    else
        ext_files = string.format("Connected %d / %d external files, Errors: %d", filename.loaded_ext_files or 0,
            filename.count_ext_tracks, filename.error_ext_files or 0)
        if next(loadings) then
            timeout = 99
            if #current_state_loading > 0 then
                current_state_loading = current_state_loading .. ' / Connecting external files'
            else
                current_state_loading = 'Connecting external files'
            end
        end
    end

    local message = string.format(
        "Loading %s...\nCurrent state: %s\n\nTorrent load info:\nSpeed: %s\nCache: %s / %s GB\nPeers·Seeders: %s\n\n%s",
        filename.filename, current_state_loading, download_speed, preloaded_gb, total_gb, peers_info, ext_files
    )
    mp.osd_message(message, timeout)
end

local update_timer
local function timer_torrent_load_info()
    if not torrent or not is_buffering() then
        if update_timer then
            update_timer:kill()
            update_timer = nil
        end
        return
    elseif not update_timer then
        update_timer = mp.add_periodic_timer(0.5, timer_torrent_load_info)
    end
    local cache = curl(TORRSERVER .. "/cache", '{"action":"get","hash":"' .. torrent.hash .. '"}', true)
    if not cache then return end
    torrent.capacity = cache.Capacity
    if cache.Torrent then
        torrent.download_speed = cache.Torrent.download_speed
        torrent.loaded_size = cache.Torrent.loaded_size
        torrent.active_peers = cache.Torrent.active_peers
        torrent.total_peers = cache.Torrent.total_peers
        torrent.connected_seeders = cache.Torrent.connected_seeders
    end
    show_torrent_load_info(torrent, file_index)
end

-- external name
local function replace(s, needle)
    local i, j = s:find(needle, 1, true)
    if i then
        s = s:sub(1, i - 1) .. s:sub(j + 1)
    end
    return s
end

local function remove_extra_spaces(s)
    s = s:gsub("^%s+", "") -- remove the spaces at the beginning
    s = s:gsub("%s+$", "") -- remove spaces at the end
    s = s:gsub("%s+", " ") -- replace multiple spaces with one
    return s
end

local function remove_duplicate_words(str)
    local seen = {}
    local result = {}

    -- a function for clearing words from quotation marks/brackets and reducing them to lowercase
    local function clean_word(word)
        -- we remove all [], (), "" and spaces inside, and reduce them to lowercase
        word = word:gsub("[%[%]()\"]", ""):gsub("%s+", "")
        return word:lower()
    end

    for word in str:gmatch("%S+") do
        local cleaned = clean_word(word)
        if cleaned and not seen[cleaned] then
            seen[cleaned] = true
            table.insert(result, word) -- inserting the original word with quotes/brackets
        end
    end

    return table.concat(result, " ")
end

local function format_external_filename(basename, filename_path, torrent_name)
    -- removing the file extension
    local name = filename_path:match("^(.*)%.%w+$")
    -- removing the base file name
    name = replace(name, basename)
    -- deleting the torrent name (usually the name of the root folder)
    name = replace(name, torrent_name)
    -- removing the dots "." and slashes "/"
    name = name:gsub("[./]", " ")
    name = remove_extra_spaces(name)
    name = remove_duplicate_words(name)

    if name == "" then return nil end

    return name
end


local function edlencode(url)
    return "%" .. string.len(url) .. "%" .. url
end

local function extend_with_extra_fileinfo(fileinfo)
    fileinfo.filename = fileinfo.path:match("^.+[\\/](.+)$") or fileinfo.path
    fileinfo.name, fileinfo.ext = fileinfo.filename:match("^(.*)%.([^%.]+)$")
end

-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst
local function generate_m3u_edl(torr)
    -- Portions of this code are derived from https://github.com/dyphire/mpv-scripts/blob/main/mpv-torrserver.lua#L123
    -- Copyright (c) <2022> dyphire
    -- Licensed under the MIT License https://github.com/dyphire/mpv-scripts/blob/main/LICENSE

    local playlist = { "#EXTM3U", "# Generated by TorrServer-Loader" }
    local count = 0

    for _, fileinfo in ipairs(torr.file_stats) do
        if not fileinfo.filename then extend_with_extra_fileinfo(fileinfo) end

        if not fileinfo.processed and VIDEO_EXTS[fileinfo.ext] then
            table.insert(playlist, '#EXTINF:0,' .. fileinfo.name)

            local url = TORRSERVER .. "/stream?link=" .. torr.hash .. "&index=" .. fileinfo.id .. "&play"
            local hdr = { "!new_stream", "!no_clip",
                --"!track_meta,title=" .. edlencode(basename),
                edlencode(url)
            }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"
            local external_tracks = 0

            fileinfo.processed = true
            fileinfo.main_file = true
            if not fileinfo.ext_files then fileinfo.ext_files = {} end
            count = count + 1
            --mp.msg.info("Attached main file: " .. fileinfo.name)
            for i, fileinfo2 in ipairs(torr.file_stats) do
                if not fileinfo2.filename then extend_with_extra_fileinfo(fileinfo2) end

                if not fileinfo2.processed and not VIDEO_EXTS[fileinfo2.ext] and string.find(fileinfo2.name, fileinfo.name, 1, true) then
                    --mp.msg.info("Attached external track: " .. fileinfo2.name)
                    fileinfo2.title = format_external_filename(fileinfo.name, fileinfo2.path, torr.name) or
                        ("Unknown name (Index " .. fileinfo2.id .. ")")
                    table.insert(fileinfo.ext_files, i)
                    if not fileinfo2.type then
                        fileinfo2.type = AUDIO_EXTS[fileinfo2.ext] and "audio" or "sub"
                    end
                    if options.use_edl then
                        -- TODO: check if we can assign those values to upper url and hdr vars
                        local url_ext = TORRSERVER ..
                        "/stream?link=" .. torr.hash .. "&index=" .. fileinfo2.id .. "&play"
                        local hdr_ext = {
                            "!new_stream", "!no_clip", "!no_chapters",
                            "!delay_open,media_type=" .. fileinfo2.type,
                            "!track_meta,title=" .. edlencode(fileinfo2.title .. " [external]"),
                            edlencode(url_ext)
                        }
                        edl = edl .. table.concat(hdr_ext, ";") .. ";"
                    end
                    fileinfo2.processed = true
                    count = count + 1
                    external_tracks = external_tracks + 1
                end
            end
            fileinfo.count_ext_tracks = external_tracks

            if not options.use_edl or external_tracks == 0 then -- dont use edl
                table.insert(playlist, url)
            else
                table.insert(playlist, edl)
            end
        end
    end

    -- if this playlist is audio only
    if #torr.file_stats > count then
        for _, fileinfo in ipairs(torr.file_stats) do
            if not fileinfo.processed and AUDIO_EXTS[fileinfo.ext] then
                fileinfo.processed = true
                fileinfo.main_file = true
                table.insert(playlist, '#EXTINF:0,' .. fileinfo.name)
                local url = TORRSERVER .. "/stream?link=" .. torr.hash .. "&index=" .. fileinfo.id .. "&play"
                table.insert(playlist, url)
            end
        end
    end

    torr.playlist = table.concat(playlist, '\n')
end

local function play_from_playlist(torrent_menu, index)
    torrent = torrent_menu
    file_index = index

    show_torrent_load_info(torrent, file_index)

    mp.commandv("loadlist", "memory://" .. torrent.playlist)
    mp.set_property_number("playlist-pos-1", index)
end

-- temporary solution to the problem
-- https://github.com/mpv-player/mpv/pull/17256
-- TODO: remove this after a stable release of MPV with a fix appears
local function input_select(args)
    mp.add_timeout(0.1, function()
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

    generate_m3u_edl(torrent_menu)

    local items = {}
    local last_viewed
    for i, entry in ipairs(torrent_menu.file_stats) do
        if entry.main_file then
            for _, entry2 in ipairs(viewed_list) do
                if entry2.file_index == entry.id then
                    last_viewed = i
                    break
                end
            end
            if i == last_viewed then
                items[i] = "> " .. entry.filename
            else
                items[i] = "   " .. entry.filename
            end
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

mp.add_key_binding("Ctrl+t", "torr_open", show_torrents)


local LOCAL_HOSTS = { "127.0.0.1", "[::1]", "localhost" }

local torrserver_is_localhost = false
for _, host in ipairs(LOCAL_HOSTS) do
    if options.host == host then
        torrserver_is_localhost = true
        break
    end
end

local function is_torrserver(path)
    if not path then
        path = mp.get_property("path", "")
    end
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
    if not torrent then return end

    if options.use_edl then return end

    local main_fileinfo = torrent.file_stats[file_index]
    main_fileinfo.loaded_ext_files = 0
    main_fileinfo.error_ext_files = 0
    for _, i_ext in ipairs(main_fileinfo.ext_files) do
        local ext_fileinfo = torrent.file_stats[i_ext]
        local url_ext = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. ext_fileinfo.id .. "&play"
        local cmd = ext_fileinfo.type == 'audio' and "audio-add" or "sub-add"

        local request_id
        request_id = mp.command_native_async({ cmd, url_ext, "auto", ext_fileinfo.title }, function(success)
            loadings[request_id] = nil

            if success then
                main_fileinfo.loaded_ext_files = main_fileinfo.loaded_ext_files + 1
            else
                main_fileinfo.error_ext_files = main_fileinfo.error_ext_files + 1
            end

            show_torrent_load_info(torrent, file_index)
        end)

        loadings[request_id] = true
    end
end

local function abort_loadings()
    for request_id in pairs(loadings) do
        mp.abort_async_command(request_id)
    end
    loadings = {}
end

local function load_external_assets()
    abort_loadings()

    local path = mp.get_property("path", "")
    if not is_torrserver(path) then
        torrent = nil
        return
    end

    file_index = mp.get_property_number("playlist-pos-1", 1)

    if mp.get_property("playlist-path", ""):find("# Generated by TorrServer-Loader", 1, true) then
        connect_external_assets()
        timer_torrent_load_info()
        return
    end
    local btih = path:match("%link=(" .. string.rep(".", 40) .. ")")
    if not btih then
        torrent = nil
        mp.osd_message("Invalid BTIH extracted from path!", 7)
        return
    end

    if torrent and torrent.hash ~= btih then
        torrent = nil
    end

    if not torrent or not torrent.file_stats then
        torrent = curl(TORRSERVER .. "/stream?link=" .. btih .. "&stat")
        if not torrent then return end
    end

    if not torrent.playlist then
        generate_m3u_edl(torrent)
    end

    -- finding pos of playlist
    local play_index = 0
    local found_pos = false
    local f_index = tonumber(path:match("index=(%d+)"))
    for _, fileinfo in ipairs(torrent.file_stats) do
        if fileinfo.main_file then
            play_index = play_index + 1
            if fileinfo.id == f_index then
                found_pos = true
                break
            end
        end
    end
    if not found_pos then
        play_index = 1
        mp.msg.warn("Couldn't find playlist position")
    end

    mp.commandv("loadlist", "memory://" .. torrent.playlist)
    mp.set_property_number("playlist-pos-1", play_index)
end

mp.add_hook("on_load", 5, load_external_assets)

-- By default, edl inserts a chapter with a link in the name, we fix this by deleting it.
-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst#implicit-chapters
local function fix_edl_chapters()
    if not torrent then return end

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

mp.add_hook("on_preloaded", 5, fix_edl_chapters)

mp.observe_property("demuxer-cache-duration", "number", function(_, value)
    if not value then return end
    if update_timer or not torrent or not is_buffering(value) then
        return
    end

    timer_torrent_load_info()
end)
