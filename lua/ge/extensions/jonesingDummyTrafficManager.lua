-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummyTrafficManager.lua
-- Game-Engine extension that spawns and recycles 10 agenty_dummy pedestrians
-- as traffic whenever the Universal Dummy Mod (license-plate slot) is active
-- in any vehicle.
--
-- Lifecycle:
--   1. The jonesingDummyTrafficTrigger vehicle-controller calls
--      jonesingDummyTrafficManager.onDummyModActivated(hostVehicleId)
--      from the VE context via obj:queueGameEngineLua().
--   2. This extension begins spawning up to DUMMY_COUNT agenty_dummy vehicles
--      on road positions near the player.  Each dummy uses its default NPC
--      behaviour slot (jonesing_gta_npc_on), so it walks ghost-style along the
--      road and tumbles naturally when struck by a car.
--   3. onUpdate() runs every frame.  Every UPDATE_INTERVAL seconds it:
--        • Removes dummies whose distance from the player exceeds RECYCLE_DIST.
--        • Spawns replacement dummies to keep the pool at DUMMY_COUNT.
--   4. When the host vehicle is destroyed / the mod is deactivated,
--      onDummyModDeactivated() removes all managed dummies and shuts down.
--
-- Spawn positions are chosen by picking a random road node within
-- [SPAWN_RADIUS_MIN, SPAWN_RADIUS_MAX] metres of the player, falling back to
-- a flat-plane offset when no map data is available.

local M = {}

-- ── tuneable constants ────────────────────────────────────────────────────────
local DUMMY_COUNT      = 10      -- target pedestrian pool size
local SPAWN_RADIUS_MIN = 40      -- minimum spawn distance from player (m)
local SPAWN_RADIUS_MAX = 150     -- maximum spawn distance from player (m)
local RECYCLE_DIST     = 200     -- despawn dummies beyond this distance (m)
local UPDATE_INTERVAL  = 3.0     -- seconds between pool maintenance passes
local DUMMY_MODEL      = "agenty_dummy"
local DUMMY_CONFIG     = "vehicles/agenty_dummy/Normal.pc"

-- ── runtime state ─────────────────────────────────────────────────────────────
local active          = false
local hostVehicleIds  = {}   -- [vid] = true for every vehicle that activated us
local trackedIds      = {}   -- [vid] = true for all dummies we manage
local pendingSpawns   = 0    -- incremented per spawn request; consumed in onVehicleAdded
local updateTimer     = 0


-- ── helpers ───────────────────────────────────────────────────────────────────

local function getPlayerPos()
    local pv = be:getPlayerVehicle(0)
    if not pv then return nil end
    local p = pv:getPosition()
    return vec3(p.x, p.y, p.z)
end

