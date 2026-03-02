-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- lua/ge/extensions/jonesingGtaEffects.lua
-- GTA-style hit effects (blood particles, scream sound, impact flash) for the
-- Jonesing pedestrian NPC.
--
-- Creation pattern mirrors lua/ge/extensions/editor/createObjectTool.lua:
--   worldEditorCppApi.createObject(classname) → Sim.upcast → setField → registerObject
--
-- Objects created here:
--
--   ParticleEmitterNode  (blood/impact sparks)
--     dataBlock = "lightExampleEmitterNodeData1"
--     emitter   = "BNGP_23"   ← matches the SKIN/blood-red entry added to
--                                lua/common/particles.json
--     Destroyed after BLOOD_DURATION seconds.
--
--   SFXEmitter  (ambient scream, one-shot)
--     playOnce  = 1
--     profile   = SCREAM_PROFILE  (configure below; must reference a valid
--                                  SFXProfile datablock in the level or mod)
--     Destroyed after SCREAM_DURATION seconds.
--
--   PointLight  (brief red flash at impact point)
--     color     = "1 0.1 0.1 1"   ← deep red
--     brightness = 4
--     range     = 3
--     Destroyed after FLASH_DURATION seconds.
--
-- The module is loaded lazily via obj:queueGameEngineLua() from the
-- jonesingGtaNpc vehicle controller when it transitions to "standing" state
-- (i.e. the pedestrian dummy has been struck by a vehicle).

local M = {}
local TAG = "jonesingGtaEffects"

-- ── tunables ───────────────────────────────────────────────────────────────────
local BLOOD_DURATION  = 2.0   -- seconds the particle emitter lives
local SCREAM_DURATION = 3.0   -- seconds the SFXEmitter lives
local FLASH_DURATION  = 0.3   -- seconds the PointLight flash lives

-- SFXProfile to use for the pedestrian scream.
-- Set to the name of an SFXProfile datablock available in the level or mod.
-- If nil or the datablock is not found, no sound emitter is created.
-- Example: "AudioHandle_PlayerVehicle_DamageHigh" (built-in BeamNG profile)
local SCREAM_PROFILE  = nil   -- replace with a valid SFXProfile name if available

-- Check interval for the cleanup tick (seconds between sweeps)
local CHECK_INTERVAL  = 0.25

-- ── internal state ─────────────────────────────────────────────────────────────
-- _pending: list of {deleteAt=<timestamp>, objId=<sim object id>}
-- Timestamps use os.clock() — consistent with propRecycler.lua in this mod.
local _pending = {}
local _accum   = 0

local function logI(msg, ...) log("I", TAG, select('#', ...) > 0 and string.format(msg, ...) or msg) end
local function logW(msg, ...) log("W", TAG, select('#', ...) > 0 and string.format(msg, ...) or msg) end
local function logD(msg, ...) log("D", TAG, select('#', ...) > 0 and string.format(msg, ...) or msg) end

-- ── helpers ────────────────────────────────────────────────────────────────────

-- Create a runtime scene object using the same API as createObjectTool.lua.
-- Returns the Sim-upcast instance, or nil on failure.
local function createSceneObject(classname)
  if not worldEditorCppApi then
    logW("worldEditorCppApi unavailable; cannot create %s", classname)
    return nil
  end
  local raw = worldEditorCppApi.createObject(classname)
  if not raw then
    logW("createObject returned nil for %s", classname)
    return nil
  end
  local obj = Sim.upcast(raw)
  if not obj then
    logW("Sim.upcast failed for %s", classname)
    return nil
  end
  return obj
end

-- Register a created object, add it to MissionGroup, set its world position,
-- and schedule it for deletion after `duration` seconds.
local function finaliseAndSchedule(obj, pos, duration)
  obj:registerObject("")
  scenetree.MissionGroup:add(obj)
  obj:setPosition(vec3(pos.x, pos.y, pos.z))
  table.insert(_pending, {deleteAt = os.clock() + duration, objId = obj:getID()})
end

-- ── public API ─────────────────────────────────────────────────────────────────

--- Spawn a blood/impact particle effect at the given world position.
-- Uses ParticleEmitterNode with the BNGP_23 emitter (skin/blood-red sparks),
-- mirroring the buildParticleEmitter pattern in createObjectTool.lua.
-- The emitter is automatically destroyed after BLOOD_DURATION seconds.
-- @param px  world X coordinate
-- @param py  world Y coordinate
-- @param pz  world Z coordinate
function M.spawnBloodEffect(px, py, pz)
  local obj = createSceneObject("ParticleEmitterNode")
  if not obj then return end

  -- Mirror buildParticleEmitter() from createObjectTool.lua:
  --   dataBlock points to the standard emitter node data (used for all
  --   in-editor particle emitters).
  --   emitter = "BNGP_23" matches the SKIN vs METAL/ASPHALT collision
  --   particle added to lua/common/particles.json.
  obj:setField("dataBlock", 0, "lightExampleEmitterNodeData1")
  obj:setField("emitter", 0, "BNGP_23")

  -- setEmitterDataBlock is the live-update counterpart to setField("emitter")
  -- (same call as in buildParticleEmitter).
  local emitterDb = scenetree.findObject("BNGP_23")
  if emitterDb and obj.setEmitterDataBlock then
    obj:setEmitterDataBlock(emitterDb)
  end

  -- Offset 0.2 m off the surface, matching the offsetFromSurface table in
  -- createObjectTool.lua for ParticleEmitterNode.
  finaliseAndSchedule(obj, {x = px, y = py, z = pz + 0.2}, BLOOD_DURATION)
  logD("Blood ParticleEmitterNode id=%d at (%.2f,%.2f,%.2f)", obj:getID(), px, py, pz)
