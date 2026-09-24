local Transmog = _G.Transmog
if not Transmog then Transmog = {} _G.Transmog = Transmog end

local MAX_VISIBLE_SETS = 7
local MAX_PIECES_PER_SET = 10
local SET_BUTTON_HEIGHT = 48

local CLASS_ARMOR_SUBCLASS = {
    ["WARRIOR"] = 4,
    ["PALADIN"] = 4,
    ["DEATHKNIGHT"] = 4,
    ["HUNTER"] = 3,
    ["SHAMAN"] = 3,
    ["ROGUE"] = 2,
    ["DRUID"] = 2,
    ["MAGE"] = 1,
    ["PRIEST"] = 1,
    ["WARLOCK"] = 1,
}

local SUBCLASS_STR_TO_NUM = {
    ["Cloth"] = 1, ["Tela"] = 1,
    ["Leather"] = 2, ["Cuero"] = 2,
    ["Mail"] = 3, ["Malla"] = 3,
    ["Plate"] = 4, ["Placas"] = 4,
    ["Miscellaneous"] = 0, ["Misceláneo"] = 0,
    ["Shields"] = 6, ["Escudos"] = 6,
}

local SLOT_LABELS = {
    [1] = "Head",
    [3] = "Shoulder",
    [4] = "Shirt",
    [5] = "Chest",
    [6] = "Waist",
    [7] = "Legs",
    [8] = "Feet",
    [9] = "Wrist",
    [10] = "Hands",
    [15] = "Back",
    [16] = "Main Hand",
    [17] = "Off Hand",
    [18] = "Ranged"
}

-- Checks if an item is collected in the player's transmog appearance collection.
function Transmog:IsItemCollected(itemID)
    if not itemID or itemID == 0 then return false end
    if self.collectedItems and self.collectedItems[itemID] then return true end
    for _, slot in pairs(self.inventorySlots) do
        local link = GetInventoryItemLink('player', slot)
        if link and self:IDFromLink(link) == itemID then
            return true
        end
    end
    return false
end

-- Counts how many pieces of a set the player has collected.
function Transmog:GetSetCollectedCount(set)
    if not set or not set.pieces then return 0, 0 end
    local collected = 0
    local total = #set.pieces
    for _, piece in ipairs(set.pieces) do
        if self:IsItemCollected(piece.id) then
            collected = collected + 1
        end
    end
    return collected, total
end

-- Checks if a set piece can be transmogrified onto the currently equipped item in that slot.
-- Returns: compatible (boolean), targetItemID (number: 0 to reset/restore original, or piece.id to transmog)
function Transmog:IsSetPieceCompatibleWithEquipped(piece, set)
    if not piece or not piece.slot or not piece.id then
        return false, nil
    end

    local eqLink = GetInventoryItemLink('player', piece.slot)
    if not eqLink then
        return false, nil
    end

    local eqID = self:IDFromLink(eqLink)
    -- If player is already wearing this exact item in this slot:
    -- Return target 0 so any active foreign transmog is removed, restoring the original set piece appearance.
    if eqID == piece.id then
        return true, 0
    end

    -- Universal slot matches: Cloaks (slot 15), Shirts (slot 4), Tabards (slot 19)
    if piece.slot == 15 or piece.slot == 4 or piece.slot == 19 then
        return true, piece.id
    end

    -- Armor slots: Match subclass
    local _, _, _, _, _, _, eqSubclass = GetItemInfo(eqLink)
    local eqSubNum = eqSubclass and SUBCLASS_STR_TO_NUM[eqSubclass]
    if not eqSubNum and eqSubclass and self.ItemSubclassStrToNum then
        local ok, val = pcall(self.ItemSubclassStrToNum, self, eqSubclass)
        if ok and val and val >= 0 then
            eqSubNum = val
        end
    end

    local _, _, _, _, _, _, pieceSubclass = GetItemInfo(piece.id)
    local pieceSubNum = pieceSubclass and SUBCLASS_STR_TO_NUM[pieceSubclass]
    if not pieceSubNum and pieceSubclass and self.ItemSubclassStrToNum then
        local ok, val = pcall(self.ItemSubclassStrToNum, self, pieceSubclass)
        if ok and val and val >= 0 then
            pieceSubNum = val
        end
    end

    if eqSubNum and pieceSubNum then
        if eqSubNum == pieceSubNum then
            return true, piece.id
        else
            return false, nil
        end
    end

    -- Fallback: If piece subclass is not yet in client cache, match using set.class
    if eqSubNum and set and set.class and set.class ~= "ALL" then
        for cls, subNum in pairs(CLASS_ARMOR_SUBCLASS) do
            if subNum == eqSubNum and string.find(set.class, cls) then
                return true, piece.id
            end
        end
        local isClassArmorSet = false
        for cls, _ in pairs(CLASS_ARMOR_SUBCLASS) do
            if string.find(set.class, cls) then
                isClassArmorSet = true
                break
            end
        end
        if isClassArmorSet then
            return false, nil
        end
    end

    -- Fallback: Check server appearance bucket if populated
    if self.IsOutfitAppearanceCompatible and self:IsOutfitAppearanceCompatible(piece.slot, piece.id) then
        return true, piece.id
    end

    if eqSubNum then
        return true, piece.id
    end

    return false, nil
