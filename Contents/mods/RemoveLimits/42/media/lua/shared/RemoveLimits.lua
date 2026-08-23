-- Infinite Capacity
-- Configurable Build 42.20+ implementation. SandboxVars are read on every
-- check so server-owned settings remain authoritative in multiplayer.

local CONTAINER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_ItemContainer_originalHasRoomFor"
local CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_ItemContainer_originalGetCapacity"
local EFFECTIVE_CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_ItemContainer_originalGetEffectiveCapacity"
local MAX_WEIGHT_PATCH_KEY = "RemoveCapacityAndPickUpLimits_ItemContainer_originalGetMaxWeight"
local SET_CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_ItemContainer_originalSetCapacity"
local HAS_FULL_INVENTORY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_IsoGameCharacter_originalHasFullInventory"
local FREE_INVENTORY_CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_IsoGameCharacter_originalGetFreeInventoryCapacity"
local VEHICLE_MASS_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalUpdateTotalMass"
local UNLIMITED_CHARACTER_CAPACITY = 10000
local UNLIMITED_CONTAINER_CAPACITY = 10000
local MAX_CHARACTER_CONTAINER_CAPACITY = 100
local characterStates = setmetatable({}, { __mode = "k" })
local originalGetEffectiveCapacity = nil
local originalCharacterGetMaxWeight = nil
local originalCharacterSetMaxWeight = nil
local originalCharacterGetMaxWeightBase = nil
local originalCharacterSetMaxWeightBase = nil
local originalCharacterHasFullInventory = nil
local originalCharacterGetFreeInventoryCapacity = nil
local vehicleMassFailureReported = false

local function sandboxValues()
    return SandboxVars and SandboxVars.RemoveLimits
end

local function numberSetting(name, fallback)
    local values = sandboxValues()
    return tonumber(values and values[name]) or fallback
end

local function booleanSetting(name)
    local values = sandboxValues()
    return not values or values[name] ~= false
end

local function characterMode()
    return numberSetting("CharacterMode", 3)
end

local function characterLimit()
    return numberSetting("CharacterCapacityLimit", 100)
end

local function configuredCharacterTarget()
    if characterMode() == 2 then
        return math.max(1, math.floor(characterLimit()))
    end
    return UNLIMITED_CHARACTER_CAPACITY
end

local function safeCall(callback, fallback)
    local ok, result = pcall(callback)
    if ok then return result end
    return fallback
end

local function effectiveCharacterCapacity(character)
    local mode = characterMode()
    if mode == 1 then return nil end
    local configured = configuredCharacterTarget()
    local native = originalCharacterGetMaxWeight and tonumber(originalCharacterGetMaxWeight(character)) or nil
    if not native then return configured end
    if mode == 2 then return math.min(configured, native) end
    return native
end

local function classify(container)
    if container:getType() == "floor" then
        return "floor"
    end

    local parent = container:getParent()
    if parent and instanceof and instanceof(parent, "IsoPlayer") then
        return "character"
    end
    if parent and instanceof and instanceof(parent, "IsoGameCharacter") then
        return "other-character"
    end

    if container:getVehiclePart() then
        return "vehicle"
    end

    local ownerItem = container:getContainingItem()
    if ownerItem then
        local outer = ownerItem:getContainer()
        if outer and outer:getVehiclePart() then
            return "vehicle"
        end
        return "bag"
    end
    return "world"
end

local function configuredContainerCapacity(container, character, vanillaCapacity)
    local mode = numberSetting("ContainerMode", 3)
    if mode == 1 then return vanillaCapacity end

    local category = classify(container)
    local affected = (category == "bag" and booleanSetting("AffectBags"))
        or (category == "vehicle" and booleanSetting("AffectVehicles"))
        or (category == "world" and booleanSetting("AffectWorldContainers"))

    if not affected then return vanillaCapacity end
    if mode == 3 then return UNLIMITED_CONTAINER_CAPACITY end
    return math.max(1, vanillaCapacity * math.max(1, numberSetting("ContainerMultiplier", 2)))
end

local function unpackHasRoomArguments(...)
    local count = select("#", ...)
    if count >= 2 then
        return select(1, ...), select(2, ...)
    end
    return nil, select(1, ...)
end

local function addedWeight(value)
    if type(value) == "number" then return value end
    if not value then return nil end

    local weight = safeCall(function() return value:getUnequippedWeight() end, nil)
    if weight == nil then
        weight = safeCall(function() return value:getActualWeight() end, nil)
    end
    return tonumber(weight)
end

local function itemAllowed(container, value)
    if type(value) == "number" or not value then return true end
    return safeCall(function() return container:isItemAllowed(value) end, false)
end

