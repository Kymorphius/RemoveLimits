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
local CHARACTER_MAX_WEIGHT_PATCH_KEY = "RemoveCapacityAndPickUpLimits_IsoGameCharacter_originalGetMaxWeight"
local CHARACTER_MAX_WEIGHT_BASE_PATCH_KEY = "RemoveCapacityAndPickUpLimits_IsoGameCharacter_originalGetMaxWeightBase"
local VEHICLE_MASS_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalUpdateTotalMass"
local VEHICLE_CONTENT_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalSetContainerContentAmount"
local VEHICLE_SEAT_OCCUPIED_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalIsSeatOccupied"
local FLUID_CAN_TRANSFER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalCanTransfer"
local FLUID_TRANSFER_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalTransfer"
local NETWORK_MODULE = "RemoveLimits"
local COMMAND_CHARACTER_READY = "CharacterReady"
local COMMAND_SANDBOX_CHANGED = "SandboxChanged"
local COMMAND_APPLY_CHARACTER = "ApplyCharacterCapacity"
local COMMAND_TRANSFER_REQUEST = "CapacityTransferRequest"
local COMMAND_TRANSFER_RESULT = "CapacityTransferResult"
local UNLIMITED_CHARACTER_CAPACITY = 10000
local UNLIMITED_CONTAINER_CAPACITY = 10000
local MAX_CHARACTER_CONTAINER_CAPACITY = 100
local unpackValues = unpack or table.unpack
local characterStates = setmetatable({}, { __mode = "k" })
local originalHasRoomFor = nil
local originalGetEffectiveCapacity = nil
local originalCharacterGetMaxWeight = nil
local originalCharacterSetMaxWeight = nil
local originalCharacterGetMaxWeightBase = nil
local originalCharacterSetMaxWeightBase = nil
local vehicleMassFailureReported = false
local pendingReadyPlayers = setmetatable({}, { __mode = "k" })
local pendingReadyPlayerCount = 0
local readyPlayerUpdateRegistered = false
local clientGameStarted = false

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

local function setUnlimitedCarryState(character, enabled)
    local cheats = safeCall(function() return character:getCheats() end, nil)
    local cheatTypes = getCheatTypes and safeCall(getCheatTypes, nil) or nil
    if cheats and cheatTypes then
        for index = 0, cheatTypes:size() - 1 do
            local cheatType = cheatTypes:get(index)
            if safeCall(function() return cheatType:getTooltip() end, nil) == "UnlimitedCarry" then
                return safeCall(function() cheats:set(cheatType, enabled == true) end, nil)
            end
        end
    end
    return safeCall(function() character:setUnlimitedCarry(enabled == true) end, nil)
end

local function effectiveCharacterCapacity(character)
    local mode = characterMode()
    if mode == 1 then return nil end
    -- Multiplayer can restore the native character field after OnCreatePlayer.
    -- That physical field is not our logical capacity authority: every Lua
    -- caller must consistently see the server-owned sandbox target.
    return configuredCharacterTarget()
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
    local affected = category == "floor"
        or (category == "bag" and booleanSetting("AffectBags"))
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

local function configuredTransferMode(container)
    local category = classify(container)
    if category == "character" then
        return category, characterMode()
    end
    if category == "floor" then
        return category, numberSetting("ContainerMode", 3)
    end
    if category == "bag" and booleanSetting("AffectBags") then
        return category, numberSetting("ContainerMode", 3)
    end
    if category == "vehicle" and booleanSetting("AffectVehicles") then
        return category, numberSetting("ContainerMode", 3)
    end
    if category == "world" and booleanSetting("AffectWorldContainers") then
        return category, numberSetting("ContainerMode", 3)
    end
    return category, 1
end

local function usesConfiguredTransferCapacity(container)
    local category, mode = configuredTransferMode(container)
    return mode ~= 1 and category ~= "other-character"
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

