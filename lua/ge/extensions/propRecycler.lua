-- lua/ge/extensions/propRecycler.lua
-- Jonesing Pedestrians
-- FAR  = cheap grounded colored cylinders
-- MID  = visual-only .dae dummy models, no physics
-- NEAR = pooled AgentY physics ragdolls

local M = {}
M.dependencies = {"core_vehicles"}

-- ADD YOUR DAE PATH HERE:
local VISUAL_DAE_PATH = "/vehicles/common/AgentY_Dummy/AgentY_Dummy.dae"

local TAG = "propRecycler"

local cfg = {
  debug = true,

  totalCylinders = 100,
  maxVisualDummies = 20,
  physicsPoolSize = 3,
  maxActiveRagdolls = 3,

  dummyModel = "agenty_dummy",

  wideRadiusMin = 90,
  wideRadiusMax = 650,
  recycleRadius = 760,

  visualRadius = 200,
  ragdollBaseDistance = 7,
  ragdollHighSpeedDistance = 18,
  speedActivationMultiplier = 0.18,

  sidewalkMode = true,
  sidewalkOffset = 5.75,
  sidewalkRandomExtra = 2.25,

  farCylinderHeight = 1.45,
  farCylinderRadius = 0.30,

  visualScale = "1 1 1",

  markerGroundOffset = 0.01,
  visualGroundOffset = 0.00,
  ragdollGroundOffset = 0.00,

  groundProbeHeight = 250,
  groundProbeDepth = 700,

  pedestriansMove = true,
  walkSpeedMin = 0.35,
  walkSpeedMax = 1.15,
  turnChance = 0.006,
  crossChance = 0.0015,

  updateInterval = 0.10,
  recycleInterval = 0.45,
  visualLodInterval = 0.35,
  activationInterval = 0.05,

  minActiveTime = 2.0,
  maxActiveTime = 10.0,
  activationCooldownSeconds = 1.0,

  frontConeDot = 0.12,
  sideThreatDistance = 6.5,

  storageOffset = vec3(0, 0, -500),

  drawFarCylinders = true,
  useVisualDaeModels = true,
  showDebugUi = true,
}

local _enabled = false
local _peds = {}
local _visuals = {} -- [pedIndex] = TSStatic object
local _pool = {}

local _accUpdate = 0
local _accRecycle = 0
local _accVisual = 0
local _accActivate = 0
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

local function rand(a, b) return a + (b - a) * math.random() end

local function dist2(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

local function flat(v) return vec3(v.x, v.y, 0) end

local function safeNorm(v, fallback)
  if v and v:squaredLength() > 0.0001 then return v:normalized() end
  return fallback or vec3(0, 1, 0)
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

local function playerSpeed()
  local v = playerVeh()
  if not v or not v.getVelocity then return 0 end
  local ok, vel = pcall(function() return v:getVelocity() end)
  if ok and vel then return math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) end
  return 0
end

local function vBasis()
  local veh = playerVeh()
  if not veh then return nil end

  local pos = veh:getPosition()
  local fwd = veh.getDirectionVector and veh:getDirectionVector() or vec3(0, 1, 0)
  fwd = safeNorm(flat(fwd), vec3(0, 1, 0))

  local right
  if veh.getDirectionVectorSide then
    right = veh:getDirectionVectorSide()
  elseif veh.getSideVector then
    right = veh:getSideVector()
  else
    right = vec3(1, 0, 0)
  end

  right = safeNorm(flat(right), vec3(1, 0, 0))
  return pos, fwd, right
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
  if m > 0 then x, y, z, w = x / m, y / m, z / m, w / m end
  return quat(x, y, z, w)
end

local function playerGroundZ()
  local v = playerVeh()
  if not v then return 0 end
  local p = v:getPosition()
  local probe = vec3(p.x, p.y, p.z + cfg.groundProbeHeight)

  if map and map.surfaceHeightBelow then
    local ok, z = pcall(function() return map.surfaceHeightBelow(probe) end)
    if ok and type(z) == "number" then return z end
  end

  return p.z
end

local function getGroundZ(pos)
  local probe = vec3(pos.x, pos.y, pos.z + cfg.groundProbeHeight)

  if map and map.surfaceHeightBelow then
    local ok, z = pcall(function() return map.surfaceHeightBelow(probe) end)
    if ok and type(z) == "number" then return z end
  end

  if castRayStatic then
    local ok, hitDist = pcall(function()
      return castRayStatic(probe, vec3(0, 0, -1), cfg.groundProbeDepth)
    end)
    if ok and type(hitDist) == "number" and hitDist > 0 then
      return probe.z - hitDist
    end
  end

  return playerGroundZ()
