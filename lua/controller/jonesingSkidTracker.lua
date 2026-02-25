-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingSkidTracker.lua
-- Leaves red skid streaks on the ground whenever the dummy ragdoll is sliding
-- (sustained ground contact + horizontal speed).  Works in freeroam with
-- spawned dummies; no world-editor placement needed.
--
-- Detection logic (all conditions must be true simultaneously):
--   (a) Body is lying flat  — chest node is within bodyFlatThreshold of foot Z
--   (b) Horizontal speed    — foot node ≥ speedThreshold m/s
--   (c) Not airborne        — foot vertical velocity < vertVelThreshold m/s upward
--   (d) Foot near ground    — foot Z is within groundClearance of the terrain
--                             surface (queried via be:getSurfaceHeightBelow;
--                             falls back to foot-vs-chest heuristic on failure)
--
-- Visual output:
--   Each sample interval a short segment is added to a circular buffer.
--   Every GFX frame all living segments are drawn as flat "double-line" quads
--   (two parallel lines + two end-caps) using DebugDrawer, with alpha fading
--   over the segment's lifetime.  This gives persistent, fade-out marks that
--   require no decal or particle API.
--
-- Tunable params (set in the jbeam slot entry, all optional):
--   skidGroundClearance   (default 0.25  m)   — foot-to-surface max distance
--   skidBodyFlatThreshold (default 0.80  m)   — max chest-above-foot to count as flat
--   skidSpeedThreshold    (default 0.80 m/s)  — min horizontal speed for marks
--   skidVertVelThreshold  (default 3.00 m/s)  — upward vert velocity = airborne
--   skidSampleInterval    (default 0.05  s)   — how often to record a new point
--   skidMaxSegments       (default 50)        — hard cap; oldest removed first
--   skidSegmentLifetime   (default 10.0  s)   — fade-out duration per segment
--   skidMarkWidth         (default 0.10  m)   — half-width of the drawn quad
--   skidDebugMode         (default false)     — log state transitions + green spheres
--   skidTrackNodeName     (default "dummy1_L_footbmr")   — foot/ground reference node
--   skidBodyNodeName      (default "dummy1_thoraxtfl")   — chest/orientation node

local M = {}

-- ── Configuration (overridable from jbeam) ────────────────────────────────────
local cfg = {
    groundClearance    = 0.25,   -- m: foot-to-surface threshold
    bodyFlatThreshold  = 0.80,   -- m: max (chestZ - footZ) when body is flat
    speedThreshold     = 0.80,   -- m/s: min horizontal speed
    vertVelThreshold   = 3.00,   -- m/s: max upward foot velocity before "airborne"
    sampleInterval     = 0.05,   -- s: ~20 Hz sampling
    maxSegments        = 50,     -- hard cap on stored segments
    segmentLifetime    = 10.0,   -- s: fade duration
    markWidth          = 0.10,   -- m: half-width of drawn quad
    debugMode          = false,
    trackNodeName      = "dummy1_L_footbmr",
    bodyNodeName       = "dummy1_thoraxtfl",
}

-- ── Internal state ─────────────────────────────────────────────────────────────
local footCid        = nil    -- node cid for ground-contact tracking
local chestCid       = nil    -- node cid for body-orientation check
local segments       = {}     -- {x1,y1,z1, x2,y2,z2, life, maxLife}
local sampleTimer    = 0.0
local lastSamplePos  = nil    -- vec3 of last sampled foot position
local isSliding      = false
local prevFootZ      = nil    -- previous-frame foot Z for vertical-velocity estimate
local rawNodeIds     = {}


-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Query terrain height below a world position.  Returns nil on failure.
local function getSurfaceHeight(x, y, z)
    local ok, h = pcall(function()
        return be:getSurfaceHeightBelow(x, y, z)
    end)
    return (ok and type(h) == "number") and h or nil
end

-- Safe DebugDrawer line call (no-op if API unavailable this build).
local function dbgLine(p1, p2, col)
    pcall(function() DebugDrawer:drawLine(p1, p2, col) end)
end

-- Safe DebugDrawer sphere call.
local function dbgSphere(center, radius, col)
    pcall(function() DebugDrawer:drawSphere(center, radius, col) end)