local function exceedsBagItemSize(container, value, weight)
    if type(value) == "number" or not value then return false end
    local ownerItem = container:getContainingItem()
    if not ownerItem then return false end
    local maximum = tonumber(safeCall(function() return ownerItem:getMaxItemSize() end, 0)) or 0
    return maximum > 0 and weight > maximum
end

local function isHeavyItemBlockedInVehicle(character, container, value)
    if not character or type(value) == "number" or not value then return false end
    local parent = safeCall(function() return container:getParent() end, nil)
    if not (parent and instanceof and instanceof(parent, "IsoGameCharacter")) then return false end
    if not safeCall(function() return character:getVehicle() end, nil) then return false end
    if not ItemTag or not ItemTag.HEAVY_ITEM then return false end
    return safeCall(function() return value:hasTag(ItemTag.HEAVY_ITEM) end, false)
end

local function applyCharacterCapacity(character)
    if not character or not instanceof or not instanceof(character, "IsoPlayer") then return end
    local inventory = safeCall(function() return character:getInventory() end, nil)
    if not inventory then return end

    local mode = characterMode()
    local state = characterStates[character]
    if not state then
        state = {
            originalMaxWeight = tonumber(safeCall(function()
                if originalCharacterGetMaxWeight then return originalCharacterGetMaxWeight(character) end
                return character:getMaxWeight()
            end, 0)) or 0,
            originalMaxWeightBase = tonumber(safeCall(function()
                if originalCharacterGetMaxWeightBase then return originalCharacterGetMaxWeightBase(character) end
                return character:getMaxWeightBase()
            end, 0)) or 0,
            originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, 50)) or 50,
            applied = false,
            reportedTarget = nil,
        }
        characterStates[character] = state
    end

    if mode == 1 then
        if state.applied then
            safeCall(function()
                if originalCharacterSetMaxWeightBase then
                    originalCharacterSetMaxWeightBase(character, state.originalMaxWeightBase)
                else
                    character:setMaxWeightBase(state.originalMaxWeightBase)
                end
                if originalCharacterSetMaxWeight then
                    originalCharacterSetMaxWeight(character, state.originalMaxWeight)
                else
                    character:setMaxWeight(state.originalMaxWeight)
                end
            end, nil)
            safeCall(function() inventory:setCapacity(state.originalInventoryCapacity) end, nil)
            state.applied = false
            state.reportedTarget = nil
        else
            state.originalMaxWeight = tonumber(safeCall(function() return character:getMaxWeight() end, state.originalMaxWeight)) or state.originalMaxWeight
            state.originalMaxWeightBase = tonumber(safeCall(function() return character:getMaxWeightBase() end, state.originalMaxWeightBase)) or state.originalMaxWeightBase
            state.originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, state.originalInventoryCapacity)) or state.originalInventoryCapacity
        end
        return
    end

    if not state.applied then
        state.originalMaxWeight = tonumber(safeCall(function()
            if originalCharacterGetMaxWeight then return originalCharacterGetMaxWeight(character) end
            return character:getMaxWeight()
        end, state.originalMaxWeight)) or state.originalMaxWeight
        state.originalMaxWeightBase = tonumber(safeCall(function()
            if originalCharacterGetMaxWeightBase then return originalCharacterGetMaxWeightBase(character) end
            return character:getMaxWeightBase()
        end, state.originalMaxWeightBase)) or state.originalMaxWeightBase
        state.originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, state.originalInventoryCapacity)) or state.originalInventoryCapacity
    end

    local target = configuredCharacterTarget()
    -- Build 42 hard-rejects ItemContainer capacities above 100. The character
    -- soft limit and hasRoomFor patch can still expose/allow larger values, but
    -- the underlying inventory container must stay within the Java limit.
    local inventoryTarget = math.min(target, MAX_CHARACTER_CONTAINER_CAPACITY)
    -- BodyDamage.UpdateStrength recalculates maxWeight in native Java code from
    -- maxWeightBase. Persist the configured capacity in that source field, then
    -- seed maxWeight once so the Heavy Load moodle is correct immediately. The
    -- game's own recalculation keeps it durable without a Lua polling event.
    safeCall(function()
        local currentBase = originalCharacterGetMaxWeightBase(character)
        if currentBase ~= target then originalCharacterSetMaxWeightBase(character, target) end
        local currentMax = originalCharacterGetMaxWeight(character)
        if currentMax ~= target then originalCharacterSetMaxWeight(character, target) end
    end, nil)
    safeCall(function()
        if inventory:getCapacity() ~= inventoryTarget then inventory:setCapacity(inventoryTarget) end
    end, nil)
    state.applied = true
    if state.reportedTarget ~= target then
        print("[RemoveLimits] Character capacity applied: " .. tostring(target)
            .. " (physical container: " .. tostring(inventoryTarget) .. ")")
        state.reportedTarget = target
    end
end

