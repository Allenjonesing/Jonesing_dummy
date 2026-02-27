-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianSpawner.lua
-- Automatically spawns Jonesing dummy pedestrians when a freeroam map loads.
-- Primary trigger: onVehicleAdded (event-driven, fires when the player vehicle
-- enters the scene).  Fallback: onUpdate polls every second.

local M = {}

local _pendingSpawn = false
local _updateTimer  = 0

local function _doSpawn()
    _pendingSpawn = false
    _updateTimer  = 0
    local ok, err = pcall(function()
        if not propRecycler then
            extensions.load("propRecycler")
        end
        log('I', 'Spawn_Ped', 'Spawning...')
        -- Use propRecycler's exported config so params stay in one place.
        local cfg = (propRecycler and propRecycler.autoSpawnCfg) or
                    {maxDistance=150, leadDistance=50, lateralJitter=10, debug=true}
        propRecycler.spawn10DummiesAndStart(cfg)
        log('I', 'Spawn_Ped', 'Spawn Complete')
    end)
    if not ok then
        log('E', 'Spawn_Ped', 'Spawn error: ' .. tostring(err))
    end
end

local function onClientStartMission()
    if scenario_scenarios and scenario_scenarios.getScenario and scenario_scenarios.getScenario() then
        _pendingSpawn = false
        return
    end
    _pendingSpawn = true
    _updateTimer  = 0
end

local function onClientEndMission()
    _pendingSpawn = false
    _updateTimer  = 0
end

-- Primary trigger: fires as soon as any vehicle is added to the scene.
-- If the player vehicle is already set at that point we spawn immediately;
-- otherwise the onUpdate fallback catches it shortly after.
local function onVehicleAdded(id)
    if not _pendingSpawn then return end
    if not (be and be:getPlayerVehicle(0)) then return end
    _doSpawn()
end

-- Fallback: check once per second so we don't spin every frame.
local function onUpdate(dt)
    if not _pendingSpawn then return end
    _updateTimer = _updateTimer + dt
    if _updateTimer < 1.0 then return end
    _updateTimer = 0
    if be and be:getPlayerVehicle(0) then
        _doSpawn()
    end
end

M.onClientStartMission = onClientStartMission
M.onClientEndMission   = onClientEndMission
M.onVehicleAdded       = onVehicleAdded
M.onUpdate             = onUpdate

return M
