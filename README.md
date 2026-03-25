🚷Jonesing Pedestrians

Jonesing Pedestrians is a BeamNG.drive mod that adds spawnable, moving pedestrian crash-test dummies to the world — building toward a more immersive sandbox experience.

📦 Repository Contents

This repository contains:
The latest Jonesing_Pedestrians.zip mod file
Source and controller adjustments used to build the mod
Packed releases ready for manual installation
The .zip file in this repo is the packaged mod and can be used directly in BeamNG.

🚗 Installing (Sideloading)

If the official BeamNG repository version is pending approval or not yet updated, you can manually install the mod:
Download the latest Jonesing_Pedestrians.zip from this repo.
Move the file into your BeamNG mods folder:
/BeamNG.drive/mods/
Launch BeamNG.drive
Ensure the mod is enabled in the in-game mod manager.
No extraction is required — BeamNG reads the .zip directly.

🌐 Official BeamNG Repository Page

The mod is also published on the official BeamNG repository:
https://www.beamng.com/resources/crash-test-dummy-pedestrian-traffic.36089/
Once approved, the repository version may be the easiest way to stay updated.

⚠️ Notes

Do not rename the .zip file once installed.
Keep file names consistent to avoid update warnings.
This repository may contain newer builds than the official repo while approval is pending.

---

🎨 Art File Map & Reskinning Guide

Everything you need to know about changing how the dummy looks.

## Where the Art Lives

The `art/` folder at the root of this repo contains **ground-model physics definitions only** (friction, sound, decals for flesh-surface interactions). It does **not** contain any textures or mesh data. See [`art/README.md`](art/README.md) for details.

All visual assets are stored under:

```
vehicles/common/AgentY_Dummy/
```

### Key files

| File | What it controls |
|---|---|
| `dummy.materials.json` | All material definitions: body color, organ colors, plastic parts, clothing |
| `AgentY_Dummy.dae` | Main body 3D mesh (Collada format) |
| `AgentY_Driver.dae` | Driver/stuntman 3D mesh |
| `Organs.dae` | Interior organ 3D mesh |
| `AgentY_Dummy_d.color.png` | Body diffuse (color) texture |
| `AgentY_Dummy_Organ_d.color.png` | Organ base color texture |
| `skins/dummy_skin.materials.json` | Skin override materials (colorable, humanoid, steel) |
| `skins/agenty_passengers_skins.jbeam` | Registers skin slots visible in the parts selector |
| `skins/AgentY_Dummy_col1/2/3_palette_uv0.color.png` | Color palette maps for the three colorable slots |

---

## How Materials Work

BeamNG uses a **PBR (Physically Based Rendering)** material system defined in `.materials.json` files (version 1.5).

Each material entry has a `Stages` array. The first stage is the main PBR stage:

```json
"MySkin": {
  "class": "Material",
  "Stages": [
    {
      "baseColorMap": "path/to/texture.png",   // diffuse texture
      "diffuseColor": [R, G, B, 1],            // multiplier or solid color
      "metallicFactor":  0.0,                  // 0 = non-metal, 1 = full metal
      "roughnessFactor": 0.5,                  // 0 = mirror-smooth, 1 = fully matte
      "clearCoatFactor": 0.0,                  // 0-1 lacquer layer
      "clearCoatRoughnessFactor": 1.0
    },
    {}, {}, {}
  ],
  "mapTo": "MySkin",
  "twoSided": true,                            // render both faces of the polygon
  "version": 1.5
}
```

**Tips:**
- `diffuseColor` multiplies on top of `baseColorMap`. Setting `baseColorMap` to `vehicles/common/null.dds` (a white 1×1 texture) means `diffuseColor` is the only color.
- `twoSided: true` makes the inner face of shell meshes visible — without it the backface appears transparent/dark when the outer shell is deformed.
- All organ materials (`organs_heart`, `organs_lung`, `organs_guts`, etc.) use `twoSided: true` or `doubleSided: true` so they are visible from any angle after the outer body breaks open.
- **`AgentY_Dummy_organ`** is the cavity lining (inner surface of the shell body). It **requires** `twoSided: true` — without it the inward-facing mesh is culled by the renderer and the inside appears black regardless of its color.

---

## Current Color Reference

### Outer Body (`AgentY_Dummy`, `AgentY_Dummy_plasticparts`)
- Color comes from the texture `AgentY_Dummy_d.color.png` (orange/tan dummy look)
- Both materials have `twoSided: true` so the inner face of the shell renders when broken

### Interior / Organs (vivid red, wet/glossy)
All interior materials are vivid red with low roughness (`0.2`) and high clearCoat (`0.8`) for a wet, bloody appearance:

| Material | RGB | roughness | clearCoat |
|---|---|---|---|
| `AgentY_Dummy_organ` (cavity lining) | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| `organs_heart` | `[0.9, 0.05, 0.1]` | 0.2 | 0.8 |
| `organs_lung` | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| `organs_liver` | `[0.75, 0.05, 0.05]` | 0.25 | 0.7 |
| `organs_guts` | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| `stomach-material` | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| `Bladder-material` | `[0.9, 0.1, 0.1]` | 0.2 | 0.8 |
| `Intestines_001` – `Intestines_010`, `Intestines.001` | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| Lung variants (`thairoid01_*`) | `[1.0, 0.05, 0.05]` | 0.2 | 0.8 |
| `Liver_Material-material` | `[0.75, 0.05, 0.05]` | 0.25 | 0.7 |

---

## How Skins Work

