-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two states (GHOST and STANDING):
--
--   GHOST    — The dummy floats at spawn height and walks slowly, phasing
--              through everything.  Implemented via setNodePosition on all
--              nodes simultaneously (constant beam lengths, no internal forces).
--              Walk direction is aligned to the road (perpendicular of the
--              player→dummy spawn vector) so the dummy walks like a pedestrian
--              along the sidewalk rather than drifting across the road.
--              Spawn position is shifted 2.5 m to the side of the road centerline.
--
--   STANDING — All position overrides stop.  The existing stabiliser beams hold
--              the dummy upright as a solid physics object.  A vehicle impact
--              will overwhelm the stabilisers and the dummy tumbles naturally.
--
-- GHOST → STANDING transition:
--   • Reference node is displaced ≥ 3 cm from expected position while in GHOST.
--     Any vehicle (player or traffic) physically contacting the dummy triggers
--     this — overrides stop, dummy becomes a solid upright pedestrian, the
--     impact force knocks it over naturally via physics.
--
-- Controller params (set in the jbeam slot entry):
--   walkSpeed        (default 0.03 m/s) — slow pedestrian pace in ghost mode
--   maxWalkSpeed     (default 2.235 m/s / 5 mph) — absolute cap, prevents runaway
--   walkChangePeriod (default 5.0 s)  — seconds between gentle road-parallel tweaks
--   sidewalkOffset   (default 2.5 m)  — lateral shift from road centreline at spawn

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "ghost"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ}
local walkOffsetX        = 0.0
local walkOffsetY        = 0.0
local walkDir            = 0.0
local walkTimer          = 0.0

-- configurable params
local walkSpeed          = 0.03     -- m/s  (slow GTA pedestrian pace)
-- Hard speed cap: teleport delta per frame is clamped so physics velocity
-- never accumulates beyond this regardless of frame rate or walk speed setting.
-- 5 mph = 2.235 m/s
local maxWalkSpeed        = 2.235    -- m/s  (~5 mph)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local sidewalkOffset     = 2.5      -- m    (lateral shift from road centreline)

-- Direction change magnitude — tight so dummy stays road-parallel with only a
-- gentle drift over time.
local DIRECTION_CHANGE_MAX = math.pi / 36   -- ±5°
-- Impact detection threshold: normal walking drift ≈ 1 mm; anything larger
-- than IMPACT_THRESHOLD (3 cm) means a wall or vehicle physically displaced a node.
local IMPACT_THRESHOLD_SQ  = 0.03 * 0.03   -- metres²  (3 cm)


-- ── helpers ───────────────────────────────────────────────────────────────────

-- Safely get the player vehicle's world position (returns vec3 or nil).
-- Used during init() to compute road direction and sidewalk offset.
local function getPlayerPos()
    local ok, result = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and result) or nil
end


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    maxWalkSpeed     = jbeamData.maxWalkSpeed      or maxWalkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    sidewalkOffset   = jbeamData.sidewalkOffset   or sidewalkOffset

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

    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0

    -- Align walk direction to road and apply sidewalk offset.
    -- Heuristic: assume the player is near the road centreline when spawning
    -- the dummy.  The vector from the dummy spawn to the player is therefore
    -- roughly PERPENDICULAR to the road.  Rotating it 90° gives the road
    -- direction (parallel), which we use as the walk direction.
    local pp = getPlayerPos()
    if pp and #allNodes > 0 then
        local r = allNodes[1]
        local dx = pp.x - r.spawnX
        local dy = pp.y - r.spawnY
        local perpDist = math.sqrt(dx*dx + dy*dy)

        if perpDist > 1.0 then
            -- Road-parallel direction = 90° rotation of (dx, dy)
            --   perpendicular to road = (dx/d, dy/d)  [toward player]
            --   along road            = (-dy/d, dx/d)
            local nx = -dy / perpDist
            local ny =  dx / perpDist
            walkDir = math.atan2(nx, ny)
            -- 50/50 chance of walking toward or away from player's heading
            local flip = (math.random() > 0.5) and math.pi or 0.0
            walkDir = walkDir + flip

            -- Sidewalk offset: shift spawn sideways (along perpendicular to road,
            -- i.e. in the player→dummy direction) so the dummy stands on the kerb.
            local sideSign = (math.random() > 0.5) and 1 or -1
            local offX = (dx / perpDist) * sidewalkOffset * sideSign
            local offY = (dy / perpDist) * sidewalkOffset * sideSign
            for _, rec in ipairs(allNodes) do
                rec.spawnX = rec.spawnX + offX
                rec.spawnY = rec.spawnY + offY
                obj:setNodePosition(rec.cid, vec3(rec.spawnX, rec.spawnY, rec.spawnZ))
            end
        else
            -- Player is almost on top of spawn — fall back to random direction
            walkDir = math.random() * 2 * math.pi
        end
    else
        walkDir = math.random() * 2 * math.pi
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
    state = "ghost"
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- STANDING state: all position overrides are OFF.
    -- The stabiliser beams hold the dummy upright as a solid physics object.
    -- A vehicle hit will overwhelm the stabilisers and the dummy tumbles naturally.
    if state == "standing" then return end

    -- ── 1. Impact detection ───────────────────────────────────────────────────
    -- Compare where physics currently has the reference node vs. where we put it
    -- last frame (spawnXY + accumulated walk offset, same Z we always set).
    -- Normal walking residual drift ≈ 1 mm.  A wall or vehicle contact pushes the
    -- node far more (≥ 3 cm) → switch to standing immediately so the dummy
    -- reacts to the collision instead of teleporting through it.
    if #allNodes > 0 then
        local ref = allNodes[1]
        local cur = vec3(obj:getNodePosition(ref.cid))
        local expX = ref.spawnX + walkOffsetX
        local expY = ref.spawnY + walkOffsetY
        local expZ = ref.spawnZ
        local ddx = cur.x - expX
        local ddy = cur.y - expY
        local ddz = cur.z - expZ
        if (ddx*ddx + ddy*ddy + ddz*ddz) > IMPACT_THRESHOLD_SQ then
            state = "standing"
            return
        end
    end

    -- ── 2. Periodically tweak walk direction (gentle, ±5°, road-parallel) ─────
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir = walkDir + (math.random() - 0.5) * 2 * DIRECTION_CHANGE_MAX
    end

    -- ── 3. Accumulate horizontal walk displacement ────────────────────────────
    local effectiveSpeed = math.min(walkSpeed, maxWalkSpeed)
    local stepX = math.sin(walkDir) * effectiveSpeed * dt
    local stepY = math.cos(walkDir) * effectiveSpeed * dt
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
