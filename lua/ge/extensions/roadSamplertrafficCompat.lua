-- roadSampler_trafficCompat.lua
-- Sample a road pose using the same machinery traffic uses for respawns.

local M = {}
local TAG = "roadSamplerTC"

local function logI(msg, ...) log("I", TAG, string.format(msg, ...)) end
local function logW(msg, ...) log("W", TAG, string.format(msg, ...)) end
local function logD(msg, ...) log("D", TAG, string.format(msg, ...)) end

-- Z-up forward for vehicles (same basis as traffic.lua)
local vecUp, vecY = vec3(0,0,1), vec3(0,1,0)

-- Prefer player velocity, else facing, else +X
local function bestForward()
  local v = be:getPlayerVehicle(0)
  if v then
    if v.getVelocity then
      local vel = v:getVelocity()
      if vel:squaredLength() > 1e-4 then return vel:normalized() end
    end
    if v.getDirectionVector then
      local f = v:getDirectionVector()
      return vec3(f.x,f.y,f.z):normalized()
    end
  end
  return vec3(1,0,0)
end

-- Public: return {pos=vec3, rot=quat} or nil
-- opts = { minDist?, maxDist?, targetDist?, dirBias?, useFocus? (true), params? }
function M.sampleUsingTraffic(seedPos, seedDir, opts)
  opts = opts or {}
  -- Require map graph (traffic refuses to respawn without nodes)
  if not next(map.getMap().nodes) then
    logW("No map nodes; traffic spawn helpers unavailable.")
    return nil
  end

  -- Fallbacks similar to traffic.lua
  local minDist    = opts.minDist or 80
  local maxDist    = opts.maxDist or 400
  local targetDist = opts.targetDist or math.min(minDist * 2, lerp(minDist, maxDist, 0.5))
  local dirBias    = opts.dirBias

  local pos = seedPos or core_camera.getPosition()
  local dir = (seedDir and seedDir:normalized()) or bestForward()

  -- (A) Seed the traffic focus (optional but helps quality)
  local restoreFocus
  if opts.useFocus ~= false and traffic and traffic.setFocus and traffic.getFocus then
    local prev = deepcopy(traffic.getFocus())
    restoreFocus = function()
      if prev and prev.mode then traffic.setFocus(prev.mode, prev) else traffic.setFocus() end
    end
    traffic.setFocus('custom', {pos = pos, dir = dir, dist = dir:length(), auto = false})
  end

  -- (B) Ask traffic to find & finalize a safe spawn point
  local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(
    pos, dir, minDist, maxDist, targetDist, opts.params or {}
  )

  if not spawnData then
    if restoreFocus then restoreFocus() end
    logW("findSafeSpawnPoint returned nil.")
    return nil
  end

  local place = { legalDirection = true }
  if dirBias then place.dirRandomization = dirBias end

  local newPos, newDir =
    gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, place)

  if restoreFocus then restoreFocus() end
  if not newPos or not newDir then
    logW("finalizeSpawnPoint failed.")
    return nil
  end

  -- (C) Build rotation like traffic.lua does
  local normal = map.surfaceNormal(newPos, 1) or vecUp
  local rot = quatFromDir(vecY:rotated(quatFromDir(newDir, normal)), normal)

  logD("Sample via traffic OK at (%.2f, %.2f, %.2f).", newPos.x, newPos.y, newPos.z)
  return { pos = newPos, rot = rot }
end

return M
