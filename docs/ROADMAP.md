# Rally Sim — Roadmap & Working Notes

_Last updated: 2026-07-28. Living document — future sessions should read this first, then verify against current code._

Native Apple-Silicon (M1) realistic rally sim in **Godot 4.4 + Jolt**, built procedurally in code, grounded in real vehicle-dynamics literature. Design philosophy: **improve realism and fun through physical functions, not by tuning magic-number constants.**

**ACTIVE PLANS:** `docs/PLAN-drivetrain-suspension.md` (Arcs A/B/C — drivetrain, suspension, steering feel) and `docs/PLAN-stages-ground-map.md` (**Arc D — the ground map & real point-to-point stages**, planned 2026-08-13). **Arc C1 was accepted 2026-08-24, which unblocked Arc D; D1 (the ground map) is DONE and drive-verified 2026-08-27 — "all four hold", i.e. nothing about the car changed, which was the pass condition. D2 is DONE and drive-verified 2026-08-28 — lap/sector detection is now arc-length triggers on a per-circuit `Centreline` rather than `atan2` crossings and radius bands, `Centreline` handles open (point-to-point) roads, and timing/pace notes/wear no longer know the road is polar. **D3 is DONE and DRIVE-VERIFIED 2026-08-30 — "road is drivable and feels like a road", pace notes correct, corner rhythm accepted; five defects found and fixed on the verdict, including a §0 repeatability violation where stage parameters travelled in a float32 `Vector4` so "same seed = same stage" was simply not true (CHANGELOG 2026-08-30)** — the project now has **SHAKEDOWN**, a generated point-to-point stage on the fourth `[B]` entry, routed from stage parameters under real road-design constraints (minimum radius from design speed, maximum grade, AASHTO vertical curves) and living in its own area with the legacy map untouched. It grips, sounds, throws dust and gets pace notes without a line changing in `stage.gd`, `sound.gd`, `effects.gd`, `roughness.gd` or `wear.gd` — which is what D1's ground map and D2's centrelines were for. **D4 (chunked terrain, streaming and LOD) is BUILT and probe-verified 2026-08-30, awaiting its drive verdict** — SHAKEDOWN's ground is streamed as chunks on a global lattice instead of one 720 m slab, which lifts the stage to **4779 m timed / 4905 m of road**. Seam continuity and order independence pass EXACTLY (0.000000000 m step, 0 differing vertices), and §8 risk 6 was asserted at the new length and holds. **The plan's central assumption was wrong and the measurement is worth keeping:** the collider cook is 0.11 ms of a 16 ms chunk — 96% of the cost is `Centreline.nearest_point()` per vertex — so the spike is avoided by time-slicing the build under a hard per-tick budget, not by cooking ahead. See `CHANGELOG.md` 2026-08-30 (later). Two follow-ups landed 2026-08-28 ahead of it: the tyre audio now takes its surface from the ground map (the rally loop was being mixed as 40% tarmac), and `Centreline.nearest_point()` was fixed — it was returning the wrong sample at ~10% of road-edge positions, scrambling C1's washboard phase by up to 6 ridges exactly where washboard is masked to.** **D5 (the area manager and the connecting tunnel) is BUILT and probe-verified 2026-08-31, awaiting its drive verdict** — the two worlds are joined by a tunnel used as a PORTAL, because the stage's start line is 4149 m from the calibration map and a tunnel's two mouths need not be adjacent. The calibration bed is never unloaded (a cold rebuild costs 494 ms), so §1.1 is now structural. All four probes pass over 10 round trips — and the entry worth reading is that they ALL passed while the swap was flinging the car into open air beyond the far portal, because none of them could see where the car was. `scripts/ground_map.gd` is now the single authority for what the ground is at any (x, z) — every surface question (grip, road class, deformability, colour, audio) resolves through it.

**ACTIVE PLAN (2026-08-02): `docs/PLAN-drivetrain-suspension.md`** — phased, self-contained execution plan: 120 Hz tick + virtual pedals, then drivetrain arc (engine inertia/clutch/neutral, emergent engine braking, Salisbury + selectable diffs + centre coupling, shift model + assists, handbrake), then suspension arc (derived setup, digressive dampers, bump stops, relaxation length). Execute it phase-by-phase before picking other milestones.

