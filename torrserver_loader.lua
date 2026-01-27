-- Lua script for MPV to load external subtitles and audios based on the current video series M3U info from TorrServer.
--
-- Requires **curl** to be installed in your OS.

local mp = require "mp"
local utils = require "mp.utils"

local options = {
    TORRSERVER_HOST = "127.0.0.1",
    TORRSERVER_PORT = "8090",
}
require "mp.options".read_options(options, "torrserver-loader")

local TORRSERVER = "http://"..options.TORRSERVER_HOST..":"..options.TORRSERVER_PORT

local torrents = {}
local menu = {}
local cursor_pos = 1
local state = "hidden" -- torrents | files | hidden
local torrent_index = 1
local VISIBLE_LINES = 12
local offset = 0
local opened_btih

local back

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

local function curl(url, json, data)
    mp.osd_message("Requesting TorrServer's API...", 99)
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

    if data or json then
        response = utils.parse_json(response)
    end

    mp.osd_message("")
    return response
end

local function torr_osd()
    local osd_title
    if state == "hidden" then
        mp.osd_message("")
        return
    elseif state == "torrents" then
        osd_title = "torrent list"
    elseif state == "files" then
        osd_title = "torrent content"
    end

    local text = "TorrServer - " .. osd_title .. "\n\n"

    local start = offset + 1
    local finish = math.min(offset + VISIBLE_LINES, #menu)

    for i = start, finish do
        text = text
            .. ((i == cursor_pos) and "▶ " or "  ")
            .. menu[i] .. "\n"
    end

    if #menu > VISIBLE_LINES then
        text = text .. string.format("\n[%d/%d]", cursor_pos, #menu)
    end

    mp.osd_message(text, 60)
end

local function remove_menu_keys()
    mp.remove_key_binding("torr_up")
    mp.remove_key_binding("torr_down")
    mp.remove_key_binding("torr_enter")
    mp.remove_key_binding("torr_back")
    mp.remove_key_binding("torr_close")
end

local function close_menu()
    state = "hidden"
    remove_menu_keys()
    mp.osd_message("")
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
    s = s:gsub("^%s+", "")  -- remove the spaces at the beginning
    s = s:gsub("%s+$", "")  -- remove spaces at the end
    s = s:gsub("%s+", " ")  -- replace multiple spaces with one
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

local function name_of_file(fileinfo)
    fileinfo.filename = fileinfo.path:match("^.+[\\/](.+)$") or fileinfo.path
    fileinfo.name, fileinfo.ext = fileinfo.filename:match("^(.*)%.([^%.]+)$")
end

-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst
local function generate_m3u_edl(torrent)
    -- Portions of this code are derived from https://github.com/dyphire/mpv-scripts/blob/main/mpv-torrserver.lua#L123
    -- Copyright (c) <2022> dyphire
    -- Licensed under the MIT License https://github.com/dyphire/mpv-scripts/blob/main/LICENSE

    local playlist = { "#EXTM3U", "# Generated by TorrServer-Loader" }
    local count = 0

    for _, fileinfo in ipairs(torrent.file_stats) do
        if not fileinfo.filename then name_of_file(fileinfo) end

        if not fileinfo.processed and VIDEO_EXTS[fileinfo.ext] then
            table.insert(playlist, '#EXTINF:0,' .. fileinfo.name)

            local url = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. fileinfo.id .. "&play"
            local hdr = { "!new_stream", "!no_clip",
                --"!track_meta,title=" .. edlencode(basename),
                          edlencode(url)
            }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"
            local external_tracks = 0

            fileinfo.processed = true
            fileinfo.main_file = true
            count = count + 1
            --mp.msg.info("!" .. fileinfo.name)
            for _, fileinfo2 in ipairs(torrent.file_stats) do
                if not fileinfo2.filename then name_of_file(fileinfo2) end

                if not fileinfo2.processed and not VIDEO_EXTS[fileinfo2.ext] and string.find(fileinfo2.name, fileinfo.name, 1, true) then
                    --mp.msg.info("->" .. fileinfo2.name)
                    local title = format_external_filename(fileinfo.name, fileinfo2.path, torrent.name) or ("Unknown name (Index "..fileinfo2.id .. ")")
                    local url = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. fileinfo2.id .. "&play"
                    local hdr = { "!new_stream", "!no_clip", "!no_chapters",
                                  "!delay_open,media_type=" .. (AUDIO_EXTS[fileinfo2.ext] and "audio" or "sub"),
                                  "!track_meta,title=" .. edlencode(title),
                                  edlencode(url)
                    }
                    edl = edl .. table.concat(hdr, ";") .. ";"
                    fileinfo2.processed = true
                    count = count + 1
                    external_tracks = external_tracks + 1
                end
            end

            if external_tracks == 0 then -- dont use edl
                table.insert(playlist, url)
            else
                fileinfo.count_ext_tracks = external_tracks
                table.insert(playlist, edl)
            end
        end
    end

    -- if this playlist is audio only
    if #torrent.file_stats > count then
        for _, fileinfo in ipairs(torrent.file_stats) do
            if not fileinfo.processed and AUDIO_EXTS[fileinfo.ext] then
                fileinfo.processed = true
                fileinfo.main_file = true
                table.insert(playlist, '#EXTINF:0,' .. fileinfo.name)
                local url = TORRSERVER .. "/stream?link=" .. torrent.hash .. "&index=" .. fileinfo.id .. "&play"
                table.insert(playlist, url)
            end
        end
    end

    torrent.playlist = table.concat(playlist, '\n')
end

local function load_files(torrent)
    menu = {}
    cursor_pos = 1
    offset = 0
    state = "files"

    generate_m3u_edl(torrent)

    for _, fileinfo in ipairs(torrent.file_stats) do
        if fileinfo.main_file then
            table.insert(menu, fileinfo.filename)
        end
    end

    torr_osd()
end

local function play_from_playlist(torrent, index)
    close_menu()

    mp.osd_message("Opening " .. (torrent.name or torrent.title) .. "...")

    opened_btih = torrent.hash
    mp.commandv("loadlist", "memory://" .. torrent.playlist)
    mp.set_property_number("playlist-pos", index - 1)
end

local function enter()
    if state == "torrents" then
        if not torrents[cursor_pos].file_stats then
            local torrent = curl(TORRSERVER .. "/stream?link=" .. torrents[cursor_pos].hash .. "&stat", true)
            if not torrent then return end
            torrents[cursor_pos] = torrent
        end
        torrent_index = cursor_pos
        load_files(torrents[cursor_pos])
    elseif state == "files" then
        play_from_playlist(torrents[torrent_index], cursor_pos)
    end
end

local function add_menu_keys()
    mp.add_forced_key_binding("UP", "torr_up", function()
        if cursor_pos > 1 then
            cursor_pos = cursor_pos - 1

            if cursor_pos <= offset then
                offset = math.max(0, cursor_pos - 1)
            end

            torr_osd()
        end
    end, { repeatable = true })

    mp.add_forced_key_binding("DOWN", "torr_down", function()
        if cursor_pos < #menu then
            cursor_pos = cursor_pos + 1

            if cursor_pos > offset + VISIBLE_LINES then
                offset = cursor_pos - VISIBLE_LINES
            end

            torr_osd()
        end
    end, { repeatable = true })

    mp.add_forced_key_binding("ENTER", "torr_enter", enter)
    mp.add_forced_key_binding("BS", "torr_back", back)
    mp.add_forced_key_binding("ESC", "torr_close", close_menu)
end

local function show_torrents()
    torrents = curl(TORRSERVER .. "/torrents", true, '{"action":"list"}')
    if not torrents then return end

    menu = {}
    cursor_pos = 1
    offset = 0
    state = "torrents"
    add_menu_keys()

    for _, t in ipairs(torrents) do
        table.insert(menu, t.name or t.title)
    end

    torr_osd()
end

back = function()
    if state == "files" then
        show_torrents()
    else
        close_menu()
    end
end

mp.add_key_binding("Ctrl+t", "torr_open", show_torrents)


local function load_external_assets()
    local path = mp.get_property("path", "")
    if not path:find(TORRSERVER, 1, true) then
        return
    end
    if mp.get_property("playlist-path", ""):find("# Generated by TorrServer-Loader", 1, true) then
        return
    end
    local btih = path:match("%link=(" .. string.rep(".",40) .. ")")
    if not btih then
        mp.osd_message("Invalid BTIH extracted from path!", 7)
        return
    end
    if opened_btih and opened_btih == btih and not mp.get_property("media-title", ""):find(btih, 1, true) then
        return
    end

    local torrent
    for _, t in ipairs(torrents) do
        if t.hash == btih then
            torrent = t
            break
        end
    end
    if not torrent then
        torrent = curl(TORRSERVER .. "/stream?link=" .. btih .. "&stat", true)
        if not torrent then return end
        table.insert(torrents, torrent)
    end

    local memory_link = torrent.playlist
    if not memory_link then
        generate_m3u_edl(torrent)
        memory_link = torrent.playlist
    end
    --mp.msg.info(memory_link)

    -- finding pos of playlist
    local count = 0
    local play_index = 1
    local found_pos = false
    local file_index = tonumber(path:match("index=(%d+)"))
    for _, fileinfo in ipairs(torrent.file_stats) do
        if fileinfo.main_file then
            if fileinfo.id == file_index then
                play_index = count
                found_pos = true
                break
            end
            count = count + 1
        end
    end
    if not found_pos then
        mp.msg.warn("Couldn't find playlist position")
    end

    opened_btih = btih
    mp.commandv("loadlist", "memory://" .. memory_link)
    mp.set_property_number("playlist-pos", play_index)
end

mp.add_hook("on_load", 5, load_external_assets)
