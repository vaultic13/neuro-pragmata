-- Pragmata mod entrypoint (Phase 0).
--
-- Boots the file-mailbox transport, sends startup + actions/register to the
-- bridge via the Python sidecar, and pumps the inbox each frame to dispatch
-- incoming actions.
--
-- Deploy: copy the contents of mods/pragmata_lua/autorun/ into
-- <Pragmata>/reframework/autorun/.

-- Make pragmata/ submodules requireable. REFramework's autorun dir is on the
-- working path; we add it explicitly to be safe.
package.path = package.path .. ";reframework/autorun/?.lua;./reframework/autorun/?.lua"

local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local dispatcher = require("pragmata.dispatcher")

-- Dialogue capture binding. Pulls subtitle text from UI/Asset/ui2000/gui/ui2010
-- and forwards each new line to the AI as a silent context message.
require("pragmata.dialogue")

-- Ability state emitters. Polls binding state each frame; emits gauge/scan/
-- overdrive/auto-hack-unlock edges as context updates with appropriate lanes.
require("pragmata.ability_state")

-- World state emitters. Scene transitions, checkpoint reaches, combat start/end.
require("pragmata.world_state")

-- Autonomy nudges. No-op unless mod_config.autonomy_nudges is true; emits
-- in-combat ability hints on the transient lane while enabled.
require("pragmata.autonomy")

-- ====================================================================
-- GUI probe is loaded but DISABLED by default. Re-enable from the
-- in-game ImGui panel (Pragmata Probe -> Enable) when you want to do
-- more discovery, e.g. finding the speaker-name source. The dialogue
-- binding above doesn't depend on this.
-- ====================================================================
require("pragmata.probe_gui")  -- registers UI panel; remains disabled until clicked
-- ====================================================================

log.info("booting (Phase 1)")

-- --------------------------------------------------------------------
-- Phase 0 actions
-- --------------------------------------------------------------------

dispatcher.register("pragmata_ping", {
    description = "Phase 0 sanity check. Confirms the mod, sidecar, and bridge are wired up. Returns 'pong' as the result message.",
    -- Empty Lua tables encode ambiguously in some JSON encoders ([] vs {}).
    -- Plain {type = "object"} avoids that without losing meaning here.
    schema = { type = "object" },
    handler = function(_args)
        log.info("pragmata_ping called")
        return true, "pong"
    end,
})

-- --------------------------------------------------------------------
-- Phase 1 actions: Diana abilities
-- --------------------------------------------------------------------
-- Bindings live in spoiler-isolation under bindings/. Failures at load time
-- shouldn't take down the rest of the mod, so each is loaded via pcall and
-- the corresponding action returns a neutral failure if its binding is nil.

local function load_binding(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.error("failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local hacking_bind = load_binding("pragmata.bindings.hacking")
local scan_bind = load_binding("pragmata.bindings.scan")
local overdrive_bind = load_binding("pragmata.bindings.overdrive")

dispatcher.register("pragmata_scan", {
    description = "Have Diana scan the environment. Highlights nearby objectives, paths, and (with the Object Scan upgrade) pickups like REM disks, Upgrade Modules, Mods, and Pure Lunum. Fire-and-forget: scan results arrive as separate context updates.",
    schema = { type = "object" },
    handler = function(_args)
        if not scan_bind then return false, "scan binding not loaded" end
        return scan_bind.scan()
    end,
})

dispatcher.register("pragmata_auto_hack", {
    description = "Have Diana auto-hack a target. Consumes part of the hacking gauge to bypass the manual hacking minigame. Requires the Auto-Hack upgrade (unlocked mid-game from the Unit Printer). target_id is optional; if omitted, the currently locked-on target is used. Returns success on precondition pass; actual hack completion will be confirmed via subsequent context updates.",
    schema = {
        type = "object",
        properties = {
            target_id = {
                type = "string",
                description = "Optional. Identifier of the target to hack. Omit to use the currently locked-on target.",
            },
        },
    },
    handler = function(args)
        if not hacking_bind then return false, "hacking binding not loaded" end
        return hacking_bind.auto_hack(args.target_id)
    end,
})

dispatcher.register("pragmata_overdrive", {
    description = "Fire Diana's Overdrive Protocol. An AoE pulse that stuns and exposes the weak points of nearby enemies and grants Hugh a brief energy/Suit Integrity buffer. Requires the hacking gauge to be full. Unlocks during the Sector 1 boss fight.",
    schema = { type = "object" },
    handler = function(_args)
        if not overdrive_bind then return false, "overdrive binding not loaded" end
        return overdrive_bind.trigger()
    end,
})

-- --------------------------------------------------------------------
-- Boot + frame loop
-- --------------------------------------------------------------------

local started = false
local last_warn_frame = 0
local frame_counter = 0

re.on_frame(function()
    frame_counter = frame_counter + 1

    if not started then
        if mailbox.ensure_ready() then
            mailbox.send({ command = "startup", game = "Pragmata" })
            mailbox.send({
                command = "actions/register",
                game = "Pragmata",
                data = { actions = dispatcher.action_list() },
            })
            log.info("sent startup + actions/register")
            started = true
        else
            -- Throttle warning so we don't spam the log every frame
            if frame_counter - last_warn_frame > 600 then  -- ~10 sec at 60fps
                log.warn("mailbox dir not ready (create reframework/data/pragmata_mailbox/ and start sidecar)")
                last_warn_frame = frame_counter
            end
        end
        return
    end

    -- Drain inbox: process at most a few messages per frame to avoid hitches.
    for _ = 1, 8 do
        local msg = mailbox.recv()
        if msg == nil then break end
        dispatcher.handle_incoming(msg, mailbox.send)
    end
end)
