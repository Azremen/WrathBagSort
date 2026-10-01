WrathBagSort = WrathBagSort or {}
WrathBagSort_TESTING_MODE = false
-- WrathBagSort_Log is a newline-joined STRING so it saves as one readable block
-- in SaveVariables.lua (the client serializes Lua tables in arbitrary key order,
-- which made the old table-based log unreadable on disk). Migrate old data away.
if type(WrathBagSort_Log) ~= "string" then
    WrathBagSort_Log = ""
end
WrathBagSort_Settings = WrathBagSort_Settings or {}
if WrathBagSort_Settings.mode ~= "type" and WrathBagSort_Settings.mode ~= "name" and WrathBagSort_Settings.mode ~= "tier" then
    WrathBagSort_Settings.mode = "name"
end
if WrathBagSort_Settings.direction ~= "desc" then
    WrathBagSort_Settings.direction = "asc"
end

-- CreateFrame() is never reliably callable from addon Lua on this client (confirmed:
-- fails even as the very first statement in this file on a full client restart).
-- So we never create a new frame; the OnUpdate-based pacing needed for sorting
-- reuses the log window's frame (WrathBagSortLogFrame), which is defined in
-- WrathBagSortLog.xml. Per the .toc order WrathBagSortLog.xml loads AFTER this
-- file, but that's fine: this file only touches WrathBagSortLogFrame lazily at
-- sort time, by which point the XML-defined frame already exists, so we never
-- need to call CreateFrame.

local function Print(message)
    if WrathBagSort_TESTING_MODE ~= true then
        return
    end

    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[WrathBagSort]|r " .. message)
    end

    -- Guard against the old table format still being present (e.g. loaded after
    -- this file ran via VARIABLES_LOADED).
    if type(WrathBagSort_Log) ~= "string" then
        WrathBagSort_Log = ""
    end
    WrathBagSort_Log = WrathBagSort_Log .. message .. "\n"

    -- Cap to roughly the last ~500 lines (drop the oldest at a line boundary).
    if #WrathBagSort_Log > 50000 then
        local cutAt = string.find(WrathBagSort_Log, "\n", #WrathBagSort_Log - 40000, true)
        if cutAt then
            WrathBagSort_Log = string.sub(WrathBagSort_Log, cutAt + 1)
        end
    end

    if type(SaveVariables) == "function" then
        pcall(SaveVariables, "WrathBagSort_Log")
    end
end

local function DescribeValue(value)
    if value == nil then
        return "nil"
    end

    if type(value) == "string" then
        return '"' .. value .. '"'
    end

    return tostring(value)
end

local function CallGetter(getter, ...)
    if type(getter) ~= "function" then
        return false, "not a function"
    end

    local success, first, second, third, fourth, fifth, sixth = pcall(getter, ...)
    if not success then
        return false, first
    end

    return true, first, second, third, fourth, fifth, sixth
end

local function ProbeGlobals()
    local names = {
        "GetBagItemInfo",
        "GetBagCount",
        "GetBagItemCount",
        "GetBagItemLink",
        "PickupBagItem",
        "PutItemInBag",
        "MoveItem",
        "GetInventoryItemLink",
        "CreateFrame",
        "SlashCmdList",
        "CursorHasItem",
        "ClearCursor",
        "GetCursorInfo",
        "CursorItemType",
        "GetCursorItemInfo",
    }

    Print("loaded; API availability:")
    for index = 1, table.getn(names) do
        local name = names[index]
        Print("  " .. name .. " = " .. type(_G[name]))
    end
end

local function ProbeBag()
    -- Dump GetBagCount()'s full return list first. Its exact signature is
    -- ambiguous across this client's addons (some read the total slot count from
    -- the 2nd return, others from the 3rd), so showing every value here lets us
    -- settle that question empirically. Observed on a live client:
    -- GetBagCount() returns: 52, 60, 360, nil  (360 = total slots).
    local scanSlots = 240
    if type(GetBagCount) == "function" then
        local ok, a, b, c, d = pcall(GetBagCount)
        if ok then
            Print("GetBagCount() returns: " .. DescribeValue(a) .. ", " .. DescribeValue(b) .. ", " .. DescribeValue(c) .. ", " .. DescribeValue(d))
            local largest = 0
            for _, value in ipairs({a, b, c}) do
                if type(value) == "number" and value > largest then
                    largest = value
                end
            end
            if largest > 0 then
                scanSlots = largest
            end
        else
            Print("GetBagCount() errored: " .. tostring(a))
        end
    else
        Print("GetBagCount is unavailable")
    end

    local getter = _G.GetBagItemInfo
    if type(getter) ~= "function" then
        Print("GetBagItemInfo is unavailable; bag scan skipped")
        return
    end

    local readable = 0
    for slot = 1, scanSlots do
        local success, first, second, third, fourth, fifth, sixth = CallGetter(getter, slot)
        if success and first ~= nil then
            readable = readable + 1
            Print("slot " .. slot .. ": " .. DescribeValue(first) .. ", " .. DescribeValue(second) .. ", " .. DescribeValue(third) .. ", " .. DescribeValue(fourth) .. ", " .. DescribeValue(fifth) .. ", " .. DescribeValue(sixth))
        end
    end

    Print("bag scan finished; readable slots = " .. readable .. " (scanned 1.." .. scanSlots .. ")")
    Print("  (run /sortbag log to open a copyable version of this output)")
end

local function GetBagSlotCount()
    if type(GetBagCount) == "function" then
        local success, a, b, c = pcall(GetBagCount)
        if success then
            -- CONFIRMED via live /sortbag probe: GetBagCount() returns
            -- (occupied, ???, total) - e.g. "52, 60, 360" on a 12-bag backpack.
            -- The 3rd value is the total backpack slot count (matches zBag's
            -- ZBAG_MAXBAG = 360). Prefer it directly; if it's somehow absent
            -- (older API?), fall back to the largest positive number.
            if type(c) == "number" and c > 0 then
                return c
            end
            local largest = 0
            for _, value in ipairs({a, b, c}) do
                if type(value) == "number" and value > largest then
                    largest = value
                end
            end
            if largest > 0 then
                return largest
            end
        end
    end

    return 240
end

local function IsFlagSet(value)
    if value == true then
        return true
    end

    if type(value) == "string" then
        local lowered = string.lower(value)
        return lowered == "true" or lowered == "1"
    end

    return false
end

