-- Generates the small art indexes the simulator ships with:
--   wowapi/data/icons.txt    "<fileID> <icon name>" for every Interface/Icons texture
--   wowapi/data/atlases.txt  "<atlas>\t<fileID>\t<path>\t<w>\t<h>\t<l>\t<r>\t<t>\t<b>\t<tileH>\t<tileV>"
--
--   lua5.1 tools/gen-art-data.lua <community-listfile.csv> <AtlasInfo.lua> <out dir>
-- (tools/update-art-data.sh downloads the inputs.)
local listfile, atlasinfo, outdir = arg[1], arg[2], arg[3]
assert(listfile and atlasinfo and outdir, "usage: gen-art-data.lua <listfile.csv> <AtlasInfo.lua> <out dir>")

local icons = {}
for line in io.lines(listfile) do
  line = line:gsub("\r$", "")
  local id, name = line:match("^(%d+);interface/icons/([^/]+)%.blp$")
  if id then icons[#icons + 1] = { tonumber(id), name:lower() } end
end
table.sort(icons, function(a, b) return a[1] < b[1] end)
local f = assert(io.open(outdir .. "/icons.txt", "w"))
f:write("# fileID name  (Interface/Icons, from wowdev/wow-listfile)\n")
for _, i in ipairs(icons) do f:write(i[1], " ", i[2], "\n") end
f:close()

local out = assert(io.open(outdir .. "/atlases.txt", "w"))
out:write("# atlas\tfileID\tpath\twidth\theight\tleft\tright\ttop\tbottom\ttileH\ttileV  (from Ketho/BlizzardInterfaceResources)\n")
local fileKey, fileID, n = nil, nil, 0
for line in io.lines(atlasinfo) do
  local key, id = line:match('^\t%["(.-)"%] = { %-%- (%d+)')
  if key then
    fileKey, fileID = key, id
  else
    local name, rest = line:match('^\t\t%["(.-)"%] = {(.-)},?$')
    if name and fileKey then
      local v = {}
      for x in rest:gmatch("[^,%s]+") do v[#v + 1] = x end
      local path = fileKey:match("^%d+$") and "" or fileKey:gsub("/ ", "/")
      out:write(table.concat({ name, fileID, path, v[1], v[2], v[3], v[4], v[5], v[6],
        v[7] == "true" and "1" or "0", v[8] == "true" and "1" or "0" }, "\t"), "\n")
      n = n + 1
    end
  end
end
out:close()
io.stderr:write(string.format("%d icons, %d atlases\n", #icons, n))
