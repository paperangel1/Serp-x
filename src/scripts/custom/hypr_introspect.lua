#!/usr/bin/env lua
--
-- Loads a Hyprland Lua config tree (hyprland.lua + config/*.lua) with a stubbed
-- `hl` table instead of the real one, so every hl.bind(...) call is RECORDED
-- instead of applied. Prints the collected binds as a JSON array on stdout.
--
-- This does NOT touch the running compositor and has no side effects: hl.exec_cmd
-- (the immediate-execution call used in autostart.lua) is a no-op, hl.on callbacks
-- are never invoked, and every unknown hl.* member resolves to a no-op function via
-- __index metatables so an unfamiliar API surface can never raise an error.
--
-- Each record: keys, modmask, key, kind, args, opts, src (config file that registered it).
-- Usage: lua hypr_introspect.lua <hypr-config-dir>
--   (defaults to $HOME/.config/hypr if omitted)
--

local hypr_dir = arg[1] or (os.getenv("HOME") .. "/.config/hypr")

package.path = hypr_dir .. "/?.lua;" .. package.path

local binds = {}

-- A "descriptor" is what hl.dsp.<path>(...) returns instead of a real dispatcher:
-- it just remembers the dotted access path and the arguments it was called with.
local function mk_descriptor(path)
    return setmetatable({}, {
        __index = function(_, k)
            return mk_descriptor(path .. "." .. k)
        end,
        __call = function(_, ...)
            return { kind = path, args = { ... }, n = select("#", ...) }
        end,
    })
end

-- A generic no-op callable/indexable stub for any hl.* member we don't care about
-- (hl.env, hl.monitor, hl.config, hl.curve, hl.animation, hl.gesture, hl.on, ...).
-- Calling it does nothing and returns nothing; indexing it yields more of the same.
local function mk_noop()
    local t
    t = setmetatable({}, {
        __index = function() return t end,
        __call = function() return nil end,
    })
    return t
end

-- hl.dsp.<name>(...) and hl.dsp.window.<name>(...) etc: each first-level member
-- starts a fresh descriptor path (no leading "dsp." prefix) so kinds come out as
-- plain "exec_cmd" / "window.close" / "focus" — directly usable as i18n key suffixes.
local hl_dsp = setmetatable({}, {
    __index = function(_, k)
        return mk_descriptor(k)
    end,
})

hl = setmetatable({
    bind = function(keys, dispatcher, opts)
        -- Which config file registered this bind (relative to the hypr dir): lets the
        -- UI tell shipped binds (config/keybinds.lua) from generated ones
        -- (config/user_keybinds.lua) and from anything the user wrote by hand.
        local info = debug.getinfo(2, "S")
        local src = info and info.source or ""
        src = src:gsub("^@", "")
        if src:sub(1, #hypr_dir + 1) == hypr_dir .. "/" then src = src:sub(#hypr_dir + 2) end
        binds[#binds + 1] = { keys = keys, dispatcher = dispatcher, opts = opts, src = src }
        return mk_descriptor("keybind")
    end,
    dsp = hl_dsp,
    -- hl.exec_cmd (NOT hl.dsp.exec_cmd) runs a command immediately when called from
    -- autostart.lua-style code. Must be inert here.
    exec_cmd = function() end,
    -- hl.on registers an event callback (e.g. "hyprland.start"). Must never invoke it.
    on = function() end,
}, {
    __index = function(_, k)
        return mk_noop()
    end,
})

local ok, err = pcall(require, "hyprland")
if not ok then
    io.stderr:write("hypr_introspect: failed to load hyprland.lua: " .. tostring(err) .. "\n")
    io.write("[]\n")
    os.exit(1)
end

-- ---- modmask computation -------------------------------------------------

local MODBITS = {
    SHIFT = 1, CAPS = 2, CTRL = 4, CONTROL = 4, ALT = 8, MOD1 = 8,
    MOD2 = 16, MOD3 = 32, SUPER = 64, MOD4 = 64, WIN = 64, LOGO = 64,
    MOD5 = 128, ALTGR = 128,
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Splits a combo string like "SUPER + SHIFT + Left" into (modmask, "Left").
-- Anything not a recognized modifier name is treated as the key itself; if more
-- than one non-modifier token appears (shouldn't happen), the last one wins.
local function split_combo(s)
    local mask, key = 0, ""
    for raw_tok in tostring(s):gmatch("[^+]+") do
        local tok = trim(raw_tok)
        if tok ~= "" then
            local bit = MODBITS[tok:upper()]
            if bit then
                mask = mask | bit
            else
                key = tok
            end
        end
    end
    return mask, key
end

-- ---- JSON encoding (no external deps available inside lua) --------------

local function json_escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

local function json_string(s)
    return '"' .. json_escape(s) .. '"'
end

-- True if t's keys are exactly the integers 1..n with no holes (a Lua "array"),
-- as opposed to a map-style table like {direction = "l"}.
local function is_array_like(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
            return false
        end
        if k > n then n = k end
    end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == n
end

-- Recursively encodes any dispatcher argument value as real JSON: strings,
-- numbers and booleans as themselves, array-like tables as JSON arrays,
-- map-style tables (e.g. { direction = "l" }, { x = -50, y = 0, relative = true })
-- as JSON objects. This is what lets the generator faithfully reconstruct a
-- non-exec_cmd dispatcher call (hl.dsp.window.move({direction="l"}), etc.) on a
-- remapped key, instead of the old "<table>" placeholder which threw the
-- original arguments away.
local function encode_value(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" or t == "number" then
        return tostring(v)
    elseif t == "string" then
        return json_string(v)
    elseif t == "table" then
        if is_array_like(v) then
            local parts = {}
            for i = 1, #v do
                parts[#parts + 1] = encode_value(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = json_string(tostring(k)) .. ":" .. encode_value(v[k])
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        -- function/userdata/thread: not expected in real dispatcher args.
        return json_string("<" .. t .. ">")
    end
end

local function args_to_json(d)
    local parts = {}
    for i = 1, (d.n or 0) do
        parts[#parts + 1] = encode_value(d.args[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function opts_to_json(opts)
    if type(opts) ~= "table" then
        return "{}"
    end
    local parts = {}
    for k, v in pairs(opts) do
        local t = type(v)
        if t == "boolean" then
            parts[#parts + 1] = json_string(k) .. ":" .. tostring(v)
        elseif t == "string" then
            parts[#parts + 1] = json_string(k) .. ":" .. json_string(v)
        elseif t == "number" then
            parts[#parts + 1] = json_string(k) .. ":" .. tostring(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local out = { "[" }
for i, b in ipairs(binds) do
    local mask, key = split_combo(b.keys)
    local kind, args_json = "unknown", "[]"
    if type(b.dispatcher) == "table" and b.dispatcher.kind then
        kind = b.dispatcher.kind
        args_json = args_to_json(b.dispatcher)
    end
    local rec = string.format(
        '{"keys":%s,"modmask":%d,"key":%s,"kind":%s,"args":%s,"opts":%s,"src":%s}',
        json_string(b.keys), mask, json_string(key), json_string(kind), args_json, opts_to_json(b.opts), json_string(b.src or "")
    )
    if i > 1 then
        out[#out + 1] = ","
    end
    out[#out + 1] = rec
end
out[#out + 1] = "]"

io.write(table.concat(out))
io.write("\n")
