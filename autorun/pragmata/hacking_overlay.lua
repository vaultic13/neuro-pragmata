-- On-screen "Vera is hacking" overlay.
--
-- Problem this solves: when the AI peer (Vera) drives a hack, from the
-- player's seat it just looks like the player is hacking unusually slowly —
-- there's no signal that the AI is the one moving the cursor. This draws a
-- prominent banner over the game while a hack is in progress so it's obvious
-- Vera is hacking, and shows how far along she is.
--
-- Rendering uses REFramework's `draw` API (a 2D overlay drawn every frame,
-- independent of the REFramework menu). If a build doesn't expose `draw`,
-- this module silently no-ops. Every draw call is wrapped so a missing
-- primitive or signature mismatch can never take down the frame loop.
--
-- Phases come from hacking_observer.overlay_status():
--   planning  -> "VERA IS HACKING / planning route..."
--   executing -> "VERA IS HACKING / move N / M"
--   success   -> brief "HACK COMPLETE" flash
--   failed    -> brief "HACK FAILED" flash

local M = {}

local config   = require("pragmata.mod_config")
local observer = require("pragmata.hacking_observer")

-- ImGui packs ImU32 colors as 0xAABBGGRR (R is the low byte). LuaJIT has no
-- `<<` operator, so build the value arithmetically.
local function rgba(r, g, b, a)
    a = a or 255
    return a * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

-- Replace the alpha byte of an existing color, keeping its RGB.
local function with_alpha(color, a)
    return a * 0x1000000 + (color % 0x1000000)
end

local COL_BG    = rgba(8, 10, 18, 210)     -- near-opaque dark panel
local COL_WHITE = rgba(240, 240, 240, 255)
local COL_CYAN  = rgba(80, 220, 255, 255)  -- in-progress accent ("Vera")
local COL_GREEN = rgba(90, 230, 130, 255)  -- success
local COL_RED   = rgba(255, 80, 80, 255)   -- failed

local _frame = 0

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

-- Individually-guarded draw primitives so a missing one degrades gracefully
-- instead of skipping the whole banner.
local function filled_rect(x, y, w, h, c) pcall(function() draw.filled_rect(x, y, w, h, c) end) end
local function outline_rect(x, y, w, h, c) pcall(function() draw.outline_rect(x, y, w, h, c) end) end
local function text_at(s, x, y, c) pcall(function() draw.text(s, x, y, c) end) end

-- Rough text width for the default ImGui font (~7px/glyph). Used only for
-- horizontal centering; being a few px off is invisible.
local function text_centered(s, cx, y, color)
    local x = cx - (#s * 7) / 2
    text_at(s, x, y, color)
    text_at(s, x + 1, y, color)  -- 1px overdraw = faux-bold
end

-- Title, sub-line, accent color, and whether this is a (steady) result flash.
-- Returns nil to draw nothing this frame.
local function lines_for(status)
    local phase = status.phase
    if phase == "planning" then
        local dots = string.rep(".", 1 + (math.floor(_frame / 18) % 3))
        return "VERA IS HACKING", "planning route" .. dots, COL_CYAN, false
    elseif phase == "executing" then
        local total = status.total or 0
        local n = math.min((status.executed or 0) + 1, math.max(total, 1))
        local sub = (total > 0)
            and string.format("executing move %d / %d", n, total)
            or "executing route"
        return "VERA IS HACKING", sub, COL_CYAN, false
    elseif phase == "success" then
        return "HACK COMPLETE", "Vera finished the hack", COL_GREEN, true
    elseif phase == "failed" then
        return "HACK FAILED", "the hack was interrupted", COL_RED, true
    end
    return nil
end


re.on_frame(function()
    _frame = _frame + 1

    if not config.hacking_show_overlay then return end
    if draw == nil then return end  -- build doesn't expose the 2D draw API

    local ok_status, status = pcall(observer.overlay_status)
    if not ok_status or status == nil or status.phase == "idle" then return end

    local title, sub, accent, is_result = lines_for(status)
    if title == nil then return end

    local sw, sh = screen_size()
    local banner_w, banner_h = 440, 66
    -- Center horizontally on x_fraction (default: over the right third, where
    -- the hacking grid appears), clamped so it never runs off-screen.
    local x = sw * (config.hacking_overlay_x_fraction or 0.83) - banner_w / 2
    x = math.max(8, math.min(x, sw - banner_w - 8))
    local y = sh * (config.hacking_overlay_y_fraction or 0.10)
    local cx = x + banner_w / 2

    -- Dark panel.
    filled_rect(x, y, banner_w, banner_h, COL_BG)

    -- Border: pulsing while in progress, steady on a result flash.
    local pulse = is_result and 1.0 or (0.55 + 0.45 * math.sin(_frame * 0.12))
    local border = with_alpha(accent, math.floor(255 * pulse))
    outline_rect(x, y, banner_w, banner_h, border)
    outline_rect(x + 1, y + 1, banner_w - 2, banner_h - 2, border)

    -- Title in the accent color, sub-line in white.
    text_centered(title, cx, y + 12, accent)
    text_centered(sub, cx, y + 38, COL_WHITE)
end)


return M
