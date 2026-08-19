# Execution prompt — the deformable patch's unloaded tiles render pristine

Paste this into a fresh session. It is an EXECUTION prompt: diagnose, fix, verify, then stop at
the user's visual checklist.

---

Read `CLAUDE.md` and `docs/ROADMAP.md` first. The bug is entirely inside
**`scripts/terrain.gd`** (the flagship deformable centre patch — the DIRT CIRCLE / centre dirt
patch, radius 75 m, `zone_size` square). Nothing outside that file is implicated.

## The symptom, in the user's words

> "the dirt tiles/squares still have the rendering issue where unloaded tiles are much lighter
> than loaded ones"

Reported 2026-08-15 with a screenshot showing a hard brightness seam across the centre patch.
"still" — this has been noticed before and not yet fixed.

## Near-certain root cause (verify first, but this fits the symptom exactly)

**Every unloaded tile renders as pristine, undug dirt, and always will, because all of them share
one material pointing at one uniform 2×2 texture.**

The patch has two render paths for the same ground, and swaps between them by visibility:

| | flat "unloaded" quad | live "loaded" tile |
|---|---|---|
| built in | `_build_flat_visuals()` (~:136) | `_make_tile()` (~:213) |
| mesh | `_flat_quad`, an undivided `PlaneMesh` | `_plane`, tessellated `_tn × _tn` |
| material | **`_flat_mat` — ONE instance shared by every quad** | `t.mat`, one per tile |
| height texture | **`_flat_tex` — ONE 2×2 image filled with `bed_height / height_scale`** | `t.tex`, `_tn × _tn`, updated as the wheels dig |
| `texel` | `0.5` | `1.0 / _tn` |

The swap is at `:257` (`_flat_vis[key].visible = false` when a tile goes live) and `:403-404`
(`_flat_vis[key].visible = true`, commented *"back to a plain flat square"*, when it is released).

The shader colours ground by depth below the bed:
```
depth = clamp((bed - vh - 0.015) / maxsink, 0, 1);
c = mix(dirt, rut, depth);          // dirt 0.66,0.48,0.26  ->  rut 0.22,0.15,0.08
```
`_flat_tex` is a constant fill at exactly `bed_height`, so for every unloaded tile `vh == bed`,
`depth == 0`, and the colour is **always pure `dirt`** — the lightest value the shader can
produce. `rut_color` is roughly a third the brightness of `dirt_color`, so a dug tile next to an
undug one is a large, hard-edged step.

**Consequence to state plainly: driving away from ruts visually erases them.** The tile unloads,
the pristine flat quad takes over, and the churned ground you just made snaps back to smooth light
brown. The ruts still exist in `t.heights` (and in the collider while loaded) — only the unloaded
*visual* is wrong.

## Rule this in or out in one observation, before writing code

Spawn on the centre patch (`[B]` cycles circuits; DIRT CIRCLE is the centre skid-pad) and **do not
drive**. Look at the boundary between the live tiles around the car and the flat quads beyond.

- **No seam on undriven ground → the diagnosis above is confirmed.** The seam is dug ruts
  disappearing on unload, and the fix is to make unloaded tiles render their own height data.
- **A seam even with zero deformation → there is a SECOND, independent problem** in how the two
  paths shade identically-flat ground. In that case bisect with a temporary shader edit: force
  `ALBEDO = dirt;` unconditionally. If the seam survives that, it is the `NORMAL` (computed in
  `vertex()` from height-texture finite differences, using different `texel` values and very
  different mesh tessellation between the two paths) and therefore lighting, not the colour mix.
  Remove the temporary edit either way.

## Fix direction (do not over-build this)

Unloaded tiles need to keep showing their own deformation. The cheap shape:

- Keep a small **persistent per-tile visual texture** that survives unload — downsample `t.img`
  when a tile is released rather than discarding the state.
- Give each flat quad **its own `ShaderMaterial`** bound to that tile's texture, instead of every
  quad sharing `_flat_mat` with the uniform 2×2. Set `texel` to match whatever resolution you pick.
- A tile that has never been dug can keep pointing at the shared pristine material, so undriven
  ground costs nothing extra.

**Watch the cost.** `_ntiles = zone_size / tile_size`, so this is `_ntiles²` materials and textures
in the worst case — pick a low visual resolution (16×16 or 32×32 is plenty for rut *colour*; the
displacement only needs to look right at distance) and only allocate for tiles that have actually
been dug (`t.dug` already exists as that flag). **Measure it**: this project has an on-screen perf
readout on **`[J]`** (FPS, process ms, physics ms, draw calls, primitives), and a parallel session
has already been chasing frame-rate drops on loose surfaces — do not hand back a fix that trades a
seam for a stutter. Report draw calls and process ms before/after.

## What must not break

- **Collision is unaffected and must stay that way.** This is a rendering bug; `t.heights`, the
  `HeightMapShape3D`, and the dig/berm simulation are all correct. Do not touch the physics path.
- The centre patch is excluded from C1's procedural roughness field by design
  (`stage.deformable_patch_factor()`), because `terrain.gd` owns real geometry there. Leave that
  exclusion alone — it is not related to this bug.
- `dirt_color` / `rut_color` / `berm_color` are drive-approved contrast choices. The fix is to make
  unloaded tiles *use* the existing colours correctly, not to re-tune them.
- The four surface-effect names in `CLAUDE.md` are not involved here; this is terrain shading, not
  dirt/dust plumes or dirt/gravel particles. Do not conflate them.

## Working rules

- Compile gate: `./check.sh` must print `✅ Godot check clean` after every edit. It no-ops when
  nothing under `scripts/` changed — `rm -f .last_check` to force a real run.
- Validate with temporary print probes or temporary shader edits, then **remove them**.
- macOS has no `timeout`; use `--quit-after N` (N = FRAMES). Tabs, not spaces. `:=` cannot infer
  from a Variant.
- You cannot verify appearance headlessly. Hand the user a short visual checklist and stop.
- Update `CHANGELOG.md` when it closes, naming the symptom in the words a driver would use
  ("the ruts I just dug vanish when I drive away", "hard brightness seam across the dirt circle"),
  with the before/after numbers from `[J]`.
- When the gate is clean, commit and push to origin/main
  (`github.com/sagizarbel-cloud/rally-sim`).

## Suggested user visual checklist

- [ ] Dig a visible set of ruts on the centre patch, drive 50 m away, look back — the ruts are
  still there and the same colour as when they were under the car.
- [ ] No hard brightness step at the loaded/unloaded tile boundary, moving or stationary.
- [ ] Berms (the brighter piled soil) survive unload too, not just the dark ruts.
- [ ] `[J]` readout: draw calls and process ms no worse than before in a full lap of the dirt
  circle.
