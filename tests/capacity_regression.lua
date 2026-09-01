local source = arg[1] or "Contents/mods/RemoveLimits/42/media/lua/shared/RemoveLimits.lua"
local clientOptions = arg[2] or "Contents/mods/RemoveLimits/42/media/lua/client/RemoveLimitsModOptions.lua"
local testItemScript = arg[3] or "Contents/mods/RemoveLimits/42/media/scripts/RemoveLimits_test_item.txt"
local fluidActions = arg[4] or "Contents/mods/RemoveLimits/42/media/lua/client/RemoveLimitsFluidActions.lua"

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

assert(not readAll(source):find("Events%.OnTick"), "shared capacity logic must not register OnTick")
assert(not readAll(clientOptions):find("Events%.OnTick"), "mod-options UI must not register OnTick")
local fluidActionLogic = readAll(fluidActions)
assert(not fluidActionLogic:find("Events%.OnTick"), "fluid action compatibility must not register OnTick")
assert(fluidActionLogic:find('tooltip%.description == fullInventoryText'), "native menu repair must require the Full Inventory tooltip")
assert(fluidActionLogic:find('Events%.OnFillWorldObjectContextMenu%.Add'), "native menu repair must run after menu fill")
assert(fluidActionLogic:find('ISTakeWaterAction%.isValid = function'), "water timed action validity must use configured capacity")
assert(fluidActionLogic:find('ISTakeWaterAction%.new = function'), "water timed action amount must use configured free capacity")
assert(fluidActionLogic:find('ISTakeWaterAction%.transferFluid = function'), "water transfer must use the native fluid bridge")
local testItemDefinition = readAll(testItemScript)
assert(testItemDefinition:find("item%s+CapacityTestWeight"), "capacity test item must be defined")
assert(testItemDefinition:find("Weight%s*=%s*150"), "test item must exercise heavy-output placement directly")
assert(testItemDefinition:find("OnCreate%s*=%s*RemoveLimits%.onCreateCapacityTestWeight"), "test recipe must preserve its custom weight")
assert(testItemDefinition:find("item%s+1%s+%[Base%.RippedSheets%]"), "test recipe must consume one ripped sheet")
assert(testItemDefinition:find("item%s+1%s+RemoveLimits%.CapacityTestWeight"), "test recipe must output the capacity test item")

