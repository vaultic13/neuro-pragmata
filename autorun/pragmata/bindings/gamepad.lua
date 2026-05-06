-- Generic GamePad input injection via via.hid.GamePadDevice.
--
-- The RE Engine exposes a "hijack mode" on its GamePadDevice that lets a
-- caller drive the device's button state directly. With hijack on, the
-- engine's input pipeline reads our writes instead of (or layered over)
-- real controller input. This is the documented mechanism for input mods.
--
-- Why this binding exists: it was developed as a fallback input path for
-- the hacking minigame (app.PuzzleSnake) before the direct Unit.move route
-- was working. The mod no longer uses it for puzzle input — Unit.move with
-- engine-supplied via.Int2 wrappers turned out to be reliable — but the
-- generic press queue is left in place for any future mod use that needs
-- to synthesize controller input.
--
-- API:
--   M.is_initialized() -> bool
--   M.get_init_error() -> string|nil
--   M.queue_press(btn_name, opts?) -> ok, err
--       Queues a button press. btn_name matches via.hid.GamePadButton field
--       names (e.g. "RUp", "RDown", "RLeft", "RRight"). opts can carry:
--           hold_frames        - how many frames to hold the button (default 3)
--           post_delay_frames  - frames to idle after release before next
--                                queue item processes (default 20). Lets the
--                                cursor finish its cell-transition animation
--                                before we issue the next press.
--   M.tick()
--       Per-frame entry. Caller (pragmata_main.lua re.on_frame) calls every
--       frame. Drives the press state machine.
--   M.queue_size() / M.is_busy() / M.clear_queue() / M.release_now()
--   M.status() -> snapshot for the debug panel
--
-- Direction → face-button mapping for the puzzle minigame is the caller's
-- responsibility (this module is generic). For reference, on Xbox layout:
--   X (left  face) = RLeft
--   Y (top   face) = RUp
--   B (right face) = RRight
--   A (bottom face) = RDown
-- which the puzzle interprets as left/up/right/down respectively.

local M = {}

-- ---------------------------------------------------------------------------
-- Cached SDK lookups
-- ---------------------------------------------------------------------------

local _inited = false
local _resolve_err = nil

local _gamepad_td        -- via.hid.GamePad        (static device manager)
local _device_td         -- via.hid.GamePadDevice  (instance with button state)
local _button_td         -- via.hid.GamePadButton  (enum)

local _m_get_device      -- static
local _m_get_merged      -- static (fallback)
local _m_set_hijack
local _m_get_hijack
local _m_set_button
local _m_set_button_down
local _m_set_button_up
local _m_get_button_down -- for capturing the idle "no buttons" enum value

-- Cached enum values (REFramework-side wrappers), keyed by name.
local _button_values = {}
-- Cached integer representations of each button enum value, keyed by name.
-- Used for OR-combining into the device's button mask.
local _button_ints = {}

-- The engine's "nothing pressed" enum value. Captured at runtime by reading
-- get_ButtonDown when no button is held (the assumption is reasonable: the
-- panel button only fires when the user is interacting with the panel, not
-- mashing the controller). Cached after first capture.
local _idle_value = nil

local function ensure_init()
    if _inited then return _resolve_err == nil end
    _inited = true

    local function fail(msg)
        _resolve_err = msg
        return false
    end

    _gamepad_td = sdk.find_type_definition("via.hid.GamePad")
    if not _gamepad_td then return fail("via.hid.GamePad type def not found") end

    _device_td = sdk.find_type_definition("via.hid.GamePadDevice")
    if not _device_td then return fail("via.hid.GamePadDevice type def not found") end

    _button_td = sdk.find_type_definition("via.hid.GamePadButton")
    if not _button_td then return fail("via.hid.GamePadButton type def not found") end

    _m_get_device = _gamepad_td:get_method("get_Device")
    _m_get_merged = _gamepad_td:get_method("get_MergedDevice")

    _m_set_hijack = _device_td:get_method("set_HijackMode(System.Boolean)")
    _m_get_hijack = _device_td:get_method("get_HijackMode")

    _m_set_button      = _device_td:get_method("set_Button(via.hid.GamePadButton)")
    _m_set_button_down = _device_td:get_method("set_ButtonDown(via.hid.GamePadButton)")
    _m_set_button_up   = _device_td:get_method("set_ButtonUp(via.hid.GamePadButton)")
    _m_get_button_down = _device_td:get_method("get_ButtonDown")

    if not _m_get_device      then return fail("get_Device method not resolvable") end
    if not _m_set_hijack      then return fail("set_HijackMode method not resolvable") end
    if not _m_set_button      then return fail("set_Button method not resolvable") end
    if not _m_set_button_down then return fail("set_ButtonDown method not resolvable") end

    _resolve_err = nil
    return true
