local _, addon = ...

if GetLocale() ~= "enUS" and GetLocale() ~= "enGB" then return end

addon.L = {
    LEFT_CLICK     = "Left click",
    RIGHT_CLICK    = "Right click",
    MIDDLE_CLICK   = "Middle click",
    NO_DISPEL      = "No dispel available",
    BINDING_FORMAT = "%s: %s",
}
