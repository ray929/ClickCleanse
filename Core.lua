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

-- WoW: Forever（内部代号 Camelot，即"永恒"）跑在现代化客户端上：与 12.1 同一套
-- API 家族与保密光环系统，但职业/法术/等级沿用香草（Vanilla）规则，界面版本号
-- 为 16001。用版本号判定最稳——早期 beta 的 WOW_PROJECT_ID 报 1（Mainline），
-- 后续 build 才报 18（WOW_PROJECT_CAMELOT）。
local IS_FOREVER = false
do
    local ok, version, _, _, tocversion = pcall(GetBuildInfo)
    -- 1.60.x（=_forever_ 的 1.60.1.70790）同样按永恒处理：部分 build 的
    -- TOC 版本号不一定报 16001，版本串是更直接的信号。
    if ok and type(version) == "string" and version:find("^1%.60") then
        IS_FOREVER = true
    elseif ok and tocversion and tocversion >= 16000 and tocversion < 20000 then
        IS_FOREVER = true
    elseif _G.WOW_PROJECT_CAMELOT ~= nil and _G.WOW_PROJECT_ID == _G.WOW_PROJECT_CAMELOT then
        IS_FOREVER = true
    end
end

-- 保密值可读性谓词：12.1/永恒的受限状态下，对 secret 值做比较或布尔测试会抛错。
local canAccessValue = _G.canaccessvalue or function() return true end

local IsSpellKnownFunc = (C_Spell and C_Spell.IsSpellKnown) or _G.IsSpellKnown

-- 法术名解析：永恒移除了全局 GetSpellInfo，按 C_Spell.GetSpellName →
-- C_Spell.GetSpellInfo（返回表）→ 全局 GetSpellInfo 逐级回退。
local function GetSpellNameFunc(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellID)
        if name then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then return info.name end
    end
    if _G.GetSpellInfo then
        local name = (_G.GetSpellInfo(spellID))
        if name then return name end
    end
    return nil
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
local MIN_SIZE = 20

-- 亮色版驱散类型色（用户要求鲜艳：天蓝/亮紫/亮绿/明黄/明红）。
-- 注意感知亮度：人眼对绿最敏感（权重 0.7152），亮绿的 G 值略压（0.90），
-- 避免在黑底职业色上刺眼失衡；其余颜色放开发到近满饱和。
local DISPEL_COLORS = {
    Magic  = {0.00, 0.55, 0.90},  -- 天蓝（用户嫌浅加深一档，原 0.70,1.0）
    Curse  = {0.50, 0.15, 0.95},  -- 深亮紫（用户反馈亮紫偏浅，加深一档）
    Poison = {0.00, 0.75, 0.10},  -- 亮绿（用户嫌浅加深一档，原 0.90,0.15）
    Disease= {1.00, 0.90, 0.00},  -- 明黄
    Bleed  = {1.00, 0.20, 0.10},  -- 明红
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
        -- Improved Purify (390632) 点出后 Purify 追加疾病（对照 Decursive RC3：
        -- IMPROVED_PURIFY 增强检查；用于 213634 未学而天赋已点的场景，需实测确认）。
        {spellID = 527,   types = {"Magic"},                   prio = 1, -- Purify
                  talent = 390632, extraTypes = {"Disease"}},
        {spellID = 213634,types = {"Disease"},                  prio = 2}, -- Purify Disease
    },
    SHAMAN = {
        -- Purify Spirit 基础只有魔法，诅咒需天赋 Improved Purify Spirit
        -- (383016)（对照 Decursive RC3：IMPROVED_PURIFY_SPIRIT 增强检查）。
        {spellID = 77130, types = {"Magic"},                    prio = 1, -- Purify Spirit
                  talent = 383016, extraTypes = {"Curse"}},
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
    WARLOCK = {
        -- 烧灼驱魔（Singe Magic）：驱散友方一个魔法效果。宽松绑定（用户
        -- 明确要求）：不检测天赋/宠物/override 状态，职业为术士即默认
        -- 可用。来源参考：①小鬼宠物（恶魔掌控 override 形态，89808）；
        -- ②魔典：小鬼领主（1276452）激活期间替换为 132411（15s CD）。
        -- 绑定用 132411 的名字（zhCN"烧灼驱魔"），能否实际施放由游戏
        -- 运行时判断，宏失败无害。
        {spellID = 132411, types = {"Magic"}, prio = 1, warlock = true},
    },
}

-- WoW: Forever（香草规则）的驱散技能表。现代技能（净化灵魂/清洁毒素/自然之愈等）
-- 在永恒里不存在，香草时期的驱散法术按 Decursive 的 Classic 表核对：
--   * 德鲁伊：解除诅咒 2782（诅咒）、强力驱毒 2893（中毒）
--   * 法师：解除次级诅咒 475（诅咒）
--   * 圣骑士：清洁术 4987（魔法/疾病/中毒）
--   * 牧师：驱散魔法 527（魔法）、祛病术 528（疾病）
--   * 萨满：驱病术 2870（疾病）、驱毒术 526（中毒）
--   * 术士：地狱犬的吞噬魔法 19505（魔法，宠物技能）
-- 这里有意省略同类型的其它形态（驱毒术 8946、废除疾病 552、圣骑士净化术 1152）：
-- 永恒的驱散能力按职业固定，同一类型绑定两个键纯属冗余（552 是 528 的升级版，
-- 两条都收会占两个鼠标键，故只收 528）。
local DISPEL_SPELLS_FOREVER = {
    DRUID = {
        {spellID = 2782, types = {"Curse"},                prio = 1}, -- Remove Curse
        {spellID = 2893, types = {"Poison"},               prio = 2}, -- Abolish Poison
    },
    MAGE = {
        {spellID = 475,  types = {"Curse"},                prio = 1}, -- Remove Lesser Curse
    },
    PALADIN = {
        {spellID = 4987, types = {"Magic", "Disease", "Poison"}, prio = 1}, -- Cleanse
    },
    PRIEST = {
        {spellID = 527,  types = {"Magic"},                prio = 1}, -- Dispel Magic
        -- 永恒的 zhCN 客户端里"祛病术"是 528（Cure Disease）；552（Abolish
        -- Disease）是更晚学到的升级版，同类型再绑一个键属冗余，故只收 528。
        {spellID = 528,  types = {"Disease"},              prio = 2}, -- Cure Disease
    },
    SHAMAN = {
        {spellID = 2870, types = {"Disease"},              prio = 1}, -- Cure Disease
        {spellID = 526,  types = {"Poison"},               prio = 2}, -- Cure Poison
    },
    WARLOCK = {
        {spellID = 19505, types = {"Magic"},               prio = 1}, -- Devour Magic (Felhunter)
    },
}