---

## Where the project is (systems in place)

- **Vehicle** (`scripts/vehicle_m2.gd`): RigidBody3D + raycast suspension. Full **slip-ratio drivetrain** (per-wheel ω, Magic-Formula longitudinal via slip ratio + lateral via slip angle, **combined-slip friction ellipse**, load-sensitive grip `_mu_load`, viscous LSD, centre diff, AWD/RWD/FWD, manual 6-speed + reverse). Anti-roll bars, camber, emergent weight transfer.
- **Stage** (`scripts/stage.gd`): procedural rolling-hill heightmap. Three concentric circuits + a drag strip, all centred at origin: **rally loop** `_road(θ)=168+42·sin3θ+24·sin5θ`, **outer asphalt ring** `_asphalt_r(θ)` (~300, Monte-Carlo-inspired winding, abrupt shoulder + kerb), **centre deformable dirt patch** (radius 55), **4 km drag strip** spur (2026-08-12: `strip_len` derives `strip_x1`; distance posts every 100 m down both shoulders, billboard call-out every km, W-beam guard-rail arc round the far lip of the runoff pad). Per-surface grip `grip_at()`: asphalt 1.45 > dirt 1.0 > grass 0.8.
- **Audio** (`scripts/sound.gd`): steady engine drone loop pitched by rpm (ceiling **derived from redline**, not a constant); surface-aware tyre rumble + slide; cabin low-pass muffle in interior views. Raw-WAV parser bypasses Godot's truncating importer.
- **HUD** (`scripts/hud.gd`): rev bar, shift light, G-meter, per-wheel Fz/slipR/slipA/grip; reads lap timing from the time-trial node. In-cabin rev bar on the binnacle.
- **Co-driver pace notes** (`scripts/pace_notes.gd`): corners detected procedurally from road curvature + elevation → rally notes (dir, severity 1–6, long/tightens/opens/crest/into), **spoken via OS TTS** + on-screen. Rally loop only for now.
- **Time-trial ghost** (`scripts/time_trial.gd`): best-lap recording + translucent ghost, **3 concentric circuits** (`[B]` toggles + respawns), per-circuit best, live time delta, survives respawn.
- **Rear-view mirror** (2D SubViewport overlay — ViewportTexture is black on 3D/Metal). Real directional-light cast shadow.

**Flagship deformable terrain** (`scripts/terrain.gd`): GPU height-displacement + per-tile HeightMapShape3D collider, speed-independent Bekker dig + wheelspin excavation + berms. **Working, but currently only on the centre patch — not wired to the main stage.**

## Already solid — do NOT redo
- Core cornering physics is **mature**: combined-slip Pacejka + friction ellipse + load sensitivity already implemented (`vehicle_m2.gd:605-616`). Do not propose "add a friction ellipse" — refine, don't rebuild.
- Engine-audio approach is settled (steady loop + pitch). The future upgrade is a multi-sample rpm crossfade, gated on the user supplying labeled steady-rpm clips. See `[[rally-sim-engine-audio]]`.

---

## After-arc fix list (Arc D follow-ups)

Things found while driving that are REAL but deliberately not fixed mid-arc, so a phase does not
sprawl. Each names why it was deferred, because "later" without a reason becomes never.

- **The engine takes far too much damage from jumps** (user, 2026-08-31, D4 drive). Landing a jump
  should punish the suspension and maybe the tyres; it should not cook the engine. The damage model
  is currently ONE scalar driven by a horizontal-deceleration spike (`impact_threshold`, M8), so it
  cannot tell a landing from a head-on hit, and the component HUD then shows the engine taking it.
  **Needs a per-component damage model** — chassis / suspension / engine as separate pools with
  their own triggers — not a bigger threshold. Deferred because it is a vehicle-model rework and
  Arc D is a terrain arc.
