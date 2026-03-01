-- lua/ge/extensions/propRecycler.lua
-- Minimal recycler: teleports given prop IDs back near the player when far away.
local M = {}
M.dependencies = {"core_vehicles", "roadSampler"}

local cfg = {
    checkInterval = 0.25,
    minDistance = 60,
    maxDistance = 5000,
    leadDistance = 160,
    useFocus = false,
    lateralJitter = 20,
    heightOffset = 0.8,

    -- NEW: per-dummy teleport lockout (seconds)
    teleportCooldownSeconds = 3.0,

    -- Deprecated alias (kept for backwards-compat). If provided, it will be
    -- copied into teleportCooldownSeconds at start/tune time.
    cooldownTime = nil,

    debug = true,
    verboseEvery = 10
}

local _enabled, _accum, _tpCount, _lastVerb = false, 0, 0, 0
local _props = {} -- [numericId] = { nextTeleportAt = 0 }
local TAG = "propRecycler"
local _pendingFocusId, _focusTimer = nil, 0
local _focusDeadline = 0 -- absolute time window to keep retrying

local function d(level, msg, ...)
    if level == 'D' and not cfg.debug then return end
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    log(level, TAG, msg)
end

-- --- Helpers ----------------------------------------------------------------
-- helper: safe handle to module
local function RS() return (extensions and extensions.roadSampler) or nil end

local function asId(x)
    if type(x) == "number" then return x end
    if type(x) == "string" then
        local n = tonumber(x);
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

local function v() return be:getPlayerVehicle(0) end

local function vBasis(veh)
    local pos = veh:getPosition()
    local fwd
    if veh.getDirectionVector then
        fwd = veh:getDirectionVector()
    else
        fwd = vec3(0, 1, 0)
    end
    local right
    if veh.getDirectionVectorSide then
        right = veh:getDirectionVectorSide()
    elseif veh.getSideVector then
        right = veh:getSideVector()
    else
        right = vec3(1, 0, 0)
    end
    return pos, fwd, right
end

-- FIXED: do not call veh.getRotation() without self; use feature check
local function qFromVeh(veh)
    local q
    if veh.getRotation then
        q = veh:getRotation()
    else
        q = quat(0, 0, 0, 1)
    end
    return q.x, q.y, q.z, q.w
end

local function rand(a, b) return a + (b - a) * math.random() end

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
    if m > 0 then x, y, z, w = x / m, y / m, z / m, w / m end
    return x, y, z, w
end

-- Z-up forward for vehicles (same basis as traffic.lua)
local vecUp, vecY = vec3(0, 0, 1), vec3(0, 1, 0)

-- Prefer player velocity, else facing, else +X
local function bestForward()
    local v = be:getPlayerVehicle(0)
    if v then
        if v.getVelocity then
            local vel = v:getVelocity()
            if vel:squaredLength() > 1e-4 then
                return vel:normalized()
            end
        end
        if v.getDirectionVector then
            local f = v:getDirectionVector()
            return vec3(f.x, f.y, f.z):normalized()
        end
    end
    return vec3(1, 0, 0)
end

-- Public: return {pos=vec3, rot=quat} or nil
-- opts = { minDist?, maxDist?, targetDist?, dirBias?, useFocus? (true), params? }
local function sampleUsingTraffic(seedPos, seedDir, opts)
    opts = opts or {}
    -- Require map graph (traffic refuses to respawn without nodes)
    if not next(map.getMap().nodes) then
        d("W", "No map nodes; traffic spawn helpers unavailable.")
        return nil
    end

    -- Fallbacks similar to traffic.lua
    local minDist = opts.minDist or 80
    local maxDist = opts.maxDist or 400
    local targetDist = opts.targetDist or
                           math.min(minDist * 2, lerp(minDist, maxDist, 0.5))
    local dirBias = opts.dirBias

    local pos = seedPos or core_camera.getPosition()
    local dir = (seedDir and seedDir:normalized()) or bestForward()

    -- (A) Seed the traffic focus (optional but helps quality)
    local restoreFocus
    if opts.useFocus ~= false and traffic and traffic.setFocus and
        traffic.getFocus then
        local prev = deepcopy(traffic.getFocus())
        restoreFocus = function()
            if prev and prev.mode then
                traffic.setFocus(prev.mode, prev)
            else
                traffic.setFocus()
            end
        end
        traffic.setFocus('custom', {
            pos = pos,
            dir = dir,
            dist = dir:length(),
            auto = false
        })
    end

    -- (B) Ask traffic to find & finalize a safe spawn point
    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(pos, dir,
                                                                       minDist,
                                                                       maxDist,
                                                                       targetDist,
                                                                       opts.params or
                                                                           {})

    if not spawnData then
        if restoreFocus then restoreFocus() end
        d("W", "findSafeSpawnPoint returned nil.")
        return nil
    end

    local place = {legalDirection = true}
    if dirBias then place.dirRandomization = dirBias end

    local newPos, newDir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(
                               spawnData.pos, spawnData.dir, spawnData.n1,
                               spawnData.n2, place)

    if restoreFocus then restoreFocus() end
    if not newPos or not newDir then
        d("W", "finalizeSpawnPoint failed.")
        return nil
    end

    -- (C) Build rotation like traffic.lua does
    local normal = map.surfaceNormal(newPos, 1) or vecUp
    local rot = quatFromDir(vecY:rotated(quatFromDir(newDir, normal)), normal)

    d("D", "Sample via traffic OK at (%.2f, %.2f, %.2f).", newPos.x, newPos.y,
      newPos.z)
    return {pos = newPos, rot = rot}
