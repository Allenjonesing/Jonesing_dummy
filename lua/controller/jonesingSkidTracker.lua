-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingSkidTracker.lua
-- Leaves red skid streaks on the ground whenever the dummy ragdoll is sliding
-- (sustained ground contact + any horizontal movement).  Works in freeroam with
-- spawned dummies; no world-editor placement needed.
--
-- Rendering: uses obj:addSkidmarkSegment() — the same C++ path that draws
-- tire tracks — so marks render identically to real tire skidmarks and fade/
-- cull with distance exactly like they do.  The "blood_skid" decal name used
-- in art/groundModels/flesh.json is reused here for a red/blood appearance.
--
-- Detection (all must be true):
--   (a) Body flat   — chestZ - torsoZ < bodyFlatThreshold (1.1 m)
--   (b) On ground   — torso Z within groundClearance (0.40 m) of surface
--   (c) Moving      — horizontal speed ≥ speedThreshold (0.25 m/s)
--   (d) Not flying  — upward vertical velocity < vertVelThreshold (4 m/s)
--
-- Tunable params (set in the jbeam slot entry, all optional):
--   skidGroundClearance   (default 0.40  m)
--   skidBodyFlatThreshold (default 1.10  m)
--   skidSpeedThreshold    (default 0.25 m/s)
--   skidVertVelThreshold  (default 4.00 m/s)
--   skidSampleInterval    (default 0.04  s)  — ~25 Hz
--   skidMarkWidth         (default 0.18  m)  — total mark width
--   skidDebugMode         (default false)
--   skidTrackNodeName     (default "dummy1_L_footbmr")
--   skidBodyNodeName      (default "dummy1_thoraxtfl")

local M = {}

-- ── Configuration (overridable from jbeam) ────────────────────────────────────
local cfg = {
    groundClearance    = 0.40,   -- m
    bodyFlatThreshold  = 1.10,   -- m: (chestZ - torsoZ) when lying flat
    speedThreshold     = 0.25,   -- m/s: minimum horizontal speed
    vertVelThreshold   = 4.00,   -- m/s: upward velocity cap
    sampleInterval     = 0.04,   -- s: ~25 Hz
    markWidth          = 0.18,   -- m: total width of one skidmark strip
    debugMode          = false,
    trackNodeName      = "dummy1_L_footbmr",
    bodyNodeName       = "dummy1_thoraxtfl",
}

-- ── Internal state ─────────────────────────────────────────────────────────────
local trackCid       = nil    -- cid of ground-contact reference node
local chestCid       = nil    -- cid of body-orientation reference node
local rawNodeIds     = {}
local sampleTimer    = 0.0
local prevPos        = nil    -- previous-frame world pos of trackNode (vec3)
local prevZ          = nil    -- previous-frame Z for vertical-velocity estimate
local isSliding      = false
local lastMarkPos    = nil    -- world pos of the last emitted mark point


-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Query terrain height below a world position.  Returns nil on failure.
local function getSurfaceHeight(x, y, z)
    local ok, h = pcall(function()
        return be:getSurfaceHeightBelow(x, y, z)
    end)
    return (ok and type(h) == "number") and h or nil
end

-- Emit one skidmark segment using BeamNG's built-in tire-track system.
-- obj:addSkidmarkSegment(x1,y1,z1, x2,y2,z2, nx,ny,nz, width, r,g,b,a)
-- All wrapped in pcall so failure is silent on any BeamNG build.
local function emitSegment(x1, y1, z1, x2, y2, z2)
    pcall(function()
        obj:addSkidmarkSegment(
            x1, y1, z1,
            x2, y2, z2,
            0, 0, 1,             -- upward surface normal
            cfg.markWidth,
            0.75, 0.02, 0.02, 1.0  -- deep red, fully opaque
        )
    end)
end


-- ── jbeam lifecycle ────────────────────────────────────────────────────────────