end

-- Previews a set on the 3D player model.
-- If the player has collected pieces, only collected & compatible pieces are previewed,
-- while uncollected or unrepresented slots display the player's active gear.
-- If the player has 0 pieces collected, the entire set is previewed as a showcase.
function Transmog:PreviewSetOnModel(set)
    if not set or not set.pieces then return end
    TransmogFramePlayerModel:Undress()

    local collectedCount = self:GetSetCollectedCount(set)

    -- Determine which set pieces should be previewed
    local previewSetSlots = {}
    for _, p in ipairs(set.pieces) do
        local shouldTryOn = false
        if collectedCount == 0 then
            shouldTryOn = true
        else
            if self:IsItemCollected(p.id) then
                local compatible = self:IsSetPieceCompatibleWithEquipped(p, set)
                if compatible then
                    shouldTryOn = true
                end
            end
        end

        if shouldTryOn and p.id and p.id ~= 0 then
            previewSetSlots[p.slot] = p.id
        end
    end

    -- For slots not previewing a set piece, display active server appearance or equipped item
    for _, slot in pairs(self.inventorySlots) do
        if not previewSetSlots[slot] then
            local eff = nil
            if self.transmogStatusFromServer and self.transmogStatusFromServer[slot] and self.transmogStatusFromServer[slot] ~= 0 then
                if self.transmogStatusFromServer[slot] ~= Transmog.HIDDEN_ITEM_ID then
                    eff = self.transmogStatusFromServer[slot]
                end
            else
                local eqID = self.equippedItems and self.equippedItems[slot]
                if (not eqID or eqID == 0) and GetInventoryItemLink then
                    local link = GetInventoryItemLink('player', slot)
                    if link and self.IDFromLink then
                        eqID = self:IDFromLink(link)
                    end
                end
                if eqID and eqID ~= 0 and eqID ~= Transmog.HIDDEN_ITEM_ID then
                    eff = eqID
                end
            end
            if eff then
                TransmogFramePlayerModel:TryOn(eff)
            end
        end
    end

    -- Try on the previewed set pieces
    for _, p in ipairs(set.pieces) do
        if previewSetSlots[p.slot] == p.id then
            self:cacheItem(p.id)
            TransmogFramePlayerModel:TryOn(p.id)
        end
    end
end