- **Carve the terrain for the tunnel portal** (driver, 2026-09-02: *"2 is the solution i want
  eventually ... the optimal solution but the hardest one to work around - maybe put it in the
  future plan"*). Today the tunnel avoids terrain entirely: the mouth stands off the map so nothing
  can bury it. The end state is a portal that genuinely BORES into a hillside, which needs the stage
  area's height field to cut a trench and a portal face - i.e. `sample_at` gaining a tunnel-corridor
  term the way it already has a road corridor. Deferred because it changes the stage's ground near
  the mouth and wants its own drive verdict, not because it is unclear.
- **Berm scalloping at the road edge** (D4 drive). The colour sawtooth was fixed per-pixel, but the
  berm ridge is genuinely under-resolved: `berm_width` 1.6 m on a 1.41 m lattice is about one vertex
  across. A denser corridor chunk is 4x the vertices and vertices are 96% of chunk cost, so the
  principled fix is a **road-aligned ribbon mesh** for the carriageway and shoulders, resolving the
  cross-section ACROSS the road (12-16 vertices) instead of by a square lattice that happens to pass
  through it. Belongs with D6/D7, which already touch the corridor.
- **Stages are not relocatable.** Elevation is sampled at ABSOLUTE world coordinates, so moving an
  area changes its road. This is what forced D5's portal design (the stage start is 4149 m from the
  calibration map and could not simply be moved closer). Fixable by sampling in area-LOCAL
  coordinates, anchored so the current stage is preserved exactly — but it is generator work and it
  would have invalidated a drive verdict mid-test.
- **Corner rhythm and hairpin tightness** (D3 drive). "Corners do have rhythm but we might improve
  it in the future"; "the hairpin is tight - can be tighter in future seeds, meaning this should not
  be the limit". The lever named in D3 is a design speed that VARIES along the stage.

---

## Milestones (prioritized)

### Tier 1 — Rally depth (highest payoff; reuses tech already built)

