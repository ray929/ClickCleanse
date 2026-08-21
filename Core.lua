local _, addon = ...
local L = addon.L or {}

-- -----------------------------------------------------------------------------
-- Chat output colors
-- -----------------------------------------------------------------------------
local COLOR_GREEN  = "|cFF00FF00"
local COLOR_WHITE  = "|cFFFFFFFF"
local COLOR_YELLOW = "|cFFFFFF00"
local COLOR_RED    = "|cFFFF0000"
local COLOR_RESET  = "|r"
local ADDON_PREFIX = COLOR_GREEN .. "[ClickCleanse]" .. COLOR_RESET

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. " " .. COLOR_WHITE .. msg .. COLOR_RESET)
    end
end

local function PrintError(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. " " .. COLOR_RED .. msg .. COLOR_RESET)
    end
end

-- -----------------------------------------------------------------------------
-- Helpers / API shims
-- -----------------------------------------------------------------------------
local C_Spell = _G.C_Spell

local IsSpellKnownFunc = (C_Spell and C_Spell.IsSpellKnown) or _G.IsSpellKnown
local GetSpellNameFunc = (C_Spell and C_Spell.GetSpellName) or function(sid)
    return (GetSpellInfo(sid))
end
local GetSpellCooldownFunc = (C_Spell and C_Spell.GetSpellCooldown)

local function tContains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- Constants
-- -----------------------------------------------------------------------------
local BORDER_SIZE = 4
local MIN_SIZE = 20

local DISPEL_COLORS = {
    Magic  = {0.20, 0.60, 1.00},
    Curse  = {0.60, 0.00, 1.00},
    Poison = {0.00, 0.60, 0.00},
    Disease= {0.60, 0.40, 0.00},
    Bleed  = {1.00, 0.20, 0.20},
}

-- Spell database.  Only friendly dispels are listed.
local DISPEL_SPELLS = {
    DRUID = {
        {spellID = 88423, types = {"Magic", "Poison", "Curse"}, prio = 1}, -- Nature's Cure
        {spellID = 2782,  types = {"Poison", "Curse"},         prio = 2}, -- Remove Corruption
    },
    MAGE = {
        {spellID = 475,   types = {"Curse"},                   prio = 1}, -- Remove Curse
    },
    PALADIN = {
        {spellID = 4987,  types = {"Magic", "Poison", "Disease"}, prio = 1}, -- Cleanse
        {spellID = 213644,types = {"Poison", "Disease"},          prio = 2}, -- Cleanse Toxins
    },
    PRIEST = {
        {spellID = 527,   types = {"Magic"},                   prio = 1}, -- Purify
        {spellID = 213634,types = {"Disease"},                  prio = 2}, -- Purify Disease
    },
    SHAMAN = {
        {spellID = 77130, types = {"Magic", "Curse"},           prio = 1}, -- Purify Spirit
        {spellID = 51886, types = {"Curse"},                    prio = 2}, -- Cleanse Spirit
        {spellID = 383013,types = {"Poison"},                   prio = 3}, -- Poison Cleansing Totem (AoE 脉冲驱毒，落地即生效，[@unit] 由引擎忽略)
    },
    MONK = {
        {spellID = 115450,types = {"Magic"},                    prio = 1, -- Detox (Mistweaver)
                  talent = 388874, extraTypes = {"Poison", "Disease"}},
        {spellID = 218164,types = {"Poison", "Disease"},      prio = 2}, -- Detox (Brewmaster/Windwalker)
    },
    EVOKER = {
        {spellID = 374251,types = {"Poison", "Curse", "Disease", "Bleed"}, prio = 1}, -- Cauterizing Flame
        {spellID = 360823,types = {"Magic", "Poison"},          prio = 2}, -- Naturalize
        {spellID = 365585,types = {"Poison"},                   prio = 3}, -- Expunge
    },
    DEMONHUNTER = {
        {spellID = 205604,types = {"Magic"},                    prio = 1}, -- Reverse Magic (PvP)
    },
}

local MOUSE_KEYS = {"1", "2", "3"}
local BUTTON_LABELS = {
    L.LEFT_CLICK   or "Left click",
    L.RIGHT_CLICK  or "Right click",
    L.MIDDLE_CLICK or "Middle click",
}

local DEFAULT_SIZE = 30

-- 方块相对血条的停靠位置；默认沿用旧行为（血条左侧）。
local ANCHORS = {
    left   = { point = "RIGHT",  relPoint = "LEFT",   dx = -5, dy = 0 },
    right  = { point = "LEFT",   relPoint = "RIGHT",  dx = 5,  dy = 0 },
    top    = { point = "BOTTOM", relPoint = "TOP",    dx = 0,  dy = 5 },
    bottom = { point = "TOP",    relPoint = "BOTTOM", dx = 0,  dy = -5 },
}

-- 持久化设置：SavedVariables（账号级，ADDON_LOADED 时由引擎注入全局表）。
local DB

