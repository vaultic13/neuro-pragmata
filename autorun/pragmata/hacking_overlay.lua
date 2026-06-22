-- On-screen "auto-hack" overlay.
--
-- Problem this solves: when the AI peer drives a hack, from the player's seat
-- it just looks like the player is hacking unusually slowly — there's no
-- signal that the AI is the one moving the cursor. This draws a prominent,
-- HUD-styled banner over the game while a hack is in progress so it's obvious
-- the AI (not the player) is hacking, and shows how far along it is. The
-- peer's name shown comes from mod_config.display_name.
--
-- Two render paths:
--   1. PREFERRED — an ImGui window (created from re.on_frame, independent of
--      the REFramework menu) using a font loaded at a real pixel size via
--      imgui.load_font + push_font. This gives genuinely large, crisp text
--      that stays readable at stream/encode resolution. The animated glow is
--      drawn with the `draw` API OUTSIDE the window rect, so it shows
--      regardless of how the draw / ImGui layers are ordered.
--   2. FALLBACK — the original `draw` API banner (fixed-size font). Used only
--      if ImGui or font loading isn't available on the running build. Every
--      call is pcall-wrapped; a single ImGui failure flips a flag and we stay
--      on the fallback for the rest of the session.
--
-- Phases come from hacking_observer.overlay_status(); each has a DISTINCT
-- accent color (see DRAW) so the state reads at a glance, not just from text:
--   planning  (cyan)   -> "<NAME> IS HACKING / planning route..."
--   busy      (violet) -> "<NAME> IS HACKING / finishing another target..."
--   executing (teal)   -> "<NAME> IS HACKING / move N / M"
--   resumed   (teal)   -> brief "resuming planned route" flash
--   retrying  (amber)  -> brief "PUZZLE CHANGED / replanning" flash (grid changed)
--   rerouting (rose)   -> brief "REROUTING / hit a wall, finding another way" flash
--   jammed    (orange) -> "HACKING JAMMED / waiting for the jammer to clear"
--   paused    (slate)  -> "HACK PAUSED / waiting for the game to resume" (steady)
--   success   (green)  -> brief "HACK COMPLETE" flash
--   failed    (red)    -> brief "HACK FAILED" flash

local M = {}

local config   = require("pragmata.mod_config")
local observer = require("pragmata.hacking_observer")

-- BOTH the `draw` API and ImGui's ImU32 pack colors as ABGR (0xAABBGGRR — R in
-- the low byte, i.e. ImGui's IM_COL32). The reframework-book text calling it
-- "ARGB" is wrong; feeding ARGB makes cyan render as orange and dark-blue as
-- brown. LuaJIT has no `<<`, so build arithmetically.
local function abgr(r, g, b, a) a = a or 255; return a * 0x1000000 + b * 0x10000 + g * 0x100 + r end
local function with_alpha(color, a) return a * 0x1000000 + (color % 0x1000000) end

