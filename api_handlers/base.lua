local logger = require("logger")
local socket = require("socket")
local socket_url = require("socket.url")
local ssl = require("ssl")
local UIManager = require("ui/uimanager")

local BaseHandler = {
    trap_widget = nil,  -- widget to trap the request
}

BaseHandler.CODE_CANCELLED = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR = "NETWORK_ERROR"
BaseHandler.CODE_TIMEOUT = "TIMEOUT"
BaseHandler.PROTOCOL_NON_200 = "X-NON-200-STATUS:"

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function BaseHandler:resetTrapWidget()
    self.trap_widget = nil
end

--- Query method to be implemented by specific handlers
function BaseHandler:query(message_history, provider_setting)
    error("query method must be implemented")
end

-- Defaults align with KOReader's existing TLS posture (luasec).
-- verify="none" matches the previous `https.cert_verify = false` policy in this file.
local DEFAULT_TLS_PARAMS = {
    mode = "client",
    protocol = "any",
    verify = "none",
    options = { "all", "no_sslv2", "no_sslv3" },
}

-- One scheduling cycle while waiting for socket I/O readiness.
-- 60ms is a balance: short enough to feel responsive on slow networks,
-- long enough to avoid spinning the UIManager scheduler.
local IO_POLL_INTERVAL_SEC = 0.06

-- Small chunk size: SSE events from Anthropic/OpenAI are typically
-- < 1KB each, so reading 4KB at a time keeps latency low without
-- excessive read() syscall pressure.
local READ_CHUNK_SIZE = 4096

--- Yield control back to UIManager and resume after `interval` seconds,
--- OR return early (with a falsy value) if dismiss_check() returns true.
--- This is the heart of cooperative non-blocking I/O — when the socket
--- isn't ready, we hand the CPU back to the UI so the user can still
--- interact (and crucially, hit the Stop button).
--- Returns true if we should continue, false if cancelled.
local function yieldOrCancel(co, interval, dismiss_check)
    if dismiss_check and dismiss_check() then
        return false
    end
    local go_on_func = function()
        if coroutine.status(co) == "suspended" then
            coroutine.resume(co, true)
        end
    end
    UIManager:scheduleIn(interval, go_on_func)
    local go_on = coroutine.yield()
    if not go_on then
        UIManager:unschedule(go_on_func)
        return false
    end
    -- Re-check dismiss after wake; the user may have hit Stop while we slept.
    if dismiss_check and dismiss_check() then
        return false
    end
    return true
end

--- Parse a URL into host/port/path. Defaults port to 443 for https, 80 for http.
local function parseUrl(url)
    local parsed = socket_url.parse(url)
    if not parsed or not parsed.host then return nil, "invalid URL" end
    local scheme = (parsed.scheme or "https"):lower()
    local port = tonumber(parsed.port) or (scheme == "http" and 80 or 443)
    local path = parsed.path or "/"
    if parsed.query and parsed.query ~= "" then path = path .. "?" .. parsed.query end
    return {
        scheme = scheme,
        host = parsed.host,
        port = port,
        path = path,
    }
end

