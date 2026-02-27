-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- bloodSmearStreaks.lua
-- GE-side extension: watches spawned pedestrian dummies for "grounded + sliding"
-- and emits projected DecalRoad strip segments to simulate red blood smears.
--
-- Loaded automatically by BeamNG as a GE Lua extension because it lives in
-- lua/ge/extensions/.  No core-file edits required.
--
-- Usage: the extension self-registers via onExtensionLoaded and hooks into the
-- standard BeamNG update and vehicle event callbacks.

local M = {}

-- ── Config (tune these without touching logic) ────────────────────────────────

local CFG = {
  -- Detection thresholds
  -- NOTE: set very low so any moving dummy generates streaks (easy debug mode).
  -- Raise SMEAR_MIN_SPEED (e.g. 2.5) and lower GROUND_MAX_DIST (e.g. 0.7) for
  -- production tightness once streaks are confirmed working.
  SMEAR_MIN_SPEED    = 0.1,    -- m/s  – nearly any motion triggers smearing
  GROUND_MAX_DIST    = 3.0,    -- m    – very lenient; dummy is always "grounded"
  RAY_ORIGIN_OFFSET  = 0.5,    -- m    – raycast start above dummy position

  -- Emission spacing (emits one segment every DIST_STEP metres travelled while smearing)
  DIST_STEP          = 0.05,   -- m    – very frequent segments for debug visibility

  -- Decal segment size (metres)
  SEG_LENGTH         = 1.5,    -- m  (long, easy to spot)
  SEG_WIDTH          = 0.8,    -- m  (wide, easy to spot)
  SEG_ZOFFSET        = 0.02,   -- m  (above ground to avoid z-fighting)

  -- Random variation
  SCALE_JITTER       = 0.15,   -- ±fraction of random scale jitter per segment

  -- Cleanup
  MAX_SEGMENTS       = 800,    -- hard cap across all dummies
  SEGMENT_TTL        = 120,    -- seconds before a segment is removed (0 = no TTL)

  -- Material (must match the name in blood_smear.material.json)
  MATERIAL_NAME      = "bloodSmearDecal",

  -- Debug: set true to see per-segment log lines and error details in the console
  DEBUG              = true,
}

-- ── Internal state ─────────────────────────────────────────────────────────────

-- Per-dummy tracking table, keyed by vehicle object ID.
-- Each entry: { lastEmitPos, lastPos, smearing, totalEmitted }
local dummyState = {}

-- Ring buffer of spawned DecalRoad object IDs + creation time for TTL/cap cleanup.
-- Each entry: { id = <sceneObjectId>, t = <gameTime> }
local segments   = {}
local totalSegs  = 0

-- Cached game time (updated each onPreRender / update tick)
local gameTime      = 0
local cleanupTimer  = 0   -- seconds since last cleanup pass

-- ── Helpers ────────────────────────────────────────────────────────────────────

--- Returns the ground contact point directly below `pos`, or nil if too far.
--- Uses castRayStatic which tests against static geometry (terrain + road meshes).
local function getGroundPoint(pos)
  local rayStart = vec3(pos.x, pos.y, pos.z + CFG.RAY_ORIGIN_OFFSET)
  local rayDir   = vec3(0, 0, -1)
  local maxDist  = CFG.GROUND_MAX_DIST + CFG.RAY_ORIGIN_OFFSET
  local hitDist  = castRayStatic(rayStart, rayDir, maxDist)
  if not hitDist or hitDist <= 0 then return nil end
  -- Reject if the hit is beyond our max distance from the original pos
  if (hitDist - CFG.RAY_ORIGIN_OFFSET) > CFG.GROUND_MAX_DIST then return nil end
  return vec3(pos.x, pos.y, rayStart.z - hitDist + CFG.SEG_ZOFFSET)
end

--- Register a vehicle for smear tracking if it hasn't been registered yet.
local function registerVehicle(vehId)
  if not vehId or dummyState[vehId] then return end
  dummyState[vehId] = {
    smearing     = false,
    lastEmitPos  = nil,
    lastPos      = nil,   -- previous position for speed calculation via delta
    totalEmitted = 0,
  }
  if CFG.DEBUG then
    log("I", "bloodSmearStreaks", "Registered vehicle id=" .. tostring(vehId))
  end
end

--- Remove a DecalRoad segment by scene-object ID.
local function removeSegment(id)
  local ok, err = pcall(function()
    local obj = scenetree.findObjectById(id)
    if obj then obj:delete() end
  end)
  if not ok and CFG.DEBUG then
    log("W", "bloodSmearStreaks", "removeSegment error: " .. tostring(err))
  end
