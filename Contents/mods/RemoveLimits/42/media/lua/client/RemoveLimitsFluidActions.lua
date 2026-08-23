-- Build 42.20 creates the water-source context menu in native Java. That code
-- calls IsoPlayer.hasFullInventory() directly, bypassing Lua method-table
-- replacements. Correct the one affected menu entry after vanilla finishes
-- building it, and make the timed action use the same configured capacity.

require "ISUI/ISWorldObjectContextMenu"
require "TimedActions/ISTakeWaterAction"

local CREATE_MENU_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalCreateMenu"
local TAKE_WATER_VALID_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalIsValid"
local TAKE_WATER_NEW_PATCH_KEY = "RemoveCapacityAndPickUpLimits_originalNew"

local function configuredFreeCapacity(character)
    if not RemoveLimits or type(RemoveLimits.getFreeCharacterCapacity) ~= "function" then
        return nil
    end
    return RemoveLimits.getFreeCharacterCapacity(character)
end

local repairReported = false

local function repairNativeFullInventoryOptions(context, player, visited)
    local freeCapacity = configuredFreeCapacity(player)
    if freeCapacity == nil or freeCapacity <= 0 or not context or not context.options then return end
    visited = visited or {}
    if visited[context] then return end
    visited[context] = true

    local fullInventoryText = getText("ContextMenu_FullInventory")
    local repaired = 0
    for _, option in ipairs(context.options) do
        local tooltip = option and option.toolTip
        if option
            and option.notAvailable
            and tooltip
            and tooltip.description == fullInventoryText then
            option.notAvailable = false
            option.toolTip = nil
            repaired = repaired + 1
        end
    end

    -- Submenus are held in the root context's instance map. Cover them too so
    -- fuel, water and other fluid-transfer menus share the same carry limit.
    if context.instanceMap then
        for _, childContext in ipairs(context.instanceMap) do
            if childContext ~= context then
                repairNativeFullInventoryOptions(childContext, player, visited)
            end
        end
    end

    if repaired > 0 and not repairReported then
        print("[RemoveLimits] Re-enabled native transfer option blocked by physical inventory capacity")
        repairReported = true
    end
end

local function installWorldMenuPatch()
    if not ISWorldObjectContextMenu or type(ISWorldObjectContextMenu.createMenu) ~= "function" then return end
    if ISWorldObjectContextMenu[CREATE_MENU_PATCH_KEY] then return end

    local originalCreateMenu = ISWorldObjectContextMenu.createMenu
    ISWorldObjectContextMenu[CREATE_MENU_PATCH_KEY] = originalCreateMenu
    ISWorldObjectContextMenu.createMenu = function(playerNum, worldobjects, x, y, test)
        local context = originalCreateMenu(playerNum, worldobjects, x, y, test)
        if type(context) == "table" then
            local player = getSpecificPlayer(playerNum)
            repairNativeFullInventoryOptions(context, player)
        end
        return context
    end
end

local function onFillWorldObjectContextMenu(playerNum, context)
    local player = getSpecificPlayer(playerNum)
    repairNativeFullInventoryOptions(context, player)
end

local function installTakeWaterPatch()
    if not ISTakeWaterAction then return end

    if type(ISTakeWaterAction.isValid) == "function" and not ISTakeWaterAction[TAKE_WATER_VALID_PATCH_KEY] then
        local originalIsValid = ISTakeWaterAction.isValid
        ISTakeWaterAction[TAKE_WATER_VALID_PATCH_KEY] = originalIsValid
        ISTakeWaterAction.isValid = function(action)
            local freeCapacity = configuredFreeCapacity(action.character)
            if freeCapacity == nil then return originalIsValid(action) end
            if action.item and not action.item:getContainer() then return false end
            return action.waterObject:hasFluid() and freeCapacity > 0
        end
    end

    if type(ISTakeWaterAction.new) == "function" and not ISTakeWaterAction[TAKE_WATER_NEW_PATCH_KEY] then
        local originalNew = ISTakeWaterAction.new
        ISTakeWaterAction[TAKE_WATER_NEW_PATCH_KEY] = originalNew
        ISTakeWaterAction.new = function(actionType, character, item, waterObject, waterTaintedCL)
            local action = originalNew(actionType, character, item, waterObject, waterTaintedCL)
            local freeCapacity = configuredFreeCapacity(character)
            if action and item and freeCapacity ~= nil and item:getFluidContainer() then
                if item:isEquipped() or character:isEquippedClothing(item) then
                    freeCapacity = freeCapacity / ZomboidGlobals.EquippedOrWornEncumbranceMultiplier
                end
                local waterAvailable = waterObject:getFluidAmount()
                action.waterUnit = math.min(
                    math.min(action.endUsedAmount - action.startUsedAmount, waterAvailable),
                    freeCapacity
                )
                action.maxTime = action:getDuration()
            end
            return action
        end
    end
end

installWorldMenuPatch()
installTakeWaterPatch()
if Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
end
print("[RemoveLimits] Native water-fill menu and action patch installed")
