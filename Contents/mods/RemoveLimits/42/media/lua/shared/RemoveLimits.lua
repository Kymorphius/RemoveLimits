-- Infinite Capacity
-- Configurable Build 42.20+ implementation. SandboxVars are read on every
-- check so server-owned settings remain authoritative in multiplayer.

local CONTAINER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalHasRoomFor"
local CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalGetCapacity"
local EFFECTIVE_CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalGetEffectiveCapacity"
local MAX_WEIGHT_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalGetMaxWeight"
local SET_CAPACITY_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalSetCapacity"
local BODY_DAMAGE_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalUpdateStrength"
local VEHICLE_MASS_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalUpdateTotalMass"
local UNLIMITED_CHARACTER_CAPACITY = 10000
local UNLIMITED_CONTAINER_CAPACITY = 10000
local MAX_CHARACTER_CONTAINER_CAPACITY = 100
local characterStates = setmetatable({}, { __mode = "k" })
local originalGetEffectiveCapacity = nil

local function settings()
    local values = SandboxVars and SandboxVars.RemoveLimits or {}
    return {
        characterMode = tonumber(values.CharacterMode) or 3,
        characterLimit = tonumber(values.CharacterCapacityLimit) or 100,
        containerMode = tonumber(values.ContainerMode) or 3,
        containerMultiplier = tonumber(values.ContainerMultiplier) or 2,
        affectBags = values.AffectBags ~= false,
        affectWorldContainers = values.AffectWorldContainers ~= false,
        affectVehicles = values.AffectVehicles ~= false,
        ignoreVehicleCargoMass = values.IgnoreVehicleCargoMass ~= false,
    }
end

local function safeCall(callback, fallback)
    local ok, result = pcall(callback)
    if ok then return result end
    return fallback
end

local function vehiclePart(container)
    return safeCall(function() return container:getVehiclePart() end, nil)
end

local function containingItem(container)
    return safeCall(function() return container:getContainingItem() end, nil)
end

local function classify(container)
    if safeCall(function() return container:getType() end, nil) == "floor" then
        return "floor"
    end
    if vehiclePart(container) then
        return "vehicle"
    end

    local ownerItem = containingItem(container)
    if ownerItem then
        local outer = safeCall(function() return ownerItem:getContainer() end, nil)
        if outer and vehiclePart(outer) then
            return "vehicle"
        end
        return "bag"
    end

    local parent = safeCall(function() return container:getParent() end, nil)
    if parent and instanceof and instanceof(parent, "IsoGameCharacter") then
        return "character"
    end
    return "world"
end