--- Read one CRLF-terminated line from `sock`, yielding when no data is ready.
--- Buffers leftover bytes back into a closure-shared buffer so subsequent
--- reads (line or body) see them.
--- Returns line, err. On err == "closed" with no line, returns nil, "closed".
local function makeLineReader(sock, co, dismiss_check, deadline_check)
    local buf = ""
    local closed = false

    local function read_more()
        local data, err, partial = sock:receive(READ_CHUNK_SIZE)
        if data then
            buf = buf .. data
            return true
        end
        -- partial may carry bytes received before would-block — never drop them.
        if partial and #partial > 0 then
            buf = buf .. partial
        end
        if err == "wantread" or err == "wantwrite" or err == "timeout" then
            if deadline_check and deadline_check() then
                return nil, "timeout"
            end
            local cont = yieldOrCancel(co, IO_POLL_INTERVAL_SEC, dismiss_check)
            if not cont then return nil, "cancelled" end
            return true
        elseif err == "closed" then
            closed = true
            return true  -- signal end-of-stream; caller decides what to do with buf
        else
            return nil, err or "unknown"
        end
    end

    local read_line = function()
        while true do
            local s, e = buf:find("\r?\n", 1)
            if s then
                local line = buf:sub(1, s - 1)
                buf = buf:sub(e + 1)
                return line
            end
            if closed then
                if #buf > 0 then
                    local line = buf
                    buf = ""
                    return line
                end
                return nil, "closed"
            end
            local ok, err = read_more()
            if not ok then return nil, err end
        end
    end

    -- Expose the internal buffer so the body reader can pick up
    -- bytes that were over-read during header parsing.
    local function take_buffer()
        local ret = buf
        buf = ""
        return ret
    end

    local function is_closed()
        return closed
    end

    return read_line, take_buffer, is_closed
end

--- Send all bytes through `sock`, retrying on partial sends.
--- Sends are short (request headers + a JSON body) so we use bounded
--- yielding. Returns true on success, nil + err on failure.
local function sendAll(sock, data, co, dismiss_check, deadline_check)
    local total = #data
    local sent = 0
    while sent < total do
        local n, err, last = sock:send(data, sent + 1, total)
        if n then
            sent = n
        else
            if last then sent = last end
            if err == "wantread" or err == "wantwrite" or err == "timeout" then
                if deadline_check and deadline_check() then
                    return nil, "timeout"
                end
                local cont = yieldOrCancel(co, IO_POLL_INTERVAL_SEC, dismiss_check)
                if not cont then return nil, "cancelled" end
            elseif err == "closed" then
                return nil, "closed"
            else
                return nil, err or "send failed"
            end
        end
    end
    return true
end

--- Best-effort socket close. Closing a non-blocking SSL socket may itself
--- yield in odd cases; pcall keeps that from leaking out.
local function safeClose(sock)
    if not sock then return end
    pcall(function() sock:close() end)
end

--- Run the TLS handshake, yielding on wantread/wantwrite.
local function tlsHandshake(sock, co, dismiss_check, deadline_check)
    while true do
        local ok, err = sock:dohandshake()
        if ok then return true end
        if err == "wantread" or err == "wantwrite" or err == "timeout" then
            if deadline_check and deadline_check() then
                return nil, "timeout"
            end
            local cont = yieldOrCancel(co, IO_POLL_INTERVAL_SEC, dismiss_check)
            if not cont then return nil, "cancelled" end
        else
            return nil, "tls handshake: " .. tostring(err)
        end
    end
end

