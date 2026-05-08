--- Plain-Lua test runner for assistant.koplugin parsers.
---
--- Run from the test/ directory:
---     lua run_tests.lua
---
--- No external dependencies (no busted, no LuaUnit). Every helper used
--- by a test lives either in this file or in the test module itself.
---
--- Module loading strategy:
---  * Plugin root (parent dir) is added to package.path so requires
---    like `api_handlers.base` and `assistant_sse_parser` resolve.
---  * KOReader-runtime-only modules (logger, ui/uimanager, ssl, socket)
---    are pre-stubbed in package.loaded so api_handlers/base.lua can
---    load under plain Lua. The pure parsers we test never call any
---    method on these stubs at parse time, so empty-table stubs suffice.
---  * socket.url is given a real implementation (verbatim copy of
---    luasocket's url.parse) since parseUrl actively uses it.

-- Resolve the test directory regardless of where lua was invoked from.
-- Lua sets arg[0] to the script path; if for some reason that's missing,
-- fall back to the cwd.
local function script_dir()
    local s = arg and arg[0]
    if not s then return "." end
    local d = s:match("^(.*)/[^/]+$")
    return d or "."
end
local TEST_DIR = script_dir()
local PLUGIN_ROOT = TEST_DIR .. "/.."

-- Add plugin root + test dir to package.path so tests can require
-- production modules and sibling test modules.
package.path = table.concat({
    PLUGIN_ROOT .. "/?.lua",
    PLUGIN_ROOT .. "/?/init.lua",
    TEST_DIR .. "/?.lua",
    TEST_DIR .. "/?/init.lua",
    package.path,
}, ";")

-- ---------------------------------------------------------------------
-- Stubs for KOReader-runtime modules that api_handlers/base.lua requires
-- at load time. The pure parsers we test never invoke any method on
-- these, so trivial stubs suffice. If a stub field IS invoked during a
-- test, we want a loud error, not a silent no-op — hence functions over
-- nil values where there's any risk of accidental use.

local function noop() end
local function noop_returning_self(self) return self end

package.loaded["logger"] = {
    warn = noop, info = noop, dbg = noop, err = noop, error = noop,
}

-- socket: only socket.tcp is referenced by base.lua, and only inside
-- functions that the tests don't exercise. Stub as table with a tcp()
-- that returns a table (so any accidental use surfaces as a method
-- call on a plain table rather than nil indexing).
package.loaded["socket"] = setmetatable({
    tcp = function() return {} end,
}, { __index = function(_, k)
    error("socket." .. tostring(k) .. " accessed during a parser test — "
          .. "tests should not touch real sockets", 2)
end })

-- socket.url: real implementation needed by parseUrl. Use the verbatim
-- luasocket copy in test/stubs/socket_url.lua.
package.loaded["socket.url"] = require("stubs.socket_url")

-- ssl: only used by connectAndUpgrade, never by pure parsers.
package.loaded["ssl"] = setmetatable({}, { __index = function(_, k)
    error("ssl." .. tostring(k) .. " accessed during a parser test", 2)
end })

-- UIManager: only used by yieldOrCancel, never by pure parsers.
package.loaded["ui/uimanager"] = setmetatable({}, { __index = function(_, k)
    error("UIManager." .. tostring(k) .. " accessed during a parser test", 2)
end })

-- ---------------------------------------------------------------------
-- Run all suites and aggregate results.

local suites = {
    { name = "url_parsing",  mod = require("test_url_parsing") },
    { name = "http_parsing", mod = require("test_http_parsing") },
    { name = "sse_parser",   mod = require("test_sse_parser") },
}

local total_passed, total_failed = 0, 0
local all_failures = {}

for _, suite in ipairs(suites) do
    io.write(string.format("=== %s ===\n", suite.name))
    local passed, failed, errs = suite.mod.run()
    io.write(string.format("  %d passed, %d failed\n", passed, failed))
    total_passed = total_passed + passed
    total_failed = total_failed + failed
    for _, e in ipairs(errs or {}) do
        table.insert(all_failures, suite.name .. " :: " .. e)
    end
end

io.write(string.format("\n%d passed, %d failed\n", total_passed, total_failed))
for _, f in ipairs(all_failures) do
    io.write("  FAIL: " .. f .. "\n")
end

os.exit(total_failed == 0 and 0 or 1)
