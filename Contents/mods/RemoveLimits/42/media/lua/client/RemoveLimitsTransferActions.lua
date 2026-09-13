-- Build 42 multiplayer capacity bridge.
--
-- The native ItemTransaction validator runs Java-to-Java and therefore cannot
-- see a Lua override of ItemContainer.hasRoomFor(). For transfers rejected only
-- by the physical capacity-100 ceiling, suppress the redundant native lock.
-- One request asks the server to locate, revalidate and move the canonical
-- item, then its result completes the waiting animation. No item weight or
-- persistent container field is changed.

require "TimedActions/ISInventoryTransferAction"

local PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalTransferMethods"
local unpackValues = table.unpack or unpack
local pendingRequests = {}
local nextRequestID = 0

local function bypassesNativeTransaction(action, item)
    if not action or not RemoveLimits or type(RemoveLimits.shouldBypassNativeTransfer) ~= "function" then
        return false
    end
    return RemoveLimits.shouldBypassNativeTransfer(
        action.character,
        item or action.item,
        action.srcContainer,
        action.destContainer
    ) == true
end

local function usesConfiguredCapacity(action)
    return action and RemoveLimits
        and type(RemoveLimits.usesConfiguredTransferCapacity) == "function"
        and RemoveLimits.usesConfiguredTransferCapacity(action.destContainer) == true
end

local function withTemporaryGlobals(replacements, callback)
    local originals = {}
    for name, replacement in pairs(replacements) do
        originals[#originals + 1] = { name = name, value = _G[name] }
        _G[name] = replacement
    end
    local results = { pcall(callback) }
    for _, original in ipairs(originals) do
        _G[original.name] = original.value
    end
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return unpackValues(results)
end

local function installTransferActionBridge()
    if not ISInventoryTransferAction or ISInventoryTransferAction[PATCH_KEY] then return end
    if type(ISInventoryTransferAction.isValid) ~= "function"
        or type(ISInventoryTransferAction.start) ~= "function"
        or type(ISInventoryTransferAction.update) ~= "function"
        or type(ISInventoryTransferAction.perform) ~= "function"
        or type(ISInventoryTransferAction.stop) ~= "function"
        or type(ISInventoryTransferAction.canMergeAction) ~= "function" then return end

    local originals = {
        isValid = ISInventoryTransferAction.isValid,
        start = ISInventoryTransferAction.start,
        update = ISInventoryTransferAction.update,
        perform = ISInventoryTransferAction.perform,
        stop = ISInventoryTransferAction.stop,
        canMergeAction = ISInventoryTransferAction.canMergeAction,
    }
    ISInventoryTransferAction[PATCH_KEY] = originals

    ISInventoryTransferAction.isValid = function(action)
        if originals.isValid(action) then return true end
        if not isClient() or not bypassesNativeTransaction(action, action.item) then return false end

        -- Run the complete native validity check again, changing only the
        -- Java transaction-capacity answer. Trading, safehouse, crafting,
        -- vehicle-seat and all other vanilla restrictions remain authoritative.
        return withTemporaryGlobals({
            isItemTransactionConsistent = function() return true end,
        }, function()
            return originals.isValid(action)
        end)
    end

    ISInventoryTransferAction.canMergeAction = function(action, other)
        if not originals.canMergeAction(action, other) then return false end
        -- A merged native transaction is chosen before earlier queued items
        -- fill the destination. Keep configured transfers single-item so each
        -- action rechecks the real weight when it starts and switches to the
        -- authoritative bridge exactly when the physical limit is crossed.
        if usesConfiguredCapacity(action) or usesConfiguredCapacity(other) then return false end
        return true
    end

    ISInventoryTransferAction.start = function(action)
        action.RemoveLimitsBypassTransaction = isClient() and bypassesNativeTransaction(action, action.item)
        if not action.RemoveLimitsBypassTransaction then return originals.start(action) end

        local result = withTemporaryGlobals({
            createItemTransaction = function() return 0 end,
        }, function()
            return originals.start(action)
        end)
        nextRequestID = nextRequestID + 1
        if nextRequestID > 2147483646 then nextRequestID = 1 end
        action.RemoveLimitsRequestID = nextRequestID
        pendingRequests[nextRequestID] = action

        local source = RemoveLimits.describeTransferContainer(action.srcContainer, action.character, action.item)
        local destination = RemoveLimits.describeTransferContainer(action.destContainer, action.character, action.item)
        local itemID = action.item and action.item:getID() or nil
        if not source or not destination or not itemID or not sendClientCommand then
            pendingRequests[nextRequestID] = nil
            action:forceStop()
            return result
        end
        sendClientCommand(action.character, RemoveLimits.networkModule,
            RemoveLimits.capacityTransferRequestCommand, {
                requestID = nextRequestID,
                itemID = itemID,
                source = source,
                destination = destination,
            })
        return result
    end

    ISInventoryTransferAction.update = function(action)
        if not action.RemoveLimitsBypassTransaction then return originals.update(action) end
        return withTemporaryGlobals({
            isItemTransactionDone = function() return false end,
            isItemTransactionRejected = function() return false end,
            getItemTransactionDuration = function() return 0 end,
        }, function()
            return originals.update(action)
        end)
    end

    ISInventoryTransferAction.perform = function(action)
        if not action.RemoveLimitsBypassTransaction then return originals.perform(action) end
        if action.RemoveLimitsRequestID then pendingRequests[action.RemoveLimitsRequestID] = nil end
        return withTemporaryGlobals({
            removeItemTransaction = function() end,
        }, function()
            return originals.perform(action)
        end)
    end

    ISInventoryTransferAction.stop = function(action)
        if not action.RemoveLimitsBypassTransaction then return originals.stop(action) end
        if action.RemoveLimitsRequestID then pendingRequests[action.RemoveLimitsRequestID] = nil end
        return withTemporaryGlobals({
            removeItemTransaction = function() end,
        }, function()
            return originals.stop(action)
        end)
    end

    print("[RemoveLimits] Multiplayer authoritative transfer bridge installed")
end

installTransferActionBridge()

local function onCapacityTransferResult(module, command, arguments)
    if not RemoveLimits or module ~= RemoveLimits.networkModule
        or command ~= RemoveLimits.capacityTransferResultCommand then return end
    local requestID = arguments and tonumber(arguments.requestID) or nil
    local action = requestID and pendingRequests[requestID] or nil
    if not action then return end
    pendingRequests[requestID] = nil
    if arguments.success == true then
        print("[RemoveLimits] Capacity transfer completed: " .. tostring(requestID))
        action:forceComplete()
    else
        print("[RemoveLimits] Capacity transfer rejected: " .. tostring(requestID)
            .. " (" .. tostring(arguments.reason) .. ")")
        action:forceStop()
    end
end

if Events.OnServerCommand then Events.OnServerCommand.Add(onCapacityTransferResult) end
