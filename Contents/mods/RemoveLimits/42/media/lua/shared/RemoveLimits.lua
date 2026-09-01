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
local FLUID_CAN_TRANSFER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalCanTransfer"
local FLUID_TRANSFER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalTransfer"
local NETWORK_MODULE = "RemoveLimits"
local COMMAND_CHARACTER_READY = "CharacterReady"
local COMMAND_SANDBOX_CHANGED = "SandboxChanged"
local COMMAND_APPLY_CHARACTER = "ApplyCharacterCapacity"
local UNLIMITED_CHARACTER_CAPACITY = 10000
local UNLIMITED_CONTAINER_CAPACITY = 10000
local MAX_CHARACTER_CONTAINER_CAPACITY = 100
local unpackValues = unpack or table.unpack
local characterStates = setmetatable({}, { __mode = "k" })
local originalGetEffectiveCapacity = nil
local originalCharacterGetMaxWeight = nil
local originalCharacterSetMaxWeight = nil
local originalCharacterGetMaxWeightBase = nil
local originalCharacterSetMaxWeightBase = nil
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

local function configuredFreeCharacterCapacity(character)
    if not character or not instanceof or not instanceof(character, "IsoPlayer") or characterMode() == 1 then
        return nil
    end
    local inventory = safeCall(function() return character:getInventory() end, nil)
    if not inventory then return nil end
    local limit = effectiveCharacterCapacity(character)
    local weight = tonumber(safeCall(function() return inventory:getCapacityWeight() end, nil))
    if not limit or not weight then return nil end
    return math.max(0, limit - weight)
end

-- Build 42's native FluidContainer.CanTransfer() directly calls the Java
-- IsoPlayer.hasFullInventory(), bypassing Lua accessors. During one synchronous
-- native transfer check/call, detach only the destination item's back-reference
-- to the character inventory, then restore it immediately. All native fluid
-- filters, mixing rules, target capacity and synchronization remain intact.
local function withFluidTargetCapacityBypass(targetFluidContainer, callback)
    if type(callback) ~= "function" or not targetFluidContainer then
        return callback and callback() or nil
    end

    local owner = safeCall(function() return targetFluidContainer:getOwner() end, nil)
    if not owner or not instanceof or not instanceof(owner, "InventoryItem") then
        return callback()
    end
    local inventory = safeCall(function() return owner:getContainer() end, nil)
    local player = inventory and safeCall(function() return inventory:getParent() end, nil) or nil
    local freeCapacity = player and configuredFreeCharacterCapacity(player) or nil
    if freeCapacity == nil or freeCapacity <= 0 then return callback() end

    local detached = safeCall(function()
        owner:setContainer(nil)
        return owner:getContainer() == nil
    end, false)
    if not detached then return callback() end

    local results = { pcall(callback) }
    owner:setContainer(inventory)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return unpackValues(results)
end

local function installFluidTransferBridge()
    if not FluidContainer
        or type(FluidContainer.CanTransfer) ~= "function"
        or type(FluidContainer.Transfer) ~= "function" then
        print("[RemoveLimits] Native fluid transfer API is unavailable; bridge not installed")
        return
    end
    if FluidContainer[FLUID_CAN_TRANSFER_PATCH_KEY] then return end

    local originalCanTransfer = FluidContainer.CanTransfer
    local originalTransfer = FluidContainer.Transfer
    FluidContainer[FLUID_CAN_TRANSFER_PATCH_KEY] = originalCanTransfer
    FluidContainer[FLUID_TRANSFER_PATCH_KEY] = originalTransfer
    FluidContainer.CanTransfer = function(source, target)
        return withFluidTargetCapacityBypass(target, function()
            return originalCanTransfer(source, target)
        end)
    end
    FluidContainer.Transfer = function(source, target, ...)
        local arguments = { ... }
        return withFluidTargetCapacityBypass(target, function()
            return originalTransfer(source, target, unpackValues(arguments))
        end)
    end
    print("[RemoveLimits] Native fluid transfer capacity bridge installed")
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