-- Build 42 multiplayer validates inventory transactions in Java. Java-to-Java
-- calls do not pass through the Lua method-table replacement below, so a
-- logically valid transfer can still be rejected by the physical capacity-100
-- ceiling. The client timed-action bridge uses this predicate to skip only the
-- redundant native transaction lock for that exact capacity-only difference;
-- the normal server-side timed action still validates and performs the move.
local function shouldBypassNativeTransfer(character, item, source, destination, sourceItemIsWorldItem)
    if not character or not item or not source or not destination or not originalHasRoomFor then return false end
    if source == destination then return false end
    -- A floor ItemContainer is only a virtual UI/transaction endpoint.  The
    -- canonical InventoryItem belongs to an IsoWorldInventoryObject and has no
    -- ordinary ItemContainer on the server, so it cannot pass contains().
    if not sourceItemIsWorldItem
        and not safeCall(function() return source:contains(item) end, false) then return false end
    if type(source.isRemoveItemAllowed) == "function"
        and not safeCall(function() return source:isRemoveItemAllowed(item) end, false) then return false end

    local category, mode = configuredTransferMode(destination)
    if mode == 1 or category == "other-character" then return false end

    local weight = addedWeight(item)
    if not weight or not itemAllowed(destination, item) then return false end
    if exceedsBagItemSize(destination, item, weight) then return false end
    if isHeavyItemBlockedInVehicle(character, destination, item) then return false end

    -- UnlimitedCarry makes ItemContainer.hasRoomFor() return true for a player,
    -- but Build 42's multiplayer ItemTransaction still compares against the
    -- physical ItemContainer ceiling. Detect that physical/logical mismatch
    -- directly instead of treating native hasRoomFor() as transaction proof.
    local physicalCapacity = originalGetEffectiveCapacity and tonumber(safeCall(function()
        return originalGetEffectiveCapacity(destination, character)
    end, nil)) or nil
    local currentWeight = tonumber(safeCall(function()
        return destination:getCapacityWeight()
    end, nil))
    local correctedWeight = currentWeight
    if currentWeight and ItemContainer and type(ItemContainer.floatingPointCorrection) == "function" then
        correctedWeight = tonumber(safeCall(function()
            return ItemContainer.floatingPointCorrection(currentWeight)
        end, currentWeight)) or currentWeight
    end
    if not physicalCapacity or not currentWeight
        or correctedWeight + weight <= physicalCapacity then
        return false
    end

    return safeCall(function()
        return destination:hasRoomFor(character, item)
    end, false) == true
end

local function describeTransferContainer(container, player, transferItem, depth)
    depth = (depth or 0) + 1
    if not container or not player or depth > 4 then return nil end
    if container == safeCall(function() return player:getInventory() end, nil) then
        return { kind = "player" }
    end

    local containingItem = safeCall(function() return container:getContainingItem() end, nil)
    if containingItem then
        local outer = safeCall(function() return containingItem:getContainer() end, nil)
        local outerDescriptor = describeTransferContainer(outer, player, transferItem, depth)
        local itemID = tonumber(safeCall(function() return containingItem:getID() end, nil))
        if outerDescriptor and itemID then
            return { kind = "item", itemID = itemID, outer = outerDescriptor }
        end
        return nil
    end

    local vehiclePart = safeCall(function() return container:getVehiclePart() end, nil)
    if vehiclePart then
        local vehicle = safeCall(function() return vehiclePart:getVehicle() end, nil)
        local vehicleID = vehicle and tonumber(safeCall(function() return vehicle:getId() end, nil)) or nil
        local partID = safeCall(function() return vehiclePart:getId() end, nil)
        if vehicleID and partID then
            return { kind = "vehicle", vehicle = vehicleID, part = tostring(partID) }
        end
        return nil
    end

    local square = safeCall(function() return container:getSourceGrid() end, nil)
    if not square and container:getType() == "floor" then
        local worldItem = transferItem and safeCall(function() return transferItem:getWorldItem() end, nil) or nil
        square = worldItem and safeCall(function() return worldItem:getSquare() end, nil)
            or safeCall(function() return player:getCurrentSquare() end, nil)
    end
    local parent = safeCall(function() return container:getParent() end, nil)
    if not square and parent then square = safeCall(function() return parent:getSquare() end, nil) end
    if not square then return nil end

    local descriptor = {
        kind = container:getType() == "floor" and "floor" or "object",
        x = tonumber(square:getX()), y = tonumber(square:getY()), z = tonumber(square:getZ()),
        containerID = tonumber(safeCall(function() return container.id end, -1)) or -1,
    }
    if descriptor.kind == "object" and parent then
        descriptor.objectIndex = tonumber(safeCall(function() return parent:getObjectIndex() end, -1)) or -1
        descriptor.containerIndex = tonumber(safeCall(function() return parent:getContainerIndex(container) end, -1)) or -1
    end
    return descriptor
