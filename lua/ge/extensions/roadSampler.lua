-- lua/ge/extensions/roadSampler.lua
local M = {}
local TAG = "roadSampler"

local function logI(msg, ...) log("I", TAG, string.format(msg, ...)) end
local function logD(msg, ...) log("D", TAG, string.format(msg, ...)) end
local function logW(msg, ...) log("W", TAG, string.format(msg, ...)) end

-- Robust forward: prefer player velocity, then facing, then +X
local function bestForwardAt(pos)
  if traffic and traffic.focus and traffic.focus.dirVec then
    local d = traffic.focus.dirVec
    return vec3(d.x, d.y, d.z):normalized()
  end
  local v = be:getPlayerVehicle(0)
  if v then
    if v.getVelocity then
      local vel = v:getVelocity()
      local spd2 = vel.x*vel.x + vel.y*vel.y + vel.z*vel.z
      if spd2 > 1e-4 then
        return vec3(vel.x, vel.y, vel.z):normalized()
      end
    end
    if v.getDirectionVector then
      local f = v:getDirectionVector()
      return vec3(f.x, f.y, f.z):normalized()
    end
  end
  return vec3(1,0,0)
end

-- Build a right vector that's stable (Z-up world)
local function makeBasis(dir)
  dir = dir:normalized()
  local up = vec3(0,0,1)
  -- Use up × forward to get a consistent "right" (avoids left/right flips on steep slopes)
  local right = up:cross(dir):normalized()
  local trueUp = dir:cross(right):normalized()
  return right, trueUp
end

-- Cast from way above to way below to catch bridges/mesh/decal roads/terrain
local function groundHitAt(pos, maxUp, maxDown, layerMask)
  maxUp   = maxUp   or 200
  maxDown = maxDown or 500
  local from = vec3(pos.x, pos.y, pos.z + maxUp)
  local to   = vec3(pos.x, pos.y, pos.z - maxDown)
  local hit, hitPos, hitNorm, hitDist, hitObj = castRay(from, to, layerMask or 0xFFFFFFFF)
  if not hit then return nil end
  return hitPos, hitNorm, hitObj
end

local function quatLook(dir, up)
  dir = dir:normalized()
  up  = (up and up:normalized()) or vec3(0,0,1)
  local right = up:cross(dir):normalized()
  local trueUp = dir:cross(right):normalized()
  local m = MatrixF(true)
  m:setColumn(0, Point3F(right.x,  right.y,  right.z))
  m:setColumn(1, Point3F(trueUp.x, trueUp.y, trueUp.z))
  m:setColumn(2, Point3F(dir.x,    dir.y,    dir.z))
  return quat(m)
end

-- Optional: nudge to lane if traffic provides it (harmless no-op otherwise)
local function nudgeToLaneCenter(pos)
  if traffic and traffic.roadGraph and traffic.roadGraph.getClosestLanePos then
    local lanePos = traffic.roadGraph.getClosestLanePos(pos)
    if type(lanePos) == "table" and lanePos.pos then
      return vec3(lanePos.pos.x, lanePos.pos.y, lanePos.pos.z)
    end
  end
  return pos
end

-- PUBLIC
function M.sampleRoadPose(seedPos, seedDir, opts)
  opts = opts or {}
  local fwd = (seedDir and seedDir:normalized()) or bestForwardAt(seedPos)
  local right, _ = makeBasis(fwd)

  -- probe a little above the seed so the first downcast isn't inside geometry
  local probe = vec3(
    seedPos.x + (opts.ahead or 0)   * fwd.x + (opts.lateral or 0) * right.x,
    seedPos.y + (opts.ahead or 0)   * fwd.y + (opts.lateral or 0) * right.y,
    seedPos.z + 2.0
  )

  if opts.snapToLane ~= false then
    probe = nudgeToLaneCenter(probe)
  end

  local hitPos, hitNorm, hitObj = groundHitAt(probe, 200, opts.maxDrop or 500, 0xFFFFFFFF)
  if not hitPos then
    -- small radial search around probe to catch narrow roads/bridges
    for r = 3, 24, 3 do
      for a = 0, 330, 30 do
        local rad = math.rad(a)
        local p = vec3(
          probe.x + math.cos(rad)*r,
          probe.y + math.sin(rad)*r,
          probe.z
        )
        hitPos, hitNorm, hitObj = groundHitAt(p, 200, opts.maxDrop or 500, 0xFFFFFFFF)
        if hitPos then probe = p; break end
      end
      if hitPos then break end
    end
  end

  if not hitPos then
    logW("No ground hit near (%.1f, %.1f, %.1f).", probe.x, probe.y, probe.z)
    return nil
  end

  -- Debug what we actually hit; super helpful when it keeps preferring terrain.
  if hitObj and hitObj.getClassName then
    local cls = hitObj:getClassName()
    logD("Hit %s @ (%.2f, %.2f, %.2f).", cls, hitPos.x, hitPos.y, hitPos.z)
  else
    logD("Hit unknown object @ (%.2f, %.2f, %.2f).", hitPos.x, hitPos.y, hitPos.z)
  end

  local dir = bestForwardAt(hitPos)
  local rot = quatLook(dir, hitNorm)
  return { pos = hitPos, rot = rot }
end

function M.sampleFan(seedPos, seedDir, count, spacing, lateralStep)
  local poses, n = {}, (tonumber(count) or 1)
  spacing = spacing or 8
  lateralStep = lateralStep or 2.5
  for i = 1, n do
    local sideIndex = math.floor(i/2)
    local lr = (i % 2 == 0) and 1 or -1
    local opts = {
      ahead = (i-1) * spacing,
      lateral = lr * sideIndex * lateralStep,
      snapToLane = true,
      maxDrop = 500
    }
    local pose = M.sampleRoadPose(seedPos, seedDir, opts)
    if pose then poses[#poses+1] = pose end
  end
  return poses
end

return M