local function configuredEffectiveCapacity(container, character, vanillaCapacity)
    if classify(container) ~= "character" or characterMode() == 1 then
        return configuredContainerCapacity(container, character, vanillaCapacity)
    end

    -- Both the legacy RecipeManager path and Build 42's CraftRecipe path
    -- finish in Actions.addOrDropItem(). Vanilla adds the crafted output,
    -- then compares getCapacityWeight() with getEffectiveCapacity() and drops
    -- the item on the floor when the latter still reports the physical Java
    -- limit of 100. Override only this logical/effective accessor; getCapacity
    -- continues to expose the physical value needed for durable restoration.
    local owner = safeCall(function() return container:getParent() end, nil)
    local configured = effectiveCharacterCapacity(owner or character)
    return configured or vanillaCapacity
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
        or type(methods.setMaxWeightBase) ~= "function" then
        print("[RemoveLimits] IsoGameCharacter capacity fields are unavailable; character capacity patch not installed")
        return
    end

    originalCharacterGetMaxWeight = methods.getMaxWeight
    originalCharacterSetMaxWeight = methods.setMaxWeight
    originalCharacterGetMaxWeightBase = methods.getMaxWeightBase
    originalCharacterSetMaxWeightBase = methods.setMaxWeightBase

    local function patchFluidAccessors(targetMethods, className)
        if not targetMethods
            or type(targetMethods.hasFullInventory) ~= "function"
            or type(targetMethods.getFreeInventoryCapacity) ~= "function" then
            print("[RemoveLimits] " .. className .. " fluid accessors are unavailable; patch not installed")
            return false
        end
        if rawget(targetMethods, HAS_FULL_INVENTORY_PATCH_KEY) then return true end

        local originalHasFullInventory = targetMethods.hasFullInventory
        local originalGetFreeInventoryCapacity = targetMethods.getFreeInventoryCapacity
        rawset(targetMethods, HAS_FULL_INVENTORY_PATCH_KEY, originalHasFullInventory)
        rawset(targetMethods, FREE_INVENTORY_CAPACITY_PATCH_KEY, originalGetFreeInventoryCapacity)

        targetMethods.getFreeInventoryCapacity = function(character)
            local configured = configuredFreeCharacterCapacity(character)
            if configured ~= nil then return configured end
            return originalGetFreeInventoryCapacity(character)
        end
        targetMethods.hasFullInventory = function(character)
            local configured = configuredFreeCharacterCapacity(character)
            if configured ~= nil then return configured <= 0 end
            return originalHasFullInventory(character)
        end
        return true
    end

    local characterPatched = patchFluidAccessors(methods, "IsoGameCharacter")
    local playerPatched = false
    if IsoPlayer and IsoPlayer.class then
        local playerMetatable = __classmetatables[IsoPlayer.class]
        local playerMethods = playerMetatable and playerMetatable.__index
        if playerMethods == methods then
            playerPatched = characterPatched
        else
            playerPatched = patchFluidAccessors(playerMethods, "IsoPlayer")
        end
    end
    if characterPatched or playerPatched then
        print("[RemoveLimits] Character capacity and fluid-action accessors installed"
            .. " (IsoGameCharacter=" .. tostring(characterPatched)
            .. ", IsoPlayer=" .. tostring(playerPatched) .. ")")
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
        local vanillaCapacity = safeCall(function() return originalGetCapacity(container) end, 0)
        return configuredContainerCapacity(container, nil, vanillaCapacity)
    end
    methods.getEffectiveCapacity = function(container, character)
        local vanillaCapacity = safeCall(function()
            return originalGetEffectiveCapacity(container, character)
        end, safeCall(function() return originalGetCapacity(container) end, 0))
        return configuredEffectiveCapacity(container, character, vanillaCapacity)
    end
    methods.getMaxWeight = function(container)
        local vanillaCapacity = safeCall(function() return originalGetMaxWeight(container) end, 0)
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

local function playerOnlineID(player)
    return tonumber(safeCall(function() return player:getOnlineID() end, -1)) or -1
end

local function notifyCharacterCapacity(player)
    if not player or not sendServerCommand then return end
    safeCall(function()
        sendServerCommand(player, NETWORK_MODULE, COMMAND_APPLY_CHARACTER, {
            onlineID = playerOnlineID(player),
        })
    end, nil)
end

local function applyAuthoritativeCharacterCapacity(player)
    applyCharacterCapacity(player)
    notifyCharacterCapacity(player)
end

local function canChangeSandbox(player)
    if not player then return false end

    local role = safeCall(function() return player:getRole() end, nil)
    if role and Capability and Capability.SandboxOptions then
        return safeCall(function()
            return role:hasCapability(Capability.SandboxOptions)
        end, false) == true
    end

    -- Compatibility fallback for older Build 42 role APIs.
    return safeCall(function() return player:isAdmin() end, false) == true
end

local function applyCapacityToOnlinePlayers()
    local players = getOnlinePlayers and safeCall(getOnlinePlayers, nil) or nil
    if not players then return 0 end

    local applied = 0
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player then
            applyAuthoritativeCharacterCapacity(player)
            applied = applied + 1
        end
    end
    return applied
end

local function onClientCommand(module, command, player)
    if module ~= NETWORK_MODULE or not player then return end

    if command == COMMAND_CHARACTER_READY then
        -- OnCreatePlayer is a client-only lifecycle event in Build 42. The
        -- dedicated server applies its own authoritative copy exactly once
        -- when the newly-created client character announces readiness.
        applyAuthoritativeCharacterCapacity(player)
        print("[RemoveLimits] Server capacity applied for connected player")
        return
    end

    if command == COMMAND_SANDBOX_CHANGED then
        if not canChangeSandbox(player) then
            print("[RemoveLimits] Rejected sandbox refresh from a player without permission")
            return
        end

        -- SandboxOptions:sendToServer() has already updated SandboxVars before
        -- this ordered client command arrives. Reapply once to every connected
        -- player; container and vehicle options are read dynamically already.
        local count = applyCapacityToOnlinePlayers()
        print("[RemoveLimits] Server capacity refreshed after sandbox update for "
            .. tostring(count) .. " player(s)")
    end
