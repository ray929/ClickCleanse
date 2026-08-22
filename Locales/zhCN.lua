local _, addon = ...

if GetLocale() ~= "zhCN" then return end

addon.L = {
    LEFT_CLICK     = "左键",
    RIGHT_CLICK    = "右键",
    MIDDLE_CLICK   = "中键",
    NO_DISPEL      = "无可用驱散",
    BINDING_FORMAT = "%s：%s",
    LOADED         = "已加载",
    ANCHOR_SET     = "停靠位置已设为%s",
    ANCHOR_NAMES   = { left = "左侧", right = "右侧", top = "上方", bottom = "下方" },
    SIZE_INVALID   = "方块大小必须在 10 到 100 之间",
    SIZE_SET       = "方块大小已设为 %d",
    REFRESHED      = "已手动刷新",
    DEBUG_ON       = "调试输出已开启",
    DEBUG_OFF      = "调试输出已关闭",
    TEST_IN_COMBAT = "战斗中，无法测试",
    TEST_START     = "开始测试",
    TEST_END       = "测试结束",
    TEST_TYPE_NAMES = {
        Magic = "魔法", Curse = "诅咒", Poison = "中毒",
        Disease = "疾病", Bleed = "流血",
    },
}
