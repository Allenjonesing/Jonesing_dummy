-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummyTrafficTrigger.lua
-- Lightweight vehicle controller attached to the agenty_universal_dummy jbeam
-- slot (which fits the licenseplate_design_2_1 slot of any vehicle).
--
-- Purpose: when the Universal Dummy Mod is loaded (i.e. the license-plate slot
-- is occupied by the dummy mod), this controller bridges from the Vehicle-Engine
-- (VE) context to the Game-Engine (GE) context so that
-- jonesingDummyTrafficManager can spawn and recycle 10 agenty_dummy pedestrians
-- around the map as traffic.
--
-- VE → GE bridge:
--   init()   fires obj:queueGameEngineLua() to load the extension and pass
--            this vehicle's ID so the manager knows which vehicle to watch.
--   reset()  re-signals activation (vehicle was reset, not destroyed).

local M = {}


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    -- Load the GE extension (idempotent) and tell it a host vehicle is active.
    obj:queueGameEngineLua(
        "extensions.load('jonesingDummyTrafficManager');" ..
        "jonesingDummyTrafficManager.onDummyModActivated(" .. obj:getId() .. ")"
    )
end


local function reset()
    -- Vehicle reset (I-key / Insert-key).  The mod is still installed.
    obj:queueGameEngineLua(
        "extensions.load('jonesingDummyTrafficManager');" ..
        "jonesingDummyTrafficManager.onDummyModActivated(" .. obj:getId() .. ")"
    )
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset

return M