--- Build the HTTP/1.1 request bytes. We always send Connection: close
--- because we're not pooling and don't want keep-alive ambiguity.
local function buildRequest(parts, method, headers, body)
    local default_port = (parts.scheme == "https") and 443 or 80
    local host_header = parts.host
    if parts.port ~= default_port then
        host_header = host_header .. ":" .. tostring(parts.port)
    end
    local lines = {
        method .. " " .. parts.path .. " HTTP/1.1",
        "Host: " .. host_header,
        "User-Agent: KOReader-assistant.koplugin",
        "Accept-Encoding: identity",
        "Connection: close",
        "Content-Length: " .. tostring(#(body or "")),
    }
    if headers then
        for k, v in pairs(headers) do
            -- Skip headers we always set ourselves to avoid duplicates.
            local lk = k:lower()
            if lk ~= "host" and lk ~= "connection"
               and lk ~= "content-length" and lk ~= "accept-encoding" then
                table.insert(lines, k .. ": " .. tostring(v))
            end
        end
    end
    table.insert(lines, "")
    table.insert(lines, body or "")
    return table.concat(lines, "\r\n")
end

--- Parse status line "HTTP/1.1 200 OK" -> code, reason.
local function parseStatusLine(line)
    if not line then return nil, "empty status line" end
    local code, reason = line:match("^HTTP/%d%.%d%s+(%d+)%s*(.*)$")
    if not code then return nil, "bad status line: " .. tostring(line) end
    return tonumber(code), reason or ""
end

--- Parse one chunk-size line of HTTP/1.1 chunked transfer encoding.
--- Hex digits, optionally followed by ";extension". Returns size or nil.
local function parseChunkSize(line)
    if not line then return nil end
    local hex = line:match("^([0-9A-Fa-f]+)")
    if not hex then return nil end
    return tonumber(hex, 16)
end

--- Pull exactly N bytes from the wire, draining `pre_buffer` first.
--- Returns the bytes string, or nil + err.
local function readExactly(sock, n, pre_buffer, co, dismiss_check, deadline_check)
    local out = { pre_buffer or "" }
    local got = #(pre_buffer or "")
    while got < n do
        local want = n - got
        local data, err, partial = sock:receive(math.min(want, READ_CHUNK_SIZE))
        if data then
            table.insert(out, data)
            got = got + #data
        else
            if partial and #partial > 0 then
                table.insert(out, partial)
                got = got + #partial
            end
            if err == "wantread" or err == "wantwrite" or err == "timeout" then
                if deadline_check and deadline_check() then
                    return nil, "timeout", table.concat(out)
                end
                local cont = yieldOrCancel(co, IO_POLL_INTERVAL_SEC, dismiss_check)
                if not cont then return nil, "cancelled", table.concat(out) end
            elseif err == "closed" then
                return table.concat(out), "closed"
            else
                return nil, err or "read failed", table.concat(out)
            end
        end
    end
    return table.concat(out)
end

--- Translate a low-level I/O failure reason — as returned by the
--- helpers in this file (sendAll, tlsHandshake, makeLineReader,
--- readExactly) — into a (code, msg) pair for the public return tuple.
--- The two sentinels "cancelled" and "timeout" map to their dedicated
--- codes; anything else is a NETWORK_ERROR. `prefix` is mixed in so the
--- final message preserves the same wording as the pre-refactor code
--- ("send timeout", "headers: foo", "chunk read timeout", ...).
local function ioFailure(reason, prefix)
    if reason == "cancelled" then
        return BaseHandler.CODE_CANCELLED, "user cancelled"
    elseif reason == "timeout" then
        return BaseHandler.CODE_TIMEOUT, prefix .. " timeout"
    end
    return BaseHandler.CODE_NETWORK_ERROR, prefix .. ": " .. tostring(reason)
end

--- Open a TCP socket, connect, and (for https) wrap with TLS and run
--- the handshake non-blocking. On success returns the connected socket
--- (settimeout(0) already applied) ready for HTTP I/O. On failure
--- returns nil + (code, msg) for direct propagation.
--- This helper closes its socket on every failure path; caller only
--- owns close() responsibility for the returned socket.
local function connectAndUpgrade(parts, co, connect_timeout, dismiss_check, deadline_check)
    local sock = socket.tcp()
    if not sock then
        return nil, BaseHandler.CODE_NETWORK_ERROR, "socket.tcp() failed"
    end

    -- Use a short blocking timeout for connect/DNS; once connected we
    -- switch to non-blocking. (gethostbyname is invoked inside :connect
    -- and remains blocking — that's a luasocket limitation.)
    -- Caller-overridable via the public `timeout` arg in makeRequest;
    -- defaults to 15 to preserve prior behavior.
    sock:settimeout(connect_timeout or 15)
    local ok, cerr = sock:connect(parts.host, parts.port)
    if not ok then
        safeClose(sock)
        return nil, BaseHandler.CODE_NETWORK_ERROR, "connect: " .. tostring(cerr)
    end

    if parts.scheme ~= "https" then
        sock:settimeout(0)
        return sock
    end

    -- Wrap with TLS, then settimeout(0) for cooperative non-blocking.
    local params = {}
    for k, v in pairs(DEFAULT_TLS_PARAMS) do params[k] = v end
    local tls_sock, werr = ssl.wrap(sock, params)
    if not tls_sock then
        safeClose(sock)
        return nil, BaseHandler.CODE_NETWORK_ERROR, "ssl.wrap: " .. tostring(werr)
    end
    -- From here on the original raw `sock` is owned by the SSL wrapper;
    -- closing tls_sock closes the underlying TCP socket.
    sock = tls_sock
    if sock.sni then
        local sni_ok, sni_err = pcall(function() sock:sni(parts.host) end)
        if not sni_ok then
            logger.warn("SNI failed for", parts.host, ":", sni_err)
        end
    end
    sock:settimeout(0)

    local hs_ok, hs_err = tlsHandshake(sock, co, dismiss_check, deadline_check)
    if not hs_ok then
        safeClose(sock)
        -- tlsHandshake already builds the "tls handshake: ..." prefix on
        -- its non-sentinel errors, so we route through ioFailure with a
        -- "tls handshake" prefix only for the cancel/timeout sentinels.
        local code, msg = ioFailure(hs_err, "tls handshake")
        return nil, code, msg
    end
    return sock
end

--- Build the HTTP/1.1 request bytes and send them cooperatively.
--- Returns true on success, or nil + (code, msg) on failure.
local function sendRequest(sock, parts, method, headers, body, co, dismiss_check, deadline_check)
    local req_bytes = buildRequest(parts, (method or "POST"):upper(), headers, body)
    local ok, err = sendAll(sock, req_bytes, co, dismiss_check, deadline_check)
    if not ok then
        local code, msg = ioFailure(err, "send")
        return nil, code, msg
    end
    return true
end

--- Read the HTTP status line and header block. Returns:
---   status_code (number), status_reason (string),
---   response_headers (table, lowercased keys),
---   read_line (function),
---   take_buffer (function — flushes any over-read body bytes from
---     the line reader so the body reader can pick them up),
---   is_closed (function — true once the stream signaled EOF), or
--- nil + (code, msg) on failure.
local function readResponseHeaders(sock, co, dismiss_check, deadline_check)
    local read_line, take_buffer, is_closed = makeLineReader(
        sock, co, dismiss_check, deadline_check)

    local status_line, lerr = read_line()
    if not status_line then
        -- read_line distinguishes cancel/timeout via ioFailure sentinels;
        -- all other errors get the "no status:" prefix.
        if lerr == "cancelled" then
            return nil, BaseHandler.CODE_CANCELLED, "user cancelled"
        elseif lerr == "timeout" then
            return nil, BaseHandler.CODE_TIMEOUT, "read status timeout"
        end
        return nil, BaseHandler.CODE_NETWORK_ERROR, "no status: " .. tostring(lerr)
    end
    local code, reason = parseStatusLine(status_line)
    if not code then
        return nil, BaseHandler.CODE_NETWORK_ERROR, reason
    end

    local resp_headers = {}
    while true do
        local line, herr = read_line()
        if not line then
            -- Original code only special-cased cancel here (no timeout
            -- branch on the headers loop). Preserve that behavior.
            if herr == "cancelled" then
                return nil, BaseHandler.CODE_CANCELLED, "user cancelled"
            end
            return nil, BaseHandler.CODE_NETWORK_ERROR, "headers: " .. tostring(herr)
        end
        if line == "" then break end
        local hk, hv = line:match("^([^:]+):%s*(.*)$")
        if hk then resp_headers[hk:lower()] = hv end
    end

    return code, reason, resp_headers, read_line, take_buffer, is_closed
end

--- Read the response body using whichever framing the server picked,
--- delivering bytes to on_chunk as they arrive. Three framings are
--- supported (priority per RFC 7230 §3.3.3):
---   1) Transfer-Encoding: chunked
---   2) Content-Length
---   3) read-until-close (identity, EOF-framed)
--- Returns true on success, or nil + (code, msg) on failure.
local function readResponseBody(sock, resp_headers, read_line, take_buffer,
                                is_closed, on_chunk, co, dismiss_check, deadline_check)
    local transfer_encoding = (resp_headers["transfer-encoding"] or ""):lower()
    local content_length = tonumber(resp_headers["content-length"])
    local is_chunked = transfer_encoding:find("chunked", 1, true) ~= nil

    if is_chunked then
        while true do
            local size_line, slerr = read_line()
            if not size_line then
                if slerr == "cancelled" then
                    return nil, BaseHandler.CODE_CANCELLED, "user cancelled"
                end
                return nil, BaseHandler.CODE_NETWORK_ERROR,
                    "chunk size: " .. tostring(slerr)
            end
            local chunk_size = parseChunkSize(size_line)
            if not chunk_size then
                return nil, BaseHandler.CODE_NETWORK_ERROR,
                    "bad chunk size: " .. size_line
            end
            if chunk_size == 0 then
                break  -- terminating chunk; trailers ignored.
            end
            local pre = take_buffer()
            local chunk_bytes, rerr = readExactly(
                sock, chunk_size, pre, co, dismiss_check, deadline_check)
            if not chunk_bytes then
                local code, msg = ioFailure(rerr, "chunk read")
                return nil, code, msg
            end
            if on_chunk and #chunk_bytes > 0 then on_chunk(chunk_bytes) end
            -- consume trailing CRLF after chunk data
            local trailing = read_line()
            if trailing == nil then
                -- closed mid-chunked; treat as end-of-body
                break
            end
        end
        return true
    end

    if content_length then
        local pre = take_buffer()
        local body_bytes, rerr = readExactly(
            sock, content_length, pre, co, dismiss_check, deadline_check)
        if not body_bytes then
            local code, msg = ioFailure(rerr, "body read")
            return nil, code, msg
        end
        if on_chunk and #body_bytes > 0 then on_chunk(body_bytes) end
        return true
    end

    -- read-until-close: hand bytes to on_chunk as they arrive.
    -- Some streaming providers in identity-encoded mode rely on this.
    local pre = take_buffer()
    if #pre > 0 and on_chunk then on_chunk(pre) end
    while not is_closed() do
        local data, rerr, partial = sock:receive(READ_CHUNK_SIZE)
        if data then
            if on_chunk and #data > 0 then on_chunk(data) end
        else
            if partial and #partial > 0 and on_chunk then on_chunk(partial) end
            if rerr == "wantread" or rerr == "wantwrite" or rerr == "timeout" then
                if deadline_check() then
                    return nil, BaseHandler.CODE_TIMEOUT, "stream read timeout"
                end
                local cont = yieldOrCancel(co, IO_POLL_INTERVAL_SEC, dismiss_check)
                if not cont then
                    return nil, BaseHandler.CODE_CANCELLED, "user cancelled"
                end
            elseif rerr == "closed" then
                break
            else
                return nil, BaseHandler.CODE_NETWORK_ERROR,
                    "stream: " .. tostring(rerr)
            end
        end
    end
    return true