-- Reads the tooltip for a bag item and returns its left-column lines as a list
-- of { text = <string>, r/g/b = <color 0-1> }, or nil if the tooltip can't be
-- read. `bagIndex` must be GetBagItemInfo's first return value (NOT the raw UI
-- slot number) - SetBagItem silently fails/keeps stale content otherwise, which
-- is what caused every slot to be misdetected as "Item Shop" previously.
local function ReadTooltipLines(bagIndex)
    if type(GameTooltip) ~= "table" and type(GameTooltip) ~= "userdata" then
        return nil
    end
    if type(GameTooltip.SetBagItem) ~= "function" then
        return nil
    end

    local okOwner = pcall(function()
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
    end)
    if not okOwner then
        return nil
    end

    local okSet = pcall(GameTooltip.SetBagItem, GameTooltip, bagIndex)
    if not okSet then
        pcall(GameTooltip.Hide, GameTooltip)
        return nil
    end

    local name = GameTooltip:GetName()
    local lines = {}
    for i = 1, 40 do
        local left = _G[name .. "TextLeft" .. i]
        if not left then
            break
        end
        local text = left:GetText()
        if not text or text == "" then
            break
        end
        local r, g, b = 1, 1, 1
        if type(left.GetColor) == "function" then
            local ok, cr, cg, cb = pcall(left.GetColor, left)
            if ok and cr and cg and cb then
                r, g, b = cr, cg, cb
            end
        end
        lines[#lines + 1] = { text = text, r = r, g = g, b = b }
    end

    pcall(GameTooltip.Hide, GameTooltip)
    return lines
end

-- True if any tooltip line CONTAINS searchText (used for "Item Shop Item",
-- which may be prefixed/suffixed by other text).
local function TooltipContains(lines, searchText)
    if not lines then
        return false
    end
    for i = 1, #lines do
        if string.find(lines[i].text, searchText, 1, true) then
            return true
        end
    end
    return false
end

-- Extracts the item's category/type from tooltip lines, mirroring zBag's
-- BagSort.lua ParseItemDataFromLines: skip the name, bound/itemshop labels,
-- "Stacked Number: N", "Time till expiration", "Tier N", "Level N",
-- "Worth: N", "Durability ...", "Rune (n/m)", "Power Modifier ...", bare
-- numbers, short lines, and colored (green stat / blue flavor) lines; the first
-- remaining white (or red "unequipable") line is the type. Returns "" if none.
local function ExtractType(lines)
    local LABELS = {
        ["Current Equipment"] = true,
        ["Bound"] = true,
        ["Soulbound"] = true,
        ["Binds when equipped"] = true,
        ["Binds when used"] = true,
        ["Binds when picked up"] = true,
        ["Item Shop Item"] = true,
        ["Not dropped on PK death"] = true,
    }

    local function IsNonType(line)
        local text = line.text
        if LABELS[text] then return true end
        if text:match("^Stacked Number:") then return true end
        if text:match("^Time till expiration") then return true end
        if text:match("^Tier%s+%d") then return true end
        if text:match("^Level%s+%d") then return true end
        if text:match("^Worth:") then return true end
        if text:match("^Durability") then return true end
        if text:match("^Rune%s+%(") then return true end
        if text:match("^Power Modifier") then return true end
        if text:match("^x?%d+$") then return true end
        if #text < 2 then return true end

        -- Colored lines (green stats, blue flavor) are not the type. The type
        -- is white (normal) or red ("unequipable" error color).
        local isWhite = line.r > 0.99 and line.g > 0.99 and line.b > 0.99
        local isRed = line.r > 0.9 and line.g < 0.3 and line.b < 0.3
        if not (isWhite or isRed) then return true end

        return false
    end

    for i = 2, #lines do
        if not IsNonType(lines[i]) then
            return lines[i].text
        end
    end
    return ""
end

-- Extracts the item's tier number (from a "Tier N" line), or 0 if absent.
local function ExtractTier(lines)
    for i = 1, #lines do
        local tier = tonumber(string.match(lines[i].text, "^Tier%s+(%d+)"))
        if tier then
            return tier
        end
    end
    return 0
end

local function IsQuestItem(lines, itemType)
    if string.find(string.lower(itemType or ""), "quest", 1, true) then
        return true
    end
    for i = 2, #lines do
        if string.find(string.lower(lines[i].text or ""), "quest", 1, true) then
            return true
        end
    end
    return false
end

-- Diagnostic: dumps every tooltip line (left + right) for a UI slot, so the
-- "type" extraction in ExtractType can be verified/tuned against real items.
local function TooltipDump(uiSlot)
    uiSlot = tonumber(uiSlot)
    if not uiSlot then
        Print("usage: /sortbag tooltip <uiSlot>")
        return
    end

    local itemIndex = GetBagItemInfo(uiSlot)
    if not itemIndex then
        Print("slot " .. uiSlot .. " appears empty")
        return
    end

    if type(GameTooltip) ~= "table" and type(GameTooltip) ~= "userdata" then
        Print("GameTooltip is unavailable")
        return
    end

    pcall(function()
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
    end)
    local okSet = pcall(GameTooltip.SetBagItem, GameTooltip, itemIndex)
    if not okSet then
        Print("SetBagItem failed for itemIndex " .. tostring(itemIndex))
        return
    end

    local name = GameTooltip:GetName()
    Print("tooltip for slot " .. uiSlot .. " (itemIndex " .. tostring(itemIndex) .. "):")
    for i = 1, 40 do
        local left = _G[name .. "TextLeft" .. i]
        local right = _G[name .. "TextRight" .. i]
        local leftText = left and left:GetText() or ""
        local rightText = right and right:GetText() or ""
        if leftText == "" and rightText == "" then
            break
        end
        local colorTag = ""
        if left and type(left.GetColor) == "function" then
            local ok, r, g, b = pcall(left.GetColor, left)
            if ok and r and g and b then
                colorTag = string.format(" [rgb=%.2f,%.2f,%.2f]", r, g, b)
            end
        end
        Print("  L" .. i .. ": " .. DescribeValue(leftText) .. colorTag .. "  |  R" .. i .. ": " .. DescribeValue(rightText))
    end
    pcall(GameTooltip.Hide, GameTooltip)
end

local function IsBagPageAvailable(page)
    if page <= 2 then
        return true
    end
    if type(GetBagPageLetTime) ~= "function" then
        return false
    end
    local ok, rented, rentTime = pcall(GetBagPageLetTime, page)
    return ok and not (rented and rentTime == -1)
end

local function ReadOccupiedSlots()
    local slots = {}
    local total = GetBagSlotCount()
    local skippedItemShop = 0
    local lockedCount = 0
    local tooltipUnavailable = false
    local itemShopSlots = {}
    local lockedSlots = {}
    local pageAvailability = {}

    for slot = 1, total do
        local page = math.floor((slot - 1) / 30) + 1
        if pageAvailability[page] == nil then
            pageAvailability[page] = IsBagPageAvailable(page)
        end
        if not pageAvailability[page] then
            lockedSlots[slot] = true
        else
            local itemIndex, icon, name, itemCount, locked, itemQuality = GetBagItemInfo(slot)
            if icon and icon ~= "" and name and name ~= "" then
                if IsFlagSet(locked) then
                    lockedSlots[slot] = true
                    lockedCount = lockedCount + 1
                else
                    local lines = ReadTooltipLines(itemIndex)
                    if lines == nil then
                        tooltipUnavailable = true
                    elseif TooltipContains(lines, "Item Shop Item") then
                        skippedItemShop = skippedItemShop + 1
                        itemShopSlots[slot] = true
                    else
                        local itemType = ExtractType(lines)
                        table.insert(slots, {
                            slot = slot,
                            itemIndex = itemIndex,
                            icon = icon,
                            name = name,
                            itemCount = itemCount or 0,
                            itemType = itemType,
                            itemTier = ExtractTier(lines),
                            isQuestItem = IsQuestItem(lines, itemType),
                        })
                    end
                end
            end
        end
    end

    return slots, total, skippedItemShop, tooltipUnavailable, itemShopSlots, lockedSlots, lockedCount
end

-- Slots we are allowed to place sorted items into: anything in range that isn't
-- an Item Shop item slot or a locked occupied slot (neither can ever be
-- touched). Ascending order.
local function BuildUsableSlots(total, itemShopSlots, lockedSlots)
    local usable = {}
    for slot = 1, total do
        if not itemShopSlots[slot] and not lockedSlots[slot] then
            table.insert(usable, slot)
        end
    end
    return usable
end

local function GetTypeGroup(item)
    local itemType = string.lower(item.itemType or "")
    if item.isQuestItem or string.find(itemType, "quest", 1, true) then
        return 4
    end

    local equipmentWords = {
        "armor", "armour", "weapon", "shield", "helmet", "head", "chest",
        "shoulder", "glove", "boot", "belt", "ring", "necklace", "earring",
        "jewel", "accessory", "robe", "clothing", "costume", "one-handed",
        "two-handed", "off hand",
    }
    if (item.itemTier or 0) > 0 then
        return 1
    end
    for _, word in ipairs(equipmentWords) do
        if string.find(itemType, word, 1, true) then
            return 1
        end
    end

    local consumableWords = { "potion", "medicine", "consumable", "elixir", "food", "drink", "recovery" }
    for _, word in ipairs(consumableWords) do
        if string.find(itemType, word, 1, true) then
            return 2
        end
    end

    return 3
end

local function BuildSortedItems()
    local items, total, skippedItemShop, tooltipUnavailable, itemShopSlots, lockedSlots, lockedCount = ReadOccupiedSlots()
    local mode = WrathBagSort_Settings.mode or "name"
    local descending = (WrathBagSort_Settings.direction == "desc")

    table.sort(items, function(left, right)
        -- For descending order, swap the operands and run the same ascending
        -- comparison on the reversed pair.
        local a, b = left, right
        if descending then
            a, b = right, left
        end

        if mode == "type" then
            local aGroup = GetTypeGroup(a)
            local bGroup = GetTypeGroup(b)
            if aGroup ~= bGroup then
                return aGroup < bGroup
            end
            local aType = string.lower(a.itemType or "")
            local bType = string.lower(b.itemType or "")
            if aType ~= bType then
                return aType < bType
            end
        elseif mode == "tier" then
            local aTier = a.itemTier or 0
            local bTier = b.itemTier or 0
            if aTier ~= bTier then
                return aTier < bTier
            end
        end

        local aName = string.lower(a.name)
        local bName = string.lower(b.name)
        if aName ~= bName then
            return aName < bName
        end

        return a.slot < b.slot
    end)

    return items, total, skippedItemShop, tooltipUnavailable, itemShopSlots, lockedSlots, lockedCount
end

local function PreviewSort()
    local items, total, skippedItemShop, tooltipUnavailable, itemShopSlots, lockedSlots, lockedCount = BuildSortedItems()
    local usableSlots = BuildUsableSlots(total, itemShopSlots, lockedSlots)
    local count = table.getn(items)

    if tooltipUnavailable then
        Print("warning: could not verify Item Shop items via tooltip; some slots were skipped out of caution")
    end
    if skippedItemShop > 0 then
        Print(skippedItemShop .. " Item Shop item slot(s) detected and will be left untouched")
    end
    if lockedCount > 0 then
        Print(lockedCount .. " locked item slot(s) detected and will be left untouched")
    end

    local modeLabel = WrathBagSort_Settings.mode or "name"
    local dirLabel = (WrathBagSort_Settings.direction == "desc") and "descending" or "ascending"
    local capacity = table.getn(usableSlots)
    if type(GetBagCount) == "function" then
        local ok, _, reportedCapacity = pcall(GetBagCount)
        if ok and type(reportedCapacity) == "number" then
            capacity = reportedCapacity
        end
    end
    Print("preview: " .. count .. " occupied slots / " .. capacity .. " total Backpack capacity (sort by " .. modeLabel .. ", " .. dirLabel .. ")")
    for p = 1, count do
        local item = items[p]
        local targetSlot = usableSlots[p]
        if item.slot ~= targetSlot then
            Print("  slot " .. item.slot .. " -> " .. targetSlot .. ": " .. item.name .. " x" .. item.itemCount)
        end
    end
    Print("preview complete; no items were moved")
    Print("  (run /sortbag log to open a copyable version of this output)")
end

-- Based on zBag's BagSort.lua DoMove(), the only addon on this client confirmed
-- to move bag items safely: verify every pickup/place via CursorHasItem(), and
-- always try to return a stranded cursor item rather than leaving it dangling.
local function HasCursorItem()
    if type(CursorHasItem) ~= "function" then
        return nil
    end
    local ok, hasItem = pcall(CursorHasItem)
    if not ok then
        return nil
    end
    return hasItem
end

local function ClearCursor()
    local hasItem = HasCursorItem()
    if hasItem ~= true then
        return
    end

    if type(CursorItemType) == "function" and type(GetCursorItemInfo) == "function" then
        local okType, cursorType = pcall(CursorItemType)
        if okType and cursorType == "bag" then
            local okInfo, slot = pcall(GetCursorItemInfo)
            if okInfo and slot then
                pcall(PickupBagItem, slot)
                return
            end
        end
    end

    Print("WARNING: an item is stuck on your cursor; click an empty bag slot to release it")
end

-- CONFIRMED via /sortbag testswap: PickupBagItem's numeric argument is NOT the
-- same as the UI backpack slot number used by GetBagItemInfo. This client's
-- Item Shop Backpack occupies PickupBagItem indices 1-60; the real Backpack's
-- UI slot N is addressed as (N + BAG_PICKUP_OFFSET). This matches
-- GetBagItemInfo's own first return value (itemIndex == slot + 60), which we
-- were already using correctly for GameTooltip:SetBagItem but NOT for
-- PickupBagItem - that mismatch caused real moves to hit the Item Shop
-- Backpack instead of the regular Backpack.
local BAG_PICKUP_OFFSET = 60

local function ToPickupIndex(uiSlot)
    if type(uiSlot) ~= "number" or uiSlot < 1 then
        return nil
    end

    local pickupIndex = uiSlot + BAG_PICKUP_OFFSET
    if pickupIndex <= BAG_PICKUP_OFFSET then
        return nil
    end
    return pickupIndex
end

local function DescribeSlot(slot)
    local _, icon, name, itemCount = GetBagItemInfo(slot)
    if not icon or icon == "" then
        return "empty"
    end
    return "\"" .. tostring(name) .. "\" x" .. tostring(itemCount)
end

local function TestSwap(slotA, slotB)
    slotA = tonumber(slotA)
    slotB = tonumber(slotB)
    if not slotA or not slotB then
        Print("usage: /sortbag testswap <slotA> <slotB>")
        return
    end

    Print("before: slot " .. slotA .. " = " .. DescribeSlot(slotA) .. ", slot " .. slotB .. " = " .. DescribeSlot(slotB))

    local okPickup = pcall(PickupBagItem, slotA)
    Print("after pickup(" .. slotA .. "): ok=" .. tostring(okPickup) .. ", slot " .. slotA .. " = " .. DescribeSlot(slotA))
    if type(CursorHasItem) == "function" then
        local hasItem = pcall(CursorHasItem)
        Print("  CursorHasItem() = " .. tostring(hasItem))
    end

    local okPlace = pcall(PickupBagItem, slotB)
    Print("after place(" .. slotB .. "): ok=" .. tostring(okPlace))
    Print("result: slot " .. slotA .. " = " .. DescribeSlot(slotA) .. ", slot " .. slotB .. " = " .. DescribeSlot(slotB))
end

-- Like /sortbag testswap, but takes UI backpack slot numbers (same numbering
-- as GetBagItemInfo/DescribeSlot) and applies the +60 PickupBagItem offset
-- itself, so before/after readouts and the actual move target the SAME slot.
-- Built specifically to isolate the "move into UI slot 1" failure.
local function TestMove(uiFromSlot, uiToSlot)
    uiFromSlot = tonumber(uiFromSlot)
    uiToSlot = tonumber(uiToSlot)
    if not uiFromSlot or not uiToSlot then
        Print("usage: /sortbag testmove <uiFromSlot> <uiToSlot>")
        return
    end

    Print("before: slot " .. uiFromSlot .. " = " .. DescribeSlot(uiFromSlot) .. ", slot " .. uiToSlot .. " = " .. DescribeSlot(uiToSlot))

    if HasCursorItem() == true then
        Print("  aborting: cursor already has an item before starting")
        return
    end

    local okPickup = pcall(PickupBagItem, ToPickupIndex(uiFromSlot))
    local pickedUp = HasCursorItem()
    Print("after pickup(" .. uiFromSlot .. " -> index " .. ToPickupIndex(uiFromSlot) .. "): ok=" .. tostring(okPickup)
        .. ", CursorHasItem()=" .. tostring(pickedUp) .. ", slot " .. uiFromSlot .. " = " .. DescribeSlot(uiFromSlot))

    if pickedUp ~= true then
        Print("  pickup put nothing on the cursor; stopping here")
        return
    end

    local okPlace = pcall(PickupBagItem, ToPickupIndex(uiToSlot))
    local stillHeld = HasCursorItem()
    Print("after place(" .. uiToSlot .. " -> index " .. ToPickupIndex(uiToSlot) .. "): ok=" .. tostring(okPlace)
        .. ", CursorHasItem()=" .. tostring(stillHeld))

    if stillHeld == true then
        Print("  item still on cursor after place; trying ClearCursor()")
        ClearCursor()
    end

    Print("result (immediate): slot " .. uiFromSlot .. " = " .. DescribeSlot(uiFromSlot) .. ", slot " .. uiToSlot .. " = " .. DescribeSlot(uiToSlot))
    Print("  run /sortbag probe again in a few seconds to see if this changes")
end

-- Read-only diagnostic: scans _G for global frame-like objects whose name
-- contains `substring` (case-insensitive). Used to identify native frame
-- names we don't know yet (e.g. the Item Shop Backpack window) without
-- guessing - guessing wrong here has caused real item loss before.
local function FindFramesMatching(substring, exclude)
    if not substring or substring == "" then
        Print("usage: /sortbag frames <substring> [exclude]")
        return
    end
    local needle = string.lower(substring)
    local excludeNeedle = exclude and exclude ~= "" and string.lower(exclude) or nil
    local matches = {}
    for key, value in pairs(_G) do
        if type(key) == "string" and string.find(string.lower(key), needle, 1, true) then
            local lowerKey = string.lower(key)
            if not excludeNeedle or not string.find(lowerKey, excludeNeedle, 1, true) then
                local isFrameLike = type(value) == "table" and type(value.IsVisible) == "function"
                if isFrameLike then
                    local ok, visible = pcall(value.IsVisible, value)
                    table.insert(matches, key .. " (visible=" .. tostring(ok and visible) .. ")")
                end
            end
        end
    end
    table.sort(matches)
    if table.getn(matches) == 0 then
        Print("no frame-like globals found matching \"" .. substring .. "\"")
        return
    end
    Print("frames matching \"" .. substring .. "\" (" .. table.getn(matches) .. "):")
    for i = 1, table.getn(matches) do
        Print("  " .. matches[i])
    end
end

local function SlotMatches(slot, expected)
    local _, _, name = GetBagItemInfo(slot)
    return name == expected, name
end

-- Confirmed via /sortbag testswap: placing onto an OCCUPIED real-Backpack
-- slot performs a genuine atomic swap (not a silent revert), so we no
-- longer need to stage displaced items through an empty buffer slot.
local function SwapSlots(fromSlot, toSlot)
    local fromIndex = ToPickupIndex(fromSlot)
    local toIndex = ToPickupIndex(toSlot)
    if not fromIndex or not toIndex or fromIndex <= BAG_PICKUP_OFFSET or toIndex <= BAG_PICKUP_OFFSET then
        return false, "refusing to touch Item Shop Backpack indices 1-60"
    end

    if HasCursorItem() == true then
        ClearCursor()
        return false, "cursor already had an item before this move"
    end

    if not pcall(PickupBagItem, fromIndex) then
        return false, "failed to pick up slot " .. fromSlot
    end

    if HasCursorItem() == false then
        return false, "pickup from slot " .. fromSlot .. " put nothing on the cursor"
    end

	if not pcall(PickupBagItem, toIndex) then
        ClearCursor()
        return false, "failed to place into slot " .. toSlot
    end

    if HasCursorItem() == true then
        -- displaced item came back to the cursor instead of swapping atomically; recover it
        ClearCursor()
    end

    return true
end

-- Confirmed via live testing: this client's bag data lags by roughly one
-- frame behind the PickupBagItem calls that changed it - GetBagItemInfo
-- checked immediately afterward can still show the OLD contents even though
-- the swap genuinely succeeded. A real sort run showed this lag can exceed
-- 7.5s (4 retries x 1.5s) for a single move, so per-move verify-then-retry
-- was both too slow and still produced false "sort aborted" failures.
-- ALSO CONFIRMED: firing many PickupBagItem pairs back-to-back with ZERO
-- delay works for a while (13 moves into empty slots succeeded) then a
-- pickup silently put nothing on the cursor - this client appears to
-- rate-limit/drop rapid-fire bag actions. Fix: a short PACING_DELAY is
-- enforced between each move (via OnUpdate), separate from the much longer
-- FINAL_VERIFY_DELAY used once at the very end for the consistency report.
-- FURTHER CONFIRMED: 0.4s still wasn't enough specifically for a slot that
-- had JUST received a displaced item - picking it back up again that soon
-- failed, then succeeded roughly a pass-cycle later (~1-2s on). Raised to
-- 1.5s; a slot needs real engine-side settle time after being touched, not
-- just a cosmetic delay before issuing the next PickupBagItem call.
local PACING_DELAY = 1.5
local FINAL_VERIFY_DELAY = 5.0
-- Repeated failures kept hitting the SAME slot again just 1 pacing tick
-- (1.5s) after it was last touched, even across retry-pass boundaries -
-- that's not enough settle time for a slot that just received an item.
-- Retry passes now wait PACING_DELAY + RETRY_EXTRA_DELAY before their first
-- move, giving recently-touched slots more real recovery time.
local RETRY_EXTRA_DELAY = 3.0
local SortState = nil

local function GetElapsedArg(a, b)
    if type(b) == "number" then
        return b
    end
    if type(a) == "number" then
        return a
    end
    return 0
end

local function RestoreFrameVisibility(state)
    if state and not state.wasVisible then
        local logFrame = _G["WrathBagSortLogFrame"]
        if logFrame then
            pcall(logFrame.SetAlpha, logFrame, 1)
            logFrame:Hide()
        end
    end
end

-- FinishSort, StartSortRound and DoNextSwap call each other (FinishSort may
-- kick off another StartSortRound, which calls DoNextSwap) - declared as
-- locals up front since Lua's `local function` sugar can't forward-reference
-- a sibling local defined later in the file.
local FinishSort
local StartSortRound
local DoNextSwap

-- Adapted from zBag/BagSort.lua's proven DoMove loop: a failed pickup/place
-- does NOT abort the whole sort - it's skipped and retried in a later pass
-- (up to MAX_RETRY_PASSES), matching zBag's "skip, ClearCursor, try again
-- next cycle" resilience instead of treating any single failure as fatal.
-- Anything still unresolved after all passes simply shows up as a mismatch
-- in the final FinishSort report.
local MAX_RETRY_PASSES = 3
-- Separately, users found that simply running /sortbag sort AGAIN
-- after a finished-but-mismatched sort reliably fixes the stragglers (fresh
-- ground-truth GetBagItemInfo reads catch whatever our in-memory bookkeeping
-- missed). FinishSort now does this automatically instead of making the user
-- retype the command, up to MAX_CORRECTION_ROUNDS times. 3 rounds wasn't
-- always enough in testing (a 4th manual /sortbag sort was needed),
-- so this is intentionally generous - each round only keeps running while
-- there's still real work to do.
local MAX_CORRECTION_ROUNDS = 8

FinishSort = function()
    local state = SortState
    SortState = nil
    if not state then
        return
    end

    local mismatches = 0
    for identity = 1, state.count do
        local slot = state.desiredSlot[identity]
        local matches = SlotMatches(slot, state.expectedName[identity])
        if not matches then
            mismatches = mismatches + 1
        end
    end

    if mismatches > 0 and state.correctionRound < MAX_CORRECTION_ROUNDS then
        Print("  " .. mismatches .. " item(s) still not in place; re-reading bag and retrying (correction round "
            .. (state.correctionRound + 1) .. "/" .. MAX_CORRECTION_ROUNDS .. ")...")
        StartSortRound(state.wasVisible, state.moveCount, state.correctionRound + 1)
        return
    end

    for identity = 1, state.count do
        local slot = state.desiredSlot[identity]
        local matches, name = SlotMatches(slot, state.expectedName[identity])
        if not matches then
            Print("  warning: slot " .. slot .. " expected \"" .. state.expectedName[identity] .. "\" but found \"" .. tostring(name) .. "\"")
        end
    end

    Print("sort complete; " .. state.moveCount .. " moves performed, " .. mismatches .. " mismatches")
    if mismatches > 0 then
        Print("  run /sortbag sort again to retry the remaining item(s)")
    end
    RestoreFrameVisibility(state)
end

StartSortRound = function(wasVisible, priorMoveCount, correctionRound)
    local items, total, skippedItemShop, tooltipUnavailable, itemShopSlots, lockedSlots, lockedCount = BuildSortedItems()
    local count = table.getn(items)

    if tooltipUnavailable then
        Print("sort aborted: cannot verify Item Shop items via tooltip in this client; refusing to move anything")
        RestoreFrameVisibility({ wasVisible = wasVisible })
        return
    end
    if correctionRound == 0 and skippedItemShop > 0 then
        Print(skippedItemShop .. " Item Shop item slot(s) detected and will be left untouched")
    end
    if correctionRound == 0 and lockedCount > 0 then
        Print(lockedCount .. " locked item slot(s) detected and will be left untouched")
    end
    if count == 0 then
        if correctionRound == 0 then
            Print("nothing to sort; no occupied slots found")
        end
        RestoreFrameVisibility({ wasVisible = wasVisible })
        return
    end

    local usableSlots = BuildUsableSlots(total, itemShopSlots, lockedSlots)
    if table.getn(usableSlots) < count then
        Print("sort aborted: not enough usable slots after excluding Item Shop/locked items")
        RestoreFrameVisibility({ wasVisible = wasVisible })
        return
    end

    -- identity (1..count, matches sorted `items` order) -> desired final slot
    local desiredSlot = {}
    local expectedName = {}
    local location = {}
    local occupant = {}
    for identity, item in ipairs(items) do
        desiredSlot[identity] = usableSlots[identity]
        expectedName[identity] = item.name
        location[identity] = item.slot
        occupant[item.slot] = identity
    end

    SortState = {
        count = count,
        desiredSlot = desiredSlot,
        expectedName = expectedName,
        location = location,
        occupant = occupant,
        identity = 1,
        moveCount = priorMoveCount,
        waited = 0,
        pacingPending = false,
        finishPending = false,
        retryPass = 0,
        hadFailureThisPass = false,
        correctionRound = correctionRound,
        wasVisible = wasVisible,
    }

    if correctionRound == 0 then
        Print("sorting " .. count .. " items (paced to avoid this client's rapid-action limit)...")
        DoNextSwap()
    else
        -- The stragglers left over from a correction round were often the
        -- SAME slots just touched moments ago (end of the previous round) -
        -- give them the same extra backoff a retry pass gets instead of
        -- immediately re-attempting the first move with zero delay.
        SortState.waited = -RETRY_EXTRA_DELAY
        SortState.pacingPending = true
    end
end

DoNextSwap = function()
    local state = SortState
    if not state then
        return
    end

    if state.identity > state.count then
        if state.hadFailureThisPass and state.retryPass < MAX_RETRY_PASSES then
            state.retryPass = state.retryPass + 1
            state.hadFailureThisPass = false
            state.identity = 1
            Print("  retrying unmoved item(s) (pass " .. state.retryPass .. "/" .. MAX_RETRY_PASSES .. ")...")
            -- negative starting point so the usual PACING_DELAY check also
            -- absorbs the extra backoff before the first move of this pass
            state.waited = -RETRY_EXTRA_DELAY
            state.pacingPending = true
            return
        end
        state.waited = 0
        state.finishPending = true
        return
    end

    local identity = state.identity
    local target = state.desiredSlot[identity]
    if state.location[identity] == target then
        state.identity = identity + 1
        DoNextSwap()
        return
    end

    local fromSlot = state.location[identity]
    local displaced = state.occupant[target]

    Print("  swapping slot " .. fromSlot .. " (" .. state.expectedName[identity] .. ") <-> slot " .. target
        .. (displaced and (" (" .. state.expectedName[displaced] .. ")") or " (empty)"))

    local ok, err = SwapSlots(fromSlot, target)
    if not ok then
        Print("  skipping for now: " .. err .. " (will retry after the rest)")
        state.hadFailureThisPass = true
        state.identity = identity + 1
        state.waited = 0
        state.pacingPending = true
        return
    end
    state.moveCount = state.moveCount + 1

    -- optimistic bookkeeping: SwapSlots already confirmed the pickup and
    -- place via real-time CursorHasItem() checks; GetBagItemInfo itself can
    -- lag several seconds, so don't re-verify this against it per-move.
    state.occupant[fromSlot] = displaced
    state.location[identity] = target
    state.occupant[target] = identity
    if displaced then
        -- the item that was sitting at `target` physically landed at
        -- `fromSlot` as a result of this swap - without this, its stale old
        -- location causes every later swap involving it to target the wrong
        -- slot, producing the cascading mismatch cycles seen in testing.
        state.location[displaced] = fromSlot
    end
    state.identity = identity + 1

    -- pace the NEXT move by PACING_DELAY rather than firing it immediately -
    -- back-to-back calls with zero delay eventually got silently dropped.
    state.waited = 0
    state.pacingPending = true
end

local function OnWorkerUpdateInner(a, b)
    local state = SortState
    if not state then
        return
    end

    if state.pacingPending then
        state.waited = (state.waited or 0) + GetElapsedArg(a, b)
        if state.waited < PACING_DELAY then
            return
        end
        state.pacingPending = false
        DoNextSwap()
        return
    end

    if not state.finishPending then
        return
    end

    state.waited = (state.waited or 0) + GetElapsedArg(a, b)
    if state.waited < FINAL_VERIFY_DELAY then
        return
    end

    FinishSort()
end

-- Wrapped in pcall for the same reason as ExecuteSort: an uncaught error in
-- here would otherwise fail silently (or worse) on every single frame.
-- Exposed on the WrathBagSort table (not local) because this client only
-- supports attaching script handlers via XML <Scripts> blocks - calling
-- frame:SetScript("OnUpdate", ...) from Lua errors with "attempt to call
-- method 'SetScript' (a nil value)". WrathBagSortLog.xml's OnUpdate script
-- calls WrathBagSort.OnWorkerUpdate(arg1) directly instead.
function WrathBagSort.OnWorkerUpdate(a, b)
    local ok, err = pcall(OnWorkerUpdateInner, a, b)
    if not ok then
        SortState = nil
        Print("sort error (caught in OnUpdate): " .. tostring(err))
    end
end

local function GetWorkerFrame()
    return _G["WrathBagSortLogFrame"]
end

local function ExecuteSortInner()
    if type(PickupBagItem) ~= "function" then
        Print("PickupBagItem is unavailable; cannot move items in this client")
        return
    end

    if SortState then
        Print("a sort is already in progress; please wait for it to finish")
        return
    end

    local workerFrame = GetWorkerFrame()
    if not workerFrame then
        Print("sort aborted: no usable frame to schedule paced moves (addon failed to create one at load time)")
        return
    end

    -- Hidden frames don't appear to receive OnUpdate ticks on this client, so
    -- show the log window for the duration of the sort (restored afterward).
    -- SetAlpha(0) keeps it visually invisible (no open/close flicker) while
    -- still "shown" so OnUpdate keeps firing; /sortbag log still works
    -- normally afterward since alpha is restored before hiding again.
    local wasVisible = workerFrame:IsVisible()
    if not wasVisible then
        workerFrame:Show()
        pcall(workerFrame.SetAlpha, workerFrame, 0)
    end

    StartSortRound(wasVisible, 0, 0)
end

-- Wrapped in pcall: this client appears to lock up the chat input (or at
-- least give no feedback at all) on an uncaught Lua error from inside a
-- slash-command handler, rather than showing a normal error message. This
-- guarantees we always get a printed diagnostic instead of silent failure.
local function ExecuteSort()
    local ok, err = pcall(ExecuteSortInner)
    if not ok then
        SortState = nil
        Print("sort error (caught): " .. tostring(err))
    end
end

-- Make the native "sort items" button run OUR sort instead of the native
-- per-bag sort. `RefreshBag` is what the native BagRefreshButton calls (and
-- zBag's "sort items" button calls it once per bag via zBag_Sort);
-- `zBag_SortFull` is zBag's separate "full sort" button. ExecuteSort has a
-- re-entrancy guard, so overlapping/rapid calls are harmless.
if type(RefreshBag) == "function" then
    RefreshBag = function()
        ExecuteSort()
    end
end
if type(zBag_SortFull) == "function" then
    zBag_SortFull = function()
        ExecuteSort()
    end
end

function WrathBagSort.Probe()
    ProbeGlobals()
    ProbeBag()
end

-- Copyable log window, adapted from CopyChat.lua's Update()/scrollbar logic
-- (the only addon on this client confirmed to let players select+copy text).
-- Each line gets its own single-line EditBox. A single multi-line/ScrollFrame
-- EditBox was tried and crashed this client, so that approach is avoided.
-- Window is sized large (35 lines) so a screenshot can capture more at once.
local NUM_LOG_LINES = 35

-- Splits the newline-joined log string into an ordered list of lines.
local function GetLogLines()
    local lines = {}
    if type(WrathBagSort_Log) == "string" then
        for line in string.gmatch(WrathBagSort_Log, "[^\n]+") do
            lines[#lines + 1] = line
        end
    end
    return lines
end

function WrathBagSort.LogUpdate()
    if not WrathBagSortLogScrollBar then
        return
    end

    local lines = GetLogLines()
    local count = #lines
    local value = WrathBagSortLogScrollBar:GetValue()

    for i = 1, NUM_LOG_LINES do
        _G["WrathBagSortLogMessage" .. i]:Hide()
    end

    local editBoxIndex = 1
    for i = 1, count do
        if editBoxIndex <= NUM_LOG_LINES and (i - 1) >= value then
            local editbox = _G["WrathBagSortLogMessage" .. editBoxIndex]
            editbox:Show()
            editbox:SetText(lines[i])
            editBoxIndex = editBoxIndex + 1
        end
    end

    if count <= NUM_LOG_LINES then
        WrathBagSortLogScrollBar:Hide()
        WrathBagSortLogScrollBar:SetValue(0)
        WrathBagSortLogScrollBar:SetMaxValue(0)
    else
        WrathBagSortLogScrollBar:Show()
        WrathBagSortLogScrollBar:SetMinMaxValues(0, count - NUM_LOG_LINES)
    end

    -- Fill the "copy all" box. This client's EditBoxes are single-line only
    -- (multi-line crashes), so join with " | " instead of newlines.
    if WrathBagSortLogCopyAll then
        WrathBagSortLogCopyAll:SetText(table.concat(lines, " | "))
    end
end

function WrathBagSort.ToggleLog()
    if not WrathBagSortLogFrame then
        Print("log window is unavailable (WrathBagSortLogFrame not found)")
        return
    end

    -- While a sort is in progress, the frame may already be Shown (but
    -- invisible via alpha=0) purely to keep OnUpdate ticking - Hide()ing it
    -- here would stop the sort. Just make it visible instead of toggling.
    if SortState then
        WrathBagSortLogFrame:Show()
        pcall(WrathBagSortLogFrame.SetAlpha, WrathBagSortLogFrame, 1)
        WrathBagSortLogScrollBar:SetValue(WrathBagSortLogScrollBar:GetMaxValue())
        WrathBagSort.LogUpdate()
        return
    end

    if WrathBagSortLogFrame:IsVisible() then
        WrathBagSortLogFrame:Hide()
        return
    end

    WrathBagSortLogFrame:Show()
    pcall(WrathBagSortLogFrame.SetAlpha, WrathBagSortLogFrame, 1)
    WrathBagSortLogScrollBar:SetValue(WrathBagSortLogScrollBar:GetMaxValue())
    WrathBagSort.LogUpdate()
end

-- =========================================================================
-- Custom bag frame (icon grid) - a "native-like" UI bound to OUR sort.
-- Item buttons and count overlays are XML-defined; CreateFrame remains
-- unavailable on this client (see AGENTS.md quirk #5).
-- =========================================================================

local BAG_GRID_COLS = 6
local BAG_GRID_ROWS = 5
local BAG_PAGE_SIZE = BAG_GRID_COLS * BAG_GRID_ROWS
local BAG_PAGE_COUNT = 12
local BAG_SLOT_SIZE = 42
local BAG_SLOT_PITCH = 46
local BAG_PAGE_ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" }
local BagCurrentPage = 1
local BagSearchText = ""
local BagSearchMatches = {}
local BagSearchPages = {}
local BagSearchMatchCount = 0

local BagGridButtons = {}   -- slot -> button
local BagGridIcons = {}     -- slot -> icon texture
local BagGridCounts = {}    -- slot -> stack-count FontString
local BagSlotByButton = {}  -- button name -> slot

local function CreateBagGrid()
    for slot = 1, BAG_PAGE_SIZE do
        local button = _G["WrathBagSortItem" .. slot]
        if button and not BagGridButtons[slot] then
            WrathBagSort.OnBagSlotLoad(button)
        end
    end
end

function WrathBagSort.OnBagSlotLoad(button)
    local slot = button:GetID()
    if not slot or slot < 1 or slot > BAG_PAGE_SIZE then
        return
    end

    local col = (slot - 1) % BAG_GRID_COLS
    local row = math.floor((slot - 1) / BAG_GRID_COLS)
    button:SetSize(BAG_SLOT_SIZE, BAG_SLOT_SIZE)
    button:ClearAllAnchors()
    button:SetAnchor("TOPLEFT", "TOPLEFT", "WrathBagSortBagFrame", 58 + col * BAG_SLOT_PITCH, 146 + row * BAG_SLOT_PITCH)
    button:SetMouseEnable(true)
    button:RegisterForClicks("LeftButton", "RightButton")
    button:RegisterEvent("BAG_ITEM_UPDATE")

    local name = button:GetName()
    BagGridButtons[slot] = button
    BagGridIcons[slot] = _G[name .. "Icon"]
    BagGridCounts[slot] = _G[name .. "Count"]
    BagSlotByButton[name] = slot
end

function WrathBagSort.OnBagFrameLoad()
    WrathBagSort.UpdateBagButtons()
end

function WrathBagSort.RefreshBagGrid()
    if not BagGridButtons[1] then
        return
    end
    for localSlot = 1, BAG_PAGE_SIZE do
        WrathBagSort.RefreshBagSlot(localSlot)
    end
end

function WrathBagSort.RefreshBagSlot(localSlot)
    local button = BagGridButtons[localSlot]
    local icon = BagGridIcons[localSlot]
    local countText = BagGridCounts[localSlot]
    if button and icon then
        local slot = (BagCurrentPage - 1) * BAG_PAGE_SIZE + localSlot
        local itemIndex, iconPath, _, itemCount, locked = GetBagItemInfo(slot)
        button.index = itemIndex
        BagSlotByButton[button:GetName()] = localSlot
        if iconPath and iconPath ~= "" then
            icon:SetFile(iconPath)
            icon:Show()
        else
            icon:Hide()
        end
        if countText then
            if itemCount and itemCount > 1 then
                countText:SetText(tostring(itemCount))
            else
                countText:SetText("")
            end
        end
        if IsFlagSet(locked) then
            pcall(icon.SetColor, icon, 1, 0.3, 0.3)
        else
            pcall(icon.SetColor, icon, 1, 1, 1)
        end
        if BagSearchText == "" or BagSearchMatches[slot] then
            button:SetAlpha(1)
        else
            button:SetAlpha(0.22)
        end
    end
end

function WrathBagSort.UpdateSearchStatus()
    local status = _G["WrathBagSortBagFrameSearchStatus"]
    if status then
        if BagSearchText == "" then
            status:SetText("")
        else
            status:SetText(tostring(BagSearchMatchCount) .. " found")
        end
    end
end

function WrathBagSort.SearchChanged(editBox)
    local text = editBox and editBox:GetText() or ""
    BagSearchText = string.lower(string.gsub(text, "^%s*(.-)%s*$", "%1"))
    BagSearchMatches = {}
    BagSearchPages = {}
    BagSearchMatchCount = 0

    if BagSearchText ~= "" then
        local firstPage = nil
        local total = GetBagSlotCount()
        for slot = 1, total do
            local _, icon, name = GetBagItemInfo(slot)
            if icon and icon ~= "" and name and string.find(string.lower(name), BagSearchText, 1, true) then
                local page = math.floor((slot - 1) / BAG_PAGE_SIZE) + 1
                BagSearchMatches[slot] = true
                BagSearchPages[page] = true
                BagSearchMatchCount = BagSearchMatchCount + 1
                if not firstPage then
                    firstPage = page
                end
            end
        end
        if firstPage then
            BagCurrentPage = firstPage
        end
    end

    WrathBagSort.UpdateSearchStatus()
    WrathBagSort.UpdatePageButtons()
    WrathBagSort.RefreshBagGrid()
end

function WrathBagSort.ClearSearch()
    local searchBox = _G["WrathBagSortBagFrameSearchBox"]
    if searchBox then
        searchBox:SetText("")
        searchBox:ClearFocus()
    end
end

local function ClearSearchFocus()
    local searchBox = _G["WrathBagSortBagFrameSearchBox"]
    if searchBox then
        searchBox:ClearFocus()
    end
end

function WrathBagSort.UpdatePageButtons()
    for page = 1, BAG_PAGE_COUNT do
        local button = _G["WrathBagSortBagFramePageButton" .. page]
        if button then
            local available = IsBagPageAvailable(page)
            local hasMatches = BagSearchPages[page]
            button:SetText(BAG_PAGE_ROMAN[page] .. (hasMatches and "+" or "") .. (available and "" or " *"))
            if page == BagCurrentPage then
                button:Disable()
            else
                button:Enable()
            end
        end
    end

    local countLabel = _G["WrathBagSortBagFrameBagCount"]
    local pageLabel = _G["WrathBagSortBagFramePageLabel"]
    if type(GetBagCount) == "function" and countLabel then
        local ok, occupied, capacity = pcall(GetBagCount)
        if ok then
            countLabel:SetText("Backpack (" .. tostring(occupied or 0) .. "/" .. tostring(capacity or GetBagSlotCount()) .. ")")
        end
    end
    if pageLabel then
        local available = IsBagPageAvailable(BagCurrentPage)
        pageLabel:SetText("Page " .. BAG_PAGE_ROMAN[BagCurrentPage] .. " / XII" .. (available and "" or " - read only"))
    end
    WrathBagSort.UpdateSearchStatus()
    local rentButton = _G["WrathBagSortBagFrameRentPageButton"]
    if rentButton then
        if BagCurrentPage > 2 and not IsBagPageAvailable(BagCurrentPage) then
            rentButton:Show()
        else
            rentButton:Hide()
        end
    end
end

function WrathBagSort.SelectPage(page)
    ClearSearchFocus()
    page = tonumber(page)
    if not page or page < 1 or page > BAG_PAGE_COUNT or page == BagCurrentPage then
        return
    end
    BagCurrentPage = page
    WrathBagSort.UpdatePageButtons()
    WrathBagSort.RefreshBagGrid()
end

local function GetCurrentBagSlot(button)
    local localSlot = button and BagSlotByButton[button:GetName()]
    if not localSlot then
        return nil
    end
    return (BagCurrentPage - 1) * BAG_PAGE_SIZE + localSlot
end

function WrathBagSort.ItemOnEvent(button, event)
    if event == "BAG_ITEM_UPDATE" and button.index == arg1 then
        local localSlot = BagSlotByButton[button:GetName()]
        if localSlot then
            WrathBagSort.RefreshBagSlot(localSlot)
        end
    end
end

function WrathBagSort.ItemOnClick(button, mouseButton, ignoreModifiers)
    ClearSearchFocus()
    local slot = GetCurrentBagSlot(button)
    if not slot or not IsBagPageAvailable(math.floor((slot - 1) / 30) + 1) then
        return
    end
    local itemIndex, icon, _, itemCount, locked = GetBagItemInfo(slot)
    if not itemIndex or itemIndex <= 60 then
        return
    end
    local occupied = icon and icon ~= ""

    if mouseButton == "LBUTTON" then
        if IsFlagSet(locked) then
            return
        end
        if occupied and not ignoreModifiers and IsShiftKeyDown() then
            local itemLink = GetBagItemLink(itemIndex)
            if itemLink and ChatEdit_AddItemLink(itemLink) then
                return
            end
            if itemCount and itemCount > 1 then
                button.AskNumberFrameCallBack = function(_, amount)
                    SplitBagItem(itemIndex, amount)
                end
                OpenAskNumberFrame(1, itemCount, button, "BOTTOMRIGHT", "TOPRIGHT")
            end
            return
        elseif occupied and not ignoreModifiers and IsCtrlKeyDown() then
            local itemLink = GetBagItemLink(itemIndex)
            if itemLink then
                ItemPreviewFrame_SetItemLink(ItemPreviewFrame, itemLink)
            end
            return
        end
        pcall(PickupBagItem, itemIndex)
        return
    end

    if mouseButton == "RBUTTON" and occupied and not IsFlagSet(locked) and type(UseBagItem) == "function" then
        pcall(UseBagItem, itemIndex)
    end
end

function WrathBagSort.ItemDragStart(button)
    WrathBagSort.ItemOnClick(button, "LBUTTON", true)
end

function WrathBagSort.DropOnSlot(button)
    ClearSearchFocus()
    local slot = GetCurrentBagSlot(button)
    if not slot or not IsBagPageAvailable(math.floor((slot - 1) / 30) + 1) then
        return
    end
    local itemIndex, icon, _, _, locked = GetBagItemInfo(slot)
    if not itemIndex or itemIndex <= 60 or IsFlagSet(locked) then
        return
    end
    pcall(PickupBagItem, itemIndex)
end

function WrathBagSort.RentCurrentPage()
    local page = BagCurrentPage
    if page <= 2 or IsBagPageAvailable(page) then
        return
    end
    if type(OpenTimeFlagStoreUpFrame) == "function" then
        pcall(OpenTimeFlagStoreUpFrame, "BagLet" .. page)
    else
        Print("the native bag-rental window is unavailable in this client")
    end
end

function WrathBagSort.OpenGoods()
    if type(GoodsFrame) == "table" or type(GoodsFrame) == "userdata" then
        ToggleUIFrame(GoodsFrame)
        if GoodsFrame:IsVisible() then
            GoodsFrame:ClearAllAnchors()
            GoodsFrame:SetAnchor("TOPRIGHT", "TOPLEFT", "WrathBagSortBagFrame", -10, 0)
        end
    end
end

function WrathBagSort.OpenPartner()
    if type(OpenPartnerFrameButton_OnClick) == "function" then
        OpenPartnerFrameButton_OnClick()
    end
end

function WrathBagSort.OpenTransmuter()
    if type(OpenMagicBoxButton_OnClick) == "function" then
        OpenMagicBoxButton_OnClick()
        if MagicBoxFrame and MagicBoxFrame:IsVisible() then
            MagicBoxFrame:ClearAllAnchors()
            MagicBoxFrame:SetAnchor("TOPRIGHT", "TOPLEFT", "WrathBagSortBagFrame", -10, 0)
        end
    end
end

function WrathBagSort.OpenGarbage()
    if GarbageFrame then
        ToggleUIFrame(GarbageFrame)
        if GarbageFrame:IsVisible() then
            GarbageFrame:ClearAllAnchors()
            GarbageFrame:SetAnchor("TOPRIGHT", "TOPLEFT", "WrathBagSortBagFrame", -10, 0)
        end
    end
end

function WrathBagSort.ItemOnEnter(button)
    local slot = GetCurrentBagSlot(button)
    if not slot then
        return
    end
    local itemIndex, icon, name = GetBagItemInfo(slot)
    if not icon or icon == "" or not name or name == "" or not itemIndex or itemIndex <= 60 then
        return
    end
    if type(GameTooltip) == "table" or type(GameTooltip) == "userdata" then
        GameTooltip:SetOwner(button, "ANCHOR_TOPLEFT", -5, 0)
        GameTooltip:SetBagItem(itemIndex)
    end
end

function WrathBagSort.ItemOnLeave(button)
    if type(GameTooltip) == "table" or type(GameTooltip) == "userdata" then
        GameTooltip:Hide()
    end
end

function WrathBagSort.Sort()
    ExecuteSort()
end

function WrathBagSort.Preview()
    PreviewSort()
end

function WrathBagSort.CycleMode()
    local mode = WrathBagSort_Settings.mode or "name"
    if mode == "name" then
        mode = "type"
    elseif mode == "type" then
        mode = "tier"
    else
        mode = "name"
    end
    WrathBagSort_Settings.mode = mode
    pcall(SaveVariables, "WrathBagSort_Settings")
    WrathBagSort.UpdateBagButtons()
    Print("sort mode set to: " .. mode)
end

function WrathBagSort.ToggleOrder()
    local dir = WrathBagSort_Settings.direction or "asc"
    dir = (dir == "asc") and "desc" or "asc"
    WrathBagSort_Settings.direction = dir
    pcall(SaveVariables, "WrathBagSort_Settings")
    WrathBagSort.UpdateBagButtons()
    Print("sort order set to: " .. dir)
end

function WrathBagSort.UpdateBagButtons()
    local mode = WrathBagSort_Settings.mode or "name"
    local modeLabel = ({ name = "Name", type = "Type", tier = "Tier" })[mode] or "Name"
    local dirLabel = (WrathBagSort_Settings.direction == "desc") and "Desc" or "Asc"
    local modeBtn = _G["WrathBagSortBagFrameModeButton"]
    local orderBtn = _G["WrathBagSortBagFrameOrderButton"]
    if modeBtn and modeBtn.SetText then modeBtn:SetText("Mode: " .. modeLabel) end
    if orderBtn and orderBtn.SetText then orderBtn:SetText("Order: " .. dirLabel) end
end

-- Runs every frame (from WrathBagSortHandlerFrame's OnUpdate). Mirrors zBag's
-- zBagHandler_OnUpdate: when the native BagFrame opens, show our bag window and
-- push the native one out of the way; when it closes, close ours too.
function WrathBagSort.HandlerOnUpdate()
    local bagFrame = _G["WrathBagSortBagFrame"]
    if not bagFrame then
        return
    end
    if type(BagFrame) ~= "table" and type(BagFrame) ~= "userdata" then
        return
    end

    if bagFrame:IsVisible() and not BagFrame:IsVisible() then
        bagFrame:Hide()
    elseif not bagFrame:IsVisible() and BagFrame:IsVisible() then
        if not BagGridButtons[1] then
            CreateBagGrid()
        end
        bagFrame:Show()
        pcall(BagFrame.ClearAllAnchors, BagFrame)
        pcall(BagFrame.SetAnchor, BagFrame, "TOPLEFT", "TOPRIGHT", "UIParent", 50, 50)
        if BagItemFrame then
            pcall(BagItemFrame.Hide, BagItemFrame)
        end
    end
end

function WrathBagSort.CloseBag()
    if type(BagFrame) == "table" or type(BagFrame) == "userdata" then
        if BagFrame:IsVisible() then
            if type(HideUIPanel) == "function" then
                pcall(HideUIPanel, BagFrame)
            end
            pcall(BagFrame.Hide, BagFrame)
        end
    end

    local bagFrame = _G["WrathBagSortBagFrame"]
    if bagFrame then
        bagFrame:Hide()
    end
end

local function HandleSlashCommand(_, message)
    local command = string.lower(message or "")
    command = string.gsub(command, "^%s*(.-)%s*$", "%1")
    if command == "testing on" then
        WrathBagSort_TESTING_MODE = true
        Print("testing mode enabled; diagnostic output is on")
        return
    end

    if command == "testing off" then
        if WrathBagSort_TESTING_MODE then
            Print("testing mode disabled; diagnostic output is off")
        end
        WrathBagSort_TESTING_MODE = false
        return
    end

    if command == "probe" then
        WrathBagSort.Probe()
        return
    end

    if command == "preview" then
        PreviewSort()
        return
    end

    if command == "sort" or command == "sortconfirm" or command == "sort confirm" then
        ExecuteSort()
        return
    end

    if command == "cancel" then
        if SortState then
            local state = SortState
            SortState = nil
            RestoreFrameVisibility(state)
            Print("sort cancelled; no further items will be moved")
        else
            Print("no sort is currently in progress")
        end
        return
    end

    if command == "log" then
        WrathBagSort.ToggleLog()
        return
    end

    if command == "bag" then
        -- Toggle the native bag; WrathBagSort.HandlerOnUpdate then shows/hides
        -- our custom bag window in its place.
        if type(BagFrame) == "table" or type(BagFrame) == "userdata" then
            if BagFrame:IsVisible() then
                pcall(BagFrame.Hide, BagFrame)
            else
                pcall(BagFrame.Show, BagFrame)
            end
        end
        return
    end

    if command == "clearlog" then
        WrathBagSort_Log = ""
        pcall(SaveVariables, "WrathBagSort_Log")
        if WrathBagSortLogCopyAll then
            WrathBagSortLogCopyAll:SetText("")
        end
        WrathBagSort.LogUpdate()
        Print("log cleared")
        return
    end

    if command == "mode name" then
        WrathBagSort_Settings.mode = "name"
        pcall(SaveVariables, "WrathBagSort_Settings")
        Print("sort mode set to: name (plain alphabetical)")
        return
    end

    if command == "mode type" then
        WrathBagSort_Settings.mode = "type"
        pcall(SaveVariables, "WrathBagSort_Settings")
        Print("sort mode set to: type (grouped by item type, then name)")
        return
    end

    if command == "mode tier" then
        WrathBagSort_Settings.mode = "tier"
        pcall(SaveVariables, "WrathBagSort_Settings")
        Print("sort mode set to: tier (grouped by tier, then name)")
        return
    end

    if command == "order asc" then
        WrathBagSort_Settings.direction = "asc"
        pcall(SaveVariables, "WrathBagSort_Settings")
        Print("sort order set to: ascending")
        return
    end

    if command == "order desc" then
        WrathBagSort_Settings.direction = "desc"
        pcall(SaveVariables, "WrathBagSort_Settings")
        Print("sort order set to: descending")
        return
    end

    local tooltipSlot = string.match(command, "^tooltip%s+(%d+)$")
    if tooltipSlot then
        TooltipDump(tooltipSlot)
        return
    end

    local testSlotA, testSlotB = string.match(command, "^testswap%s+(%d+)%s+(%d+)$")
    if testSlotA then
        TestSwap(testSlotA, testSlotB)
        return
    end

    local moveFrom, moveTo = string.match(command, "^testmove%s+(%d+)%s+(%d+)$")
    if moveFrom then
        TestMove(moveFrom, moveTo)
        return
    end

    local frameSearch = string.match(command, "^frames%s+(.+)$")
    if frameSearch then
        local include, exclude = string.match(frameSearch, "^(.-)%s+(%S+)$")
        if include then
            FindFramesMatching(include, exclude)
        else
            FindFramesMatching(frameSearch)
        end
        return
    end

    if command == "reload" then
        if type(ReloadUI) == "function" then
            Print("reloading UI...")
            ReloadUI()
        else
            Print("ReloadUI is unavailable in this client; restart the client instead")
        end
        return
    end

    Print("commands: /sortbag bag, /sortbag probe, /sortbag preview, /sortbag sort, /sortbag cancel, /sortbag log, /sortbag clearlog, /sortbag mode <name|type|tier>, /sortbag order <asc|desc>, /sortbag tooltip <slot>, /sortbag frames <substring>, /sortbag reload")
end

SLASH_WRATHBAGSORT1 = "/sortbag"
SlashCmdList = SlashCmdList or {}
SlashCmdList.WRATHBAGSORT = HandleSlashCommand

Print("loaded; type /sortbag probe (or /sortbag log to copy output)")