local function installCharacterCapacityAccessors()
    if not __classmetatables or not IsoGameCharacter or not IsoGameCharacter.class then
        print("[RemoveLimits] IsoGameCharacter metadata is unavailable; character capacity patch not installed")
        return
    end

    local classMetatable = __classmetatables[IsoGameCharacter.class]
    local methods = classMetatable and classMetatable.__index
    if not methods
        or type(methods.getMaxWeight) ~= "function"
        or type(methods.setMaxWeight) ~= "function"
        or type(methods.getMaxWeightBase) ~= "function"
        or type(methods.setMaxWeightBase) ~= "function"
        or type(methods.hasFullInventory) ~= "function"
        or type(methods.getFreeInventoryCapacity) ~= "function" then
        print("[RemoveLimits] IsoGameCharacter capacity fields are unavailable; character capacity patch not installed")
        return
    end

    originalCharacterGetMaxWeight = methods.getMaxWeight
    originalCharacterSetMaxWeight = methods.setMaxWeight
    originalCharacterGetMaxWeightBase = methods.getMaxWeightBase
    originalCharacterSetMaxWeightBase = methods.setMaxWeightBase

    if methods[HAS_FULL_INVENTORY_PATCH_KEY] then
        originalCharacterHasFullInventory = methods[HAS_FULL_INVENTORY_PATCH_KEY]
        originalCharacterGetFreeInventoryCapacity = methods[FREE_INVENTORY_CAPACITY_PATCH_KEY]
        return
    end

    originalCharacterHasFullInventory = methods.hasFullInventory
    originalCharacterGetFreeInventoryCapacity = methods.getFreeInventoryCapacity
    methods[HAS_FULL_INVENTORY_PATCH_KEY] = originalCharacterHasFullInventory
    methods[FREE_INVENTORY_CAPACITY_PATCH_KEY] = originalCharacterGetFreeInventoryCapacity

    local function configuredFreeCapacity(character)
        if not instanceof or not instanceof(character, "IsoPlayer") or characterMode() == 1 then
            return nil
        end
        local inventory = character:getInventory()
        if not inventory then return nil end
        local limit = effectiveCharacterCapacity(character)
        local weight = tonumber(inventory:getCapacityWeight())
        if not limit or not weight then return nil end
        return math.max(0, limit - weight)
    end

    methods.getFreeInventoryCapacity = function(character)
        local configured = configuredFreeCapacity(character)
        if configured ~= nil then return configured end
        return originalCharacterGetFreeInventoryCapacity(character)
    end
    methods.hasFullInventory = function(character)
        local configured = configuredFreeCapacity(character)
        if configured ~= nil then return configured <= 0 end
        return originalCharacterHasFullInventory(character)
    end
    print("[RemoveLimits] Character capacity and fluid-action accessors installed")
