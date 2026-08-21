local _, addon = ...

if GetLocale() ~= "zhCN" then return end

addon.L = {
    LEFT_CLICK     = "左键",
    RIGHT_CLICK    = "右键",
    MIDDLE_CLICK   = "中键",
    NO_DISPEL      = "无可用驱散",
    MAGIC          = "魔法",
    CURSE          = "诅咒",
    POISON         = "中毒",
    DISEASE        = "疾病",
    BLEED          = "流血",
    BINDING_FORMAT = "%s: %s",
    DETECT_FORMAT  = "可检测：%s",
}
