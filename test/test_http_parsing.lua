--- Tests for parseStatusLine, parseChunkSize, buildRequest in
--- api_handlers/base.lua. Lock in current behavior; spot the regression
--- before the user does.

local BaseHandler = require("api_handlers.base")
local parseStatusLine = BaseHandler._test.parseStatusLine
local parseChunkSize  = BaseHandler._test.parseChunkSize
local buildRequest    = BaseHandler._test.buildRequest

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

    local function assert_true(name, v, msg)
        check(name, v and true or false, msg or ("got " .. tostring(v)))
    end

    local function assert_nil(name, v)
        check(name, v == nil, "expected nil, got " .. tostring(v))
    end

    local function contains(haystack, needle)
        return haystack:find(needle, 1, true) ~= nil
    end

    -- ===================================================================
    -- parseStatusLine
    -- ===================================================================

    do
        local code, reason = parseStatusLine("HTTP/1.1 200 OK")
        assert_eq("status.200_OK.code",   200,  code)
        assert_eq("status.200_OK.reason", "OK", reason)
    end

    do
        local code, reason = parseStatusLine("HTTP/1.0 404 Not Found")
        assert_eq("status.404.code",   404,         code)
        assert_eq("status.404.reason", "Not Found", reason)
    end

    -- No reason phrase → empty string (the `(.*)` capture matches "")
    do
        local code, reason = parseStatusLine("HTTP/1.1 200")
        assert_eq("status.no_reason.code",   200, code)
        assert_eq("status.no_reason.reason", "",  reason)
    end

    -- Multi-word reason
    do
        local code, reason = parseStatusLine("HTTP/1.1 503 Service Temporarily Unavailable")
        assert_eq("status.503.code",   503,                                code)
        assert_eq("status.503.reason", "Service Temporarily Unavailable", reason)
    end

    -- HTTP/2 status line: regex requires `%d%.%d`, so HTTP/2 (no dot)
    -- DOES NOT MATCH. parseStatusLine returns nil + error string.
    do
        local code, err = parseStatusLine("HTTP/2 200")
        assert_nil("status.http2.code", code)
        assert_true("status.http2.err_starts",
                    type(err) == "string" and err:sub(1, 4) == "bad ",
                    "err=" .. tostring(err))
    end

    -- Total garbage
    do
        local code, err = parseStatusLine("garbage")
        assert_nil("status.garbage.code", code)
        assert_true("status.garbage.err_string", type(err) == "string")
    end

    -- Empty string
    do
        local code, err = parseStatusLine("")
        assert_nil("status.empty.code", code)
        assert_true("status.empty.err_string", type(err) == "string")
    end

    -- Nil
    do
        local code, err = parseStatusLine(nil)
        assert_nil("status.nil.code", code)
        assert_true("status.nil.err_is_string", type(err) == "string")
    end

    -- ===================================================================
    -- parseChunkSize
    -- ===================================================================

    assert_eq("chunk.lower_hex",  31,         parseChunkSize("1f"))
    assert_eq("chunk.upper_hex",  31,         parseChunkSize("1F"))
    assert_eq("chunk.zero",       0,          parseChunkSize("0"))
    assert_eq("chunk.with_ext",   256,        parseChunkSize("100;chunk-ext=foo"))
    assert_eq("chunk.deadbeef",   3735928559, parseChunkSize("deadbeef"))
    assert_nil("chunk.empty",                 parseChunkSize(""))
    assert_nil("chunk.non_hex",               parseChunkSize("xyz"))
    -- Whitespace-prefixed: regex anchors at ^, demands hex. " 1f" → nil.
    assert_nil("chunk.leading_ws",            parseChunkSize("   1f"))
    -- Trailing whitespace: hex prefix matches, trailing ignored.
    assert_eq("chunk.trailing_ws", 31,        parseChunkSize("1f   "))
    -- Nil input: parseChunkSize returns nil immediately.
    assert_nil("chunk.nil",                   parseChunkSize(nil))

    -- ===================================================================
    -- buildRequest
    -- ===================================================================

    -- POST with body and an additional header.
    do
        local req = buildRequest(
            { scheme = "https", host = "api.anthropic.com",
              port = 443, path = "/v1/messages" },
            "POST",
            { ["Content-Type"] = "application/json" },
            '{"hello":1}'
        )
        assert_true("post.request_line",
            contains(req, "POST /v1/messages HTTP/1.1\r\n"))
        assert_true("post.host_header",
            contains(req, "Host: api.anthropic.com\r\n"))
        assert_true("post.user_agent",
            contains(req, "User-Agent: KOReader-assistant.koplugin\r\n"))
        assert_true("post.accept_encoding",
            contains(req, "Accept-Encoding: identity\r\n"))
        assert_true("post.connection_close",
            contains(req, "Connection: close\r\n"))
        assert_true("post.content_length",
            contains(req, "Content-Length: 11\r\n"))
        assert_true("post.content_type",
            contains(req, "Content-Type: application/json\r\n"))
        -- Body is appended after a blank line.
        assert_true("post.body_separator",
            contains(req, "\r\n\r\n" .. '{"hello":1}'))
    end

    -- GET with no body. Production code STILL emits Content-Length: 0
    -- (it does `#(body or "")`), so lock that quirk in.
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "GET", nil, nil
        )
        assert_true("get.request_line",
            contains(req, "GET / HTTP/1.1\r\n"))
        assert_true("get.content_length_zero",
            contains(req, "Content-Length: 0\r\n"))
    end

    -- Path with query string is sent verbatim — NOT URL-encoded.
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443,
              path = "/foo?bar=baz&qux=1+2" },
            "GET", nil, nil
        )
        assert_true("query.verbatim",
            contains(req, "GET /foo?bar=baz&qux=1+2 HTTP/1.1\r\n"))
    end

    -- Custom User-Agent in caller headers: production code does NOT
    -- skip User-Agent in its lower-case dedupe list, so BOTH the
    -- default and the custom UA end up in the request. Lock that in.
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "POST", { ["User-Agent"] = "test-client/1.0" }, ""
        )
        assert_true("ua.default_kept",
            contains(req, "User-Agent: KOReader-assistant.koplugin\r\n"))
        assert_true("ua.caller_added",
            contains(req, "User-Agent: test-client/1.0\r\n"))
    end

    -- Caller tries to override Host: production code SKIPS the caller's
    -- Host (case-insensitive) and uses its own. Lock in.
    do
        local req = buildRequest(
            { scheme = "https", host = "real.example", port = 443, path = "/" },
            "POST", { ["host"] = "evil.example" }, ""
        )
        assert_true("host.real_used",
            contains(req, "Host: real.example\r\n"))
        assert_true("host.evil_skipped",
            not contains(req, "Host: evil.example\r\n"))
    end

    -- Caller tries to override Content-Length / Connection / Accept-Encoding:
    -- all skipped (case-insensitively). Locks in the dedupe list.
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "POST",
            {
                ["Content-Length"]  = "99999",
                ["connection"]      = "keep-alive",
                ["Accept-Encoding"] = "gzip",
            },
            "abc"
        )
        assert_true("dedupe.content_length_correct",
            contains(req, "Content-Length: 3\r\n"))
        assert_true("dedupe.no_caller_cl",
            not contains(req, "Content-Length: 99999"))
        assert_true("dedupe.connection_close",
            contains(req, "Connection: close\r\n"))
        assert_true("dedupe.no_keep_alive",
            not contains(req, "keep-alive"))
        assert_true("dedupe.accept_identity",
            contains(req, "Accept-Encoding: identity\r\n"))
        assert_true("dedupe.no_gzip",
            not contains(req, "Accept-Encoding: gzip"))
    end

    -- Non-default port → Host header includes :port
    do
        local req = buildRequest(
            { scheme = "http", host = "internal.svc", port = 8080, path = "/" },
            "POST", nil, ""
        )
        assert_true("port.in_host",
            contains(req, "Host: internal.svc:8080\r\n"))
    end

    -- HTTPS on default 443 → port NOT in Host
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "POST", nil, ""
        )
        assert_true("port.https_default_no_port",
            contains(req, "Host: x.example\r\n"))
        assert_true("port.https_default_no_443",
            not contains(req, "Host: x.example:443"))
    end

    -- HTTP on default 80 → port NOT in Host
    do
        local req = buildRequest(
            { scheme = "http", host = "x.example", port = 80, path = "/" },
            "POST", nil, ""
        )
        assert_true("port.http_default_no_port",
            contains(req, "Host: x.example\r\n"))
        assert_true("port.http_default_no_80",
            not contains(req, "Host: x.example:80"))
    end

    -- Body with newlines and special characters: passed through unchanged.
    do
        local body = "line1\nline2\r\n{\"k\":\"v with \\\" quote\"}\n"
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "POST", nil, body
        )
        assert_true("body.unchanged",
            contains(req, "\r\n\r\n" .. body))
        assert_true("body.content_length",
            contains(req, "Content-Length: " .. tostring(#body) .. "\r\n"))
    end

    -- Empty body string is treated identically to nil for length purposes.
    do
        local req = buildRequest(
            { scheme = "https", host = "x.example", port = 443, path = "/" },
            "POST", nil, ""
        )
        assert_true("empty_body.cl_zero",
            contains(req, "Content-Length: 0\r\n"))
    end

    return passed, failed, errs
end

return M