local function configuredContainerCapacity(container, character, vanillaCapacity)
    local category = classify(container)
    local options = settings()
    local affected = (category == "bag" and options.affectBags)
        or (category == "vehicle" and options.affectVehicles)
        or (category == "world" and options.affectWorldContainers)

    if not affected or options.containerMode == 1 then return vanillaCapacity end
    if options.containerMode == 3 then return UNLIMITED_CONTAINER_CAPACITY end
    return math.max(1, vanillaCapacity * math.max(1, options.containerMultiplier))
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
    local ownerItem = containingItem(container)
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
    if not character then return end
    local inventory = safeCall(function() return character:getInventory() end, nil)
    if not inventory then return end

    local options = settings()
    local mode = options.characterMode
    local state = characterStates[character]
    if not state then
        state = {
            originalMaxWeight = tonumber(safeCall(function() return character:getMaxWeight() end, 0)) or 0,
            originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, 50)) or 50,
            applied = false,
            reportedTarget = nil,
        }
        characterStates[character] = state
    end

    if mode == 1 then
        if state.applied then
            safeCall(function() character:setMaxWeight(state.originalMaxWeight) end, nil)
            safeCall(function() inventory:setCapacity(state.originalInventoryCapacity) end, nil)
            state.applied = false
            state.reportedTarget = nil
        else
            state.originalMaxWeight = tonumber(safeCall(function() return character:getMaxWeight() end, state.originalMaxWeight)) or state.originalMaxWeight
            state.originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, state.originalInventoryCapacity)) or state.originalInventoryCapacity
        end
        return
    end

    if not state.applied then
        state.originalMaxWeight = tonumber(safeCall(function() return character:getMaxWeight() end, state.originalMaxWeight)) or state.originalMaxWeight
        state.originalInventoryCapacity = tonumber(safeCall(function() return inventory:getCapacity() end, state.originalInventoryCapacity)) or state.originalInventoryCapacity
    end

    local target = mode == 2 and math.max(1, math.floor(options.characterLimit)) or UNLIMITED_CHARACTER_CAPACITY
    -- Build 42 hard-rejects ItemContainer capacities above 100. The character
    -- soft limit and hasRoomFor patch can still expose/allow larger values, but
    -- the underlying inventory container must stay within the Java limit.
    local inventoryTarget = math.min(target, MAX_CHARACTER_CONTAINER_CAPACITY)
    safeCall(function()
        if character:getMaxWeight() ~= target then character:setMaxWeight(target) end
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
                numericCapacity = math.min(numericCapacity, MAX_CHARACTER_CONTAINER_CAPACITY)
                local currentCapacity = tonumber(safeCall(function()
                    return originalGetCapacity(container)
                end, nil))
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

        local vanillaResult = originalHasRoomFor(container, ...)
        local category = classify(container)
        local options = settings()
        local mode

        if category == "character" then
            mode = options.characterMode
        elseif category == "bag" and options.affectBags then
            mode = options.containerMode
        elseif category == "vehicle" and options.affectVehicles then
            mode = options.containerMode
        elseif category == "world" and options.affectWorldContainers then
            mode = options.containerMode
        else
            return vanillaResult
        end

        if mode == 1 then return vanillaResult end

        local character, value = unpackHasRoomArguments(...)
        local weight = addedWeight(value)
        if not weight then return vanillaResult end
        if not itemAllowed(container, value) then return false end
        if exceedsBagItemSize(container, value, weight) then return false end
        if isHeavyItemBlockedInVehicle(character, container, value) then return false end

        if mode == 3 then return true end

        local currentWeight = tonumber(safeCall(function()
            return container:getCapacityWeight()
        end, nil))
        if not currentWeight then return vanillaResult end

        if category == "character" then
            return currentWeight + weight <= math.max(1, options.characterLimit)
        end

        local baseCapacity = tonumber(safeCall(function()
            return originalGetEffectiveCapacity(container, character)
        end, nil))
        if not baseCapacity then return vanillaResult end
        return currentWeight + weight <= baseCapacity * math.max(1, options.containerMultiplier)
    end

    print("[RemoveLimits] Configurable capacity and display patch installed (Build 42.20+)")
end

local function installBodyDamagePatch()
    if not __classmetatables or not BodyDamage or not BodyDamage.class then
        print("[RemoveLimits] BodyDamage metadata is unavailable; using OnTick fallback")
        return
    end

    local classMetatable = __classmetatables[BodyDamage.class]
    local methods = classMetatable and classMetatable.__index
    if not methods or type(methods.UpdateStrength) ~= "function" then
        print("[RemoveLimits] BodyDamage.UpdateStrength is unavailable; using OnTick fallback")
        return
    end
    if methods[BODY_DAMAGE_PATCH_KEY] then return end

    local originalUpdateStrength = methods.UpdateStrength
    methods[BODY_DAMAGE_PATCH_KEY] = originalUpdateStrength
    methods.UpdateStrength = function(bodyDamage, ...)
        local result = originalUpdateStrength(bodyDamage, ...)
        local character = safeCall(function() return bodyDamage:getParentChar() end, nil)
        applyCharacterCapacity(character)
        return result
    end
    print("[RemoveLimits] Build 42 character-capacity recalculation patch installed")
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
        if not settings().ignoreVehicleCargoMass then
            return originalUpdateTotalMass(vehicle, ...)
        end

        local ok = pcall(function()
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
            return originalUpdateTotalMass(vehicle, ...)
        end
    end
    print("[RemoveLimits] Vehicle cargo mass exclusion patch installed")
end

local function applyActivePlayerCapacities()
    local count = tonumber(safeCall(function() return getNumActivePlayers() end, 1)) or 1
    for playerIndex = 0, math.max(0, count - 1) do
        local player = safeCall(function() return getSpecificPlayer(playerIndex) end, nil)
        if player then applyCharacterCapacity(player) end
    end
end

Events.OnGameBoot.Add(installPatch)
Events.OnGameBoot.Add(installBodyDamagePatch)
Events.OnGameBoot.Add(installVehicleMassPatch)
-- OnTick runs after the engine's player/body-damage update in Build 42.20.3,
-- guaranteeing the inventory title reads the final configured value.
Events.OnTick.Add(applyActivePlayerCapacities)
