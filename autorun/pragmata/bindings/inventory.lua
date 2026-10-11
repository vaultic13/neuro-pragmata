--
-- Held items: currency, collectibles, consumables.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.InventoryManager (managed singleton)
--     - getItemIDs()               -> System.UInt32[]   every item id held
--     - getItemQuantity(UInt32)    -> System.Int32
--
-- Currency is not a separate wallet: app.MoneyData is just (MoneyID, Money),
-- i.e. an item id and an amount, and the game checks affordability with
-- InventoryManager.hasMoney(MoneyData). So currency is one more held item and
-- is read the same way as everything else.
--
-- Each id is named and categorised through object_names (the game's item
-- catalog for the localised name, app.ObjectIDs.Variety for the category), so
-- the split into currency / collectibles / other is the game's own taxonomy
-- rather than a list kept here.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")

local M = {}

local _s = { inited = false }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local inv = r.td("app.InventoryManager")
    _s.m_ids = r.method(inv, "getItemIDs()")
    _s.m_qty = r.method(inv, "getItemQuantity(System.UInt32)")
    if _s.m_ids == nil or _s.m_qty == nil then
        log.warn("inventory: InventoryManager item accessors unresolved")
    end
end

-- Returns nil outside gameplay, else a list of
--   { id, name, internal, kind, detail, quantity, named }
-- `detail` is the item page's header when it differs from `name`: the only
-- thing that tells apart distinct items the game gives the same name.
-- sorted by kind then name. Zero-quantity entries are dropped.
function M.read()
    ensure_init()
    local inv = r.singleton("app.InventoryManager")
    if inv == nil then return nil end
    local arr = r.call(_s.m_ids, inv)
    if arr == nil then return nil end

    local out = {}
    for _, id in ipairs(r.numbers(arr)) do
        local qty = r.to_int(r.call(_s.m_qty, inv, id))
        if qty ~= nil and qty > 0 then
            local info = object_names.resolve_object(id)
            out[#out + 1] = {
                id       = id,
                name     = info.label,
                internal = info.internal,
                kind     = info.kind,
                detail   = info.named and object_names.item_detail(id) or nil,
                quantity = qty,
                named    = info.named == true,
            }
        end
    end
    table.sort(out, function(a, b)
        if (a.kind or "") ~= (b.kind or "") then return (a.kind or "") < (b.kind or "") end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

-- Quantity of one item id, or nil. Used by the other state bindings.
function M.quantity(id)
    ensure_init()
    local inv = r.singleton("app.InventoryManager")
    if inv == nil or id == nil then return nil end
    return r.to_int(r.call(_s.m_qty, inv, id))
end

function M.debug_status()
    ensure_init()
    return {
        inventory_manager = r.singleton("app.InventoryManager") ~= nil,
        ids_ok            = _s.m_ids ~= nil,
        quantity_ok       = _s.m_qty ~= nil,
    }
end

return M
