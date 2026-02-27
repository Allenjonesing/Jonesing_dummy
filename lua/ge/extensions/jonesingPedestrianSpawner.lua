-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianSpawner.lua
-- Automatically spawns Jonesing dummy pedestrians when a freeroam map loads.
-- Hooks into onClientStartMission and defers the actual spawn to onUpdate so
-- that the player vehicle is guaranteed to exist before propRecycler is called.

local M = {}

-- Set by onClientStartMission; cleared once the spawn succeeds.
local _needsSpawn = false

local function onClientStartMission(missionPath)
    -- Only spawn in freeroam (not during a scenario or time trial, etc.)
    if scenario_scenarios and scenario_scenarios.getScenario and scenario_scenarios.getScenario() then
        _needsSpawn = false
        return
    end
    _needsSpawn = true
end

-- Polls every frame until the player vehicle is ready, then spawns once.
local function onUpdate(dt)
    if not _needsSpawn then return end
    -- Wait until the player vehicle exists; spawn10DummiesAndStart requires it.
    if not (be and be:getPlayerVehicle(0)) then return end
    _needsSpawn = false

    if not propRecycler then
        extensions.load("propRecycler")
    end
    log('I', 'Spawn_Ped', 'Spawning...')
    propRecycler.spawn10DummiesAndStart({
        maxDistance = 150,
        leadDistance = 50,
        lateralJitter = 10,
        debug = true
    })
    log('I', 'Spawn_Ped', 'Spawn Complete')
end

M.onClientStartMission = onClientStartMission
M.onUpdate = onUpdate

return M