end

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
    if methods[CONTAINER_PATCH_KEY] then return end

    local originalHasRoomFor = methods.hasRoomFor
    local originalGetCapacity = methods.getCapacity
    originalGetEffectiveCapacity = methods.getEffectiveCapacity
    local originalGetMaxWeight = methods.getMaxWeight
    local originalSetCapacity = methods.setCapacity

    methods[CAPACITY_PATCH_KEY] = originalGetCapacity
    methods[EFFECTIVE_CAPACITY_PATCH_KEY] = originalGetEffectiveCapacity
    methods[MAX_WEIGHT_PATCH_KEY] = originalGetMaxWeight
    methods[SET_CAPACITY_PATCH_KEY] = originalSetCapacity
    methods[CONTAINER_PATCH_KEY] = originalHasRoomFor

    -- Other carry-capacity mods may also try to mirror a high character
    -- maxWeight into ItemContainer:setCapacity(). Clamp only character
    -- inventories and skip no-op writes; bags, vehicles and world containers
    -- keep their original behavior.
    if type(originalSetCapacity) == "function" then
        methods.setCapacity = function(container, capacity)
            local numericCapacity = tonumber(capacity)
            if numericCapacity and classify(container) == "character" then
                local mode = characterMode()
                if mode == 2 or mode == 3 then
                    numericCapacity = math.min(configuredCharacterTarget(), MAX_CHARACTER_CONTAINER_CAPACITY)
                else
                    numericCapacity = math.min(numericCapacity, MAX_CHARACTER_CONTAINER_CAPACITY)
                end
                local currentCapacity = tonumber(originalGetCapacity(container))
                if currentCapacity == numericCapacity then return end
                return originalSetCapacity(container, numericCapacity)
            end
            return originalSetCapacity(container, capacity)
        end
    end

    -- Build 42's inventory UI reads getEffectiveCapacity() every frame. Keep
    -- the raw vehicle/item definition untouched, and expose the configured
    -- value only through the capacity accessors so Vanilla restores instantly.
    methods.getCapacity = function(container)
        local vanillaCapacity = originalGetCapacity(container)
        return configuredContainerCapacity(container, nil, vanillaCapacity)
    end
    methods.getEffectiveCapacity = function(container, character)
        local vanillaCapacity = originalGetEffectiveCapacity(container, character)
        return configuredContainerCapacity(container, character, vanillaCapacity)
    end
    methods.getMaxWeight = function(container)
        local vanillaCapacity = originalGetMaxWeight(container)
        return configuredContainerCapacity(container, nil, vanillaCapacity)
    end

    methods.hasRoomFor = function(container, ...)
        if not container then return false end

        local category = classify(container)
        local mode

        if category == "character" then
            mode = characterMode()
        elseif category == "bag" and booleanSetting("AffectBags") then
            mode = numberSetting("ContainerMode", 3)
        elseif category == "vehicle" and booleanSetting("AffectVehicles") then
            mode = numberSetting("ContainerMode", 3)
        elseif category == "world" and booleanSetting("AffectWorldContainers") then
            mode = numberSetting("ContainerMode", 3)
        else
            return originalHasRoomFor(container, ...)
        end

        if mode == 1 then return originalHasRoomFor(container, ...) end

        local character, value = unpackHasRoomArguments(...)
        local weight = addedWeight(value)
        if not weight then return originalHasRoomFor(container, ...) end
        if not itemAllowed(container, value) then return false end
        if exceedsBagItemSize(container, value, weight) then return false end
        if isHeavyItemBlockedInVehicle(character, container, value) then return false end

        if mode == 3 then return true end

        local currentWeight = tonumber(container:getCapacityWeight())
        if not currentWeight then return originalHasRoomFor(container, ...) end

        if category == "character" then
            local parent = container:getParent()
            local limit = parent and effectiveCharacterCapacity(parent) or characterLimit()
            limit = math.max(0, tonumber(limit) or characterLimit())
            return currentWeight + weight <= limit
        end

        local baseCapacity = tonumber(originalGetEffectiveCapacity(container, character))
        if not baseCapacity then return originalHasRoomFor(container, ...) end
        return currentWeight + weight <= baseCapacity * math.max(1, numberSetting("ContainerMultiplier", 2))
    end

    print("[RemoveLimits] Configurable capacity and display patch installed (Build 42.20+)")
end

local function installVehicleMassPatch()
    if not __classmetatables or not BaseVehicle or not BaseVehicle.class then
        print("[RemoveLimits] BaseVehicle metadata is unavailable; cargo mass patch not installed")
        return
    end

    local classMetatable = __classmetatables[BaseVehicle.class]
    local methods = classMetatable and classMetatable.__index
    if not methods or type(methods.updateTotalMass) ~= "function" then
        print("[RemoveLimits] BaseVehicle.updateTotalMass is unavailable; cargo mass patch not installed")
        return
    end
    if methods[VEHICLE_MASS_PATCH_KEY] then return end

    local originalUpdateTotalMass = methods.updateTotalMass
    methods[VEHICLE_MASS_PATCH_KEY] = originalUpdateTotalMass
    methods.updateTotalMass = function(vehicle, ...)
        if not booleanSetting("IgnoreVehicleCargoMass") then
            return originalUpdateTotalMass(vehicle, ...)
        end

        local ok, err = pcall(function()
            local installedPartsWeight = 0
            local parts = vehicle:getParts()
            for partIndex = 0, parts:size() - 1 do
                local part = parts:get(partIndex)
                local item = part and part:getInventoryItem() or nil
                if item then
                    installedPartsWeight = installedPartsWeight + (tonumber(item:getWeight()) or 0)
                end
            end

            local totalMass = math.floor((tonumber(vehicle:getInitialMass()) or 0) + installedPartsWeight + 0.5)
            vehicle:setMass(totalMass)

            -- BaseVehicle's native update loop forwards getMass()/getFudgedMass()
            -- to Bullet. Bullet itself is intentionally not exposed to Lua in
            -- Build 42.20.3, so setting the vehicle mass here is the supported
            -- route and is picked up on the next vehicle physics update.
        end)
        if not ok then
            if not vehicleMassFailureReported then
                print("[RemoveLimits] Vehicle cargo mass patch failed; using vanilla mass: " .. tostring(err))
                vehicleMassFailureReported = true
            end
            return originalUpdateTotalMass(vehicle, ...)
        end
    end
    print("[RemoveLimits] Vehicle cargo mass exclusion patch installed")
end

Events.OnGameBoot.Add(installPatch)
Events.OnGameBoot.Add(installCharacterCapacityAccessors)
Events.OnGameBoot.Add(installVehicleMassPatch)
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(function(_, player) applyCharacterCapacity(player) end)
end

RemoveLimits = RemoveLimits or {}
RemoveLimits.applyCharacterCapacity = applyCharacterCapacity