end

local function groundSnap(pos, offset)
  local z = getGroundZ(pos)
  return vec3(pos.x, pos.y, z + (offset or 0))
end

local function makeRotFromDir(dir, pos)
  local normal = vecUp
  if map and map.surfaceNormal then
    local ok, n = pcall(function() return map.surfaceNormal(pos, 1) end)
    if ok and n then normal = n end
  end

  local f = safeNorm(flat(dir), vec3(0, 1, 0))
  local ok, rot = pcall(function()
    return quatFromDir(vecY:rotated(quatFromDir(f, normal)), normal)
  end)

  if ok and rot then return rot end
  return quat(0, 0, 0, 1)
end

local function color(seed, alpha)
  return ColorF(
    0.25 + 0.65 * math.abs(math.sin(seed * 11.1)),
    0.25 + 0.65 * math.abs(math.sin(seed * 27.7)),
    0.25 + 0.65 * math.abs(math.sin(seed * 53.3)),
    alpha or 0.55
  )
end

local function sampleAroundPlayer()
  local ppos, fwd = vBasis()
  if not ppos then return nil end

  local angle = rand(0, math.pi * 2)
  local radius = rand(cfg.wideRadiusMin, cfg.wideRadiusMax)

  local pos = vec3(
    ppos.x + math.cos(angle) * radius,
    ppos.y + math.sin(angle) * radius,
    ppos.z + cfg.groundProbeHeight
  )

  if cfg.sidewalkMode
    and gameplay_traffic_trafficUtils
    and gameplay_traffic_trafficUtils.findSafeSpawnPoint
    and gameplay_traffic_trafficUtils.finalizeSpawnPoint
    and map and map.getMap and map.getMap().nodes and next(map.getMap().nodes) then

    local ok, spawnData = pcall(function()
      return gameplay_traffic_trafficUtils.findSafeSpawnPoint(
        ppos,
        fwd,
        cfg.wideRadiusMin,
        cfg.wideRadiusMax,
        radius,
        {}
      )
    end)

    if ok and spawnData then
      local ok2, roadPos, roadDir = pcall(function()
        return gameplay_traffic_trafficUtils.finalizeSpawnPoint(
          spawnData.pos,
          spawnData.dir,
          spawnData.n1,
          spawnData.n2,
          { legalDirection = true }
        )
      end)

      if ok2 and roadPos and roadDir then
        local dir = safeNorm(flat(roadDir), fwd)
        local lateral = vec3(-dir.y, dir.x, 0)
        local side = math.random() < 0.5 and -1 or 1
        local offset = cfg.sidewalkOffset + rand(0, cfg.sidewalkRandomExtra)

        pos = roadPos + lateral * offset * side
        pos = groundSnap(pos, cfg.markerGroundOffset)

        return {
          pos = pos,
          dir = dir,
          rot = makeRotFromDir(dir, pos)
        }
      end
    end
  end

  pos = groundSnap(pos, cfg.markerGroundOffset)
  local dir = safeNorm(vec3(-math.sin(angle), math.cos(angle), 0), fwd)

  return {
    pos = pos,
    dir = dir,
    rot = makeRotFromDir(dir, pos)
  }
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

  if os.clock() < _focusDeadline then _focusTimer = 0.05 else _pendingFocusId = nil end
end

