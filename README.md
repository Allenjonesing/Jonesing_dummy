# Jonesing Dummy Mod

Standalone crash-test dummies and GTA-style walking NPCs for BeamNG.drive.

---

## Spawning dummies via hotkey

The mod adds two user-assignable actions that appear in BeamNG's **Controls** settings:

| Action | Default binding | Description |
|--------|----------------|-------------|
| **Spawn Ped Dummies** | **F7** | Spawns a row of `agenty_dummy` props ahead of the player vehicle |
| **Despawn / Clear Dummies** | **F8** | Removes all dummies spawned through the hotkey |

Both actions default to **F7** (spawn) and **F8** (despawn) — you can rebind them at any time.

### How to bind the hotkeys in BeamNG Controls

F7 and F8 are set as defaults. To rebind them:

1. Open **Options** → **Controls** (or press **Escape → Options → Controls**).
2. In the search box at the top type **"Jonesing"** (or browse to the **Jonesing Dummy Mod** category).
3. Click the binding next to **Spawn Ped Dummies** and press your preferred key.
4. Click the binding next to **Despawn / Clear Dummies** and press your preferred key.
5. Click **Save** and close Options.

### How it works

* `ui/inputActions/jonesingDummyMod.json` defines the two actions (`actionMap`, `name`, `description`, `isTrigger: true`) so BeamNG merges them into the Controls UI and the **"Jonesing Dummy Mod"** category appears in **Options → Controls → Bindings**.
* `settings/inputmaps/jonesingDummyMod.json` seeds the default (empty) key bindings for those action names.
* `lua/ge/extensions/gameplay/jonesingDummySpawner.lua` is a GE-side extension that listens for the actions via `onInputAction` and calls `core_vehicles.spawnNewVehicle("agenty_dummy", ...)` with the `Normal` config — the same vehicle used when spawning dummies through other means.

### Tuning spawn parameters

Open `lua/ge/extensions/gameplay/jonesingDummySpawner.lua` and adjust the constants near the top:

```lua
local SPAWN_COUNT  = 3      -- how many dummies per key press
local SPAWN_CONFIG = "Normal"  -- which .pc config to use (Normal, Ragdoll, Female, …)
local SPAWN_SPACING = 1.5   -- metres between dummies in the row
local SPAWN_FORWARD = 4.0   -- metres ahead of the player to place the row
local COOLDOWN      = 0.5   -- minimum seconds between key activations
```

Available configs (from `vehicles/agenty_dummy/`):

| Config | Description |
|--------|-------------|
| `Normal` | Standard standing dummy |
| `Ragdoll` | Floppy ragdoll |
| `Female` | Female body model |
| `Sitting` | Pre-posed seated |
| `Small` | Child-scale dummy |
| `Unbreakable` | Won't break apart on impact |

---

## In-game verification / testing

1. Start **Free Roam** on any map.
2. Press `F7` — you should see 3 dummies spawn ~4 m ahead of your vehicle.  
   Check the **Lua console** (`` ` `` key → open Lua console) for log lines:
   ```
   [I] jonesingDummySpawner: spawning 3 ped dummy(s) ahead of player
   [I] jonesingDummySpawner: spawned agenty_dummy id=…
   ```
3. Press `F7` again within 500 ms — nothing should happen (cooldown).
4. Press `F8` — all 3 dummies should vanish and the console should show:
   ```
   [I] jonesingDummySpawner: despawning 3 tracked ped dummy(s)
   ```

---

## File map

```
lua/
  controller/
    agentyDummyPositioner.lua   — positions seated dummies inside cars
    jonesingGtaNpc.lua          — GTA-style walking NPC controller
  ge/
    extensions/
      gameplay/
        jonesingDummySpawner.lua  ← NEW: hotkey input handler & spawner

ui/
  inputActions/
    jonesingDummyMod.json         ← NEW: action definitions (shown in Controls UI)

settings/
  inputmaps/
    jonesingDummyMod.json         ← NEW: default (empty) key binding seeds

vehicles/
  agenty_dummy/                   — vehicle model & .pc configs for the prop dummy
```
