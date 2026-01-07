-- Lua script for MPV to load external subtitles and audios based on the current video series M3U info from TorrServerq.
--
-- Requires **curl** to be installed in your OS.

local mp = require "mp"
local utils = require "mp.utils"

local options = {
    TORRSERVER_URL_HOST = "127.0.0.1",
    TORRSERVER_URL_PORT = "8090",
}
require "mp.options".read_options(options, "torrserver-loader")

local TORRSERVER_URL = "http://" .. options.TORRSERVER_URL_HOST .. ":" .. options.TORRSERVER_URL_PORT

local torrents = {}
local menu = {}
local cursor_pos = 1
local state = "hidden" -- torrents | files | hidden
local torrent_index = 1
local VISIBLE_LINES = 12
local offset = 0


local function curl(url, data)
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

    if data then
        response = utils.parse_json(response)
    end

    mp.osd_message("")
    return response
end

local function load_torrents()
    torrents = curl(TORRSERVER_URL .. "/torrents", '{"action":"list"}')
    --- @diagnostic disable: param-type-mismatch, need-check-nil
    for i, _ in ipairs(torrents) do
        torrents[i].index = i
    --- @diagnostic enable: param-type-mismatch, need-check-nil
    end
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

local function close_menu()
    state = "hidden"
    mp.osd_message("")
end

local function get_lines_from_string(s)
    return s:gmatch("([^\r\n]+)")
end

local function get_torrent_tracks(torrent)
    local function split(str, sep)
        local t = {}
        for s in str:gmatch("[^" .. sep .. "]+") do
            table.insert(t, s)
        end
        return t
    end

    local response = curl(TORRSERVER_URL .. "/playlist?hash=" .. torrent.hash)

    local tracks = {}

    local current = {
        title = nil,
        duration = nil,
        vlcopt = {}
    }

    for line in get_lines_from_string(response) do
        line = line:gsub("\r", "")

        local dur, title = line:match("^#EXTINF:([^,]*),(.*)")
        if dur then
            current.duration = tonumber(dur) or -1
            current.title = title
        end

        local opt, value = line:match("^#EXTVLCOPT:([^=]+)=(.+)")
        if opt then
            opt = opt:gsub("%-", "_")

            if opt == "input_slave" then
                current.vlcopt.input_slave = split(value, "#")
            else
                current.vlcopt[opt] = value
            end
        end

        -- Media URL
        if line ~= "" and not line:match("^#") then
            current.url = line

            table.insert(tracks, {
                title = current.title,
                duration = current.duration,
                url = current.url,
                vlcopt = current.vlcopt
            })

            current = {
                title = nil,
                duration = nil,
                vlcopt = {}
            }
        end
    end

    return tracks
end

local function play_from_playlist(torrent, index)
    close_menu()
    local playlist_url = string.format(
        "%s/playlist/?hash=%s",
        TORRSERVER_URL,
        torrent.hash
    )

    torrent.position = index
    state = "hidden"
    mp.osd_message("Opening " .. (torrent.name or torrent.title) .. "...")

    mp.commandv("loadlist", playlist_url, "replace")
    mp.set_property_number("playlist-pos", index - 1)
end

local function show_torrents()
    load_torrents()

    menu = {}
    cursor_pos = 1
    offset = 0
    state = "torrents"

    for _, t in ipairs(torrents) do
        table.insert(menu, t.name or t.title)
    end

    torr_osd()
end

local function show_torrent_files(torrent)
    menu = {}
    cursor_pos = 1
    offset = 0
    state = "files"

    torrent.tracks = get_torrent_tracks(torrent)

    for _, track in ipairs(torrent.tracks) do
        table.insert(menu, track.title)
    end

    torr_osd()
end

mp.add_key_binding("Ctrl+t", "torr_open", show_torrents)

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

mp.add_forced_key_binding("ENTER", "torr_enter", function()
    if state == "torrents" then
        torrent_index = cursor_pos
        show_torrent_files(torrents[cursor_pos])
    elseif state == "files" then
        play_from_playlist(torrents[torrent_index], cursor_pos)
    end
end)

mp.add_forced_key_binding("BS", "torr_back", function()
    if state == "files" then
        show_torrents()
    else
        state = "hidden"
        mp.osd_message("")
    end
end)

mp.add_forced_key_binding("ESC", "torr_close", close_menu)