end

local function findItemByID(container, itemID)
    if not container or not itemID then return nil end
    local direct = safeCall(function() return container:getItemWithID(itemID) end, nil)
    if direct then return direct end
    return safeCall(function() return container:getItemWithIDRecursiv(itemID) end, nil)
end

local function containerFromObject(object, containerIndex, containerID)
    if not object then return nil end
    if containerIndex and containerIndex >= 0 then
        local indexed = safeCall(function() return object:getContainerByIndex(containerIndex) end, nil)
        -- Object and container indices are the same identity used by the
        -- native transaction packet. ItemContainer.id is only a fallback;
        -- it is not guaranteed to be identical in every client process.
        if indexed then return indexed end
    end
    local count = tonumber(safeCall(function() return object:getContainerCount() end, 0)) or 0
    for index = 0, count - 1 do
        local candidate = safeCall(function() return object:getContainerByIndex(index) end, nil)
        local candidateID = candidate and tonumber(safeCall(function() return candidate.id end, -2)) or -2
        if candidate and candidateID == containerID then return candidate end
    end
    local primary = safeCall(function() return object:getContainer() end, nil)
    local primaryID = primary and tonumber(safeCall(function() return primary.id end, -2)) or -2
    if primary and (not containerID or containerID < 0 or primaryID == containerID) then return primary end
    return nil
end

local function gridSquareFromDescriptor(descriptor)
    if type(descriptor) ~= "table" or not getCell then return nil end
    local x, y, z = tonumber(descriptor.x), tonumber(descriptor.y), tonumber(descriptor.z)
    if not x or not y or not z then return nil end
    return safeCall(function() return getCell():getGridSquare(x, y, z) end, nil)
end

local function newFloorTransferContainer(square)
    if not square or not ItemContainer or type(ItemContainer.new) ~= "function" then return nil end
    return safeCall(function() return ItemContainer.new("floor", square, nil) end, nil)
end

local function findFloorItemByID(square, itemID)
    if not square or not itemID then return nil end
    local worldObjects = safeCall(function() return square:getWorldObjects() end, nil)
    if not worldObjects then return nil end
    for index = 0, worldObjects:size() - 1 do
        local worldObject = worldObjects:get(index)
        local item = worldObject and safeCall(function() return worldObject:getItem() end, nil) or nil
        if item and tonumber(safeCall(function() return item:getID() end, nil)) == itemID then
            return item
        end
    end
    return nil
end

local function resolveTransferContainer(player, descriptor, transferItemID)
    if not player or type(descriptor) ~= "table" then return nil end
    if descriptor.kind == "player" then return safeCall(function() return player:getInventory() end, nil) end
    if descriptor.kind == "item" then
        local outer = resolveTransferContainer(player, descriptor.outer, transferItemID)
        local owner = findItemByID(outer, tonumber(descriptor.itemID))
        return owner and safeCall(function() return owner:getInventory() end, nil) or nil
    end
    if descriptor.kind == "vehicle" then
        local vehicle = getVehicleById and safeCall(function()
            return getVehicleById(tonumber(descriptor.vehicle))
        end, nil) or nil
        local part = vehicle and safeCall(function() return vehicle:getPartById(tostring(descriptor.part)) end, nil) or nil
        return part and safeCall(function() return part:getItemContainer() end, nil) or nil
    end

    local square = gridSquareFromDescriptor(descriptor)
    if not square then return nil end
    if descriptor.kind == "floor" then
        -- Ground items do not have an ordinary owning ItemContainer.  Return
        -- the virtual floor endpoint here; processCapacityTransfer resolves the
        -- canonical world item separately from the square.
        if not findFloorItemByID(square, transferItemID) then return nil end
        return newFloorTransferContainer(square)
    end
    if descriptor.kind ~= "object" then return nil end

    local objects = safeCall(function() return square:getObjects() end, nil)
    local objectIndex = tonumber(descriptor.objectIndex) or -1
    if objects and objectIndex >= 0 and objectIndex < objects:size() then
        local resolved = containerFromObject(objects:get(objectIndex), tonumber(descriptor.containerIndex),
            tonumber(descriptor.containerID))
        if resolved then return resolved end
    end

    local collections = {
        objects,
        safeCall(function() return square:getSpecialObjects() end, nil),
        safeCall(function() return square:getStaticMovingObjects() end, nil),
    }
    for _, collection in ipairs(collections) do
        if collection then
            for index = 0, collection:size() - 1 do
                local resolved = containerFromObject(collection:get(index), tonumber(descriptor.containerIndex),
                    tonumber(descriptor.containerID))
                local resolvedID = resolved and tonumber(safeCall(function() return resolved.id end, -2)) or -2
                if resolved and resolvedID == tonumber(descriptor.containerID) then return resolved end
            end
        end
    end
    return nil
