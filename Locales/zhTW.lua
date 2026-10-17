local _, addon = ...

if GetLocale() ~= "zhTW" then return end

addon.L = {
    LEFT_CLICK     = "左鍵",
    RIGHT_CLICK    = "右鍵",
    MIDDLE_CLICK   = "中鍵",
    NO_DISPEL      = "無可用驅散",
    BINDING_FORMAT = "%s：%s",
    LOADED         = "已載入",
    ANCHOR_SET     = "停靠位置已設為%s",
    ANCHOR_NAMES   = { left = "左側", right = "右側", top = "上方", bottom = "下方" },
    SIZE_INVALID   = "方塊大小必須在 10 到 100 之間",
    SIZE_SET       = "方塊大小已設為 %d",
    REFRESHED      = "已手動重新整理",
    DEBUG_ON       = "除錯輸出已開啟",
    DEBUG_OFF      = "除錯輸出已關閉",
    TEST_IN_COMBAT = "戰鬥中，無法測試",
    TEST_START     = "開始測試",
    TEST_END       = "測試結束",
    TEST_TYPE_NAMES = {
        Magic = "魔法", Curse = "詛咒", Poison = "中毒",
        Disease = "疾病", Bleed = "流血",
    },
}
