--- Pure SSE line parser.
---
--- Splits a streaming buffer into Server-Sent-Events lines and classifies
--- each one. No JSON decoding, no business logic — just line splitting +
--- prefix matching, exactly mirroring the splitter that previously lived
--- inline in `Querier:processStream` (assistant_querier.lua).
---
--- Behavioral contract (preserved verbatim from the original closure):
---  * Lines are split on a SINGLE `\r` or `\n` character. CRLF therefore
---    yields the line plus an empty line afterward; LF on its own yields
---    just the line. (This matches the original `partial_data:find("[\r\n]")`
---    behavior exactly — including the quirk that a bare `\r` mid-stream
---    closes the line.)
---  * Lines starting with "data: " (six chars including the space) emit
---    ("data", trimmed_payload) where trimmed_payload has leading and
---    trailing whitespace removed (the original used koutil.trim).
---  * Lines starting with "event: " (seven chars) emit ("event", payload)
---    with payload UNTRIMMED (the original consumed-but-ignored these;
---    we emit them so callers can see them).
---  * Lines starting with ":" emit nothing (SSE comment / heartbeat).
---  * Empty lines (zero length, or only whitespace) emit nothing.
---  * Anything else emits (nil, line) — the raw line — so the caller can
---    decide what to do (e.g. try JSON-decoding bare `{...}` error frames).
---
--- The parser does NOT interpret `[DONE]` itself. If the caller wants to
--- short-circuit on [DONE] (or any other event), the delta_callback may
--- return the literal `false` — parseSSE will then stop processing and
--- return the remaining unconsumed buffer (including the line that
--- triggered the stop's not-yet-consumed siblings, if any). Returning
--- nil or any other value continues parsing as normal.
---
--- @param buffer string  accumulated bytes (possibly with a partial trailing line)
--- @param delta_callback function  called as delta_callback(event_type, payload)
---                                  for each complete line.
---                                  event_type is "data", "event", or nil.
---                                  Return `false` to stop parsing.
--- @return string  the remaining unconsumed buffer (the trailing partial line, if any)
local function parseSSE(buffer, delta_callback)
    if not buffer then return "" end
    while true do
        local line_end = buffer:find("[\r\n]")
        if not line_end then break end
        local line = buffer:sub(1, line_end - 1)
        buffer = buffer:sub(line_end + 1)

        local r
        if line:sub(1, 6) == "data: " then
            local payload = line:sub(7)
            -- Trim, mirroring koutil.trim semantics:
            -- "  hi  " -> "hi", "   " -> "".
            local from = payload:match("^%s*()")
            payload = (from > #payload) and "" or payload:match(".*%S", from)
            r = delta_callback("data", payload)
        elseif line:sub(1, 7) == "event: " then
            r = delta_callback("event", line:sub(8))
        elseif line:sub(1, 1) == ":" then
            -- SSE comment / heartbeat — drop silently.
        else
            -- Empty or whitespace-only lines drop; non-empty unknown lines
            -- get passed through with event_type=nil. Mirrors the original
            -- `if #koutil.trim(line) > 0` guard.
            local from = line:match("^%s*()")
            local trimmed = (from > #line) and "" or line:match(".*%S", from)
            if trimmed and #trimmed > 0 then
                r = delta_callback(nil, line)
            end
        end

        if r == false then break end
    end
    return buffer
end

return {
    parseSSE = parseSSE,
}