-- Accent palette, keyed by phase. One table — the `draw` API and ImGui share
-- the ABGR packing. Tuned toward the in-game hacking grid: dark navy panel
-- (slightly translucent for a holographic feel), cool-white text. Each
-- overlay state gets a DISTINCT accent so the color alone tells you the state
-- at a glance (the text was the only differentiator before):
--   cyan   = planning (waiting on the plan for THIS puzzle)
--   teal   = executing / resuming (cursor actually moving)
--   violet = busy (a different enemy's hack is finishing first)
--   amber  = retrying (the grid STRUCTURE changed; replanning)
--   rose   = rerouting (a planned move hit a wall/error node; replanning)
--   orange = jammed (a jammer is blocking hacking entirely)
--   slate  = paused (the game is paused; the hack is frozen)
--   green  = success    red = failed
local DRAW = {
    bg     = abgr(9, 17, 32, 214),
    white  = abgr(235, 244, 255, 255),
    shadow = abgr(0, 0, 0, 200),
    cyan   = abgr(78, 188, 255, 255),
    teal   = abgr(60, 224, 196, 255),
    violet = abgr(188, 124, 255, 255),
    green  = abgr(90, 230, 130, 255),
    red    = abgr(255, 80, 80, 255),
    amber  = abgr(255, 195, 70, 255),
    orange = abgr(255, 140, 40, 255),
    -- Rose/pink: a distinct "minor snag, rerouting" accent, apart from amber
    -- (grid changed) and red (hard failure).
    rose   = abgr(255, 120, 170, 255),
    -- Desaturated slate-blue: reads as inactive/frozen, clearly apart from the
    -- saturated "something's happening" accents above.
    slate  = abgr(150, 170, 200, 255),
}

-- ImGui enum constants (stable across ImGui versions for these flags).
local COND_ALWAYS      = 1
local IMCOL_WINDOW_BG  = 2
local IMCOL_BORDER     = 5
-- Borderless, fixed, click-through overlay window.
local OVERLAY_FLAGS =
      1        -- NoTitleBar
    + 2        -- NoResize
    + 4        -- NoMove
    + 8        -- NoScrollbar
    + 32       -- NoCollapse
    + 256      -- NoSavedSettings
    + 512      -- NoMouseInputs
    + 4096     -- NoBringToFrontOnFocus
    + 8192     -- NoFocusOnAppearing
    + 65536    -- NoNavInputs
    + 131072   -- NoNavFocus

local _frame = 0

-- Sizing knobs (easy to tune). Font sizes are real pixel heights for the
-- ImGui path; the banner box scales with them.
local FONT_TITLE_SIZE = 30
local FONT_SUB_SIZE   = 18
local BANNER_W        = 560
local BANNER_H        = 106

-- Fonts loaded at real pixel sizes for the ImGui path. Loaded lazily (once)
-- so we don't depend on ImGui being ready at script-load time.
local _font_big, _font_med
local _fonts_loaded = false
local _imgui_failed = false   -- set if an ImGui render throws; pins us to fallback

local function load_fonts()
    if _fonts_loaded then return end
    if imgui == nil or imgui.load_font == nil then return end
    pcall(function() _font_big = imgui.load_font(nil, FONT_TITLE_SIZE) end)
    pcall(function() _font_med = imgui.load_font(nil, FONT_SUB_SIZE) end)
    if _font_big ~= nil then _fonts_loaded = true end
end

-- Fallback if the display size can't be read; centering is slightly off at
-- other resolutions but the banner still shows.
local FALLBACK_W, FALLBACK_H = 1920, 1080

local function screen_size()
    local ok, size = pcall(function() return imgui.get_display_size() end)
    if ok and size ~= nil then
        local w, h
        local okx = pcall(function() w = size.x end)
        local oky = pcall(function() h = size.y end)
        if okx and oky and type(w) == "number" and type(h) == "number"
           and w > 0 and h > 0 then
            return w, h
        end
    end
    return FALLBACK_W, FALLBACK_H
end

-- Individually-guarded `draw` primitives so a missing one degrades gracefully.
local function filled_rect(x, y, w, h, c) pcall(function() draw.filled_rect(x, y, w, h, c) end) end
local function outline_rect(x, y, w, h, c) pcall(function() draw.outline_rect(x, y, w, h, c) end) end
local function text_at(s, x, y, c) pcall(function() draw.text(s, x, y, c) end) end

-- Title, sub-line, accent key, and whether this is a (steady) result flash.
-- Returns nil to draw nothing this frame.
local function lines_for(status)
    local name = config.display_name or "Neuro"
    local NAME = string.upper(name)
    local phase = status.phase
    if phase == "planning" then
        local dots = string.rep(".", 1 + (math.floor(_frame / 18) % 3))
        return NAME .. " IS HACKING", "planning route" .. dots, "cyan", false
    elseif phase == "busy" then
        local dots = string.rep(".", 1 + (math.floor(_frame / 18) % 3))
        return NAME .. " IS HACKING", "finishing another target" .. dots, "violet", false
    elseif phase == "jammed" then
        return "HACKING JAMMED", name .. " is waiting for the jammer to clear", "orange", false
    elseif phase == "paused" then
        -- is_result=true → steady (no breathing pulse / scan sweep), which reads
        -- as "frozen" and fits a paused game.
        return "HACK PAUSED", "waiting for the game to resume", "slate", true
    elseif phase == "executing" then
        local total = status.total or 0
        local n = math.min((status.executed or 0) + 1, math.max(total, 1))
        local sub = (total > 0)
            and string.format("executing move %d / %d", n, total)
            or "executing route"
        return NAME .. " IS HACKING", sub, "teal", false
    elseif phase == "resumed" then
        return NAME .. " IS HACKING", "resuming planned route", "teal", true
    elseif phase == "retrying" then
        return "PUZZLE CHANGED", name .. " is replanning", "amber", true
    elseif phase == "rerouting" then
        -- Fires for BOTH a wall-stop and an error-node reset (the precise
        -- outcome only reaches the tool result, not this flash), so keep the
        -- on-screen text outcome-neutral rather than asserting "hit a wall".
        return "REROUTING", name .. " got blocked - finding another way", "rose", true
    elseif phase == "success" then
        return "HACK COMPLETE", name .. " finished the hack", "green", true
    elseif phase == "failed" then
        return "HACK FAILED", "the hack was interrupted", "red", true
    end
    return nil
end


-- ---------------------------------------------------------------------------
-- Preferred path: large, crisp ImGui-window banner
-- ---------------------------------------------------------------------------

-- Estimate text width for centering. calc_text_size honors the pushed font;
-- fall back to a per-glyph estimate if it's unavailable.
local function im_text_width(s, per_char)
    local w = nil
    pcall(function()
        local sz = imgui.calc_text_size(s)
        if sz ~= nil then w = sz.x end
    end)
    if type(w) ~= "number" or w <= 0 then w = #s * per_char end
    return w
end

-- HUD-style decorative frame drawn around the banner with the `draw` API.
-- Everything is rendered OUTSIDE the window rect (or as an outer frame), so it
-- shows regardless of whether `draw` composites above or below ImGui windows —
-- the window's own background can never cover it. Echoes the hacking grid's
-- look: glowing frame, angular corner brackets, corner nodes, side ticks, a
-- data-callout line, and a traveling pulse dot.
local function draw_hud_frame(x, y, w, h, accent, pulse)
    if draw == nil then return end

    -- Faux depth: a dim "back face" offset down-right with corner connectors,
    -- so the panel reads as a slab with a bit of thickness rather than a flat
    -- rectangle (drawn first so the bright front frame sits on top of it).
    local dx, dy = 11, 8
    local back = with_alpha(accent, 60)
    outline_rect(x + dx, y + dy, w, h, back)
    pcall(function() draw.line(x,     y,     x + dx,     y + dy,     back) end)
    pcall(function() draw.line(x + w, y,     x + w + dx, y + dy,     back) end)
    pcall(function() draw.line(x,     y + h, x + dx,     y + h + dy, back) end)
    pcall(function() draw.line(x + w, y + h, x + w + dx, y + h + dy, back) end)

    -- Multi-layer animated outer glow.
    for i = 1, 6 do
        local a = math.floor((95 - i * 13) * (0.4 + 0.6 * pulse))
        if a > 0 then
            outline_rect(x - i * 2, y - i * 2, w + i * 4, h + i * 4, with_alpha(accent, a))
        end
    end
    -- Bright frame line hugging the window.
    outline_rect(x - 2, y - 2, w + 4, h + 4, with_alpha(accent, math.floor(200 + 55 * pulse)))

    -- Angular corner brackets just outside each corner.
    local bl, bt, o = 24, 3, 3
    filled_rect(x - o, y - o, bl, bt, accent);                  filled_rect(x - o, y - o, bt, bl, accent)
    filled_rect(x + w + o - bl, y - o, bl, bt, accent);         filled_rect(x + w + o - bt, y - o, bt, bl, accent)
    filled_rect(x - o, y + h + o - bt, bl, bt, accent);         filled_rect(x - o, y + h + o - bl, bt, bl, accent)
    filled_rect(x + w + o - bl, y + h + o - bt, bl, bt, accent); filled_rect(x + w + o - bt, y + h + o - bl, bt, bl, accent)

    -- Corner nodes (small dots at the outer corners).
    for _, corner in ipairs({ { x - o, y - o }, { x + w + o, y - o },
                              { x - o, y + h + o }, { x + w + o, y + h + o } }) do
        pcall(function() draw.filled_circle(corner[1], corner[2], 3, accent, 10) end)
    end

    -- Side ticks extending outward from the left/right edges.
    local dim = with_alpha(accent, 120)
    for _, fy in ipairs({ 0.32, 0.5, 0.68 }) do
        local ty = y + h * fy
        pcall(function() draw.line(x - 4, ty, x - 14, ty, dim) end)
        pcall(function() draw.line(x + w + 4, ty, x + w + 14, ty, dim) end)
    end

    -- Data-callout line off the top-right corner (echoes the grid's HUD lines).
    local cc = with_alpha(accent, 150)
    pcall(function() draw.line(x + w + o, y - o, x + w + o + 24, y - o - 16, cc) end)
    pcall(function() draw.line(x + w + o + 24, y - o - 16, x + w + o + 70, y - o - 16, cc) end)

    -- Traveling pulse dot along the top edge for motion.
    local px = x - 4 + ((_frame * 3) % (w + 8))
    pcall(function() draw.filled_circle(px, y - 4, 2, with_alpha(accent, 220), 8) end)
end


-- Returns true if the ImGui banner rendered cleanly, false on any failure
-- (caller then pins to the draw fallback).
local function draw_imgui_banner(x, y, w, h, title, sub, akey, is_result, pulse)
    draw_hud_frame(x, y, w, h, DRAW[akey], pulse)

    return pcall(function()
        imgui.set_next_window_pos({ x, y }, COND_ALWAYS)
        imgui.set_next_window_size({ w, h }, COND_ALWAYS)
        imgui.push_style_color(IMCOL_WINDOW_BG, DRAW.bg)
        imgui.push_style_color(IMCOL_BORDER, DRAW[akey])
        imgui.begin_window("##autohack_overlay", nil, OVERLAY_FLAGS)

        -- Blinking AUTO-HACK tag (top-left) — hammers home that it's automated.
        if is_result or (math.floor(_frame / 20) % 2) == 0 then
            imgui.set_cursor_pos({ 18, 8 })
            if _font_med then imgui.push_font(_font_med) end
            imgui.text_colored(">> AUTO-HACK", DRAW[akey])
            if _font_med then imgui.pop_font() end
        end

        -- Title — large, centered, accent-colored.
        if _font_big then imgui.push_font(_font_big) end
        local tw = im_text_width(title, 15)
        imgui.set_cursor_pos({ math.max(12, (w - tw) / 2), 32 })
        imgui.text_colored(title, DRAW[akey])
        if _font_big then imgui.pop_font() end

        -- Status sub-line — medium, centered, white.
        if _font_med then imgui.push_font(_font_med) end
        local sw2 = im_text_width(sub, 9)
        imgui.set_cursor_pos({ math.max(12, (w - sw2) / 2), 70 })
        imgui.text_colored(sub, DRAW.white)
        if _font_med then imgui.pop_font() end

        imgui.end_window()
        imgui.pop_style_color(2)
    end)
end


-- ---------------------------------------------------------------------------
-- Fallback path: fixed-font `draw` API banner
-- ---------------------------------------------------------------------------

local function text_bold(s, x, y, c)
    text_at(s, x + 2, y + 2, DRAW.shadow)
    text_at(s, x,     y,     c)
    text_at(s, x + 1, y,     c)
    text_at(s, x,     y + 1, c)
    text_at(s, x + 1, y + 1, c)
end

local function text_centered_bold(s, cx, y, c) text_bold(s, cx - (#s * 7) / 2, y, c) end

local function text_centered(s, cx, y, c)
    local x = cx - (#s * 7) / 2
    text_at(s, x + 1, y + 1, DRAW.shadow)
    text_at(s, x,     y,     c)
    text_at(s, x + 1, y,     c)
end

local function corner_brackets(x, y, w, h, len, thick, c)
    filled_rect(x, y, len, thick, c);                 filled_rect(x, y, thick, len, c)
    filled_rect(x + w - len, y, len, thick, c);       filled_rect(x + w - thick, y, thick, len, c)
    filled_rect(x, y + h - thick, len, thick, c);     filled_rect(x, y + h - len, thick, len, c)
    filled_rect(x + w - len, y + h - thick, len, thick, c)
    filled_rect(x + w - thick, y + h - len, thick, len, c)
end

local function draw_legacy_banner(x, y, w, h, title, sub, akey, is_result, pulse)
    if draw == nil then return end
    local accent = DRAW[akey]

    for i = 1, 4 do
        local a = math.floor((80 - i * 15) * (0.45 + 0.55 * pulse))
        if a > 0 then
            outline_rect(x - i * 2, y - i * 2, w + i * 4, h + i * 4, with_alpha(accent, a))
        end
    end
    filled_rect(x, y, w, h, DRAW.bg)
    filled_rect(x, y, 6, h, accent)
    outline_rect(x, y, w, h, with_alpha(accent, math.floor(180 + 75 * pulse)))
    outline_rect(x + 2, y + 2, w - 4, h - 4, with_alpha(accent, 110))
    corner_brackets(x, y, w, h, 20, 3, accent)
    if not is_result then
        local sweep = y + 8 + ((_frame * 2) % (h - 16))
        filled_rect(x + 10, sweep, w - 20, 1, with_alpha(accent, 55))
    end
    if is_result or (math.floor(_frame / 20) % 2) == 0 then
        text_bold(">> AUTO-HACK", x + 16, y + 10, accent)
    end
    local cx = x + w / 2
    text_centered_bold(title, cx, y + 38, accent)
    text_centered(sub, cx, y + 66, DRAW.white)
end


re.on_frame(function()
    _frame = _frame + 1

    if not config.hacking_show_overlay then return end

    local ok_status, status = pcall(observer.overlay_status)
    if not ok_status or status == nil or status.phase == "idle" then return end

    local title, sub, akey, is_result = lines_for(status)
    if title == nil then return end

    load_fonts()

    local sw, sh = screen_size()
    local banner_w, banner_h = BANNER_W, BANNER_H
    -- Center horizontally on x_fraction, clamped so it never runs off-screen.
    local x = sw * (config.hacking_overlay_x_fraction or 0.5) - banner_w / 2
    x = math.max(8, math.min(x, sw - banner_w - 8))
    local y = sh * (config.hacking_overlay_y_fraction or 0.08)

    -- Pulse 0..1. Steady (1.0) on a result flash; breathing while in progress.
    local pulse = is_result and 1.0 or (0.5 + 0.5 * math.sin(_frame * 0.12))

    -- Prefer the crisp, large ImGui-window banner; fall back to the fixed-font
    -- `draw` banner if ImGui/font isn't usable (or a render ever throws).
    local used_imgui = false
    if imgui ~= nil and _font_big ~= nil and not _imgui_failed then
        used_imgui = draw_imgui_banner(x, y, banner_w, banner_h, title, sub, akey, is_result, pulse)
        if not used_imgui then _imgui_failed = true end
    end
    if not used_imgui then
        draw_legacy_banner(x, y, banner_w, banner_h, title, sub, akey, is_result, pulse)
    end
end)


return M
