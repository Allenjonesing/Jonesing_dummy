-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianSpawner.lua
-- Automatically spawns Jonesing dummy pedestrians when a freeroam map loads.
-- Hooks into onClientStartMission and skips execution when a scenario is active.

local M = {}

local function onClientStartMission(missionPath)
    -- Only spawn in freeroam (not during a scenario or time trial, etc.)
    if scenario_scenarios and scenario_scenarios.getScenario and scenario_scenarios.getScenario() then
        return
    end

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

return M
