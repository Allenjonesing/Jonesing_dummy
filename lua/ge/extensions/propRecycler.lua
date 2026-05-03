-- lua/ge/extensions/propRecycler.lua
-- Jonesing Pedestrians / Prop Recycler
-- Optimized version:
--   - Ghost pedestrians are cheap Lua positions + debug markers.
--   - Real soft-body dummies are pre-spawned once into a small pool.
--   - Activation teleports an existing dummy instead of spawning during gameplay.

local M = {}
M.dependencies = {"core_vehicles"}

local TAG = "propRecycler"

local cfg = {
  debug = true,

  -- Ghost pedestrians
  totalGhosts = 20,
  drawGhostDebug = true,
  ghostMarkerRadius = 0.55,
  ghostMove = true,
  ghostSpeedMin = 0.6,
  ghostSpeedMax = 1.5,
  ghostTurnChance = 0.012,
  ghostCrossChance = 0.003,

  -- Physics pool
  physicsPoolSize = 3,
  dummyModel = "agenty_dummy",
  spawnPoolAtStart = true,
  maxActiveDummies = 3,

  -- Distances
  minDistance = 65,
  maxDistance = 280,
  leadDistance = 150,
  activateDistance = 55,
  deactivateDistance = 120,
  emergencyFarDistance = 350,

  -- Placement
  sidewalkMode = true,
  sidewalkOffset = 5.75,
  sidewalkRandomExtra = 2.0,
  heightOffset = 0.85,

  -- Timing
  ghostUpdateInterval = 0.10,
  recycleCheckInterval = 0.35,
  activationCheckInterval = 0.15,
  minActiveTime = 4.0,
  maxActiveTime = 14.0,
  activationCooldownSeconds = 1.0,

  -- Inactive dummy storage
  storageOffset = vec3(0, 0, -500),

  verboseEvery = 10,

  -- Back compat
  cooldownTime = nil,
  teleportCooldownSeconds = 3.0
}

local _enabled = false
local _ghosts = {}
local _pool = {} -- {id=id, active=false, ghostIndex=nil, activeSince=0}
local _accGhost = 0
local _accRecycle = 0
local _accActivate = 0
local _lastVerb = 0
local _recycles = 0

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
  if type(x) == "string" then return tonumber(x) end

  if type(x) == "userdata" or type(x) == "table" then
    local ok, id = pcall(function()
      if x.getId then return x:getId() end
      if x.id then return x.id end
      if x.obj and x.obj.getId then return x.obj:getId() end
      return nil
    end)
    if ok and id then return tonumber(id) end
  end

  return nil
end

local function playerVeh()
  return be and be:getPlayerVehicle(0) or nil
end

local function playerId()
  if be and be.getPlayerVehicleID then
    local ok, id = pcall(function() return be:getPlayerVehicleID(0) end)
    if ok and id then return id end
  end

  local v = playerVeh()
  if v and v.getId then return v:getId() end
  return nil
end

local function restoreFocusSoon()
  local id = playerId()
  if id then
    _pendingFocusId = id
    _focusTimer = 0.15
    _focusDeadline = os.clock() + 2.0
  end
end

local function runFocusRestore(dt)
  if not _pendingFocusId then return end

  _focusTimer = _focusTimer - dt
  if _focusTimer > 0 then return end

  if playerId() == _pendingFocusId then
    _pendingFocusId = nil
    return
  end

  pcall(function()
    if be.setPlayerVehicleID then be:setPlayerVehicleID(0, _pendingFocusId) end
    if be.enterVehicleID then be:enterVehicleID(_pendingFocusId, 0) end
    if be.enterVehicle then
      local o = be:getObjectByID(_pendingFocusId)
      if o then be:enterVehicle(o, 0) end
    end
    if be.setActiveObjectID then be:setActiveObjectID(_pendingFocusId) end
  end)

  if os.clock() < _focusDeadline then
    _focusTimer = 0.05
  else
    _pendingFocusId = nil
  end
end

