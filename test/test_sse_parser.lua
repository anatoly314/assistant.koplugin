--- Tests for assistant_sse_parser.parseSSE.
---
--- The parser is the line-splitting + classification half of the original
--- inline closure in Querier:processStream. JSON decode and business
--- logic stay in the caller (out of scope for these tests).
---
--- Each test feeds buffer(s) through parseSSE with a recording callback
--- and asserts on the recorded events plus the returned remainder.

local sse = require("assistant_sse_parser")
local parseSSE = sse.parseSSE

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

    -- Build a recording callback. `events` is a list of {type, payload}.
    -- `stop_after_done` makes the callback return false when it sees
    -- `data: [DONE]`, mirroring how Querier:processStream uses the parser.
    local function recorder(stop_after_done)
        local events = {}
        local cb = function(et, payload)
            table.insert(events, { type = et, payload = payload })
            if stop_after_done and et == "data" and payload == "[DONE]" then
                return false
            end
        end
        return events, cb
    end

    -- ---- single event ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data: hello\n\n", cb)
        assert_eq("single.count",   1,        #events)
        assert_eq("single.type",    "data",   events[1] and events[1].type)
        assert_eq("single.payload", "hello",  events[1] and events[1].payload)
        -- Empty trailing line consumed → no remainder
        assert_eq("single.rest",    "",       rest)
    end

    -- ---- multiple events in one chunk ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data: a\n\ndata: b\n\n", cb)
        assert_eq("multi.count",   2,       #events)
        assert_eq("multi.first",   "a",     events[1] and events[1].payload)
        assert_eq("multi.second",  "b",     events[2] and events[2].payload)
        assert_eq("multi.rest",    "",      rest)
    end

    -- ---- event split across chunks ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data: hel", cb)
        -- No newline yet → no events, full buffer returned.
        assert_eq("split.first.count", 0, #events)
        assert_eq("split.first.rest",  "data: hel", rest)

        rest = parseSSE(rest .. "lo\n\n", cb)
        assert_eq("split.second.count",   1,       #events)
        assert_eq("split.second.payload", "hello", events[1] and events[1].payload)
        assert_eq("split.second.rest",    "",      rest)
    end

    -- ---- comment line: emits nothing ----

    do
        local events, cb = recorder()
        local rest = parseSSE(": ping\n\n", cb)
        assert_eq("comment.count", 0,  #events)
        assert_eq("comment.rest",  "", rest)
    end

    -- ---- multi-line data: emitted as separate events ----
    -- (Real SSE spec says concat data lines, but the original splitter
    -- emitted each independently — this test locks that in.)

    do
        local events, cb = recorder()
        local rest = parseSSE("data: line1\ndata: line2\n\n", cb)
        assert_eq("multiline.count",   2,       #events)
        assert_eq("multiline.first",   "line1", events[1] and events[1].payload)
        assert_eq("multiline.second",  "line2", events[2] and events[2].payload)
        assert_eq("multiline.rest",    "",      rest)
    end

    -- ---- [DONE] marker: parser passes it through; caller handles ----

    do
        local events, cb = recorder()  -- caller does NOT short-circuit
        local rest = parseSSE("data: [DONE]\n\n", cb)
        assert_eq("done.count",    1,       #events)
        assert_eq("done.type",     "data",  events[1] and events[1].type)
        assert_eq("done.payload",  "[DONE]", events[1] and events[1].payload)
        assert_eq("done.rest",     "",      rest)
    end

    -- ---- [DONE] marker with caller-side stop ----
    -- Returning false from the callback makes parseSSE stop; trailing
    -- data is preserved in the returned remainder.
    do
        local events, cb = recorder(true)  -- stop_after_done = true
        local rest = parseSSE("data: [DONE]\n\ndata: ignored\n\n", cb)
        assert_eq("done_stop.count",    1, #events)
        assert_eq("done_stop.payload",  "[DONE]",
                  events[1] and events[1].payload)
        -- The `\n` immediately after [DONE]\n was consumed (it produced
        -- the empty line), but `data: ignored\n\n` remains untouched.
        assert_true("done_stop.rest_has_ignored",
                    rest:find("data: ignored", 1, true) ~= nil,
                    "rest=" .. tostring(rest))
    end

    -- ---- Anthropic format: event line + data line ----

    do
        local events, cb = recorder()
        local input = 'event: content_block_delta\n'
                   .. 'data: {"type":"content_block_delta","index":0,'
                   .. '"delta":{"type":"text_delta","text":"Hi"}}\n\n'
        local rest = parseSSE(input, cb)
        -- Expect: event line + data line (whitespace-only trailing line drops)
        assert_eq("anthropic.count", 2, #events)
        assert_eq("anthropic.event_type",   "event", events[1] and events[1].type)
        assert_eq("anthropic.event_payload","content_block_delta",
                  events[1] and events[1].payload)
        assert_eq("anthropic.data_type",    "data",  events[2] and events[2].type)
        -- The JSON in `data:` is forwarded as a raw string — parsing is
        -- the caller's job. Verify a recognizable substring.
        local data_payload = events[2] and events[2].payload or ""
        assert_true("anthropic.data_is_json",
                    data_payload:find('"text":"Hi"', 1, true) ~= nil,
                    "data_payload=" .. tostring(data_payload))
        -- The JSON should have leading/trailing whitespace stripped by
        -- the trim. It starts with `{` and ends with `}`.
        assert_eq("anthropic.data_starts", "{", data_payload:sub(1, 1))
        assert_eq("anthropic.data_ends",   "}", data_payload:sub(-1))
        assert_eq("anthropic.rest",       "", rest)
    end

    -- ---- trailing partial after a complete event ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data: x\n\ndata: par", cb)
        assert_eq("trailing.count",   1,         #events)
        assert_eq("trailing.payload", "x",       events[1] and events[1].payload)
        assert_eq("trailing.rest",    "data: par", rest)
    end

    -- ---- CRLF line endings: behavior with single-char split ----
    -- Splitting on a single \r OR \n means CRLF produces the line plus
    -- an empty line afterwards. Net visible result: same number of
    -- events as plain \n.
    do
        local events, cb = recorder()
        local rest = parseSSE("data: x\r\n\r\n", cb)
        assert_eq("crlf.count",   1,    #events)
        assert_eq("crlf.payload", "x",  events[1] and events[1].payload)
        assert_eq("crlf.rest",    "",   rest)
    end

    -- ---- empty input ----

    do
        local events, cb = recorder()
        local rest = parseSSE("", cb)
        assert_eq("empty.count", 0,  #events)
        assert_eq("empty.rest",  "", rest)
    end

    -- ---- nil input: should not crash ----

    do
        local events, cb = recorder()
        local rest = parseSSE(nil, cb)
        assert_eq("nil_input.count", 0,  #events)
        assert_eq("nil_input.rest",  "", rest)
    end

    -- ---- unknown line: passed through as (nil, line) ----
    -- Lines that don't match data:/event:/: are non-empty get an
    -- event_type=nil callback so the caller (which knows about bare
    -- JSON error frames `{...}`) can handle them.

    do
        local events, cb = recorder()
        local rest = parseSSE('{"error":{"message":"oops"}}\n', cb)
        assert_eq("unknown.count",   1,        #events)
        assert_eq("unknown.type",    nil,      events[1] and events[1].type)
        assert_eq("unknown.payload", '{"error":{"message":"oops"}}',
                  events[1] and events[1].payload)
        assert_eq("unknown.rest",    "",       rest)
    end

    -- ---- whitespace-only line: dropped ----

    do
        local events, cb = recorder()
        -- "   \n\n" → first iter: line="   ", empty after trim → no event.
        -- second iter: line="", drop.
        local rest = parseSSE("   \n\n", cb)
        assert_eq("ws_only.count", 0, #events)
        assert_eq("ws_only.rest",  "", rest)
    end

    -- ---- trim semantics: data payload has leading + trailing ws stripped ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data:    hello world   \n\n", cb)
        assert_eq("trim.count",   1,             #events)
        -- After "data: " (6 chars) prefix, payload = "   hello world   "
        -- trimmed to "hello world".
        assert_eq("trim.payload", "hello world", events[1] and events[1].payload)
        assert_eq("trim.rest",    "",            rest)
    end

    -- ---- "data:" without space: NOT recognized as data line ----

    do
        local events, cb = recorder()
        local rest = parseSSE("data:nospace\n", cb)
        -- The prefix check is `line:sub(1, 6) == "data: "` which requires
        -- the trailing space. Without it, falls into the "unknown" bucket.
        assert_eq("nospace.count",   1,             #events)
        assert_eq("nospace.type",    nil,           events[1] and events[1].type)
        assert_eq("nospace.payload", "data:nospace", events[1] and events[1].payload)
    end

    -- ---- comment-only with arbitrary content after `:` ----

    do
        local events, cb = recorder()
        local rest = parseSSE(":this is a heartbeat\n", cb)
        assert_eq("hb.count", 0,  #events)
        assert_eq("hb.rest",  "", rest)
    end

    -- ---- mixed event types interleaved ----

    do
        local events, cb = recorder()
        local input = ": keepalive\n"
                   .. "event: foo\n"
                   .. "data: {\"a\":1}\n\n"
                   .. ": another keepalive\n"
                   .. "data: {\"b\":2}\n\n"
        local rest = parseSSE(input, cb)
        -- Comments dropped → 4 events: event/data/data
        -- Wait — there are 2 comments + 1 event + 2 data = 3 events
        -- (event + 2 data). Empty trailing lines drop.
        assert_eq("mixed.count", 3, #events)
        assert_eq("mixed.e1.type", "event", events[1] and events[1].type)
        assert_eq("mixed.e1.payload", "foo", events[1] and events[1].payload)
        assert_eq("mixed.e2.type", "data",  events[2] and events[2].type)
        assert_eq("mixed.e2.payload", '{"a":1}', events[2] and events[2].payload)
        assert_eq("mixed.e3.type", "data",  events[3] and events[3].type)
        assert_eq("mixed.e3.payload", '{"b":2}', events[3] and events[3].payload)
        assert_eq("mixed.rest", "", rest)
    end

    -- ---- buffer survival across many chunks ----
    -- Feed one byte at a time; final remainder should match what we'd
    -- get from a single call.

    do
        local input = "data: hello\n\ndata: world\n\n"
        local events, cb = recorder()
        local rest = ""
        for i = 1, #input do
            rest = parseSSE(rest .. input:sub(i, i), cb)
        end
        assert_eq("byte_by_byte.count",   2,        #events)
        assert_eq("byte_by_byte.first",   "hello",  events[1] and events[1].payload)
        assert_eq("byte_by_byte.second",  "world",  events[2] and events[2].payload)
        assert_eq("byte_by_byte.rest",    "",       rest)
    end

    return passed, failed, errs
end

return M
