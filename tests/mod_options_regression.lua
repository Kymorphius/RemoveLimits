local source = arg[1] or "Contents/mods/RemoveLimits/42/media/lua/client/RemoveLimitsModOptions.lua"

package.preload["PZAPI/ModOptions"] = function() end

local createdOptions
local function control(defaultValue)
    return {
        value = defaultValue,
        getValue = function(self) return self.value end,
        setValue = function(self, value) self.value = value end,
        setEnabled = function(self, enabled) self.enabled = enabled end,
        addItem = function() end,
    }
end

PZAPI = { ModOptions = {
    getOptions = function() return nil end,
    create = function(_, id, name)
        local options = { id = id, name = name, controls = {}, descriptions = {} }
        function options:addDescription(key)
            self.descriptions[#self.descriptions + 1] = key
        end
        function options:addSeparator() end
        function options:addComboBox(id)
            local value = control(1)
            self.controls[id] = value
            return value
        end
        function options:addTextEntry(id, _, defaultValue)
            local value = control(defaultValue)
            self.controls[id] = value
            return value
        end
        function options:addTickBox(id, _, defaultValue)
            local value = control(defaultValue)
            self.controls[id] = value
            return value
        end
        createdOptions = options
        return options
    end,
} }

local sandbox = {
    ["RemoveLimits.CharacterMode"] = 2,
    ["RemoveLimits.CharacterCapacityLimit"] = 250,
    ["RemoveLimits.ContainerMode"] = 2,
    ["RemoveLimits.ContainerMultiplier"] = 4,
    ["RemoveLimits.AffectBags"] = false,
    ["RemoveLimits.AffectWorldContainers"] = true,
    ["RemoveLimits.AffectVehicles"] = false,
    ["RemoveLimits.IgnoreVehicleCargoMass"] = true,
}
local sandboxObject = {
    getOptionByName = function(_, name)
        if sandbox[name] == nil then return nil end
        return { getValue = function() return sandbox[name] end }
    end,
    set = function(_, name, value) sandbox[name] = value end,
    toLua = function(self) self.toLuaCalls = (self.toLuaCalls or 0) + 1 end,
}

function getSandboxOptions() return sandboxObject end
local clientMode = false
function isClient() return clientMode end
function isAdmin() return true end

Capability = { SandboxOptions = {} }
local sandboxRole = {
    hasCapability = function(_, capability)
        return capability == Capability.SandboxOptions
    end,
}
local localPlayer = {
    id = 1,
    getRole = function() return sandboxRole end,
}
function getPlayer() return localPlayer end

local sandboxChangeNotifications = 0
RemoveLimits = {
    notifySandboxChanged = function(notifyPlayer)
        assert(notifyPlayer == localPlayer, "sandbox refresh must identify the local admin player")
        sandboxChangeNotifications = sandboxChangeNotifications + 1
        return true
    end,
}

local sentSandboxValues
SandboxOptions = {
    new = function()
        local values = {}
        return {
            copyValuesFrom = function()
                for name, value in pairs(sandbox) do values[name] = value end
            end,
            set = function(_, name, value) values[name] = value end,
            sendToServer = function()
                sentSandboxValues = values
            end,
        }
    end,
}

local nativeAdminApplyCalls = 0
ISServerSandboxOptionsUI = {
    onButtonApply = function()
        nativeAdminApplyCalls = nativeAdminApplyCalls + 1
    end,
}

local originalToUICalls = 0
MainOptions = {
    toUI = function()
        originalToUICalls = originalToUICalls + 1
    end,
}

local gameStartHandlers = {}
Events = {
    OnGameStart = { Add = function(callback) gameStartHandlers[#gameStartHandlers + 1] = callback end },
}

assert(loadfile(source))()
assert(createdOptions, "mod options were not created")
assert(MainOptions.RemoveLimits_originalToUI, "MainOptions.toUI hook was not installed")
assert(table.concat(createdOptions.descriptions, ",") == table.concat({
    "UI_RemoveLimits_SyncDescription",
    "UI_RemoveLimits_CarryWeightSection",
    "UI_RemoveLimits_TransferWeightSection",
    "UI_RemoveLimits_VehicleSeatSection",
    "UI_RemoveLimits_VehicleMassSection",
}, ","), "vehicle-seat controls must have an independent section")

MainOptions:toUI()
assert(originalToUICalls == 1, "original MainOptions.toUI must be called exactly once")
assert(createdOptions.controls.CharacterMode:getValue() == 2)
assert(createdOptions.controls.CharacterCapacityLimit:getValue() == "250")
assert(createdOptions.controls.ContainerMode:getValue() == 2)
assert(createdOptions.controls.ContainerMultiplier:getValue() == "4")
assert(createdOptions.controls.AffectBags:getValue() == false)
assert(createdOptions.controls.AffectWorldContainers:getValue() == true)
assert(createdOptions.controls.AffectVehicles:getValue() == false)
assert(createdOptions.controls.AllowSeatWithItems:getValue() == true)
assert(createdOptions.controls.IgnoreVehicleCargoMass:getValue() == true)

createdOptions.controls.CharacterCapacityLimit:setValue("500")
createdOptions.controls.ContainerMultiplier:setValue("3")
createdOptions.controls.AffectBags:setValue(true)
createdOptions.controls.AllowSeatWithItems:setValue(false)
createdOptions:apply()
assert(sandbox["RemoveLimits.CharacterCapacityLimit"] == 500)
assert(sandbox["RemoveLimits.ContainerMultiplier"] == 3)
assert(sandbox["RemoveLimits.AffectBags"] == true)
assert(sandbox["RemoveLimits.AllowSeatWithItems"] == false)
assert(sandboxObject.toLuaCalls == 1, "single-player apply must call SandboxOptions:toLua once")

clientMode = true
createdOptions.controls.CharacterMode:setValue(2)
createdOptions.controls.CharacterCapacityLimit:setValue("750")
createdOptions:apply()
assert(sentSandboxValues["RemoveLimits.CharacterMode"] == 2)
assert(sentSandboxValues["RemoveLimits.CharacterCapacityLimit"] == 750)
assert(sandboxChangeNotifications == 1,
    "multiplayer mod-options apply must request one authoritative server refresh")

ISServerSandboxOptionsUI:onButtonApply()
assert(nativeAdminApplyCalls == 1, "vanilla admin sandbox apply must retain its original behavior")
assert(sandboxChangeNotifications == 2,
    "vanilla Admin Sandbox Options must also request one authoritative server refresh")

for _, callback in ipairs(gameStartHandlers) do callback() end
assert(MainOptions.RemoveLimits_originalToUI, "game start must keep the hook idempotent")

print("mod options regression: PASS")
print("OnTick registrations: 0")
print("open-time sandbox sync: PASS")
print("apply-time sandbox write: PASS")
print("multiplayer authoritative sandbox refresh notification: PASS")
print("vanilla admin sandbox refresh notification: PASS")