end

--- Streaming HTTPS request over a non-blocking SSL socket.
--- This is the load-bearing primitive: every `makeRequest` and
--- `backgroundRequest` call funnels through here. No fork(), no
--- subprocess — just cooperative coroutine yielding around socket I/O.
---
--- Orchestrates four stages, each in its own helper:
---   1) connectAndUpgrade  — TCP connect + TLS wrap + handshake
---   2) sendRequest        — build & send HTTP/1.1 request
---   3) readResponseHeaders — status line + headers
---   4) readResponseBody   — chunked / content-length / EOF body
--- The orchestrator owns socket lifetime: every error path closes the
--- socket via safeClose before returning.
---
--- @param url string  full URL (https://...)
--- @param headers table  request headers (Content-Type etc; api keys)
--- @param body string  request body (already encoded, e.g. JSON)
--- @param on_chunk function  called as on_chunk(bytes) for each body chunk;
---                           for non-streaming responses, called once with full body.
--- @param dismiss_check function|nil  returns true if user wants to abort.
--- @param maxtime number|nil  total wall-clock seconds; default 120.
--- @param method string  HTTP method ("POST" or "GET"); defaults to POST.
--- @param connect_timeout number|nil  blocking-timeout (seconds) used for
---                       connect/DNS and as the legacy per-block budget;
---                       default 15. Mirrors the old `timeout` semantics
---                       from the pre-refactor LuaSocket path.
--- @return boolean success, string|number code, string err_or_msg
function BaseHandler:_streamingHttpsRequest(url, headers, body, on_chunk, dismiss_check, maxtime, method, connect_timeout)
    local co = coroutine.running()
    if not co then
        -- Strict precondition: every caller is inside Trapper:wrap().
        -- Fall back to a clear error rather than blocking the UI thread.
        logger.warn("_streamingHttpsRequest called outside coroutine; aborting")
        return false, BaseHandler.CODE_NETWORK_ERROR, "no coroutine"
    end

    local parts, perr = parseUrl(url)
    if not parts then return false, BaseHandler.CODE_NETWORK_ERROR, perr end

    local deadline = os.time() + (maxtime or 120)
    local function deadline_check() return os.time() > deadline end

    -- Stage 1: connect + TLS upgrade.
    -- connectAndUpgrade owns close() on its failure paths; on success
    -- the orchestrator owns close() for the returned socket.
    local sock, c_code, c_msg = connectAndUpgrade(
        parts, co, connect_timeout, dismiss_check, deadline_check)
    if not sock then
        return false, c_code, c_msg
    end

    -- Stage 2: send the HTTP request.
    local ok, s_code, s_msg = sendRequest(
        sock, parts, method, headers, body, co, dismiss_check, deadline_check)
    if not ok then
        safeClose(sock)
        return false, s_code, s_msg
    end

    -- Stage 3: read status line + headers.
    -- On success: status_code, reason, resp_headers, read_line, take_buffer, is_closed.
    -- On failure: nil, h_code, h_msg.
    local status_code, reason_or_code, headers_or_msg, read_line, take_buffer, is_closed =
        readResponseHeaders(sock, co, dismiss_check, deadline_check)
    if not status_code then
        safeClose(sock)
        return false, reason_or_code, headers_or_msg
    end
    local reason = reason_or_code
    local resp_headers = headers_or_msg

    -- Stage 4: stream the body.
    local bok, b_code, b_msg = readResponseBody(
        sock, resp_headers, read_line, take_buffer, is_closed,
        on_chunk, co, dismiss_check, deadline_check)
    if not bok then
        safeClose(sock)
        return false, b_code, b_msg
    end

    safeClose(sock)

    if status_code >= 400 then
        -- Non-2xx is signaled to the caller via the code; the body bytes
        -- have already been delivered to on_chunk so error messages can
        -- be parsed by the consumer.
        return false, status_code, reason
    end
    return true, status_code, reason
end

--- Make a request to the specified URL with headers and body. Buffers
--- the entire response into a string and returns it.
function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    -- Decide a maxtime: large bodies (whole-book analysis) get a longer budget.
    local request_maxtime
    if maxtime then
        request_maxtime = maxtime
    elseif body and #body > 10000 then
        request_maxtime = 300
    elseif self.trap_widget then
        request_maxtime = 120
    else
        request_maxtime = 45
    end
    -- `timeout` from callers maps to the connect/DNS blocking timeout
    -- in the new non-blocking path (closest equivalent to the old
    -- LuaSocket per-block timeout). nil falls back to the 15s default
    -- inside _streamingHttpsRequest.
    -- Cancellation is wired through `trap_widget`'s dismiss_callback when set.
    local cancelled = false
    local trap = self.trap_widget
    local override_active = false
    local prev_dismiss
    if trap then
        prev_dismiss = trap.dismiss_callback  -- may be nil; that's fine
        trap.dismiss_callback = function()
            cancelled = true
            if prev_dismiss then pcall(prev_dismiss) end
        end
        override_active = true
    end
    local dismiss_check = function() return cancelled end

    local buf = {}
    local on_chunk = function(c) table.insert(buf, c) end

    local success, code, msg = self:_streamingHttpsRequest(
        url, headers, body, on_chunk, dismiss_check, request_maxtime, nil, timeout)

    -- Always restore — assigning nil is correct when there was no prior
    -- callback. The previous guarded form leaked the override (and the
    -- captured `cancelled` upvalue) when prev_dismiss was nil.
    if override_active then
        trap.dismiss_callback = prev_dismiss
    end

    if cancelled or code == BaseHandler.CODE_CANCELLED then
        return false, BaseHandler.CODE_CANCELLED, BaseHandler.CODE_CANCELLED
    end

    local content = table.concat(buf)
    if not success then
        -- Network/timeout error path: msg is the error string.
        -- For non-200 with body, we still return the body as `content`
        -- so callers can parse error JSON from the API.
        if type(code) == "number" then
            return false, code, content ~= "" and content or msg
        end
        return false, code, msg or content
    end
    return true, code, content
end

--- Convenience GET request, buffered into a single string. Used by the
--- model picker and update checker. Replaces the old fork-based path.
--- Same dismiss semantics as makeRequest: pass a trap_widget if you want
--- the user to be able to cancel via dismiss_callback.
--- @param url string
--- @param headers table|nil
--- @param trap_widget table|nil  optional widget whose dismiss_callback we hook
--- @param maxtime number|nil
--- @return boolean success, string|number code, string content_or_err
function BaseHandler:simpleGet(url, headers, trap_widget, maxtime)
    local cancelled = false
    local override_active = false
    local prev_dismiss
    if trap_widget then
        prev_dismiss = trap_widget.dismiss_callback  -- may be nil; that's fine
        trap_widget.dismiss_callback = function()
            cancelled = true
            if prev_dismiss then pcall(prev_dismiss) end
        end
        override_active = true
    end
    local dismiss_check = function() return cancelled end

    local buf = {}
    local on_chunk = function(c) table.insert(buf, c) end
    local success, code, msg = self:_streamingHttpsRequest(
        url, headers, "", on_chunk, dismiss_check, maxtime or 30, "GET")

    -- Always restore — see makeRequest for rationale. The previous guarded
    -- form leaked the override when there was no prior dismiss_callback,
    -- which was the common path for the elseif branch above.
    if override_active then
        trap_widget.dismiss_callback = prev_dismiss
    end

    if cancelled or code == BaseHandler.CODE_CANCELLED then
        return false, BaseHandler.CODE_CANCELLED, BaseHandler.CODE_CANCELLED
    end

    local content = table.concat(buf)
    if not success then
        if type(code) == "number" then
            return false, code, content ~= "" and content or msg
        end
        return false, code, msg or content
    end
    return true, code, content
end

--- Streaming background request. The returned callable is consumed by
--- Querier:processStream. Signature change vs the old subprocess version:
---     OLD: function(pid, child_write_fd) -> writes raw bytes to fd
---     NEW: function(on_chunk, dismiss_check) -> success, code, err_or_msg
--- The handler-facing signature (the one that builds and returns this
--- closure) is unchanged: backgroundRequest(url, headers, body).
function BaseHandler:backgroundRequest(url, headers, body)
    local self_ref = self
    return function(on_chunk, dismiss_check, maxtime)
        return self_ref:_streamingHttpsRequest(
            url, headers, body, on_chunk, dismiss_check, maxtime or 300)
    end
end

-- Internal helpers exposed for testing only. Do not use from production code.
BaseHandler._test = {
    parseUrl = parseUrl,
    parseStatusLine = parseStatusLine,
    parseChunkSize = parseChunkSize,
    buildRequest = buildRequest,
}

return BaseHandler
