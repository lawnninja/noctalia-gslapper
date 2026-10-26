local state, files = {}, {}
local now = 1000000
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
    fileExists = function() return false end,
    fileInfo = function() return { isDir = false } end,
    listDir = function() return {} end,
    outputs = function() return { { name = "DP-1" }, { name = "DP-2" } } end,
    setWallpaper = function() end,
    setWallpaperEnabled = function() end,
    nowMs = function() return now end,
    getenv = function() return "/run/user/1000" end,
    runAsync = function() return true end,
    processMatches = function(callback) callback(false) return true end,
    mkdirAll = function() return true end,
    log = function() end,
    notify = function() end,
    notifyError = function() end,
    json = {
        encode = function(value) return "json:" .. tostring(value.version), nil end,
        decode = function() return nil end,
    },
}
-- Keep slideshow persistence round-trippable through the stub codec.
local saved
noctalia.json.encode = function(value) saved = value return "encoded" end

local service = dofile("gslapper/service.luau")

assert(service.runSelfTest(true).passed, "service self-test failed: " .. tostring(service.runSelfTest(true).error))

local nonce = 0
local function send(action, target, extra)
    nonce = nonce + 1
    local command = { nonce = nonce, action = action, target = target }
    for key, value in pairs(extra or {}) do command[key] = value end
    return service.handleCommand(command)
end

-- No wallpaper yet: a single-output request is rejected, All is silently skipped.
send("set-slideshow", "DP-1", { interval_sec = 300, shuffle = false })
assert(state.command_result.results["DP-1"].ok == false, "unassigned output accepted a slideshow")
send("set-slideshow", "*", { interval_sec = 300, shuffle = false })
assert(next(state.slideshow) == nil, "All outputs created a slideshow for unassigned outputs")

-- Give DP-1 an image, then enable the slideshow on All outputs: only DP-1 qualifies.
assert(send("assign-image", "DP-1", { path = "/w/a.jpg" }))
send("set-slideshow", "*", { interval_sec = 300, shuffle = true })
assert(state.slideshow["DP-1"].interval_sec == 300 and state.slideshow["DP-1"].shuffle == true, "slideshow not stored")
assert(state.slideshow["DP-2"] == nil, "unassigned output received a slideshow")
assert(saved and saved.outputs["DP-1"].interval_sec == 300, "slideshow not persisted")

-- Invalid intervals never reach the handler.
assert(not send("set-slideshow", "DP-1", { interval_sec = 7, shuffle = false }), "invalid interval accepted")
assert(state.slideshow["DP-1"].interval_sec == 300, "invalid command changed state")

-- Restore turns the slideshow off.
assert(send("restore", "DP-1"))
assert(state.slideshow["DP-1"] == nil, "restore left the slideshow on")

-- Off clears.
assert(send("assign-image", "DP-1", { path = "/w/a.jpg" }))
send("set-slideshow", "DP-1", { interval_sec = 60, shuffle = false })
send("set-slideshow", "DP-1", { interval_sec = 0, shuffle = false })
assert(state.slideshow["DP-1"] == nil, "interval 0 did not clear the slideshow")

print("service slideshow test: passed")