Skins are **material overrides** that replace specific base materials when a skin slot is active in-game.

### File structure for a skin named `myskin`

1. **Material override** — add entries to `skins/dummy_skin.materials.json`:

```json
"AgentY_Dummy.skin_dummy.myskin": {
  "name": "AgentY_Dummy.skin_dummy.myskin",
  "class": "Material",
  "Stages": [{
    "baseColorMap": "vehicles/common/null.dds",
    "diffuseColor": [R, G, B, 1],
    "metallicFactor": 0,
    "roughnessFactor": 0.85
  }, {}, {}, {}],
  "mapTo": "AgentY_Dummy.skin_dummy.myskin",
  "version": 1.5
},
"AgentY_Dummy_plasticparts.skin_dummy.myskin": {
  ...same pattern for joints/plastic parts...
}
```

> **Naming rule:** `[base_material_name].skin_[slotType].[skinName]`

2. **Skin registration** — add an entry to `skins/agenty_passengers_skins.jbeam`:

```json
"agenty_dummy_skin_myskin": {
  "information": { "authors": "You", "name": "My Skin" },
  "slotType": "skin_dummy",
  "skinName": "myskin"
}
```

3. **Config preset (optional)** — create `vehicles/agenty_dummy/myskin.pc`:

```json
{
  "format": 2,
  "mainPartName": "AgentY_Dummy",
  "model": "jonesing_dummy",
  "parts": {
    "AgentY_Dummy0_arm_L": "AgentY_Dummy0_arm_L",
    "AgentY_Dummy0_arm_R": "AgentY_Dummy0_arm_R",
    "AgentY_Dummy0_body_extra": "",
    "AgentY_Dummy0_extras": "",
    "AgentY_Dummy0_head": "AgentY_Dummy0_head",
    "AgentY_Dummy0_legs": "AgentY_Dummy0_legs",
    "AgentY_Dummy0_torso": "AgentY_Dummy0_torso",
    "AgentY_Dummy_breakable": "Breakable_yes",
    "AgentY_Dummy_connectors": "AgentY_Dummy_connectors",
    "AgentY_Dummy_mod": "",
    "AgentY_Dummy_stabilizers": "AgentY_Dummy_stabilizers",
    "licenseplate_design_2_1": "",
    "skin_dummy": "agenty_dummy_skin_myskin"
  },
  "vars": {
    "$adummy1weight": 1.20967742,
    "$adummy1scale": 1,
    "$adummy1stabilizers": 1000,
    "$adummy1strength": 6700
  }
}
```

4. **Config info** — create `vehicles/agenty_dummy/info_myskin.json`:

```json
{
  "Configuration": "My Skin (M)",
  "Description": "Short description of this skin",
  "Weight": 75,
  "Value": 131000
}
```

---

## Reskin Examples

### Example 1 — Humanoid Skin Tone (included in this PR)

Makes the dummy appear flesh-toned and more humanoid rather than the orange plastic default.

- **Skin name:** `humanoid`
- **Slot:** `skin_dummy`
- **Body color:** `diffuseColor: [0.82, 0.62, 0.48, 1]` (warm skin tone, matte)
- **Joints/plastic color:** `diffuseColor: [0.70, 0.50, 0.38, 1]` (slightly darker skin)
- **Files:** `skins/dummy_skin.materials.json`, `skins/agenty_passengers_skins.jbeam`, `vehicles/agenty_dummy/humanoid.pc`, `vehicles/agenty_dummy/info_humanoid.json`

### Example 2 — Steel Base (existing `angrydummy` skin)

Classic metallic chrome look.

- Uses `null.dds` + `metallicFactor: 1` for a full-metal reflective finish
- Defined in `skins/dummy_skin.materials.json` under `AgentY_Dummy_plasticparts.skin_dummy.angrydummy`

### Example 3 — Colorable Skins (existing `dummy_col1/2/3`)

Player-adjustable color using palette UV maps.

- Uses `colorPaletteMap` + `instanceDiffuse: true` so players can set a custom color in-game
- Palette textures: `skins/AgentY_Dummy_col1_palette_uv0.color.png` etc.

---

## Editing Textures

The body texture `AgentY_Dummy_d.color.png` (and its `.dds` counterpart) drives the orange/tan look of the default dummy. Editing this file directly will change the appearance of all non-skinned configurations.

**Recommended tools:**
- [GIMP](https://www.gimp.org/) — free, supports DDS via the DDS plugin
- [Paint.NET](https://www.getpaint.net/) — Windows, DDS plugin available
- [Substance Painter](https://www.adobe.com/products/substance3d-painter.html) — professional workflow, import the `.dae` mesh

**DDS format notes:**
- BeamNG prefers `BC3/DXT5` (with alpha) for color maps and `BC5/ATI2` for normal maps
- The `.color.dds` suffix is a BeamNG convention — the engine uses it to determine the texture role
- Always keep a `.png` source alongside the `.dds` so you can re-export after edits

---

## Quick Reference — Reskin Checklist

- [ ] Add material entries to `skins/dummy_skin.materials.json` (one per base material you want to override)
- [ ] Add a skin registration block to `skins/agenty_passengers_skins.jbeam`
- [ ] (Optional) Create `vehicles/agenty_dummy/<skinname>.pc` to add a config preset in the vehicle selector
- [ ] (Optional) Create `vehicles/agenty_dummy/info_<skinname>.json` for metadata
- [ ] Test in-game: spawn the dummy, open the Parts Selector, choose your skin under the "Skin" slot

