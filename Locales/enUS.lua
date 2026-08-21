local _, addon = ...

if GetLocale() ~= "enUS" and GetLocale() ~= "enGB" then return end

addon.L = {
    LEFT_CLICK     = "Left click",
    RIGHT_CLICK    = "Right click",
    MIDDLE_CLICK   = "Middle click",
    NO_DISPEL      = "No dispel available",
    MAGIC          = "Magic",
    CURSE          = "Curse",
    POISON         = "Poison",
    DISEASE        = "Disease",
    BLEED          = "Bleed",
    BINDING_FORMAT = "%s: %s",
    DETECT_FORMAT  = "Detects: %s",
}
