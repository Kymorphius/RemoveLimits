local source = arg[1] or "Contents/mods/RemoveLimits/42/media/lua/shared/RemoveLimits.lua"
local clientOptions = arg[2] or "Contents/mods/RemoveLimits/42/media/lua/client/RemoveLimitsModOptions.lua"

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

assert(not readAll(source):find("Events%.OnTick"), "shared capacity logic must not register OnTick")
assert(not readAll(clientOptions):find("Events%.OnTick"), "mod-options UI must not register OnTick")

local bootHandlers, createHandlers = {}, {}
Events = {
    OnGameBoot = { Add = function(callback) bootHandlers[#bootHandlers + 1] = callback end },
    OnCreatePlayer = { Add = function(callback) createHandlers[#createHandlers + 1] = callback end },
}

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

local containerMethods, characterMethods = {}, {}
local player, npc
ItemContainer = { class = {} }
IsoGameCharacter = { class = {} }
__classmetatables = {
    [ItemContainer.class] = { __index = containerMethods },
    [IsoGameCharacter.class] = { __index = characterMethods },
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

player = setmetatable({ rawMaxWeight = 8, rawMaxWeightBase = 8, kind = "player" }, { __index = characterMethods })
npc = setmetatable({ rawMaxWeight = 12, rawMaxWeightBase = 12, kind = "npc" }, { __index = characterMethods })
local inventory = setmetatable({ rawCapacity = 50, currentWeight = 0, owner = player }, { __index = containerMethods })
local npcInventory = setmetatable({ rawCapacity = 50, currentWeight = 0, owner = npc }, { __index = containerMethods })

function player:getInventory() return inventory end
function player:getVehicle() return nil end
function npc:getInventory() return npcInventory end
function npc:getVehicle() return nil end

function instanceof(value, className)
    if className == "IsoPlayer" then return value and value.kind == "player" end
    if className == "IsoGameCharacter" then return value and (value.kind == "player" or value.kind == "npc") end
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
assert(not player:hasFullInventory(), "fluid actions must not see a full inventory above physical capacity 100")
assert(player:getFreeInventoryCapacity() == 9500, "fluid actions must see native character free capacity")
assert(vanillaHasFullInventoryCalls == 0, "configured fluid full check must bypass physical capacity 100")
assert(vanillaFreeCapacityCalls == 0, "configured fluid free-capacity check must bypass physical capacity 100")

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
assert(not containerMethods.hasRoomFor(inventory, player, item), "vanilla mode must delegate hasRoomFor")
player:hasFullInventory()
player:getFreeInventoryCapacity()
assert(vanillaHasFullInventoryCalls == 1, "vanilla mode must delegate the full-inventory check")
assert(vanillaFreeCapacityCalls == 1, "vanilla mode must delegate the free-capacity check")
assert(vanillaHasRoomCalls == 1, "vanilla mode should delegate to vanilla hasRoomFor")

assert(containerMethods.hasRoomFor(npcInventory, npc, item) == false, "NPC inventory must remain vanilla")
assert(vanillaHasRoomCalls == 2, "NPC inventory must delegate to vanilla")

print("capacity regression: PASS")
print("periodic hooks: 0")
print("over-limit physical writes: " .. overLimitWrites)
print("repeated physical writes after initialization: " .. (physicalWrites - writesAfterInitialization - 2))
print("native Heavy Load ratio at 500 / 10000: PASS")
print("persistent maxWeightBase without polling: PASS")
print("fluid/fuel actions above physical capacity 100: PASS")
