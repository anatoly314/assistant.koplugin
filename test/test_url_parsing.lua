--- Tests for parseUrl in api_handlers/base.lua.
---
--- Goal: lock in current behavior so any future change is detectable.
--- These assertions reflect what the production code DOES today, not
--- what some idealized URL parser would do — see SETUP comment in
--- run_tests.lua for the rationale (luasocket's url.parse is permissive).

local BaseHandler = require("api_handlers.base")
local parseUrl = BaseHandler._test.parseUrl

local M = {}

function M.run()
    local passed, failed, errs = 0, 0, {}

    local function check(name, ok, msg)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            table.insert(errs, name .. ": " .. (msg or "no message"))
        end
    end

    local function assert_eq(name, expected, actual)
        check(name, expected == actual,
              string.format("expected %s got %s",
                            tostring(expected), tostring(actual)))
    end

    local function assert_nil(name, v)
        check(name, v == nil, "expected nil, got " .. tostring(v))
    end

    -- ---- happy paths ----

    do
        local p = parseUrl("https://api.anthropic.com/v1/messages")
        assert_eq("anthropic.scheme", "https", p.scheme)
        assert_eq("anthropic.host",   "api.anthropic.com", p.host)
        assert_eq("anthropic.port",   443, p.port)
        assert_eq("anthropic.path",   "/v1/messages", p.path)
    end

    do
        local p = parseUrl("http://example.com:8080/foo?bar=baz")
        assert_eq("http_with_port.scheme", "http", p.scheme)
        assert_eq("http_with_port.host",   "example.com", p.host)
        assert_eq("http_with_port.port",   8080, p.port)
        -- parseUrl appends ?query to path verbatim
        assert_eq("http_with_port.path",   "/foo?bar=baz", p.path)
    end

    -- bare host: no path, no port → defaults
    do
        local p = parseUrl("https://example.com")
        assert_eq("bare_host.scheme", "https", p.scheme)
        assert_eq("bare_host.host",   "example.com", p.host)
        assert_eq("bare_host.port",   443, p.port)
        assert_eq("bare_host.path",   "/", p.path)
    end

    -- trailing slash: path = "/"
    do
        local p = parseUrl("https://example.com/")
        assert_eq("trailing_slash.path", "/", p.path)
    end

    -- explicit default port → still 443
    do
        local p = parseUrl("https://example.com:443/foo")
        assert_eq("explicit_default_port.port", 443, p.port)
        assert_eq("explicit_default_port.path", "/foo", p.path)
    end

    -- empty port (`https://example.com:`): luasocket parses port="";
    -- tonumber("") is nil so parseUrl falls back to the scheme default.
    do
        local p = parseUrl("https://example.com:")
        check("empty_port.parsed_ok", p ~= nil, "parsed nil for empty port")
        if p then
            assert_eq("empty_port.scheme", "https", p.scheme)
            assert_eq("empty_port.host",   "example.com", p.host)
            assert_eq("empty_port.port",   443, p.port)  -- fell back to default
        end
    end

    -- non-http scheme: parseUrl doesn't reject; it just returns whatever
    -- luasocket gave plus the https/http port-fallback rule. ftp gets the
    -- "neither http nor https" branch → 443.
    do
        local p = parseUrl("ftp://example.com/x")
        check("ftp.parsed_ok", p ~= nil, "parsed nil for ftp")
        if p then
            assert_eq("ftp.scheme", "ftp",         p.scheme)
            assert_eq("ftp.host",   "example.com", p.host)
            assert_eq("ftp.port",   443,           p.port)  -- not http -> 443
            assert_eq("ftp.path",   "/x",          p.path)
        end
    end

    -- query with empty value
    do
        local p = parseUrl("https://example.com/path?")
        check("empty_query.parsed_ok", p ~= nil, "parsed nil")
        if p then
            -- luasocket sets query="" when the ? is present with nothing after.
            -- parseUrl skips appending if query=="" (`parsed.query ~= ""` guard).
            assert_eq("empty_query.path", "/path", p.path)
        end
    end

    -- multi-segment query
    do
        local p = parseUrl("https://example.com/a/b/c?x=1&y=2")
        assert_eq("multi_query.path", "/a/b/c?x=1&y=2", p.path)
    end

    -- ---- error paths ----

    -- bare token, no scheme, no `//authority` — luasocket leaves host
    -- unset, parseUrl returns nil + "invalid URL".
    do
        local p, err = parseUrl("not-a-url")
        assert_nil("not_a_url.p", p)
        assert_eq("not_a_url.err", "invalid URL", err)
    end

    -- nil input
    do
        local p, err = parseUrl(nil)
        assert_nil("nil_input.p", p)
        assert_eq("nil_input.err", "invalid URL", err)
    end

    -- empty string input
    do
        local p, err = parseUrl("")
        assert_nil("empty_input.p", p)
        assert_eq("empty_input.err", "invalid URL", err)
    end

    return passed, failed, errs
end

return M
