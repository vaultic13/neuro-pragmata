-- pragmata_enviro_hack_sequence's registration, and switching its group at runtime.
--
-- The sequence hack is shown to the peer as one of five tested groups
-- (mod_config.puzzle_sequence_group; util/puzzle_render.lua has the table). The
-- group decides not only the state text but the action's description and its
-- schema -- the letter groups answer with a `buttons` array, the list groups
-- with `order` -- so switching it means re-registering the action, not just
-- rendering differently.
--
-- Neuro-SDK ignores a register for a name that is already registered, so a
-- switch sends actions/unregister for the one action and then actions/register
-- with the full action list, carrying its new definition. The sidecar forwards
-- both verbatim.
--
-- A switch is refused while a sequence force is outstanding: the peer is
-- already answering in the old group's format, and its reply would be read
-- in the new one's.
--
-- Session only. Nothing here writes mod_config.lua; a restart is back on the
-- configured group.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local dispatcher = require("pragmata.dispatcher")
local render = require("pragmata.util.puzzle_render")

local M = {}

M.ACTION_NAME = "pragmata_enviro_hack_sequence"

-- The configured group, as it was at boot, so the panel can say whether the
-- active one came from the config or from a switch.
M.configured_group = render.sequence_group().number

-- Description and schema for the active group.
function M.definition()
    return {
        -- The group text is an experiment (puzzle_render); only the opening
        -- says which kind of hack this is, to tell it from the enemy grid.
        description = "Environment hack (a door, switch or elevator). " .. render.buttons_description(),
        -- mod_config.action_descriptions = "short": the group's description
        -- above then rides on the force as its rules (dispatcher.lua).
        short = "Solve the active sequence hack, an environment hack (a door, switch or elevator): answer with the presses the state field asks for.",
        schema = render.buttons_schema(),
    }
end

-- The payload key the handler reads the answer from, for the active group.
M.answer_field = render.buttons_answer_field

-- Switches to group `value` (its number or id) for this session. Returns ok and
-- a message saying what happened or why not.
function M.set_group(value)
    local group = render.find_sequence_group(value)
    if group == nil then
        return false, "no sequence group " .. tostring(value)
    end
    if render.sequence_group().number == group.number then
        return true, "group " .. group.number .. " is already active"
    end

    -- Through package.loaded rather than require: the observer loads after
    -- this module in some boot orders, and it is only needed once a force can
    -- exist at all.
    local observer = package.loaded["pragmata.hacking_observer"]
    local inflight = observer and observer.inflight and observer.inflight()
    if inflight ~= nil and inflight.kind == "buttons" and inflight.id ~= nil then
        return false, "a sequence force is waiting for its answer in the current group's "
            .. "format; switch once it is answered"
    end

    config.puzzle_sequence_group = group.number
    local def = M.definition()
    if not dispatcher.update(M.ACTION_NAME, def) then
        -- The sequence family is switched off, so the action was never
        -- registered. The group still applies if it is turned back on after a
        -- restart; nothing to announce now.
        log.info("sequence_action: group " .. group.number .. " set; the action is not registered")
        return true, "group " .. group.number .. " set (the sequence action is not registered)"
    end

    -- Unregister the one action, then register the full list (the reason the
    -- whole list goes out is in dispatcher.reannounce).
    dispatcher.reannounce({ M.ACTION_NAME })
    log.info("sequence_action: switched to group " .. group.number .. " (" .. group.id .. ")"
        .. (dispatcher.announced and ", re-registered with the peer" or ""))
    return true, "switched to group " .. group.number .. " (" .. group.id .. ")"
end

return M