-- Updates paperdoll slot icons to reflect pending changes from set staging.
function Transmog:RefreshStagedSlotIcons()
    for slotName, slotId in pairs(self.inventorySlots) do
        local toServer = self.transmogStatusToServer and self.transmogStatusToServer[slotId]
        local fromServer = self.transmogStatusFromServer and self.transmogStatusFromServer[slotId]
        if toServer ~= nil and fromServer ~= nil and toServer ~= fromServer then
            local iconTex = nil
            if toServer == 0 then
                local eqLink = GetInventoryItemLink('player', slotId)
                if eqLink then
                    local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(eqLink)
                    iconTex = tex
                end
            elseif toServer == Transmog.HIDDEN_ITEM_ID then
                local emptyTexture = string.lower(TransmogFrame_Explode(slotName, 'Slot')[1])
                if emptyTexture == 'wrist' then emptyTexture = 'wrists' end
                if emptyTexture == 'back' then emptyTexture = 'chest' end
                iconTex = 'Interface\\Paperdoll\\ui-paperdoll-slot-' .. emptyTexture
            else
                self:cacheItem(toServer)
                local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(toServer)
                iconTex = tex
            end
            if iconTex then
                local iconObj = getglobal(slotName .. "ItemIcon")
                if iconObj then
                    iconObj:SetTexture(iconTex)
                end
            end
        end
    end
end

-- Stages collected, compatible pieces from the set into transmogStatusToServer.
function Transmog:ApplySetToSlots(set)
    if not set or not set.pieces then return end
    self.transmogStatusFromServer = self.transmogStatusFromServer or {}
    self.transmogStatusToServer = self.transmogStatusToServer or {}

    for _, slot in pairs(self.inventorySlots) do
        self.transmogStatusToServer[slot] = self.transmogStatusFromServer[slot] or 0
    end

    local appliedCount = 0
    local skippedCount = 0

    for _, p in ipairs(set.pieces) do
        if self:IsItemCollected(p.id) then
            local compatible, targetID = self:IsSetPieceCompatibleWithEquipped(p, set)
            if compatible then
                self.transmogStatusToServer[p.slot] = targetID
                appliedCount = appliedCount + 1
            else
                skippedCount = skippedCount + 1
            end
        else
            skippedCount = skippedCount + 1
        end
    end

    self:transmogStatus()
    self:RefreshStagedSlotIcons()
    self:RefreshPendingGlows()
    self:RefreshPreviewModel()
    self:calculateCost()
    self:EnableOutfitSaveButton()

    if appliedCount > 0 then
        PlaySound("igSpellBookOpen")
        if skippedCount > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Transmog]|r Staged " .. appliedCount .. " pieces of |cffa335ee[" .. set.name .. "]|r (" .. skippedCount .. " uncollected or incompatible pieces skipped). Click Apply to transmog!")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Transmog]|r Staged all " .. appliedCount .. " pieces of |cffa335ee[" .. set.name .. "]|r! Click Apply to commit.")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[Transmog]|r No applicable collected appearances found for your equipped gear from [" .. set.name .. "].")
    end
end

-- Saves the set directly as a custom player outfit.
function Transmog:SaveSetAsOutfit(set)
    if not set or not set.pieces then return end

    local outfit = {}
    for _, slot in pairs(self.inventorySlots) do
        outfit[slot] = 0
    end
    for _, p in ipairs(set.pieces) do
        outfit[p.slot] = p.id
    end

    local outfitName = set.name
    transmogOutfits[outfitName] = outfit

    UIDropDownMenu_SetText(TransmogFrameOutfits, outfitName)
    Transmog.currentOutfit = outfitName
    Transmog:EnableOutfitSaveButton()
    PlaySound("igMainMenuOptionCheckBoxOn")
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Transmog]|r Saved |cffa335ee[" .. outfitName .. "]|r to your Outfits dropdown!")
end

-- Class dropdown menu initializer.
local function SetClassDropDown_Initialize()
    local classes = {
        { text = "My Class (" .. (UnitClass("player") or "Player") .. ")", value = string.upper(select(2, UnitClass("player")) or "WARRIOR") },
        { text = "All Classes", value = "ALL" },
        { text = "Death Knight", value = "DEATHKNIGHT" },
        { text = "Druid", value = "DRUID" },
        { text = "Hunter", value = "HUNTER" },
        { text = "Mage", value = "MAGE" },
        { text = "Paladin", value = "PALADIN" },
        { text = "Priest", value = "PRIEST" },
        { text = "Rogue", value = "ROGUE" },
        { text = "Shaman", value = "SHAMAN" },
        { text = "Warlock", value = "WARLOCK" },
        { text = "Warrior", value = "WARRIOR" },
    }

    for _, c in ipairs(classes) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = c.text
        info.value = c.value
        info.checked = (Transmog.selectedSetClass == c.value)
        info.func = function()
            Transmog.selectedSetClass = c.value
            UIDropDownMenu_SetText(TransmogSetClassDropDown, c.text)
            Transmog:UpdateSetList(true)
        end
        UIDropDownMenu_AddButton(info)
    end