end

-- Teleport using whatever the GE object supports
local function teleportGE(id, targetPos, targetQuat)
    local o = be:getObjectByID(id)
    if not o then
        d('D', 'Teleport skip: id %s missing', tostring(id));
        return false
    end
    local pos = toVec3(targetPos)
    local qx, qy, qz, qw = toQuat(targetQuat)

    if be.teleportVehicle then
        local ok = be:teleportVehicle(id, pos, quat(qx, qy, qz, qw))
        if ok then return true end
    end
    if o.setPositionRotation then
        o:setPositionRotation(pos.x, pos.y, pos.z, qx, qy, qz, qw);
        return true
    end
    if o.setPosQuat then
        o:setPosQuat(pos.x, pos.y, pos.z, qx, qy, qz, qw);
        return true
    end
    if o.setPosition and o.setRotation then
        o:setPosition(pos);
        o:setRotation(quat(qx, qy, qz, qw));
        return true
    end
    if o.setPosition then
        o:setPosition(pos);
        return true
    end

    local cmd = string.format([[
    if obj then
      if obj.setFreeze then obj:setFreeze(true) end
      if obj.setVelocity then obj:setVelocity(0,0,0) end
      if obj.setAngularVelocity then obj:setAngularVelocity(0,0,0) end
      if obj.setPosQuat then obj:setPosQuat(%f,%f,%f,%f,%f,%f,%f)
      elseif obj.setPosition then obj:setPosition(%f,%f,%f) end
      if obj.setFreeze then obj:setFreeze(false) end
    end
  ]], pos.x, pos.y, pos.z, qx, qy, qz, qw, pos.x, pos.y, pos.z)
    o:queueLuaCommand(cmd)
    return true
end

-- --- Spawner ---------------------------------------------------------------
local function spawnDummyAt(pos, q)
    local qx, qy, qz, qw = toQuat(q)
    if core_vehicles and core_vehicles.spawnNewVehicle then
        local ok, id = pcall(core_vehicles.spawnNewVehicle, "jonesing_dummy", {
            pos = toVec3(pos),
            rot = quat(qx, qy, qz, qw),
            paint = nil,
            partConfig = "",
            cling = false,
            autoEnterVehicle = false, -- <<< prevents stealing player focus
            setPlayerVehicle = false -- <<< ignored on some builds, harmless
            -- playerUsable = true       -- keep TAB-able; set false to hide from TAB
        })
        if ok and id then return id end
    end
    -- (fallbacks unchanged)
    if spawn and spawn.spawnVehicle then
        local ok, id = pcall(spawn.spawnVehicle, "jonesing_dummy",
                             {pos = toVec3(pos), rot = quat(qx, qy, qz, qw)})
        if ok and id then return id end
    end
    if be and be.spawnVehicle then
        local ok, id = pcall(function()
            return be:spawnVehicle("jonesing_dummy", toVec3(pos),
                                   quat(qx, qy, qz, qw))
        end)
        if ok and id then return id end
    end
    d('W', 'Failed to spawn dummy at requested position.')
    return nil
end

