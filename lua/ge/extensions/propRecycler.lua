-- lua/ge/extensions/propRecycler.lua
-- Jonesing Prop Recycler / Lightweight Pedestrian Cycler
--
-- Main idea:
--   - Keep most pedestrians as cheap "ghost" records, not physics objects.
--   - Only activate a small number of real agenty_dummy physics props near the player.
--   - Place ghosts using traffic road sampling, then push them sideways toward sidewalk/shoulder.
--   - Recycle far ghosts ahead of the player.
--
-- Public:
--   extensions.propRecycler.spawn10DummiesAndStart(optCfg)
--   extensions.propRecycler.start(nil, optCfg)
--   extensions.propRecycler.stop()
--   extensions.propRecycler.tune(optCfg)

local M = {}
M.dependencies = {"core_vehicles"}

local TAG = "propRecycler"

local cfg = {
  -- General
  enabled = true,
  debug = true,
  verboseEvery = 10,

  -- Tick rates
  ghostUpdateInterval = 0.10,
  recycleCheckInterval = 0.35,
  activationCheckInterval = 0.20,

  -- Population
  totalGhosts = 20,
  maxActiveDummies = 3,
  dummyModel = "agenty_dummy",

  -- Distances
  minDistance = 70,
  maxDistance = 260,
  leadDistance = 150,
  activateDistance = 45,
  deactivateDistance = 95,
  emergencyFarDistance = 350,

  -- Sidewalk/shoulder placement
  sidewalkMode = true,
  sidewalkOffset = 5.75,
  sidewalkRandomExtra = 2.0,
  heightOffset = 0.85,

  -- Ghost movement
  ghostsMove = true,
  ghostWalkSpeedMin = 0.7,
  ghostWalkSpeedMax = 1.8,
  ghostTurnChance = 0.015,
  ghostCrossChance = 0.004,

  -- Physics dummy behavior
  teleportCooldownSeconds = 3.0,
  activationCooldownSeconds = 1.0,
  minActiveTime = 4.0,
  deactivateAfterSeconds = 10.0,

  -- Spawn throttling
  maxActivationsPerSecond = 1,

  -- Debug visuals
  drawGhostDebug = false,
  drawActiveDebug = false,

  -- Back compat
  cooldownTime = nil,
}

local _enabled = false
local _ghosts = {}
local _active = {} -- [dummyId] = ghostIndex
local _accGhost = 0
local _accRecycle = 0
local _accActivate = 0
local _tpCount = 0
local _lastVerb = 0
local _lastActivationAt = 0

local _pendingFocusId = nil
local _focusTimer = 0
local _focusDeadline = 0

local vecUp = vec3(0, 0, 1)
local vecY = vec3(0, 1, 0)

local function d(level, msg, ...)
  if level == "D" and not cfg.debug then return end
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  log(level, TAG, msg)
end

local function rand(a, b)
  return a + (b - a) * math.random()
end

local function asId(x)
  if type(x) == "number" then return x end
  if type(x) == "string" then
    local n = tonumber(x)
    if n then return n end
  end
  if type(x) == "userdata" or type(x) == "table" then
    local ok, n = pcall(function()
      if x.getId then return x:getId() end
      if x.id then return x.id end
      if x.obj and x.obj.getId then return x.obj:getId() end
      return nil
    end)
    if ok and n then return tonumber(n) end
  end
  return nil
end

local function playerVeh()
  return be and be:getPlayerVehicle(0) or nil
end

local function playerId()
  local id = nil
  if be and be.getPlayerVehicleID then
    pcall(function() id = be:getPlayerVehicleID(0) end)
  end
  if not id then
    local v = playerVeh()
    if v and v.getId then id = v:getId() end
  end
  return id
end

