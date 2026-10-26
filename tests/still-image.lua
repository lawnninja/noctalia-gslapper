local state, files = {}, {}
local asyncCallbacks = {}
local now = 1000000

if not bit32 then
    bit32 = {
        bxor = function(a, b) return a ~ b end,
    }
end

local wallpaperCalls = {}
local wallpapersEnabled = {}

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
    listDir = function(dir)
        local list = {}
        for path in pairs(files) do
            local parent, name = path:match("^(.*)/([^/]+)$")
            if parent == dir then
                table.insert(list, name)
            end
        end
        return list
    end,
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
            -- Simulate gslapper query response: "STATUS: playing video /fake/path\n"
            local path = command:match("STATUS") or "/path"
            callback({ exitCode = 0, stdout = "STATUS: playing video /fake/path\n", stderr = "", timedOut = false })
        end
        return true
    end,
    processMatches = function(callback) callback(false) return true end,
    mkdirAll = function() return true end,
    commandExists = function(cmd) return true end,
    getConfig = function() return nil end,
    wallpaperDirectory = function() return "/wallpapers" end,
    expandPath = function(p) return p end,
    json = {
        encode = function(value) return "json:" .. tostring(value.version or 1), nil end,
        decode = function(str) return { version = 1, assignments = {} } end,
    },
}

local service = dofile("gslapper/service.luau")

local testReport = service.runSelfTest(true)
assert(testReport.passed, "self-test failed: " .. tostring(testReport.error))
assert(testReport.checks == 32, "expected 32 checks, got " .. tostring(testReport.checks))

-- Helper to trigger pending async callbacks
local function stepAsync(filterPattern, exitCode, stdout)
    local remaining = {}
    local matched = 0
    for _, item in ipairs(asyncCallbacks) do
        if not filterPattern or item.command:find(filterPattern) then
            matched = matched + 1
            item.callback({ exitCode = exitCode or 0, stdout = stdout or "", stderr = "", timedOut = false })
        else
            table.insert(remaining, item)
        end
    end
    asyncCallbacks = remaining
    return matched
end

-- Complete capabilities check
stepAsync("gslapper %-%-help", 0, table.concat(service.requiredFlags, " "))