end


-- ── jbeam lifecycle ────────────────────────────────────────────────────────────

local function init(jbeamData)
    -- Allow per-instance overrides from the jbeam slot entry
    cfg.groundClearance   = jbeamData.skidGroundClearance   or cfg.groundClearance
    cfg.bodyFlatThreshold = jbeamData.skidBodyFlatThreshold or cfg.bodyFlatThreshold
    cfg.speedThreshold    = jbeamData.skidSpeedThreshold    or cfg.speedThreshold
    cfg.vertVelThreshold  = jbeamData.skidVertVelThreshold  or cfg.vertVelThreshold
    cfg.sampleInterval    = jbeamData.skidSampleInterval    or cfg.sampleInterval
    cfg.maxSegments       = jbeamData.skidMaxSegments       or cfg.maxSegments
    cfg.segmentLifetime   = jbeamData.skidSegmentLifetime   or cfg.segmentLifetime
    cfg.markWidth         = jbeamData.skidMarkWidth         or cfg.markWidth
    cfg.debugMode         = jbeamData.skidDebugMode         or cfg.debugMode
    cfg.trackNodeName     = jbeamData.skidTrackNodeName     or cfg.trackNodeName
    cfg.bodyNodeName      = jbeamData.skidBodyNodeName      or cfg.bodyNodeName

    footCid  = nil
    chestCid = nil
    rawNodeIds = {}

    for _, n in pairs(v.data.nodes) do
        table.insert(rawNodeIds, n.cid)
        if n.name == cfg.trackNodeName then footCid  = n.cid end
        if n.name == cfg.bodyNodeName  then chestCid = n.cid end
    end

    -- Fallback: first node if named nodes not found
    if not footCid  and #rawNodeIds > 0 then footCid  = rawNodeIds[1] end
    if not chestCid and #rawNodeIds > 0 then chestCid = rawNodeIds[1] end

    segments      = {}
    sampleTimer   = 0.0
    lastSamplePos = nil
    isSliding     = false
    prevFootZ     = nil

    if cfg.debugMode then
        log("I", "jonesingSkidTracker", "init() — footCid=" .. tostring(footCid) ..
            " chestCid=" .. tostring(chestCid))
    end
end


local function reset()
    segments      = {}
    sampleTimer   = 0.0
    lastSamplePos = nil
    isSliding     = false
    prevFootZ     = nil
end


-- ── Per-frame update ──────────────────────────────────────────────────────────