end

local function transferContainerIsNearPlayer(player, container)
    if not player or not container then return false end
    if container == safeCall(function() return player:getInventory() end, nil) then return true end
    local ownerItem = safeCall(function() return container:getContainingItem() end, nil)
    if ownerItem then
        return transferContainerIsNearPlayer(player, safeCall(function() return ownerItem:getContainer() end, nil))
    end
    local part = safeCall(function() return container:getVehiclePart() end, nil)
    local target = part and safeCall(function() return part:getVehicle() end, nil)
        or safeCall(function() return container:getParent() end, nil)
    local square = safeCall(function() return container:getSourceGrid() end, nil)
    local x = target and tonumber(safeCall(function() return target:getX() end, nil))
        or square and tonumber(square:getX())
    local y = target and tonumber(safeCall(function() return target:getY() end, nil))
        or square and tonumber(square:getY())
    local z = target and tonumber(safeCall(function() return target:getZ() end, nil))
        or square and tonumber(square:getZ())
    if not x or not y or not z then return false end
    local dx, dy = (tonumber(player:getX()) or 0) - x, (tonumber(player:getY()) or 0) - y
    return dx * dx + dy * dy <= 25 and math.abs((tonumber(player:getZ()) or 0) - z) <= 1
end

local function transferSquareIsNearPlayer(player, square)
    if not player or not square then return false end
    local dx = (tonumber(player:getX()) or 0) - tonumber(square:getX())
    local dy = (tonumber(player:getY()) or 0) - tonumber(square:getY())
    return dx * dx + dy * dy <= 25
        and math.abs((tonumber(player:getZ()) or 0) - tonumber(square:getZ())) <= 1
end