local function init(jbeamData)
    cfg.groundClearance   = jbeamData.skidGroundClearance   or cfg.groundClearance
    cfg.bodyFlatThreshold = jbeamData.skidBodyFlatThreshold or cfg.bodyFlatThreshold
    cfg.speedThreshold    = jbeamData.skidSpeedThreshold    or cfg.speedThreshold
    cfg.vertVelThreshold  = jbeamData.skidVertVelThreshold  or cfg.vertVelThreshold
    cfg.sampleInterval    = jbeamData.skidSampleInterval    or cfg.sampleInterval
    cfg.markWidth         = jbeamData.skidMarkWidth         or cfg.markWidth
    cfg.debugMode         = jbeamData.skidDebugMode         or cfg.debugMode
    cfg.trackNodeName     = jbeamData.skidTrackNodeName     or cfg.trackNodeName
    cfg.bodyNodeName      = jbeamData.skidBodyNodeName      or cfg.bodyNodeName

    trackCid  = nil
    chestCid  = nil
    rawNodeIds = {}

    for _, n in pairs(v.data.nodes) do
        table.insert(rawNodeIds, n.cid)
        if n.name == cfg.trackNodeName then trackCid = n.cid end
        if n.name == cfg.bodyNodeName  then chestCid = n.cid end
    end

    if not trackCid and #rawNodeIds > 0 then trackCid = rawNodeIds[1] end
    if not chestCid and #rawNodeIds > 0 then chestCid = rawNodeIds[1] end

    sampleTimer  = 0.0
    prevPos      = nil
    prevZ        = nil
    isSliding    = false
    lastMarkPos  = nil

    if cfg.debugMode then
        log("I", "jonesingSkidTracker", "init() trackCid=" .. tostring(trackCid)
            .. " chestCid=" .. tostring(chestCid))
    end
end


local function reset()
    sampleTimer  = 0.0
    prevPos      = nil
    prevZ        = nil
    isSliding    = false
    lastMarkPos  = nil
end


-- ── Per-frame update ──────────────────────────────────────────────────────────

local function updateGFX(dt)
    if dt <= 0 then return end
    if not trackCid or not chestCid then return end

    -- ── 1. Node positions ───────────────────────────────────────────────────
    local tPos = vec3(obj:getNodePosition(trackCid))
    local cPos = vec3(obj:getNodePosition(chestCid))

    -- ── 2. Per-frame velocity ───────────────────────────────────────────────
    local hSpeed = 0.0
    local vVel   = 0.0
    if prevPos and dt > 0 then
        local dx = tPos.x - prevPos.x
        local dy = tPos.y - prevPos.y
        hSpeed = math.sqrt(dx * dx + dy * dy) / dt
    end
    if prevZ then
        vVel = (tPos.z - prevZ) / dt
    end

    -- ── 3. Ground-contact check ─────────────────────────────────────────────
    local surfH   = getSurfaceHeight(tPos.x, tPos.y, tPos.z + 2.0)
    local grounded
    if surfH then
        grounded = (tPos.z - surfH) < cfg.groundClearance
    else
        grounded = (math.abs(vVel) < 2.0)
    end

    -- ── 4. Detection gates ──────────────────────────────────────────────────
    local heightDiff = cPos.z - tPos.z
    local bodyFlat   = (heightDiff < cfg.bodyFlatThreshold)
    local moving     = (hSpeed    >= cfg.speedThreshold)
    local notFlying  = (vVel      <  cfg.vertVelThreshold)

    local wasSliding = isSliding
    isSliding = bodyFlat and grounded and moving and notFlying

    if cfg.debugMode and (isSliding ~= wasSliding) then
        log("I", "jonesingSkidTracker", string.format(
            "sliding=%s  hSpeed=%.2f  heightDiff=%.2f  vVel=%.2f  grounded=%s",
            tostring(isSliding), hSpeed, heightDiff, vVel, tostring(grounded)))
    end

    -- ── 5. Emit skidmark segments ───────────────────────────────────────────
    sampleTimer = sampleTimer + dt

    if isSliding and sampleTimer >= cfg.sampleInterval then
        sampleTimer = 0.0
        -- Pin the mark to the surface (or foot Z if surface unavailable)
        local markZ  = surfH and (surfH + 0.012) or tPos.z
        local curPos = vec3(tPos.x, tPos.y, markZ)

        if lastMarkPos then
            local dx = curPos.x - lastMarkPos.x
            local dy = curPos.y - lastMarkPos.y
            if (dx * dx + dy * dy) > 0.0009 then  -- > 3 cm movement between samples
                emitSegment(
                    lastMarkPos.x, lastMarkPos.y, lastMarkPos.z,
                    curPos.x,      curPos.y,      curPos.z
                )
                if cfg.debugMode then
                    log("I", "jonesingSkidTracker", string.format(
                        "  mark (%.2f,%.2f)→(%.2f,%.2f)",
                        lastMarkPos.x, lastMarkPos.y, curPos.x, curPos.y))
                end
            end
        end
        lastMarkPos = curPos
    end

    if not isSliding then
        lastMarkPos = nil
        sampleTimer = 0.0
    end

    -- Store previous-frame state
    prevPos = vec3(tPos.x, tPos.y, tPos.z)
    prevZ   = tPos.z
end


-- ── Public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
