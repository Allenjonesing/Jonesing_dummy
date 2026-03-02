-- lua/ge/extensions/jonesingPoliceManager.lua
-- GTA-style wanted / police pursuit system for BeamNG.drive.
-- Uses the BeamNG extension system – do NOT modify any vanilla game files.
-- Safe to hot-reload; gracefully degrades if traffic/police APIs are absent.

local M = {}
M.dependencies = { "core_vehicles" }

local TAG = "jonesingPoliceManager"

-- ---------------------------------------------------------------------------
-- Logging helpers (respect debugLog flag)
-- ---------------------------------------------------------------------------
local cfg = {} -- populated in _loadConfig()

local function logI(msg, ...) log("I", TAG, string.format(msg, ...)) end
local function logW(msg, ...) log("W", TAG, string.format(msg, ...)) end
local function logE(msg, ...) log("E", TAG, string.format(msg, ...)) end
local function logD(msg, ...)
    if cfg.debugLog then log("D", TAG, string.format(msg, ...)) end
end

-- ---------------------------------------------------------------------------
-- Default config (overridden by JSON file)
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    enabled                    = true,
    debugLog                   = false,
    wantedDecayPerSecond       = 0.05,
    wantedMax                  = 5,
    thresholds = {
        speedingMph            = 85,
        collisionDamageDelta   = 250,
        dummyHitWanted         = 1,
        trafficHitWanted       = 1,
    },
    spawnRules = {
        ["1"] = { units = 1, aggression = 0.3 },
        ["2"] = { units = 2, aggression = 0.5 },
        ["3"] = { units = 3, aggression = 0.7, roadblockRequest = true },
        ["4"] = { units = 4, aggression = 0.85, spikeStripRequest = true },
        ["5"] = { units = 6, aggression = 1.0 },
    },
    spawnCooldownSeconds           = 8.0,
    minDistanceFromPlayerMeters    = 60,
    maxDistanceFromPlayerMeters    = 350,
    despawnDistanceMeters          = 600,
    policeVehiclePool = {
        "fullsize_police",
        "police",
        "roadsurfer_police",
        "midsize_police",
    },
    -- Lua pattern matched (case-insensitive) against each vehicle's model/jbeam
    -- filename to identify police vehicles in the scene.
    policeNamePattern = "police",
}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------
local state = {
    wantedLevel    = 0,      -- 0..wantedMax  (discrete stars)
    wantedHeat     = 0.0,    -- float accumulator; stars = floor(heat)
    lastSpawnTime  = 0,
    lastRefreshTime = 0,     -- last time pursuit was refreshed on existing cops
    spawnedPoliceIds = {},   -- set: [numericId] = true
    playerVehId    = nil,    -- numeric id of current player vehicle
    speedingTimer  = 0.0,    -- seconds above speed threshold
    prevDamage     = nil,    -- last known damage value for player vehicle
    inCareer       = false,  -- true if career/scenario detected
    updateAccum    = 0.0,    -- dt accumulator for throttling
    eventsExt      = nil,    -- reference to jonesingPoliceEvents module
}

local UPDATE_INTERVAL   = 0.25   -- run main logic 4× per second
local REFRESH_INTERVAL  = 2.0    -- re-issue pursuit commands every N seconds
-- Distance threshold (metres) for passive native-police detection when hooks
-- don't fire.  Kept short to avoid false-positives from parked roadside cars.
local NATIVE_DETECT_RADIUS = 80

-- ---------------------------------------------------------------------------
-- Config loader
-- ---------------------------------------------------------------------------
local function _deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _deepMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local function _loadConfig()
    -- Start with hard defaults
    cfg = {}
    _deepMerge(cfg, DEFAULTS)

    -- Try to read the JSON override from the mod's settings folder
    local paths = {
        "settings/jonesingPoliceManager.json",
        "/settings/jonesingPoliceManager.json",
    }
    for _, p in ipairs(paths) do
        local ok, content = pcall(function()
            return readFile(p)
        end)
        if ok and content and #content > 0 then
            local ok2, parsed = pcall(function() return jsonDecode(content) end)
            if ok2 and type(parsed) == "table" then
                _deepMerge(cfg, parsed)
                logI("Config loaded from %s", p)
                return
            else
                logW("Config JSON parse error in %s: %s", p, tostring(parsed))
            end
        end
    end
    logI("Using default config (no JSON file found at settings/jonesingPoliceManager.json).")
