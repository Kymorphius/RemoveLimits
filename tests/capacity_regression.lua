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
local vanillaHasRoomCalls = 0

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

player = setmetatable({ rawMaxWeight = 8, kind = "player" }, { __index = characterMethods })
npc = setmetatable({ rawMaxWeight = 12, kind = "npc" }, { __index = characterMethods })
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
assert(player.rawMaxWeight == 8, "player maxWeight field must remain untouched")
assert(npc:getMaxWeight() == 12, "NPC maxWeight must remain vanilla")
assert(inventory.rawCapacity == 100, "unlimited physical player capacity must be 100")
assert(containerMethods.hasRoomFor(inventory, player, item), "unlimited player transfer must be allowed")
assert(vanillaHasRoomCalls == 0, "unlimited success path must not call vanilla hasRoomFor")

local writesAfterInitialization = physicalWrites
for iteration = 1, 1000 do
    containerMethods.setCapacity(inventory, player:getMaxWeight() * 1.5)
    containerMethods.setCapacity(inventory, iteration % 2 == 0 and 100 or 50)
end
assert(overLimitWrites == 0, "no physical write may exceed Build 42's limit")
assert(physicalWrites == writesAfterInitialization, "external capacity mods must not cause repeated writes")
assert(maxWeightFieldWrites == 0, "configured display must not write the maxWeight field")

SandboxVars.RemoveLimits.CharacterMode = 2
SandboxVars.RemoveLimits.CharacterCapacityLimit = 30
for _, callback in ipairs(createHandlers) do callback(0, player) end
assert(player:getMaxWeight() == 30, "custom player display capacity")
assert(inventory.rawCapacity == 30, "custom physical capacity below 100")
inventory.currentWeight = 25
assert(not containerMethods.hasRoomFor(inventory, player, item), "custom limit must reject excess weight")

SandboxVars.RemoveLimits.CharacterMode = 1
for _, callback in ipairs(createHandlers) do callback(0, player) end
assert(player:getMaxWeight() == 8, "vanilla player display capacity")
assert(inventory.rawCapacity == 50, "vanilla physical capacity restoration")
assert(not containerMethods.hasRoomFor(inventory, player, item), "vanilla mode must delegate hasRoomFor")
assert(vanillaHasRoomCalls == 1, "vanilla mode should delegate to vanilla hasRoomFor")

assert(containerMethods.hasRoomFor(npcInventory, npc, item) == false, "NPC inventory must remain vanilla")
assert(vanillaHasRoomCalls == 2, "NPC inventory must delegate to vanilla")

print("capacity regression: PASS")
print("periodic hooks: 0")
print("over-limit physical writes: " .. overLimitWrites)
print("repeated physical writes after initialization: " .. (physicalWrites - writesAfterInitialization - 2))
print("player-only accessor: PASS")
