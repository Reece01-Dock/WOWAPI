-- Generates wowapi/data/apidocs.lua from Blizzard's generated API docs
-- (Interface/AddOns/Blizzard_APIDocumentationGenerated in wow-ui-source).
--
--   lua5.1 tools/gen-apidocs.lua <docs dir> "<source description>" > wowapi/data/apidocs.lua
--
-- Use tools/update-apidocs.sh to fetch the latest docs and regenerate.
local dir, source = arg[1], arg[2] or "unknown"
assert(dir, "usage: gen-apidocs.lua <Blizzard_APIDocumentationGenerated dir> [source]")

local proxy
local function ret() return proxy end
proxy = setmetatable({}, { __index = ret, __call = ret, __add = ret, __sub = ret, __mul = ret,
  __div = ret, __unm = ret, __mod = ret, __concat = ret })

-- Docs reference Enum.* / Constants.* values, sometimes with arithmetic.
-- Load everything twice: the first pass learns the values the second uses.
local function lookup(known)
  return setmetatable({}, { __index = function(_, k)
    local t = known[k]
    if not t then return proxy end
    return setmetatable({}, { __index = function(_, v) local x = t[v]; if x == nil then return proxy end return x end })
  end })
end

local tables
local knownEnums, knownConsts = {}, {}
for pass = 1, 3 do
  tables = {}
  local env = setmetatable({
    APIDocumentation = { AddDocumentationTable = function(_, t) tables[#tables + 1] = t end },
    Enum = lookup(knownEnums), Constants = lookup(knownConsts),
  }, { __index = _G })
  local p = io.popen('ls "' .. dir .. '"/*.lua | sort')
  for file in p:lines() do
    local chunk = assert(loadfile(file))
    setfenv(chunk, env)
    local ok, err = pcall(chunk)
    if not ok and pass == 3 then io.stderr:write("skip " .. file .. ": " .. tostring(err) .. "\n") end
  end
  p:close()
  for _, t in ipairs(tables) do
    for _, tb in ipairs(t.Tables or {}) do
      if tb.Type == "Enumeration" then
        knownEnums[tb.Name] = {}
        for _, f in ipairs(tb.Fields or {}) do knownEnums[tb.Name][f.Name] = f.EnumValue end
      elseif tb.Type == "Constants" then
        knownConsts[tb.Name] = {}
        for _, v in ipairs(tb.Values or {}) do
          local val = v.Value
          -- constants typed as an enum name their value by enum key
          if type(val) == "string" and knownEnums[v.Type] and knownEnums[v.Type][val] then val = knownEnums[v.Type][val] end
          if type(val) == "number" or type(val) == "string" then knownConsts[tb.Name][v.Name] = val end
        end
      end
    end
  end
end

local out = { functions = {}, events = {}, enums = {}, constants = {}, structures = {}, callbacks = {},
  scriptObjects = {} }

local function field(f)
  local t = { f.Name, f.Type, f.Nilable and true or false }
  if f.InnerType then t[4] = f.InnerType end
  if f.Default ~= nil and type(f.Default) ~= "table" then t[5] = f.Default end
  if f.StrideIndex then t[6] = f.StrideIndex end
  return t
end
local function fields(list)
  local o = {}
  for i, f in ipairs(list or {}) do o[i] = field(f) end
  return o
end
local FLAGS = { "IsProtectedFunction", "HasRestrictions", "SecretReturns", "SecretWhenInCombat",
  "MayReturnNothing", "SecretWhenUnitStatsRestricted", "SecretWhenUnitIdentityRestricted",
  "SecretWhenUnitAuraRestricted", "SecretWhenUnitSpellCastRestricted", "SecretWhenCooldownsRestricted",
  "SecretWhenUnitPowerRestricted", "ReturnsNeverSecret" }
local function fn(f)
  local d = { a = fields(f.Arguments), r = fields(f.Returns) }
  for _, flag in ipairs(FLAGS) do if f[flag] then d.f = d.f or {}; d.f[#d.f + 1] = flag end end
  if f.SecretArguments then d.sa = f.SecretArguments end
  return d
end

for _, t in ipairs(tables) do
  if t.Environment == "SecureOnly" then
    -- not callable from addon code
  elseif t.Type == "ScriptObject" then
    local methods = {}
    for _, f in ipairs(t.Functions or {}) do methods[f.Name] = fn(f) end
    out.scriptObjects[t.Name] = methods
  else
    for _, f in ipairs(t.Functions or {}) do
      if f.Environment ~= "SecureOnly" then
        local key = t.Namespace and (t.Namespace .. "." .. f.Name) or f.Name
        out.functions[key] = fn(f)
      end
    end
  end
  for _, e in ipairs(t.Events or {}) do
    local ev = fields(e.Payload)
    if e.SecretPayloads then ev.secret = true end
    out.events[e.LiteralName] = ev
  end
  for _, tb in ipairs(t.Tables or {}) do
    if tb.Type == "Enumeration" then
      local vals = {}
      for _, f in ipairs(tb.Fields or {}) do
        if type(f.EnumValue) == "number" then vals[f.Name] = f.EnumValue end
      end
      out.enums[tb.Name] = vals
    elseif tb.Type == "Constants" then
      local vals = {}
      for _, v in ipairs(tb.Values or {}) do
        if type(v.Value) == "string" and knownEnums[v.Type] and knownEnums[v.Type][v.Value] then
          v.Value = knownEnums[v.Type][v.Value]
        end
        if type(v.Value) == "number" or type(v.Value) == "string" or type(v.Value) == "boolean" then vals[v.Name] = v.Value end
      end
      out.constants[tb.Name] = vals
    elseif tb.Type == "Structure" then
      out.structures[tb.Name] = fields(tb.Fields)
    elseif tb.Type == "CallbackType" then
      out.callbacks[tb.Name] = true
    end
  end
end

-- deterministic serializer
local function ser(v, ind)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t ~= "table" then return tostring(v) end
  local n = #v
  local parts = {}
  for i = 1, n do parts[#parts + 1] = ser(v[i], ind) end
  local keys = {}
  for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local ks = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. ser(k) .. "]")
    parts[#parts + 1] = ks .. "=" .. ser(v[k], ind)
  end
  if ind and ind < 2 and #keys > 0 then
    local pad = string.rep(" ", ind + 1)
    return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. "\n" .. string.rep(" ", ind) .. "}"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local count = function(t) local n = 0; for _ in pairs(t) do n = n + 1 end return n end
io.write("-- GENERATED by tools/gen-apidocs.lua from Blizzard's API documentation. Do not edit.\n")
io.write("-- Source: " .. source .. "\n")
io.write(string.format("-- %d functions, %d events, %d enums, %d structures, %d widget APIs\n",
  count(out.functions), count(out.events), count(out.enums), count(out.structures), count(out.scriptObjects)))
io.write("-- Format: field = { name, type, nilable, innerType, default }\n")
io.write("return " .. ser({ source = source, functions = out.functions, events = out.events, enums = out.enums,
  constants = out.constants, structures = out.structures, callbacks = out.callbacks,
  scriptObjects = out.scriptObjects }, 0) .. "\n")
