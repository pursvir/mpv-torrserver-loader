-- Lua script for MPV to load external subtitles and audios based on the current video series M3U info from TorrServer.
--
-- Requires **curl** to be installed in your OS.

local string = require "string"

local options = {
    TORRSERVER_HOST = "127.0.0.1",
    TORRSERVER_PORT = "8090",
}
require "mp.options".read_options(options, "torrserver-loader")

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

local loadings = {}

local function load_external_assets()
    local filename = mp.get_property("filename", "")
    local btih = filename:match("%?link=(" .. string.rep(".", 40) .. ")")
    local request, err = io.popen(
        "curl http://" .. options.TORRSERVER_HOST .. ":" .. options.TORRSERVER_PORT .. "/playlist?hash=" .. btih
    )
    if not request then
        mp.osd_message("Cannot call curl: ", err)
        return
    end
    ---@diagnostic disable: need-check-nil
    local m3u = request:read("*a")
    ---@diagnostic enable: need-check-nil
    if not m3u then
        mp.osd_message("No response from TorrServer's API!")
        return
    end
    ---@diagnostic disable: need-check-nil
    local success, reason, code = request:close()
    ---@diagnostic enable: need-check-nil
    if not success then
        print("curl execution failed: ", reason .. " " .. code)
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
        mp.osd_message("Failed to parse current video info from M3U playlist!")
        return
    end
    if not string.find(input_slaves_row, EXTVLCOPT, 0, true) then
        mp.osd_message("This video doesn't contain any external subtitles and audio.")
        return
    end

    input_slaves_row = string.sub(input_slaves_row, #EXTVLCOPT + 1)
    for url in (input_slaves_row):gmatch("(.-)#") do
        local ext = url:match(".*%.([^%.%?]+)%?")
        -- Not that informative, but that's all what I can get from TorrServer's API for now. :(
        local index = "Index " .. url:match("[?&]index=(%d+)")
        local loading = nil
        loading = mp.command_native_async({
            AUDIO_EXTS[ext] and "audio-add" or "sub-add", url, "auto", index,
        }, function() end)
        table.insert(loadings, loading)
    end
end

local function abort_loadings()
    for index, loading in ipairs(loadings) do
        mp.abort_async_command(loading)
        table.remove(loadings, index)
    end
end

for _, event in ipairs({ "file-loaded", "playlist-pos-changes" }) do
    mp.register_event(event, function()
        abort_loadings()
        load_external_assets()
    end)
end