local function processCapacityTransfer(player, arguments)
    local requestID = arguments and tonumber(arguments.requestID) or nil
    local itemID = arguments and tonumber(arguments.itemID) or nil
    if not requestID or not itemID then return false, "invalid request" end
    local sourceIsFloor = arguments.source and arguments.source.kind == "floor"
    local sourceSquare = sourceIsFloor and gridSquareFromDescriptor(arguments.source) or nil
    local source = resolveTransferContainer(player, arguments.source, itemID)
    local destinationIsFloor = arguments.destination and arguments.destination.kind == "floor"
    local destinationSquare = destinationIsFloor and gridSquareFromDescriptor(arguments.destination) or nil
    local destination = destinationIsFloor
        and newFloorTransferContainer(destinationSquare)
        or resolveTransferContainer(player, arguments.destination, itemID)
    local item = sourceIsFloor and findFloorItemByID(sourceSquare, itemID)
        or source and findItemByID(source, itemID) or nil
    if not source then return false, "source container unavailable" end
    if not destination then return false, "destination container unavailable" end
    if not item then return false, "source item unavailable" end
    if sourceIsFloor then
        if not transferSquareIsNearPlayer(player, sourceSquare) then return false, "source floor out of range" end
    elseif not transferContainerIsNearPlayer(player, source) then
        return false, "source out of range"
    end
    if destinationIsFloor then
        if not destinationSquare then return false, "floor unavailable" end
        if not transferSquareIsNearPlayer(player, destinationSquare) then
            return false, "floor out of range"
        end
    elseif not transferContainerIsNearPlayer(player, destination) then
        return false, "destination out of range"
    end
    if safeCall(function() return item:getIsCraftingConsumed() end, false) then return false, "item consumed" end
    if safeCall(function() return item:isFavorite() end, false)
        and not safeCall(function() return destination:isInCharacterInventory(player) end, false) then
        return false, "favorite item"
    end
    if not shouldBypassNativeTransfer(player, item, source, destination, sourceIsFloor) then
        return false, "not a capacity-only transfer"
    end

    local loaded = safeCall(function() require "TimedActions/ISTransferAction" return ISTransferAction end, nil)
    if not loaded or type(loaded.transferItem) ~= "function" then return false, "transfer API unavailable" end
    if destinationIsFloor and type(loaded.canDropOnFloor) == "function"
        and not safeCall(function()
            return loaded:canDropOnFloor(destinationSquare, player)
        end, false) then return false, "floor is not drop-safe" end
    local moved = loaded:transferItem(player, item, source, destination, destinationSquare)
    local movedSuccessfully
    if destinationIsFloor then
        movedSuccessfully = moved and safeCall(function() return moved:getWorldItem() ~= nil end, false)
    else
        movedSuccessfully = moved and safeCall(function() return destination:contains(moved) end, false)
    end
    if not movedSuccessfully then
        return false, "transfer failed"
    end
    if not destinationIsFloor and sendAddItemToContainer then sendAddItemToContainer(destination, moved) end
    return true
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
            originalUnlimitedCarry = safeCall(function() return character:isUnlimitedCarry() end, false) == true,
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
                setUnlimitedCarryState(character, state.originalUnlimitedCarry)
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
    -- Seed the legacy fields once for compatibility. Build 42 may recalculate
    -- them later, so durable carry behavior uses its native UnlimitedCarry flag
    -- and durable UI/transfer behavior uses the logical accessors above.
    safeCall(function()
        local currentBase = originalCharacterGetMaxWeightBase(character)
        if currentBase ~= target then originalCharacterSetMaxWeightBase(character, target) end
        local currentMax = originalCharacterGetMaxWeight(character)
        if currentMax ~= target then originalCharacterSetMaxWeight(character, target) end
    end, nil)
    safeCall(function()
        if inventory:getCapacity() ~= inventoryTarget then inventory:setCapacity(inventoryTarget) end
    end, nil)
    if not safeCall(function() return character:isUnlimitedCarry() end, false) then
        setUnlimitedCarryState(character, true)
    end
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

    originalCharacterGetMaxWeight = rawget(methods, CHARACTER_MAX_WEIGHT_PATCH_KEY) or methods.getMaxWeight
    originalCharacterSetMaxWeight = methods.setMaxWeight
    originalCharacterGetMaxWeightBase = rawget(methods, CHARACTER_MAX_WEIGHT_BASE_PATCH_KEY) or methods.getMaxWeightBase
    originalCharacterSetMaxWeightBase = methods.setMaxWeightBase

    local function patchLogicalCapacityAccessors(targetMethods, className)
        if not targetMethods or type(targetMethods.getMaxWeight) ~= "function"
            or type(targetMethods.getMaxWeightBase) ~= "function" then
            print("[RemoveLimits] " .. className .. " logical capacity accessors are unavailable")
            return false
        end
        if rawget(targetMethods, CHARACTER_MAX_WEIGHT_PATCH_KEY) then return true end

        local originalGetMaxWeight = targetMethods.getMaxWeight
        local originalGetMaxWeightBase = targetMethods.getMaxWeightBase
        rawset(targetMethods, CHARACTER_MAX_WEIGHT_PATCH_KEY, originalGetMaxWeight)
        rawset(targetMethods, CHARACTER_MAX_WEIGHT_BASE_PATCH_KEY, originalGetMaxWeightBase)
        targetMethods.getMaxWeight = function(character)
            if character and instanceof and instanceof(character, "IsoPlayer")
                and characterMode() ~= 1 then return configuredCharacterTarget() end
            return originalGetMaxWeight(character)
        end
        targetMethods.getMaxWeightBase = function(character)
            if character and instanceof and instanceof(character, "IsoPlayer")
                and characterMode() ~= 1 then return configuredCharacterTarget() end
            return originalGetMaxWeightBase(character)
        end
        return true
    end

    local characterCapacityPatched = patchLogicalCapacityAccessors(methods, "IsoGameCharacter")

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
    local playerCapacityPatched = false
    if IsoPlayer and IsoPlayer.class then
        local playerMetatable = __classmetatables[IsoPlayer.class]
        local playerMethods = playerMetatable and playerMetatable.__index
        if playerMethods == methods then
            playerPatched = characterPatched
            playerCapacityPatched = characterCapacityPatched
        else
            playerPatched = patchFluidAccessors(playerMethods, "IsoPlayer")
            playerCapacityPatched = patchLogicalCapacityAccessors(playerMethods, "IsoPlayer")
        end
    end
    if characterPatched or playerPatched or characterCapacityPatched or playerCapacityPatched then
        print("[RemoveLimits] Character capacity and fluid-action accessors installed"
            .. " (IsoGameCharacter=" .. tostring(characterPatched and characterCapacityPatched)
            .. ", IsoPlayer=" .. tostring(playerPatched and playerCapacityPatched) .. ")")
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

    originalHasRoomFor = methods.hasRoomFor
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

        local category, mode = configuredTransferMode(container)

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

        local initialMass = tonumber(safeCall(function() return vehicle:getInitialMass() end, nil))
        local cargoMass = tonumber(safeCall(function() return vehicle:getTotalContainerItemWeight() end, nil))
        if not initialMass or not cargoMass or cargoMass == 0 then
            return originalUpdateTotalMass(vehicle, ...)
        end

        local arguments = { ... }
        vehicle:setInitialMass(initialMass - cargoMass)
        local results = { pcall(function()
            return originalUpdateTotalMass(vehicle, unpackValues(arguments))
        end) }
        vehicle:setInitialMass(initialMass)
        local ok, err = results[1], results[2]
        if not ok then
            if not vehicleMassFailureReported then
                print("[RemoveLimits] Vehicle cargo mass patch failed; using vanilla mass: " .. tostring(err))
                vehicleMassFailureReported = true
            end
            return originalUpdateTotalMass(vehicle, ...)
        end
        table.remove(results, 1)
        return unpackValues(results)
    end

    if type(methods.isSeatOccupied) == "function" and type(methods.getCharacter) == "function"
        and not methods[VEHICLE_SEAT_OCCUPIED_PATCH_KEY] then
        local originalIsSeatOccupied = methods.isSeatOccupied
        methods[VEHICLE_SEAT_OCCUPIED_PATCH_KEY] = originalIsSeatOccupied
        methods.isSeatOccupied = function(vehicle, seat)
            local occupied = originalIsSeatOccupied(vehicle, seat)
            if not occupied
                or not booleanSetting("AllowSeatWithItems")
                or not booleanSetting("AffectVehicles")
                or numberSetting("ContainerMode", 3) == 1 then return occupied end
            local character = safeCall(function() return vehicle:getCharacter(seat) end, false)
            return character ~= nil
        end
    end


    local partMetatable = VehiclePart and VehiclePart.class and __classmetatables[VehiclePart.class]
    local partMethods = partMetatable and partMetatable.__index
    if partMethods and type(partMethods.setContainerContentAmount) == "function"
        and not partMethods[VEHICLE_CONTENT_PATCH_KEY] then
        local originalSetContainerContentAmount = partMethods.setContainerContentAmount
        partMethods[VEHICLE_CONTENT_PATCH_KEY] = originalSetContainerContentAmount
        partMethods.setContainerContentAmount = function(part, ...)
            local results = { originalSetContainerContentAmount(part, ...) }
            local vehicle = booleanSetting("IgnoreVehicleCargoMass")
                and safeCall(function() return part:getVehicle() end, nil) or nil
            if vehicle then vehicle:updateTotalMass() end
            return unpackValues(results)
        end
    end
    print("[RemoveLimits] Vehicle cargo mass and seat-sharing patches installed")
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