local function GetDB()
    if not DB then
        DB = _G.ClickCleanseDB or {}
        _G.ClickCleanseDB = DB
    end
    if type(DB.size) ~= "number" or DB.size < 10 or DB.size > 100 then
        DB.size = DEFAULT_SIZE
    end
    if not ANCHORS[DB.anchor] then DB.anchor = "left" end
    if type(DB.debug) ~= "boolean" then DB.debug = false end
    return DB
end

local function GetSquareSize()
    return GetDB().size
end

local function GetAnchor()
    return GetDB().anchor
end

local function IsDebugEnabled()
    return GetDB().debug
end

local units = {"player", "party1", "party2", "party3", "party4"}

local function GetUnitIndex(unit)
    for i, u in ipairs(units) do
        if u == unit then return i end
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------
local dispels = {}
local buttons = {}
local frameCache = {}
local pendingUpdate = false
local addonEnabled = false
local lastRefreshTime = 0
local REFRESH_THROTTLE = 0.5
local lastBindingString = ""
local dispelConfigVersion = 0

local function DebugPrint(...)
    if IsDebugEnabled() and DEFAULT_CHAT_FRAME then
        local msg = table.concat({...}, " ")
        DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. " " .. COLOR_YELLOW .. msg .. COLOR_RESET)
    end
end

-- -----------------------------------------------------------------------------
-- Blizzard-managed aura overlay (12.1)
-- -----------------------------------------------------------------------------
-- WoW 12.1 hides aura data from addon Lua during combat, instances and PvP,
-- so Lua scanning (C_UnitAuras / UnitDebuff) can no longer detect debuffs on
-- party members.  Detection is delegated to Blizzard's managed
-- AuraContainer/AuraButton system instead:
--   * The engine evaluates the protected aura data internally and only shows
--     the managed button when the unit has a harmful aura the active player
--     can dispel (HARMFUL|RAID_PLAYER_DISPELLABLE + includeDispelTypes).
--   * The fill texture is colored by dispel type through a ColorCurve that
--     Blizzard evaluates in the engine; addon code never reads aura data.
--   * The container topology may only be built out of combat.

local AURA_SLOT_KEY = "clickcleanse_dispel"
local AURA_FILTER = "HARMFUL|RAID_PLAYER_DISPELLABLE"

-- Blizzard numeric dispel type codes used on ColorCurves
-- (1=Magic 2=Curse 3=Disease 4=Poison, 9 and 11 both map to Bleed).
local DISPEL_TYPE_CURVE_POINTS = {
    {typeName = "Magic",   code = 1},
    {typeName = "Curse",   code = 2},
    {typeName = "Disease", code = 3},
    {typeName = "Poison",  code = 4},
    {typeName = "Bleed",   code = 9},
    {typeName = "Bleed",   code = 11},
}

local dispelCurve
local initializedManagedAuraButtons = setmetatable({}, { __mode = "k" })

local function BuildDispelTypeFilter()
    local include = {}
    for _, d in ipairs(dispels) do
        for _, t in ipairs(d.types) do include[t] = true end
    end
    return include
end

local function RebuildDispelCurve()
    if not _G.C_CurveUtil or not _G.C_CurveUtil.CreateColorCurve
        or not _G.Enum or not _G.Enum.LuaCurveType or not _G.CreateColor then
        return false
    end
    if not dispelCurve then
        dispelCurve = _G.C_CurveUtil.CreateColorCurve()
        dispelCurve:SetType(_G.Enum.LuaCurveType.Step)
    end
    -- The curve object is mutated in place so textures already registered
    -- with AddDispelTypeTexture pick up new colors on the next reconfigure.
    dispelCurve:ClearPoints()
    dispelCurve:AddPoint(0, _G.CreateColor(0, 0, 0, 0))
    local include = BuildDispelTypeFilter()
    for _, point in ipairs(DISPEL_TYPE_CURVE_POINTS) do
        local c = include[point.typeName] and DISPEL_COLORS[point.typeName]
        if c then
            dispelCurve:AddPoint(point.code, _G.CreateColor(c[1], c[2], c[3], 1))
        else
            dispelCurve:AddPoint(point.code, _G.CreateColor(0, 0, 0, 0))
        end
    end
    return true
end

local function InitializeManagedAuraButton(auraButton, host)
    if initializedManagedAuraButtons[auraButton] then return end
    initializedManagedAuraButtons[auraButton] = true

    -- initializeFrame is the one guaranteed-safe setup window before Blizzard
    -- locks the managed button (DenyTaintedAccessWhenAurasAreSecret).
    pcall(function()
        auraButton:SetAllPoints(host)
        if auraButton.EnableMouse then auraButton:EnableMouse(false) end
        if auraButton.SetMouseClickEnabled then auraButton:SetMouseClickEnabled(false) end
        if auraButton.SetMouseMotionEnabled then auraButton:SetMouseMotionEnabled(false) end
    end)

    -- 整层填充（不内缩）：职业色内层方块在其上方遮住中央，露出的外圈
    -- 即"边框变色"效果。
    local fill = auraButton:CreateTexture(nil, "ARTWORK")
    fill:SetAllPoints(auraButton)
    fill:SetColorTexture(1, 1, 1, 1)

    local styleEnum = _G.Enum and _G.Enum.CustomAuraButtonDispelTypeTextureStyle
    if dispelCurve and styleEnum and styleEnum.PreserveAsset and auraButton.AddDispelTypeTexture then
        local ok = pcall(auraButton.AddDispelTypeTexture, auraButton, fill, {
            style = styleEnum.PreserveAsset,
            showWhenHarmful = true,
            showWhenHelpful = false,
            showWithoutDispelType = false,
            customDispelColorCurve = dispelCurve,
        })
        if not ok then
            DebugPrint("AddDispelTypeTexture failed")
        end
    end
