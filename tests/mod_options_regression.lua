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
        local options = { id = id, name = name, controls = {} }
        function options:addDescription() end
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
function isClient() return false end
function isAdmin() return true end

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

MainOptions:toUI()
assert(originalToUICalls == 1, "original MainOptions.toUI must be called exactly once")
assert(createdOptions.controls.CharacterMode:getValue() == 2)
assert(createdOptions.controls.CharacterCapacityLimit:getValue() == "250")
assert(createdOptions.controls.ContainerMode:getValue() == 2)
assert(createdOptions.controls.ContainerMultiplier:getValue() == "4")
assert(createdOptions.controls.AffectBags:getValue() == false)
assert(createdOptions.controls.AffectWorldContainers:getValue() == true)
assert(createdOptions.controls.AffectVehicles:getValue() == false)
assert(createdOptions.controls.IgnoreVehicleCargoMass:getValue() == true)

createdOptions.controls.CharacterCapacityLimit:setValue("500")
createdOptions.controls.ContainerMultiplier:setValue("3")
createdOptions.controls.AffectBags:setValue(true)
createdOptions:apply()
assert(sandbox["RemoveLimits.CharacterCapacityLimit"] == 500)
assert(sandbox["RemoveLimits.ContainerMultiplier"] == 3)
assert(sandbox["RemoveLimits.AffectBags"] == true)
assert(sandboxObject.toLuaCalls == 1, "single-player apply must call SandboxOptions:toLua once")

for _, callback in ipairs(gameStartHandlers) do callback() end
assert(MainOptions.RemoveLimits_originalToUI, "game start must keep the hook idempotent")

print("mod options regression: PASS")
print("OnTick registrations: 0")
print("open-time sandbox sync: PASS")
print("apply-time sandbox write: PASS")