end

-- Category dropdown menu initializer.
local function SetCategoryDropDown_Initialize()
    local categories = {
        { text = "All Categories", value = "ALL" },
        { text = "Classic (T0 - T3, AQ, ZG)", value = "CLASSIC" },
        { text = "Burning Crusade (D3, T4 - T6)", value = "TBC" },
        { text = "Wrath of the Lich King (T7 - T10)", value = "WOTLK" },
        { text = "PvP (Arena & Honor Sets)", value = "PVP" },
    }

    for _, cat in ipairs(categories) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = cat.text
        info.value = cat.value
        info.checked = (Transmog.selectedSetCategory == cat.value)
        info.func = function()
            Transmog.selectedSetCategory = cat.value
            UIDropDownMenu_SetText(TransmogSetCategoryDropDown, cat.text)
            Transmog:UpdateSetList(true)
        end
        UIDropDownMenu_AddButton(info)
    end
end

-- Initializes the Sets view frames and widgets.
function Transmog:InitSetsView()
    if self.setsViewInitialized then return end

    -- Default to player's current class
    local _, playerClass = UnitClass("player")
    self.selectedSetClass = string.upper(playerClass or "WARRIOR")
    self.selectedSetCategory = "ALL"

    -- Main sets container (constrained strictly inside TransmogFrame content area)
    local frame = CreateFrame("Frame", "TransmogSetsFrame", TransmogFrame)
    frame:SetPoint("TOPLEFT", TransmogFrame, "TOPLEFT", 252, -80)
    frame:SetWidth(452)
    frame:SetHeight(388)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(TransmogFrame:GetFrameLevel() + 2)
    frame:Hide()

    -- Class filter dropdown
    local classDD = CreateFrame("Frame", "TransmogSetClassDropDown", frame, "UIDropDownMenuTemplate")
    classDD:SetPoint("TOPLEFT", frame, "TOPLEFT", -12, 4)
    UIDropDownMenu_SetWidth(classDD, 115)
    UIDropDownMenu_Initialize(classDD, SetClassDropDown_Initialize)
    UIDropDownMenu_SetText(classDD, "My Class (" .. (UnitClass("player") or "") .. ")")

    -- Category filter dropdown
    local catDD = CreateFrame("Frame", "TransmogSetCategoryDropDown", frame, "UIDropDownMenuTemplate")
    catDD:SetPoint("LEFT", classDD, "RIGHT", -22, 0)
    UIDropDownMenu_SetWidth(catDD, 135)
    UIDropDownMenu_Initialize(catDD, SetCategoryDropDown_Initialize)
    UIDropDownMenu_SetText(catDD, "All Categories")

    self.setsFrame = frame
    self.classDropDown = classDD
    self.categoryDropDown = catDD

    -- Left Column: Set List container
    local listContainer = CreateFrame("Frame", "TransmogSetListContainer", frame)
    listContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -32)
    listContainer:SetWidth(198)
    listContainer:SetHeight(350)
    listContainer:SetFrameLevel(frame:GetFrameLevel() + 1)
    listContainer:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    listContainer:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
    listContainer:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.9)
    listContainer:EnableMouseWheel(true)
    listContainer:SetScript("OnMouseWheel", function(self, delta)
        local bar = TransmogSetScrollFrameScrollBar
        if bar then
            bar:SetValue(bar:GetValue() - delta * SET_BUTTON_HEIGHT)
        end
    end)
    self.listContainer = listContainer

    -- Scroll Frame
    local scrollFrame = CreateFrame("ScrollFrame", "TransmogSetScrollFrame", listContainer, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", listContainer, "BOTTOMRIGHT", -24, 4)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, SET_BUTTON_HEIGHT, function() Transmog:RenderSetList() end)
    end)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local bar = TransmogSetScrollFrameScrollBar
        if bar then
            bar:SetValue(bar:GetValue() - delta * SET_BUTTON_HEIGHT)
        end
    end)
    self.scrollFrame = scrollFrame

    -- Set List Buttons
    self.setButtons = {}
    for i = 1, MAX_VISIBLE_SETS do
        local btn = CreateFrame("Button", "TransmogSetListButton" .. i, listContainer)
        btn:SetWidth(172)
        btn:SetHeight(SET_BUTTON_HEIGHT)
        btn:SetPoint("TOPLEFT", listContainer, "TOPLEFT", 3, -4 - (i - 1) * SET_BUTTON_HEIGHT)
        btn:SetFrameLevel(scrollFrame:GetFrameLevel() + 2)
        btn:EnableMouseWheel(true)
        btn:SetScript("OnMouseWheel", function(self, delta)
            local bar = TransmogSetScrollFrameScrollBar
            if bar then
                bar:SetValue(bar:GetValue() - delta * SET_BUTTON_HEIGHT)
            end
        end)

        -- Row Background texture (using standard WHITE8X8 solid color texture)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetVertexColor(0.08, 0.10, 0.15, 0.5)
        bg:SetAllPoints(btn)
        btn.bg = bg

        -- Highlight texture on hover
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetAllPoints(btn)
        hl:SetBlendMode("ADD")
        btn.highlight = hl

        -- Selected highlight texture (subtle golden tint)
        local sel = btn:CreateTexture(nil, "BORDER")
        sel:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        sel:SetAllPoints(btn)
        sel:SetVertexColor(1, 0.82, 0.1, 0.35)
        sel:SetBlendMode("ADD")
        sel:Hide()
        btn.selectedTex = sel

        -- Set Name text (independent TOPLEFT with explicit width/height)
        local nameText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", btn, "TOPLEFT", 6, -7)
        nameText:SetWidth(116)
        nameText:SetHeight(16)
        nameText:SetJustifyH("LEFT")
        btn.nameText = nameText

        -- Collection Badge text (independent TOPRIGHT with explicit width/height)
        local badge = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        badge:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -4, -7)
        badge:SetWidth(42)
        badge:SetHeight(16)
        badge:SetJustifyH("RIGHT")
        btn.badge = badge

        -- Subtitle text (tier & expansion - independent TOPLEFT with explicit width/height)
        local subText = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subText:SetPoint("TOPLEFT", btn, "TOPLEFT", 6, -26)
        subText:SetWidth(158)
        subText:SetHeight(14)
        subText:SetJustifyH("LEFT")
        btn.subText = subText

        btn:SetScript("OnClick", function()
            if btn.setData then
                Transmog:SelectSet(btn.setData)
            end
        end)

        self.setButtons[i] = btn
    end

    -- Empty placeholder for set list
    local emptyText = listContainer:CreateFontString("TransmogSetEmptyText", "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("CENTER", listContainer, "CENTER", 0, 0)
    emptyText:SetWidth(180)
    emptyText:SetText("No sets match the current filter.")
    emptyText:Hide()
    self.emptyText = emptyText
    _G["TransmogSetEmptyText"] = emptyText

    -- Right Column: Selected Set Details (250px wide, ending at x = 704 cleanly inside inner border)
    local detail = CreateFrame("Frame", "TransmogSetDetailFrame", frame)
    detail:SetPoint("TOPLEFT", frame, "TOPLEFT", 202, -32)
    detail:SetWidth(250)
    detail:SetHeight(350)
    detail:SetFrameLevel(frame:GetFrameLevel() + 1)
    detail:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    detail:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
    detail:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.9)
    self.detailFrame = detail
    _G["TransmogSetDetailFrame"] = detail

    -- Detail Header: Title
    local title = detail:CreateFontString("TransmogSetDetailTitle", "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -8)
    title:SetWidth(230)
    title:SetHeight(18)
    title:SetJustifyH("LEFT")
    self.detailTitle = title
    _G["TransmogSetDetailTitle"] = title

    -- Detail Header: Subtitle
    local sub = detail:CreateFontString("TransmogSetDetailSubtitle", "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -28)
    sub:SetWidth(230)
    sub:SetHeight(14)
    sub:SetJustifyH("LEFT")
    self.detailSubtitle = sub
    _G["TransmogSetDetailSubtitle"] = sub

    -- Detail Header: Progress
    local prog = detail:CreateFontString("TransmogSetDetailProgress", "OVERLAY", "GameFontHighlightSmall")
    prog:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -44)
    prog:SetWidth(230)
    prog:SetHeight(14)
    prog:SetJustifyH("LEFT")
    self.detailProgress = prog
    _G["TransmogSetDetailProgress"] = prog

    -- Separator line
    local sep = detail:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -60)
    sep:SetWidth(234)
    sep:SetHeight(1)
    sep:SetTexture("Interface\\Buttons\\WHITE8X8")
    sep:SetVertexColor(0.35, 0.35, 0.45, 0.8)
    self.detailSep = sep

    -- Pieces container & buttons
    self.pieceButtons = {}
    for i = 1, MAX_PIECES_PER_SET do
        local pBtn = CreateFrame("Button", "TransmogSetPieceButton" .. i, detail)
        pBtn:SetWidth(234)
        pBtn:SetHeight(30)
        pBtn:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -66 - (i - 1) * 33)
        pBtn:SetFrameLevel(detail:GetFrameLevel() + 2)

        -- Icon (26x26 to match character equipment slot icons)
        local icon = pBtn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("LEFT", pBtn, "LEFT", 3, 0)
        icon:SetWidth(26)
        icon:SetHeight(26)
        pBtn.icon = icon

        -- Icon Border
        local iborder = pBtn:CreateTexture(nil, "OVERLAY")
        iborder:SetPoint("CENTER", icon, "CENTER", 0, 0)
        iborder:SetWidth(30)
        iborder:SetHeight(30)
        iborder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        iborder:SetBlendMode("ADD")
        pBtn.iborder = iborder

        -- Status Icon (Green Tick or Red Cross)
        local statusIcon = pBtn:CreateTexture(nil, "ARTWORK")
        statusIcon:SetPoint("RIGHT", pBtn, "RIGHT", -6, 0)
        statusIcon:SetWidth(16)
        statusIcon:SetHeight(16)
        pBtn.statusIcon = statusIcon

        -- Item Name (GameFontNormal for proportional size, occupying full row width)
        local nameText = pBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        nameText:SetPoint("RIGHT", statusIcon, "LEFT", -6, 0)
        nameText:SetHeight(16)
        nameText:SetJustifyH("LEFT")
        pBtn.nameText = nameText

        -- Highlight on hover
        local hl = pBtn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetAllPoints(pBtn)
        hl:SetBlendMode("ADD")

        pBtn:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. self.itemID .. ":0:0:0")
                if self.isCollected then
                    GameTooltip:AddLine("|cff00ff00Collected|r")
                else
                    GameTooltip:AddLine("|cffff4444Not Collected|r")
                end
                GameTooltip:Show()
            end
        end)
        pBtn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        pBtn:SetScript("OnClick", function(self)
            if self.itemID and self.itemID ~= 0 then
                if IsShiftKeyDown() then
                    local _, itemLink = GetItemInfo(self.itemID)
                    if itemLink and ChatEdit_InsertLink then
                        ChatEdit_InsertLink(itemLink)
                    end
                else
                    TransmogFramePlayerModel:TryOn(self.itemID)
                end
            end
        end)

        pBtn:Hide()
        self.pieceButtons[i] = pBtn
    end

    self.setsViewInitialized = true