local function vBasis(veh)
  local pos = veh:getPosition()
  local fwd = veh.getDirectionVector and veh:getDirectionVector() or vec3(0, 1, 0)
  local right = nil

  if veh.getDirectionVectorSide then
    right = veh:getDirectionVectorSide()
  elseif veh.getSideVector then
    right = veh:getSideVector()
  else
    right = vec3(1, 0, 0)
  end

  return pos, fwd, right
end

local function bestForward()
  local veh = playerVeh()
  if veh then
    if veh.getVelocity then
      local vel = veh:getVelocity()
      if vel and vel:squaredLength() > 1e-4 then
        return vel:normalized()
      end
    end
    if veh.getDirectionVector then
      return veh:getDirectionVector():normalized()
    end
  end
  return vec3(1, 0, 0)
end

local function dist2(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

local function toVec3(p)
  if p and p.x then return vec3(p.x, p.y, p.z) end
  if p and p[1] then return vec3(p[1], p[2], p[3]) end
  return vec3(0, 0, 0)
end

local function toQuat(q)
  local x, y, z, w = 0, 0, 0, 1
  if q then
    x = q.x or q[1] or x
    y = q.y or q[2] or y
    z = q.z or q[3] or z
    w = q.w or q[4] or w
  end
  local m = math.sqrt(x * x + y * y + z * z + w * w)
  if m > 0 then x, y, z, w = x / m, y / z, z / m, w / m end
  return x, y, z, w
end

-- Fix bad typo risk from normalized quaternion.
local function safeQuat(q)
  local x, y, z, w = 0, 0, 0, 1
  if q then
    x = q.x or q[1] or x
    y = q.y or q[2] or y
    z = q.z or q[3] or z
    w = q.w or q[4] or w
  end
  local m = math.sqrt(x * x + y * y + z * z + w * w)
  if m > 0 then x, y, z, w = x / m, y / m, z / m, w / m end
  return quat(x, y, z, w)
end

local function groundSnap(pos, fallbackZ)
  local p = vec3(pos.x, pos.y, pos.z)

  if map and map.surfaceHeightBelow then
    local ok, z = pcall(function() return map.surfaceHeightBelow(p) end)
    if ok and z then
      p.z = z + cfg.heightOffset
      return p
    end
  end

  if fallbackZ then
    p.z = fallbackZ + cfg.heightOffset
  else
    p.z = p.z + cfg.heightOffset
  end

  return p
end

local function roadSideOffset(roadPos, roadDir)
  if not cfg.sidewalkMode then
    return groundSnap(roadPos, roadPos.z)
  end

  local dir = vec3(roadDir.x, roadDir.y, 0)
  if dir:squaredLength() < 0.0001 then
    return groundSnap(roadPos, roadPos.z)
  end

  dir = dir:normalized()
  local lateral = vec3(-dir.y, dir.x, 0)
  local side = math.random() < 0.5 and -1 or 1
  local offset = cfg.sidewalkOffset + rand(0, cfg.sidewalkRandomExtra)

  local p = roadPos + lateral * offset * side
  return groundSnap(p, roadPos.z)
end

local function makeRotFromDir(dir, pos)
  local normal = vecUp
  if map and map.surfaceNormal then
    local ok, n = pcall(function() return map.surfaceNormal(pos, 1) end)
    if ok and n then normal = n end
  end

  local d2 = vec3(dir.x, dir.y, 0)
  if d2:squaredLength() < 0.0001 then d2 = vec3(0, 1, 0) end
  d2 = d2:normalized()

  local ok, rot = pcall(function()
    return quatFromDir(vecY:rotated(quatFromDir(d2, normal)), normal)
  end)

  if ok and rot then return rot end
  return quat(0, 0, 0, 1)
end

local function sampleUsingTraffic(seedPos, seedDir, opts)
  opts = opts or {}

  if not map or not map.getMap or not map.getMap().nodes or not next(map.getMap().nodes) then
    return nil
  end

  if not gameplay_traffic_trafficUtils or not gameplay_traffic_trafficUtils.findSafeSpawnPoint then
    return nil
  end

  local minDist = opts.minDist or cfg.minDistance
  local maxDist = opts.maxDist or cfg.maxDistance
  local targetDist = opts.targetDist or cfg.leadDistance

  local pos = seedPos or core_camera.getPosition()
  local dir = seedDir or bestForward()

  local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(
    pos,
    dir,
    minDist,
    maxDist,
    targetDist,
    opts.params or {}
  )

  if not spawnData then return nil end

  local place = { legalDirection = true }
  local newPos, newDir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(
    spawnData.pos,
    spawnData.dir,
    spawnData.n1,
    spawnData.n2,
    place
  )

  if not newPos or not newDir then return nil end

  local sidewalkPos = roadSideOffset(newPos, newDir)
  local rot = makeRotFromDir(newDir, sidewalkPos)

  return {
    pos = sidewalkPos,
    dir = vec3(newDir.x, newDir.y, 0):normalized(),
    rot = rot
  }
end

local function fallbackPose(ppos, fwd, right)
  local lateral = rand(-18, 18)
  local p = vec3(
    ppos.x + fwd.x * cfg.leadDistance + right.x * lateral,
    ppos.y + fwd.y * cfg.leadDistance + right.y * lateral,
    ppos.z
  )

  p = groundSnap(p, ppos.z)
  local rot = makeRotFromDir(fwd, p)

  return {
    pos = p,
    dir = vec3(fwd.x, fwd.y, 0):normalized(),
    rot = rot
  }
end

local function getFreshPose()
  local veh = playerVeh()
  if not veh then return nil end

  local ppos, fwd, right = vBasis(veh)
  local pose = sampleUsingTraffic(ppos, fwd, {
    minDist = cfg.minDistance,
    maxDist = cfg.maxDistance,
    targetDist = cfg.leadDistance
  })

  if pose then return pose end
  return fallbackPose(ppos, fwd, right)
end

local function teleportGE(id, targetPos, targetQuat)
  local o = be:getObjectByID(id)
  if not o then return false end

  local pos = toVec3(targetPos)
  local q = safeQuat(targetQuat)

  if be.teleportVehicle then
    local ok = be:teleportVehicle(id, pos, q)
    if ok then return true end
  end

  if o.setPositionRotation then
    o:setPositionRotation(pos.x, pos.y, pos.z, q.x, q.y, q.z, q.w)
    return true
  end

  if o.setPosQuat then
    o:setPosQuat(pos.x, pos.y, pos.z, q.x, q.y, q.z, q.w)
    return true
  end

  if o.setPosition and o.setRotation then
    o:setPosition(pos)
    o:setRotation(q)
    return true
  end

  if o.setPosition then
    o:setPosition(pos)
    return true
  end

  return false
end

local function spawnDummyAt(pos, rot)
  if core_vehicles and core_vehicles.spawnNewVehicle then
    local ok, id = pcall(core_vehicles.spawnNewVehicle, cfg.dummyModel, {
      pos = toVec3(pos),
      rot = safeQuat(rot),
      paint = nil,
      partConfig = "",
      cling = false,
      autoEnterVehicle = false,
      setPlayerVehicle = false
    })
    if ok and id then return asId(id) end
  end

  if spawn and spawn.spawnVehicle then
    local ok, id = pcall(spawn.spawnVehicle, cfg.dummyModel, {
      pos = toVec3(pos),
      rot = safeQuat(rot)
    })
    if ok and id then return asId(id) end
  end

  if be and be.spawnVehicle then
    local ok, id = pcall(function()
      return be:spawnVehicle(cfg.dummyModel, toVec3(pos), safeQuat(rot))
    end)
    if ok and id then return asId(id) end
  end

  return nil
end

local function deleteObject(id)
  local o = be:getObjectByID(id)
  if not o then return end

  if o.delete then
    pcall(function() o:delete() end)
    return
  end

  if be.deleteObject then
    pcall(function() be:deleteObject(id) end)
    return
  end

  if core_vehicles and core_vehicles.removeVehicle then
    pcall(function() core_vehicles.removeVehicle(id) end)
  end
end

local function countActive()
  local n = 0
  for _ in pairs(_active) do n = n + 1 end
  return n
end

local function restoreFocusSoon()
  local id = playerId()
  if id then
    _pendingFocusId = id
    _focusTimer = 0.20
    _focusDeadline = os.clock() + 2.0
  end
end

local function runFocusRestore(dt)
  if not _pendingFocusId then return end

  _focusTimer = (_focusTimer or 0) - dt
  if _focusTimer > 0 then return end

  local cur = playerId()
  if cur == _pendingFocusId then
    _pendingFocusId, _focusTimer, _focusDeadline = nil, 0, 0
    return
  end

  pcall(function()
    if be.setPlayerVehicleID then be:setPlayerVehicleID(0, _pendingFocusId) end
    if be.enterVehicleID then be:enterVehicleID(_pendingFocusId, 0) end
    if be.enterVehicle then
      local veh = be:getObjectByID(_pendingFocusId)
      if veh then be:enterVehicle(veh, 0) end
    end
    if be.setActiveObjectID then be:setActiveObjectID(_pendingFocusId) end
  end)

  if os.clock() < (_focusDeadline or 0) then
    _focusTimer = 0.05
  else
    _pendingFocusId, _focusTimer, _focusDeadline = nil, 0, 0
  end
end

local function recycleGhost(i)
  local pose = getFreshPose()
  if not pose then return false end

  local g = _ghosts[i]
  if not g then return false end

  g.pos = pose.pos
  g.dir = pose.dir
  g.rot = pose.rot
  g.speed = rand(cfg.ghostWalkSpeedMin, cfg.ghostWalkSpeedMax)
  g.activeId = nil
  g.activeSince = nil
  g.lastRecycleAt = os.clock()

  _tpCount = _tpCount + 1
  return true
end

local function buildGhost(i)
  local pose = getFreshPose()
  if not pose then return nil end

  return {
    index = i,
    pos = pose.pos,
    dir = pose.dir,
    rot = pose.rot,
    speed = rand(cfg.ghostWalkSpeedMin, cfg.ghostWalkSpeedMax),
    activeId = nil,
    activeSince = nil,
    lastRecycleAt = os.clock(),
    nextActivationAt = 0,
  }
end

local function initGhosts()
  _ghosts = {}

  for i = 1, cfg.totalGhosts do
    local g = buildGhost(i)
    if g then
      table.insert(_ghosts, g)
    end
  end

  d("I", "Initialized %d lightweight ghosts.", #_ghosts)
end

local function updateGhosts(dt)
  if not cfg.ghostsMove then return end

  for _, g in ipairs(_ghosts) do
    if not g.activeId then
      if math.random() < cfg.ghostTurnChance then
        g.dir = g.dir * -1
        g.rot = makeRotFromDir(g.dir, g.pos)
      elseif math.random() < cfg.ghostCrossChance then
        g.dir = vec3(-g.dir.y, g.dir.x, 0):normalized()
        g.rot = makeRotFromDir(g.dir, g.pos)
      end

      g.pos = g.pos + g.dir * g.speed * dt
      g.pos = groundSnap(g.pos, g.pos.z - cfg.heightOffset)
    end
  end
end

local function activateGhost(i)
  local g = _ghosts[i]
  if not g or g.activeId then return false end

  local now = os.clock()
  if now < (g.nextActivationAt or 0) then return false end
  if now - _lastActivationAt < (1 / math.max(0.1, cfg.maxActivationsPerSecond)) then return false end
  if countActive() >= cfg.maxActiveDummies then return false end

  restoreFocusSoon()

  local id = spawnDummyAt(g.pos, g.rot)
  if not id then
    g.nextActivationAt = now + cfg.activationCooldownSeconds
    return false
  end

  g.activeId = id
  g.activeSince = now
  g.nextActivationAt = now + cfg.activationCooldownSeconds
  _active[id] = i
  _lastActivationAt = now

  d("D", "Activated ghost %d as physics dummy id=%s", i, tostring(id))
  return true
end

local function deactivateGhost(i, recycleAfter)
  local g = _ghosts[i]
  if not g or not g.activeId then return end

  local id = g.activeId
  _active[id] = nil
  deleteObject(id)

  g.activeId = nil
  g.activeSince = nil
  g.nextActivationAt = os.clock() + cfg.activationCooldownSeconds

  if recycleAfter then
    recycleGhost(i)
  end
end

local function updateActivation()
  local veh = playerVeh()
  if not veh then return end

  local ppos = veh:getPosition()
  local act2 = cfg.activateDistance * cfg.activateDistance
  local deact2 = cfg.deactivateDistance * cfg.deactivateDistance
  local emergency2 = cfg.emergencyFarDistance * cfg.emergencyFarDistance
  local now = os.clock()

  -- Deactivate far/old/missing physics dummies.
  for id, i in pairs(_active) do
    local g = _ghosts[i]
    local o = be:getObjectByID(id)

    if not g or not o then
      _active[id] = nil
      if g then
        g.activeId = nil
        g.activeSince = nil
      end
    else
      local opos = o:getPosition()
      local far = dist2(opos, ppos) > deact2
      local emergencyFar = dist2(opos, ppos) > emergency2
      local oldEnough = (now - (g.activeSince or now)) > cfg.deactivateAfterSeconds
      local minTimeMet = (now - (g.activeSince or now)) > cfg.minActiveTime

      -- Track real object position back into the ghost.
      g.pos = opos

      if emergencyFar or (far and minTimeMet) or (oldEnough and far) then
        deactivateGhost(i, true)
      end
    end
  end

  -- Activate closest inactive ghosts.
  if countActive() >= cfg.maxActiveDummies then return end

  local bestI = nil
  local bestD2 = nil

  for i, g in ipairs(_ghosts) do
    if not g.activeId then
      local d2v = dist2(g.pos, ppos)
      if d2v < act2 and (not bestD2 or d2v < bestD2) then
        bestI = i
        bestD2 = d2v
      end
    end
  end

  if bestI then activateGhost(bestI) end
end

local function recycleFarGhosts()
  local veh = playerVeh()
  if not veh then return end

  local ppos = veh:getPosition()
  local max2 = cfg.maxDistance * cfg.maxDistance

  for i, g in ipairs(_ghosts) do
    if not g.activeId then
      if dist2(g.pos, ppos) > max2 then
        recycleGhost(i)
      end
    end
  end

  if cfg.debug and (_tpCount - _lastVerb) >= cfg.verboseEvery then
    _lastVerb = _tpCount
    d("D", "Recycles=%d ghosts=%d active=%d/%d", _tpCount, #_ghosts, countActive(), cfg.maxActiveDummies)
  end
end

local function drawDebug()
  if not debugDrawer then return end

  if cfg.drawGhostDebug then
    for _, g in ipairs(_ghosts) do
      if not g.activeId then
        debugDrawer:drawSphere(g.pos, 0.45, ColorF(0.2, 0.8, 1.0, 0.35))
      end
    end
  end

  if cfg.drawActiveDebug then
    for id, _ in pairs(_active) do
      local o = be:getObjectByID(id)
      if o then
        debugDrawer:drawSphere(o:getPosition(), 0.75, ColorF(1.0, 0.2, 0.2, 0.45))
      end
    end
  end
end

function M.start(idList, optCfg)
  if optCfg then
    for k, v in pairs(optCfg) do
      if cfg[k] ~= nil then cfg[k] = v end
    end
  end

  if cfg.cooldownTime and not cfg.teleportCooldownSeconds then
    cfg.teleportCooldownSeconds = cfg.cooldownTime
  end

  _enabled = true
  _active = {}
  _accGhost = 0
  _accRecycle = 0
  _accActivate = 0
  _tpCount = 0
  _lastVerb = 0
  _lastActivationAt = 0

  initGhosts()

  -- Optional back-compat: if old caller passed already-spawned IDs,
  -- absorb up to maxActiveDummies as active physics dummies.
  if idList then
    local n = 0
    for _, raw in ipairs(idList) do
      local id = asId(raw)
      if id and n < cfg.maxActiveDummies then
        n = n + 1
        if _ghosts[n] then
          _ghosts[n].activeId = id
          _ghosts[n].activeSince = os.clock()
          _active[id] = n
        end
      end
    end
  end

  d("I", "Started: ghosts=%d maxPhysics=%d activate=%.1fm deactivate=%.1fm sidewalk=%s",
    #_ghosts,
    cfg.maxActiveDummies,
    cfg.activateDistance,
    cfg.deactivateDistance,
    tostring(cfg.sidewalkMode)
  )
end

function M.spawn10DummiesAndStart(optCfg)
  -- Name kept for old license-plate trigger compatibility.
  -- It no longer spawns 10 real physics dummies. It starts the optimized ghost pool.
  if _enabled then
    d("I", "Recycler already active; skipping duplicate start.")
    return {}
  end

  M.start(nil, optCfg)
  return {}
end

function M.setIds(idList)
  -- Back-compat helper. Clears active pool and adopts provided IDs.
  for id, _ in pairs(_active) do
    deleteObject(id)
  end

  _active = {}

  if idList then
    local n = 0
    for _, raw in ipairs(idList) do
      local id = asId(raw)
      if id and n < cfg.maxActiveDummies then
        n = n + 1
        if not _ghosts[n] then
          _ghosts[n] = buildGhost(n)
        end
        if _ghosts[n] then
          _ghosts[n].activeId = id
          _ghosts[n].activeSince = os.clock()
          _active[id] = n
        end
      end
    end
  end

  d("I", "Adopted active IDs. active=%d/%d", countActive(), cfg.maxActiveDummies)
end

function M.tune(optCfg)
  if not optCfg then return end

  for k, v in pairs(optCfg) do
    if cfg[k] ~= nil then cfg[k] = v end
  end

  if cfg.cooldownTime and not optCfg.teleportCooldownSeconds then
    cfg.teleportCooldownSeconds = cfg.cooldownTime
  end

  d("I", "Tuned: ghosts=%d maxPhysics=%d sidewalk=%s offset=%.2f debug=%s",
    cfg.totalGhosts,
    cfg.maxActiveDummies,
    tostring(cfg.sidewalkMode),
    cfg.sidewalkOffset,
    tostring(cfg.debug)
  )
end

function M.stop()
  _enabled = false

  for id, _ in pairs(_active) do
    deleteObject(id)
  end

  local ghostCount = #_ghosts
  _ghosts = {}
  _active = {}

  d("I", "Stopped. Cleared ghosts=%d and active physics dummies.", ghostCount)
end

function M.onUpdate(dt)
  runFocusRestore(dt)

  if not _enabled then return end
  if not playerVeh() then return end

  _accGhost = _accGhost + dt
  _accRecycle = _accRecycle + dt
  _accActivate = _accActivate + dt

  if _accGhost >= cfg.ghostUpdateInterval then
    updateGhosts(_accGhost)
    _accGhost = 0
  end

  if _accRecycle >= cfg.recycleCheckInterval then
    recycleFarGhosts()
    _accRecycle = 0
  end

  if _accActivate >= cfg.activationCheckInterval then
    updateActivation()
    _accActivate = 0
  end

  drawDebug()
end

function M.onExtensionLoaded()
  d("I", "Loaded optimized pedestrian recycler.")
  d("I", "Call propRecycler.spawn10DummiesAndStart(optCfg) or propRecycler.start(nil, optCfg).")
end

return M