-- pragmata_enviro_hack_sequence's registration.
--
-- The sequence hack is shown to the peer as one of five tested groups
-- (mod_config.puzzle_sequence_group; util/puzzle_render.lua has the table). The
-- group decides not only the state text but the action's description and its
-- schema -- the letter groups answer with a `buttons` array, the list groups
-- with `order`.

local render = require("pragmata.util.puzzle_render")

local M = {}

M.ACTION_NAME = "pragmata_enviro_hack_sequence"

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

return M