end

--- Clean up old segments: enforce MAX_SEGMENTS cap and optional TTL.
local function cleanupSegments()
  -- TTL pass
  if CFG.SEGMENT_TTL > 0 then
    local i = 1
    while i <= #segments do
      local s = segments[i]
      if (gameTime - s.t) > CFG.SEGMENT_TTL then
        removeSegment(s.id)
        table.remove(segments, i)
        totalSegs = totalSegs - 1
      else
        i = i + 1
      end
    end
  end

  -- Hard-cap pass (remove oldest first)
  while totalSegs > CFG.MAX_SEGMENTS and #segments > 0 do
    local s = table.remove(segments, 1)
    removeSegment(s.id)
    totalSegs = totalSegs - 1
  end
end

--- Spawn a single DecalRoad strip segment between two ground points.
--- node0 = previous sample ground point, node1 = current sample ground point.
--- Returns the new scene-object ID or nil on failure.
local function spawnSegment(node0, node1)
  local ok, result = pcall(function()
    -- Random scale variation
    local scaleJitter = 1.0 + (math.random() - 0.5) * 2.0 * CFG.SCALE_JITTER
    local width  = CFG.SEG_WIDTH  * scaleJitter
    local texLen = CFG.SEG_LENGTH * scaleJitter

    -- Build a unique TorqueScript name for later lookup/deletion.
    -- Use a counter suffix so two segments spawned in the same millisecond are distinct.
    local segName = string.format("bsSmear_%d_%d", math.floor(gameTime * 1000), math.random(0, 999999))

    -- Create the DecalRoad via TorqueScript eval.
    -- "new DecalRoad(name) { ... };" creates the object; "MissionGroup.add(name);" adds it
    -- to the scene root; then addNode populates the two-node strip geometry.
    local tsCode = string.format(
      'new DecalRoad(%s) { material = "%s"; width = %f; textureLength = %f;'
      .. ' breakAngle = 0; renderPriority = 10; };'
      .. ' MissionGroup.add(%s);'
      .. ' %s.addNode("%f %f %f", %f);'
      .. ' %s.addNode("%f %f %f", %f);',
      segName, CFG.MATERIAL_NAME, width, texLen,
      segName,
      segName, node0.x, node0.y, node0.z, width,
      segName, node1.x, node1.y, node1.z, width
    )

    if CFG.DEBUG then
      log("D", "bloodSmearStreaks", "TorqueScript: " .. tsCode)
    end

    -- Engine.evalTorqueScript is the primary API; TorqueScript.eval is the legacy alias.
    if Engine and Engine.evalTorqueScript then
      Engine.evalTorqueScript(tsCode)
    elseif TorqueScript and TorqueScript.eval then
      TorqueScript.eval(tsCode)
    else
      -- Last resort: bare global, some BeamNG versions expose this directly
      local ok3, err3 = pcall(evalTorqueScript, tsCode)
      if not ok3 and CFG.DEBUG then
        log("E", "bloodSmearStreaks", "All TorqueScript eval methods failed: " .. tostring(err3))
      end
    end

    local road = scenetree.findObject(segName)
    if not road then
      if CFG.DEBUG then
        log("W", "bloodSmearStreaks", "scenetree.findObject returned nil for " .. segName)
      end
      return nil
    end

    if CFG.DEBUG then
      log("D", "bloodSmearStreaks",
        string.format("OK id=%s  n0=(%.1f,%.1f,%.1f) n1=(%.1f,%.1f,%.1f) w=%.2f",
          tostring(road:getId()), node0.x, node0.y, node0.z,
          node1.x, node1.y, node1.z, width))
    end

    return road:getId()
  end)

  if not ok then
    if CFG.DEBUG then
      log("W", "bloodSmearStreaks", "spawnSegment error: " .. tostring(result))
    end
    return nil
  end
  return result
end

-- ── Per-dummy update ──────────────────────────────────────────────────────────

