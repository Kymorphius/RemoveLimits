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

local function findWaterFillData(player)
    if not player or not ISWorldObjectContextMenu or not ISWorldObjectContextMenu.fetchVars then return nil, nil end
    local sources = ISWorldObjectContextMenu.fetchVars.storeWater
    if not sources then return nil, nil end

    local inventory = player:getInventory()
    if not inventory then return nil, nil end
    local candidates = inventory:getAllEvalRecurse(function(item)
        local fluidContainer = item and item:getFluidContainer()
        return fluidContainer
            and not fluidContainer:isFull()
            and fluidContainer:canAddFluid(Fluid.Water)
    end)
    if not candidates or candidates:isEmpty() then return nil, nil end

    for _, source in ipairs(sources) do
        local compatible = {}
        for index = 0, candidates:size() - 1 do
            local item = candidates:get(index)
            if source:canTransferFluidTo(item:getFluidContainer()) then
                compatible[#compatible + 1] = item
            end
        end
        if #compatible > 0 then
            table.sort(compatible, function(left, right) return left:getName() < right:getName() end)
            return source, compatible
        end
    end
    return nil, nil
end

local function buildWaterFillSubmenu(context, option, player, playerNum, worldobjects)
    if option.onSelect or option.subOption then return true end
    if option.name ~= getText("ContextMenu_Fill") then return false end

    local source, items = findWaterFillData(player)
    if not source or not items then return false end
    local submenu = context:getNew(context)
    context:addSubMenu(option, submenu)
    for _, item in ipairs(items) do
        local itemOption = submenu:addGetUpOption(
            item:getName(),
            worldobjects,
            ISWorldObjectContextMenu.onTakeWater,
            source,
            nil,
            item,
            playerNum
        )
        itemOption.itemForTexture = item
    end
    return true
end

local function repairNativeFullInventoryOptions(context, player, playerNum, worldobjects, visited)
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
            -- Native Build 42 returns immediately after creating the disabled
            -- Fill parent, leaving it without a submenu or callback. Rebuild
            -- that missing submenu before enabling it. Other actions are only
            -- enabled when vanilla already attached a real callback/submenu.
            local actionable = option.onSelect or option.subOption
                or buildWaterFillSubmenu(context, option, player, playerNum, worldobjects)
            if actionable then
                option.notAvailable = false
                option.toolTip = nil
                repaired = repaired + 1
            end
        end
    end

    -- Submenus are held in the root context's instance map. Cover them too so
    -- fuel, water and other fluid-transfer menus share the same carry limit.
    if context.instanceMap then
        for _, childContext in ipairs(context.instanceMap) do
            if childContext ~= context then
                repairNativeFullInventoryOptions(childContext, player, playerNum, worldobjects, visited)
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
            repairNativeFullInventoryOptions(context, player, playerNum, worldobjects)
        end
        return context
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects)
    local player = getSpecificPlayer(playerNum)
    repairNativeFullInventoryOptions(context, player, playerNum, worldobjects)
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
