-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Three states:
--   GHOST   — The dummy floats at spawn height and drifts slowly forward,
--             phasing through everything.  Implemented via obj:setNodePosition.
--             Active while the player vehicle is farther than effectiveProxRadius.
--   PHYSICS — Player has come within effectiveProxRadius (= spawnDist * 0.25).
--             Position overrides stop.  The existing stabiliser beams keep the
--             dummy standing upright while full collision physics are active:
--             the dummy can be hit by cars, poles, and other vehicles normally.
--   (no separate ragdoll — once in PHYSICS the physics engine handles it)
--
-- Controller params (set in the jbeam controller entry):
--   walkSpeed        (default 0.3 m/s)— slow pedestrian pace in ghost mode
--   walkChangePeriod (default 5.0 s)  — seconds between gentle direction tweaks
--   proximityRadius  (default 20 m)   — fallback radius if spawn distance can't
--                                       be measured; actual radius = spawnDist*0.25

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "ghost"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ}
local walkOffsetX        = 0.0
local walkOffsetY        = 0.0
local walkDir            = 0.0
local walkTimer          = 0.0
local effectiveProxRadius = 20.0    -- computed at init from spawnDist * 0.25

-- configurable params
local walkSpeed          = 0.3      -- m/s  (slow GTA pedestrian pace)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local proximityRadius    = 20.0     -- m    (fallback if spawn dist unavailable)

-- Direction change magnitude — small so each dummy walks in a consistent line
-- and doesn't zigzag across the road.
local DIRECTION_CHANGE_MAX   = math.pi / 18   -- ±10°
-- Minimum effective proximity radius regardless of spawn distance
local MIN_PROXIMITY_RADIUS   = 6.0           -- metres


-- ── helpers ───────────────────────────────────────────────────────────────────

-- Safely get the player vehicle's world position (returns vec3 or nil).
local function getPlayerPos()
    local ok, result = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and result) or nil
end

-- World position of the dummy's walk origin (spawn centre + accumulated offset).
local function getDummyWorldPos()
    if #allNodes == 0 then return nil end
    local r = allNodes[1]
    return vec3(r.spawnX + walkOffsetX, r.spawnY + walkOffsetY, r.spawnZ)
end


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    proximityRadius  = jbeamData.proximityRadius  or proximityRadius

    -- Record spawn position for every node
    allNodes = {}
    for _, n in pairs(v.data.nodes) do
        local p = vec3(obj:getNodePosition(n.cid))
        table.insert(allNodes, {
            cid    = n.cid,
            spawnX = p.x,
            spawnY = p.y,
            spawnZ = p.z,
        })
    end

    -- Per-instance random seed (unique per vehicle object)
    local seed = 0
    if allNodes[1] then seed = allNodes[1].cid end
    math.randomseed(os.time() + seed)

    -- Walk direction: fully random start, but small perturbations keep it
    -- consistent so the dummy doesn't zigzag sideways across the road.
    walkDir = math.random() * 2 * math.pi

    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0

    -- Compute effective proximity radius = 1/4 of the distance to the player
    -- at spawn time.  Fall back to jbeam proximityRadius if player is unavailable.
    local pp = getPlayerPos()
    if pp and #allNodes > 0 then
        local r = allNodes[1]
        local dx = pp.x - r.spawnX
        local dy = pp.y - r.spawnY
        local dz = pp.z - r.spawnZ
        local spawnDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        effectiveProxRadius = math.max(spawnDist * 0.25, MIN_PROXIMITY_RADIUS)
    else
        effectiveProxRadius = proximityRadius
    end

    state = "ghost"
end


local function reset()
    for _, rec in ipairs(allNodes) do
        local p = vec3(obj:getNodePosition(rec.cid))
        rec.spawnX = p.x
        rec.spawnY = p.y
        rec.spawnZ = p.z
    end
    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0
    local seed = 0
    if allNodes[1] then seed = allNodes[1].cid end
    math.randomseed(os.time() + seed)
    walkDir = math.random() * 2 * math.pi

    -- Recalculate effective proximity radius from new spawn positions
    local pp = getPlayerPos()
    if pp and allNodes[1] then
        local r = allNodes[1]
        local dx = pp.x - r.spawnX
        local dy = pp.y - r.spawnY
        local dz = pp.z - r.spawnZ
        local spawnDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        effectiveProxRadius = math.max(spawnDist * 0.25, MIN_PROXIMITY_RADIUS)
    end

    state = "ghost"
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- PHYSICS state: position overrides are OFF; stabilisers hold dummy upright;
    -- full collision physics active.  Nothing to do here.
    if state == "physics" then return end

    -- ── 1. Check player proximity ─────────────────────────────────────────────
    local myPos = getDummyWorldPos()
    if myPos then
        local pp = getPlayerPos()
        if pp then
            local dx = pp.x - myPos.x
            local dy = pp.y - myPos.y
            local dz = pp.z - myPos.z
            if (dx*dx + dy*dy + dz*dz) < (effectiveProxRadius * effectiveProxRadius) then
                -- Player is close — hand off to physics + stabilisers
                state = "physics"
                return
            end
        end
    end

    -- ── 2. Periodically tweak walk direction (gentle, ±10°) ──────────────────
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir = walkDir + (math.random() - 0.5) * 2 * DIRECTION_CHANGE_MAX
    end

    -- ── 3. Accumulate horizontal walk displacement ────────────────────────────
    local stepX = math.sin(walkDir) * walkSpeed * dt
    local stepY = math.cos(walkDir) * walkSpeed * dt
    walkOffsetX = walkOffsetX + stepX
    walkOffsetY = walkOffsetY + stepY

    -- ── 4. Teleport every node to its desired ghost position ─────────────────
    --  Moving ALL nodes by the same XY offset keeps every beam length constant
    --  → no spurious internal forces or vibration.  Z is fixed (anti-gravity).
    for _, rec in ipairs(allNodes) do
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            rec.spawnZ
        ))
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