-- Return a world position on a road near basePos, within [minDist, maxDist] m.
-- Uses the navigation map's road-node table; falls back to a flat offset.
local function findRoadSpawnPos(basePos, minDist, maxDist)
    local angle = math.random() * 2 * math.pi
    local dist  = minDist + math.random() * (maxDist - minDist)

    -- Try to snap to an actual road node
    local mapData = map and map.getMap and map.getMap()
    if mapData and mapData.nodes then
        -- Collect nodes roughly in the desired distance band
        local candidates = {}
        for _, node in pairs(mapData.nodes) do
            if node.pos then
                local dx = node.pos.x - basePos.x
                local dy = node.pos.y - basePos.y
                local d2 = dx * dx + dy * dy
                if d2 >= minDist * minDist and d2 <= maxDist * maxDist then
                    table.insert(candidates, node.pos)
                end
            end
        end
        if #candidates > 0 then
            return candidates[math.random(#candidates)]
        end
    end

    -- Fallback: flat-plane offset
    return vec3(
        basePos.x + math.cos(angle) * dist,
        basePos.y + math.sin(angle) * dist,
        basePos.z
    )
end

local function spawnDummy(pos)
    if not pos then return end
    local spawnOptions = {}
    spawnOptions.pos    = pos
    spawnOptions.rot    = quatFromDir(vec3(math.cos(math.random() * 2 * math.pi), math.sin(math.random() * 2 * math.pi), 0), vec3(0, 0, 1))
    spawnOptions.config = DUMMY_CONFIG
    pendingSpawns = pendingSpawns + 1
    core_vehicles.spawnNewVehicle(DUMMY_MODEL, spawnOptions)
end

local function countTracked()
    local n = 0
    for _ in pairs(trackedIds) do n = n + 1 end
    return n
end


-- ── public interface ──────────────────────────────────────────────────────────

-- Called by jonesingDummyTrafficTrigger when the Universal Dummy Mod is loaded.
-- Safe to call for multiple host vehicles simultaneously.
function M.onDummyModActivated(vehicleId)
    hostVehicleIds[vehicleId] = true
    if active then return end  -- pool already running; just register the host
    active      = true
    updateTimer = UPDATE_INTERVAL  -- spawn immediately on first update pass
    trackedIds  = {}
    pendingSpawns = 0
    log("I", "jonesingDummyTrafficManager", "Dummy traffic activated by vehicle id=" .. tostring(vehicleId))
end

-- Remove all managed dummy pedestrians and shut down.
-- Only called when no host vehicles remain active.
local function deactivateAll()
    active = false
    for vid, _ in pairs(trackedIds) do
        local veh = be:getObjectByID(vid)
        if veh then veh:delete() end
    end
    trackedIds    = {}
    pendingSpawns = 0
    log("I", "jonesingDummyTrafficManager", "Dummy traffic deactivated; all pedestrians removed.")
end


-- ── BeamNG event hooks ────────────────────────────────────────────────────────

function M.onVehicleAdded(vid)
    if not active then return end
    -- Only track this vehicle if we were expecting a dummy spawn AND it is not
    -- one of the host vehicles that activated us (they have the mod installed,
    -- not a standalone dummy pedestrian).
    if pendingSpawns > 0 and not hostVehicleIds[vid] then
        pendingSpawns = pendingSpawns - 1
        trackedIds[vid] = true
    end
end

function M.onVehicleDestroyed(vid)
    trackedIds[vid] = nil
    -- If a host vehicle was destroyed, unregister it.
    if hostVehicleIds[vid] then
        hostVehicleIds[vid] = nil
        -- Count remaining hosts; shut down only when none remain.
        local remaining = 0
        for _ in pairs(hostVehicleIds) do remaining = remaining + 1 end
        if remaining == 0 then
            deactivateAll()
        end
    end
end

function M.onUpdate(dt)
    if not active then return end
    updateTimer = updateTimer + dt
    if updateTimer < UPDATE_INTERVAL then return end
    updateTimer = 0

    local pp = getPlayerPos()
    if not pp then return end

    -- 1. Cull dummies that have moved too far from the player or are gone.
    -- Collect removals first to avoid modifying the table mid-iteration.
    local toRemove = {}
    for vid, _ in pairs(trackedIds) do
        local veh = be:getObjectByID(vid)
        if veh then
            local vp  = veh:getPosition()
            local dx  = vp.x - pp.x
            local dy  = vp.y - pp.y
            -- XY-plane distance: sufficient for road traffic; elevated roads are
            -- still within the horizontal band that matters for recycling.
            if (dx * dx + dy * dy) > RECYCLE_DIST * RECYCLE_DIST then
                veh:delete()
                table.insert(toRemove, vid)
            end
        else
            table.insert(toRemove, vid)
        end
    end
    for _, vid in ipairs(toRemove) do
        trackedIds[vid] = nil
    end

    -- 2. Top up the pool.
    local shortage = DUMMY_COUNT - countTracked() - pendingSpawns
    for i = 1, math.max(0, shortage) do
        local spawnPos = findRoadSpawnPos(pp, SPAWN_RADIUS_MIN, SPAWN_RADIUS_MAX)
        spawnDummy(spawnPos)
    end
end

function M.onClientEndMission()
    -- Level unloaded — clear state without trying to delete vehicles
    -- (the engine already removes everything).
    active         = false
    trackedIds     = {}
    pendingSpawns  = 0
    hostVehicleIds = {}
end

return M