end

local function AttachManagedAura(button, unit)
    if button.auraContainer then return end
    if InCombatLockdown() then return end

    local ok, container = pcall(CreateFrame, "AuraContainer", nil, button, "CustomAuraContainerTemplate")
    if not ok or not container then
        DebugPrint(string.format("%s -> AuraContainer creation failed", unit))
        return
    end

    RebuildDispelCurve()

    button.auraContainer = container
    button.auraConfigVersion = dispelConfigVersion
    container:SetAllPoints(button)
    if container.EnableMouse then pcall(container.EnableMouse, container, false) end
    if container.SetUnit then
        local okUnit = pcall(container.SetUnit, container, unit)
        if not okUnit then
            DebugPrint(string.format("%s -> AuraContainer SetUnit failed", unit))
        end
    end

    if container.AddAuraSlot then
        local options = {
            initializeFrame = function(auraButton)
                InitializeManagedAuraButton(auraButton, button)
            end,
            candidateFilters = { includeDispelTypes = BuildDispelTypeFilter() },
        }
        local okSlot, slotButton = pcall(container.AddAuraSlot, container, AURA_SLOT_KEY, AURA_FILTER, options)
        if okSlot and slotButton then
            pcall(function() slotButton:SetAllPoints(button) end)
        elseif not okSlot then
            DebugPrint(string.format("%s -> AddAuraSlot failed", unit))
        end
    else
        DebugPrint(string.format("%s -> AuraContainer has no AddAuraSlot", unit))
    end

    -- SetEnabled must come last, after the unit and slot declarations exist.
    if container.SetEnabled then pcall(container.SetEnabled, container, true) end
    pcall(container.Show, container)
    if container.UpdateAllAuras then pcall(container.UpdateAllAuras, container) end

    if IsDebugEnabled() then
        local include = BuildDispelTypeFilter()
        local names = {}
        for t in pairs(include) do table.insert(names, t) end
        table.sort(names)
        DebugPrint(string.format("%s -> managed aura container attached (types: %s)",
            unit, table.concat(names, ",")))
    end
end

local function ReconfigureManagedAura(button)
    local container = button.auraContainer
    if not container or not container.SetAuraSlotCandidateFilters then return end
    local ok = pcall(container.SetAuraSlotCandidateFilters, container, AURA_SLOT_KEY, {
        includeDispelTypes = BuildDispelTypeFilter(),
    })
    if IsDebugEnabled() then
        DebugPrint(string.format("managed aura filter updated ok=%s", tostring(ok)))
    end
end

-- -----------------------------------------------------------------------------
-- Dispel discovery
-- -----------------------------------------------------------------------------
-- 类型超集去重：若技能 A 的可驱散类型完全覆盖技能 B，则 B 冗余，不占按键。
-- 例：恢复萨同时知道纯净之魂(魔法+诅咒)与清洁之魂(诅咒)，后者被前者覆盖；
-- 恢复德的自然之恩赐覆盖腐蚀驱散；神圣骑的清洁覆盖清洁毒素。
local function IsTypeSubset(small, big)
    for _, t in ipairs(small) do
        if not tContains(big, t) then return false end
    end
    return true
end

local function PruneRedundantDispels()
    local kept = {}
    for _, d in ipairs(dispels) do
        local redundant = false
        for _, other in ipairs(dispels) do
            if other ~= d and #other.types > #d.types and IsTypeSubset(d.types, other.types) then
                redundant = true
                break
            end
        end
        if not redundant then table.insert(kept, d) end
    end
    wipe(dispels)
    for i, d in ipairs(kept) do dispels[i] = d end
end