local function onClientCommand(module, command, player, arguments)
    if module ~= NETWORK_MODULE or not player then return end

    if command == COMMAND_TRANSFER_REQUEST then
        local requestID = arguments and tonumber(arguments.requestID) or -1
        local ok, success, reason = pcall(processCapacityTransfer, player, arguments)
        if not ok then
            reason = tostring(success)
            success = false
        end
        if sendServerCommand then
            sendServerCommand(player, NETWORK_MODULE, COMMAND_TRANSFER_RESULT, {
                requestID = requestID,
                success = success == true,
                reason = reason,
            })
        end
        if not success then
            print("[RemoveLimits] Server rejected capacity transfer: " .. tostring(reason))
        else
            print("[RemoveLimits] Server completed capacity transfer request " .. tostring(requestID))
        end
        return
    end

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

local function announceCharacterReady(player)
    if isClient and isClient() and sendClientCommand then
        -- No capacity number is sent by the client. The server always reads
        -- its own sandbox configuration, so clients cannot grant themselves
        -- a larger limit.
        -- Build 42 may discard an empty custom-command argument table during
        -- the connection boundary. The online ID is identity only; the server
        -- still chooses the capacity entirely from its own SandboxVars.
        sendClientCommand(player, NETWORK_MODULE, COMMAND_CHARACTER_READY, {
            onlineID = playerOnlineID(player),
        })
    end
