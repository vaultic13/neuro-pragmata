-- Peer action for the Stamp Club.
--
--   pragmata_stamps   the board on screen: a map of stamped / open / hidden
--                     cells, each cell's reward, the line bonuses, Cabin
--                     Coins, and the other boards
--
-- Visible only while the Cabin hub shows the Stamp Club tab
-- (action_gates.menu_open("stamps")). Formatting only: the reads go through
-- bindings/stamp_club.lua. Another board is reported by switching to it in
-- game; the off-screen boards' cells are not read.

local M = {}

local log = require("pragmata.util.log")

local stamps = nil              -- bindings/stamp_club.lua, set by register()

local COLUMNS = "ABCDEFGHIJ"

local function clean(text)
    return (tostring(text):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- "A1" for x = 0, y = 0: columns are letters, rows numbers, row 1 on top.
local function coord(x, y)
    if x == nil or y == nil then return "?" end
    local col = COLUMNS:sub(x + 1, x + 1)
    if col == "" then col = "#" .. tostring(x + 1) .. "-" end
    return col .. tostring(y + 1)
end

local function mark(cell)
    if cell.unlocked == true then return "[X]" end
    if cell.hidden then return "[?]" end
    return "[ ]"
end

local function grid_lines(b)
    local by_pos = {}
    local w, h = b.width or 0, b.height or 0
    for _, cell in ipairs(b.cells) do
        if cell.x ~= nil and cell.y ~= nil then
            by_pos[cell.y * 100 + cell.x] = cell
            if cell.x + 1 > w then w = cell.x + 1 end
            if cell.y + 1 > h then h = cell.y + 1 end
        end
    end
    local header = { "  " }
    for x = 0, w - 1 do header[#header + 1] = " " .. COLUMNS:sub(x + 1, x + 1) .. " " end
    local lines = { table.concat(header, " ") }
    for y = 0, h - 1 do
        local row = { string.format("%-2d", y + 1) }
        for x = 0, w - 1 do
            local cell = by_pos[y * 100 + x]
            row[#row + 1] = cell and mark(cell) or " - "
        end
        lines[#lines + 1] = table.concat(row, " ")
    end
    return lines
end

local function cell_line(cell)
    local s = "- " .. coord(cell.x, cell.y) .. " "
    if cell.hidden and cell.unlocked ~= true then
        s = s .. "hidden reward (" .. clean(cell.name or "???") .. ")"
    else
        s = s .. clean(cell.name or "an unnamed reward")
        if cell.hidden then s = s .. " (was a hidden reward)" end
    end
    s = s .. " - " .. (cell.unlocked == true and "stamped" or "not stamped yet")
    if cell.selected then s = s .. " (selected)" end
    if cell.unlocked ~= true and not cell.hidden and cell.description then
        s = s .. ": " .. clean(cell.description)
    end
    return s
end

local function board_text(b)
    local coin = b.coin_name or "Cabin Coin"
    local lines = {}
    lines[#lines + 1] = string.format("Stamp Club board %s%s.",
        b.name and ("'" .. clean(b.name) .. "'") or "(unnamed)",
        (b.width and b.height) and string.format(" (%dx%d)", b.width, b.height) or "")
    if b.lines_done and b.lines_max then
        local s = string.format("Lines completed: %d of %d", b.lines_done, b.lines_max)
        if b.line_filament and b.line_filament > 0 then
            s = s .. string.format(" (each line gives %d Filament)", b.line_filament)
        end
        lines[#lines + 1] = s .. "."
    end
    local stamped, total = 0, #b.cells
    for _, cell in ipairs(b.cells) do if cell.unlocked == true then stamped = stamped + 1 end end
    lines[#lines + 1] = string.format("Cells stamped: %d of %d. %s: %s; each cell costs %d.",
        stamped, total, coin, b.cabin_coins ~= nil and tostring(b.cabin_coins) or "unknown",
        b.cost_per_cell or 1)
    lines[#lines + 1] = "Map (row 1 at the top; [X] stamped, [ ] not yet, [?] hidden reward):"
    for _, l in ipairs(grid_lines(b)) do lines[#lines + 1] = l end
    lines[#lines + 1] = "Cells:"
    for _, cell in ipairs(b.cells) do lines[#lines + 1] = cell_line(cell) end
    if #b.bonuses > 0 then
        lines[#lines + 1] = "Bonuses:"
        for _, bo in ipairs(b.bonuses) do
            local s = "- " .. clean(bo.header or "Bonus")
            if bo.lines_needed then
                s = s .. string.format(" (%d line%s)", bo.lines_needed, bo.lines_needed > 1 and "s" or "")
            elseif bo.whole_board then
                s = s .. " (every cell)"
            end
            if bo.reward then s = s .. ": " .. clean(bo.reward) end
            s = s .. " - " .. (bo.earned == true and "earned" or "not earned yet")
            lines[#lines + 1] = s
        end
    end
    if #b.boards > 1 then
        local parts = {}
        for _, bd in ipairs(b.boards) do
            local s = bd.name and clean(bd.name) or ("board " .. tostring((bd.index or 0) + 1))
            if bd.shown then s = s .. " (on screen)"
            elseif bd.available == false then s = s .. " (locked)" end
            parts[#parts + 1] = s
        end
        lines[#lines + 1] = "Boards: " .. table.concat(parts, "; ") .. "."
    end
    return table.concat(lines, "\n")
end

local function stamps_action()
    if stamps == nil then return false, "the Stamp Club reader failed to load" end
    local ok, b = pcall(stamps.board)
    if not ok then
        log.warn("stamp_actions: board raised: " .. tostring(b))
        return false, "the Stamp Club board could not be read"
    end
    if b == nil then return false, "the Stamp Club is not open" end
    if #b.cells == 0 then return false, "the Stamp Club board has no cells to read yet" end
    return true, board_text(b)
end

function M.register(dispatcher, gates, binding)
    stamps = binding
    dispatcher.register("pragmata_stamps", {
        description = "Read the Stamp Club board on screen: a map of which cells are stamped, not yet stamped or hidden rewards, what each cell gives, lines completed and their bonuses, Cabin Coins held, and the other boards. Only available while the Stamp Club tab of the Cabin is open. Read-only.",
        schema = { type = "object" },
        available = gates.menu_open("stamps"),
        handler = function() return stamps_action() end,
    })
end

-- For Pragmata State Debug: the text the peer would get.
function M.debug_text()
    local ok, success, text = pcall(stamps_action)
    if not ok then return "RAISED: " .. tostring(success) end
    return string.format("[%s] %s", tostring(success), tostring(text))
end

return M
