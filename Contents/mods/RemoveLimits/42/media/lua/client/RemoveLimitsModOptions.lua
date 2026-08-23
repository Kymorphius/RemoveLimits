require "PZAPI/ModOptions"

-- Mirrors the Build 42 sandbox options in the game's built-in Mod Options page.
-- The sandbox remains authoritative so multiplayer clients cannot keep a
-- private capacity configuration that disagrees with the server.

local MOD_OPTIONS_ID = "RemoveLimits"
local SANDBOX_PREFIX = "RemoveLimits."
local MAIN_OPTIONS_TO_UI_PATCH_KEY = "RemoveLimits_originalToUI"

if PZAPI.ModOptions:getOptions(MOD_OPTIONS_ID) then return end

local options = PZAPI.ModOptions:create(MOD_OPTIONS_ID, "UI_RemoveLimits_Name")
options:addDescription("UI_RemoveLimits_SyncDescription")

local characterMode = options:addComboBox("CharacterMode", "UI_RemoveLimits_CharacterMode", "UI_RemoveLimits_CharacterMode_Tooltip")
characterMode:addItem("UI_RemoveLimits_Mode_Vanilla", false)
characterMode:addItem("UI_RemoveLimits_Mode_Custom", false)
characterMode:addItem("UI_RemoveLimits_Mode_Unlimited", true)

local characterLimit = options:addTextEntry("CharacterCapacityLimit", "UI_RemoveLimits_CharacterCapacityLimit", "100", "UI_RemoveLimits_CharacterCapacityLimit_Tooltip")

options:addSeparator()

local containerMode = options:addComboBox("ContainerMode", "UI_RemoveLimits_ContainerMode", "UI_RemoveLimits_ContainerMode_Tooltip")
containerMode:addItem("UI_RemoveLimits_Mode_Vanilla", false)
containerMode:addItem("UI_RemoveLimits_Mode_Multiplier", false)
containerMode:addItem("UI_RemoveLimits_Mode_Unlimited", true)

local containerMultiplier = options:addTextEntry("ContainerMultiplier", "UI_RemoveLimits_ContainerMultiplier", "2", "UI_RemoveLimits_ContainerMultiplier_Tooltip")
local affectBags = options:addTickBox("AffectBags", "UI_RemoveLimits_AffectBags", true, "UI_RemoveLimits_AffectBags_Tooltip")
local affectWorldContainers = options:addTickBox("AffectWorldContainers", "UI_RemoveLimits_AffectWorldContainers", true, "UI_RemoveLimits_AffectWorldContainers_Tooltip")
local affectVehicles = options:addTickBox("AffectVehicles", "UI_RemoveLimits_AffectVehicles", true, "UI_RemoveLimits_AffectVehicles_Tooltip")
local ignoreVehicleCargoMass = options:addTickBox("IgnoreVehicleCargoMass", "UI_RemoveLimits_IgnoreVehicleCargoMass", true, "UI_RemoveLimits_IgnoreVehicleCargoMass_Tooltip")

local editableOptions = {
    characterMode,
    characterLimit,
    containerMode,
    containerMultiplier,
    affectBags,
    affectWorldContainers,
    affectVehicles,
    ignoreVehicleCargoMass,
}

local function clampNumber(value, minimum, maximum, fallback, integer)
    value = tonumber(value) or fallback
    value = math.max(minimum, math.min(maximum, value))
    if integer then value = math.floor(value) end
    return value
end

local function sandboxValue(name, fallback)
    local sandbox = getSandboxOptions and getSandboxOptions()
    local option = sandbox and sandbox:getOptionByName(SANDBOX_PREFIX .. name)
    if option then return option:getValue() end
    local values = SandboxVars and SandboxVars.RemoveLimits
    if values and values[name] ~= nil then return values[name] end
    return fallback
end

local function canEditSandbox()
    return not isClient() or isAdmin()
end

local function setEditable(editable)
    for _, option in ipairs(editableOptions) do
        option:setEnabled(editable)
    end
end

local function pullFromSandbox()
    characterMode:setValue(clampNumber(sandboxValue("CharacterMode", 3), 1, 3, 3, true))
    characterLimit:setValue(tostring(clampNumber(sandboxValue("CharacterCapacityLimit", 100), 1, 10000, 100, true)))
    containerMode:setValue(clampNumber(sandboxValue("ContainerMode", 3), 1, 3, 3, true))
    containerMultiplier:setValue(tostring(clampNumber(sandboxValue("ContainerMultiplier", 2), 1, 100, 2, false)))
    affectBags:setValue(sandboxValue("AffectBags", true) ~= false)
    affectWorldContainers:setValue(sandboxValue("AffectWorldContainers", true) ~= false)
    affectVehicles:setValue(sandboxValue("AffectVehicles", true) ~= false)
    ignoreVehicleCargoMass:setValue(sandboxValue("IgnoreVehicleCargoMass", true) ~= false)
    setEditable(canEditSandbox())
end

local function collectedValues()
    return {
        CharacterMode = clampNumber(characterMode:getValue(), 1, 3, 3, true),
        CharacterCapacityLimit = clampNumber(characterLimit:getValue(), 1, 10000, 100, true),
        ContainerMode = clampNumber(containerMode:getValue(), 1, 3, 3, true),
        ContainerMultiplier = clampNumber(containerMultiplier:getValue(), 1, 100, 2, false),
        AffectBags = affectBags:getValue() == true,
        AffectWorldContainers = affectWorldContainers:getValue() == true,
        AffectVehicles = affectVehicles:getValue() == true,
        IgnoreVehicleCargoMass = ignoreVehicleCargoMass:getValue() == true,
    }
end

local function normalizeUI(values)
    characterMode:setValue(values.CharacterMode)
    characterLimit:setValue(tostring(values.CharacterCapacityLimit))
    containerMode:setValue(values.ContainerMode)
    containerMultiplier:setValue(tostring(values.ContainerMultiplier))
    affectBags:setValue(values.AffectBags)
    affectWorldContainers:setValue(values.AffectWorldContainers)
    affectVehicles:setValue(values.AffectVehicles)
    ignoreVehicleCargoMass:setValue(values.IgnoreVehicleCargoMass)
end

function options:apply()
    if not canEditSandbox() then
        pullFromSandbox()
        return
    end

    local values = collectedValues()
    normalizeUI(values)

    local target = getSandboxOptions()
    if isClient() then
        target = SandboxOptions.new()
        target:copyValuesFrom(getSandboxOptions())
    end
    for name, value in pairs(values) do
        target:set(SANDBOX_PREFIX .. name, value)
    end

    if isClient() then
        target:sendToServer()
    else
        target:toLua()
        local player = getPlayer and getPlayer()
        if player and RemoveLimits and RemoveLimits.applyCharacterCapacity then
            RemoveLimits.applyCharacterCapacity(player)
        end
    end
end

local function installMainOptionsHook()
    if not MainOptions or type(MainOptions.toUI) ~= "function" then return end
    if MainOptions[MAIN_OPTIONS_TO_UI_PATCH_KEY] then return end

    local originalToUI = MainOptions.toUI
    MainOptions[MAIN_OPTIONS_TO_UI_PATCH_KEY] = originalToUI
    MainOptions.toUI = function(mainOptions, ...)
        pullFromSandbox()
        return originalToUI(mainOptions, ...)
    end
end

local function initializeModOptions()
    pullFromSandbox()
    installMainOptionsHook()
end

installMainOptionsHook()
Events.OnGameStart.Add(initializeModOptions)