end

-- ---------------------------------------------------------------------------
-- Player vehicle tracking helpers
-- ---------------------------------------------------------------------------
local function _getPlayerVeh()
    if not be then return nil end
    local ok, v = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and v then return v end
    return nil
end

local function _getPlayerVehId()
    local v = _getPlayerVeh()
    if not v then return nil end
    local ok, id = pcall(function()
        if v.getId then return v:getId() end
        return nil
    end)
    if ok and id then return tonumber(id) end
    return nil
end

-- Return current vehicle position as vec3 or nil
local function _playerPos()
    local v = _getPlayerVeh()
    if not v then return nil end
    local ok, pos = pcall(function() return v:getPosition() end)
    if ok and pos then return pos end
    return nil
end

-- Return speed in mph or nil
local function _playerSpeedMph()
    local v = _getPlayerVeh()
    if not v then return nil end
    if not v.getVelocity then return nil end
    local ok, vel = pcall(function() return v:getVelocity() end)
    if not ok or not vel then return nil end
    local spd_ms = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
    return spd_ms * 2.23694  -- m/s → mph
end

-- Return current cumulative damage for player vehicle, or nil
local function _playerDamage()
    local v = _getPlayerVeh()
    if not v then return nil end
    -- Try the most common API
    local ok, d = pcall(function()
        if v.getDamage then return v:getDamage() end
        if v.getTotalDamage then return v:getTotalDamage() end
        return nil
    end)
    if ok and type(d) == "number" then return d end
    return nil
end

-- ---------------------------------------------------------------------------
-- Wanted level management
-- ---------------------------------------------------------------------------
local function _updateStars()
    state.wantedLevel = math.max(0, math.min(cfg.wantedMax,
        math.floor(state.wantedHeat)))
end

function M.addWanted(amount, reason)
    if not cfg.enabled then return end
    local prev = state.wantedLevel
    state.wantedHeat = math.max(0,
        math.min(cfg.wantedMax, state.wantedHeat + (amount or 0)))
    _updateStars()
    if state.wantedLevel ~= prev then
        logI("Wanted changed %d → %d (reason: %s)", prev, state.wantedLevel,
            tostring(reason or "unknown"))
        -- Toast notification so it's unmissable regardless of HUD state
        local msg
        if state.wantedLevel == 0 then
            msg = "Wanted level cleared"
        else
            msg = string.format("WANTED: %d star%s",
                state.wantedLevel, state.wantedLevel == 1 and "" or "s")
        end
        pcall(function()
            guihooks.trigger("Message",
                { msg = msg, category = "wanted", icon = "warning" })
        end)
    elseif amount ~= 0 then
        logD("addWanted %.2f (heat=%.2f stars=%d) reason=%s",
            amount, state.wantedHeat, state.wantedLevel,
            tostring(reason or "unknown"))
    end
end

function M.setWanted(level, reason)
    level = math.max(0, math.min(cfg.wantedMax, math.floor(level or 0)))
    state.wantedHeat  = level
    state.wantedLevel = level
    logI("Wanted set to %d (reason: %s)", level, tostring(reason or "manual"))
    local msg = level == 0 and "Wanted level cleared"
        or string.format("WANTED: %d star%s", level, level == 1 and "" or "s")
    pcall(function()
        guihooks.trigger("Message",
            { msg = msg, category = "wanted", icon = "warning" })
    end)
end

function M.clearWanted(reason)
    state.wantedHeat  = 0
    state.wantedLevel = 0
    logI("Wanted cleared (reason: %s)", tostring(reason or "manual"))
    pcall(function()
        guihooks.trigger("Message",
            { msg = "Wanted level cleared", category = "wanted", icon = "info" })
    end)
    -- Despawn all police immediately
    M._despawnAll()
end

