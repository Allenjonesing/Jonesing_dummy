# jonesingPoliceManager

A lightweight, GTA-style wanted/police pursuit system for BeamNG.drive implemented as a **Lua Game Engine Extension**. It runs entirely inside the mod folder and never edits any vanilla BeamNG file.

---

## What it does

- Tracks a **Wanted Level (0–5)** for the player vehicle.
- Raises wanted heat from configurable triggers: speeding, collisions/damage, hitting dummy pedestrians, and hitting traffic.
- Spawns police vehicles near the player and assigns pursuit behaviour when the wanted level is ≥ 1.
- Scales the number and aggression of police units with the wanted level.
- Continuously decays wanted heat when the player is not triggering offences.
- Automatically despawns distant police units and all police when wanted drops to 0.
- Detects career/scenario mode and suspends itself gracefully.
- Survives game updates because it only uses published BeamNG extension APIs.

---

## Files

| Path | Purpose |
|---|---|
| `lua/ge/extensions/jonesingPoliceManager.lua` | Core extension (main logic) |
| `lua/ge/extensions/jonesingPoliceEvents.lua` | Optional event normalizer / capability adapter |
| `settings/jonesingPoliceManager.json` | User-tunable settings |
| `docs/jonesingPoliceManager.md` | This file |

---

## Configuration (`settings/jonesingPoliceManager.json`)

```json
{
  "enabled": true,
  "debugLog": false,
  "wantedDecayPerSecond": 0.05,
  "wantedMax": 5,
  "thresholds": {
    "speedingMph": 85,
    "collisionDamageDelta": 250,
    "dummyHitWanted": 1,
    "trafficHitWanted": 1
  },
  "spawnRules": {
    "1": { "units": 1, "aggression": 0.3 },
    "2": { "units": 2, "aggression": 0.5 },
    "3": { "units": 3, "aggression": 0.7, "roadblockRequest": true },
    "4": { "units": 4, "aggression": 0.85, "spikeStripRequest": true },
    "5": { "units": 6, "aggression": 1.0 }
  },
  "spawnCooldownSeconds": 8.0,
  "minDistanceFromPlayerMeters": 60,
  "maxDistanceFromPlayerMeters": 350,
  "despawnDistanceMeters": 600,
  "policeVehiclePool": [
    "fullsize_police",
    "police",
    "roadsurfer_police",
    "midsize_police"
  ]
}
```

### Key settings

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `true` | Master switch. Set to `false` to disable the system entirely. |
| `debugLog` | bool | `false` | Log verbose debug messages (useful during development). |
| `wantedDecayPerSecond` | float | `0.05` | Heat units lost per second passively. Raise to make wanted fade faster. |
| `wantedMax` | int | `5` | Maximum wanted stars (do not exceed 5). |
| `thresholds.speedingMph` | float | `85` | Speed in mph above which heat accumulates. |
| `thresholds.collisionDamageDelta` | float | `250` | Damage units per tick required to gain wanted heat from a collision. |
| `thresholds.dummyHitWanted` | float | `1` | Base heat increase per dummy pedestrian hit (multiplied by severity). |
| `thresholds.trafficHitWanted` | float | `1` | Heat increase per qualifying collision with traffic. |
| `spawnRules` | object | see above | Per-level spawn count and aggression (0.0–1.0). |
| `spawnCooldownSeconds` | float | `8.0` | Minimum seconds between spawn attempts. |
| `minDistanceFromPlayerMeters` | float | `60` | Police spawn at least this far from the player. |
| `maxDistanceFromPlayerMeters` | float | `350` | Police spawn no farther than this. |
| `despawnDistanceMeters` | float | `600` | Police farther than this are silently removed. |
| `policeVehiclePool` | list | see above | Internal BeamNG vehicle names used for spawned police. |

---

## Integrating with Jonesing Pedestrians

When a pedestrian dummy is hit, call the public function on the manager:

```lua
-- Inside your pedestrian mod Lua code:
local pm = extensions.jonesingPoliceManager
if pm and pm.reportDummyHit then
    pm.reportDummyHit(1)      -- severity = 1 (normal hit)
    -- pm.reportDummyHit(2)   -- severity = 2 (lethal hit)
end
```

`reportDummyHit(severity)` adds `dummyHitWanted × severity` heat to the wanted system. This is the stable, update-safe integration point between the two mods.

You can also call it via `extensions`:

```lua
if extensions and extensions.jonesingPoliceManager then
    extensions.jonesingPoliceManager.reportDummyHit(1)
end
```

---

## Public API

| Function | Description |
|---|---|
| `M.reportDummyHit(severity)` | Primary integration point for Jonesing Pedestrians. |
| `M.addWanted(amount, reason)` | Add (or subtract) wanted heat. |
| `M.setWanted(level, reason)` | Force wanted level to an exact star count. |
| `M.clearWanted(reason)` | Set wanted to 0 and despawn all police immediately. |
| `M.getWantedLevel()` | Return current discrete star count (0–5). |
| `M.getWantedHeat()` | Return raw float heat accumulator. |
| `M.getPoliceCount()` | Return number of active police units. |
| `M.getConfig()` | Return current live config table. |

---

## Known limitations and safe mode notes

1. **Pursuit AI quality** depends on which BeamNG version is installed. The system tries the traffic high-level pursuit API first, then falls back to vehicle-level `ai.setMode("chase")`, and finally just spawns police in traffic mode. All three paths are safe.

2. **Roadblock and spike strip requests** are stubbed with a log message. These require deeper traffic-graph integration that is not available in the current BeamNG public API surface. They can be filled in when the API is documented.

3. **Career / scenario mode**: the system detects `scenario_scenarios` and `career_career` activity and suspends police management while those are active. It does not interfere with scenario logic.

4. **Damage events**: BeamNG does not guarantee a stable `onVehicleTakenDamage` GE event across versions. The manager uses a polling fallback (comparing damage values each tick) and upgrades to the event path if the hook fires. No crash occurs in either case.

5. **Map with no road graph**: if traffic utilities cannot find a road-aligned spawn point, the system falls back to a simple radial offset spawn. Police will still appear but may not be on a road.

6. **No vanilla file edits**: this mod is fully self-contained. Removing the mod folder completely removes all its effects.
