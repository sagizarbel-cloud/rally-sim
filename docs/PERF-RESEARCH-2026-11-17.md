# SHAKEDOWN fullscreen performance: where the frame goes (research, 2026-11-17)

No code changes here. This is the measured state of PR #4 (`claude/project-thread-gogg6v`, 33f5b58)
on the M1 MacBook Air (7-core GPU, Metal 3), and the techniques that would make the **same picture
cheaper**. Turning effects down is not on this list (see sagi's verdict below).

## Verdict that frames this

> "i asked for optimization and you just turned down graphic intensive processes"

Commits 05221be and 33f5b58 cut SSAO/glow defaults, shadow range, shadow splits (4 to 2), tree detail
range (110 to 80 m) and the tree backlight. That is the same kind of masking as render scale. Those
turn-downs should be **restored** once the real costs below are fixed.

## Measured (fullscreen SHAKEDOWN, three drives today)

Cells: median fps / 5th-percentile fps, triangles per frame. main and 05221be were vsync-capped at 60;
33f5b58 was uncapped.

| Time of day | main | 05221be (SSAO off) | 33f5b58 (SSAO off) |
|---|---|---|---|
| Noon | 60 / 50, 656k | 48 / 39, 1188k | 48 / 41, 760k |
| Morning | 60 / 48, 972k | 54 / 41, 1149k | 46 / 36, 987k |
| Whole stage | 60 / 48 | 58 / 41 | 47 / 37 |

- With SSAO and glow off, the frame takes about **21 ms** of GPU time. 120 fps needs **8.3 ms**. With them on, it takes about 26 ms (38.5 fps).
- 33f5b58 is not measurably slower than 05221be under the same settings. It feels worse because vsync is off: frames arrive unevenly and the image tears, while the 60 cap hid that.
- Game code is not the bottleneck. Physics is about 3.3 ms (main: 4.9 ms) and the CPU side of rendering about 1.2 ms. Draw calls are 798 (main: 1498).
- Godot 4.4 on Metal reports **0 for GPU time**, so the HUD's GPU readout stays blank. Uncapped fps is the only measure from inside the game.
- **The first 30 seconds is the forest, not shader compiles.** After [B], fps by 5 s step: 59, 61, 54, 47, 47, 47... It holds 60 while the start area is open, then drops to about 47 as the road enters the trees, at the same moment triangles jump from about 0.5M to 1.0-1.4M. main stays at 60 for the whole first minute.
- Hitches:
  - Turning SSAO or glow on mid-drive causes one 170 ms compile, which the warm-up doesn't cover.
  - The streamer has 44 small stalls, 1.9 s in total over 346 s.
- Frame log: `framelog-2026-11-17T16-09-23.csv` on the Mac (135 columns, 17,746 frames).

## Where the time goes (most likely first; unconfirmed until a per-pass capture)

1. **The forest.** About one tree every 5.75 m. Near meshes reach 80 m, with far meshes and a shadow silhouette beyond. Every vertex runs the sway function, in the colour pass and again in every shadow cascade.
2. **Shadows of the forest.** Every tree near the road is drawn again into the shadow map each frame. main had no trees, so its shadow pass was nearly empty.
3. **The cloud sky.** Five octaves of value noise per sky pixel, at half resolution. main used ProceduralSkyMaterial, which is nearly free. In a forest the sky is a smaller share of the screen, so this probably ranks below 1 and 2.
4. **Pixel count.** The game rendered fullscreen at 2880x1800 (5.2 Mpx), but the panel reports **2560x1600** (4.1 Mpx). That is about 27% more pixels than the screen physically has. The compositor then scales them down, so they add cost without sharpness. Every per-pixel cost above is multiplied by this.
5. **SSAO and glow.** About 5 ms on top, in passes that each read and write the whole screen. That is expensive on a tile-based GPU like the M1, where each extra full-screen pass costs memory bandwidth.
6. **Dirt/dust plumes.** Up to 240 alpha-blended quads per emitter, and SHAKEDOWN is gravel throughout. When the chase cam sits in the plume, layered transparent quads covering the screen are a classic cost that nothing has measured yet. The frame log has an effects-particles column to correlate against.

## Techniques that keep the picture (ranked by value for effort)

| # | Technique | What it fixes | Fidelity cost | Effort |
|---|---|---|---|---|
| 1 | **Per-pass GPU capture** (Xcode Metal frame capture or Instruments' Metal System Trace) of one frame in the forest | Replaces the ranking above with real milliseconds per pass | none | ~30 min at the Mac |
| 2 | **Render at the panel's physical resolution** (2560x1600 rather than 2880x1800): check how Godot picks the fullscreen size and the window's HiDPI setting | ~21% fewer pixels | None. These are the screen's real pixels, not upscaling. Verify the panel spec first. | small |
| 3 | **Bake the sky** into a panorama or cubemap once per time of day, and show that texture | Removes the sky's per-pixel noise | none (rebake over a few frames if clouds should drift) | small |
| 4 | **Sway only where it shows**: skip the sway in the shadow pass (`!SHADOW` / depth-only path) and fade it out on far trees | Vertex work in every shadow cascade | none visible (shadow outlines barely move) | small |
| 5 | **Shadow casters by need**: only trees within ~40 m of the road cast real-time shadows; further out, bake the canopy's shade into ground vertex colour per time of day (sun is fixed per preset) | Shadow-pass triangles | none (far shadows are static) | medium |
| 6 | **Impostors for far trees**: octahedral or cross billboards beyond about 30-40 m, chosen by size on screen rather than fixed metres, with visibility-range fade | Most of the triangle jump at the forest edge (0.5M to 1.4M) | Low when done well. Alpha-tested quads can cost more than they save, so measure. | medium |
| 7 | **Occlusion culling from the terrain**: build `ArrayOccluder3D` from coarse chunk heights so hills hide the chunks and trees behind them | Hidden geometry in rolling terrain | none | medium |
| 8 | **Baked AO**: vertex AO for terrain under trees and in crowns (static), so SSAO is only needed near the car | Most of SSAO's job, at no per-frame cost | none (arguably better: no screen-space halos) | medium |
| 9 | **Glow from the levels that contribute**: with a 1.2 HDR threshold, only the sun and sky bloom. Check which glow levels actually add anything, and skip the full-resolution first level. | Glow's full-resolution pass | none if the dropped levels add nothing (measure with a capture) | small |
| 10 | **Warm-up covers SSAO and glow too** (toggle them on for one frame at boot) | The 170 ms hitch when they are turned on | none | small |
| 11 | **Dust plumes**: fewer, larger puffs with soft-particle fade, and a cap on how much screen they cover when the camera is inside the cloud | Transparent overdraw on gravel | low | medium |
| 12 | **Try the Mobile renderer as an experiment**: it is built for tile-based GPUs and runs tonemap and glow in subpasses | Bandwidth on the M1 | High: it has no SSAO. Only a benchmark to learn how much Forward+ itself costs, not a fix. | small |

Not proposed:
- **Render scale or MetalFX upscaling.** It hides the cost rather than fixing it. Godot 4.4 does support MetalFX. Revisit only at much higher fidelity.

Also worth noting:
- **Fanless MacBook Air.** Sustained uncapped runs heat the chip, and it then slows itself down. Compare drives only at the same thermal state, for example by running a cool-down before each drive or comparing only the first two minutes.
- **`project.godot` has `verbose_stdout=true`.** It adds a small CPU cost from logging and is worth turning off outside debugging.

## Suggested order

1. Capture one frame per pass (1).
2. Do the cheap, safe ones: native panel resolution (2), baked sky (3), no sway in the shadow pass (4), full warm-up (10).
3. Measure again uncapped.
4. Rework the forest: shadow casters (5), impostors (6), occlusion (7).
5. Restore the turn-downs from 05221be and 33f5b58: 4 splits, 110 m tree detail, tree backlight.
6. Add baked AO (8) and judge SSAO and glow on top of that baseline.