end

--- Spawn a one-shot scream SFXEmitter at the given world position.
-- The emitter is automatically destroyed after SCREAM_DURATION seconds.
-- Requires SCREAM_PROFILE to be set to a valid SFXProfile datablock name.
-- @param px  world X coordinate
-- @param py  world Y coordinate
-- @param pz  world Z coordinate
function M.spawnScreamSound(px, py, pz)
  if not SCREAM_PROFILE then
    logD("SCREAM_PROFILE not configured; skipping SFXEmitter creation")
    return
  end

  -- Verify the SFXProfile datablock exists before creating the emitter.
  local profile = scenetree.findObject(SCREAM_PROFILE)
  if not profile then
    logW("SFXProfile '%s' not found in scenetree; skipping scream sound", SCREAM_PROFILE)
    return
  end

  local obj = createSceneObject("SFXEmitter")
  if not obj then return end

  -- SFXEmitter fields (createObjectTool.lua creates SFXEmitter with no
  -- buildFunc, so all fields are at their defaults; we add what we need):
  obj:setField("profile",              0, SCREAM_PROFILE)
  obj:setField("playOnce",             0, "1")   -- one-shot: destroy after playing
  obj:setField("useTrackDescriptions", 0, "0")   -- use direct profile, not track

  -- Offset 0.2 m off surface (matches offsetFromSurface["SFXEmitter"] in
  -- createObjectTool.lua).
  finaliseAndSchedule(obj, {x = px, y = py, z = pz + 0.2}, SCREAM_DURATION)
  logD("Scream SFXEmitter id=%d at (%.2f,%.2f,%.2f)", obj:getID(), px, py, pz)
end

--- Spawn a brief red PointLight impact flash at the given world position.
-- The light is automatically destroyed after FLASH_DURATION seconds.
-- @param px  world X coordinate
-- @param py  world Y coordinate
-- @param pz  world Z coordinate
function M.spawnImpactFlash(px, py, pz)
  local obj = createSceneObject("PointLight")
  if not obj then return end

  -- buildLight() in createObjectTool.lua is a no-op (returns true with no
  -- field overrides), so we set our own dramatic blood-red flash values.
  obj:setField("color",      0, "1 0.1 0.1 1")  -- deep red
  obj:setField("brightness", 0, "4")
  obj:setField("range",      0, "3")
  obj:setField("castShadows",0, "0")             -- no shadow for a brief flash

  -- Offset 0.2 m (matches offsetFromSurface["PointLight"] in createObjectTool.lua).
  finaliseAndSchedule(obj, {x = px, y = py, z = pz + 0.2}, FLASH_DURATION)
  logD("Impact PointLight id=%d at (%.2f,%.2f,%.2f)", obj:getID(), px, py, pz)
end

--- Spawn all GTA-style hit effects (blood particles + scream + flash) at once.
-- This is the single entry-point called from jonesingGtaNpc via queueGameEngineLua.
-- @param px  world X of the impact point
-- @param py  world Y of the impact point
-- @param pz  world Z of the impact point
function M.spawnHitEffects(px, py, pz)
  M.spawnBloodEffect(px, py, pz)
  M.spawnScreamSound(px, py, pz)
  M.spawnImpactFlash(px, py, pz)
end

-- ── lifecycle / cleanup tick ──────────────────────────────────────────────────

function M.onUpdate(dt)
  if #_pending == 0 then return end
  _accum = _accum + dt
  if _accum < CHECK_INTERVAL then return end
  _accum = 0

  local now       = os.clock()
  local remaining = {}
  for _, entry in ipairs(_pending) do
    if now >= entry.deleteAt then
      -- Prefer findObjectById (editor API) with scenetree fallback.
      local o = scenetree.findObjectById and scenetree.findObjectById(entry.objId)
                or scenetree.findObjectByID and scenetree.findObjectByID(entry.objId)
      if o then
        o:delete()
        logD("Deleted effect object id=%d", entry.objId)
      end
    else
      table.insert(remaining, entry)
    end
  end
  _pending = remaining
end

function M.onExtensionLoaded()
  logI("Loaded. Call jonesingGtaEffects.spawnHitEffects(x,y,z) to trigger effects.")
end

return M