end

local function localPlayerForCommand(arguments)
    local onlineID = arguments and tonumber(arguments.onlineID) or nil
    if onlineID and getPlayerByOnlineID then
        local player = safeCall(function() return getPlayerByOnlineID(onlineID) end, nil)
        if player then return player end
    end

    -- Some client builds do not expose getPlayerByOnlineID(). Match the
    -- recipient among local split-screen players before falling back to the
    -- primary player.
    if onlineID and getSpecificPlayer then
        local playerCount = getNumActivePlayers
            and tonumber(safeCall(getNumActivePlayers, 0)) or 4
        for playerIndex = 0, math.max(0, playerCount - 1) do
            local player = safeCall(function() return getSpecificPlayer(playerIndex) end, nil)
            if player and playerOnlineID(player) == onlineID then return player end
        end
    end
    return getPlayer and getPlayer() or nil
end

local function onServerCommand(module, command, arguments)
    if module ~= NETWORK_MODULE or command ~= COMMAND_APPLY_CHARACTER then return end
    local player = localPlayerForCommand(arguments)
    if player then applyCharacterCapacity(player) end
end

local function onCreatePlayer(_, player)
    applyCharacterCapacity(player)
    if isClient and isClient() and sendClientCommand then
        -- No capacity number is sent by the client. The server always reads
        -- its own sandbox configuration, so clients cannot grant themselves
        -- a larger limit.
        sendClientCommand(player, NETWORK_MODULE, COMMAND_CHARACTER_READY, {})
    end
end

Events.OnGameBoot.Add(installPatch)
Events.OnGameBoot.Add(installCharacterCapacityAccessors)
Events.OnGameBoot.Add(installVehicleMassPatch)
Events.OnGameBoot.Add(installFluidTransferBridge)
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(onCreatePlayer)
end
if Events.OnClientCommand then
    Events.OnClientCommand.Add(onClientCommand)
end
if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end

RemoveLimits = RemoveLimits or {}
RemoveLimits.applyCharacterCapacity = applyCharacterCapacity
RemoveLimits.getFreeCharacterCapacity = configuredFreeCharacterCapacity
RemoveLimits.withFluidTargetCapacityBypass = withFluidTargetCapacityBypass
RemoveLimits.notifySandboxChanged = function(player)
    if not (isClient and isClient()) or not sendClientCommand or not player then return false end
    sendClientCommand(player, NETWORK_MODULE, COMMAND_SANDBOX_CHANGED, {})
    return true
end

-- Manual test helper. It creates exactly one item when explicitly called and
-- never registers an update event or adds the item to normal loot tables.
-- Example: RemoveLimits.addCapacityTestItem(300)
local function setCapacityTestItemWeight(item, weight, inventory)
    if not item then return nil end
    local requestedWeight = math.max(0.1, tonumber(weight) or 150)
    safeCall(function()
        item:setActualWeight(requestedWeight)
        item:setWeight(requestedWeight)
        item:setCustomWeight(true)
        if inventory then inventory:setDrawDirty(true) end
    end, nil)
    return item
end

function RemoveLimits.addCapacityTestItem(weight, player)
    local character = player or (getPlayer and getPlayer())
    if not character then return nil, "player is unavailable" end

    local inventory = safeCall(function() return character:getInventory() end, nil)
    if not inventory then return nil, "player inventory is unavailable" end

    local requestedWeight = math.max(0.1, tonumber(weight) or 150)
    local item = safeCall(function()
        return inventory:AddItem("RemoveLimits.CapacityTestWeight")
    end, nil)
    if not item then return nil, "test item could not be created" end

    setCapacityTestItemWeight(item, requestedWeight, inventory)
    print("[RemoveLimits] Added capacity test item with weight " .. tostring(requestedWeight))
    return item
end

-- Keep the test item's custom weight explicit after crafting as well. The item
-- definition itself already weighs 150, so crafting it now exercises the same
-- generic Actions.addOrDropItem path as every other recipe.
function RemoveLimits.onCreateCapacityTestWeight(craftRecipeData, character)
    if not craftRecipeData then return end
    local createdItems = safeCall(function() return craftRecipeData:getAllCreatedItems() end, nil)
    if not createdItems then return end
    local inventory = character and safeCall(function() return character:getInventory() end, nil) or nil
    for index = 0, createdItems:size() - 1 do
        local item = createdItems:get(index)
        setCapacityTestItemWeight(item, 150, inventory)
    end
    print("[RemoveLimits] Crafted capacity test item with weight 150")
end