-- ---------------------------------------------------------------------------
-- Public integration point: Jonesing Pedestrians calls this
-- ---------------------------------------------------------------------------
function M.reportDummyHit(severity)
    if not cfg.enabled then return end
    severity = tonumber(severity) or 1
    local amount = (cfg.thresholds and cfg.thresholds.dummyHitWanted or 1) * severity
    M.addWanted(amount, "dummy_hit")
end

-- ---------------------------------------------------------------------------
-- Career / scenario detection
-- ---------------------------------------------------------------------------
local function _detectCareer()
    -- If scenario or career systems are active, back off gracefully.
    local inScenario = scenario_scenarios and scenario_scenarios.getScenario and
                        scenario_scenarios.getScenario() ~= nil
    local inCareerMode = career_career and career_career.isActive and
                          career_career.isActive()
    state.inCareer = (inScenario == true) or (inCareerMode == true)
    if state.inCareer then
        logD("Career/scenario active – police manager in standby.")
    end
    return state.inCareer
end

-- ---------------------------------------------------------------------------
-- Police vehicle spawning
-- ---------------------------------------------------------------------------
local function _pickPoliceModel()
    local pool = cfg.policeVehiclePool
    if not pool or #pool == 0 then
        return "fullsize_police"
    end
    return pool[math.random(1, #pool)]
end

local function _spawnPoliceVehicle(pos, rot)
    local model = _pickPoliceModel()
    local spawnOpts = {
        pos              = pos,
        rot              = rot,
        paint            = nil,
        partConfig       = "",
        cling            = false,
        autoEnterVehicle = false,
        setPlayerVehicle = false,
    }

    -- Attempt via core_vehicles (preferred, mirrors propRecycler pattern)
    if core_vehicles and core_vehicles.spawnNewVehicle then
        local ok, id = pcall(core_vehicles.spawnNewVehicle, model, spawnOpts)
        if ok and id then
            logD("Spawned police vehicle '%s' id=%s", model, tostring(id))
            return tonumber(id)
        end
    end

    -- Fallback: spawn global
    if spawn and spawn.spawnVehicle then
        local ok, id = pcall(spawn.spawnVehicle, model, spawnOpts)
        if ok and id then return tonumber(id) end
    end

    logW("Failed to spawn police vehicle '%s'.", model)
    return nil
end

local function _findSpawnPose()
    local ppos = _playerPos()
    if not ppos then return nil end

    -- Use the events module if available for smart road-aware placement
    if state.eventsExt and state.eventsExt.findSpawnPose then
        local pose = state.eventsExt.findSpawnPose(
            ppos, nil,
            cfg.minDistanceFromPlayerMeters,
            cfg.maxDistanceFromPlayerMeters)
        if pose then return pose end
    end

    -- Fallback: place along a random bearing at minDist
    local minD = cfg.minDistanceFromPlayerMeters or 60
    local angle = math.random() * 2 * math.pi
    local offset = vec3(math.cos(angle) * minD, math.sin(angle) * minD, 0)
    local targetPos = vec3(ppos.x + offset.x, ppos.y + offset.y, ppos.z)
    local rot = quat(0, 0, 0, 1)
    return { pos = targetPos, rot = rot }
end

function M._despawnAll()
    for id, _ in pairs(state.spawnedPoliceIds) do
        local o = be and be:getObjectByID(id)
        if o then
            pcall(function() o:delete() end)
        end
        logD("Despawned police id=%d", id)
    end
    state.spawnedPoliceIds = {}
end

local function _despawnFarPolice()
    local ppos = _playerPos()
    if not ppos then return end
    local maxD2 = cfg.despawnDistanceMeters * cfg.despawnDistanceMeters
    for id, _ in pairs(state.spawnedPoliceIds) do
        local o = be and be:getObjectByID(id)
        if not o then
            state.spawnedPoliceIds[id] = nil
        else
            local ok, opos = pcall(function() return o:getPosition() end)
            if ok and opos then
                local dx = opos.x - ppos.x
                local dy = opos.y - ppos.y
                local dz = opos.z - ppos.z
                if dx*dx + dy*dy + dz*dz > maxD2 then
                    pcall(function() o:delete() end)
                    state.spawnedPoliceIds[id] = nil
                    logD("Despawned far police id=%d", id)
                end
            else
                -- Object vanished
                state.spawnedPoliceIds[id] = nil
            end
        end
    end
end

local function _countActivePolice()
    local count = 0
    for id, _ in pairs(state.spawnedPoliceIds) do
        local o = be and be:getObjectByID(id)
        if o then
            count = count + 1
        else
            state.spawnedPoliceIds[id] = nil  -- clean up stale entries
        end
    end
    return count
end

-- Scan all scene vehicles and return a set of IDs whose model/name contains 'police'.
-- This includes native game police AND any vehicles we spawned.
local function _getAllScenePoliceIds()
    local ids = {}
    if not be then return ids end
    local n = 0
    local ok0, err = pcall(function() n = be:getVehicleCount() end)
    if not ok0 then logD("getVehicleCount failed: %s", tostring(err)) end
    local pattern = (cfg.policeNamePattern or "police"):lower()
    for i = 0, n - 1 do
        pcall(function()
            local veh = be:getVehicle(i)
            if not veh then return end
            local name = ""
            -- getJBeamFilename() returns the model folder name (e.g. "fullsize_police")
            local ok1, jn = pcall(function() return veh:getJBeamFilename() end)
            if ok1 and type(jn) == "string" then name = jn end
            -- Fallback: getName()
            if name == "" then
                local ok2, sn = pcall(function() return veh:getName() end)
                if ok2 and type(sn) == "string" then name = sn end
            end
            if name:lower():find(pattern) then
                local ok3, vid = pcall(function() return veh:getID() end)
                if ok3 and vid then ids[tonumber(vid)] = true end
            end
        end)
    end
    return ids
end

local function _countAllScenePolice()
    local n = 0
    for _ in pairs(_getAllScenePoliceIds()) do n = n + 1 end
    return n
end

local function _managePolice(now)
    local level = state.wantedLevel
    if level < 1 then
        -- Passive detection fallback: if a police vehicle is within 80 m of the
        -- player and the native pursuit hooks haven't fired yet, treat as start.
        local ppos = _playerPos()
        if ppos then
            for id in pairs(_getAllScenePoliceIds()) do
                local o = be and be:getObjectByID(id)
                if o then
                    local ok, opos = pcall(function() return o:getPosition() end)
                    if ok and opos then
                        local dx = opos.x - ppos.x
                        local dy = opos.y - ppos.y
                        if (dx*dx + dy*dy) < (NATIVE_DETECT_RADIUS * NATIVE_DETECT_RADIUS) then
                            logI("Native police detected nearby – setting wanted 1.")
                            M.addWanted(1, "native_police_nearby")
                            break
                        end
                    end
                end
            end
        end
        -- Ensure our own spawned extras are despawned
        if next(state.spawnedPoliceIds) then
            logI("Wanted dropped to 0 – despawning police.")
            M._despawnAll()
        end
        return
    end

    -- Despawn police that are too far
    _despawnFarPolice()

    -- Periodically re-issue pursuit commands so cops don't drift out of chase mode
    if (now - state.lastRefreshTime) >= REFRESH_INTERVAL then
        local rule = cfg.spawnRules and cfg.spawnRules[tostring(level)]
        local aggr = (rule and rule.aggression) or 1.0
        for id, _ in pairs(state.spawnedPoliceIds) do
            if state.eventsExt and state.eventsExt.assignPursuit then
                state.eventsExt.assignPursuit(id, state.playerVehId, aggr)
            end
        end
        state.lastRefreshTime = now
    end

    -- Check if it's time to spawn more
    if (now - state.lastSpawnTime) < cfg.spawnCooldownSeconds then return end

    local rule = cfg.spawnRules and cfg.spawnRules[tostring(level)]
    if not rule then
        logD("No spawn rule for wanted level %d", level)
        return
    end

    local desired    = rule.units     or 1
    local aggression = rule.aggression or 0.5
    -- Count ALL police in the scene (native game + our extras) so we don't
    -- over-spawn when the native system already has units chasing the player.
    local current    = _countAllScenePolice()

    if current >= desired then return end

    -- Spawn up to the desired count
    local toSpawn = desired - current
    logD("Wanted=%d desired=%d current=%d – spawning %d units",
        level, desired, current, toSpawn)

    for _ = 1, toSpawn do
        local pose = _findSpawnPose()
        if not pose then
            logW("Could not find spawn pose; skipping unit.")
            break
        end

        local newId = _spawnPoliceVehicle(pose.pos, pose.rot)
        if newId then
            state.spawnedPoliceIds[newId] = true
            -- Assign pursuit behavior
            if state.eventsExt and state.eventsExt.assignPursuit then
                state.eventsExt.assignPursuit(
                    newId, state.playerVehId, aggression)
            end
        end
    end

    state.lastSpawnTime = now

    -- Stub hooks for advanced tactics (logged but not yet implemented)
    if rule.roadblockRequest then
        logD("Wanted=%d: roadblock requested (stub – not yet implemented).", level)
    end
    if rule.spikeStripRequest then
        logD("Wanted=%d: spike strip requested (stub – not yet implemented).", level)
    end
end

-- ---------------------------------------------------------------------------
-- Wanted trigger: speeding
-- ---------------------------------------------------------------------------
local function _tickSpeeding(dt)
    local mph = _playerSpeedMph()
    if not mph then
        state.speedingTimer = 0
        return
    end
    local threshold = cfg.thresholds and cfg.thresholds.speedingMph or 85
    if mph > threshold then
        state.speedingTimer = state.speedingTimer + dt
        -- Ramp: +0.1 heat per second over threshold
        M.addWanted(0.1 * dt, "speeding")
    else
        -- Decay speeding timer quickly when below threshold
        state.speedingTimer = math.max(0, state.speedingTimer - dt * 2)
    end
end

-- ---------------------------------------------------------------------------
-- Wanted trigger: collision / damage (polling fallback)
-- ---------------------------------------------------------------------------
local function _tickDamage()
    local dmg = _playerDamage()
    if dmg == nil then
        state.prevDamage = nil
        return
    end
    if state.prevDamage == nil then
        state.prevDamage = dmg
        return
    end
    local delta = dmg - state.prevDamage
    state.prevDamage = dmg
    local threshold = cfg.thresholds and cfg.thresholds.collisionDamageDelta or 250
    if delta > threshold then
        M.addWanted(cfg.thresholds.trafficHitWanted or 1, "collision_damage")
    end
end

-- ---------------------------------------------------------------------------
-- Hook: vehicle damage event (non-polling path, if available)
-- NOTE: Hook name varies by BeamNG version.  Register defensively.
-- ---------------------------------------------------------------------------
function M.onVehicleTakenDamage(vid, damage)
    if not cfg.enabled or state.inCareer then return end
    if vid ~= state.playerVehId then return end
    if state.eventsExt then
        state.eventsExt.caps.hasVehicleDamageEvt = true
    end
    local delta = 0
    if type(damage) == "number" then
        delta = damage
    elseif type(damage) == "table" then
        delta = damage.damage or damage.delta or damage.value or 0
    end
    local threshold = cfg.thresholds and cfg.thresholds.collisionDamageDelta or 250
    if delta > threshold then
        M.addWanted(cfg.thresholds.trafficHitWanted or 1, "vehicle_damage_event")
    end
end

-- ---------------------------------------------------------------------------
-- Extension lifecycle hooks
-- ---------------------------------------------------------------------------
function M.onExtensionLoaded()
    _loadConfig()

    -- Load optional event normaliser (graceful if absent)
    local ok, evts = pcall(function()
        return extensions.load("jonesingPoliceEvents")
    end)
    if ok and evts then
        state.eventsExt = evts
        if evts.detect then evts.detect() end
        logI("jonesingPoliceEvents loaded and detected.")
    else
        logI("jonesingPoliceEvents not available; running in basic mode.")
    end

    logI("jonesingPoliceManager loaded. enabled=%s debugLog=%s",
        tostring(cfg.enabled), tostring(cfg.debugLog))

    -- Auto-load the HUD overlay (graceful if absent)
    pcall(function() extensions.load("jonesingPoliceHud") end)
end

function M.onInit()
    -- onInit fires earlier than onExtensionLoaded on some versions; re-load config
    if not next(cfg) then _loadConfig() end
end

-- ---------------------------------------------------------------------------
-- Vehicle tracking
-- ---------------------------------------------------------------------------
function M.onVehicleSpawned(vid)
    -- Check if the new vehicle is the player's vehicle
    local id = _getPlayerVehId()
    if id and id ~= state.playerVehId then
        logD("Player vehicle changed: %s → %s",
            tostring(state.playerVehId), tostring(id))
        state.playerVehId = id
        state.prevDamage  = nil  -- reset damage baseline
    end
end

function M.onVehicleDestroyed(vid)
    local numId = tonumber(vid)
    if numId then
        -- Was it a police vehicle?
        if state.spawnedPoliceIds[numId] then
            state.spawnedPoliceIds[numId] = nil
            logD("Police vehicle %d destroyed/removed.", numId)
        end
        -- Was it the player vehicle?
        if numId == state.playerVehId then
            state.playerVehId = nil
            state.prevDamage  = nil
            logD("Player vehicle %d destroyed.", numId)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main update tick
-- ---------------------------------------------------------------------------
function M.onUpdate(dtReal, dtSim, dtRaw)
    if not cfg.enabled then return end

    -- Throttle to UPDATE_INTERVAL
    state.updateAccum = state.updateAccum + (dtReal or 0)
    if state.updateAccum < UPDATE_INTERVAL then return end
    local dt = state.updateAccum
    state.updateAccum = 0

    -- Keep player vehicle id up-to-date
    local pid = _getPlayerVehId()
    if pid ~= state.playerVehId then
        state.playerVehId = pid
        state.prevDamage  = nil
        logD("Player vehicle id updated to %s", tostring(pid))
    end

    -- Pause if no player vehicle
    if not state.playerVehId then
        logD("No player vehicle; skipping update.")
        return
    end

    -- Pause in career/scenario modes
    _detectCareer()
    if state.inCareer then return end

    -- Trigger: speeding
    _tickSpeeding(dt)

    -- Trigger: damage polling (backup for when the event hook isn't available)
    if not (state.eventsExt and state.eventsExt.caps and
            state.eventsExt.caps.hasVehicleDamageEvt) then
        _tickDamage()
    end

    -- Decay wanted heat
    if state.wantedHeat > 0 then
        local decay = (cfg.wantedDecayPerSecond or 0.05) * dt
        state.wantedHeat = math.max(0, state.wantedHeat - decay)
        _updateStars()
    end

    -- Manage police units
    _managePolice(os.clock())
end

-- ---------------------------------------------------------------------------
-- Expose state for HUD / debugging
-- ---------------------------------------------------------------------------
function M.getWantedLevel()  return state.wantedLevel end
function M.getWantedHeat()   return state.wantedHeat end
-- Count ALL police vehicles in the scene (native game + any we spawned).
function M.getPoliceCount()  return _countAllScenePolice() end
function M.getConfig()       return cfg end

-- ---------------------------------------------------------------------------
-- Native pursuit hooks (fired by BeamNG's built-in police/traffic system)
-- Hook names vary between BeamNG versions; register all known variants.
-- ---------------------------------------------------------------------------
local function _onNativePursuitStart()
    if not cfg.enabled or state.inCareer then return end
    if state.wantedLevel < 1 then
        logI("Native pursuit started – setting wanted 1.")
        M.addWanted(1, "native_pursuit_started")
    end
end

-- Hook names seen across BeamNG versions
function M.onPlayerPursuitStart()  _onNativePursuitStart() end
function M.onPursuitStarted()      _onNativePursuitStart() end
function M.onPlayerWanted()        _onNativePursuitStart() end

-- ---------------------------------------------------------------------------
-- Hot-reload support: re-init cleanly
-- ---------------------------------------------------------------------------
function M.onExtensionUnloaded()
    M._despawnAll()
    logI("Unloaded – police despawned.")
end

return M