--- Called each tick for every tracked vehicle.
local function updateDummy(veh, state, dt)
  if not veh then return end

  local pos = veh:getPosition()
  if not pos then return end
  local posV = vec3(pos.x, pos.y, pos.z)

  -- Speed: computed from position delta so it works on all vehicle types
  -- (avoids relying on veh:getVelocity() which may not exist on GE-side objects).
  local speed = 0
  if state.lastPos and dt > 0 then
    local dx = posV.x - state.lastPos.x
    local dy = posV.y - state.lastPos.y
    local dz = posV.z - state.lastPos.z
    speed = math.sqrt(dx*dx + dy*dy + dz*dz) / dt
  end
  state.lastPos = posV

  -- Ground raycast
  local groundPt = getGroundPoint(posV)

  -- Smear condition: fast enough AND grounded
  local smearing = (speed >= CFG.SMEAR_MIN_SPEED) and (groundPt ~= nil)

  if CFG.DEBUG then
    -- Log every 60 frames so we can see detection state throughout the vehicle's lifecycle
    if not state._dbgFrames then state._dbgFrames = 0 end
    state._dbgFrames = state._dbgFrames + 1
    if state._dbgFrames <= 5 or state._dbgFrames % 60 == 0 then
      log("D", "bloodSmearStreaks",
        string.format("veh %s: speed=%.2f smearing=%s groundPt=%s emitted=%d",
          tostring(veh:getId()), speed, tostring(smearing),
          groundPt and string.format("(%.1f,%.1f,%.1f)", groundPt.x, groundPt.y, groundPt.z) or "nil",
          state.totalEmitted or 0))
    end
  end

  if not smearing then
    state.smearing = false
    return
  end

  -- First frame of smearing: initialise lastEmitPos
  if not state.smearing or not state.lastEmitPos then
    state.smearing    = true
    state.lastEmitPos = groundPt
    return
  end

  -- Check distance since last emission
  local dx = groundPt.x - state.lastEmitPos.x
  local dy = groundPt.y - state.lastEmitPos.y
  local dist = math.sqrt(dx*dx + dy*dy)
  if dist < CFG.DIST_STEP then return end

  -- Emit segment
  local segId = spawnSegment(state.lastEmitPos, groundPt)
  if segId then
    table.insert(segments, { id = segId, t = gameTime })
    totalSegs = totalSegs + 1
    state.totalEmitted = (state.totalEmitted or 0) + 1
    if CFG.DEBUG then
      log("I", "bloodSmearStreaks",
        string.format("veh %s: seg #%d  spd=%.1f m/s dist=%.2f m total=%d",
          tostring(veh:getId()), state.totalEmitted, speed, dist, totalSegs))
    end
  end

  state.lastEmitPos = groundPt
end

-- ── BeamNG GE extension lifecycle ─────────────────────────────────────────────

--- Called by BeamNG when a new vehicle is spawned / loaded.
function M.onVehicleSpawned(vehId)
  registerVehicle(vehId)
end

--- Called by BeamNG when a vehicle is removed.
function M.onVehicleDestroyed(vehId)
  dummyState[vehId] = nil
end

--- Main update tick — called every render frame via onPreRender.
function M.onPreRender(dt)
  if dt <= 0 then return end
  gameTime = gameTime + dt

  -- Fallback scan: register any vehicles that onVehicleSpawned may have missed.
  -- be:getVehicleCount() + be:getVehicle(i) is the canonical GE iteration.
  local ok, cnt = pcall(function() return be:getVehicleCount() end)
  if ok and cnt and cnt > 0 then
    for i = 0, cnt - 1 do
      local veh = be:getVehicle(i)
      if veh then
        local id = veh:getId()
        if id then registerVehicle(id) end
      end
    end
  end

  -- Update each tracked vehicle
  for vehId, state in pairs(dummyState) do
    local veh = be:getObjectByID(vehId)
    if veh then
      local ok2, err2 = pcall(updateDummy, veh, state, dt)
      if not ok2 and CFG.DEBUG then
        log("W", "bloodSmearStreaks", "updateDummy error veh " .. tostring(vehId) .. ": " .. tostring(err2))
      end
    else
      dummyState[vehId] = nil
    end
  end

  -- Periodic cleanup every 2 s (dedicated timer avoids fmod drift at varying dt)
  cleanupTimer = cleanupTimer + dt
  if cleanupTimer >= 2.0 then
    cleanupTimer = 0
    cleanupSegments()
  end
end

--- Called when the extension is first loaded.
function M.onExtensionLoaded()
  log("I", "bloodSmearStreaks",
    string.format("Blood smear streaks loaded  MIN_SPEED=%.1f GROUND_DIST=%.1f DIST_STEP=%.2f DEBUG=%s",
      CFG.SMEAR_MIN_SPEED, CFG.GROUND_MAX_DIST, CFG.DIST_STEP, tostring(CFG.DEBUG)))
end

--- Called when the extension is about to be unloaded; clean up all segments.
function M.onExtensionUnloaded()
  for _, s in ipairs(segments) do
    removeSegment(s.id)
  end
  segments     = {}
  totalSegs    = 0
  dummyState   = {}
  cleanupTimer = 0
  log("I", "bloodSmearStreaks", "Blood smear streaks unloaded; all segments removed.")
end

return M
