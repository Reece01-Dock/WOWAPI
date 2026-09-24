-- Renders the simulated UI to SVG: frames in strata/level order, their
-- regions by draw layer, backdrops, color and file textures, status bars,
-- edit boxes, tooltips and text with |c color codes.
--
-- File textures can't be drawn (no game assets), so they render as a
-- tinted placeholder labelled with the file or atlas name.
local layout = require("wowapi.layout")

local M = {}

local H = layout.SCREEN_H

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function rgb(r, g, b)
  local function c(v) return math.max(0, math.min(255, math.floor((v or 1) * 255 + 0.5))) end
  return string.format("#%02x%02x%02x", c(r), c(g), c(b))
end

local function num(n) return string.format("%.1f", n) end

-- "|cffff0000red|r plain" -> list of { text, color }
local function colorRuns(text, default)
  local runs = {}
  local color = default
  local i = 1
  text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("||", "|")
  while i <= #text do
    local s, e, hex = text:find("|c(%x%x%x%x%x%x%x%x)", i)
    local rs, re = text:find("|r", i, true)
    local nextCode = math.min(s or math.huge, rs or math.huge)
    if nextCode == math.huge then
      runs[#runs + 1] = { text:sub(i), color }
      break
    end
    if nextCode > i then runs[#runs + 1] = { text:sub(i, nextCode - 1), color } end
    if s and nextCode == s then
      color = "#" .. hex:sub(3):lower()
      i = e + 1
    else
      color = default
      i = re + 1
    end
  end
  return runs
end

local function textSvg(out, x, y, text, size, color, anchor, opacity, bold)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  for i, line in ipairs(lines) do
    local parts = {}
    for _, run in ipairs(colorRuns(line, color)) do
      parts[#parts + 1] = string.format('<tspan fill="%s">%s</tspan>', run[2], esc(run[1]))
    end
    out[#out + 1] = string.format(
      '<text x="%s" y="%s" font-size="%s" text-anchor="%s" opacity="%.2f"%s font-family="Friz Quadrata TT, Georgia, serif" stroke="#000" stroke-width="%.1f" paint-order="stroke">%s</text>',
      num(x), num(y + (i - 1) * size * 1.15), num(size), anchor, opacity, bold and ' font-weight="bold"' or "",
      size / 8, table.concat(parts))
  end
end

local function region(sim, obj, out, opts)
  local st = sim.widgetState
  local s = st[obj]
  local l, b, w, h = layout.rect(sim, obj)
  if not l then return end
  local x, y = l, H - b - h
  local alpha = obj.GetEffectiveAlpha and obj:GetEffectiveAlpha() or 1
  if alpha <= 0 then return end

  if s.type == "Texture" or s.type == "Line" then
    if w <= 0 or h <= 0 then return end
    local c = s.color or { 1, 1, 1, 1 }
    local a = (c[4] or 1) * alpha
    if s.texture == "color" then
      out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" opacity="%.2f"/>',
        num(x), num(y), num(w), num(h), rgb(c[1], c[2], c[3]), a)
    elseif s.texture or s.atlas then
      local label = tostring(s.atlas or s.texture):gsub("^.*[/\\]", "")
      out[#out + 1] = string.format(
        '<g opacity="%.2f"><rect x="%s" y="%s" width="%s" height="%s" fill="%s" fill-opacity="0.55" stroke="%s" stroke-opacity="0.6"/>%s<title>%s</title></g>',
        a, num(x), num(y), num(w), num(h), rgb(c[1] * 0.6, c[2] * 0.6, c[3] * 0.6), rgb(c[1], c[2], c[3]),
        (w > 40 and h > 10) and string.format('<text x="%s" y="%s" font-size="9" fill="#ddd" font-family="monospace">%s</text>',
          num(x + 2), num(y + 10), esc(label:sub(1, math.floor(w / 5.5)))) or "",
        esc(tostring(s.atlas or s.texture)))
    end
  elseif s.type == "FontString" then
    if not s.text or s.text == "" then return end
    local _, size = layout.fontOf(sim, obj)
    local tc = s.textColor
    if not tc then
      local fo = s.fontObject
      if type(fo) == "string" then fo = sim:Get(fo) end
      tc = fo and st[fo] and st[fo].textColor
    end
    tc = tc or { 1, 0.82, 0, 1 }
    local jh = s.justifyH or "CENTER"
    local anchor, tx = "middle", x + w / 2
    if jh == "LEFT" then anchor, tx = "start", x elseif jh == "RIGHT" then anchor, tx = "end", x + w end
    local lines = layout.textLines(s.text)
    local ty
    local jv = s.justifyV or "MIDDLE"
    if jv == "TOP" then ty = y + size * 0.85
    elseif jv == "BOTTOM" then ty = y + h - (lines - 1) * size * 1.15 - size * 0.2
    else ty = y + h / 2 - (lines - 1) * size * 0.575 + size * 0.35 end
    textSvg(out, tx, ty, s.text, size, rgb(tc[1], tc[2], tc[3]), anchor, alpha * (tc[4] or 1))
  end
end

local LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY", "HIGHLIGHT" }

local function frame(sim, obj, out, opts)
  local st = sim.widgetState
  local s = st[obj]
  local l, b, w, h = layout.rect(sim, obj)
  if not l then return end
  local x, y = l, H - b - h
  local alpha = obj:GetEffectiveAlpha()

  -- backdrop
  if s.backdrop then
    local c = s.backdropColor or { 0, 0, 0, 0.8 }
    local bc = s.backdropBorderColor or { 0.6, 0.6, 0.6, 1 }
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="4" fill="%s" fill-opacity="%.2f" stroke="%s" stroke-opacity="%.2f" stroke-width="%s" opacity="%.2f"/>',
      num(x), num(y), num(w), num(h), rgb(c[1], c[2], c[3]), c[4] or 1, rgb(bc[1], bc[2], bc[3]), bc[4] or 1,
      s.backdrop.edgeFile and num(math.max(1, (s.backdrop.edgeSize or 12) / 4)) or "0", alpha)
  end

  -- widget-specific drawing
  if s.type == "GameTooltip" then
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="4" fill="#090a1a" fill-opacity="0.92" stroke="#b0b0b0" opacity="%.2f"/>',
      num(x), num(y), num(w), num(h), alpha)
    for i, line in ipairs(s.lines or {}) do
      local size = i == 1 and 14 or 12
      local ly = y + 8 + (i - 1) * 14 + size * 0.85
      local c = (line.r and rgb(line.r, line.g, line.b)) or (i == 1 and "#ffffff" or "#ffd100")
      textSvg(out, x + 10, ly, line.left or "", size, c, "start", alpha)
      if line.right then textSvg(out, x + w - 10, ly, line.right, size, "#ffffff", "end", alpha) end
    end
  elseif s.type == "StatusBar" then
    local lo, hi = s.min or 0, s.max or 0
    local frac = hi > lo and ((s.value or 0) - lo) / (hi - lo) or 0
    local c = s.color or { 1, 1, 1, 1 }
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" opacity="%.2f"/>',
      num(x), num(y), num(w * math.max(0, math.min(1, frac))), num(h), rgb(c[1], c[2], c[3]), alpha * (c[4] or 1))
  elseif s.type == "EditBox" then
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="#000" fill-opacity="0.5" stroke="#777" opacity="%.2f"/>',
      num(x), num(y), num(w), num(h), alpha)
    local text = s.password and string.rep("*", #(s.text or "")) or (s.text or "")
    local tc = s.textColor or { 1, 1, 1, 1 }
    textSvg(out, x + 4, y + h / 2 + 4, text .. (sim.keyboardFocus == obj and "|" or ""), 12, rgb(tc[1], tc[2], tc[3]), "start", alpha)
  elseif s.type == "Slider" then
    local lo, hi = s.min or 0, s.max or 0
    local frac = hi > lo and ((s.value or 0) - lo) / (hi - lo) or 0
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#222" stroke="#666" opacity="%.2f"/>',
      num(x), num(y + h / 2 - 3), num(w), "6", alpha)
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="10" height="%s" rx="2" fill="#ccc" opacity="%.2f"/>',
      num(x + (w - 10) * frac), num(y), num(h), alpha)
  elseif s.type == "Button" or s.type == "CheckButton" then
    if s.type == "CheckButton" then
      out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#111" stroke="#aaa" opacity="%.2f"/>',
        num(x), num(y), num(math.min(w, h)), num(math.min(w, h)), alpha)
      if s.checked then
        local d = math.min(w, h)
        out[#out + 1] = string.format('<path d="M%s %s L%s %s L%s %s" stroke="#ffd100" stroke-width="3" fill="none" opacity="%.2f"/>',
          num(x + d * 0.2), num(y + d * 0.5), num(x + d * 0.42), num(y + d * 0.75), num(x + d * 0.82), num(y + d * 0.25), alpha)
      end
    elseif s.chrome == "panel" then
      local fill = s.enabled == false and "#444" or "#7a1010"
      if sim.mouseFocus == obj and s.enabled ~= false then fill = "#a01818" end
      out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" rx="4" fill="%s" stroke="#d4a017" stroke-width="1.5" opacity="%.2f"/>',
        num(x), num(y), num(w), num(h), fill, alpha)
    elseif s.chrome == "close" then
      out[#out + 1] = string.format('<g opacity="%.2f"><rect x="%s" y="%s" width="%s" height="%s" rx="4" fill="#7a1010" stroke="#d4a017"/><path d="M%s %s L%s %s M%s %s L%s %s" stroke="#ffd100" stroke-width="2.5"/></g>',
        alpha, num(x + 3), num(y + 3), num(w - 6), num(h - 6), num(x + 8), num(y + 8), num(x + w - 8), num(y + h - 8),
        num(x + w - 8), num(y + 8), num(x + 8), num(y + h - 8))
    end
    for slot, t in pairs(s.textures or {}) do
      local show = slot == "Normal" or (slot == "Highlight" and sim.mouseFocus == obj)
        or (slot == "Checked" and s.checked) or (slot == "Disabled" and s.enabled == false)
      if show and t and st[t] and st[t].shown then region(sim, t, out, opts) end
    end
  end

  -- regions by draw layer, then sublevel, then creation order
  local regions = {}
  for _, c in ipairs(s.children) do
    local cs = st[c]
    if cs and not cs.isFrame and cs.shown and not cs.buttonSlot then
      if cs.layer ~= "HIGHLIGHT" or sim.mouseFocus == obj then regions[#regions + 1] = c end
    end
  end
  local layerIdx = {}
  for i, n in ipairs(LAYERS) do layerIdx[n] = i end
  table.sort(regions, function(a, c)
    local sa, sc = st[a], st[c]
    local la, lc = layerIdx[sa.layer or "ARTWORK"] or 3, layerIdx[sc.layer or "ARTWORK"] or 3
    if la ~= lc then return la < lc end
    if (sa.sublevel or 0) ~= (sc.sublevel or 0) then return (sa.sublevel or 0) < (sc.sublevel or 0) end
    return (sa.seq or 0) < (sc.seq or 0)
  end)
  -- a Button's text is drawn by its own FontString region
  for _, r in ipairs(regions) do region(sim, r, out, opts) end
  if s.type == "StatusBar" and s.barTexture == nil then
    -- nothing extra
  end

  if opts.outlines then
    out[#out + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="none" stroke="#00e0ff" stroke-opacity="0.5" stroke-dasharray="4 3"/>',
      num(x), num(y), num(w), num(h))
    if s.name then
      out[#out + 1] = string.format('<text x="%s" y="%s" font-size="10" fill="#00e0ff" font-family="monospace">%s</text>',
        num(x + 2), num(y - 3), esc(s.name))
    end
  end
end

-- Returns SVG markup of everything currently visible.
function M.svg(sim, opts)
  opts = opts or {}
  local st = sim.widgetState
  local frames = {}
  for obj, s in pairs(st) do
    if s.isFrame and not s.fixedRect and sim._isVisible(obj) then frames[#frames + 1] = obj end
  end
  table.sort(frames, function(a, c)
    local s1, l1, q1 = layout.frameOrder(sim, a)
    local s2, l2, q2 = layout.frameOrder(sim, c)
    if s1 ~= s2 then return s1 < s2 end
    if l1 ~= l2 then return l1 < l2 end
    return q1 < q2
  end)
  local out = {}
  out[#out + 1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">',
    layout.SCREEN_W, H, opts.width or layout.SCREEN_W, opts.height or H)
  out[#out + 1] = '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b3a4a"/><stop offset="1" stop-color="#1a2418"/></linearGradient></defs>'
  out[#out + 1] = string.format('<rect width="%d" height="%d" fill="url(#bg)"/>', layout.SCREEN_W, H)
  -- UIParent's own regions
  local uiRegions = {}
  for _, c in ipairs(st[sim.env.UIParent].children) do
    if not st[c].isFrame and st[c].shown then uiRegions[#uiRegions + 1] = c end
  end
  for _, r in ipairs(uiRegions) do region(sim, r, out, opts) end
  for _, f in ipairs(frames) do frame(sim, f, out, opts) end
  if sim.cursorX and opts.cursor ~= false then
    local cx, cy = sim.cursorX, H - sim.cursorY
    out[#out + 1] = string.format('<path d="M%s %s l0 18 l5 -5 l7 0 z" fill="#fff" stroke="#000"/>', num(cx), num(cy))
  end
  out[#out + 1] = "</svg>"
  return table.concat(out, "\n")
end

return M