local function storagePosFor(index)
  local base = core_camera and core_camera.getPosition and core_camera.getPosition() or vec3(0, 0, 0)
  return vec3(base.x + index * 4, base.y, base.z - 500)
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
      if obj.setVelocity then obj:setVelocity(0, 0, 0) end
      if obj.setAngularVelocity then obj:setAngularVelocity(0, 0, 0) end
      if obj.setFreeze then obj:setFreeze(%s) end
    end
  ]], val))
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
    local id = spawnDummyAt(storagePosFor(i), quat(0, 0, 0, 1))
    if id then
      queueFreeze(id, true)
      table.insert(_pool, { id = id, active = false, pedIndex = nil, activeSince = 0 })
    else
      d("W", "Failed to spawn pooled ragdoll %d", i)
    end
  end

  d("I", "Ragdoll pool ready: %d/%d", #_pool, cfg.physicsPoolSize)
end

local function activeRagdolls()
  local n = 0
  for _, p in ipairs(_pool) do if p.active then n = n + 1 end end
  return n
end

local function acquirePoolDummy()
  for _, p in ipairs(_pool) do
    if not p.active and be:getObjectByID(p.id) then return p end
  end
  return nil
end

local function deleteVisualDummy(index)
  local obj = _visuals[index]
  if obj then
    pcall(function()
      if obj.delete then obj:delete() end
    end)
  end
  _visuals[index] = nil
end

local function setVisualTransform(obj, pos, rot)
  if not obj then return end
  local q = safeQuat(rot)

  pcall(function()
    if obj.setPosition then
      obj:setPosition(pos)
    else
      obj.position = string.format("%f %f %f", pos.x, pos.y, pos.z)
    end

    if obj.setRotation then
      obj:setRotation(q)
    else
      obj.rotation = string.format("%f %f %f %f", q.x, q.y, q.z, q.w)
    end
  end)
end

local function spawnVisualDummy(index)
  if not cfg.useVisualDaeModels or not VISUAL_DAE_PATH or VISUAL_DAE_PATH == "" then return nil end
  if _visuals[index] then return _visuals[index] end

  local ped = _peds[index]
  if not ped then return nil end

  local pos = groundSnap(ped.pos, cfg.visualGroundOffset)
  local rot = ped.rot or quat(0, 0, 0, 1)

  if createObject and scenetree and scenetree.MissionGroup then
    local ok, obj = pcall(function()
      local o = createObject("TSStatic")
      o.shapeName = VISUAL_DAE_PATH
      o.position = string.format("%f %f %f", pos.x, pos.y, pos.z)
      local q = safeQuat(rot)
      o.rotation = string.format("%f %f %f %f", q.x, q.y, q.z, q.w)
      o.scale = cfg.visualScale
      o.collisionType = "None"
      o.canSave = false
      o:registerObject("")
      scenetree.MissionGroup:addObject(o)
      return o
    end)

    if ok and obj then
      _visuals[index] = obj
      return obj
    end
  end

  return nil
end

local function recyclePed(i)
  local ped = _peds[i]
  if not ped or ped.activeRagdoll then return false end

  deleteVisualDummy(i)

  local pose = sampleAroundPlayer()
  if not pose then return false end

  ped.pos = pose.pos
  ped.dir = pose.dir
  ped.rot = pose.rot
  ped.speed = rand(cfg.walkSpeedMin, cfg.walkSpeedMax)
  ped.seed = math.random()
  ped.nextActivationAt = os.clock() + cfg.activationCooldownSeconds

  _recycles = _recycles + 1
  return true
end

local function releasePoolDummy(p, recycleAfter)
  if not p then return end

  local ped = p.pedIndex and _peds[p.pedIndex] or nil

  queueFreeze(p.id, true)
  teleportObject(p.id, storagePosFor(p.pedIndex or 1), quat(0, 0, 0, 1))

  if ped then
    ped.activeRagdoll = false
    ped.poolId = nil
    ped.nextActivationAt = os.clock() + cfg.activationCooldownSeconds
    ped.pos = groundSnap(ped.pos, cfg.markerGroundOffset)
    if recycleAfter then recyclePed(ped.index) end
  end

  p.active = false
  p.pedIndex = nil
  p.activeSince = 0
end

local function buildPed(i)
  local pose = sampleAroundPlayer()
  if not pose then return nil end

  return {
    index = i,
    pos = pose.pos,
    dir = pose.dir,
    rot = pose.rot,
    speed = rand(cfg.walkSpeedMin, cfg.walkSpeedMax),
    seed = math.random(),
    activeRagdoll = false,
    poolId = nil,
    nextActivationAt = 0,
  }
end

local function buildPedestrians()
  _peds = {}
  for i = 1, cfg.totalCylinders do
    local ped = buildPed(i)
    if ped then table.insert(_peds, ped) end
  end
  d("I", "Pedestrian field ready: %d", #_peds)
end

local function updatePedestrians(dt)
  if not cfg.pedestriansMove then return end

  for _, ped in ipairs(_peds) do
    if not ped.activeRagdoll then
      if math.random() < cfg.turnChance then
        ped.dir = ped.dir * -1
      elseif math.random() < cfg.crossChance then
        ped.dir = safeNorm(vec3(-ped.dir.y, ped.dir.x, 0), ped.dir)
      end

      ped.pos = ped.pos + ped.dir * ped.speed * dt
      ped.pos = groundSnap(ped.pos, cfg.markerGroundOffset)
      ped.rot = makeRotFromDir(ped.dir, ped.pos)

      local visual = _visuals[ped.index]
      if visual then setVisualTransform(visual, groundSnap(ped.pos, cfg.visualGroundOffset), ped.rot) end
    end
  end
end

local function recycleFarPedestrians()
  local veh = playerVeh()
  if not veh then return end

  local ppos = veh:getPosition()
  local recycle2 = cfg.recycleRadius * cfg.recycleRadius

  for i, ped in ipairs(_peds) do
    if not ped.activeRagdoll and dist2(ped.pos, ppos) > recycle2 then recyclePed(i) end
  end
end

local function updateVisualLod()
  local veh = playerVeh()
  if not veh then return end

  local ppos = veh:getPosition()
  local visual2 = cfg.visualRadius * cfg.visualRadius
  local candidates = {}

  for i, ped in ipairs(_peds) do
    if not ped.activeRagdoll then
      local d2v = dist2(ped.pos, ppos)
      if d2v <= visual2 then
        table.insert(candidates, { i = i, d2 = d2v })
      else
        deleteVisualDummy(i)
      end
    else
      deleteVisualDummy(i)
    end
  end

  table.sort(candidates, function(a, b) return a.d2 < b.d2 end)

  local keep = {}
  for n = 1, math.min(cfg.maxVisualDummies, #candidates) do
    keep[candidates[n].i] = true
    spawnVisualDummy(candidates[n].i)
  end

  for index, _ in pairs(_visuals) do
    if not keep[index] then deleteVisualDummy(index) end
  end
end

local function isThreatCandidate(ped, ppos, pfwd, speed)
  local toPed = flat(ped.pos - ppos)
  local d = toPed:length()
  if d < 0.01 then return true, d end

  local dynDist = cfg.ragdollBaseDistance + speed * cfg.speedActivationMultiplier
  dynDist = math.min(cfg.ragdollHighSpeedDistance, math.max(cfg.ragdollBaseDistance, dynDist))

  if d > dynDist then return false, d end
  if d <= cfg.sideThreatDistance then return true, d end

  return pfwd:dot(toPed:normalized()) >= cfg.frontConeDot, d
end

local function activatePedRagdoll(i)
  local ped = _peds[i]
  if not ped or ped.activeRagdoll then return false end

  local now = os.clock()
  if now < (ped.nextActivationAt or 0) then return false end
  if activeRagdolls() >= cfg.maxActiveRagdolls then return false end

  local p = acquirePoolDummy()
  if not p then return false end

  deleteVisualDummy(i)
  restoreFocusSoon()

  local ragPos = groundSnap(ped.pos, cfg.ragdollGroundOffset)
  teleportObject(p.id, ragPos, ped.rot)
  queueFreeze(p.id, false)

  p.active = true
  p.pedIndex = i
  p.activeSince = now

  ped.activeRagdoll = true
  ped.poolId = p.id

  return true
end

local function updateRagdolls()
  local ppos, pfwd = vBasis()
  if not ppos then return end

  local now = os.clock()
  local speed = playerSpeed()
  local recycle2 = cfg.recycleRadius * cfg.recycleRadius

  for _, p in ipairs(_pool) do
    if p.active then
      local o = be:getObjectByID(p.id)
      local ped = _peds[p.pedIndex]

      if not o or not ped then
        p.active = false
        p.pedIndex = nil
      else
        ped.pos = o:getPosition()
        local age = now - (p.activeSince or now)
        local far = dist2(ped.pos, ppos) > recycle2 and age >= cfg.minActiveTime
        local old = age >= cfg.maxActiveTime

        if far or old then releasePoolDummy(p, true) end
      end
    end
  end

  if activeRagdolls() >= cfg.maxActiveRagdolls then return end

  local bestI, bestD = nil, nil

  for i, ped in ipairs(_peds) do
    if not ped.activeRagdoll and now >= (ped.nextActivationAt or 0) then
      local threat, d = isThreatCandidate(ped, ppos, pfwd, speed)
      if threat and (not bestD or d < bestD) then
        bestI, bestD = i, d
      end
    end
  end

  if bestI then activatePedRagdoll(bestI) end
end

local function drawCylinder(pos, height, radius, col)
  if not debugDrawer then return end

  local bottom = groundSnap(pos, cfg.markerGroundOffset)
  local top = bottom + vec3(0, 0, height)

  local ok = false
  if debugDrawer.drawCylinder then
    ok = pcall(function() debugDrawer:drawCylinder(bottom, top, radius, col) end)
  end

  if not ok then
    debugDrawer:drawSphere(bottom + vec3(0, 0, height * 0.50), radius, col)
  end
end

local function drawFarCylinders()
  if not cfg.drawFarCylinders or not debugDrawer then return end

  for _, ped in ipairs(_peds) do
    if not ped.activeRagdoll and not _visuals[ped.index] then
      drawCylinder(ped.pos, cfg.farCylinderHeight, cfg.farCylinderRadius, color(ped.seed or 0.5, 0.55))
    end
  end
end

local function drawUi()
  if not cfg.showDebugUi or not imgui then return end

  local flags = bit.bor(
    imgui.WindowFlags_NoTitleBar or 0,
    imgui.WindowFlags_AlwaysAutoResize or 0,
    imgui.WindowFlags_NoFocusOnAppearing or 0,
    imgui.WindowFlags_NoNav or 0
  )

  imgui.SetNextWindowPos(imgui.ImVec2(20, 360), imgui.Cond_Always)
  imgui.Begin("Jonesing Pedestrians Debug", nil, flags)

  local visualCount = 0
  for _ in pairs(_visuals) do visualCount = visualCount + 1 end

  imgui.Text("Jonesing Pedestrians")
  imgui.Separator()
  imgui.Text(string.format("Cheap cylinders: %d", math.max(0, #_peds - visualCount - activeRagdolls())))
  imgui.Text(string.format("Visual .dae dummies: %d / %d", visualCount, cfg.maxVisualDummies))
  imgui.Text(string.format("Physics ragdolls: %d / %d", activeRagdolls(), cfg.maxActiveRagdolls))
  imgui.Text(string.format("Total peds: %d", #_peds))
  imgui.Text(string.format("Recycles: %d", _recycles))
  imgui.Text(string.format("Speed: %.1f m/s", playerSpeed()))
  imgui.Text(string.format("DAE: %s", VISUAL_DAE_PATH or "nil"))

  imgui.End()
end

function M.start(idList, optCfg)
  if optCfg then
    for k, v in pairs(optCfg) do
      if cfg[k] ~= nil then cfg[k] = v end
    end
  end

  _enabled = true
  _accUpdate, _accRecycle, _accVisual, _accActivate = 0, 0, 0, 0
  _recycles = 0

  if #_peds == 0 then buildPedestrians() end
  if #_pool == 0 then buildPool() end

  d("I", "Started: cylinders=%d visuals=%d ragdolls=%d",
    #_peds, cfg.maxVisualDummies, cfg.maxActiveRagdolls)
end

function M.spawn10DummiesAndStart(optCfg)
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
end

function M.stop()
  _enabled = false

  for index, _ in pairs(_visuals) do deleteVisualDummy(index) end

  for i, p in ipairs(_pool) do
    if p.id then
      queueFreeze(p.id, true)
      teleportObject(p.id, storagePosFor(i), quat(0, 0, 0, 1))
    end
    p.active = false
    p.pedIndex = nil
    p.activeSince = 0
  end

  for _, ped in ipairs(_peds) do
    ped.activeRagdoll = false
    ped.poolId = nil
  end

  d("I", "Stopped. Pool preserved.")
end

function M.reset()
  M.stop()
  for index, _ in pairs(_visuals) do deleteVisualDummy(index) end
  _peds = {}
  _visuals = {}
  _pool = {}
  M.start(nil, nil)
end

function M.onUpdate(dt)
  runFocusRestore(dt)

  if not _enabled then return end
  if not playerVeh() then return end

  _accUpdate = _accUpdate + dt
  _accRecycle = _accRecycle + dt
  _accVisual = _accVisual + dt
  _accActivate = _accActivate + dt

  if _accUpdate >= cfg.updateInterval then
    updatePedestrians(_accUpdate)
    _accUpdate = 0
  end

  if _accRecycle >= cfg.recycleInterval then
    recycleFarPedestrians()
    _accRecycle = 0
  end

  if _accVisual >= cfg.visualLodInterval then
    updateVisualLod()
    _accVisual = 0
  end

  if _accActivate >= cfg.activationInterval then
    updateRagdolls()
    _accActivate = 0
  end

  drawFarCylinders()
  drawUi()
end

function M.onExtensionLoaded()
  d("I", "Loaded Jonesing Pedestrians.")
end

return M