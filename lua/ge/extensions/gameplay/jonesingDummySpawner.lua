-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummySpawner.lua
-- GE-side extension that owns the "Spawn Ped Dummies" and
-- "Despawn / Clear Dummies" input actions.
--
-- How input registration works:
--   onExtensionLoaded() calls core_input_actionFilter.addAction() for each
--   action.  This is what makes them appear under "Jonesing Dummy Mod" in
--   Options → Controls so the user can bind any key.  The key binding itself
--   is stored by BeamNG in settings/inputmaps/ (seeded by
--   settings/inputmaps/jonesingDummyMod.json which ships with the mod).
--   When the bound key is pressed BeamNG fires onInputAction() on every
--   loaded GE extension; we also wire onDown callbacks in addAction() as
--   a direct path so either route triggers the spawn/despawn logic.
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

-- Called once when this GE extension is loaded (at gameplay start).
-- Registers the two custom actions with core_input_actionFilter so that they
-- appear in Options → Controls under the "Jonesing Dummy Mod" category where
-- the user can assign any key.  The onDown callbacks are the primary trigger
-- path; onInputAction below is the complementary/fallback path.
function M.onExtensionLoaded()
    log("I", "jonesingDummySpawner", "loaded — registering hotkey input actions")
    if core_input_actionFilter then
        core_input_actionFilter.addAction(0, "jonesingDummy_spawnPeds", {
            displayName     = "Spawn Ped Dummies",
            displayCategory = "Jonesing Dummy Mod",
            onDown          = function() spawnDummies() end,
            onUp            = function() end,
        })
        core_input_actionFilter.addAction(0, "jonesingDummy_despawnPeds", {
            displayName     = "Despawn / Clear Dummies",
            displayCategory = "Jonesing Dummy Mod",
            onDown          = function() despawnDummies() end,
            onUp            = function() end,
        })
        log("I", "jonesingDummySpawner",
            "registered jonesingDummy_spawnPeds + jonesingDummy_despawnPeds with core_input_actionFilter")
    else
        log("W", "jonesingDummySpawner",
            "core_input_actionFilter not available — actions will only trigger via onInputAction")
    end
end

-- Complementary path: BeamNG calls this on every loaded GE extension whenever
-- a named action fires (val > 0 = key down, val == 0 = key up).
function M.onInputAction(actionName, val)
    if actionName == "jonesingDummy_spawnPeds" and val > 0.5 then
        spawnDummies()
    elseif actionName == "jonesingDummy_despawnPeds" and val > 0.5 then
        despawnDummies()
    end
end

return M