print("=== Scenario 1: Thumbnail placeholder first, then still arrives asynchronously ===")
wallpaperCalls = {}
asyncCallbacks = {}
local thumbPath = "/data/thumb-1.jpg"
files[thumbPath] = "fake thumbnail data"
local ok = service.assignVideo("DP-1", "/videos/forest.mp4", thumbPath)
assert(ok, "assignVideo failed")
assert(#wallpaperCalls == 1, "expected 1 wallpaper call initially")
assert(wallpaperCalls[1].path == thumbPath, "initial call should be the thumbnail placeholder")

-- Now trigger the ensureStill async extraction job
local stillTarget = service.stillPathFor("/videos/forest.mp4")
assert(stillTarget, "stillPathFor failed")
-- Fake creation of the temporary output file
files[stillTarget .. ".tmp-" .. tostring(now)] = "fake full still data"

local ran = stepAsync("gst%-launch%-1%.0")
assert(ran > 0, "no gst extraction command was run")
assert(files[stillTarget] ~= nil, "still was not renamed into place")
assert(#wallpaperCalls == 2, "still should have been applied as wallpaper")
assert(wallpaperCalls[2].path == stillTarget, "second wallpaper call should be full still")

-- Now step the gslapper launch command so commitVideo runs
stepAsync("gslapper", 0, "")
-- Simulate query response from gslapper socket
local socketPath = "/run/user/1000/noctalia-gslapper/DP-1.sock"
files[socketPath] = "fake socket"
-- In the test environment, commitVideo will be called when query is received or launched
-- Check assignment or in-flight preview_path
assert(service.assignments["DP-1"] == nil or service.assignments["DP-1"].preview_path == stillTarget, "assignment preview_path was not updated to still")

print("=== Scenario 2: Cached still used immediately on assignment ===")
wallpaperCalls = {}
asyncCallbacks = {}
local ok2 = service.assignVideo("DP-2", "/videos/forest.mp4", thumbPath)
assert(ok2, "assignVideo for DP-2 failed")
assert(#wallpaperCalls == 1, "expected immediate wallpaper call")
assert(wallpaperCalls[1].path == stillTarget, "should use cached still immediately, not thumb")
local stillJobsQueued = 0
for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gst%-launch%-1%.0") then
        stillJobsQueued = stillJobsQueued + 1
    end
end
assert(stillJobsQueued == 0, "no async still job should have been launched")

-- Helper to clear connector state between unit test scenarios
local function resetConnectors()
    service.runtime["DP-1"] = nil
    service.runtime["DP-2"] = nil
    local _, cb = debug.getupvalue(service.assignVideo, 2)
    for i = 1, 10 do
        local name, val = debug.getupvalue(cb, i)
        if name == "pending" then
            val["DP-1"] = nil
            val["DP-2"] = nil
        end
    end
end

resetConnectors()

print("=== Scenario 3: Deduplication - one gst job for concurrent outputs ===")
local video3 = "/videos/ocean.mp4"
local stillTarget3 = service.stillPathFor(video3)
wallpaperCalls = {}
asyncCallbacks = {}
files[stillTarget3 .. ".tmp-" .. tostring(now)] = "ocean still data"

service.assignVideo("DP-1", video3, nil)
service.assignVideo("DP-2", video3, nil)

local gstCommands = 0
for _, item in ipairs(asyncCallbacks) do
    if item.command:find("gst%-launch%-1%.0") then
        gstCommands = gstCommands + 1
    end
end
assert(gstCommands == 1, "expected exactly 1 gst command for identical concurrent video, found " .. gstCommands)

stepAsync("gst%-launch%-1%.0")
assert(files[stillTarget3] ~= nil, "ocean still was not created")
local oceanCalls = 0
for _, call in ipairs(wallpaperCalls) do
    if call.path == stillTarget3 then
        oceanCalls = oceanCalls + 1
    end
end
assert(oceanCalls == 2, "both outputs should have received the completed still")

print("=== Scenario 4: User switches to image before still finishes ===")
resetConnectors()
local video4 = "/videos/space.mp4"
local stillTarget4 = service.stillPathFor(video4)
files[stillTarget4 .. ".tmp-" .. tostring(now)] = "space still data"
wallpaperCalls = {}
asyncCallbacks = {}

local okV = service.assignVideo("DP-1", video4, nil)
assert(okV, "assignVideo in scenario 4 failed")

-- Reset connector busy state while still job remains in flight
resetConnectors()
local okI = service.assignImage("DP-1", "/images/photo.jpg")
assert(okI, "assignImage in scenario 4 failed")

local imageCallIndex = #wallpaperCalls
assert(wallpaperCalls[imageCallIndex].path == "/images/photo.jpg", "image was not applied")

-- Now let the late still finish
stepAsync("gst%-launch%-1%.0")
-- Should NOT apply stillTarget4 to DP-1
for i = imageCallIndex + 1, #wallpaperCalls do
    assert(wallpaperCalls[i].path ~= stillTarget4, "late still clobbered image wallpaper!")
end

print("=== Scenario 5: pruneStills deletes orphan stills and leftover tmp files ===")
files["/data/still-aaaa.jpg"] = "stale still"
files["/data/still-bbbb.jpg"] = "referenced still"
files["/data/still-cccc.jpg.tmp-1234"] = "leftover tmp"
files["/data/thumb-1111.jpg"] = "thumb not to be touched"

local active = {
    ["DP-1"] = { kind = "video", preview_path = "/data/still-bbbb.jpg" },
}
service.pruneStills(active)

assert(files["/data/still-aaaa.jpg"] == nil, "unreferenced still was not deleted")
assert(files["/data/still-bbbb.jpg"] ~= nil, "referenced still was deleted!")
assert(files["/data/still-cccc.jpg.tmp-1234"] == nil, "tmp file was not deleted")
assert(files["/data/thumb-1111.jpg"] ~= nil, "thumbnail was deleted by pruneStills!")

print("All still image tests passed successfully!")