local MOUSE_KEYS = {"1", "2", "3"}
local BUTTON_LABELS = {
    L.LEFT_CLICK   or "Left click",
    L.RIGHT_CLICK  or "Right click",
    L.MIDDLE_CLICK or "Middle click",
}

local DEFAULT_SIZE = 30

-- 方块相对队员血条的停靠位置；拿不到血条的方块（战斗中途加入/框未就绪）
-- 先停到队伍框旁的预留列，脱战刷新时自动吸附回来。
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

-- 受保护框架（SecureActionButton 带 macrotext）的 Show/Hide 在战斗中会被
-- 禁止（ADDON_ACTION_BLOCKED），所以方块显隐交给安全状态驱动
-- （RegisterStateDriver，见下方 RegisterVisibilityDriver）：战斗中的
-- 队友加入/退出由引擎按"单位是否存在"自行显隐，Lua 不再插手。

-- 12.1 / 永恒：UnitExists 这类返回布尔值的 API 在保密上下文里可能返回
-- secret 值，对 secret 做比较或布尔测试会直接抛错。读取失败时按"存在"
-- 处理——读取失败不会误隐藏方块。
local function SafeUnitExists(unit)
    local ok, exists = pcall(function() return UnitExists(unit) == true end)
    if not ok then return true end
    return exists == true
end

-- 12.1 / 永恒：单位姓名可能是 secret 字符串（拼接/打印都会抛错）。读不到就
-- 不显示姓名行，工具提示的其余内容照常。
local function SafeUnitName(unit)
    local ok, name = pcall(UnitName, unit)
    if not ok or type(name) ~= "string" then return nil end
    if not canAccessValue(name) then return nil end
    return name
end
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
--     the managed button when the unit has a harmful aura matching the slot's
--     candidateFilters (includeDispelTypes, built from our own spell table).
--   * The fill texture is colored by dispel type through a ColorCurve that
--     Blizzard evaluates in the engine; addon code never reads aura data.
--   * The container topology may only be built out of combat.
-- Filter string is plain "HARMFUL" on purpose: the RAID_PLAYER_DISPELLABLE
-- token only knows class/spec baseline dispels, so it never matches Poison
-- for a shaman whose poison removal is Poison Cleansing Totem (a talent),
-- nor Bleed for evokers (Cauterizing Flame) or monk talent Detox types.
-- Our includeDispelTypes already gates the types we can actually dispel.

