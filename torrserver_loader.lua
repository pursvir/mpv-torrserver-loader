-- Lua script for MPV to load external subtitles and audios based on the current video series M3U info from TorrServer.
--
-- Requires **curl** to be installed in your OS.

local string = require "string"

local TORRSERVER_HOST = "127.0.0.1"
local TORRSERVER_PORT = "8090"

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

local function urldecode(url)
    return url:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function load_external_assets()
    local filename = mp.get_property("filename", "")
    local btih = filename:match("%?link=(" .. string.rep(".", 40) .. ")")
    local request = io.popen(
        "curl http://" .. TORRSERVER_HOST .. ":" .. TORRSERVER_PORT .. "/playlist?hash=" .. btih
    )
    local m3u = request:read("*a")
    if not m3u then
        print("Empty response from TorrServer's API!")
        return
    end
    local success, _, exit_code = request:close()
    if not success then
        if exit_code == 6 then
            print("Couldn't resolve TorrServer's host!")
        elseif exit_code == 7 then
            print("Failed to make request to TorrServer's API!")
        elseif exit_code == 28 then
            print("Connection to TorrServer's API timed out!")
        elseif exit_code == 127 then
            print("curl command not found!")
        else
            print("Failed to load M3U!")
        end
        return
    end

    local input_slaves_row = nil
    for row in m3u:gmatch("[^\r\n]+") do
        if urldecode(row):find(filename, 1, true) then
            success = true
            break
        end
        input_slaves_row = row
    end
    local EXTVLCOPT = "#EXTVLCOPT:input-slave="
    if not success then
        print("Failed to parse current video info from M3U playlist!")
        return
    end
    if not string.find(input_slaves_row, EXTVLCOPT, 0, true) then
        print("This video doesn't contain any external subtitles and audio.")
        return
    end

    input_slaves_row = string.sub(input_slaves_row, #EXTVLCOPT + 1)
    for url in (input_slaves_row):gmatch("(.-)#") do
        local ext = url:match(".*%.([^%.%?]+)%?")
        -- Not that informative, but that's all what I can get from TorrServer's API for now. :(
        local index = "Index " .. url:match("[?&]index=(%d+)")
        if AUDIO_EXTS[ext] then
            mp.commandv("audio-add", url, "auto", index)
        else
            mp.commandv("sub-add", url, "auto", index)
        end
    end
end

mp.register_event("file-loaded", load_external_assets)