local function updateGFX(dt)
    if dt <= 0 then return end
    if not footCid or not chestCid then return end

    -- ── 1. Read node positions ───────────────────────────────────────────────
    local footPos  = vec3(obj:getNodePosition(footCid))
    local chestPos = vec3(obj:getNodePosition(chestCid))

    -- ── 2. Compute detection signals ─────────────────────────────────────────

    -- (a) Body-flat check: chest is near foot height (lying down)
    local heightDiff = chestPos.z - footPos.z
    local bodyFlat   = (heightDiff < cfg.bodyFlatThreshold)

    -- (b) Horizontal speed (foot node, estimated from Z-less position delta)
    local hSpeed = 0.0
    if lastSamplePos then
        local dxLast = footPos.x - lastSamplePos.x
        local dyLast = footPos.y - lastSamplePos.y
        -- Use the time since last sample for speed estimate
        hSpeed = math.sqrt(dxLast * dxLast + dyLast * dyLast) / math.max(sampleTimer, dt, 0.001)
    end
    local fastEnough = (hSpeed >= cfg.speedThreshold)

    -- (c) Vertical velocity of foot (not flying upward)
    local footVZ     = prevFootZ and ((footPos.z - prevFootZ) / math.max(dt, 0.001)) or 0.0
    local notLaunched = (footVZ < cfg.vertVelThreshold)

    -- (d) Foot near terrain surface
    local surfH    = getSurfaceHeight(footPos.x, footPos.y, footPos.z + 2.0)
    local grounded
    if surfH then
        grounded = (footPos.z - surfH) < cfg.groundClearance
    else
        -- Fallback: foot Z is not changing much vertically (proxy for ground contact)
        grounded = (math.abs(footVZ) < 1.5)
    end

    local wasSliding = isSliding
    isSliding = bodyFlat and fastEnough and notLaunched and grounded

    -- Debug: log state transitions and show sample points as spheres
    if cfg.debugMode and (isSliding ~= wasSliding) then
        log("I", "jonesingSkidTracker",
            string.format("Sliding=%s | hSpeed=%.2f m/s | heightDiff=%.2f m | footVZ=%.2f m/s | grounded=%s",
                tostring(isSliding), hSpeed, heightDiff, footVZ, tostring(grounded)))
    end

    -- ── 3. Sample position → new segment ─────────────────────────────────────
    sampleTimer = sampleTimer + dt

    if isSliding and sampleTimer >= cfg.sampleInterval then
        -- Ground position for mark: foot XY at a tiny Z offset above surface
        local markZ = surfH and (surfH + 0.015) or (footPos.z + 0.015)
        local curPos = vec3(footPos.x, footPos.y, markZ)

        if lastSamplePos then
            local dx = curPos.x - lastSamplePos.x
            local dy = curPos.y - lastSamplePos.y
            if (dx * dx + dy * dy) > 0.0001 then   -- at least 1 cm movement
                -- Enforce hard cap: evict oldest
                if #segments >= cfg.maxSegments then
                    table.remove(segments, 1)
                end
                table.insert(segments, {
                    x1 = lastSamplePos.x, y1 = lastSamplePos.y, z1 = lastSamplePos.z,
                    x2 = curPos.x,        y2 = curPos.y,        z2 = curPos.z,
                    life    = cfg.segmentLifetime,
                    maxLife = cfg.segmentLifetime,
                })
                if cfg.debugMode then
                    log("I", "jonesingSkidTracker",
                        string.format("  segment(%.2f,%.2f)→(%.2f,%.2f)  total=%d",
                            lastSamplePos.x, lastSamplePos.y, curPos.x, curPos.y, #segments))
                end
            end
        end
        lastSamplePos = curPos
        sampleTimer   = 0.0
    end

    -- Reset sample state when not sliding so we restart cleanly on next contact
    if not isSliding then
        lastSamplePos = nil
        sampleTimer   = 0.0
    end

    -- ── 4. Age segments, remove expired ones, draw survivors ─────────────────
    local w   = cfg.markWidth
    local i   = 1
    while i <= #segments do
        local seg = segments[i]
        seg.life = seg.life - dt
        if seg.life <= 0.0 then
            table.remove(segments, i)
            -- do not increment i
        else
            -- Alpha fades from 1 → 0 over the segment lifetime
            local alpha = seg.life / seg.maxLife

            -- Build a flat "quad" as four lines:
            --   p1a─────p2a
            --   │         │
            --   p1b─────p2b
            -- The quad lies along the segment direction, width = 2*w.
            local dx  = seg.x2 - seg.x1
            local dy  = seg.y2 - seg.y1
            local len = math.sqrt(dx * dx + dy * dy)

            if len > 0.001 then
                local nx = (-dy / len) * w   -- perpendicular unit * half-width
                local ny = ( dx / len) * w

                local p1a = vec3(seg.x1 + nx, seg.y1 + ny, seg.z1)
                local p1b = vec3(seg.x1 - nx, seg.y1 - ny, seg.z1)
                local p2a = vec3(seg.x2 + nx, seg.y2 + ny, seg.z2)
                local p2b = vec3(seg.x2 - nx, seg.y2 - ny, seg.z2)

                local col = ColorF(0.75, 0.0, 0.0, alpha)   -- red, fading
                dbgLine(p1a, p2a, col)
                dbgLine(p1b, p2b, col)
                dbgLine(p1a, p1b, col)
                dbgLine(p2a, p2b, col)

                if cfg.debugMode then
                    -- Green spheres at the sample endpoints for visualisation
                    dbgSphere(vec3(seg.x1, seg.y1, seg.z1), 0.04, ColorF(0.0, 1.0, 0.0, alpha))
                end
            end

            i = i + 1
        end
    end

    -- Store foot Z for next frame's vertical-velocity estimate
    prevFootZ = footPos.z
end


-- ── Public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
