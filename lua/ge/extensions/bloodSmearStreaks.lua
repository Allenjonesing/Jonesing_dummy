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
  SMEAR_MIN_SPEED    = 2.5,    -- m/s  – dummy must be sliding faster than this
  GROUND_MAX_DIST    = 0.7,    -- m    – raycast down must hit within this distance
  RAY_ORIGIN_OFFSET  = 0.5,    -- m    – raycast start above dummy position

  -- Emission spacing (emits one segment every DIST_STEP metres travelled while smearing)
  DIST_STEP          = 0.25,   -- m

  -- Decal segment size (metres)
  SEG_LENGTH         = 0.65,   -- m  (along motion direction / UV texture length)
  SEG_WIDTH          = 0.22,   -- m  (DecalRoad strip width)
  SEG_ZOFFSET        = 0.015,  -- m  (above ground to avoid z-fighting)

  -- Random variation
  SCALE_JITTER       = 0.15,   -- ±fraction of random scale jitter per segment

  -- Cleanup
  MAX_SEGMENTS       = 800,    -- hard cap across all dummies
  SEGMENT_TTL        = 120,    -- seconds before a segment is removed (0 = no TTL)

  -- Material (must match the name in blood_smear.material.json)
  MATERIAL_NAME      = "bloodSmearDecal",

  -- Debug
  DEBUG              = false,
}

-- ── Internal state ─────────────────────────────────────────────────────────────

-- Per-dummy tracking table, keyed by vehicle object ID.
-- Each entry: { lastEmitPos, lastEmitTime, smearing, totalEmitted }
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
  local hitDist  = castRayStatic(rayStart, rayDir, CFG.GROUND_MAX_DIST + CFG.RAY_ORIGIN_OFFSET)
  if not hitDist or hitDist <= 0 then return nil end
  -- Reject if the hit is beyond our max distance from the original pos
  local distFromPos = hitDist - CFG.RAY_ORIGIN_OFFSET
  if distFromPos > CFG.GROUND_MAX_DIST then return nil end
  return vec3(
    pos.x,
    pos.y,
    rayStart.z - hitDist + CFG.SEG_ZOFFSET
  )
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

    -- Build a unique TorqueScript name for later lookup/deletion
    local segName = string.format("bsSmear_%d_%d", math.floor(gameTime * 1000), math.random(0, 999999))

    -- Create the DecalRoad via TorqueScript eval so it works both in-game
    -- and when the World Editor is open, without requiring core-file edits.
    local tsCode = string.format(
      'new DecalRoad(%s) { material = "%s"; width = %f; textureLength = %f;'
      .. ' breakAngle = 0; renderPriority = 10; }; MissionGroup.add(%s);'
      .. ' %s.addNode("%f %f %f", %f); %s.addNode("%f %f %f", %f);',
      segName, CFG.MATERIAL_NAME, width, texLen,
      segName,
      segName, node0.x, node0.y, node0.z, width,
      segName, node1.x, node1.y, node1.z, width
    )
    TorqueScript.eval(tsCode)

    local road = scenetree.findObject(segName)
    if not road then return nil end

    if CFG.DEBUG then
      log("D", "bloodSmearStreaks",
        string.format("Segment spawned id=%s n0=(%.2f,%.2f,%.2f) n1=(%.2f,%.2f,%.2f) w=%.3f",
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

--- Called each tick for every tracked dummy vehicle.
--- `veh`   – BeamNG vehicle object
--- `state` – our per-dummy tracking table entry
local function updateDummy(veh, state, dt)
  if not veh then return end

  -- Get current position of the vehicle's reference node (or body centre)
  local pos = veh:getPosition()
  if not pos then return end
  local posV = vec3(pos.x, pos.y, pos.z)

  -- Get velocity magnitude
  local vel = veh:getVelocity()
  local speed = 0
  if vel then
    speed = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)
  end

  -- Ground raycast
  local groundPt = getGroundPoint(posV)

  -- Smear condition: fast enough AND grounded
  local smearing = (speed >= CFG.SMEAR_MIN_SPEED) and (groundPt ~= nil)

  if not smearing then
    state.smearing = false
    return
  end

  -- First frame of smearing: initialise lastEmitPos
  if not state.smearing or not state.lastEmitPos then
    state.smearing   = true
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
      log("D", "bloodSmearStreaks",
        string.format("veh %s: emitted seg #%d  speed=%.1f m/s  dist=%.2f m  totalSegs=%d",
          tostring(veh:getId()), state.totalEmitted, speed, dist, totalSegs))
    end
  end

  state.lastEmitPos = groundPt
end

-- ── BeamNG GE extension lifecycle ─────────────────────────────────────────────

--- Called by BeamNG when a new vehicle is spawned / loaded.
function M.onVehicleSpawned(vehId)
  if not vehId then return end
  -- Only track "agenty_dummy" vehicles (our pedestrian dummies).
  local veh = be:getObjectByID(vehId)
  if not veh then return end
  local jbeamName = veh:getJBeamFilename() or ""
  if not string.find(string.lower(jbeamName), "dummy") then return end

  dummyState[vehId] = {
    smearing      = false,
    lastEmitPos   = nil,
    totalEmitted  = 0,
  }
  if CFG.DEBUG then
    log("D", "bloodSmearStreaks", "Tracking new dummy vehId=" .. tostring(vehId))
  end
end

--- Called by BeamNG when a vehicle is removed.
function M.onVehicleDestroyed(vehId)
  dummyState[vehId] = nil
end

--- Main update tick — called every render frame via onPreRender.
function M.onPreRender(dt)
  if dt <= 0 then return end
  gameTime = gameTime + dt

  -- Update each tracked dummy
  for vehId, state in pairs(dummyState) do
    local veh = be:getObjectByID(vehId)
    if veh then
      updateDummy(veh, state, dt)
    else
      -- Vehicle gone — clean up entry
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

--- Called when the extension is first loaded; can be used for one-time setup.
function M.onExtensionLoaded()
  log("I", "bloodSmearStreaks", "Blood smear streaks extension loaded. MAX_SEGMENTS=" ..
    tostring(CFG.MAX_SEGMENTS) .. " TTL=" .. tostring(CFG.SEGMENT_TTL) .. "s")
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
  log("I", "bloodSmearStreaks", "Blood smear streaks extension unloaded; all segments removed.")
end

return M