local bootHandlers, createHandlers, fillMenuHandlers = {}, {}, {}
local clientCommandHandlers, serverCommandHandlers = {}, {}
Events = {
    OnGameBoot = { Add = function(callback) bootHandlers[#bootHandlers + 1] = callback end },
    OnCreatePlayer = { Add = function(callback) createHandlers[#createHandlers + 1] = callback end },
    OnFillWorldObjectContextMenu = { Add = function(callback) fillMenuHandlers[#fillMenuHandlers + 1] = callback end },
    OnClientCommand = { Add = function(callback) clientCommandHandlers[#clientCommandHandlers + 1] = callback end },
    OnServerCommand = { Add = function(callback) serverCommandHandlers[#serverCommandHandlers + 1] = callback end },
}

local runtimeRole = "single"
function isClient() return runtimeRole == "client" end
function isServer() return runtimeRole == "server" end

SandboxVars = { RemoveLimits = {
    CharacterMode = 3,
    CharacterCapacityLimit = 500,
    ContainerMode = 3,
    ContainerMultiplier = 2,
    AffectBags = true,
    AffectWorldContainers = true,
    AffectVehicles = true,
    IgnoreVehicleCargoMass = true,
} }

local containerMethods, characterMethods, playerMethods = {}, {}, {}
local player, npc
local onlinePlayers = {}
local sentClientCommands, sentServerCommands = {}, {}
ItemContainer = { class = {} }
IsoGameCharacter = { class = {} }
IsoPlayer = { class = {} }
Capability = { SandboxOptions = {} }
local nativeFluidTransferCalls = 0
FluidContainer = {
    CanTransfer = function(_, target)
        local owner = target:getOwner()
        local ownerContainer = owner and owner:getContainer() or nil
        return not (ownerContainer and instanceof(ownerContainer:getParent(), "IsoPlayer"))
    end,
    Transfer = function(_, target)
        nativeFluidTransferCalls = nativeFluidTransferCalls + 1
        local owner = target:getOwner()
        assert(owner:getContainer() == nil, "native fluid transfer target must be detached during the call")
    end,
}
__classmetatables = {
    [ItemContainer.class] = { __index = containerMethods },
    [IsoGameCharacter.class] = { __index = characterMethods },
    [IsoPlayer.class] = { __index = playerMethods },
}

local overLimitWrites = 0
local physicalWrites = 0
local maxWeightFieldWrites = 0
local maxWeightBaseFieldWrites = 0
local vanillaHasRoomCalls = 0
local vanillaHasFullInventoryCalls = 0
local vanillaFreeCapacityCalls = 0

containerMethods.getCapacity = function(container) return container.rawCapacity end
containerMethods.getEffectiveCapacity = containerMethods.getCapacity
containerMethods.getMaxWeight = containerMethods.getCapacity
containerMethods.setCapacity = function(container, capacity)
    physicalWrites = physicalWrites + 1
    if capacity > 100 then
        overLimitWrites = overLimitWrites + 1
        return
    end
    container.rawCapacity = capacity
end
containerMethods.hasRoomFor = function()
    vanillaHasRoomCalls = vanillaHasRoomCalls + 1
    return false
end
containerMethods.getType = function() return "none" end
containerMethods.getVehiclePart = function() return nil end
containerMethods.getContainingItem = function() return nil end
containerMethods.getParent = function(container) return container.owner end
containerMethods.isItemAllowed = function() return true end
containerMethods.getCapacityWeight = function(container) return container.currentWeight end

characterMethods.getMaxWeight = function(character) return character.rawMaxWeight end
characterMethods.setMaxWeight = function(character, capacity)
    maxWeightFieldWrites = maxWeightFieldWrites + 1
    character.rawMaxWeight = capacity
end
characterMethods.getMaxWeightBase = function(character) return character.rawMaxWeightBase end
characterMethods.setMaxWeightBase = function(character, capacity)
    maxWeightBaseFieldWrites = maxWeightBaseFieldWrites + 1
    character.rawMaxWeightBase = capacity
end
characterMethods.hasFullInventory = function(character)
    vanillaHasFullInventoryCalls = vanillaHasFullInventoryCalls + 1
    return character:getInventory():getCapacityWeight() >= character:getInventory():getCapacity()
end
characterMethods.getFreeInventoryCapacity = function(character)
    vanillaFreeCapacityCalls = vanillaFreeCapacityCalls + 1
    return math.max(0, character:getInventory():getCapacity() - character:getInventory():getCapacityWeight())
end

-- Build 42 exposes inherited Java methods through IsoPlayer's own Lua method
-- table. A player call resolves here instead of through IsoGameCharacter.
playerMethods.getMaxWeight = characterMethods.getMaxWeight
playerMethods.setMaxWeight = characterMethods.setMaxWeight
playerMethods.getMaxWeightBase = characterMethods.getMaxWeightBase
playerMethods.setMaxWeightBase = characterMethods.setMaxWeightBase
playerMethods.hasFullInventory = characterMethods.hasFullInventory
playerMethods.getFreeInventoryCapacity = characterMethods.getFreeInventoryCapacity

local adminRole = { hasCapability = function(_, capability) return capability == Capability.SandboxOptions end }
local regularRole = { hasCapability = function() return false end }
player = setmetatable({
    rawMaxWeight = 8,
    rawMaxWeightBase = 8,
    kind = "player",
    onlineID = 101,
    role = adminRole,
}, { __index = playerMethods })
npc = setmetatable({ rawMaxWeight = 12, rawMaxWeightBase = 12, kind = "npc" }, { __index = characterMethods })
local inventory = setmetatable({ rawCapacity = 50, currentWeight = 0, owner = player }, { __index = containerMethods })
local npcInventory = setmetatable({ rawCapacity = 50, currentWeight = 0, owner = npc }, { __index = containerMethods })

function inventory:AddItem(fullType)
    local created = { fullType = fullType }
    function created:setActualWeight(weight) self.actualWeight = weight end
    function created:setWeight(weight) self.weight = weight end
    function created:setCustomWeight(custom) self.customWeight = custom end
    return created
end
function inventory:setDrawDirty(dirty) self.drawDirty = dirty end

function player:getInventory() return inventory end
function player:getVehicle() return nil end
function player:isEquippedClothing() return false end
function player:getOnlineID() return self.onlineID end
function player:getRole() return self.role end
function npc:getInventory() return npcInventory end
function npc:getVehicle() return nil end

function sendClientCommand(commandPlayer, module, command, arguments)
    sentClientCommands[#sentClientCommands + 1] = {
        player = commandPlayer,
        module = module,
        command = command,
        arguments = arguments,
    }
end

function sendServerCommand(commandPlayer, module, command, arguments)
    sentServerCommands[#sentServerCommands + 1] = {
        player = commandPlayer,
        module = module,
        command = command,
        arguments = arguments,
    }
end

function getOnlinePlayers()
    return {
        size = function() return #onlinePlayers end,
        get = function(_, index) return onlinePlayers[index + 1] end,
    }
end

function getPlayerByOnlineID(onlineID)
    if player.onlineID == onlineID then return player end
    for _, onlinePlayer in ipairs(onlinePlayers) do
        if onlinePlayer.onlineID == onlineID then return onlinePlayer end
    end
    return nil
end

function instanceof(value, className)
    if className == "IsoPlayer" then return value and value.kind == "player" end
    if className == "IsoGameCharacter" then return value and (value.kind == "player" or value.kind == "npc") end
    if className == "InventoryItem" then return value and value.kind == "item" end
    return false
end

local item = {
    getUnequippedWeight = function() return 10 end,
    getActualWeight = function() return 10 end,
}

assert(loadfile(source))()
for _, callback in ipairs(bootHandlers) do callback() end
for _, callback in ipairs(createHandlers) do callback(0, player) end

assert(player:getMaxWeight() == 10000, "unlimited player display capacity")
assert(player.rawMaxWeight == 10000, "native Heavy Load maxWeight must be configured")
assert(player.rawMaxWeightBase == 10000, "native recalculation source must be configured")
assert(maxWeightFieldWrites == 1, "maxWeight must be written once when the player enters")
assert(maxWeightBaseFieldWrites == 1, "maxWeightBase must be written once when the player enters")
assert(npc:getMaxWeight() == 12, "NPC maxWeight must remain vanilla")
assert(inventory.rawCapacity == 100, "unlimited physical player capacity must be 100")
assert(inventory:getCapacity() == 100, "raw player capacity accessor must remain at the physical limit")
assert(inventory:getEffectiveCapacity(player) == 10000,
    "generic crafted-output placement must compare against the logical player capacity")
assert(containerMethods.hasRoomFor(inventory, player, item), "unlimited player transfer must be allowed")
assert(vanillaHasRoomCalls == 0, "unlimited success path must not call vanilla hasRoomFor")

-- Build 42's native BodyDamage.UpdateStrength derives maxWeight from
-- maxWeightBase. Simulate repeated native recalculation without invoking any
-- mod callback: the configured source field remains durable and 500 is not
-- considered a Heavy Load against the resulting native maxWeight.
for _ = 1, 1000 do
    player.rawMaxWeight = player.rawMaxWeightBase
end
inventory.currentWeight = 500
assert(player.rawMaxWeight == 10000, "native recalculation must preserve configured capacity")
assert(inventory.currentWeight / player.rawMaxWeight < 1, "500 / 10000 must not trigger Heavy Load")
assert(inventory:getCapacityWeight() <= inventory:getEffectiveCapacity(player),
    "vanilla Actions.addOrDropItem must keep crafted outputs above physical capacity 100")
assert(not player:hasFullInventory(), "fluid actions must not see a full inventory above physical capacity 100")
assert(player:getFreeInventoryCapacity() == 9500, "fluid actions must see native character free capacity")
assert(vanillaHasFullInventoryCalls == 0, "configured fluid full check must bypass physical capacity 100")
assert(vanillaFreeCapacityCalls == 0, "configured fluid free-capacity check must bypass physical capacity 100")

local fluidOwner = { kind = "item", container = inventory }
function fluidOwner:getContainer() return self.container end
function fluidOwner:setContainer(container) self.container = container end
local targetFluidContainer = { getOwner = function() return fluidOwner end }
assert(FluidContainer.CanTransfer({}, targetFluidContainer),
    "central fluid bridge must bypass only the native player-full check")
assert(fluidOwner:getContainer() == inventory, "fluid bridge must restore the target item after validation")
FluidContainer.Transfer({}, targetFluidContainer, 1)
assert(nativeFluidTransferCalls == 1, "central fluid bridge must invoke the native transfer")
assert(fluidOwner:getContainer() == inventory, "fluid bridge must restore the target item after transfer")

-- Build 42 fires OnCreatePlayer on clients but not on a dedicated server.
-- Verify the one-shot ready command causes the server to apply its own
-- authoritative sandbox capacity and never accepts a capacity from the client.
runtimeRole = "client"
for _, callback in ipairs(createHandlers) do callback(0, player) end
local readyCommand = sentClientCommands[#sentClientCommands]
assert(readyCommand.module == "RemoveLimits" and readyCommand.command == "CharacterReady",
    "multiplayer client must announce character readiness once")
assert(next(readyCommand.arguments) == nil, "ready command must not contain a client-selected capacity")

local serverPlayer = setmetatable({
    rawMaxWeight = 8,
    rawMaxWeightBase = 8,
    kind = "player",
    onlineID = 201,
    role = adminRole,
}, { __index = playerMethods })
local serverInventory = setmetatable({
    rawCapacity = 50,
    currentWeight = 0,
    owner = serverPlayer,
}, { __index = containerMethods })
function serverPlayer:getInventory() return serverInventory end
function serverPlayer:getVehicle() return nil end
function serverPlayer:getOnlineID() return self.onlineID end
function serverPlayer:getRole() return self.role end

local regularPlayer = setmetatable({
    rawMaxWeight = 12,
    rawMaxWeightBase = 12,
    kind = "player",
    onlineID = 202,
    role = regularRole,
}, { __index = playerMethods })
local regularInventory = setmetatable({
    rawCapacity = 50,
    currentWeight = 0,
    owner = regularPlayer,
}, { __index = containerMethods })
function regularPlayer:getInventory() return regularInventory end
function regularPlayer:getVehicle() return nil end
function regularPlayer:getOnlineID() return self.onlineID end
function regularPlayer:getRole() return self.role end

runtimeRole = "server"
for _, callback in ipairs(clientCommandHandlers) do
    callback("RemoveLimits", "CharacterReady", serverPlayer, {})
end
assert(serverPlayer.rawMaxWeight == 10000 and serverPlayer.rawMaxWeightBase == 10000,
    "dedicated server must apply authoritative capacity after the ready handshake")
assert(serverInventory.rawCapacity == 100, "server physical player inventory must remain capped at 100")
serverInventory.currentWeight = 500
assert(serverInventory:getEffectiveCapacity(serverPlayer) == 10000,
    "server transfer logic must expose the authoritative unlimited capacity")
assert(serverInventory:hasRoomFor(serverPlayer, item),
    "server must allow an item transfer after physical inventory weight exceeds 100")
local serverReply = sentServerCommands[#sentServerCommands]
assert(serverReply.command == "ApplyCharacterCapacity" and serverReply.arguments.onlineID == 201,
    "server must tell the matching client to refresh its local character")

onlinePlayers = { serverPlayer, regularPlayer }
SandboxVars.RemoveLimits.CharacterMode = 2
SandboxVars.RemoveLimits.CharacterCapacityLimit = 500
for _, callback in ipairs(clientCommandHandlers) do
    callback("RemoveLimits", "SandboxChanged", serverPlayer, {})
end
assert(serverPlayer.rawMaxWeight == 500 and regularPlayer.rawMaxWeight == 500,
    "authorized sandbox update must refresh every online server player once")
serverInventory.currentWeight = 495
assert(not serverInventory:hasRoomFor(serverPlayer, item),
    "server custom capacity must reject a transfer that exceeds the authoritative limit")

SandboxVars.RemoveLimits.CharacterCapacityLimit = 300
for _, callback in ipairs(clientCommandHandlers) do
    callback("RemoveLimits", "SandboxChanged", regularPlayer, {})
end
assert(serverPlayer.rawMaxWeight == 500 and regularPlayer.rawMaxWeight == 500,
    "player without SandboxOptions capability must not trigger a capacity refresh")

for _, callback in ipairs(clientCommandHandlers) do
    callback("RemoveLimits", "SandboxChanged", serverPlayer, {})
end
assert(serverPlayer.rawMaxWeight == 300 and regularPlayer.rawMaxWeight == 300,
    "authorized live custom limit must be applied on the server")

runtimeRole = "client"
player.rawMaxWeight = 8
player.rawMaxWeightBase = 8
for _, callback in ipairs(serverCommandHandlers) do
    callback("RemoveLimits", "ApplyCharacterCapacity", { onlineID = 101 })
end
assert(player.rawMaxWeight == 300 and player.rawMaxWeightBase == 300,
    "server refresh command must update the matching local client character")

local primaryLocalPlayer = player
local secondaryLocalPlayer = setmetatable({
    rawMaxWeight = 9,
    rawMaxWeightBase = 9,
    kind = "player",
    onlineID = 102,
    role = regularRole,
}, { __index = playerMethods })
local secondaryLocalInventory = setmetatable({
    rawCapacity = 50,
    currentWeight = 0,
    owner = secondaryLocalPlayer,
}, { __index = containerMethods })
function secondaryLocalPlayer:getInventory() return secondaryLocalInventory end
function secondaryLocalPlayer:getVehicle() return nil end
function secondaryLocalPlayer:getOnlineID() return self.onlineID end
function getNumActivePlayers() return 2 end
function getSpecificPlayer(index)
    if index == 0 then return primaryLocalPlayer end
    if index == 1 then return secondaryLocalPlayer end
    return nil
end
getPlayerByOnlineID = nil
primaryLocalPlayer.rawMaxWeight = 250
for _, callback in ipairs(serverCommandHandlers) do
    callback("RemoveLimits", "ApplyCharacterCapacity", { onlineID = 102 })
end
assert(secondaryLocalPlayer.rawMaxWeight == 300 and primaryLocalPlayer.rawMaxWeight == 250,
    "server refresh must locate the matching split-screen player without getPlayerByOnlineID")

runtimeRole = "server"
SandboxVars.RemoveLimits.CharacterMode = 1
for _, callback in ipairs(clientCommandHandlers) do
    callback("RemoveLimits", "SandboxChanged", serverPlayer, {})
end
assert(serverPlayer.rawMaxWeight == 8 and serverInventory.rawCapacity == 50,
    "server live update must restore the original character capacity in Vanilla mode")
assert(regularPlayer.rawMaxWeight == 12 and regularInventory.rawCapacity == 50,
    "server Vanilla restore must preserve each player's own original values")

runtimeRole = "single"
onlinePlayers = {}
SandboxVars.RemoveLimits.CharacterMode = 3
for _, callback in ipairs(createHandlers) do callback(0, player) end

local writesAfterInitialization = physicalWrites
local maxWeightWritesAfterInitialization = maxWeightFieldWrites
local maxWeightBaseWritesAfterInitialization = maxWeightBaseFieldWrites
for iteration = 1, 1000 do
    containerMethods.setCapacity(inventory, player:getMaxWeight() * 1.5)
    containerMethods.setCapacity(inventory, iteration % 2 == 0 and 100 or 50)
end
assert(overLimitWrites == 0, "no physical write may exceed Build 42's limit")
assert(physicalWrites == writesAfterInitialization, "external capacity mods must not cause repeated writes")
assert(maxWeightFieldWrites == maxWeightWritesAfterInitialization, "mod must not repeat maxWeight writes")
assert(maxWeightBaseFieldWrites == maxWeightBaseWritesAfterInitialization, "mod must not repeat maxWeightBase writes")

SandboxVars.RemoveLimits.CharacterMode = 2
SandboxVars.RemoveLimits.CharacterCapacityLimit = 30
for _, callback in ipairs(createHandlers) do callback(0, player) end
assert(player:getMaxWeight() == 30, "custom player display capacity")
assert(player.rawMaxWeightBase == 30, "custom native recalculation source")
assert(inventory.rawCapacity == 30, "custom physical capacity below 100")
assert(inventory:getEffectiveCapacity(player) == 30, "custom crafted-output limit")
player.rawMaxWeight = 52 -- another carry mod may raise the native result
inventory.currentWeight = 25
assert(not containerMethods.hasRoomFor(inventory, player, item), "custom limit must reject excess weight")
assert(not player:hasFullInventory(), "custom fluid action must remain valid below the real limit")
assert(player:getFreeInventoryCapacity() == 5, "custom fluid action free capacity")
inventory.currentWeight = 30
assert(player:hasFullInventory(), "custom fluid action must stop at the real limit")

SandboxVars.RemoveLimits.CharacterMode = 1
for _, callback in ipairs(createHandlers) do callback(0, player) end
assert(player:getMaxWeight() == 8, "vanilla player display capacity")
assert(player.rawMaxWeightBase == 8, "vanilla maxWeightBase restoration")
assert(inventory.rawCapacity == 50, "vanilla physical capacity restoration")
assert(inventory:getEffectiveCapacity(player) == 50, "vanilla crafted-output capacity must be restored")
assert(not containerMethods.hasRoomFor(inventory, player, item), "vanilla mode must delegate hasRoomFor")
player:hasFullInventory()
player:getFreeInventoryCapacity()
assert(vanillaHasFullInventoryCalls == 1, "vanilla mode must delegate the full-inventory check")
assert(vanillaFreeCapacityCalls == 1, "vanilla mode must delegate the free-capacity check")
assert(vanillaHasRoomCalls == 1, "vanilla mode should delegate to vanilla hasRoomFor")

assert(containerMethods.hasRoomFor(npcInventory, npc, item) == false, "NPC inventory must remain vanilla")
assert(vanillaHasRoomCalls == 2, "NPC inventory must delegate to vanilla")

local testWeight = RemoveLimits.addCapacityTestItem(175, player)
assert(testWeight.fullType == "RemoveLimits.CapacityTestWeight", "test helper must create the dedicated item")
assert(testWeight.actualWeight == 175, "test helper must accept a custom actual weight")
assert(testWeight.weight == 175, "test helper must update the displayed item weight")
assert(testWeight.customWeight == true, "test helper weight must be persisted as custom")
assert(inventory.drawDirty == true, "test helper must refresh the inventory display")

inventory.drawDirty = false
local craftedWeight = inventory:AddItem("RemoveLimits.CapacityTestWeight")
local createdItems = {
    size = function() return 1 end,
    get = function(_, index) if index == 0 then return craftedWeight end end,
}
local craftRecipeData = {
    getAllCreatedItems = function() return createdItems end,
}
RemoveLimits.onCreateCapacityTestWeight(craftRecipeData, player)
assert(craftedWeight.actualWeight == 150, "crafted test item must gain weight after inventory placement")
assert(craftedWeight.weight == 150, "crafted test item must display weight 150")
assert(craftedWeight.customWeight == true, "crafted test item weight must persist")
assert(inventory.drawDirty == true, "crafted test item must refresh the inventory display")

-- Build 42.20's native Java menu bypasses Lua method tables and marks the
-- top-level Fill option unavailable before returning to Lua. Simulate that
-- exact result and verify the client compatibility layer repairs only it.
SandboxVars.RemoveLimits.CharacterMode = 3
inventory.currentWeight = 150
for _, callback in ipairs(createHandlers) do callback(0, player) end
local fullTooltip = { description = "Inventory is full" }
local fillOption = { name = "Fill", notAvailable = true, toolTip = fullTooltip }
local unrelatedOption = { name = "Unrelated", notAvailable = true, toolTip = { description = "Another reason" } }
local testFluidContainer = {
    isFull = function() return false end,
    canAddFluid = function() return true end,
}
local fillableItem = {
    getFluidContainer = function() return testFluidContainer end,
    getName = function() return "Test bottle" end,
}
local fluidCandidates = {
    isEmpty = function() return false end,
    size = function() return 1 end,
    get = function(_, index) if index == 0 then return fillableItem end end,
}
inventory.getAllEvalRecurse = function(_, predicate)
    assert(predicate(fillableItem), "test fluid item must satisfy the native water-container predicate")
    return fluidCandidates
end
local waterSource = {
    canTransferFluidTo = function(_, fluidContainer) return fluidContainer == testFluidContainer end,
}
local createdSubmenu
local nativeContext = { options = { fillOption, unrelatedOption } }
function nativeContext:getNew()
    createdSubmenu = { options = {} }
    function createdSubmenu:addGetUpOption(name, target, onSelect, ...)
        local option = { name = name, target = target, onSelect = onSelect, params = { ... } }
        self.options[#self.options + 1] = option
        return option
    end
    return createdSubmenu
end
function nativeContext:addSubMenu(option, submenu) option.subOption = submenu end
ISWorldObjectContextMenu = {
    createMenu = function() return nativeContext end,
    fetchVars = { storeWater = { waterSource } },
    onTakeWater = function() end,
}
ISTakeWaterAction = {
    isValid = function() return false end,
    new = function(_, character, waterItem, waterObject)
        return {
            character = character,
            item = waterItem,
            waterObject = waterObject,
            startUsedAmount = 1,
            endUsedAmount = 10,
            waterUnit = 0,
            getDuration = function() return 42 end,
        }
    end,
}
local testWaterItem = {
    getContainer = function() return inventory end,
    getFluidContainer = function() return {} end,
    isEquipped = function() return false end,
}
local testWaterObject = {
    hasFluid = function() return true end,
    getFluidAmount = function() return 20 end,
}
local originalRequire = require
require = function() end
getSpecificPlayer = function() return player end
getText = function(key)
    if key == "ContextMenu_Fill" then return "Fill" end
    if key == "ContextMenu_FullInventory" then return "Inventory is full" end
    return key
end
ZomboidGlobals = { EquippedOrWornEncumbranceMultiplier = 0.3 }
Fluid = { Water = {} }
assert(loadfile(fluidActions))()
require = originalRequire

ISWorldObjectContextMenu.createMenu(0, {}, 0, 0, false)
assert(fillOption.notAvailable == false, "native water Fill option must be enabled at configured capacity")
assert(fillOption.toolTip == nil, "stale native Full Inventory tooltip must be removed")
assert(fillOption.subOption == createdSubmenu, "native water Fill option must receive a real submenu")
assert(#createdSubmenu.options == 1, "native water Fill submenu must contain the compatible bottle")
assert(createdSubmenu.options[1].onSelect == ISWorldObjectContextMenu.onTakeWater,
    "native water Fill submenu must call vanilla onTakeWater")
assert(unrelatedOption.notAvailable == true, "option disabled for another reason must remain untouched")
fillOption.notAvailable = true
fillOption.toolTip = fullTooltip
for _, callback in ipairs(fillMenuHandlers) do callback(0, nativeContext, {}, false) end
assert(fillOption.notAvailable == false, "post-fill event must repair the native menu even if createMenu is replaced")
assert(ISTakeWaterAction.isValid({ character = player, item = testWaterItem, waterObject = testWaterObject }),
    "water action must remain valid above physical capacity 100")
local takeWaterAction = ISTakeWaterAction:new(player, testWaterItem, testWaterObject, false)
assert(takeWaterAction.waterUnit == 9, "water action amount must use configured free capacity")
assert(takeWaterAction.maxTime == 42, "water action duration must be refreshed")

print("capacity regression: PASS")
print("periodic hooks: 0")
print("over-limit physical writes: " .. overLimitWrites)
print("repeated physical writes during stress loop: 0")
print("native Heavy Load ratio at 500 / 10000: PASS")
print("persistent maxWeightBase without polling: PASS")
print("fluid/fuel actions above physical capacity 100: PASS")
print("custom capacity test item at weight 175: PASS")
print("generic crafted-output placement above physical capacity 100: PASS")
print("crafted test item direct weight 150: PASS")
print("native Java water menu bypass compatibility: PASS")
print("dedicated-server character-ready handshake: PASS")
print("server-authoritative transfer above physical capacity 100: PASS")
print("authorized multiplayer sandbox hot refresh: PASS")
print("unauthorized multiplayer refresh rejected: PASS")