local AURA_SLOT_KEY = "clickcleanse_dispel"
local AURA_FILTER = "HARMFUL"

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
local highlightCurve
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
    if not highlightCurve then
        highlightCurve = _G.C_CurveUtil.CreateColorCurve()
        highlightCurve:SetType(_G.Enum.LuaCurveType.Step)
    end
    -- The curve object is mutated in place so textures already registered
    -- with AddDispelTypeTexture pick up new colors on the next reconfigure.
    dispelCurve:ClearPoints()
    dispelCurve:AddPoint(0, _G.CreateColor(0, 0, 0, 0))
    highlightCurve:ClearPoints()
    highlightCurve:AddPoint(0, _G.CreateColor(0, 0, 0, 0))
    local include = BuildDispelTypeFilter()
    for _, point in ipairs(DISPEL_TYPE_CURVE_POINTS) do
        local c = include[point.typeName] and DISPEL_COLORS[point.typeName]
        if c then
            dispelCurve:AddPoint(point.code, _G.CreateColor(c[1], c[2], c[3], 1))
            -- 高亮描边统一用白色：与类型色填充同条件显示，形成"点亮"效果。
            highlightCurve:AddPoint(point.code, _G.CreateColor(1, 1, 1, 1))
        else
            dispelCurve:AddPoint(point.code, _G.CreateColor(0, 0, 0, 0))
            highlightCurve:AddPoint(point.code, _G.CreateColor(0, 0, 0, 0))
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
    -- 保存引用：引擎只在有匹配 debuff 时 Show/点亮该贴图（无 debuff 时
    -- 隐藏），ticker 借此判断"当前是否有可驱散减益"——战斗中贴图可见性
    -- 是干净的渲染状态（非 secret 数值），且读取永远在引擎侧完成。
    auraButton.fillTex = fill
    -- 同引用挂在方块按钮上（host）：HasActiveDebuff 遍历 buttons（方块），
    -- 引擎点亮的是托管槽按钮上的这张贴图，二者须指向同一纹理对象。
    host.fillTex = fill

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

    -- 高亮描边：4 条白色贴图环绕方块外侧（上/下两条加宽盖住两角），
    -- 注册到 highlightCurve（白色，仅计入当前可驱散类型）。引擎只在
    -- 有害减益出现时点亮——与整层填充同一机制，战斗中合法。锚点全部
    -- 相对 auraButton，方块改尺寸时描边自动跟随（粗细固定，重建时重算）。
    -- 注意：initializeFrame 之后托管按钮被锁定，描边只能在创建时布局。
    local thickness = math.max(2, math.floor(GetSquareSize() / 12))
    local edges = {}
    for i = 1, 4 do
        local tex = auraButton:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(1, 1, 1, 1)
        edges[i] = tex
    end
    local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
    top:SetPoint("BOTTOMLEFT", auraButton, "TOPLEFT", -thickness, 0)
    top:SetPoint("BOTTOMRIGHT", auraButton, "TOPRIGHT", thickness, 0)
    top:SetHeight(thickness)
    bottom:SetPoint("TOPLEFT", auraButton, "BOTTOMLEFT", -thickness, 0)
    bottom:SetPoint("TOPRIGHT", auraButton, "BOTTOMRIGHT", thickness, 0)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPRIGHT", auraButton, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMRIGHT", auraButton, "BOTTOMLEFT", 0, 0)
    left:SetWidth(thickness)
    right:SetPoint("TOPLEFT", auraButton, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMLEFT", auraButton, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(thickness)

    if highlightCurve and styleEnum and styleEnum.PreserveAsset and auraButton.AddDispelTypeTexture then
        for _, tex in ipairs(edges) do
            local okEdge = pcall(auraButton.AddDispelTypeTexture, auraButton, tex, {
                style = styleEnum.PreserveAsset,
                showWhenHarmful = true,
                showWhenHelpful = false,
                showWithoutDispelType = false,
                customDispelColorCurve = highlightCurve,
            })
            if not okEdge then
                DebugPrint("AddDispelTypeTexture failed (highlight edge)")
            end
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
    button.auraUnit = nil
    if container.SetUnit then
        local okUnit = pcall(container.SetUnit, container, unit)
        if okUnit then
            button.auraUnit = unit
        else
            DebugPrint(string.format("%s -> AuraContainer SetUnit failed", unit))
        end
    end

    if container.AddAuraSlot then
        local options = {
            initializeFrame = function(auraButton)
                InitializeManagedAuraButton(auraButton, button)
            end,
            candidateFilters = { includeDispelTypes = BuildDispelTypeFilter() },
            -- 固定排序（Decursive RC3 同款）：同单位多个不同类型 debuff 时，
            -- 槽按钮显示的类型色保持稳定，不在光环更新间跳动。
            sortMethod = 0,
            sortDirection = 0,
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

-- 类型名按驱散配色着色（聊天打印用）：|cFFRRGGBB + 本地化类型名。
-- 颜色取自 DISPEL_COLORS（与方块填充同源，改配色自动跟随）。
local function ColoredTypeName(typeName)
    local name = (L.TEST_TYPE_NAMES and L.TEST_TYPE_NAMES[typeName]) or typeName
    local c = DISPEL_COLORS[typeName]
    if c then
        return string.format("|cFF%02X%02X%02X%s|r",
            math.floor(c[1] * 255 + 0.5),
            math.floor(c[2] * 255 + 0.5),
            math.floor(c[3] * 255 + 0.5),
            name)
    end
    return name
end

-- 永恒术士：吞噬魔法是宠物技能，只存在于地狱犬的宠物动作条上。按动作条
-- 里的技能名（本地化，与 spellID 解析出的名字同源）判断当前宠物有没有；
-- 读不到宠物动作条信息时按"有"处理（宽松，宏里的 pet: 条件仍会兜底）。
local function PetHasSpellNamed(spellName)
    if type(_G.GetPetActionInfo) ~= "function" or not spellName then return true end
    local slots = _G.NUM_PET_ACTION_SLOTS or 10
    for i = 1, slots do
        local ok, match = pcall(function()
            local name = (_G.GetPetActionInfo(i))
            return name == spellName
        end)
        if ok and match then return true end
    end
    return false
end

-- 技能是否已学：返回 true / false；所有"已学"API 都不可用或全部读取报错
-- （保密值）时返回 nil，由调用方决定是否宽松启用。
local function IsSpellLearned(spellID)
    local anyApi, answered = false, false

    -- 每个 API 都走 pcall；只有"无报错地"返回过布尔值才算有结论，
    -- 避免某个 API 在未知 ID 上报错就把整体误判成"读不到"。
    local function check(ok, value)
        anyApi = true
        if not ok then return false end
        answered = true
        return value == true
    end

    local C_SpellBook = _G.C_SpellBook
    if IsSpellKnownFunc and check(pcall(IsSpellKnownFunc, spellID)) then
        return true
    end
    if C_SpellBook and C_SpellBook.IsSpellKnown
        and check(pcall(C_SpellBook.IsSpellKnown, spellID)) then
        return true
    end
    -- 永恒等非标准 build 上，法术书查询是更可靠的"已学"来源（EllesmereUI
    -- 的 EUI_UnitFrames_Lifecycle 同款用法）。
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook and _G.Enum
        and _G.Enum.SpellBookSpellBank
        and check(pcall(C_SpellBook.IsSpellInSpellBook, spellID,
            _G.Enum.SpellBookSpellBank.Player, true)) then
        return true
    end
    if _G.IsPlayerSpell and check(pcall(_G.IsPlayerSpell, spellID)) then
        return true
    end
    if _G.IsSpellKnownOrOverridesKnown then
        if check(pcall(_G.IsSpellKnownOrOverridesKnown, spellID)) then return true end
        if check(pcall(_G.IsSpellKnownOrOverridesKnown, spellID, true)) then return true end
    end

    if not anyApi or not answered then return nil end
    return false
end

local function DiscoverDispels()
    wipe(dispels)
    local okClass, class = pcall(function() return select(2, UnitClass("player")) end)
    if not okClass or type(class) ~= "string" then return dispels end
    class = string.upper(class)
    -- 永恒（香草规则）有自己的技能表：现代驱散技能在那边不存在。
    local list = (IS_FOREVER and DISPEL_SPELLS_FOREVER[class]) or DISPEL_SPELLS[class]

    DebugPrint(string.format("DiscoverDispels | class=%s forever=%s list=%s",
        class or "?", tostring(IS_FOREVER), tostring(list ~= nil)))

    if not list then return dispels end

    for _, entry in ipairs(list) do
        local spellID = entry.spellID
        local name = GetSpellNameFunc(spellID)
        local learned = IsSpellLearned(spellID)
        DebugPrint(string.format("  spell=%s id=%s learned=%s",
            name or "?", tostring(spellID), tostring(learned)))

        local active
        if entry.warlock then
            -- 零售术士宽松绑定（用户明确要求，见上方技能表注释）。
            active = true
        elseif IS_FOREVER then
            -- 永恒：香草驱散没有专精/天赋门控，但有等级门槛。旧版无条件启用
            -- 会把"还没学"的技能也绑到鼠标键上，点击宏静默失败（2026-11-05
            -- 牧师 lv12 实测：学会了祛病术 528，但左/右键绑的是未学的 527/552）。
            -- 改为按已学判定；只有所有已学 API 都读不到时才退回宽松启用。
            active = (learned == nil) or learned
        else
            -- 零售：按已学判定（IsSpellLearned 已做 pcall + 保密值保护）。
            active = (learned == true)
        end

        -- 法术名拿不到（法术数据尚未缓存）时跳过：宏文本依赖技能名。
        if active and not name then
            DebugPrint(string.format("  id=%s -> spell name unavailable, skipped", tostring(spellID)))
            active = false
        end

        -- 永恒的术士吞噬魔法是地狱犬的宠物技能：宠物不在场（或换了宠物）
        -- 时这个方块没有意义，按宠物动作条内容再确认一次。
        if active and IS_FOREVER and spellID == 19505 then
            active = PetHasSpellNamed(name)
        end

        if active then
            local types = {unpack(entry.types)}
            if entry.talent and _G.IsPlayerSpell and IsPlayerSpell(entry.talent) then
                for _, t in ipairs(entry.extraTypes) do
                    if not tContains(types, t) then table.insert(types, t) end
                end
            end
            table.insert(dispels, {
                spellID = spellID,
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
                -- 绑定说明附各技能的可驱散类型（按类型着色）。类型纳入
                -- lastBindingString 比对：天赋只改类型（如净化灵魂获得
                -- 诅咒）而绑定技能不变时，也能触发打印、不再静默。
                local line = string.format(L.BINDING_FORMAT or "%s: %s", d.label or "", d.name or "")
                local typeNames = {}
                for _, t in ipairs(d.types) do
                    table.insert(typeNames, ColoredTypeName(t))
                end
                if #typeNames > 0 then
                    line = line .. " → " .. table.concat(typeNames, "/")
                end
                table.insert(parts, line)
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
-- 职业色内缩量 = 方块尺寸的 10%（每边），中央剩 80%。
-- 创建时与每次 /ccl 调尺寸后都要调用（锚点偏移随尺寸变化）。
local function ApplyClassInset(button)
    local inset = math.max(2, math.floor(GetSquareSize() * 0.1))
    button.classTex:ClearAllPoints()
    button.classTex:SetPoint("TOPLEFT", button.classLayer, "TOPLEFT", inset, -inset)
    button.classTex:SetPoint("BOTTOMRIGHT", button.classLayer, "BOTTOMRIGHT", -inset, inset)
end

local function CreateSquareButton(unit)
    local button = CreateFrame("Button", "ClickCleanse_"..unit, UIParent, "SecureActionButtonTemplate")
    button:SetSize(MIN_SIZE, MIN_SIZE)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyDown", "AnyUp")
    button:Hide()
    -- 每个方块永久绑定一个 unit token（player/party1..4），预建一次后不再
    -- 换绑：战斗中队友加入/退出只靠安全状态驱动显隐。
    button.unitToken = unit
    -- 固定列不再压在各队员框上，MEDIUM + 固定层级即可（不要 HIGH：会盖住
    -- 小地图等 MEDIUM UI）。层级在创建时定好，战斗中不再改动。
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(100)

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

    -- 职业色内层方块：每边内缩 10%（ApplyClassInset），叠在托管填充之上
    -- （container+5，低于冷却的 container+10）——debuff 时类型色从四周
    -- 露出一圈（约 10% 宽）+ 中央混合，职业色印记保持在中央 80% 区域。
    local classLayer = CreateFrame("Frame", nil, button)
    classLayer:SetAllPoints()
    classLayer:EnableMouse(false)
    button.classLayer = classLayer
    local classTex = classLayer:CreateTexture(nil, "ARTWORK")
    classTex:SetColorTexture(1, 1, 1, 1)
    button.classTex = classTex
    ApplyClassInset(button)
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
        local name = SafeUnitName(unit)
        if name then
            local okClass, classFile = pcall(function() return select(2, UnitClass(unit)) end)
            local cc = (okClass and type(classFile) == "string")
                and RAID_CLASS_COLORS[classFile] or nil
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
            local text
            if d.spellID == 132411 then
                -- 术士分号分支宏：①[pet:imp/小鬼] 直呼烧灼驱魔——小鬼在
                -- 场时恶魔掌控被 override 为烧灼驱魔，玩家书可按名施放
                -- （用户实测可用，注意坐骑上宠物技能不可用）；②[nopet:
                -- imp/小鬼] 施放魔典：小鬼领主本体（1276452）——魔典激活
                -- 时引擎路由到烧灼驱魔，未激活时点下去=开启魔典获得驱散
                -- （宽松语义）。宠物类型名是本地化的，enUS=imp / zhCN=
                -- 小鬼，斜杠 OR 并列覆盖两端。名字含全角冒号，运行时解析。
                local grimoire = GetSpellNameFunc(1276452) or "魔典：小鬼领主"
                text = string.format(
                    "/cast [pet:imp/小鬼, @%s] %s; [nopet:imp/小鬼, @%s] %s",
                    unit, d.name, unit, grimoire)
            elseif d.spellID == 19505 then
                -- 永恒（香草规则）术士：吞噬魔法是地狱犬的宠物技能，只有
                -- 地狱犬在场才能施放。pet: 条件是本地化的宠物类型名
                -- （enUS=felhunter / zhCN=地狱犬），条件不满足时宏静默不施放。
                text = string.format("/cast [pet:felhunter/地狱犬, @%s] %s", unit, d.name)
            else
                text = string.format("/cast [@%s] %s", unit, d.name)
            end
            button:SetAttribute("type"..d.mouse, "macro")
            button:SetAttribute("macrotext"..d.mouse, text)
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
    -- 默认（非 raid 式）队伍框：PartyMemberFrameTemplate 的血条在
    -- HealthBarContainer.HealthBar，且成员框是 CreateFramePool 创建的匿名帧
    -- （子帧没有名字），既取不到 frame.healthBar 也扫不到 "Health" 子帧。
    local hbc = frame.HealthBarContainer
    if hbc and hbc.HealthBar and hbc.HealthBar.GetHeight then
        return hbc.HealthBar
    end
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
    -- 默认（非 raid 式）队伍框：PartyFrame["MemberFrame1".."MemberFrame4"]。
    -- 只覆盖队友（团队由 ShouldShow() 直接关闭，不在这里处理 raid 单位）。
    local pf = _G.PartyFrame
    if pf then
        for i = 1, 4 do
            local child = pf["MemberFrame"..i]
            if child and FrameMatchesUnit(child, unit) then
                return child
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
    -- EnumerateFrames 在永恒等非标准客户端上可能不存在：此时跳过全局枚举，
    -- 退回前两步（ERF/暴雪队伍框）与 player 的 PlayerFrame 兜底。
    local best
    local count = 0
    local f = _G.EnumerateFrames and _G.EnumerateFrames()
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
-- 固定列模式下方块可能被状态驱动隐藏（对应单位不存在），此处不判断
-- 可见性，直接设色即可（只改贴图，不涉及受保护操作）。
local function UpdateButtonVisual(button)
    -- 中央底色一律白色 alpha=0.2（无 debuff 时低调的白印记；有 debuff 时
    -- 中央也主要显示下方的类型色填充，白色仅微微透出提亮）。
    button.classTex:SetColorTexture(1, 1, 1, 0.2)
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

-- 方块列的锚点：优选队伍框容器（尺寸覆盖全部队员槽位），单人时退回玩家框。
-- 队伍框在战斗中会重排/移动，但容器本身位置稳定，固定列因此不会跟着重排。
local function FindColumnAnchorFrame()
    if IsInGroup() then
        local candidates = {}
        local hdr = _G.ERFPartyHeader
        if hdr and hdr.GetParent then
            candidates[#candidates + 1] = hdr:GetParent()
        end
        candidates[#candidates + 1] = _G.CompactPartyFrame
        candidates[#candidates + 1] = _G.PartyFrame
        -- 先用"正在显示"的容器（不同队伍框方案下只有一个真正可见）。
        for _, f in ipairs(candidates) do
            if f and SafeIsVisible(f) then return f end
        end
        for _, f in ipairs(candidates) do
            if f then return f end
        end
    end
    local playerFrame = FindUnitFrame("player")
    if playerFrame then return playerFrame end
    return _G.PlayerFrame or UIParent
end

-- 安全状态驱动：由引擎按"单位是否存在"显隐方块（战斗中同样有效），
-- 所以队友加入/退出时无需 Lua 再调 Show/Hide/SetPoint——那些在战斗锁定
-- 下对受保护按钮是被禁止的。团队中由 [group:raid] 整体隐藏。
local VISIBILITY_DRIVER = "[group:raid] hide; [@%s,exists] show; hide"

local function RegisterVisibilityDriver(button)
    if button.visibilityDriver then return end
    local unit = button.unitToken
    if not unit then return end
    if not _G.RegisterStateDriver then
        -- 理论上现代客户端都有；缺失时退回脱战显隐（战斗中无法变更）。
        button:SetShown(SafeUnitExists(unit) and not IsInRaid())
        return
    end
    local ok = pcall(_G.RegisterStateDriver, button, "visibility",
        string.format(VISIBILITY_DRIVER, unit))
    if not ok then
        DebugPrint(string.format("%s -> RegisterStateDriver failed", unit))
        return
    end
    button.visibilityDriver = true
    -- 注册后先同步一次显示状态；之后由驱动接管（含战斗中的单位出现/消失）。
    if IsInRaid() then
        button:Hide()
    else
        button:SetShown(SafeUnitExists(unit))
    end
end

local function UnregisterVisibilityDriver(button)
    if not button.visibilityDriver then return end
    button.visibilityDriver = false
    if _G.UnregisterStateDriver then
        pcall(_G.UnregisterStateDriver, button, "visibility")
    end
end

-- 预留列：给"暂时没有血条可挂"的方块一个固定落点（战斗中途加入的新队友
-- 就能在这里立刻看到并点击），脱战刷新时再吸附到对应队员框。整列/整行
-- 相对锚点容器居中，避免贴边不齐。
local COLUMN_GAP = 4

local function ParkButtons(anchorFrame)
    local size = GetSquareSize()
    local step = size + COLUMN_GAP
    local mode = GetAnchor()
    local count = #units
    local total = count * size + (count - 1) * COLUMN_GAP
    local w, h = anchorFrame:GetWidth() or 0, anchorFrame:GetHeight() or 0
    if anchorFrame == UIParent then w, h = 0, 0 end
    local parked = 0
    for _, unit in ipairs(units) do
        local button = buttons[unit]
        if button and button.parked then
            parked = parked + 1
            local shift = (parked - 1) * step
            button:ClearAllPoints()
            button:SetFrameStrata("MEDIUM")
            button:SetFrameLevel(100)
            if mode == "left" then
                button:SetPoint("CENTER", anchorFrame, "CENTER",
                    -(w / 2 + 5 + size / 2), (total - size) / 2 - shift)
            elseif mode == "right" then
                button:SetPoint("CENTER", anchorFrame, "CENTER",
                    w / 2 + 5 + size / 2, (total - size) / 2 - shift)
            elseif mode == "top" then
                button:SetPoint("CENTER", anchorFrame, "CENTER",
                    -((total - size) / 2) + shift, h / 2 + 5 + size / 2)
            else
                button:SetPoint("CENTER", anchorFrame, "CENTER",
                    -((total - size) / 2) + shift, -h / 2 - 5 - size / 2)
            end
        end
    end
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
    -- bootstrap 重试链每 0.5s 调一次，必须绕过节流：否则重试被节流吞掉
    --（pendingUpdate 无人消费），布局实际永远不执行。
    if not isBootstrap and now - lastRefreshTime < REFRESH_THROTTLE then
        pendingUpdate = true
        return
    end
    lastRefreshTime = now
    pendingUpdate = false

    -- 团队中：状态驱动的 [group:raid] hide 已经负责隐藏，这里无需再做任何
    -- 布局工作（也避免昂贵的帧枚举）。
    if not ShouldShow() then
        return
    end

    if IsDebugEnabled() then
        DebugPrint(string.format("RefreshLayout | group=%s raid=%s dispels=%d",
            tostring(IsInGroup()), tostring(IsInRaid()), #dispels))
    end

    -- 预建全部 5 个方块，并给每个都挂好托管容器（永久绑定固定 unit token）。
    -- 这样队友加入的瞬间容器已经在工作，战斗中不再有创建/换绑动作。
    local size = GetSquareSize()
    for _, unit in ipairs(units) do
        local button = GetButton(unit)

        -- 容器在战斗中创建会失败（首次在战斗中加载插件时）：脱战补挂一次。
        if not button.auraContainer then
            AttachManagedAura(button, unit)
        end
        if button.auraContainer and button.auraUnit ~= unit and button.auraContainer.SetUnit then
            local okUnit = pcall(button.auraContainer.SetUnit, button.auraContainer, unit)
            if okUnit then button.auraUnit = unit end
        end

        -- 尺寸与外观刷新（位置在下方逐人处理）。
        button:SetSize(size, size)
        ApplyClassInset(button)

        -- Spec/talent changes may alter which dispel types Blizzard-managed
        -- detection covers; refresh the container's candidate filters.
        if button.auraContainer and button.auraConfigVersion ~= dispelConfigVersion then
            ReconfigureManagedAura(button)
            button.auraConfigVersion = dispelConfigVersion
        end

        SetButtonMacros(button, unit)
        RegisterVisibilityDriver(button)
        UpdateButtonVisual(button)

        -- 优先贴到该队员的血条（脱战才能 SetPoint，战斗中位置保持不动）；
        -- 拿不到框（战斗中途加入的新队友、队伍框尚未就绪）→ 标记 parked，
        -- 由 ParkButtons 停到预留列，脱战后的下一次刷新自动吸附回血条。
        local frame
        if SafeUnitExists(unit) then
            frame = FindUnitFrame(unit)
        end
        local hb = frame and SafeIsVisible(frame) and GetHealthBar(frame)
        if hb then
            -- 绝不能 SetParent 进 ERF/暴雪的 secure header：外来子框架会污染
            -- SecureGroupHeader_Update 的安全路径，战斗中触发 ADDON_ACTION_BLOCKED。
            button:SetFrameStrata("MEDIUM")
            button:ClearAllPoints()
            local a = ANCHORS[GetAnchor()]
            button:SetPoint(a.point, hb, a.relPoint, a.dx, a.dy)
            if frame.GetFrameLevel then
                button:SetFrameLevel(frame:GetFrameLevel() + 50)
            end
            button.parked = false
        else
            button.parked = true
        end

        if IsDebugEnabled() and isBootstrap then
            local w, h = button:GetSize()
            local lvl = button:GetFrameLevel()
            local macroType = button:GetAttribute("type1") or "nil"
            local macroText = button:GetAttribute("macrotext1") or "nil"
            local ok, enabled = pcall(button.IsMouseEnabled, button)
            DebugPrint(string.format("%s -> square size=%dx%d level=%d mouse=%s type1=%s macro=%s managed=%s parked=%s",
                unit, w, h, lvl, tostring(ok and enabled or false), tostring(macroType), tostring(macroText), tostring(button.auraContainer ~= nil), tostring(button.parked)))
        end
    end

    ParkButtons(FindColumnAnchorFrame())
end

local function RefreshAll(rediscover, skipLayout)
    if rediscover then
        DiscoverDispels()
    end

    if #dispels == 0 then
        addonEnabled = false
        -- 战斗中不得 Hide 受保护按钮（方块带 macrotext 属性，战斗中
        -- Show/Hide 是保护操作，直接调会 ADDON_ACTION_BLOCKED）：挂起
        -- pendingUpdate，脱战后由 PLAYER_REGEN_ENABLED 补隐藏。
        if InCombatLockdown() then
            pendingUpdate = true
            return
        end
        -- 当前职业/专精没有驱散技能：完全禁用，注销状态驱动并隐藏所有方块
        --（否则 player 方块会被驱动重新显示）。
        for _, button in pairs(buttons) do
            UnregisterVisibilityDriver(button)
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
-- 事件注册走 pcall：永恒虽然沿用现代客户端的事件体系，但个别事件（如天赋树
-- 相关）在特定 build 上可能不存在，直接 RegisterEvent 会抛错中断整个文件加载。
local eventFrame = CreateFrame("Frame")
for _, event in ipairs({
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_SPECIALIZATION_CHANGED",
    "ACTIVE_TALENT_GROUP_CHANGED",
    "TRAIT_CONFIG_UPDATED",
    "PLAYER_TALENT_UPDATE",
    "GROUP_ROSTER_UPDATE",
    "GROUP_LEFT",
    "PLAYER_REGEN_ENABLED",
    "COMPACT_UNIT_FRAME_PROFILES_LOADED",
    "DISPLAY_SIZE_CHANGED",
    "UNIT_PET",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_SKILL_LINE",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

local function DelayedRefreshLayout()
    C_Timer.After(0.5, function()
        if not InCombatLockdown() then
            RefreshLayout()
        else
            pendingUpdate = true
        end
    end)
end

-- 天赋/专精事件的防抖再识别：TRAIT_CONFIG_UPDATED / PLAYER_TALENT_UPDATE
-- 会连发多次，且事件触发瞬间 IsPlayerSpell 可能尚未反映新配置——立即重判
-- 会读到旧状态 → 绑定串与 lastBindingString 相同 → 静默（打印只在绑定
-- 列表变化时发，属防刷屏设计），容器 includeDispelTypes 也停在旧类型上。
-- 用 NewTimer 从最后一个事件起算延迟 0.3s，合并连发后等配置落地再判定。
local talentRediscoverTimer
local function DelayedRediscover()
    if talentRediscoverTimer then talentRediscoverTimer:Cancel() end
    talentRediscoverTimer = C_Timer.NewTimer(0.3, function()
        talentRediscoverTimer = nil
        RefreshAll(true)
    end)
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "ClickCleanse" then
        -- SavedVariables 就绪，立即套用默认值兜底。
        GetDB()
    elseif event == "PLAYER_LOGIN" then
        Print(L.LOADED or "loaded")
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
                -- 固定列只需要一个稳定的锚点容器：ERF 装着时等它自己的队伍框
                -- 容器真正显示出来再定案（否则会先锚到暴雪隐藏的旧队伍框），
                -- 没装 ERF 时锚点存在即可。
                local anchor = FindColumnAnchorFrame()
                local hdr = _G.ERFPartyHeader
                local ready
                if anchor == UIParent then
                    ready = false
                elseif hdr and hdr.GetParent and IsInGroup() then
                    ready = (anchor == hdr:GetParent()) and SafeIsVisible(anchor)
                else
                    ready = true
                end
                if not ready then
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
        -- 走防抖：等配置真正落地后再 DiscoverDispels（见 DelayedRediscover）。
        DelayedRediscover()
    elseif event == "GROUP_ROSTER_UPDATE"
        or event == "GROUP_LEFT"
        or event == "COMPACT_UNIT_FRAME_PROFILES_LOADED"
        or event == "DISPLAY_SIZE_CHANGED" then
        if not addonEnabled then return end
        DelayedRefreshLayout()
    elseif event == "UNIT_PET" then
        -- 仅永恒需要：术士的吞噬魔法取决于当前宠物（地狱犬）是否在场，
        -- 换宠物/召唤后重新判定。零售术士是宽松绑定，不关心宠物变化。
        if IS_FOREVER then DelayedRediscover() end
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_SKILL_LINE" then
        -- 新学/遗忘法术（例如训练师学会祛病术 528）后必须重新判定可用
        -- 驱散技能，否则旧绑定会指向没学/已失效的技能（点击静默失败）。
        DelayedRediscover()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 战斗结束后补上战斗中被推迟的布局与过滤器更新。
        -- 统一重跑 RefreshAll：有驱散则刷新布局，无驱散则隐藏全部方块。
        if pendingUpdate then
            pendingUpdate = false
            RefreshAll(false)
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

-- 判定当前是否存在可驱散 debuff：任一托管按钮的整层填充贴图被引擎点亮
-- （有匹配 aura 时引擎 Show 填充并设 alpha，无 aura 时隐藏/alpha=0）。
--
-- ⚠️ 关键：AddDispelTypeTexture 会给该贴图打上 secret aspect
-- （Alpha / VertexColor / TexCoords / Shown，见 Blizzard_CustomAuraButton.lua），
-- 一旦值由保密数据驱动，GetAlpha / IsShown 就返回 secret 值，而对 secret 值
-- 做比较或布尔测试在插件代码里会**直接抛错**。所以"读不到"与"确实没有 debuff"
-- 是两种必须区分的情况：
--   * 只有【明确读到】alpha <= 0 或 Shown == false，才算"无 debuff"；
--   * 读不到（pcall 失败，或 canaccessvalue 判定不可读）一律按"有 debuff"处理
--     ——宁可多显示 CD 也不误清。否则真 CD 会在战斗/副本里被误判成"无 debuff"
--     而整段吞掉，正是本插件最需要 CD 的场景反而没有 CD。

local function HasActiveDebuff()
    for _, button in pairs(buttons) do
        local ft = button.fillTex
        if ft then
            local ok, shown = pcall(function()
                local alpha = ft:GetAlpha()
                if not canAccessValue(alpha) then return true end
                if not (alpha > 0) then return false end
                local isShown = ft:IsShown()
                if not canAccessValue(isShown) then return true end
                return isShown == true
            end)
            if not ok then return true end
            if shown then return true end
        end
    end
    return false
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
ticker.debugThrottle = 0  -- 调试用：限制日志频率
local function TickerDebug(msg)
    if not IsDebugEnabled() then return end
    local now = GetTime()
    if now - (ticker.debugThrottle or 0) < 2 then return end
    ticker.debugThrottle = now
    DebugPrint(msg)
end
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
        TickerDebug(string.format("ticker: early exit (#dispels=%d GetSpellCooldownFunc=%s)",
            #dispels, tostring(GetSpellCooldownFunc ~= nil)))
        return
    end

    -- 多技能轮询（2026-08-27 修复）：旧版只查 dispels[1]，多驱散职业
    -- 排在后面的技能（如萨满驱毒图腾排在清洁之魂之后）CD 永远不显示。
    -- 现在遍历全部驱散技能，分别收集真 CD（isActive 且非 GCD）与 GCD
    -- 两个 DurationObject（isOnGCD 布尔非 secret，可安全分支）。
    local cdObj, gcdObj
    if C_Spell and C_Spell.GetSpellCooldownDuration then
        for i = 1, #dispels do
            local scd = GetSpellCooldownFunc(dispels[i].spellID)
            TickerDebug(string.format("ticker: spell=%s isActive=%s isOnGCD=%s",
                tostring(dispels[i].spellID),
                tostring(scd and scd.isActive),
                tostring(scd and scd.isOnGCD)))
            if scd and scd.isActive == true then
                local obj = C_Spell.GetSpellCooldownDuration(dispels[i].spellID)
                TickerDebug(string.format("ticker: GetSpellCooldownDuration -> %s", tostring(obj ~= nil)))
                if obj then
                    if scd.isOnGCD ~= true then
                        cdObj = obj
                        break -- 真 CD 优先，找到即停
                    elseif not gcdObj then
                        gcdObj = obj -- 暂存 GCD 对象
                    end
                end
            end
        end
    else
        TickerDebug("ticker: C_Spell.GetSpellCooldownDuration unavailable")
    end

    -- 组合规则（2026-08-27 两全版）：
    -- * GCD 始终显示（action bar 原生行为，施放任何法术后全体方块转
    --   GCD 小圈）；
    -- * 真 CD 只在存在可驱散 debuff 时显示（HasActiveDebuff，见上）——
    --   驱散后 GCD 转完方块即清爽，真 CD 不再残留；若期间 GCD 仍活跃
    --   （刚施放驱散），退回显示 GCD 小圈。
    local durObj
    if cdObj then
        durObj = HasActiveDebuff() and cdObj or gcdObj
    else
        durObj = gcdObj
    end

    -- 变化检测：只有 DurationObject 引用变化（新 CD 开始）或从无到有才喂，
    -- 同一 CD 期间引擎自动逐帧渲染，重复喂入既浪费受限调用配额又会重置动画。
    local durObjChanged = (durObj ~= self.lastDurObj)
    if not durObj and not self.cleared then
        for _, button in pairs(buttons) do
            if button.cooldown then button.cooldown:Clear() end
        end
        self.cleared = true
        TickerDebug("ticker: cleared (no durObj)")
    elseif durObj then
        self.cleared = false
    end
    self.lastDurObj = durObj
    if not (durObj and durObjChanged) then return end

    TickerDebug(string.format("ticker: feeding durObj (cdObj=%s gcdObj=%s hasDebuff=%s)",
        tostring(cdObj ~= nil), tostring(gcdObj ~= nil), tostring(HasActiveDebuff())))

    local size = GetSquareSize()
    for _, button in pairs(buttons) do
        local cd = button.cooldown
        if cd and button:IsShown() then
            local ok, err = pcall(cd.SetCooldownFromDurationObject, cd, durObj)
            if not ok then
                TickerDebug(string.format("SetCooldownFromDurationObject failed: %s", tostring(err)))
            else
                TickerDebug(string.format("%s -> SetCooldownFromDurationObject OK", button:GetName() or "?"))
            end
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

-- -----------------------------------------------------------------------------
-- /ccl test — 驱散类型颜色预览
-- 屏幕中央显示独立预览方块（不依赖队伍/真实减益），复刻真实方块的
-- 视觉结构：类型色整层填充 + 职业色内缩 10%/alpha 0.2 叠加。
-- 依次展示 5 种类型，每种持续 2 秒、间隔 1 秒；战斗中拒绝执行。
-- -----------------------------------------------------------------------------
local TEST_TYPES = {"Magic", "Curse", "Poison", "Disease", "Bleed"}
local testFrame
local testActive = false

local function StopTestMode()
    testActive = false
    if testFrame then testFrame:Hide() end
    Print(L.TEST_END or "Test finished")
end

local function ShowTestType(index)
    if not testActive then return end
    if index > #TEST_TYPES then
        StopTestMode()
        return
    end
    local typeName = TEST_TYPES[index]
    local color = DISPEL_COLORS[typeName]
    testFrame.fill:SetColorTexture(color[1], color[2], color[3], 1)
    testFrame:Show()
    local display = (L.TEST_TYPE_NAMES and L.TEST_TYPE_NAMES[typeName]) or typeName
    Print(string.format("%s (%d/%d)", display, index, #TEST_TYPES))
    -- 持续 2 秒 → 隐藏 → 间隔 1 秒 → 下一种
    C_Timer.After(2, function()
        if not testActive then return end
        testFrame:Hide()
        C_Timer.After(1, function()
            if not testActive then return end
            ShowTestType(index + 1)
        end)
    end)
end

local function StartTestMode()
    if InCombatLockdown() then
        Print(L.TEST_IN_COMBAT or "In combat, cannot test")
        return
    end
    if testActive then
        testActive = false -- 重新开始：作废旧计时链（回调检查 testActive）
    end
    if not testFrame then
        testFrame = CreateFrame("Frame", "ClickCleanse_TestPreview", UIParent)
        testFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        local fill = testFrame:CreateTexture(nil, "ARTWORK")
        fill:SetAllPoints()
        fill:SetColorTexture(1, 1, 1, 1)
        testFrame.fill = fill
        -- 中央底色叠加层：内缩 10%、alpha 0.2 白色，复刻真实方块视觉
        local classTex = testFrame:CreateTexture(nil, "OVERLAY")
        classTex:SetColorTexture(1, 1, 1, 0.2)
        testFrame.classTex = classTex
        -- 高亮描边：4 条白色贴图（复刻真实方块 debuff 时的点亮描边）
        testFrame.edges = {}
        for i = 1, 4 do
            local tex = testFrame:CreateTexture(nil, "OVERLAY")
            tex:SetColorTexture(1, 1, 1, 1)
            testFrame.edges[i] = tex
        end
        testFrame:Hide()
    end
    -- 尺寸/内缩/描边粗细跟随当前设置（每次进入测试都重算，/ccl 改尺寸即时生效）
    local size = GetSquareSize()
    testFrame:SetSize(size, size)
    local inset = math.max(2, math.floor(size * 0.1))
    testFrame.classTex:ClearAllPoints()
    testFrame.classTex:SetPoint("TOPLEFT", testFrame, "TOPLEFT", inset, -inset)
    testFrame.classTex:SetPoint("BOTTOMRIGHT", testFrame, "BOTTOMRIGHT", -inset, inset)
    local thickness = math.max(2, math.floor(size / 12))
    local top, bottom, left, right = testFrame.edges[1], testFrame.edges[2], testFrame.edges[3], testFrame.edges[4]
    top:ClearAllPoints()
    top:SetPoint("BOTTOMLEFT", testFrame, "TOPLEFT", -thickness, 0)
    top:SetPoint("BOTTOMRIGHT", testFrame, "TOPRIGHT", thickness, 0)
    top:SetHeight(thickness)
    bottom:ClearAllPoints()
    bottom:SetPoint("TOPLEFT", testFrame, "BOTTOMLEFT", -thickness, 0)
    bottom:SetPoint("TOPRIGHT", testFrame, "BOTTOMRIGHT", thickness, 0)
    bottom:SetHeight(thickness)
    left:ClearAllPoints()
    left:SetPoint("TOPRIGHT", testFrame, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMRIGHT", testFrame, "BOTTOMLEFT", 0, 0)
    left:SetWidth(thickness)
    right:ClearAllPoints()
    right:SetPoint("TOPLEFT", testFrame, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMLEFT", testFrame, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(thickness)
    testActive = true
    Print(L.TEST_START or "Test started")
    ShowTestType(1)
end

-- Manual slash command.  "/cc" is not registered because it conflicts with
-- Blizzard Click Casting; "/ccl" is the primary prefix.
SLASH_CLICKCLEANSE1 = "/ccl"
SLASH_CLICKCLEANSE2 = "/clickcleanse"
SlashCmdList["CLICKCLEANSE"] = function(msg)
    local lower = (msg or ""):lower()

    if lower == "debug" then
        local db = GetDB()
        db.debug = not db.debug
        Print(db.debug and (L.DEBUG_ON or "Debug output enabled")
                          or (L.DEBUG_OFF or "Debug output disabled"))
        if db.debug then
            RefreshAll(true)
        end
        return
    end

    if lower == "test" then
        StartTestMode()
        return
    end

    if lower == "left" or lower == "right" or lower == "top" or lower == "bottom" then
        GetDB().anchor = lower
        Print(string.format(L.ANCHOR_SET or "Anchor set to %s",
            (L.ANCHOR_NAMES and L.ANCHOR_NAMES[lower]) or lower))
        RefreshLayout()
        return
    end

    local num = tonumber(msg)
    if num then
        if num < 10 or num > 100 then
            PrintError(L.SIZE_INVALID or "Size must be between 10 and 100")
            return
        end
        GetDB().size = num
        Print(string.format(L.SIZE_SET or "Square size set to %d", num))
        RefreshLayout()
        return
    end

    Print(L.REFRESHED or "Manual refresh triggered")
    RefreshAll(true)
end
