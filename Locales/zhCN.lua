local _, addon = ...

if GetLocale() ~= "zhCN" then return end

addon.L = {
    LEFT_CLICK     = "左键",
    RIGHT_CLICK    = "右键",
    MIDDLE_CLICK   = "中键",
    NO_DISPEL      = "无可用驱散",
    BINDING_FORMAT = "%s: %s",
    TEST_IN_COMBAT = "战斗中，无法测试",
    TEST_START     = "开始测试",
    TEST_END       = "测试结束",
    TEST_TYPE_NAMES = {
        Magic = "魔法", Curse = "诅咒", Poison = "中毒",
        Disease = "疾病", Bleed = "流血",
    },
}