local function dist2(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

local function safeQuat(q)
  local x, y, z, w = 0, 0, 0, 1

  if q then
    x = q.x or q[1] or x
    y = q.y or q[2] or y
    z = q.z or q[3] or z
    w = q.w or q[4] or w
  end

  local m = math.sqrt(x * x + y * y + z * z + w * w)
  if m > 0 then
    x, y, z, w = x / m, y / m, z / m, w / m
  end

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

  p.z = (fallbackZ or p.z) + cfg.heightOffset
  return p
end

local function makeRotFromDir(dir, pos)
  local normal = vecUp

  if map and map.surfaceNormal then
    local ok, n = pcall(function() return map.surfaceNormal(pos, 1) end)
    if ok and n then normal = n end
  end

  local flat = vec3(dir.x, dir.y, 0)
  if flat:squaredLength() < 0.0001 then flat = vec3(0, 1, 0) end
  flat = flat:normalized()

  local ok, rot = pcall(function()
    return quatFromDir(vecY:rotated(quatFromDir(flat, normal)), normal)
  end)

  if ok and rot then return rot end
  return quat(0, 0, 0, 1)
end

local function vBasis()
  local veh = playerVeh()
  if not veh then return nil end

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

local function sidewalkOffset(roadPos, roadDir)
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

  return groundSnap(roadPos + lateral * offset * side, roadPos.z)
end

local function samplePose()
  local ppos, fwd, right = vBasis()
  if not ppos then return nil end

  if map and map.getMap and map.getMap().nodes and next(map.getMap().nodes)
    and gameplay_traffic_trafficUtils
    and gameplay_traffic_trafficUtils.findSafeSpawnPoint
    and gameplay_traffic_trafficUtils.finalizeSpawnPoint then

    local ok, spawnData = pcall(function()
      return gameplay_traffic_trafficUtils.findSafeSpawnPoint(
        ppos,
        fwd,
        cfg.minDistance,
        cfg.maxDistance,
        cfg.leadDistance,
        {}
      )
    end)

    if ok and spawnData then
      local ok2, newPos, newDir = pcall(function()
        return gameplay_traffic_trafficUtils.finalizeSpawnPoint(
          spawnData.pos,
          spawnData.dir,
          spawnData.n1,
          spawnData.n2,
          {legalDirection = true}
        )
      end)

      if ok2 and newPos and newDir then
        local p = sidewalkOffset(newPos, newDir)
        return {
          pos = p,
          dir = vec3(newDir.x, newDir.y, 0):normalized(),
          rot = makeRotFromDir(newDir, p)
        }
      end
    end
  end

  -- Fallback if traffic sampler fails.
  local lateral = rand(-20, 20)
  local p = vec3(
    ppos.x + fwd.x * cfg.leadDistance + right.x * lateral,
    ppos.y + fwd.y * cfg.leadDistance + right.y * lateral,
    ppos.z
  )

  p = groundSnap(p, ppos.z)

  return {
    pos = p,
    dir = vec3(fwd.x, fwd.y, 0):normalized(),
    rot = makeRotFromDir(fwd, p)
  }
end

local function teleportObject(id, pos, rot)
  local o = be:getObjectByID(id)
  if not o then return false end

  local q = safeQuat(rot)

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

local function queueFreeze(id, frozen)
  local o = be:getObjectByID(id)
  if not o or not o.queueLuaCommand then return end

  local val = frozen and "true" or "false"

  o:queueLuaCommand(string.format([[
    if obj then
      if obj.setFreeze then obj:setFreeze(%s) end
      if %s and obj.setVelocity then obj:setVelocity(0, 0, 0) end
      if %s and obj.setAngularVelocity then obj:setAngularVelocity(0, 0, 0) end
    end
  ]], val, val, val))
end

local function storagePosFor(index)
  local ppos = core_camera and core_camera.getPosition and core_camera.getPosition() or vec3(0, 0, 0)
  return vec3(
    ppos.x + cfg.storageOffset.x + index * 4,
    ppos.y + cfg.storageOffset.y,
    ppos.z + cfg.storageOffset.z
  )
end

local function spawnDummyAt(pos, rot)
  if core_vehicles and core_vehicles.spawnNewVehicle then
    local ok, id = pcall(core_vehicles.spawnNewVehicle, cfg.dummyModel, {
      pos = pos,
      rot = safeQuat(rot),
      paint = nil,
      partConfig = "",
      cling = false,
      autoEnterVehicle = false,
      setPlayerVehicle = false
    })

    if ok and id then return asId(id) end
  end

  if be and be.spawnVehicle then
    local ok, id = pcall(function()
      return be:spawnVehicle(cfg.dummyModel, pos, safeQuat(rot))
    end)

    if ok and id then return asId(id) end
  end

  return nil
end

local function buildPool()
  if #_pool > 0 then return end

  restoreFocusSoon()

  for i = 1, cfg.physicsPoolSize do
    local pos = storagePosFor(i)
    local id = spawnDummyAt(pos, quat(0, 0, 0, 1))

    if id then
      queueFreeze(id, true)
      table.insert(_pool, {
        id = id,
        active = false,
        ghostIndex = nil,
        activeSince = 0
      })
      d("D", "Pre-spawned pooled dummy id=%s", tostring(id))
    else
      d("W", "Failed to pre-spawn pooled dummy %d", i)
    end
  end

  d("I", "Physics dummy pool ready: %d/%d", #_pool, cfg.physicsPoolSize)
end

local function activeCount()
  local n = 0
  for _, p in ipairs(_pool) do
    if p.active then n = n + 1 end
  end
  return n
end

local function acquirePoolDummy()
  for _, p in ipairs(_pool) do
    if not p.active and be:getObjectByID(p.id) then
      return p
    end
  end

  return nil
end

local function releasePoolDummy(p, recycleGhost)
  if not p then return end

  local g = p.ghostIndex and _ghosts[p.ghostIndex] or nil

  queueFreeze(p.id, true)
  teleportObject(p.id, storagePosFor(p.ghostIndex or 1), quat(0, 0, 0, 1))

  if g then
    g.active = false
    g.poolIndex = nil
    g.nextActivationAt = os.clock() + cfg.activationCooldownSeconds

    if recycleGhost then
      local pose = samplePose()
      if pose then
        g.pos = pose.pos
        g.dir = pose.dir
        g.rot = pose.rot
        g.speed = rand(cfg.ghostSpeedMin, cfg.ghostSpeedMax)
        _recycles = _recycles + 1
      end
    end
  end

  p.active = false
  p.ghostIndex = nil
  p.activeSince = 0
end

local function buildGhost(i)
  local pose = samplePose()
  if not pose then return nil end

  return {
    index = i,
    pos = pose.pos,
    dir = pose.dir,
    rot = pose.rot,
    speed = rand(cfg.ghostSpeedMin, cfg.ghostSpeedMax),
    active = false,
    poolIndex = nil,
    nextActivationAt = 0
  }
end

local function buildGhosts()
  _ghosts = {}

  for i = 1, cfg.totalGhosts do
    local g = buildGhost(i)
    if g then table.insert(_ghosts, g) end
  end

  d("I", "Ghost pedestrians ready: %d", #_ghosts)
end

local function recycleGhost(i)
  local g = _ghosts[i]
  if not g or g.active then return end

  local pose = samplePose()
  if not pose then return end

  g.pos = pose.pos
  g.dir = pose.dir
  g.rot = pose.rot
  g.speed = rand(cfg.ghostSpeedMin, cfg.ghostSpeedMax)
  g.nextActivationAt = os.clock() + cfg.activationCooldownSeconds

  _recycles = _recycles + 1
end

local function updateGhosts(dt)
  if not cfg.ghostMove then return end

  for _, g in ipairs(_ghosts) do
    if not g.active then
      if math.random() < cfg.ghostTurnChance then
        g.dir = g.dir * -1
      elseif math.random() < cfg.ghostCrossChance then
        g.dir = vec3(-g.dir.y, g.dir.x, 0):normalized()
      end

      g.pos = g.pos + g.dir * g.speed * dt
      g.pos = groundSnap(g.pos, g.pos.z - cfg.heightOffset)
      g.rot = makeRotFromDir(g.dir, g.pos)
    end
  end
end

local function activateGhost(i)
  local g = _ghosts[i]
  if not g or g.active then return false end

  local now = os.clock()
  if now < (g.nextActivationAt or 0) then return false end
  if activeCount() >= cfg.maxActiveDummies then return false end

  local p = acquirePoolDummy()
  if not p then return false end

  restoreFocusSoon()

  teleportObject(p.id, g.pos, g.rot)
  queueFreeze(p.id, false)

  p.active = true
  p.ghostIndex = i
  p.activeSince = now

  g.active = true
  g.poolIndex = p.id

  d("D", "Activated ghost %d using pooled dummy id=%s", i, tostring(p.id))
  return true
end

local function updateActivation()
  local veh = playerVeh()
  if not veh then return end

  local ppos = veh:getPosition()
  local activate2 = cfg.activateDistance * cfg.activateDistance
  local deactivate2 = cfg.deactivateDistance * cfg.deactivateDistance
  local emergency2 = cfg.emergencyFarDistance * cfg.emergencyFarDistance
  local now = os.clock()

  -- Release active pooled dummies when far/old.
  for _, p in ipairs(_pool) do
    if p.active then
      local o = be:getObjectByID(p.id)
      local g = _ghosts[p.ghostIndex]

      if not o or not g then
        p.active = false
        p.ghostIndex = nil
      else
        local opos = o:getPosition()
        g.pos = opos

        local d2v = dist2(opos, ppos)
        local activeAge = now - (p.activeSince or now)

        local farEnough = d2v > deactivate2 and activeAge >= cfg.minActiveTime
        local tooFar = d2v > emergency2
        local tooOld = activeAge >= cfg.maxActiveTime and d2v > activate2

        if farEnough or tooFar or tooOld then
          releasePoolDummy(p, true)
        end
      end
    end
  end

  if activeCount() >= cfg.maxActiveDummies then return end

  -- Activate closest visible/near ghost.
  local bestI = nil
  local bestD2 = nil

  for i, g in ipairs(_ghosts) do
    if not g.active and now >= (g.nextActivationAt or 0) then
      local d2v = dist2(g.pos, ppos)
      if d2v < activate2 and (not bestD2 or d2v < bestD2) then
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
    if not g.active and dist2(g.pos, ppos) > max2 then
      recycleGhost(i)
    end
  end

  if cfg.debug and _recycles - _lastVerb >= cfg.verboseEvery then
    _lastVerb = _recycles
    d("D", "Ghosts=%d activePhysics=%d/%d recycles=%d pool=%d",
      #_ghosts,
      activeCount(),
      cfg.maxActiveDummies,
      _recycles,
      #_pool
    )
  end
end

local function drawDebug()
  if not cfg.drawGhostDebug or not debugDrawer then return end

  for _, g in ipairs(_ghosts) do
    if not g.active then
      debugDrawer:drawSphere(g.pos, cfg.ghostMarkerRadius, ColorF(0.1, 0.8, 1.0, 0.45))
      debugDrawer:drawTextAdvanced(
        g.pos + vec3(0, 0, 1.25),
        "PED",
        ColorF(0.7, 1.0, 1.0, 0.85),
        true,
        false,
        ColorI(0, 0, 0, 120)
      )
    end
  end
end

function M.start(idList, optCfg)
  if optCfg then
    for k, v in pairs(optCfg) do
      if cfg[k] ~= nil then cfg[k] = v end
    end
  end

  _enabled = true
  _accGhost = 0
  _accRecycle = 0
  _accActivate = 0
  _lastVerb = 0
  _recycles = 0

  if #_ghosts == 0 then buildGhosts() end
  if cfg.spawnPoolAtStart then buildPool() end

  d("I", "Started Jonesing Pedestrians: ghosts=%d pool=%d maxActive=%d",
    #_ghosts,
    #_pool,
    cfg.maxActiveDummies
  )
end

function M.spawn10DummiesAndStart(optCfg)
  -- Backwards-compatible trigger name.
  -- Does NOT spawn 10 live physics dummies anymore.
  if _enabled then
    d("I", "Already active; skipping duplicate start.")
    return {}
  end

  M.start(nil, optCfg)
  return {}
end

function M.tune(optCfg)
  if not optCfg then return end

  for k, v in pairs(optCfg) do
    if cfg[k] ~= nil then cfg[k] = v end
  end

  d("I", "Tuned: ghosts=%d pool=%d active=%d sidewalk=%s debugMarkers=%s",
    cfg.totalGhosts,
    cfg.physicsPoolSize,
    cfg.maxActiveDummies,
    tostring(cfg.sidewalkMode),
    tostring(cfg.drawGhostDebug)
  )
end

function M.stop()
  _enabled = false

  for _, p in ipairs(_pool) do
    if p.id then
      queueFreeze(p.id, true)
      teleportObject(p.id, storagePosFor(1), quat(0, 0, 0, 1))
    end
    p.active = false
    p.ghostIndex = nil
  end

  for _, g in ipairs(_ghosts) do
    g.active = false
    g.poolIndex = nil
  end

  d("I", "Stopped Jonesing Pedestrians. Pool preserved for reuse.")
end

function M.reset()
  M.stop()
  _ghosts = {}
  _pool = {}
  M.start(nil, nil)
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
  d("I", "Loaded. Use propRecycler.spawn10DummiesAndStart() to start.")
end

return M