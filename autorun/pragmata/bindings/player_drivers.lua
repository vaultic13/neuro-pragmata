-- Live capture of per-player "driver" instances.
--
-- Several player abilities (Overdrive / wide FinishBlow, the hacking gauge,
-- auto-hack) are driven by objects that live on the player handle's driver
-- board, e.g. app.PlayerFinishBlowDriver and app.PlayerPuzzleControlDriver.
-- These are NOT managed singletons — `sdk.get_managed_singleton(...)` returns
-- nil for them — and walking PlayerHandle -> Updater -> DriverBoard ->
-- findDriver<T> from REFramework is unreliable (generic-instantiated overloads
-- don't dispatch cleanly).
--
-- The reliable approach is the same one the puzzle_snake binding already uses
-- for app.PuzzleSnake: hook a per-frame lifecycle method on the driver type and
-- cache `this`. The driver ticks every frame while it exists, so the cache
-- stays fresh and re-populates automatically after a scene reload.
--
-- Public API:
--   M.want(type_name)  -- register interest + install the capture hook (idempotent)
--   M.get(type_name)   -- live captured instance, or nil
--   M.debug_status()   -- { [type_name] = { hook = <state>, captured = <bool> } }

local log = require("pragmata.util.log")

local M = {}

-- type_name -> last captured instance (REManagedObject handle)
local _captured = {}
-- type_name -> "installed" | "pending" | "<failure reason>"
local _hook_state = {}

-- Update-ish methods to try, in order. We only need ONE to fire each frame to
-- keep a fresh reference; onUpdate is present on the player drivers we target.
local UPDATE_SIGS = {
    "onUpdate", "onUpdate()",
    "onLateUpdate", "onLateUpdate()",
    "update", "update()",
    "onStart", "onStart()",
    "onAwake", "onAwake()",
}


local function _is_live(inst)
    if inst == nil then return false end
    local ok = pcall(function() return inst:get_type_definition() end)
    return ok
end


local function _install(type_name)
    if _hook_state[type_name] ~= nil then return end  -- already attempted
    _hook_state[type_name] = "pending"

    local td = nil
    local ok_td = pcall(function() td = sdk.find_type_definition(type_name) end)
    if not ok_td or td == nil then
        _hook_state[type_name] = "type def not found"
        log.warn("player_drivers: type def not found: " .. tostring(type_name))
        return
    end

    -- First resolvable update-ish method wins.
    local m = nil
    for _, sig in ipairs(UPDATE_SIGS) do
        local ok, found = pcall(function() return td:get_method(sig) end)
        if ok and found ~= nil then
            m = found
            break
        end
    end
    if m == nil then
        _hook_state[type_name] = "no hookable update method"
        log.warn("player_drivers: no update method to hook on " .. tostring(type_name))
        return
    end

    local ok_hook, err = pcall(function()
        sdk.hook(
            m,
            function(args)
                -- pre-hook: args[2] is `this` (matches the puzzle_snake hooks).
                local ok_i, inst = pcall(function() return sdk.to_managed_object(args[2]) end)
                if ok_i and inst ~= nil then _captured[type_name] = inst end
            end,
            function(retval) return retval end
        )
    end)
    if ok_hook then
        _hook_state[type_name] = "installed"
        log.info("player_drivers: capture hook installed on " .. tostring(type_name))
    else
        _hook_state[type_name] = "hook failed: " .. tostring(err)
        log.warn("player_drivers: hook failed on " .. tostring(type_name)
              .. ": " .. tostring(err))
    end
end


-- Register interest in a driver type and install its capture hook. Safe to
-- call repeatedly; only the first call installs.
function M.want(type_name)
    _install(type_name)
end


-- Return the live captured instance for `type_name`, or nil. Falls back to a
-- managed-singleton lookup just in case a future build registers it (harmless
-- when it doesn't).
function M.get(type_name)
    local inst = _captured[type_name]
    if _is_live(inst) then return inst end
    _captured[type_name] = nil

    local ok, s = pcall(function() return sdk.get_managed_singleton(type_name) end)
    if ok and s ~= nil then
        _captured[type_name] = s
        return s
    end
    return nil
end


function M.debug_status()
    local out = {}
    for name, state in pairs(_hook_state) do
        out[name] = { hook = state, captured = _is_live(_captured[name]) }
    end
    return out
end


return M
