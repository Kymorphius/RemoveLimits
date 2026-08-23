-- Infinite Capacity - Build 41 compatibility entry point.
-- Build 41 keeps the original all-unlimited behavior. Build 42 adds the full
-- server-controlled sandbox settings UI.

local PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalHasRoomFor"

local function installPatch()
    if not __classmetatables or not ItemContainer or not ItemContainer.class then
        print("[RemoveLimits] ItemContainer metadata is unavailable; patch not installed")
        return
    end

    local classMetatable = __classmetatables[ItemContainer.class]
    local methods = classMetatable and classMetatable.__index
    if not methods or type(methods.hasRoomFor) ~= "function" then
        print("[RemoveLimits] ItemContainer.hasRoomFor is unavailable; patch not installed")
        return
    end
    if methods[PATCH_KEY] then return end

    methods[PATCH_KEY] = methods.hasRoomFor
    methods.hasRoomFor = function(container, ...)
        if not container then return false end
        return true
    end

    print("[RemoveLimits] Capacity checks disabled (Build 41 compatibility mode)")
end

Events.OnGameBoot.Add(installPatch)