function M.spawn10DummiesAndStart(optCfg)
    -- Guard: if the pool is already active, don't spawn another batch.
    -- The license-plate trigger fires on every vehicle init/reset, but the
    -- dummies should only ever be spawned once per session.
    if _enabled then
        if next(_props) ~= nil then
            d('I', 'Pool already active; skipping re-spawn.')
            return nil
        end
    end

    local veh = v()
    if not veh then
        d('E', 'No player vehicle; cannot spawn.');
        return {}
    end

    local originalPlayer = (veh.getId and veh:getId()) or nil
    local ppos, fwd, right = vBasis(veh)
    local qx, qy, qz, qw = qFromVeh(veh)

    local ids = {}
    for i = 1, 10 do
        local sideIndex = math.floor(i / 2)
        local lr = (i % 2 == 0) and 1 or -1

        -- MASSIVE forward spread: start 10 m ahead, +20 m per dummy
        local forwardDist = 10 + (i - 1) * 20.0
        -- small side wiggle for variety
        local sideDist = (1.5 + sideIndex * 0.5) * lr

        local pos = vec3(ppos.x + fwd.x * forwardDist + right.x * sideDist,
                         ppos.y + fwd.y * forwardDist + right.y * sideDist,
                         ppos.z + cfg.heightOffset)

        local spawned = spawnDummyAt(pos, {qx, qy, qz, qw})
        local nid = asId(spawned)
        if nid then
            table.insert(ids, nid)
        else
            d('W', 'Spawn %d failed', i)
        end
    end

    -- defer player focus restore: spawns may steal focus asynchronously
    if originalPlayer then
        _pendingFocusId = originalPlayer
        _focusTimer = 0.25
        _focusDeadline = os.clock() + 2.0
    end

    if #ids == 0 then
        d('E', 'No dummies spawned; not starting recycler.');
        return {}
    end

    d('I', 'Spawned %d dummies; starting recycler.', #ids)
    M.start(ids, optCfg)
    return ids
end

-- --- Public API -------------------------------------------------------------
function M.start(idList, optCfg)
    -- apply incoming config
    if optCfg then
        for k, v in pairs(optCfg) do if cfg[k] ~= nil then cfg[k] = v end end
    end
    -- Back-compat: if user passed cooldownTime, treat it as teleportCooldownSeconds
    if cfg.cooldownTime and not cfg.teleportCooldownSeconds then
        cfg.teleportCooldownSeconds = cfg.cooldownTime
    end

    _props = {}
    local now = os.clock()
    for _, raw in ipairs(idList or {}) do
        local id = asId(raw)
        if id then _props[id] = {nextTeleportAt = now} end -- small grace at start
    end

    _enabled, _accum, _tpCount, _lastVerb = true, 0, 0, 0
    local count = 0;
    for _ in pairs(_props) do count = count + 1 end
    d('I',
      'Enabled for %d props (cooldown=%.2fs maxDist=%d lead=%d jitter=±%d h=%.2f)',
      count, cfg.teleportCooldownSeconds, cfg.maxDistance, cfg.leadDistance,
      cfg.lateralJitter, cfg.heightOffset)
end

function M.setIds(idList)
    local prev = 0;
    for _ in pairs(_props) do prev = prev + 1 end
    _props = {}
    local now = os.clock()
    for _, raw in ipairs(idList or {}) do
        local id = asId(raw)
        if id then _props[id] = {nextTeleportAt = now} end
    end
    local nowCount = 0;
    for _ in pairs(_props) do nowCount = nowCount + 1 end
    d('I', 'Working set replaced: %d -> %d props', prev, nowCount)
end

function M.tune(optCfg)
    if not optCfg then return end
    for k, v in pairs(optCfg) do if cfg[k] ~= nil then cfg[k] = v end end
    if cfg.cooldownTime and not optCfg.teleportCooldownSeconds then
        cfg.teleportCooldownSeconds = cfg.cooldownTime
    end
    d('I',
      'Tuned (cooldown=%.2fs maxDist=%d lead=%d jitter=±%d h=%.2f debug=%s every=%d)',
      cfg.teleportCooldownSeconds, cfg.maxDistance, cfg.leadDistance,
      cfg.lateralJitter, cfg.heightOffset, tostring(cfg.debug), cfg.verboseEvery)
end

function M.stop()
    _enabled = false
    local n = 0;
    for _ in pairs(_props) do n = n + 1 end
    _props = {}
    d('I', 'Disabled (cleared %d props)', n)
end

-- ---- Tick ------------------------------------------------------------------
function M.onUpdate(dt)
    -- one-shot (with brief retry) deferred focus restore
    if _pendingFocusId then
        _focusTimer = (_focusTimer or 0) - dt
        if _focusTimer <= 0 then
            local curId = nil
            if be and be.getPlayerVehicleID then
                pcall(function() curId = be:getPlayerVehicleID(0) end)
            elseif be and be.getPlayerVehicle then
                local veh = be:getPlayerVehicle(0);
                if veh and veh.getId then curId = veh:getId() end
            end

            if curId ~= _pendingFocusId then
                pcall(function()
                    -- try the most explicit first
                    if be and be.setPlayerVehicleID then
                        be:setPlayerVehicleID(0, _pendingFocusId)
                    end
                    -- common alt signature
                    if be and be.enterVehicleID then
                        be:enterVehicleID(_pendingFocusId, 0)
                    end
                    -- older / different builds
                    if be and be.enterVehicle then
                        local veh = be:getObjectByID(_pendingFocusId)
                        if veh then
                            be:enterVehicle(veh, 0)
                        end
                    end
                    -- some builds expose these instead:
                    if be and be.setPlayerVehicle then
                        be:setPlayerVehicle(0, _pendingFocusId)
                    end
                    if be and be.setActiveObjectID then
                        be:setActiveObjectID(_pendingFocusId)
                    end
                end)

                -- re-check immediately after attempting restore
                local checkId = nil
                if be and be.getPlayerVehicleID then
                    pcall(function()
                        checkId = be:getPlayerVehicleID(0)
                    end)
                elseif be and be.getPlayerVehicle then
                    local v0 = be:getPlayerVehicle(0);
                    if v0 and v0.getId then
                        checkId = v0:getId()
                    end
                end

                if checkId == _pendingFocusId then
                    _pendingFocusId, _focusTimer, _focusDeadline = nil, 0, 0
                elseif os.clock() < (_focusDeadline or 0) then
                    _focusTimer = 0.05
                else
                    _pendingFocusId, _focusTimer, _focusDeadline = nil, 0, 0
                end
            else
                _pendingFocusId, _focusTimer, _focusDeadline = nil, 0, 0
            end
        end
    end

    if not _enabled then return end
    _accum = _accum + dt
    if _accum < cfg.checkInterval then return end
    _accum = 0

    local veh = v()
    if not veh then
        d('D', 'Waiting for player vehicle...');
        return
    end

    local now = os.clock()
    local ppos, fwd, right = vBasis(veh)
    local qx, qy, qz, qw = qFromVeh(veh)
    local max2 = cfg.maxDistance * cfg.maxDistance

    for id, st in pairs(_props) do
        local numId = asId(id)
        if numId then
            -- Skip until its teleport window opens
            if (st.nextTeleportAt or 0) > now then goto continue_prop end

            local o = be:getObjectByID(numId)
            if not o then
                d('D', 'Missing object id=%s; skipping', tostring(numId))
                goto continue_prop
            end

            local opos = o:getPosition()
            local far = dist2(opos, ppos) > max2
            if far then
                local lateral = rand(-cfg.lateralJitter, cfg.lateralJitter)
                local seedDir = vec3(fwd.x, fwd.y, fwd.z)

                local ok = false
                local pose = sampleUsingTraffic(nil, nil, {
                    minDist = cfg.minDistance,
                    targetDist = cfg.leadDistance,
                    useFocus = cfg.useFocus
                })

                if pose and pose.pos and pose.rot then
                    ok = teleportGE(numId, pose.pos, {
                        pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w
                    })
                else
                    local target = vec3(ppos.x + seedDir.x * cfg.leadDistance +
                                            right.x * lateral, ppos.y +
                                            seedDir.y * cfg.leadDistance +
                                            right.y * lateral, opos.z)
                    d('D', 'Sampler nil; fallback target (%.2f, %.2f, %.2f)',
                      target.x, target.y, target.z)
                    ok = teleportGE(numId, target, {qx, qy, qz, qw})
                end

                if ok then
                    st.nextTeleportAt = now +
                                            (cfg.teleportCooldownSeconds or 3.0)
                    _tpCount = _tpCount + 1
                    if cfg.debug and (_tpCount - _lastVerb) >= cfg.verboseEvery then
                        _lastVerb = _tpCount
                        d('D', 'Recycles so far: %d (cooldown=%.2fs)', _tpCount,
                          cfg.teleportCooldownSeconds or 3.0)
                    end
                end
            end
        end
        ::continue_prop::
    end
end

function M.onExtensionLoaded()
    d('I', 'Loaded. Call propRecycler.start({ids...}, optCfg) to begin.')
    d('I',
      'Or call propRecycler.spawn10DummiesAndStart(optCfg) to auto-spawn and recycle 10 dummies.')
end

return M
