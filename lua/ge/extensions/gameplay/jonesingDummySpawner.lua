-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummySpawner.lua
-- GE-side extension that owns the "Spawn Ped Dummies" and
-- "Despawn / Clear Dummies" input actions.
--
-- Input actions are defined in settings/inputmaps/jonesingDummyMod.json and
-- appear in BeamNG's Controls settings (unbound by default).  When the user
-- presses the bound key BeamNG fires onInputAction(), which this module
-- intercepts to trigger spawn / despawn.
--
-- Spawn behaviour:
--   • Spawns SPAWN_COUNT standalone agenty_dummy props using the "Normal"
--     config, placed in a row roughly 4 m in front of the player vehicle.
--   • Reuses the existing agenty_dummy vehicle model and Normal.pc config —
--     NO spawn logic has been changed.
--   • A 500 ms cooldown prevents key-hold spam.
--
-- Despawn behaviour:
--   • Removes every dummy previously spawned through this extension.
--   • Same 500 ms cooldown.

local M = {}

-- ── tuneable constants ────────────────────────────────────────────────────────
local SPAWN_COUNT    = 3          -- number of dummies per key press
local SPAWN_CONFIG   = "Normal"   -- .pc config inside vehicles/agenty_dummy/
local SPAWN_SPACING  = 1.5        -- metres between each dummy in the row
local SPAWN_FORWARD  = 4.0        -- metres in front of the player to place row
local COOLDOWN       = 0.5        -- seconds between allowed activations

-- ── internal state ────────────────────────────────────────────────────────────
local spawnedIds      = {}        -- vehicle IDs spawned through this extension
local lastSpawnTime   = -math.huge
local lastDespawnTime = -math.huge

-- ── helpers ───────────────────────────────────────────────────────────────────

local function now()
    return Engine.Platform.getRuntime() * 0.001  -- ms → s
end

-- Returns the player vehicle's world position and forward direction, or nil.
local function getPlayerTransform()
    local pv = be:getPlayerVehicle(0)
    if not pv then return nil, nil end
    local p   = pv:getPosition()
    local fwd = pv:getDirectionVector()
    return vec3(p.x, p.y, p.z), vec3(fwd.x, fwd.y, 0):normalized()
end

-- ── public spawn / despawn ────────────────────────────────────────────────────

local function spawnDummies()
    if now() - lastSpawnTime < COOLDOWN then return end
    lastSpawnTime = now()

    local pos, fwd = getPlayerTransform()
    if not pos then
        log("W", "jonesingDummySpawner", "spawn: player vehicle not found, skipping")
        return
    end

    -- Perpendicular axis for spacing dummies side-by-side.
    local right = vec3(-fwd.y, fwd.x, 0)

    -- Centre the row on the forward point.
    local rowCentre = pos + fwd * SPAWN_FORWARD
    local halfWidth = (SPAWN_COUNT - 1) * SPAWN_SPACING * 0.5

    log("I", "jonesingDummySpawner",
        string.format("spawning %d ped dummy(s) ahead of player", SPAWN_COUNT))

    for i = 1, SPAWN_COUNT do
        local offset   = (i - 1) * SPAWN_SPACING - halfWidth
        local spawnPos = rowCentre + right * offset
        local options  = {
            config    = SPAWN_CONFIG,
            pos       = spawnPos,
            -- spawn facing the same direction as the player
            rot       = quatFromDir(fwd, vec3(0, 0, 1)),
            autoEnterVehicle = false,
        }
        local vid = core_vehicles.spawnNewVehicle("agenty_dummy", options)
        if vid then
            table.insert(spawnedIds, vid)
            log("I", "jonesingDummySpawner", "spawned agenty_dummy id=" .. tostring(vid))
        else
            log("W", "jonesingDummySpawner", "spawnNewVehicle returned nil for dummy #" .. i)
        end
    end
end

local function despawnDummies()
    if now() - lastDespawnTime < COOLDOWN then return end
    lastDespawnTime = now()

    local count = #spawnedIds
    log("I", "jonesingDummySpawner",
        string.format("despawning %d tracked ped dummy(s)", count))

    for _, vid in ipairs(spawnedIds) do
        if be:getObjectByID(vid) then
            be:deleteObjectById(vid)
            log("I", "jonesingDummySpawner", "deleted dummy id=" .. tostring(vid))
        end
    end
    spawnedIds = {}
end

-- ── BeamNG extension hooks ────────────────────────────────────────────────────

-- Called by BeamNG whenever an input action fires (keyboard, controller, etc.)
function M.onInputAction(actionName, val)
    if actionName == "jonesingDummy_spawnPeds" and val > 0.5 then
        spawnDummies()
    elseif actionName == "jonesingDummy_despawnPeds" and val > 0.5 then
        despawnDummies()
    end
end

return M