local function DiscoverDispels()
    wipe(dispels)
    local _, class = UnitClass("player")
    class = string.upper(class)
    local list = DISPEL_SPELLS[class]

    DebugPrint(string.format("DiscoverDispels | class=%s list=%s",
        class or "?", tostring(list ~= nil)))

    if not list then return dispels end

    for _, entry in ipairs(list) do
        local known = IsSpellKnownFunc(entry.spellID)
        local playerSpell = IsPlayerSpell(entry.spellID)
        local name = GetSpellNameFunc(entry.spellID) or "?"
        DebugPrint(string.format("  spell=%s id=%d known=%s playerSpell=%s",
            name, entry.spellID, tostring(known), tostring(playerSpell)))

        if known or playerSpell then
            local types = {unpack(entry.types)}
            if entry.talent and IsPlayerSpell(entry.talent) then
                for _, t in ipairs(entry.extraTypes) do
                    if not tContains(types, t) then table.insert(types, t) end
                end
            end
            table.insert(dispels, {
                spellID = entry.spellID,
                name  = name,
                types = types,
                prio  = entry.prio,
            })
        end
    end

    table.sort(dispels, function(a, b) return a.prio < b.prio end)

    PruneRedundantDispels()

    for i = 1, math.min(3, #dispels) do
        dispels[i].mouse = MOUSE_KEYS[i]
        dispels[i].label = BUTTON_LABELS[i]
    end

    -- Only keep the first three buttons (left/right/middle).
    for i = #dispels, 4, -1 do
        dispels[i] = nil
    end

    if #dispels > 0 then
        local parts = {}
        for _, d in ipairs(dispels) do
            if d.mouse then
                table.insert(parts, string.format(L.BINDING_FORMAT or "%s: %s", d.label or "", d.name or ""))
            end
        end
        local bindingString = table.concat(parts, ", ")
        if bindingString ~= lastBindingString then
            Print(bindingString)
            lastBindingString = bindingString
        end
    end

    dispelConfigVersion = dispelConfigVersion + 1
    RebuildDispelCurve()

    return dispels
end

-- -----------------------------------------------------------------------------
-- Frame creation
-- -----------------------------------------------------------------------------
local function CreateSquareButton(unit)
    local button = CreateFrame("Button", "ClickCleanse_"..unit, UIParent, "SecureActionButtonTemplate")
    button:SetSize(MIN_SIZE, MIN_SIZE)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown", "AnyUp")
    button:Hide()

    -- 底部白色方块（全尺寸）：干净时显示为白色外圈；有可驱散减益时托管
    -- 引擎在其上渲染驱散类型颜色的整层填充——露出的外圈即"边框变色"。
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)
    button.bg = bg

    -- Attach the Blizzard-managed aura overlay BEFORE the cooldown frame so
    -- the cooldown swipe and countdown render above the managed fill.
    -- (CreateSquareButton only runs out of combat, inside RefreshLayout.)
    AttachManagedAura(button, unit)

    -- 冷却动画（转圈）与方块同尺寸。12.1 起转圈与倒计时数字均由引擎在 C 层
    -- 渲染：SetCooldownFromDurationObject(DurationObject)，Lua 不接触保密数值。
    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawBling(false)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(false)
    cd:SetCooldown(0, 0)
    button.cooldown = cd
    if button.auraContainer and button.auraContainer.GetFrameLevel then
        cd:SetFrameLevel(button.auraContainer:GetFrameLevel() + 10)
    end

    -- 职业色内层方块：比白色方块小一圈（内缩 BORDER_SIZE），叠在托管填充
    -- 之上（container+5，低于冷却的 container+10）——减益变色只出现在外圈，
    -- 职业色始终保留在中央。
    local classLayer = CreateFrame("Frame", nil, button)
    classLayer:SetAllPoints()
    classLayer:EnableMouse(false)
    button.classLayer = classLayer
    local classTex = classLayer:CreateTexture(nil, "ARTWORK")
    classTex:SetPoint("TOPLEFT", classLayer, "TOPLEFT", BORDER_SIZE, -BORDER_SIZE)
    classTex:SetPoint("BOTTOMRIGHT", classLayer, "BOTTOMRIGHT", -BORDER_SIZE, BORDER_SIZE)
    classTex:SetColorTexture(1, 1, 1, 1)
    button.classTex = classTex
    if button.auraContainer and button.auraContainer.GetFrameLevel then
        classLayer:SetFrameLevel(button.auraContainer:GetFrameLevel() + 5)
    end

    button:SetScript("OnMouseDown", function(self, mouseButton)
        if IsDebugEnabled() then
            DebugPrint(string.format("%s -> OnMouseDown: %s", unit, tostring(mouseButton)))
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip_SetDefaultAnchor(GameTooltip, self)
        -- 首行：角色姓名，按职业染色（姓名/职业不属保密光环数据）。
        local name = UnitName(unit)
        if name then
            local classFile = select(2, UnitClass(unit))
            local cc = classFile and RAID_CLASS_COLORS[classFile]
            if cc then
                GameTooltip:AddLine(name, cc.r, cc.g, cc.b)
            else
                GameTooltip:AddLine(name, 1, 1, 1)
            end
        end
        if #dispels == 0 then
            GameTooltip:AddLine(L.NO_DISPEL or "No dispel available", 1, 0, 0)
        else
            for _, d in ipairs(dispels) do
                if d.mouse then
                    GameTooltip:AddLine(string.format(L.BINDING_FORMAT or "%s: %s", d.label or "", d.name or ""), 0.8, 0.9, 1)
                end
            end
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return button
end

local function GetButton(unit)
    if not buttons[unit] then
        buttons[unit] = CreateSquareButton(unit)
    end
    return buttons[unit]
end

-- -----------------------------------------------------------------------------
-- Secure macro assignment
-- -----------------------------------------------------------------------------
local function SetButtonMacros(button, unit)
    for i = 1, 3 do
        button:SetAttribute("type"..i, nil)
        button:SetAttribute("macrotext"..i, nil)
    end
    for _, d in ipairs(dispels) do
        if d.mouse then
            button:SetAttribute("type"..d.mouse, "macro")
            button:SetAttribute("macrotext"..d.mouse,
                string.format("/cast [@%s] %s", unit, d.name))
        end
    end
end

-- -----------------------------------------------------------------------------
-- Anchor / layout discovery
-- -----------------------------------------------------------------------------
local function GetHealthBar(frame)
    local name = frame.GetName and frame:GetName() or ""
    local hb = frame.healthBar or frame.HealthBar
    if hb and hb.GetHeight then return hb end
    for _, child in ipairs({frame:GetChildren()}) do
        local n = child.GetName and child:GetName() or ""
        if (n:find("Health") or n:find("health")) and child.GetHeight then
            return child
        end
    end
    -- Ellesmere Raid Frames: health bar is an unnamed StatusBar inside the button.
    -- Pick the tallest visible StatusBar child, otherwise fall back to the button itself.
    if name:find("ERF") then
        local bestHb, bestH = nil, 0
        for _, child in ipairs({frame:GetChildren()}) do
            local ok1, isStatusBar = pcall(child.IsObjectType, child, "StatusBar")
            local ok2, h = pcall(child.GetHeight, child)
            if ok1 and isStatusBar == true and ok2 and h and h > bestH then
                bestH = h
                bestHb = child
            end
        end
        if bestHb then return bestHb end
        return frame
    end
    return nil
end

local function SafeCompareBool(value)
    local result = false
    pcall(function() result = (value == true) end)
    return result
end

local function SafeIsVisible(frame)
    local ok1, shown = pcall(frame.IsShown, frame)
    if not ok1 then return false end
    if not SafeCompareBool(shown) then return false end

    local ok2, visible = pcall(frame.IsVisible, frame)
    if not ok2 then return false end
    return SafeCompareBool(visible)
end

local function FrameUnit(frame)
    -- Blizzard Compact frames use .unit / .displayedUnit.
    local fu = frame.unit or frame.displayedUnit
    if fu then return fu end
    -- SecureGroupHeader / SecureUnitButtonTemplate store unit in the "unit" attribute.
    local ok, attrUnit = pcall(frame.GetAttribute, frame, "unit")
    if ok and attrUnit then return attrUnit end
    return nil
end

local function FrameMatchesUnit(frame, unit)
    local fu = FrameUnit(frame)
    if not fu then return false end
    if fu == unit then return true end
    local ok, same = pcall(UnitIsUnit, fu, unit)
    if not ok then return false end
    return SafeCompareBool(same)
end

local function FindBlizzardPartyFrame(unit)
    local cpf = _G.CompactPartyFrame
    if cpf then
        for _, child in ipairs({cpf:GetChildren()}) do
            if FrameMatchesUnit(child, unit) then
                return child
            end
        end
    end
    for g = 1, 8 do
        local grp = _G["CompactRaidGroup"..g]
        if grp then
            for _, child in ipairs({grp:GetChildren()}) do
                if FrameMatchesUnit(child, unit) then
                    return child
                end
            end
        end
    end
    return nil
end

local function FindERFFrames()
    local ordered = {}

    -- Self button is always slot 0 (player) when visible.
    local selfBtn = _G.ERFPartySelfButton
    if selfBtn and SafeIsVisible(selfBtn) then
        table.insert(ordered, {name="ERFPartySelfButton", frame=selfBtn})
    end

    -- Party header children: SecureGroupHeaderTemplate-generated unit buttons.
    local partyHeader = _G.ERFPartyHeader
    if partyHeader then
        for i = 1, 5 do
            local btn = partyHeader[i]
            if btn and SafeIsVisible(btn) then
                table.insert(ordered, {name="ERFPartyHeader["..i.."]", frame=btn})
            end
        end
    end

    if IsDebugEnabled() then
        local partyHeaderExists = partyHeader ~= nil
        local partyHeaderShown = partyHeader and SafeIsVisible(partyHeader) or false
        DebugPrint(string.format("ERF debug | header exists=%s shown=%s visible buttons=%d",
            tostring(partyHeaderExists), tostring(partyHeaderShown), #ordered))
    end

    return ordered
end

local function FindERFFrame(unit)
    local frames = FindERFFrames()

    if IsDebugEnabled() then
        local names = {}
        for _, item in ipairs(frames) do
            local fu = FrameUnit(item.frame) or "?"
            table.insert(names, string.format("%s(unit=%s)", item.name, fu))
        end
        DebugPrint("ERFParty frames: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    end

    if #frames == 0 then return nil end

    -- 1. Exact unit match (handles partyN, raidN, player aliases).
    for _, item in ipairs(frames) do
        if FrameMatchesUnit(item.frame, unit) then
            return item.frame
        end
    end

    -- 2. Fallback: assign by ordered index.
    --    ordered[1] = player, ordered[2] = party1, ...
    local idx = GetUnitIndex(unit)
    if idx and frames[idx] then
        return frames[idx].frame
    end

    return nil
end

local function ScoreFrameName(name)
    local n = (name or ""):lower()
    -- Reject obvious non-unit frames.
    if n:find("casting") or n:find("castbar") or n:find("nameplate")
        or n:find("buff") or n:find("debuff") or n:find("aura")
        or n:find("minimap") or n:find("chat") then
        return -100
    end
    if n:find("erf") or n:find("ellesmere") or n:find("eui") or n:find("elvuf") then
        return 3
    end
    if n:find("party") or n:find("raid") then
        return 2
    end
    if n:find("unit") or n:find("player") or n:find("target") or n:find("focus") then
        return 1
    end
    return 0
end

local MAX_ENUMERATE_FRAMES = 1500

local function FindUnitFrame(unit)
    -- 0. Ellesmere Raid Frames.
    local frame = FindERFFrame(unit)
    if frame then
        frameCache[unit] = frame
        return frame
    end

    -- 1. Blizzard raid-style party frames.
    frame = FindBlizzardPartyFrame(unit)
    if frame and SafeIsVisible(frame) then
        frameCache[unit] = frame
        return frame
    end

    -- 2. Reuse cached frame if still valid.
    local cached = frameCache[unit]
    if cached and SafeIsVisible(cached) and FrameMatchesUnit(cached, unit) then
        return cached
    end

    -- 3. Generic global search through visible unit frames.
    local best
    local count = 0
    local f = EnumerateFrames()
    while f and count < MAX_ENUMERATE_FRAMES do
        count = count + 1
        if SafeIsVisible(f) and FrameMatchesUnit(f, unit) then
            local hb = GetHealthBar(f)
            local score = ScoreFrameName(f.GetName and f:GetName())
            if score > 0 and hb and hb:GetHeight() and hb:GetHeight() >= 10 then
                if not best then
                    best = f
                else
                    if score > ScoreFrameName(best.GetName and best:GetName()) then
                        best = f
                    end
                end
            end
        end
        f = EnumerateFrames(f)
    end

    -- 4. Final fallback for the player: anchor to the default PlayerFrame
    --    so solo testing/debugging always has a visible square.
    if not best and unit == "player" then
        local pf = _G.PlayerFrame
        if pf and SafeIsVisible(pf) then
            best = pf
        end
    end

    frameCache[unit] = best
    return best
end

-- -----------------------------------------------------------------------------
-- Visual update
-- -----------------------------------------------------------------------------
-- Affliction detection/coloring is fully owned by the Blizzard-managed aura
-- overlay; addon Lua only paints the clean (class-colored) state.
local function UpdateButtonVisual(button, unit)
    if not button or not button:IsShown() then
        if IsDebugEnabled() then
            DebugPrint(string.format("UpdateButtonVisual | unit=%s skipped (not shown)", unit))
        end
        return
    end

    local _, class = UnitClass(unit)
    local cc = RAID_CLASS_COLORS[class] or {r=0.5, g=0.5, b=0.5}
    button.classTex:SetColorTexture(cc.r, cc.g, cc.b, 1)
end

-- -----------------------------------------------------------------------------
-- Layout refresh
-- -----------------------------------------------------------------------------
local function ShouldShow()
    if #dispels == 0 then return false end
    -- 单人和小队都启用，仅在团队中禁用。
    if IsInRaid() then return false end
    return true
end

local function RefreshLayout(isBootstrap)
    if IsDebugEnabled() then
        DebugPrint(string.format("RefreshLayout called | addonEnabled=%s inCombat=%s", tostring(addonEnabled), tostring(InCombatLockdown())))
    end

    if not addonEnabled then return end

    if InCombatLockdown() then
        pendingUpdate = true
        return
    end

    local now = GetTime()
    if now - lastRefreshTime < REFRESH_THROTTLE then
        pendingUpdate = true
        return
    end
    lastRefreshTime = now
    pendingUpdate = false

    -- 团队中/无驱散技能：直接隐藏全部方块并返回，跳过昂贵的
    -- FindUnitFrame 全局帧枚举（最多 1500 帧 × 5 单位；团队 roster 事件
    -- 频繁触发，不跳过的话纯属浪费）。
    if not ShouldShow() then
        for _, button in pairs(buttons) do
            button:Hide()
        end
        return
    end

    if IsDebugEnabled() then
        DebugPrint(string.format("RefreshLayout | group=%s raid=%s dispels=%d",
            tostring(IsInGroup()), tostring(IsInRaid()), #dispels))
    end

    for _, unit in ipairs(units) do
        local button = GetButton(unit)
        local frame = FindUnitFrame(unit)
        local exists = UnitExists(unit)
        local inParty = (unit == "player") or UnitInParty(unit)
        local hasFrame = frame and SafeIsVisible(frame)
        local show = ShouldShow() and (hasFrame or (exists and inParty))

        local frameName = (frame and frame.GetName and frame:GetName()) or "(nil)"
        -- Always print per-unit decisions when debugging, so users can see why squares are hidden.
        if IsDebugEnabled() then
            DebugPrint(string.format("%s -> frame=%s visible=%s Exists=%s InParty=%s show=%s addonEnabled=%s",
                unit, frameName, tostring(hasFrame), tostring(exists), tostring(inParty), tostring(show), tostring(addonEnabled)))
        end

        if show and frame then
            local hb = GetHealthBar(frame)
            if hb then
                -- 始终保持顶层父子关系（UIParent），只用锚点跟随目标血条。
                -- 绝不能 SetParent 进 ERF/暴雪的 secure header：外来子框架会
                -- 污染 SecureGroupHeader_Update 的安全路径，战斗中触发
                -- ADDON_ACTION_BLOCKED（ERF "StatusBar:SetHeight()"）。
                -- 点击由"同 strata + frameLevel+50 压顶"保证，与父子无关。
                if frame.GetFrameStrata then
                    button:SetFrameStrata(frame:GetFrameStrata())
                end
                button:ClearAllPoints()
                local a = ANCHORS[GetAnchor()]
                button:SetPoint(a.point, hb, a.relPoint, a.dx, a.dy)
                if frame.GetFrameLevel then
                    -- ERF buttons host many layered children (health +2, text +12, auras +13).
                    -- Push our square well above all of them so it actually receives clicks.
                    button:SetFrameLevel(frame:GetFrameLevel() + 50)
                end

                local size = GetSquareSize()
                button:SetSize(size, size)

                -- Spec/talent changes may alter which dispel types Blizzard-managed
                -- detection covers; refresh the container's candidate filters.
                if button.auraContainer and button.auraConfigVersion ~= dispelConfigVersion then
                    ReconfigureManagedAura(button)
                    button.auraConfigVersion = dispelConfigVersion
                end

                SetButtonMacros(button, unit)
                button:Show()
                UpdateButtonVisual(button, unit)

                if IsDebugEnabled() and isBootstrap then
                    local w, h = button:GetSize()
                    local lvl = button:GetFrameLevel()
                    local pName = (button.GetParent and button:GetParent() and button:GetParent().GetName and button:GetParent():GetName()) or "nil"
                    local macroType = button:GetAttribute("type1") or "nil"
                    local macroText = button:GetAttribute("macrotext1") or "nil"
                    local ok, enabled = pcall(button.IsMouseEnabled, button)
                    DebugPrint(string.format("%s -> square size=%dx%d level=%d parent=%s mouse=%s type1=%s macro=%s managed=%s",
                        unit, w, h, lvl, pName, tostring(ok and enabled or false), tostring(macroType), tostring(macroText), tostring(button.auraContainer ~= nil)))
                end
            else
                button:Hide()
            end
        else
            button:Hide()
        end
    end
end

local function RefreshAll(rediscover, skipLayout)
    if rediscover then
        DiscoverDispels()
    end

    if #dispels == 0 then
        addonEnabled = false
        -- 当前职业/专精没有驱散技能：完全禁用，隐藏所有方块。
        for _, button in pairs(buttons) do
            button:Hide()
        end
        return
    end

    addonEnabled = true
    if not skipLayout then
        RefreshLayout()
    end
end

-- -----------------------------------------------------------------------------
-- Events / ticker
-- -----------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("GROUP_LEFT")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("COMPACT_UNIT_FRAME_PROFILES_LOADED")
eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")

local function DelayedRefreshLayout()
    C_Timer.After(0.5, function()
        if not InCombatLockdown() then
            RefreshLayout()
        else
            pendingUpdate = true
        end
    end)
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "ClickCleanse" then
        -- SavedVariables 就绪，立即套用默认值兜底。
        GetDB()
    elseif event == "PLAYER_LOGIN" then
        Print("loaded")
        RefreshAll(true, true)
        if addonEnabled then
            -- ERF/ElvUI party frames initialize asynchronously after PLAYER_LOGIN.
            -- Retry layout several times so the squares attach once the frames exist.
            local attempts = 0
            local maxAttempts = 20
            local function bootstrapLayout()
                attempts = attempts + 1
                if attempts > maxAttempts or not addonEnabled then return end
                RefreshLayout(true)
                -- Keep retrying until every unit that should show has a cached frame.
                local allFound = true
                for _, unit in ipairs(units) do
                    local shouldShow = ShouldShow() and UnitExists(unit) and (unit == "player" or UnitInParty(unit))
                    if shouldShow and not frameCache[unit] then
                        allFound = false
                        break
                    end
                end
                if not allFound then
                    C_Timer.After(0.5, bootstrapLayout)
                elseif IsDebugEnabled() then
                    DebugPrint("bootstrap finished at attempt " .. attempts)
                end
            end
            C_Timer.After(1.0, bootstrapLayout)
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED"
        or event == "ACTIVE_TALENT_GROUP_CHANGED"
        or event == "TRAIT_CONFIG_UPDATED"
        or event == "PLAYER_TALENT_UPDATE" then
        -- 专精/天赋变化可能让职业获得或失去驱散能力，必须重新判定。
        RefreshAll(true)
    elseif event == "GROUP_ROSTER_UPDATE"
        or event == "GROUP_LEFT"
        or event == "COMPACT_UNIT_FRAME_PROFILES_LOADED"
        or event == "DISPLAY_SIZE_CHANGED" then
        if not addonEnabled then return end
        DelayedRefreshLayout()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 战斗结束后补上战斗中被推迟的布局与过滤器更新。
        if addonEnabled and pendingUpdate then
            RefreshLayout()
        end
    end
end)

-- Hook CompactPartyFrame show so anchors re-apply after the frames appear.
if CompactPartyFrame then
    CompactPartyFrame:HookScript("OnShow", function()
        if not addonEnabled then return end
        if not InCombatLockdown() then
            RefreshLayout()
        else
            pendingUpdate = true
        end
    end)
end

-- Cooldown countdown ticker.
-- 12.1：战斗中法术 CD 数字对插件 Lua 是 secret 值（比较即报错）。唯一保密
-- 安全的路径是引擎驱动的 DurationObject（Ayije_CDM / Decursive 同款）：
--   C_Spell.GetSpellCooldownDuration(spellID) → DurationObject
--   cd:SetCooldownFromDurationObject(obj)     → 转圈+倒计时数字全在 C 层渲染
-- Lua 只读 GetSpellCooldown 返回表的布尔字段 isActive/isOnGCD 判断状态
-- （布尔非 secret，可安全分支；数字一律不读、不比较）。
local ticker = CreateFrame("Frame")
ticker.elapsed = 0
ticker.lastDurObj = nil   -- 上次喂入的 DurationObject（引用比较，非数值比较，安全）
ticker.cleared = false    -- 无 CD 状态是否已 Clear 过
ticker:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < 0.1 then return end
    self.elapsed = 0

    -- 无驱散技能的职业（如猎人）：无 CD 可显示，直接早退。
    -- 重要：ticker 绝不能每 0.1s 无条件调 Clear/SetCooldownFromDurationObject
    -- 等受限方法——暴雪按配额计数，持续运行会触发
    -- "insecure scripts exceeded execution limit"（实测 2026-08-21 猎人卡死）。
    if #dispels == 0 or not GetSpellCooldownFunc then
        if not self.cleared then
            for _, button in pairs(buttons) do
                if button.cooldown then button.cooldown:Clear() end
            end
            self.cleared = true
            self.lastDurObj = nil
        end
        return
    end

    local scd = GetSpellCooldownFunc(dispels[1].spellID)
    -- GCD 与真 CD 都显示（action bar 原生行为）：isActive 即喂
    -- DurationObject，GCD/CD 切换由引擎自动处理（施法后全体方块转 GCD
    -- 小圈，真 CD 期间转大圈）。
    local active = scd and (scd.isActive == true)

    local durObj
    if active and C_Spell and C_Spell.GetSpellCooldownDuration then
        durObj = C_Spell.GetSpellCooldownDuration(dispels[1].spellID)
    end

    -- 变化检测：只有 DurationObject 引用变化（新 CD 开始）或从无到有才喂，
    -- 同一 CD 期间引擎自动逐帧渲染，重复喂入既浪费受限调用配额又会重置动画。
    local durObjChanged = (durObj ~= self.lastDurObj)
    if not durObj and not self.cleared then
        for _, button in pairs(buttons) do
            if button.cooldown then button.cooldown:Clear() end
        end
        self.cleared = true
    elseif durObj then
        self.cleared = false
    end
    self.lastDurObj = durObj
    if not (durObj and durObjChanged) then return end

    local size = GetSquareSize()
    for _, button in pairs(buttons) do
        local cd = button.cooldown
        if cd and button:IsShown() then
            pcall(cd.SetCooldownFromDurationObject, cd, durObj)
            -- 内置倒计时数字 FontString 首次喂入后才创建，字体后置应用
            -- （幂等；数字 FontString 带 secret aspect，SetFont 必须 pcall）。
            if button.cdFontKey ~= size then
                local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
                if cds then
                    pcall(cds.SetFont, cds, "Fonts\\FRIZQT__.TTF", math.max(10, math.floor(size / 2)), "OUTLINE")
                    button.cdFontKey = size
                end
            end
        end
    end
end)

-- Manual slash command.  "/cc" is not registered because it conflicts with
-- Blizzard Click Casting; "/ccl" is the primary prefix.
SLASH_CLICKCLEANSE1 = "/ccl"
SLASH_CLICKCLEANSE2 = "/clickcleanse"
SlashCmdList["CLICKCLEANSE"] = function(msg)
    local lower = (msg or ""):lower()

    if lower == "debug" then
        local db = GetDB()
        db.debug = not db.debug
        Print(db.debug and "Debug output enabled" or "Debug output disabled")
        if db.debug then
            RefreshAll(true)
        end
        return
    end

    if lower == "left" or lower == "right" or lower == "top" or lower == "bottom" then
        GetDB().anchor = lower
        Print("Anchor set to " .. lower)
        RefreshLayout()
        return
    end

    local num = tonumber(msg)
    if num then
        if num < 10 or num > 100 then
            PrintError("Size must be between 10 and 100")
            return
        end
        GetDB().size = num
        Print("Square size set to " .. num)
        RefreshLayout()
        return
    end

    Print("Manual refresh triggered")
    RefreshAll(true)
end
