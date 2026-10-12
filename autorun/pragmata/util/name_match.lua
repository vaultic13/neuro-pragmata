-- Name matching for the "info" actions (Shelter menus, catalogs).
--
-- An info call takes 1..MAX_NAMES names. Each is matched case-insensitively
-- against the entries' `name`: exact first, then as a unique substring. A
-- name that matches nothing, or several things, is answered as such rather
-- than dropped, so the peer can correct itself.

local M = {}

M.MAX_NAMES = 8

local function join(list, sep) return table.concat(list, sep or ", ") end

-- Returns a list of { entry = e } or { text = "..." } in request order.
function M.match(entries, names)
    local out = {}
    for _, want in ipairs(names) do
        local w = tostring(want):lower()
        local exact, partial = nil, {}
        for _, e in ipairs(entries) do
            local n = tostring(e.name or ""):lower()
            if n == w then exact = e break end
            if w ~= "" and n:find(w, 1, true) then partial[#partial + 1] = e end
        end
        if exact ~= nil then
            out[#out + 1] = { entry = exact }
        elseif #partial == 1 then
            out[#out + 1] = { entry = partial[1] }
        elseif #partial > 1 then
            local ns = {}
            for i = 1, math.min(#partial, 5) do ns[#ns + 1] = partial[i].name end
            out[#out + 1] = { text = string.format("'%s' matches several: %s. Give the full name.", want, join(ns)) }
        else
            out[#out + 1] = { text = string.format("Not found: '%s'.", want) }
        end
    end
    return out
end

-- The `names` argument, trimmed to MAX_NAMES; nil + reason when empty.
function M.names_arg(args)
    local names = {}
    if type(args) == "table" and type(args.names) == "table" then
        for _, n in ipairs(args.names) do
            if type(n) == "string" and n ~= "" then names[#names + 1] = n end
        end
    end
    if #names == 0 then return nil, "give at least one name in 'names'" end
    if #names > M.MAX_NAMES then
        local cut = {}
        for i = 1, M.MAX_NAMES do cut[i] = names[i] end
        names = cut
    end
    return names
end

-- How many valid names a "nothing matched" refusal lists.
local MAX_LISTED = 20

-- success, text: detail_fn(entry) for each match, the refusals in between.
-- When not one name matches, the call fails and lists names that would have,
-- so the peer's next try can succeed (BEST_PRACTICES.md: actionable errors).
function M.info_reply(entries, args, detail_fn, sep)
    local names, err = M.names_arg(args)
    if names == nil then return false, err end
    local parts, found = {}, 0
    for _, m in ipairs(M.match(entries, names)) do
        if m.entry then found = found + 1 end
        parts[#parts + 1] = m.entry and detail_fn(m.entry) or m.text
    end
    if found == 0 then
        local valid = {}
        for i = 1, math.min(#entries, MAX_LISTED) do valid[#valid + 1] = tostring(entries[i].name) end
        if #valid == 0 then
            parts[#parts + 1] = "There are no entries to name here yet."
        else
            parts[#parts + 1] = "Valid names" .. (#entries > MAX_LISTED
                and string.format(" (first %d of %d)", MAX_LISTED, #entries) or "")
                .. ": " .. join(valid) .. "."
        end
        return false, join(parts, sep or "\n")
    end
    return true, join(parts, sep or "\n")
end

function M.schema(what)
    return {
        type = "object",
        properties = {
            names = {
                type = "array",
                items = { type = "string" },
                minItems = 1,
                maxItems = M.MAX_NAMES,
                description = "Names of " .. what .. " exactly as the list action gives them (case does not matter; a unique part of a name also works).",
            },
        },
        required = { "names" },
    }
end

return M