end

-- Convert any value REFramework hands back (number, enum wrapper, etc.) to
-- a plain integer. Returns nil if the value can't be reduced to one.
local function value_to_int(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, n = pcall(function() return sdk.to_int64(v) end)
    if ok and type(n) == "number" then return n end
    local ok2, n2 = pcall(function() return v:get_field("value__") end)
    if ok2 and type(n2) == "number" then return n2 end
    return nil
end

local function get_button_value(name)
    if _button_values[name] ~= nil then return _button_values[name] end
    if not ensure_init() then return nil end
    local ok, f = pcall(function() return _button_td:get_field(name) end)
    if not ok or f == nil then return nil end
    local ok2, v = pcall(function() return f:get_data(nil) end)
    if not ok2 then return nil end
    _button_values[name] = v
    -- Also cache the integer form for OR-combining.
    local n = value_to_int(v)
    if n ~= nil then _button_ints[name] = n end
    return v
end

local function get_button_int(name)
    if _button_ints[name] ~= nil then return _button_ints[name] end
    -- Force the wrapper to materialize, which populates _button_ints.
    get_button_value(name)
    return _button_ints[name]
end

-- Bitwise OR for non-negative integers. Avoids relying on Lua 5.3+ `|`
-- syntax or LuaJIT bit module — REFramework's Lua version varies across
-- builds, so we do it explicitly.
local function bor(a, b)
    if a == 0 then return b end
    if b == 0 then return a end
    if bit32 and bit32.bor then return bit32.bor(a, b) end
    if bit and bit.bor then return bit.bor(a, b) end
    local result = 0
    local p = 1
    for _ = 1, 32 do
        if (a % 2) == 1 or (b % 2) == 1 then result = result + p end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        p = p * 2
    end
    return result
end

local function get_active_device()
    if not ensure_init() then return nil end
    local ok, dev = pcall(function() return _m_get_device:call(nil) end)
    if ok and dev ~= nil then return dev end
    if _m_get_merged ~= nil then
        local ok2, dev2 = pcall(function() return _m_get_merged:call(nil) end)
        if ok2 and dev2 ~= nil then return dev2 end
    end
    return nil
end

-- Resolve the engine's "nothing pressed" enum value. Prefer the static
-- `None` field on via.hid.GamePadButton (a stable engine constant); fall
-- back to a runtime read of get_ButtonDown if that field is unreadable.
-- The runtime fallback assumes the user isn't actively holding a button at
-- capture time, so prefer the constant when possible.
local function capture_idle_value(dev)
    if _idle_value ~= nil then return _idle_value end
    local v = get_button_value("None")
    if v ~= nil then
        _idle_value = v
        return v
    end
    if _m_get_button_down ~= nil and dev ~= nil then
        local ok, runtime_v = pcall(function() return _m_get_button_down:call(dev) end)
        if ok then
            _idle_value = runtime_v
            return runtime_v
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Press queue + state machine
-- ---------------------------------------------------------------------------

local _queue = {}     -- list of { btn_name, hold_frames, post_delay_frames }
local _current = nil  -- { btn_name, hold_frames, post_delay_frames, frame }
local _hijack_on = false

-- Last error from a write (for the debug panel).
local _last_write_err = nil

local function safe_call(method, dev, value)
    if method == nil or dev == nil then return false, "nil method/dev" end
    local ok, err = pcall(function() method:call(dev, value) end)
    if not ok then
        _last_write_err = tostring(err)
        return false, err
    end
    return true
end

-- Read the device's current Button mask as a plain integer. Used to snapshot
-- real player input before we flip on hijack mode, so we can preserve held
-- buttons (notably the trigger that keeps the hack alive) by OR-ing them
-- back into our writes for the duration of the press.
local _m_get_button_for_snapshot = nil
local function snapshot_real_button(dev)
    if dev == nil then return 0 end
    if _m_get_button_for_snapshot == nil then
        _m_get_button_for_snapshot = _device_td:get_method("get_Button")
    end
    if _m_get_button_for_snapshot == nil then return 0 end
    local ok, v = pcall(function() return _m_get_button_for_snapshot:call(dev) end)
    if not ok then return 0 end
    return value_to_int(v) or 0
end

local function set_hijack(dev, on)
    if not ensure_init() then return false end
    if dev == nil then return false end
    local target = on and true or false
    local ok, err = pcall(function() _m_set_hijack:call(dev, target) end)
    if ok then
        _hijack_on = target
    else
        _last_write_err = "hijack: " .. tostring(err)
    end
    return ok
end

function M.is_initialized()
    ensure_init()
    return _resolve_err == nil
end

function M.get_init_error()
    ensure_init()
    return _resolve_err
end

function M.queue_press(btn_name, opts)
    if not ensure_init() then return false, _resolve_err end
    opts = opts or {}
    local v = get_button_value(btn_name)
    if v == nil then return false, "unknown button: " .. tostring(btn_name) end
    -- opts.also_press: optional list of additional button names whose bits
    -- get OR'd in alongside btn_name on every frame of the press (both for
    -- the held mask and the just-pressed mask). Use this when a face button
    -- carries a paired semantic bit that the consumer gates on — e.g. on
    -- this build, A = RDown(32) + Decide(131072) and B = RRight(128) +
    -- Cancel(262144) when the player presses the physical button. Without
    -- the semantic bit, the puzzle's input handler may ignore the press.
    table.insert(_queue, {
        btn_name           = btn_name,
        hold_frames        = opts.hold_frames or 3,
        post_delay_frames  = opts.post_delay_frames or 20,
        also_press         = opts.also_press,
    })
    return true
