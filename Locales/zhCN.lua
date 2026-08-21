local _, addon = ...

if GetLocale() ~= "zhCN" then return end

addon.L = {
    LEFT_CLICK     = "左键",
    RIGHT_CLICK    = "右键",
    MIDDLE_CLICK   = "中键",
    NO_DISPEL      = "无可用驱散",
    BINDING_FORMAT = "%s: %s",
}
