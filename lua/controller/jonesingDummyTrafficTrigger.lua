-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummyTrafficTrigger.lua
-- Lightweight vehicle controller attached to the agenty_universal_dummy jbeam
-- slot (which fits the licenseplate_design_2_1 slot of any vehicle).
--
-- Purpose: when the Universal Dummy Mod is loaded (i.e. the license-plate slot
-- is occupied by the dummy mod), this controller bridges from the Vehicle-Engine
-- (VE) context to the Game-Engine (GE) context so that propRecycler can spawn
-- and recycle 10 jonesing_dummy pedestrians around the map as traffic.
--
-- VE → GE bridge:
--   init()   fires obj:queueGameEngineLua() to load propRecycler and spawn the
--            dummy pedestrian pool (idempotent — skips if already active).
--   reset()  no-op: the pool persists across vehicle resets.

local M = {}


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    obj:queueGameEngineLua(
        "extensions.load('propRecycler');" ..
        "propRecycler.spawn10DummiesAndStart({maxDistance=150,leadDistance=50,lateralJitter=10,debug=true});" ..
        "extensions.load('jonesingPoliceManager');" ..
        "extensions.load('jonesingPoliceHud')"
    )
end


local function reset()
    -- Vehicle reset (I-key / Insert-key): dummies are already alive on the map,
    -- so there is nothing to do here.  A new spawn must NOT be issued on every
    -- reset or the pool would grow by 10 on each respawn.
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset

return M