end

-- Filters and sorts the master set data according to user dropdown choices.
function Transmog:UpdateSetList(resetScroll)
    if not self.SetData then return end
    self:InitSetsView()

    local classFilter = self.selectedSetClass or "ALL"
    local catFilter = self.selectedSetCategory or "ALL"

    local function IsSetForClass(set, filter)
        if not filter or filter == "ALL" then
            return true
        end
        if set.class == filter then
            return true
        end
        -- Support multi-class sets like "WARRIOR, PALADIN"
        if set.class and string.find(set.class, filter) then
            return true
        end
        return false
    end

    self.filteredSets = {}
    for _, set in ipairs(self.SetData) do
        local classMatch = IsSetForClass(set, classFilter)
        local catMatch = (catFilter == "ALL") or (set.expansion == catFilter)

        if classMatch and catMatch then
            table.insert(self.filteredSets, set)
        end
    end

    if resetScroll and self.scrollFrame then
        FauxScrollFrame_SetOffset(self.scrollFrame, 0)
        local bar = TransmogSetScrollFrameScrollBar
        if bar then
            bar:SetValue(0)
        end
    end

    if #self.filteredSets > 0 then
        if self.emptyText then self.emptyText:Hide() end
        -- Default to first set if none selected or selected set is filtered out
        local found = false
        if self.selectedSet then
            for _, s in ipairs(self.filteredSets) do
                if s.id == self.selectedSet.id then
                    found = true
                    break
                end
            end
        end
        if not found then
            self:SelectSet(self.filteredSets[1])
        end
    else
        if self.emptyText then self.emptyText:Show() end
        self:ClearSetDetail()
    end

    self:RenderSetList()
