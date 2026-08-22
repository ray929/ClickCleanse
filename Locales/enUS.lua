local _, addon = ...

-- Base locale: always loaded. Other locale files override addon.L wholesale.
addon.L = {
    LEFT_CLICK     = "Left click",
    RIGHT_CLICK    = "Right click",
    MIDDLE_CLICK   = "Middle click",
    NO_DISPEL      = "No dispel available",
    BINDING_FORMAT = "%s: %s",
    LOADED         = "loaded",
    ANCHOR_SET     = "Anchor set to %s",
    ANCHOR_NAMES   = { left = "left", right = "right", top = "top", bottom = "bottom" },
    SIZE_INVALID   = "Size must be between 10 and 100",
    SIZE_SET       = "Square size set to %d",
    REFRESHED      = "Manual refresh triggered",
    DEBUG_ON       = "Debug output enabled",
    DEBUG_OFF      = "Debug output disabled",
    TEST_IN_COMBAT = "In combat, cannot test",
    TEST_START     = "Test started",
    TEST_END       = "Test finished",
    TEST_TYPE_NAMES = {
        Magic = "Magic", Curse = "Curse", Poison = "Poison",
        Disease = "Disease", Bleed = "Bleed",
    },
}