end

function M.queue_size()
    return #_queue
end

function M.is_busy()
    return _current ~= nil or #_queue > 0
end

function M.clear_queue()
    _queue = {}
end

function M.release_now()
    if not ensure_init() then return end
    -- Drop all injected bits immediately. The hooks check these on every
    -- call, so resetting them here stops further injection without having
    -- to wait for the state machine to reach its release frame.
    _inject_button_bits = 0
    _inject_button_down_bits = 0
    _current = nil
end

-- ---------------------------------------------------------------------------
-- Post-hook delivery: OR injection bits into get_Button / get_ButtonDown
-- return values. The puzzle queries these (per the panel readback) and our
-- hook layers our bits on top of real input, every call, no matter how
-- often the engine re-polls hardware. This avoids the hijack-mode race
-- where set_Button writes get overwritten on the next input poll.
-- ---------------------------------------------------------------------------

local _inject_button_bits = 0       -- bits OR'd into get_Button this frame
local _inject_button_down_bits = 0  -- bits OR'd into get_ButtonDown this frame
local _hooks_installed = false
local _hook_install_err = nil
-- "int" returns the raw Lua int from post-hooks; "to_ptr" wraps it via
-- sdk.to_ptr. Different REFramework builds want different forms for
-- value-type enum returns. Toggle this at runtime via the panel if "int"
-- doesn't deliver.
local _hook_modify_strategy = "int"

function M.set_hook_modify_strategy(s)
    if s == "int" or s == "to_ptr" then
        _hook_modify_strategy = s
        return true
    end
    return false
end

function M.get_hook_modify_strategy()
    return _hook_modify_strategy
end

local function install_input_hooks()
    if _hooks_installed then return true end
    if not ensure_init() then return false end

    local m_get_button = _device_td:get_method("get_Button")
    local m_get_button_down = _device_td:get_method("get_ButtonDown")

    if m_get_button == nil or m_get_button_down == nil then
        _hook_install_err = "get_Button or get_ButtonDown method not resolvable"
        return false
    end

    -- Post-hook delivery: receives the engine's computed return value and
    -- returns a (possibly modified) replacement. We proved earlier that
    -- REFramework accepts a raw Lua int for via.hid.GamePadButton method
    -- args (set_Button writes landed on the device), so symmetrically the
    -- same int form should work for enum returns. If a particular build
    -- needs sdk.to_ptr wrapping, hook_modify_strategy below switches it.
    local function modify_return(retval, new_int)
        if _hook_modify_strategy == "to_ptr" then
            return sdk.to_ptr(new_int)
        end
        return new_int
    end

    local ok1, err1 = pcall(function()
        sdk.hook(m_get_button, nil, function(retval)
            if _inject_button_bits == 0 then return retval end
            local current = value_to_int(retval) or 0
            return modify_return(retval, bor(current, _inject_button_bits))
        end)
    end)
    if not ok1 then
        _hook_install_err = "hook get_Button failed: " .. tostring(err1)
        return false
    end

    local ok2, err2 = pcall(function()
        sdk.hook(m_get_button_down, nil, function(retval)
            if _inject_button_down_bits == 0 then return retval end
            local current = value_to_int(retval) or 0
            return modify_return(retval, bor(current, _inject_button_down_bits))
        end)
    end)
    if not ok2 then
        _hook_install_err = "hook get_ButtonDown failed: " .. tostring(err2)
        return false
    end

    _hooks_installed = true
    return true
end

function M.hooks_status()
    return {
        installed = _hooks_installed,
        error     = _hook_install_err,
    }
end