end

-- Renders the scrollable set list items.
function Transmog:RenderSetList()
    if not self.scrollFrame or not self.filteredSets then return end

    local offset = FauxScrollFrame_GetOffset(self.scrollFrame) or 0
    local total = #self.filteredSets

    FauxScrollFrame_Update(self.scrollFrame, total, MAX_VISIBLE_SETS, SET_BUTTON_HEIGHT)

    for i = 1, MAX_VISIBLE_SETS do
        local idx = offset + i
        local btn = self.setButtons and self.setButtons[i]

        if btn then
            if idx <= total then
                local set = self.filteredSets[idx]
                btn.setData = set
                btn.nameText:SetText(set.name or "")
                btn.subText:SetText((set.tier or "") .. " - " .. (set.expansion or ""))

                local collected, count = self:GetSetCollectedCount(set)
                if collected == count and count > 0 then
                    btn.badge:SetText("|cff00ff00" .. collected .. "/" .. count .. "|r")
                elseif collected > 0 then
                    btn.badge:SetText("|cffffff00" .. collected .. "/" .. count .. "|r")
                else
                    btn.badge:SetText("|cff888888" .. collected .. "/" .. count .. "|r")
                end

                if self.selectedSet and self.selectedSet.id == set.id then
                    btn.selectedTex:Show()
                    btn.nameText:SetTextColor(1, 1, 1)
                else
                    btn.selectedTex:Hide()
                    btn.nameText:SetTextColor(1, 0.82, 0)
                end

                btn:Show()
            else
                btn.setData = nil
                btn:Hide()
            end
        end
    end