**M6 — Surface degradation on the stage.** Repeated runs wear the line at corners so grip evolves and a racing line emerges.
- **Phase 1 — DONE (2026-07-28..29), `scripts/wear.gd`:** VISUAL + GRIP only (no 3D deformation — that's Phase 2). **Mark ownership by surface (design call 2026-07-29):** rally loop = wear line (this system) + dust particles, NO skid marks; ASPHALT ring = skid marks (`world.gd _drop_track`) only, NO wear line; centre deformable dirt = real ruts, NO skid marks. Skid marks are gated in `world.gd _physics_process` by `_stage.grip_at() > 1.2` (asphalt-only; base grip, not wear-modified). Wear field on the rally loop over **corners + braking zones** (`curv_min` 0.018, `brake_dist`; ~23%, ~5.9k cells). Wheel work (slip + slip angle) accumulates along the wheel's contact SEGMENT (bridges bumps/air-gaps up to 5 m → continuous line, no interval dashing). Node **wraps `grip_at()`** (vehicle `surface_source`) so the swept line gains grip (`wear_grip` +0.25). MultiMesh overlay: **road-aligned, cell-sized quads** (unit plane scaled/oriented per cell), `lat_bins=24`/`arc_samples=1080` (~0.4 m lateral), dark worn-dirt tint. `sound.gd` takes `stage` so the tyre-audio split uses BASE grip. Wear persists across respawn.
- **v1/v2 TODO (from user):** replace the grid-cell quads with a **track-aligned textured trail** (a decal following the actual driven path), not grid-aligned cells.
- **Phase 2 — next:** validate/tune the feel (grip direction + magnitude), then drive real geometry ruts from the same wear field (reuse `terrain.gd`), and consider whole-loop coverage once feel + perf are proven.
- Tunables on the Wear node: `curv_min` (coverage), `brake_dist`, `wear_rate`, `wear_full`, `wear_grip` (sign/magnitude), `lat_extent`.

**M7 — Tyre & consumables. — DONE (2026-07-29), `vehicle_m2.gd`.** Per-wheel **temperature + wear + puncture**, folded into the Magic-Formula `mu` (both `mux` sites × `w.tyre_grip`). Temp: friction-power heating + airflow cooling; grip peaks at `optimal_temp` (85°C→1.0), falls to `cold_grip` (**0.95** — gentle; 0.80 stranded the car on grass since it multiplies with grass_grip 0.8) cold and `overheat_grip` (0.80) hot. Wear: accumulates from tyre work (faster when hot), grip → `worn_grip` (0.70) at 100%. Puncture: wear-blowout always; hard-hit puncture gated by `impact_punctures` (**false by default** — the Fz proxy is unreliable because the anti-roll bars inflate `Fz` past the 20000 suspension clamp, up to ~40000, so respawn landings were puncturing). Grip → `puncture_grip` (0.35). A cleaner hard-hit trigger (e.g. suspension bottom-out) is TODO before re-enabling. `tyre_wear_rate` 0.006→0.002 (slower, ~15 min hard stint to blow). Punctured tyre gets a **deflated visual** (`puncture_flat` — squash vertically + sit lower on the rim) and a **speed-scaled vertical jitter** at that corner (`puncture_shake`, feels like little bumps). **`[P]` debug key** punctures the next intact tyre (R resets) to test the visual/vibration. Punctured tyre also plays a low procedural flap/rumble (`sound.gd _make_puncture`, louder+faster with speed). **Component HUD** (`scripts/component_hud.gd`, top-right, player-facing, separate from the debug text): top-down car schematic — 4 wheel rects + an engine square, each coloured by temperature (blue→green→yellow→orange→red; RED = flat tyre), tyres darken from the bottom with wear. Engine now has a temperature gauge (`_engine_temp`, heats with rpm×throttle / cools with airflow, exposed via `get_engine().temp`; **visual-only, no power penalty yet**). Diff / other components: overlay is structured to add them once modeled. Reset (R) = fresh tyres. HUD shows per-wheel temp/wear/PUNCTURE; tuning panel (Tab) exposes optimal_temp/heat/cool/wear rates/worn_grip/cold_grip/puncture_load; `tyres_enabled` master toggle. NOT drive-tested — thermal balance (heat vs cool rates) needs tuning by driving; note the cold-start grip penalty (0.80 until warmed). Compound choice deferred. No rock objects, so hard-hit puncture uses an Fz spike as the proxy.

**M8 — Damage model. DONE v1 (2026-07-30), `vehicle_m2.gd`.** Impact detection = a crash-level HORIZONTAL deceleration spike (`impact_threshold` 45 m/s²; braking/cornering/landings stay below — landings are vertical, excluded). `_damage` 0..1 accumulates by severity (`damage_gain`). Consequences: **power loss** (`damage_power_loss` ×engine torque), **grip loss** (`damage_grip_loss` ×mu at all 3 mux/muy sites), **steering pull** (`damage_steer_pull` × `_pull_dir`, direction = the side the last big hit came from). Repaired on respawn (R). Component HUD shows a **DAMAGE %** bar (green→red). Tuning-panel sliders added. **Cosmetic mesh deform = future** (big job). Test by ramming a roadside post.

### Tier 2 — Game loop / immersion

**M9 — Pace notes everywhere. DONE v1 (2026-07-30), `pace_notes.gd`.** Refactored single-route → a list of routes; builds notes for the **rally loop AND the asphalt ring**, and each frame picks whichever circuit you're on (nearest centreline within `on_route_dist`), calling ITS corners. Asphalt uses `curv_min_asph` 0.003 (big radius) + `asph_sev_scale` 0.30 (its big-radius corners are FAST → scale radius down for severity). NB the asphalt ring is near-convex, so its corners are all one direction (correct) — a series of right-handers of varying severity. Centre skid-pad has no notes (constant curvature). **Not yet done:** sector/"finish" calls, real voice samples (still OS TTS).

**M10 — Stage structure & splits. DONE v1 (2026-07-30).** (1) **Sector splits** (`time_trial.gd`): each lap split into 3 sectors by angle (θ thirds); mid-lap boundaries at θ=TAU/3, 2·TAU/3 record sectors 0,1, finish records sector 2. Per-circuit best sectors (`_best_sector`); each boundary flashes `S# time ±delta` coloured **purple = personal-best sector**, red = slower. The live position-based delta-vs-ghost already existed. (2) **Time-of-day** (`world.gd`): `[L]` cycles NOON/MORNING/EVENING/NIGHT presets (sun angle/colour/energy + sky top/horizon + ambient), applied to the stored `_sun`/`_env`/`_sky_mat`. **Not done: multi-stage sequence** (a stage-manager loading different stage configs in order — a bigger structural job, deferred).

**M11 — Dust & smoke visuals.** Surface-aware particles (brown dust on dirt, grey tyre smoke on tarmac wheelspin) driven by the slip you already compute, plus longer-lasting skid marks. Makes the tuned physics **visible**. Effort **S–M.**

**M12 — Rivals / medals / multiple ghosts.** Target times, medals, best + last ghost together. Effort **S–M.**

### Tier 3 — Physics refinements & tech

**Driven-wheel traction & torque delivery fix. DONE (2026-08-01) — but SUPERSEDED (2026-08-13).**
**Do not resurrect `_t_drive` from the entry below.** Its first-order torque-delivery lag was
retired in Phase A1 and replaced by real two-inertia dynamics: an engine with its own rotating
state, a clutch that slips and locks, and a small physical intake lag (`intake_tau`). The `Bx`
derivation from peak slip DOES survive and is still live — B4 later mirrored it for the lateral
axis (`peak_alpha_tarmac` / `peak_alpha_gravel` deriving `By`). Historical entry follows.
**Driven-wheel traction & torque delivery fix (historical), `vehicle_m2.gd`.** Root cause of runaway FWD wheelspin was threefold (NOT a post-peak curve collapse — the old curve held 91% of peak force at 375% slip): (1) fixed `Bx=10` put the longitudinal grip peak at **40% slip on every surface**, so full drive force *required* huge wheelspin; (2) a 0→1 throttle step delivered full gear-multiplied crank torque **in one physics tick** (~2000 N·m/front wheel vs a ~1160 N·m grip cap), and because engine rpm follows the driven wheels, spin climbed the torque curve 338→500 N·m (positive feedback until the limiter); (3) the explicit-Euler spin ODE was unstable for lightly-loaded wheels at low speed (chatter). Fixes, all physical: **Bx is now derived** from `peak_slip_tarmac` (0.14) / `peak_slip_gravel` (0.28) via the MF peak condition, blended per wheel by surface grip (worn dirt line drifts toward tarmac shape — packed line is emergent); **driveline torque delivery** is a first-order state `_t_drive` (`torque_rise_time` 0.25 s = clutch bite/intake/halfshaft windup, `torque_fall_time` 0.06 s so a lift restores grip immediately); **engine breathing** anchors WOT torque at `idle_torque_frac` (0.45) at idle instead of the old 68%; the spin ODE is **semi-implicit** (analytic `_mf_slope` linearises the tyre; LSD + brake stiffness included) — stable at any B/gear/speed; reflected engine inertia now **weighted by torque share** (AWD had 2× the physical value). Optional **traction control** (`tc_enabled`, default OFF, Tab-panel checkbox) trims torque toward `tc_slip_target` — an aid on top, not a crutch. New Tab sliders: peak slips, rise/fall times, idle torque, TC target. NOTE: at 500 N·m a FWD still out-torques front grip in 2nd–3rd on dirt at WOT (real for WRC power); for a true 205-GTI power-down feel drop Peak torque to ~250–300 on the existing slider — a car-spec choice, not a model nerf. Feel NOT yet drive-tested.

**Finding 2026-08-13 — the car's real speed ceiling is the valve-float clamp, not power vs drag.** Slider test at max power/grip/rpm reached **490 km/h**, which is exactly `w_red * 1.35` (the clutch-locked engine clamp at `vehicle_m2.gd:1315`) geared through 6th: redline 9500 rpm alone gives 363 km/h, ×1.35 gives 490.1. Two things follow. (1) `top_speed_kmh()` marches down from redline-in-top-gear, so it does NOT know about the 1.35 ceiling — the speedo it graduates can under-read the car's real maximum by ~127 km/h at extreme settings. (2) `_engine_torque()` clamps its curve input at `redline_rpm` (`vehicle_m2.gd:802`), so above redline torque holds FLAT instead of collapsing; the only thing stopping the engine is the separate `rev_cut` limiter. A real engine's torque falls off a cliff past redline — a functions-over-constants gap. There is also a SECOND ceiling at almost exactly the same speed: the wheel-spin clamp `±400 rad/s` (`vehicle_m2.gd`, spin ODE) is 400 × 0.34 m = **489.6 km/h** of rolling speed, so the car cannot exceed that however it is geared. The two ceilings sit within 0.5 km/h of each other by coincidence of the defaults.

**Braking from that speed — ATTRIBUTED 2026-08-13, and it is NOT a defect.** (First attribution that session was wrong: it assumed "all settings to max" meant the weight slider at 2500 kg. The user's actual config was every slider moved in the *goes-faster* direction — weight at its 700 kg **minimum**, drag at its 0.05 minimum, torque/redline/brake maxed, long final drive.) An A4-pattern probe (`probe_brake.gd`, since removed) reproduced that config from 489.6 km/h and swept the grip slider: `mu_long` 0.9 (default) → **856 m / 1.13 g** (the reported ~1 km), 1.6 → 589 m / 1.65 g, 2.6 (slider max) → 433 m / 2.22 g. **The stop is entirely tyre-limited once drag is turned down** — at `drag_k` 0.05 the aero term is ~0.7 kN at 490 km/h instead of ~13 kN at the 0.7 default, so nothing but the tyres slows the car, and a tyre-limited stop from 490 km/h is inherently 400–900 m. For comparison, at default drag the same stop takes 630 m even at 1250 kg. Nothing to fix; the lesson is that aero drag does most of the retardation at those speeds, and turning it down to raise top speed also removes the brakes' biggest helper.

**Real finding from the same probe — the car POGOS at high speed, and it is an underdamped suspension mode.** The user reported bouncing both at top speed and under braking, and both reproduce headless. Under braking, total suspension load collapses below 15% of static weight on **15% of frames at 1.13 g, 29% at 1.65 g and 32% at 2.22 g**. Coasting on the flat drag-strip slab with NO braking and no input, the same collapse appears purely as a function of speed: **0% at 198 and 299 km/h, 0% at 400 km/h but with Fz already swinging 3.0–11.9 kN, 4% at 468 km/h, and 34–45% at 489.6 km/h with Fz swinging 0.0–36.2 kN.** Mean slip ratio stays ≈ −0.006 throughout, so it is not the wheel clamp dragging the tyres.

Two controls identify it. **It is not aerodynamic:** with `drag_k` set to 0.0 the collapse is unchanged (48%) — drag is applied as a central force along the velocity vector, so it has no vertical component and exerts no pitch moment, and there is no downforce model at all (M13). **It is genuine underdamping:** raising `zeta` from 0.65 → 1.2 drops the collapse from 45% to **3%**, and 2.5 takes it to **0%**. A numerical or collision artefact would not respond that cleanly to physical damping.

**Do not fix it by raising `zeta`** — 0.65 is B1's deliberate race-damping choice and stiffening it globally would undo the compliance B1 exists to provide. This is precisely **B2's target**: an asymmetric damper resists compression less than extension so the car settles rather than bounces, which kills the pogo without stiffening the ride. Note the onset is above ~400 km/h, far outside normal driving (stock top speed ~237 km/h), so it is not affecting ordinary play — but the collapse statistic is B2's cleanest headless success metric. Re-measure it before and after.

**Separate real bug found on the way, now FIXED.** `mass = chassis_mass` is assigned once in `_ready()`, and the Tab panel's "Car weight" row drove the RigidBody's `mass` ONLY — so `chassis_mass`, the single authority for corner masses (`_derive_setup`), the roll gradient, the tyre load reference (`_mu_load`) and rolling resistance, stayed at 1250 whatever the slider said. At the user's 700 kg setting the body was light while its own suspension was still rated for 1250 kg and the tyre model still measured load against a 1250 kg reference (inflating `_mu_load` toward its 1.15 ceiling). The row now drives `chassis_mass` and `_derive_setup` keeps the body's `mass` following it, so a live weight edit re-rates the whole car. Probe also showed the wheels lock (kappa −1.00) for the entire stop at maxed brake torque, and tyre temperature reaching 128–173 °C against an 85 °C optimum with no upper bound — the thermal model has no ceiling either, the same class of gap as the flat above-redline torque curve.

**M13 — Aero downforce + self-aligning torque.** Downforce for high-speed grip on the asphalt ring. **The SAT half is DONE — delivered by Arc C2, 2026-08-15** (awaiting drive verdict): `Mz = Fy·(pneumatic + mechanical trail)` at the front wheels, with a cosine (Pacejka) trail collapse so the wheel goes light just BEFORE the front washes out, read on the HUD as `steer Nm` via `get_steer_torque()`. **Only downforce remains here.** Effort **S.**

**M14 — Force feedback.** **Superseded by the active plan's Arc C** (2026-08-05, extended 2026-08-11): **C1 surface roughness — DONE, drive-verified 2026-08-24** (see `docs/PLAN-drivetrain-suspension.md` §9). A procedural ISO-8608 roughness field + washboard corrugation + tarmac joints/patches, sampled per wheel through a tyre-enveloping filter and injected into the suspension raycast's ground distance — the wheels can't transmit texture the world doesn't have (the collision grid is 2.25 m/cell outside the centre patch), so this gives them something to respond to without touching mesh/collider resolution. C1.0 also delivered the arc-length `Centreline` abstraction (`scripts/centreline.gd`) that Arc D's ground-map plan needs, moved forward specifically so C1's washboard `s` doesn't shift under it later. `roughness_gain` (Tab panel) is the A/B — 0 restores the pre-C1 car exactly. Next: C2 self-aligning torque (no hardware needed), C3 wheel input path, C4 FFB output. **Important finding recorded there:** Godot 4 has no force-feedback API at all — `Input.start_joy_vibration()` is rumble, not FFB — so C3 opens as a timeboxed research spike (GDExtension over SDL_Haptic, or an external bridge) that may honestly conclude "not feasible on Apple Silicon without engine work". C1/C2 deliver value regardless. Don't buy a wheel assuming C3 lands.

**M15 — Physics tick 120 + calculated suspension from weight distribution. DONE** (Phase 0 + B1). Community norm for stable raycast vehicles is ≥120 Hz (currently default 60). Cheap stability win **but it changes vehicle feel → requires a re-tune**; keep functions-over-constants (derive spring/damper from mass + distribution). Effort **S + re-tune.**

**M16 — Replay camera / photo mode.** Reuses the ghost's transform-recording infrastructure. Effort **S–M.**

---

## Arc E (sketch) — the world you SEE, and vehicle identity

Sequenced by the user 2026-08-30: **finish Arc D and Arc C's open items, then a bug-cleaning run,
then plan this.** Not a plan yet - a captured intent, so it is not lost in chat. Six items, and they
are NOT one arc's worth of the same kind of work:

**E-a. Procedural ground texturing.** The chunk mesh already carries a per-vertex EDGE DISTANCE for
exactly this reason (`StageArea.sample_at()` returns it so the road edge can be thresholded per
PIXEL rather than per vertex). **Order matters: this comes AFTER D6.** D6 changes what the ground
IS - mixed gravel/tarmac - and texturing before it means texturing it twice.

**E-b. Trees and foliage along the road.** The placement rule is already available: a pure function
of the ground map (`surface == GRASS`) plus the centreline (`lateral > x`), which is D1 and D2
paying off a third time. Two hard constraints inherited from Arc D: it must be a **pure function of
position and seed** (§0's repeatability rule - foliage that moves between visits breaks a learnable
stage), and it must **stream with the chunks** rather than existing as one scene.

**E-c. Clouds and a real skybox.** Standalone, cheap, no dependencies. The time-of-day system
(`[L]`, four presets in `world.gd`) is the hook.

**E-d. A real car MODEL replacing the primitive-built body.** Correctly identified by the user as a
different tool's job (Blender or a bought asset), not this repo's. **The rule when it lands: the
physics must not move.** Wheel mounts, CoM height, wheelbase and track are drive-verified
calibration; swapping the visual body is a "nothing moves" refactor of exactly the kind D1 and D2
already have a proven pattern and probe shape for.

**E-e. CAR PROFILES — and this one is NOT art, it is physics, and it is unblocked today.** A `CarDef`
in the same spirit as `StageDef`: mass, wheelbase, CoM, power curve, gear ratios, drive mode, tyre
parameters. It needs no 3D model to be worth having - the existing primitive body can wear any
profile. `docs/ROADMAP.md` M7 already brushes against it (peak_torque ~250-300 is the honest
"205 GTI" spec against the 500 N*m WRC default), and every export the car has is already a
drive-verified value, which is exactly what a profile is a named set of.

**The split that matters:** E-e is ordinary work for this repo and can start whenever. E-d depends
on external tooling. Bundling them would let the modelling block the physics.

**What changes about how work is verified in this arc:** everything so far has been verified by
headless probe (compiles, numbers) plus the user's drive (feel). Visual work is verified by EYE, and
Arc D proved the instrument the hard way - D3's "jagged edges" survived several rounds of correct
height-field measurement because the defect was in the MESH, and a screenshot found it in one look.
**Expect screenshots to be the primary probe for Arc E**, and expect the first real GPU budget in a
project whose budgets have so far all been physics ms/tick.

---

## Prepared decision questions (for the next session)

1. **Direction:** rally depth first (Tier 1) or game-loop/immersion (Tier 2)? _Recommendation: M6 surface degradation — signature feature, revives the flagship terrain._
2. **M6 scope:** carve ruts around the **whole loop**, or only **corners + braking zones** (cheaper, higher impact-per-metre)?
3. **M7 scope:** full temperature + wear + punctures, or just **wear → grip** to start?
4. **Hardware:** do you have a **racing wheel**? (Gates M14 FFB priority and shapes M13 SAT work.)
5. **Audio:** will you provide **labeled steady-rpm clips** (idle / mid / high) so we can do the multi-sample engine crossfade?

## Ready-to-paste kickoff prompts

- **M6:** "Start M6 surface degradation. Wire the deformable terrain (`terrain.gd`) to the rally loop so repeated runs carve ruts that feed into `grip_at()`. Read `docs/ROADMAP.md`. First propose whole-loop vs corners-only and a perf plan (tile streaming along the corridor), then implement and verify headless."
- **M7:** "Start M7 tyre model. Add tyre temperature + wear that evolve the friction-ellipse `mu` over a stage, plus punctures on hard hits. Expose the new params in the tuning panel (Tab)."
- **M11:** "Start M11 dust & smoke. Upgrade the particle/skid-mark system to be surface-aware (dust on dirt, smoke on tarmac wheelspin), intensity driven by per-wheel slip, with longer-lasting marks."

## Working patterns (how to get good results in this repo)

- **Verify headless:** `"/Users/sgyzrbl/Downloads/Godot.app/Contents/MacOS/Godot" --headless --path ~/rally-sim --quit-after N 2>&1 | grep -iE "error|SCRIPT ERROR|Parse Error"`. Windowed run is only needed for TTS / audio / `frame_post_draw`. For geometry, add a temporary probe print, validate, then remove it.
- **Functions over constants** (`[[prefer-functions-over-constants]]`): e.g. redline-derived engine-pitch ceiling, load-sensitive grip, per-mode CoM shift. Always prefer a physical function to a tuned magic number.
- **Audio samples** (`[[rally-sim-engine-audio]]`): convert with `afconvert -f WAVE -d LEI16@22050 -c 1 in.mp3 out.wav`; check steadiness with an RMS + zero-cross-rate bucket dump; want **steady loops**, not sweeps/blips; the raw-WAV parser in `sound.gd` bypasses Godot's importer (which truncates).
- **GDScript gotchas:** `:=` cannot infer from a Variant (untyped `stage.*` calls) → use `var x: Type = …`; unshaded `StandardMaterial3D` ignores emission (toggle `albedo_color`); macOS has no `timeout` (use `--quit-after N`).
- **Geometry trick:** the three circuits are concentric, so they share the θ=0 finish ray and are disambiguated by disjoint radius bands (see `time_trial.gd` RMIN/RMAX).
- **User workflow:** the user drives each change and gives feel feedback; prefers iterative milestones, live tuning sliders (Tab), and fun over strict realism where they conflict. Take control of their PC as little as possible — prefer headless verification.