end

local function onReadyPlayerUpdate(player)
    if not player or not pendingReadyPlayers[player] then return end
    pendingReadyPlayers[player] = nil
    pendingReadyPlayerCount = math.max(0, pendingReadyPlayerCount - 1)
    applyCharacterCapacity(player)
    announceCharacterReady(player)

    if pendingReadyPlayerCount == 0 and readyPlayerUpdateRegistered and Events.OnPlayerUpdate then
        Events.OnPlayerUpdate.Remove(onReadyPlayerUpdate)
        readyPlayerUpdateRegistered = false
    end
end

local function scheduleCharacterReady(player)
    if not player then return end
    if not pendingReadyPlayers[player] then
        pendingReadyPlayerCount = pendingReadyPlayerCount + 1
    end
    pendingReadyPlayers[player] = true
    if readyPlayerUpdateRegistered or not Events.OnPlayerUpdate then return end
    Events.OnPlayerUpdate.Add(onReadyPlayerUpdate)
    readyPlayerUpdateRegistered = true
end

local function onCreatePlayer(_, player)
    -- The first multiplayer character is finalized by the connection process
    -- after OnCreatePlayer. OnGameStart handles that character once. Later
    -- OnCreatePlayer calls are respawns and use one real player update.
    if isClient and isClient() then
        if clientGameStarted then scheduleCharacterReady(player) end
    else
        applyCharacterCapacity(player)
    end
end

local function onGameStart()
    if not (isClient and isClient()) then return end
    clientGameStarted = true
    local playerCount = getNumActivePlayers
        and tonumber(safeCall(getNumActivePlayers, 0)) or 0
    for playerIndex = 0, math.max(0, playerCount - 1) do
        local player = getSpecificPlayer
            and safeCall(function() return getSpecificPlayer(playerIndex) end, nil) or nil
        if player then
            applyCharacterCapacity(player)
            announceCharacterReady(player)
        end
    end
end

Events.OnGameBoot.Add(installPatch)
Events.OnGameBoot.Add(installCharacterCapacityAccessors)
Events.OnGameBoot.Add(installVehicleMassPatch)
Events.OnGameBoot.Add(installFluidTransferBridge)
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(onCreatePlayer)
end
if Events.OnGameStart then
    Events.OnGameStart.Add(onGameStart)
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
RemoveLimits.shouldBypassNativeTransfer = shouldBypassNativeTransfer
RemoveLimits.usesConfiguredTransferCapacity = usesConfiguredTransferCapacity
RemoveLimits.describeTransferContainer = describeTransferContainer
RemoveLimits.networkModule = NETWORK_MODULE
RemoveLimits.capacityTransferRequestCommand = COMMAND_TRANSFER_REQUEST
RemoveLimits.capacityTransferResultCommand = COMMAND_TRANSFER_RESULT
RemoveLimits.withFluidTargetCapacityBypass = withFluidTargetCapacityBypass
RemoveLimits.notifySandboxChanged = function(player)
    if not (isClient and isClient()) or not sendClientCommand or not player then return false end
    sendClientCommand(player, NETWORK_MODULE, COMMAND_SANDBOX_CHANGED, {})
    return true
end
