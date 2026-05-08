--- Verbatim copy of luasocket's socket.url.parse, used as a stub when
--- running tests under plain Lua (no luasocket installed).
---
--- Source: https://github.com/lunarmodules/luasocket  (src/url.lua)
--- License: MIT (luasocket is MIT-licensed; copy preserves attribution)
---
--- Only `parse` is implemented — that's the only function api_handlers/base.lua
--- uses. Everything else is omitted.

local _M = {}

function _M.parse(url, default)
    -- initialize default parameters
    local parsed = {}
    for i, v in pairs(default or parsed) do parsed[i] = v end
    -- empty url is parsed to nil
    if not url or url == "" then return nil, "invalid url" end
    -- get scheme
    url = string.gsub(url, "^([%w][%w%+%-%.]*)%:",
        function(s) parsed.scheme = s; return "" end)
    -- get authority
    url = string.gsub(url, "^//([^/%?#]*)", function(n)
        parsed.authority = n
        return ""
    end)
    -- get fragment
    url = string.gsub(url, "#(.*)$", function(f)
        parsed.fragment = f
        return ""
    end)
    -- get query string
    url = string.gsub(url, "%?(.*)", function(q)
        parsed.query = q
        return ""
    end)
    -- get params
    url = string.gsub(url, "%;(.*)", function(p)
        parsed.params = p
        return ""
    end)
    -- path is whatever was left
    if url ~= "" then parsed.path = url end
    local authority = parsed.authority
    if not authority then return parsed end
    authority = string.gsub(authority, "^([^@]*)@",
        function(u) parsed.userinfo = u; return "" end)
    authority = string.gsub(authority, ":([^:%]]*)$",
        function(p) parsed.port = p; return "" end)
    if authority ~= "" then
        -- IPv6?
        parsed.host = string.match(authority, "^%[(.+)%]$") or authority
    end
    local userinfo = parsed.userinfo
    if not userinfo then return parsed end
    userinfo = string.gsub(userinfo, ":([^:]*)$",
        function(p) parsed.password = p; return "" end)
    parsed.user = userinfo
    return parsed
end

return _M