end

-- Clears the right-hand set detail view.
function Transmog:ClearSetDetail()
    if self.detailTitle then self.detailTitle:SetText("") end
    if self.detailSubtitle then self.detailSubtitle:SetText("") end
    if self.detailProgress then self.detailProgress:SetText("") end
    if self.pieceButtons then
        for i = 1, MAX_PIECES_PER_SET do
            if self.pieceButtons[i] then
                self.pieceButtons[i]:Hide()
            end
        end
    end
end

-- Selects a set, populates its piece list, previews on 3D model, and stages collected pieces.
function Transmog:SelectSet(set)
    if not set then return end
    self.selectedSet = set

    self:RenderSetList()

    if self.detailTitle then
        self.detailTitle:SetText(set.name or "")
    end

    if self.detailSubtitle then
        local subInfo = ""
        if set.class and set.class ~= "ALL" then
            subInfo = set.class
        end
        if set.subtitle and set.subtitle ~= "" and set.subtitle ~= set.class then
            if subInfo ~= "" then
                subInfo = subInfo .. " - " .. set.subtitle
            else
                subInfo = set.subtitle
            end
        end
        if set.tier and set.tier ~= "" then
            if subInfo ~= "" then
                subInfo = subInfo .. " - " .. set.tier
            else
                subInfo = set.tier
            end
        end
        if set.expansion and set.expansion ~= "" then
            subInfo = subInfo .. " (" .. set.expansion .. ")"
        end
        self.detailSubtitle:SetText(subInfo)
    end

    local collected, total = self:GetSetCollectedCount(set)
    local pct = total > 0 and math.floor((collected / total) * 100) or 0
    if self.detailProgress then
        if collected == total and total > 0 then
            self.detailProgress:SetText("|cff00ff00Collected: " .. collected .. " of " .. total .. " pieces (100% Complete!)|r")
        elseif collected > 0 then
            self.detailProgress:SetText("|cffffff00Collected: " .. collected .. " of " .. total .. " pieces (" .. pct .. "%)|r")
        else
            self.detailProgress:SetText("|cff888888Collected: 0 of " .. total .. " pieces (0%)|r")
        end
    end

    -- Populate piece rows
    for i = 1, MAX_PIECES_PER_SET do
        local pBtn = self.pieceButtons and self.pieceButtons[i]
        if pBtn then
            if set.pieces and i <= #set.pieces then
                local piece = set.pieces[i]
                pBtn.itemID = piece.id

                self:cacheItem(piece.id)
                local itemName, _, quality, _, _, _, _, _, _, tex = GetItemInfo(piece.id)

                if not itemName then
                    itemName = piece.name or ("Item " .. piece.id)
                end
                if not quality then
                    quality = piece.quality or 1
                end

                local _, _, _, colorCode = GetItemQualityColor(quality)
                pBtn.nameText:SetText((colorCode or "|cffffffff") .. itemName .. "|r")

                pBtn.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

                local r, g, b = GetItemQualityColor(quality)
                pBtn.iborder:SetVertexColor(r or 1, g or 1, b or 1, 0.7)

                local isCollected = self:IsItemCollected(piece.id)
                pBtn.isCollected = isCollected
                if isCollected then
                    pBtn.statusIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
                    pBtn.statusIcon:Show()
                else
                    pBtn.statusIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
                    pBtn.statusIcon:Show()
                end

                pBtn:Show()
            else
                pBtn.itemID = nil
                pBtn.isCollected = nil
                pBtn:Hide()
            end
        end
    end

    -- Ensure detail frame is visible
    if self.detailFrame then
        self.detailFrame:Show()
    end

    -- Automatically stage collected, compatible pieces for equipped gear
    -- Revert pending changes on all slots to server status first
    self.transmogStatusFromServer = self.transmogStatusFromServer or {}
    self.transmogStatusToServer = self.transmogStatusToServer or {}

    for _, slot in pairs(self.inventorySlots) do
        self.transmogStatusToServer[slot] = self.transmogStatusFromServer[slot] or 0
    end

    for _, piece in ipairs(set.pieces) do
        if self:IsItemCollected(piece.id) then
            local compatible, targetID = self:IsSetPieceCompatibleWithEquipped(piece, set)
            if compatible then
                self.transmogStatusToServer[piece.slot] = targetID
            end
        end
    end

    -- Automatically preview on 3D character model
    self:PreviewSetOnModel(set)

    self:transmogStatus()
    self:RefreshStagedSlotIcons()
    self:RefreshPendingGlows()
    self:calculateCost()
    self:EnableOutfitSaveButton()
end

-- Shows the Sets view when switching tabs.
function Transmog:ShowSetsView()
    local ok, err = pcall(function()
        self:InitSetsView()
        if self.setsFrame then
            self.setsFrame:Show()
        end
        if self.detailFrame then
            self.detailFrame:Show()
        end
        if self.listContainer then
            self.listContainer:Show()
        end
        self:UpdateSetList(false)
    end)
    if not ok then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Transmog Sets Error]|r " .. tostring(err))
    end
end
