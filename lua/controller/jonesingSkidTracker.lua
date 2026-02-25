-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingSkidTracker.lua
-- Leaves red blood streaks on the ground whenever the dummy ragdoll slides
-- on any surface.  Works in freeroam with spawned dummies.
--
-- Rendering path:
--   obj:queueGameEngineLua()  →  game-engine (GE) Lua context
--   GE Lua: Engine.Render.DecalMgr.addDecalTangent()
--
--   This is the same decal-manager that BeamNG uses for persistent road marks
--   placed by the world editor.  Decals cull and fade with distance identically
--   to tire skidmarks.  The "blood_skid" DecalData is registered by BeamNG's
--   C++ ground-model system when it loads our art/groundModels/flesh.json
--   (which specifies  "skidmarkColorDecal": "blood_skid").
--
-- Detection (all must be true simultaneously):
--   (a) Body flat   — chestZ - torsoZ < bodyFlatThreshold (default 1.10 m)
--   (b) On ground   — torso Z within groundClearance (default 0.40 m) of surface
--   (c) Moving      — horizontal speed ≥ speedThreshold (default 0.25 m/s)
--   (d) Not flying  — upward vertical velocity < vertVelThreshold (default 4 m/s)
--
-- Tunable params (jbeam slot entry, all optional):
--   skidGroundClearance   (default 0.40  m)
--   skidBodyFlatThreshold (default 1.10  m)
--   skidSpeedThreshold    (default 0.25 m/s)
--   skidVertVelThreshold  (default 4.00 m/s)
--   skidSampleInterval    (default 0.04  s)   ~25 Hz
--   skidMarkWidth         (default 0.50  m)   scale passed to DecalMgr
--   skidDebugMode         (default false)
--   skidTrackNodeName     (default "dummy1_L_footbmr")
--   skidBodyNodeName      (default "dummy1_thoraxtfl")

local M = {}

-- ── Configuration ──────────────────────────────────────────────────────────────
local cfg = {
    groundClearance    = 0.40,
    bodyFlatThreshold  = 1.10,
    speedThreshold     = 0.25,
    vertVelThreshold   = 4.00,
    sampleInterval     = 0.04,
    markWidth          = 0.50,   -- larger = more visible; passed as DecalMgr scale
    debugMode          = false,
    trackNodeName      = "dummy1_L_footbmr",
    bodyNodeName       = "dummy1_thoraxtfl",
}

-- ── Internal state ─────────────────────────────────────────────────────────────
local trackCid   = nil
local chestCid   = nil
local rawNodeIds = {}
local sampleTimer = 0.0
local prevPos    = nil   -- vec3: previous-frame position of trackNode
local prevZ      = nil   -- float: previous-frame Z for vertical-velocity estimate
local isSliding  = false
local lastDx     = 1.0   -- last known slide direction X (for tangent vector)
local lastDy     = 0.0   -- last known slide direction Y


-- ── Helpers ────────────────────────────────────────────────────────────────────

local function getSurfaceHeight(x, y, z)
    local ok, h = pcall(function()
        return be:getSurfaceHeightBelow(x, y, z)
    end)
    return (ok and type(h) == "number") and h or nil
end

-- Place one decal stamp at world-space (x,y,z), oriented along (dx,dy).
-- Executes in the GE Lua context via queueGameEngineLua, where the real
-- DecalMgr lives.  The template ("blood_skid") is looked up lazily on first
-- call and cached in the global `jonesingBloodSkidTmpl`.
-- Signature:  Engine.Render.DecalMgr.addDecalTangent(
--               pos, normal, tangent, template, scale, texIndex, flags, alpha)
local function emitMark(x, y, z, dx, dy)
    local dlen = math.sqrt(dx*dx + dy*dy)
    if dlen < 0.001 then dx, dy = 1.0, 0.0 else dx, dy = dx/dlen, dy/dlen end

    pcall(function()
        obj:queueGameEngineLua(string.format(
            'if not jonesingBloodSkidTmpl then'
            .. ' jonesingBloodSkidTmpl=scenetree.findObject("blood_skid") end;'
            .. ' if jonesingBloodSkidTmpl then'
            .. ' Engine.Render.DecalMgr.addDecalTangent('
            .. 'vec3(%f,%f,%f),vec3(0,0,1),vec3(%f,%f,0),'
            .. 'jonesingBloodSkidTmpl,%f,-1,0,1.0) end',
            x, y, z, dx, dy, cfg.markWidth
        ))
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

    sampleTimer = 0.0
    prevPos     = nil
    prevZ       = nil
    isSliding   = false
    lastDx      = 1.0
    lastDy      = 0.0

    if cfg.debugMode then
        log("I", "jonesingSkidTracker", "init() trackCid=" .. tostring(trackCid)
            .. " chestCid=" .. tostring(chestCid))
    end
end


local function reset()
    sampleTimer = 0.0
    prevPos     = nil
    prevZ       = nil
    isSliding   = false
    lastDx      = 1.0
    lastDy      = 0.0
end


-- ── Per-frame update ───────────────────────────────────────────────────────────

local function updateGFX(dt)
    if dt <= 0 then return end
    if not trackCid or not chestCid then return end

    -- 1. Node positions
    local tPos = vec3(obj:getNodePosition(trackCid))
    local cPos = vec3(obj:getNodePosition(chestCid))

    -- 2. Per-frame velocity
    local hSpeed = 0.0
    local vVel   = 0.0
    if prevPos then
        local dx = tPos.x - prevPos.x
        local dy = tPos.y - prevPos.y
        hSpeed = math.sqrt(dx*dx + dy*dy) / dt
        if hSpeed > 0.01 then lastDx, lastDy = dx, dy end  -- keep last non-zero direction
    end
    if prevZ then
        vVel = (tPos.z - prevZ) / dt
    end

    -- 3. Ground contact
    local surfH = getSurfaceHeight(tPos.x, tPos.y, tPos.z + 2.0)
    local grounded
    if surfH then
        grounded = (tPos.z - surfH) < cfg.groundClearance
    else
        grounded = (math.abs(vVel) < 2.0)
    end

    -- 4. Detection gates
    local bodyFlat  = (cPos.z - tPos.z)  < cfg.bodyFlatThreshold
    local moving    = hSpeed              >= cfg.speedThreshold
    local notFlying = vVel               <  cfg.vertVelThreshold

    local wasSliding = isSliding
    isSliding = bodyFlat and grounded and moving and notFlying

    if cfg.debugMode and (isSliding ~= wasSliding) then
        log("I", "jonesingSkidTracker", string.format(
            "sliding=%s  hSpeed=%.2f  hDiff=%.2f  vVel=%.2f  grounded=%s",
            tostring(isSliding), hSpeed, cPos.z - tPos.z, vVel, tostring(grounded)))
    end

    -- 5. Emit marks at regular intervals while sliding
    sampleTimer = sampleTimer + dt

    if isSliding and sampleTimer >= cfg.sampleInterval then
        sampleTimer = 0.0
        local markZ = surfH and (surfH + 0.01) or tPos.z
        emitMark(tPos.x, tPos.y, markZ, lastDx, lastDy)

        if cfg.debugMode then
            log("I", "jonesingSkidTracker", string.format(
                "  mark @ (%.2f,%.2f,%.2f)", tPos.x, tPos.y, markZ))
        end
    end

    if not isSliding then
        sampleTimer = 0.0
    end

    -- Store previous-frame state
    prevPos = vec3(tPos.x, tPos.y, tPos.z)
    prevZ   = tPos.z
end


-- ── Public interface ───────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
