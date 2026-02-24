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
--              Spawn position is shifted sidewalkOffset metres RIGHT of the lane
--              direction (toward the kerb) so the dummy walks on the sidewalk,
--              not in the lane centre.
--
--   STANDING — All position overrides stop.  The existing stabiliser beams hold
--              the dummy upright as a solid physics object.  A vehicle impact
--              will overwhelm the stabilisers and the dummy tumbles naturally.
--
-- GHOST → STANDING transition:
--   • After STARTUP_GRACE seconds, the reference node is checked each frame.
--     If it is displaced ≥ 3 cm in XY (horizontal) from the expected ghost
--     position, a vehicle has physically contacted the dummy → switch to
--     STANDING so the impact force acts on a solid upright body.
--   • The startup grace period prevents the physics-settling jitter that
--     occurs in the first ~1-2 s after a traffic-script spawn from triggering
--     a false transition.  During grace, spawnXY is re-baselined each frame to
--     track the settling, so the post-grace impact check starts from an accurate
--     reference.
--
-- Controller params (set in the jbeam slot entry):
--   walkSpeed        (default 0.008 m/s) — very slow pedestrian shuffle in ghost mode
--   maxWalkSpeed     (default 2.235 m/s / 5 mph) — absolute cap, prevents runaway
--   walkChangePeriod (default 5.0 s)  — seconds between gentle road-parallel tweaks
--   sidewalkOffset   (default 5.0 m)  — lateral shift RIGHT of lane direction at spawn
--                                        (half-road-width offset; ~5 m puts dummy on kerb
--                                         for a typical 2×10 m lane layout)

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "ghost"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ}
local walkOffsetX        = 0.0
local walkOffsetY        = 0.0
local walkDir            = 0.0
local walkTimer          = 0.0
local startupTimer       = 0.0

-- configurable params
local walkSpeed          = 0.008    -- m/s  (very slow GTA pedestrian shuffle)
-- Hard speed cap: teleport delta per frame is clamped so physics velocity
-- never accumulates beyond this regardless of frame rate or walk speed setting.
-- 5 mph = 2.235 m/s
local maxWalkSpeed        = 2.235    -- m/s  (~5 mph)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local sidewalkOffset     = 5.0      -- m    (5 m RIGHT of lane direction = on kerb)

-- Direction change magnitude — tight so dummy stays road-parallel with only a
-- gentle drift over time.
local DIRECTION_CHANGE_MAX = math.pi / 36   -- ±5°
-- Impact detection threshold: only check XY (horizontal) displacement.
-- Terrain height changes push nodes vertically (Z) — checking Z causes false
-- triggers on any slope or bump.  Real vehicle/wall impacts displace nodes
-- laterally (XY) by ≥ 3 cm; terrain slope only affects Z.
-- Normal ghost-walking XY residual drift ≈ 1 mm (30× safety margin).
local IMPACT_THRESHOLD_SQ  = 0.03 * 0.03   -- metres²  (3 cm in XY only)
-- Grace period after spawn before the impact check is enabled.
-- Traffic-script spawning runs physics-settling for ~1 s after init();
-- during this time nodes can move > 3 cm in XY purely from spring/damper
-- settling, which would otherwise false-trigger the STANDING transition.
local STARTUP_GRACE        = 2.0             -- seconds


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

    -- Reset accumulators and startup grace timer
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkTimer    = 0
    startupTimer = 0

    -- Align walk direction to road and apply sidewalk offset.
    -- Heuristic: assume the player is near the road centreline when spawning
    -- the dummy.  The vector from the dummy spawn to the player is therefore
    -- roughly PERPENDICULAR to the road.  Rotating it 90° gives the road
    -- direction (parallel), which we use as the walk direction.
    --
    -- IMPORTANT: the sidewalk offset is stored in walkOffsetX/Y (not in
    -- spawnXY) so the ghost teleport loop applies it every frame.  Storing it
    -- in spawnXY and calling setNodePosition here would be overridden by
    -- BeamNG's physics settlement in the first frames after spawning.
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

            -- Sidewalk offset: always shift RIGHT of the walk direction.
            -- Forward vector = (sin(walkDir), cos(walkDir))
            -- Right perpendicular (90° clockwise) = (cos(walkDir), -sin(walkDir))
            -- This places the dummy on the right kerb/sidewalk of their traffic lane.
            local rightX = math.cos(walkDir)
            local rightY = -math.sin(walkDir)
            -- Store in walkOffset so teleport loop applies it every frame
            walkOffsetX = rightX * sidewalkOffset
            walkOffsetY = rightY * sidewalkOffset
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
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkTimer    = 0
    startupTimer = 0
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

    -- ── 1. Startup grace period ────────────────────────────────────────────────
    -- During STARTUP_GRACE seconds, BeamNG physics is settling the dummy's nodes
    -- from jbeam default positions onto the ground via spring/damper forces.
    -- Nodes can move > 3 cm in XY during this settling, which would otherwise
    -- immediately false-trigger the impact check → STANDING transition.
    --
    -- Strategy: re-baseline spawnXY each frame from the current physics position
    -- so that by the time the grace period ends, our reference accurately reflects
    -- the settled state.  The teleport target (spawnXY + walkOffset) always equals
    -- the current physics position during grace, so the offset is preserved.
    --   desired position = spawnXY + walkOffset
    --   ∴  spawnXY = cur − walkOffset
    local inStartup = (startupTimer < STARTUP_GRACE)
    if inStartup then
        startupTimer = startupTimer + dt
        for _, rec in ipairs(allNodes) do
            local cur = vec3(obj:getNodePosition(rec.cid))
            rec.spawnX = cur.x - walkOffsetX
            rec.spawnY = cur.y - walkOffsetY
            -- spawnZ is not re-baselined: we always hold the dummy at its initial
            -- spawn height (anti-gravity ghost effect).
        end
        -- Skip impact check — false positives guaranteed during settling.
    else
        -- ── 2. Impact detection (XY only, post-grace) ─────────────────────────
        -- Compare where physics currently has the reference node vs. where we put
        -- it last frame (spawnXY + accumulated walk offset).
        -- Normal walking residual drift ≈ 1 mm.  A wall or vehicle contact pushes
        -- the node ≥ 3 cm in XY → switch to STANDING immediately so the dummy
        -- reacts to the collision instead of teleporting through it.
        if #allNodes > 0 then
            local ref = allNodes[1]
            local cur = vec3(obj:getNodePosition(ref.cid))
            local expX = ref.spawnX + walkOffsetX
            local expY = ref.spawnY + walkOffsetY
            local ddx = cur.x - expX
            local ddy = cur.y - expY
            -- XY-only: ignore Z so terrain slope / bumps don't false-trigger
            if (ddx*ddx + ddy*ddy) > IMPACT_THRESHOLD_SQ then
                state = "standing"
                return
            end
        end
    end

    -- ── 3. Periodically tweak walk direction (gentle, ±5°, road-parallel) ─────
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir = walkDir + (math.random() - 0.5) * 2 * DIRECTION_CHANGE_MAX
    end

    -- ── 4. Accumulate horizontal walk displacement ────────────────────────────
    local effectiveSpeed = math.min(walkSpeed, maxWalkSpeed)
    local stepX = math.sin(walkDir) * effectiveSpeed * dt
    local stepY = math.cos(walkDir) * effectiveSpeed * dt
    walkOffsetX = walkOffsetX + stepX
    walkOffsetY = walkOffsetY + stepY

    -- ── 5. Teleport every node to its desired ghost position ─────────────────
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