-- Loader

-- TODO: extend this list
local AUDIO_EXTS = {
    aac = true,
    ac3 = true,
    aif = true,
    aiff = true,
    amr = true,
    flac = true,
    m4a = true,
    mka = true,
    mp3 = true,
    ogg = true,
    opus = true,
    wav = true,
    wma = true,
}

local loadings = {}
local total_files = 0
local loaded_files = 0
local error_files = 0

local function update_loading_osd()
    local timeout = 120
    if total_files == loaded_files + error_files then
        timeout = 5
    end
    mp.osd_message(
        string.format("Loaded external files: %d/%d, Errors %d", loaded_files, total_files, error_files),
        timeout
    )
end

local function urldecode(url)
    return url:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function extract_external_name(url_ext, url_main, torrent)
    -- external name
    local function replace(str, substr)
        local i, j = str:find(substr, 1, true)
        if i then
            str = str:sub(1, i - 1) .. str:sub(j + 1)
        end
        return str
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
            -- Removing all [], (), "" and spaces inside, and reducing them to lowercase
            return word:gsub("[%[%]()\"]", ""):gsub("%s+", ""):lower()
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

    if not torrent.file_stats or not torrent.name then return nil end

    local index = tonumber(url_ext:match("index=(%d+)"))
    local file_stat = torrent.file_stats[index]
    if not file_stat then return nil end
    local name = file_stat.path
    local filename_main = urldecode(url_main)
    -- Everything before the file extension
    filename_main = filename_main:match("^(.*)%.%w+")
    -- Removing the file extension
    name = name:match("^(.*)%.%w+$")
    name = replace(name, torrent.name)
    name = replace(name, filename_main)
    name = name:gsub("[./]", " ")
    name = remove_extra_spaces(name)
    name = remove_duplicate_words(name)

    return name
end

local function load_external_assets()
    if not mp.get_property("path"):find(TORRSERVER_URL, 1, true) then
        return
    end
    local filename = mp.get_property("filename", "")
    local file_btih = filename:match("%?link=(" .. string.rep(".", 40) .. ")")
    if not file_btih then
        mp.osd_message("Invalid BTIH extracted from filename!", 7)
        return
    end

    local function find_torrent(btih)
        for _, t in ipairs(torrents) do
            if t.hash == btih then
                return t
            end
        end
    end

    local torrent = find_torrent(file_btih)
    if not torrent or not torrent.file_stats then
        load_torrents()
        local new_torrent = find_torrent(file_btih)
        if not new_torrent then
            mp.osd_message("Failed to find torrent!", 7)
            return
        end
        if torrent and torrent.tracks then
            new_torrent.tracks = torrent.tracks
        end
        torrent = new_torrent
    end

    if not torrent.tracks then
        torrent.tracks = get_torrent_tracks(torrent)
    end

    local track
    for _, t in ipairs(torrent.tracks) do
        if urldecode(t.url):find(urldecode(filename), 1, true) then
            track = t
        end
    end

    if not track then
        mp.osd_message("Failed to parse current video info from M3U playlist!", 7)
        return
    end

    if not track.vlcopt.input_slave then
        mp.osd_message("This video doesn't contain any external subtitles and audio.", 7)
        return
    end

    loaded_files = 0
    loadings = {}
    total_files = #track.vlcopt.input_slave
    error_files = 0

    for _, url in ipairs(track.vlcopt.input_slave) do
        local ext = url:match(".*%.([^%.%?]+)%?")
        local caption = extract_external_name(url, filename, torrent) or ("Index " .. (url:match("index=(%d+)") or "?"))
        local cmd = AUDIO_EXTS[ext] and "audio-add" or "sub-add"

        local loading = mp.command_native_async({ cmd, url, "auto", caption }, function(success)
            if success then
                loaded_files = loaded_files + 1
                mp.command("script-message trigger-trackselect")
            else
                error_files = error_files + 1
            end
            update_loading_osd()
        end)
        table.insert(loadings, loading)
    end

    update_loading_osd()
end

local function abort_loadings()
    for _, loading in ipairs(loadings) do
        mp.abort_async_command(loading)
    end
    loadings = {}
end

for _, event in ipairs({ "file-loaded", "playlist-pos-changes" }) do
    mp.register_event(event, function()
        abort_loadings()
        load_external_assets()
    end)
end