function M.tick()
    if not ensure_init() then return end
    install_input_hooks()  -- idempotent; runs once

    -- Pull next press from queue if idle.
    if _current == nil then
        if #_queue == 0 then
            _inject_button_bits = 0
            _inject_button_down_bits = 0
            return
        end
        _current = table.remove(_queue, 1)
        _current.frame = 0
    end

    local btn_int = get_button_int(_current.btn_name)
    if btn_int == nil then
        _last_write_err = "no int value for " .. tostring(_current.btn_name)
        _current = nil
        _inject_button_bits = 0
        _inject_button_down_bits = 0
        return
    end

    -- also_press: extra bits on top of btn_int (e.g. Decide for A, Cancel
    -- for B). Combined into BOTH the held mask and the just-pressed mask.
    local also_bits = 0
    if _current.also_press then
        for _, name in ipairs(_current.also_press) do
            local v = get_button_int(name)
            if v then also_bits = bor(also_bits, v) end
        end
    end
    local press_bits = bor(btn_int, also_bits)

    local f = _current.frame
    local hold = _current.hold_frames
    local total = hold + 2 + (_current.post_delay_frames or 0)

    -- Timeline (post-hook delivery — no hijack, no device writes):
    --   f == 0:        held = press_bits, just-pressed = press_bits
    --   f == 1:        held = press_bits, just-pressed = 0 (one-frame edge)
    --   1 < f < hold:  held = press_bits, just-pressed = 0
    --   f >= hold:     held = 0, just-pressed = 0 (released)
    --   f >= total:    done — pop next from queue
    if f == 0 then
        _inject_button_bits = press_bits
        _inject_button_down_bits = press_bits
    elseif f == 1 then
        _inject_button_bits = press_bits
        _inject_button_down_bits = 0
    elseif f < hold then
        _inject_button_bits = press_bits
        _inject_button_down_bits = 0
    else
        _inject_button_bits = 0
        _inject_button_down_bits = 0
    end

    if f >= total then
        _current = nil
        return
    end

    _current.frame = f + 1
end

function M.status()
    ensure_init()
    return {
        initialized          = _resolve_err == nil,
        init_error           = _resolve_err,
        hooks_installed      = _hooks_installed,
        hook_install_err     = _hook_install_err,
        queue_size           = #_queue,
        busy                 = M.is_busy(),
        last_write_err       = _last_write_err,
        inject_button_bits      = _inject_button_bits,
        inject_button_down_bits = _inject_button_down_bits,
        current = _current and {
            btn               = _current.btn_name,
            frame             = _current.frame,
            hold_frames       = _current.hold_frames,
            post_delay_frames = _current.post_delay_frames,
            also_press        = _current.also_press,
        } or nil,
    }
end

-- Live readback of device state. For diagnostics: lets the panel show what
-- the engine actually has on the device right now, so the user can compare
-- "real button press" vs "our injection" reads.
local _m_get_button = nil
function M.live_readback()
    if not ensure_init() then return nil end
    local dev = get_active_device()
    if dev == nil then return { error = "no device" } end

    if _m_get_button == nil then
        _m_get_button = _device_td:get_method("get_Button")
    end

    local function as_int_str(v)
        if v == nil then return "<nil>" end
        if type(v) == "number" then return string.format("%d (0x%x)", v, v) end
        if type(v) == "boolean" then return tostring(v) end
        local ok_i, n = pcall(function() return sdk.to_int64(v) end)
        if ok_i and type(n) == "number" then
            return string.format("%d (0x%x)", n, n)
        end
        local ok_f, n2 = pcall(function() return v:get_field("value__") end)
        if ok_f and type(n2) == "number" then
            return string.format("%d (0x%x)", n2, n2)
        end
        return tostring(v)
    end

    local function safe_get(method)
        if method == nil then return "(no method)" end
        local ok, v = pcall(function() return method:call(dev) end)
        if not ok then return "ERR: " .. tostring(v) end
        return as_int_str(v)
    end

    local function safe_get_bool(method)
        if method == nil then return "(no method)" end
        local ok, v = pcall(function() return method:call(dev) end)
        if not ok then return "ERR: " .. tostring(v) end
        return tostring(v)
    end

    return {
        button       = safe_get(_m_get_button),
        button_down  = safe_get(_m_get_button_down),
        hijack_mode  = safe_get_bool(_m_get_hijack),
        idle_value   = _idle_value and (function()
            local ok, n = pcall(function() return sdk.to_int64(_idle_value) end)
            if ok and type(n) == "number" then
                return string.format("%d (0x%x)", n, n)
            end
            return tostring(_idle_value)
        end)() or "<not captured>",
    }
end

-- Resolve a button name to its raw integer value (for diagnostics).
function M.button_value_int(btn_name)
    local v = get_button_value(btn_name)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, n = pcall(function() return sdk.to_int64(v) end)
    if ok and type(n) == "number" then return n end
    local ok_f, n2 = pcall(function() return v:get_field("value__") end)
    if ok_f and type(n2) == "number" then return n2 end
    return nil
end

return M
