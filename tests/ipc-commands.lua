local state, files = {}, {}
local now = 1000000
local asyncCallbacks = {}
local wallpaperCalls = {}
local wallpapersEnabled = {}

if not bit32 then
    bit32 = {
        bxor = function(a, b) return a ~ b end,
    }
end

noctalia = {
    setUpdateInterval = function() end,
    state = {
        get = function(key) return state[key] end,
        set = function(key, value) state[key] = value end,
        watch = function() end,
    },
    pluginDataDir = function() return "/data" end,
    readFile = function(path) return files[path] end,
    writeFile = function(path, contents) files[path] = contents return true end,
    renameFile = function(from, to) files[to] = files[from] files[from] = nil return true end,
    removeFile = function(path) files[path] = nil end,
    fileExists = function(path) return files[path] ~= nil end,
    fileInfo = function(path)
        if files[path] then
            return { isDir = false, size = #files[path], mtime = 12345 }
        end
        return { isDir = false, size = 1000, mtime = 100 }
    end,
    listDir = function(dir) return {} end,
    outputs = function() return { { name = "DP-1" }, { name = "DP-2" } } end,
    setWallpaper = function(connector, path)
        table.insert(wallpaperCalls, { connector = connector, path = path })
    end,
    setWallpaperEnabled = function(connector, enabled)
        wallpapersEnabled[connector] = enabled
    end,
    nowMs = function() return now end,
    getenv = function() return "/run/user/1000" end,
    runAsync = function(command, callback, timeout)
        table.insert(asyncCallbacks, { command = command, callback = callback })
        if command:find("socat") and command:find("query") then
            callback({ exitCode = 0, stdout = "STATUS: playing video /fake/path\n", stderr = "", timedOut = false })
        elseif command:find("socat") and (command:find("pause") or command:find("resume") or command:find("stop")) then
            callback({ exitCode = 0, stdout = "OK\n", stderr = "", timedOut = false })
        end
        return true
    end,
    processMatches = function(callback) callback(false) return true end,
    mkdirAll = function() return true end,
    commandExists = function(cmd) return true end,
    getConfig = function() return nil end,
    wallpaperDirectory = function() return "/wallpapers" end,
    expandPath = function(p) return p end,
    log = function() end,
    notify = function() end,
    notifyError = function() end,
    json = {
        encode = function(value) return "json:" .. tostring(value.version or 1), nil end,
        decode = function(str) return { version = 1, assignments = {} } end,
    },
}

local service = dofile("gslapper/service.luau")
assert(service.runSelfTest(true).passed, "self-test failed")

-- Step startup async tasks (capabilities and find indexing)
local indexData = "f\0" .. "100\0" .. "100\0" .. "/w/1.jpg\0"
    .. "f\0" .. "100\0" .. "100\0" .. "/w/2.jpg\0"
    .. "f\0" .. "100\0" .. "100\0" .. "/w/3.jpg\0"

for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gslapper %-%-help") then
        item.callback({ exitCode = 0, stdout = table.concat(service.requiredFlags, " "), stderr = "", timedOut = false })
    elseif item.command:find("find ") then
        item.callback({ exitCode = 0, stdout = indexData, stderr = "", timedOut = false })
    end
end
asyncCallbacks = {}

print("=== Test 1: onIpc next with image assignments ===")
-- Assign image /w/1.jpg to DP-1
assert(service.assignImage("DP-1", "/w/1.jpg"))
assert(service.assignments["DP-1"].path == "/w/1.jpg")

-- Trigger next on DP-1
service.onIpc("next", "DP-1")
assert(service.assignments["DP-1"].path == "/w/2.jpg", "expected next to advance to /w/2.jpg, got: " .. tostring(service.assignments["DP-1"].path))

-- Trigger next globally (* default)
service.onIpc("next", "")
assert(service.assignments["DP-1"].path == "/w/3.jpg", "expected next to advance to /w/3.jpg, got: " .. tostring(service.assignments["DP-1"].path))

-- Wrap around to /w/1.jpg
service.onIpc("next")
assert(service.assignments["DP-1"].path == "/w/1.jpg", "expected next to wrap around to /w/1.jpg, got: " .. tostring(service.assignments["DP-1"].path))

print("=== Test 2: onIpc stop restores connector ===")
service.onIpc("stop", "DP-1")
assert(service.assignments["DP-1"] == nil, "expected stop to clear DP-1 assignment")
assert(wallpapersEnabled["DP-1"] == true, "expected native wallpaper to be enabled on stop")

-- Assign image on DP-1 and DP-2
assert(service.assignImage("DP-1", "/w/1.jpg"))
assert(service.assignImage("DP-2", "/w/2.jpg"))
assert(service.assignments["DP-1"] ~= nil and service.assignments["DP-2"] ~= nil)

-- Global stop
service.onIpc("stop", "*")
assert(service.assignments["DP-1"] == nil and service.assignments["DP-2"] == nil, "expected stop * to clear all assignments")

print("=== Test 3: onIpc pause and resume ===")
-- Setup a mock video assignment on DP-1
local socketPath = "/run/user/1000/noctalia-gslapper/DP-1.sock"
files[socketPath] = "mock socket"
service.runtime["DP-1"] = { status = "playing", socket_path = socketPath }
service.assignments["DP-1"] = { kind = "video", path = "/w/vid.mp4", desired_playback = "playing" }

service.onIpc("pause", "DP-1")
assert(service.assignments["DP-1"].desired_playback == "paused" or state.command_result.action == "pause", "expected pause action")

service.onIpc("resume", "DP-1")
assert(state.command_result.action == "resume", "expected resume action")

print("=== Test 4: assignVideo launches gslapper only after still extraction completes ===")
-- Reset DP-1
service.runtime["DP-1"] = nil
service.assignments["DP-1"] = nil
files["/run/user/1000/noctalia-gslapper/DP-1.sock"] = nil
wallpaperCalls = {}
asyncCallbacks = {}

local videoPath = "/w/testvid.mp4"
local thumbPath = "/data/thumb-test.jpg"
files[thumbPath] = "thumb content"

local ok = service.assignVideo("DP-1", videoPath, thumbPath)
assert(ok, "assignVideo failed")
-- Check that initial thumbnail was applied
assert(#wallpaperCalls == 1, "expected initial wallpaper call")
assert(wallpaperCalls[1].path == thumbPath, "initial wallpaper should be thumbnail")
-- Verify gslapper was NOT yet launched while extraction is pending
local gslapperLaunched = false
for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gslapper ") then
        gslapperLaunched = true
    end
end
assert(not gslapperLaunched, "gslapper should not launch before still extraction finishes!")

-- Complete still extraction
local stillTarget = service.stillPathFor(videoPath)
files[stillTarget .. ".tmp-" .. tostring(now)] = "high quality still data"
for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gst%-launch%-1%.0") then
        item.callback({ exitCode = 0, stdout = "", stderr = "", timedOut = false })
    end
end

-- Now wallpaperCalls should have received the high-quality still
assert(#wallpaperCalls == 2, "expected second wallpaper call with stillTarget")
assert(wallpaperCalls[2].path == stillTarget, "second wallpaper call should be high-quality still")

-- And gslapper launch command should NOW be queued
gslapperLaunched = false
for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gslapper") then
        gslapperLaunched = true
    end
end
assert(gslapperLaunched, "gslapper should now be launched after still extraction finished!")

print("All IPC command tests passed successfully!")
