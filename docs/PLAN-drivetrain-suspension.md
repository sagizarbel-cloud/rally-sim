# PLAN — Drivetrain & Differentials, then Suspension & Weight Transfer

_Written 2026-08-02 by the planning agent (Fable). Executor: Opus, phase by phase, fresh
context per session. This document is self-contained: read it top to bottom, then execute
ONE phase per session, in order. Do not skip the feel checkpoints — the user is the only
feel-verification instrument this project has._

---

## 0. How to work in this repo (read first)

- Project: `/Users/sgyzrbl/rally-sim` — Godot 4.4 + Jolt, native M1, everything built
  procedurally in code (no `.tscn` editing for gameplay). Read `CLAUDE.md` and
  `docs/ROADMAP.md` before starting any phase.
- **Compile gate after every edit:** run `./check.sh` from the project root. It must print
  `✅ Godot check clean`. This only proves the code loads — it says NOTHING about feel.
- **Feel gate:** every phase below ends with a user driving checklist. Ask the user to
  drive it and report back BEFORE marking the phase done or starting the next. Never claim
  a feel change works.
- **Functions over constants:** every behaviour must come from a physical model with
  physically-meaningful tunables (Hz, damping ratio, N·m, ramp ratios), not magic numbers.
- New tunables: `@export` vars on the vehicle + a row in `tuning_panel.gd` `_specs`
  (label, property, min, max, step, formatter — see existing rows at
  [tuning_panel.gd:13](../scripts/tuning_panel.gd)).
- **GDScript gotchas:** tabs not spaces; `:=` cannot infer from a Variant (untyped
  `stage.*`/dict access → `var x: Type = ...`); unshaded `StandardMaterial3D` ignores
  emission; macOS has no `timeout` (use `--quit-after N`, N = frames).
- **Input (updated 2026-08-11):** the **PS4 DualShock 4 is detected and in use** — analog
  throttle/brake are live and bypass the virtual-pedal shaping. The wired Xbox One pad is
  still invisible to Godot 4/macOS. Earlier phases were written assuming keyboard only;
  keyboard must keep working, but analog paths are now testable rather than theoretical.
- Keyboard input map is built in `world.gd` `_build_input()` (`_add_keys`, ~line 218).
  New keys go there.
- After finishing a phase, update the phase's checkbox in §9 of this file and add a
  one-line status note (date + what the user's drive test concluded).
- **Probe harness pattern** (A4, reusable): a probe that must simulate DRIVER INPUT is a
  `Node` with a `_physics_process` state machine using `Input.action_press/release`, added
  by a temporary block in `world.gd` `_ready()` (gated on an env var) and then
  `move_child(probe, 0)` — it MUST sit before the car in the tree, because
  `is_action_just_pressed` only reports true on the same physics frame as the press, and
  the car reads its input in tree order. Run it with a large `--quit-after`; the probe
  calls `get_tree().quit()` when done. Delete the script AND the `world.gd` block after.

---

## 1. Vision & goal (interview outcome, 2026-08-02)

The user wants the DRIVING FEEL deepened, in this order:

1. **Arc A — Drivetrain & differentials**: corner-exit diff behaviour, clutch & launch,
   engine braking & lift-off character. Handbrake refinement only as a small late phase
   (current handbrake "feels decent").
2. **Arc B — Suspension & weight transfer**: body roll / left-right transition rhythm
   ("Scandinavian-flick-ability") and bump absorption / road texture. Jumps and landings
   are acceptable as-is.
3. **Arc C — Surface texture, steering feel & force feedback** (added 2026-08-05, extended
   2026-08-11 at the user's request): first make the wheels actually FEEL the surface they
   are on, then self-aligning torque as a real computed signal, then a proper wheel input
   path and FFB output. The user's reasoning for that order is sound and worth recording:
   force feedback can only transmit what the physics already contains, and today the road
   is geometrically smooth, so an FFB wheel would faithfully reproduce nothing. Ordering
   within the arc is driven by hardware arrival rather than dependency — see §5 Arc C.

Preceded by **Phase 0: the 120 Hz physics tick** (roadmap M15) so everything new is built
and tuned once, on the stable foundation.

- **Reference feel:** Assetto Corsa Rally and DiRT Rally 1. (RBR is the long-term
  benchmark but the user hasn't been able to run it properly on the Mac.)
- **Philosophy:** realism at the core, with toggleable "training wheels" on top:
  anti-stall (default ON), auto-blip/rev-match (toggle), stability assist (default OFF),
  launch assist (default OFF). The existing TC toggle stays.
- **Input:** written when keyboard was the only option, and input shaping is still
  FIRST-CLASS feel work (a binary throttle gates everything you can feel). Since
  2026-08-09 the DS4 is detected, so the analog paths are live for real — keyboard
  shaping still has to hold up, because both are in use.
- **Constraints:** every phase must leave the car fully drivable on keyboard. Nothing is
  sacred — existing tuning may be re-tuned in service of the end result.

### Feel acceptance criteria (the end state, in the user's terms)

- **Launch:** from standstill, launches differ by surface — asphalt hooks up after brief
  clutch slip; dirt needs throttle discipline; grass is loose but no longer "ice-like".
  Bogging the engine is possible (too tall a gear, too little throttle) and audible.
- **Corner exit:** the diff is FELT — an open front diff spins the inside wheel and washes
  wide; a clutch LSD pulls the car straight and tight on power; a locked rear on dirt
  steers with the throttle. Changing diff setup on the Tab panel changes the car's
  character within one lap.
- **Corner entry:** lifting off rotates the nose in, more with aggressive coast settings;
  downshifts without auto-blip produce a felt (and survivable) jolt of engine braking.
- **Transitions:** a left-right flick chain on dirt has readable rhythm — the body takes a
  set, returns predictably, and a Scandinavian flick can be timed and repeated.
- **Road texture:** washboard, ruts and berms read through the car without launching it —
  the suspension is felt "working"; the car stays planted at speed on the rough rally loop.
- **Sound follows physics for free:** free-revving in neutral, bogging, blips and engine
  braking are all audible because engine rpm is finally a real state (`sound.gd` already
  pitches the drone from `get_engine().rpm` — zero audio work needed).

---

## 2. Current-state assessment (code read 2026-08-02)

All in `scripts/vehicle_m2.gd` (840 lines) unless noted. What exists is GOOD — a mature
combined-slip Pacejka tyre (slip ratio + slip angle + friction ellipse + load sensitivity,
lines ~605–790), a per-wheel spin-ODE drivetrain with semi-implicit integration
(lines ~666–756), surface-derived longitudinal stiffness `Bx` (the 2026-08-01 fix), tyre
thermal/wear/puncture (M7), damage (M8). **Do not rebuild any of that. Refine.**

### Drivetrain gaps (Arc A targets)

| # | What the code does today | Why it blocks the vision |
|---|---|---|
| D1 | **No engine state.** `_engine_rpm` is kinematically clamped to the driven-wheel average each substep (line ~690: `clampf(|wavg|·gr·final·60/TAU, idle, redline)`). | No flywheel → no free revving, no bog, no stall, no rev-match, no launch technique. The idle clamp is an invisible, infinitely slipping clutch. |
| D2 | **No clutch.** Launch behaviour comes from the idle clamp + `idle_torque_frac` + the `_t_drive` first-order torque lag. | Clutch bite/slip is the heart of launch feel and of the suspected grass-standstill problem ([[rally-sim-grass-standstill]]). |
| D3 | **No neutral.** `_gear` 0 = reverse, 1..6 = forward. | Free revving and real launches need N; remapping gears touches HUD + shift logic. |
| D4 | **Instant shifts.** Ratio swaps in one tick, no torque interruption, no blip. | Shifts have no rhythm, downshifts have no consequence. |
| D5 | **Engine braking is a constant** −50 N·m when `throttle < 0.05` (line ~703). | Real overrun torque grows with rpm (friction + pumping losses). Constant drag = no lift-off character to tune, no entry rotation from a downshift. |
| D6 | **Axle diffs are one hardcoded formula**: `t_axle·0.5 + lsd_lock·(mate.ω − w.ω)` (line ~726) — open + viscous coupling, same `lsd_lock` front and rear. | No preload, no torque-sensitive (Salisbury power/coast) locking, no per-axle setup, no selectable types. Corner-exit character is exactly this. |
| D7 | **Centre "diff" is a pure torque split** `eff_split` — front and rear axle speeds are completely uncoupled. | A real centre diff/coupling transfers torque when axles overspeed each other; also the rally handbrake trick (open the centre, lock the rears) is impossible. |
| D8 | **Handbrake fakes it**: adds rear brake torque (fine) but then multiplies rear lateral force by `rear_grip_cut = 0.2` (line ~780) — a magic-number hack. | Locked wheels already lose lateral grip naturally through the combined-slip ellipse; the hack double-counts and hides the real behaviour. |
| D9 | **Throttle and brake are raw 0/1 keys.** Only `_t_drive` smooths torque; brake is an unshaped 2600 N·m step. | No trail braking, no throttle modulation — the driver's foot needs a physical model too (virtual pedals). Steering, notably, IS already shaped (ramps + speed falloff, lines ~570–591). |
| D10 | Dead export: `brake_force` (M1 leftover, unused in M2; panel slider does nothing). `handbrake_torque` panel row maps to nothing on M2. | Cleanup when touching brakes. |

### Suspension gaps (Arc B targets)

| # | What the code does today | Why it blocks the vision |
|---|---|---|
| S1 | Hand-set constants: `spring_k = 40000`, `damper_c = 8000`, per-wheel corner mass ≈ 312 kg. | That is ride frequency ≈ **1.8 Hz** (tarmac-racecar stiff — gravel cars run much softer) and damping ratio **ζ ≈ 1.13 — overdamped** (race baseline is 0.65–0.70). Physically explains BOTH complaints: overdamped = dead, slow transitions AND harsh washboard skipping. |
| S2 | One damper coefficient for bump and rebound, linear. | Real (rally) dampers are asymmetric (rebound ≫ bump) and digressive — stiff low-speed for body control, soft high-speed with blow-off for square-edge hits. This one change carries most of "transitions" AND "road texture". |
| S3 | No bump stops: compression is silently clamped at `max_travel`, `Fz` hard-clamped at 20 000 N (line ~633) — which the ARBs then overflow past (up to ~40 000, the reason M7's impact-puncture proxy was unreliable). | Bottoming is a cliff, not a progressive event; the Fz clamp distorts loads; a real bump-stop gives M7 its clean puncture trigger (`w.bottomed`). |
| S4 | ARBs are N per metre of compression difference (14 000 / 10 000), hand-set. | Should be derived from a target roll gradient (deg/g) + front roll-couple %; estimate: the current setup is ≈ 1.8 deg/g — very flat, racecar-stiff. |
| S5 | Lateral tyre force is instantaneous with slip angle (line ~778). | No relaxation length → no tyre "take a set" lag; transitions feel darty rather than rhythmic. (Longitudinal already has natural lag via the ω ODE.) `By = 10` is also fixed while `Bx` is surface-derived — the lateral peak slip angle should differ tarmac vs gravel too. |
| S6 | CoM pinned very low (−0.45, comment: "corner hard without tipping"). | Suppresses honest roll/weight transfer; once ARBs/dampers are real, the CoM height can come up toward physical and roll can be controlled the real way. |
| S7 | Physics tick 60 Hz, drivetrain sub-stepped ×6 (= 360 Hz). | Community norm for raycast vehicles is ≥120 Hz; suspension/tyre forces update at only 60 Hz today. Doubling the base rate benefits everything Arc B touches. |

---

## 3. Research: chosen techniques, rationale, sources

### 3.1 Engine + clutch as a two-inertia driveline (Phases A1, A2, A4)

**Chosen approach:** give the engine its own integrated angular-velocity state
(`I_e·ω̇_e = T_combustion − T_friction(ω) − T_clutch`) coupled to the gearbox by a clutch
that transmits up to a capacity torque `T_cap = engagement · clutch_max_torque`, with
stick-slip: while slipping, torque is Coulomb-like (sign of Δω, smoothed); when |Δω| is
small and the through-torque fits inside capacity, the clutch LOCKS and the engine follows
the wheels kinematically — which is exactly today's code path, kept as the "locked" branch.
This is the standard real-time automotive approach:

- Two-inertia clutch models with Karnopp-style stick-slip (a dead zone around Δω = 0 to
  avoid chatter) are the established real-time technique — [Bataus et al., *Automotive
  clutch models for real-time simulation*](https://academiaromana.ro/sectii2002/proceedings/doc2011-2/05-Bataus.pdf).
- Vehicle Physics Pro (the best-documented commercial driveline for games) models exactly
  this: engine as rotating inertia with passive/active idle, stall + bump-start, clutch as
  lock-ratio or friction clutch-pack — [Edy: Engine, clutch and gearbox in VPP](https://www.edy.es/dev/2015/02/engine-clutch-and-gearbox-in-vehicle-physics-pro/),
  [VPP driveline docs](https://vehiclephysics.com/blocks/driveline/).
- **Engine braking becomes emergent**: motoring torque = mechanical friction + pumping
  losses, which GROW with rpm — model as `T_fric(ω) = c0 + c1·ω` (optionally +c2·ω²),
  with `c0`,`c1` DERIVED from two physical anchors (idle friction and engine-brake torque
  at redline) — [MIT 2.61 friction/pumping-loss notes](https://web.mit.edu/2.61/www/Lecture%20notes/Lec.%2019%20Friction%20and%20tribology.pdf),
  [Autosport: engine braking calculation](https://forums.autosport.com/topic/180576-engine-braking-calculation/).
  Closed throttle → negative net torque → overrun drag through the driveline. Off-throttle
  character then falls out of gear choice + rpm, and the flat `engine_brake = 50` constant
  dies.
- The existing `_t_drive` rise/fall lag is RETIRED in A1 — replaced by the real dynamics
  (engine inertia + clutch slip + a small first-order intake/manifold lag `intake_tau`,
  which keeps the physical grain of the 2026-08-01 fix without the fudged 0.25 s ramp).

**Alternative considered:** keeping the kinematic rpm and layering fake "clutch feel" on
the torque lag. Rejected: it cannot produce free-rev, bog, stall, rev-match or launch
technique, all of which the user explicitly asked for — and it's a constants-not-functions
dead end.

### 3.2 Differentials: Salisbury clutch-pack + selectable types + real centre coupling (Phase A3)

**Chosen approach:** a small diff abstraction evaluated per axle with selectable types —
OPEN / VISCOUS (today's model, kept) / **CLUTCH-PACK (Salisbury)** / LOCKED — plus a
centre coupling for AWD. Salisbury lock capacity: `T_lock = preload + k_ramp·|T_input|`,
where `k_ramp` differs for power (throttle-on) vs coast (overrun) — the ramp-angle
mechanism. Transfer torque opposes the wheel-speed difference up to that capacity
(Coulomb, integrated with the same semi-implicit `k_stiff` pattern already in the code).

- Model + parameters (preload N·m, power/coast angles, friction) documented in
  [VPP differential docs](https://vehiclephysics.com/blocks/differential/); mechanism
  background: [Autosport: LSDs and ramp angles](https://forums.autosport.com/topic/52016-limited-slip-differentials-and-ramp-angles/).
- Assetto Corsa (the user's reference title) exposes exactly POWER / COAST / PRELOAD per
  diff in `drivetrain.ini` — matching its semantics makes setup intuition transferable —
  [AC diff physics discussion](https://www.overtake.gg/threads/differentials-open-and-limited-slip.207521/).
- Feel mapping (why this serves "corner-exit diff feel"): more preload/power-lock = car
  drives straighter and tighter out of corners (push on entry, traction on exit); open =
  inside wheelspin; more coast-lock = stable on lift; less = eager lift-off rotation —
  [LSD effects on vehicle dynamics](https://www.designjudges.com/articles/differential-effects).
- **Centre:** keep the `torque_split` (it's the asymmetric-epicyclic split, real) and ADD a
  speed-coupling element (viscous or clutch preload) between the axles; the handbrake
  OPENS it (real rally hydraulic handbrakes disengage the centre so the rears can lock).

**Alternative considered:** Torsen/torque-bias model. Deferred — Salisbury + viscous +
locked covers rally practice (gravel cars run clutch/locked diffs), Torsen adds a type
later if wanted (the abstraction makes it a small add).

### 3.3 Suspension: derived setup, asymmetric digressive dampers, bump stops (Phases B1–B3)

**Chosen approach (all functions-over-constants):**

- **Springs from ride frequency:** `k = m_corner·(2π·f)²`. Targets from OptimumG: 0.5–1.5 Hz
  passenger, 1.5–2.0 Hz sedan racecar; rally gravel wants the soft end (~1.2–1.6 Hz front,
  rear ~10–20 % higher for flat-ride) — [OptimumG Tech Tip 1: Springs & Dampers](https://optimumg.com/wp-content/uploads/2020/01/SpringsDampers_Tech_Tip_1.pdf).
- **Dampers from damping ratio:** `c = 2·ζ·√(k·m_corner)`, baseline ζ ≈ 0.65–0.70, and
  asymmetric bump/rebound — [OptimumG Tech Tip 3: damping ratio](http://downloads.optimumg.com/Technical_Papers/Springs&Dampers_Tech_Tip_3.pdf).
  Current code is ζ ≈ 1.13 → the plan expects a LARGE felt improvement from this alone.
- **Digressive + blow-off:** low-speed damping (body roll/pitch — where the damper spends
  most of its time) stiff; above a knee velocity the slope drops so square-edge hits pass
  through softly — the defining rally-damper trait (gravel dampers add a high-speed
  blow-off precisely for ruts/rocks) — [damper low/high-speed tuning guide](https://corneringperformance.com/adjustable-suspension-tuning/),
  [Reiger gravel rally dampers (blow-off)](https://shop.vexperformance.com/products/reiger-suspensions-rally-performance-dampers-bmw-3-series-e46-1999-2006-gravel).
- **ARBs from roll gradient:** compute roll moment per g from mass and CoM height, choose a
  target roll gradient (deg/g) + front roll-couple %, derive the two bar rates —
  [OptimumG Tech Tip 2 (units/ARB)](https://optimumg.com/wp-content/uploads/2020/01/SpringsDampers_Tech_Tip_2.pdf),
  [Suspension Secrets: spring & ARB rates](https://suspensionsecrets.co.uk/calculating-ideal-spring-and-roll-bar-rates/).
- **Bump stops:** progressive force in the last ~20 % of travel replacing the silent clamp;
  raycast-vehicle norm of asymmetric bump/rebound damping is standard practice —
  [DigitalRune vehicle-physics notes](https://digitalrune.github.io/DigitalRune-Documentation/html/143af493-329d-408f-975d-e63625646f2f.htm).

### 3.4 Lateral relaxation length (Phase B4)

First-order lag on slip angle: `α̇ = (v/σ)·(α_ss − α)` — the tyre needs to roll ~σ metres
(≈ 63 % convergence) before lateral force builds. σ ≈ 1.5–2× tyre radius (~0.5–0.7 m
here), with a low-speed floor on `v` to avoid parking oscillation —
[Relaxation length review & time-constant analysis](https://www.researchgate.net/publication/281321108_Relaxation_Length_Review_and_Time_Constant_Analysis_for_Agile_Tire_Dynamics_Control).
This is the missing half of "transition rhythm" (the suspension is the other half); the
longitudinal side already has natural lag via the wheel-spin ODE. Also mirror the
2026-08-01 `Bx` derivation for `By`: derive from peak slip ANGLE per surface (tarmac
peaks ~8–10°, gravel slides deeper, ~12–16°) so gravel holds on longer before letting go.

### 3.5 The 120 Hz tick (Phase 0)

Raycast-vehicle stability is timestep-bound; sub-60 Hz is known-unstable and ≥120 Hz is
the community norm for stiff suspension/tyre updates ([gamedev raycast-vehicle stability
threads](https://www.gamedev.net/forums/topic/702824-raycast-suspension-at-high-physics-time-step-problem/)).
Keeping `drive_substeps` product constant (120 Hz × 3 = 360 Hz, same as today's 60 × 6)
means the drivetrain ODE budget is unchanged while suspension/tyre/lateral forces update
twice as often.

### Reference implementations worth reading during execution

- **Vehicle Physics Pro docs** (vehiclephysics.com) — the driveline/differential/engine
  chapters are the closest public blueprint to what Arc A builds.
- **Assetto Corsa `drivetrain.ini`** semantics (POWER/COAST/PRELOAD) — match the user's
  reference title's setup language.
- **Marco Monster, *Car Physics for Games*** — the classic grounding text
  ([mirror](https://www.asawicki.info/Mirror/Car%20Physics%20for%20Games/Car%20Physics%20for%20Games.html)),
  with Brian Beckman's *Physics of Racing* series as the deeper companion.
- **Richard Burns Rally / Assetto Corsa Rally / DiRT Rally 1** — feel benchmarks only.

---

## 4. Phase map (execute strictly in order)

| Phase | Arc | Title | Size |
|---|---|---|---|
| 0 | — | 120 Hz tick + virtual pedals | S |
| A1 | A | Engine inertia + clutch + neutral + anti-stall | L |
| A2 | A | Emergent engine braking + overrun + auto-blip | M |
| A3 | A | Differentials: Salisbury + selectable types + centre coupling | L |
| A4 | A | Gearshift model + launch assist + stability assist | M |
| A5 | A | Handbrake refinement (remove the grip hack, open centre) | S |
| B1 | B | Derived suspension setup (freq/ζ/roll-gradient sliders) | M |
| B2 | B | Damper model: bump/rebound split + digressive knee | M |
| B3 | B | Bump stops + honest load path (`w.bottomed` for M7) | S |
| B4 | B | Lateral relaxation length + surface-derived `By` + CoM height | M |
| B5 | B | Bake defaults, prune dead tunables, end-to-end verification | S |
| C1 | C | **Centreline abstraction + surface roughness the wheels feel** | L |
| C2 | C | Self-aligning torque — the FFB signal (no hardware needed) | M |
| C3 | C | Wheel input path: lock, ratio, pedals, shifter | M |
| C4 | C | FFB output layer (**research spike first** — see §7) | L |

Every phase: `./check.sh` clean → user drives the checklist → user verdict recorded →
next phase. Every phase leaves the car fully keyboard-drivable.

**Arc C is the exception to "strictly in order."** Its sequence is set by when a wheel
physically arrives, not by dependency: C1 and C2 need no hardware, while C3 and C4 cannot
be tested at all without the wheel in hand. If a wheel arrives mid-Arc-B, pull C3 forward
the same day — an untested input path is the difference between a usable wheel and an
unusable one — and leave the rest in place. C2 wants B4 done first (it builds on the
relaxed slip angle).

**Ordering decision, 2026-08-11 (user's call, recorded because it has a cost).** C1 runs
AFTER Arc B, not before it. The alternative was to add road texture first so B2's dampers
were tuned once against realistic input — the same "build on the final foundation" logic
that put the 120 Hz tick in Phase 0. The user chose to finish Arc B first. **Consequence to
expect and not be surprised by:** B2's `hs_blowoff` and knee speed exist specifically to
swallow washboard, and they will have been tuned on a glass-smooth road, so C1 will very
likely require revisiting them. Budget that re-tune into C1 rather than treating it as a
regression.

---

## 5. Phase details

### Phase 0 — 120 Hz foundation + virtual pedals

**Files:** `project.godot`, `scripts/vehicle_m2.gd`, `scripts/tuning_panel.gd`.

1. `project.godot` `[physics]`: add `common/physics_ticks_per_second=120`.
2. `vehicle_m2.gd`: default `drive_substeps` 6 → 3 (keeps the driveline at 360 Hz — no
   drivetrain re-tune expected; the semi-implicit ODE is rate-robust).
3. **Virtual pedals** (input shaping — the driver's foot, distinct from machine dynamics):
   add states `_throttle_pedal`, `_brake_pedal` (0..1) that chase the key state with
   physical rates; analog input (live since the DS4 was detected) bypasses the shaping exactly
   like `_steer` already does for the stick.
   - New exports + Tab rows: `throttle_rise_time` (~0.18 s), `throttle_fall_time`
     (~0.08 s), `brake_rise_time` (~0.12 s), `brake_fall_time` (~0.08 s).
   - Replace direct `Input.get_action_strength("throttle"/"brake")` reads in
     `_physics_process` with the pedal states. Handbrake stays raw (it's a lever).
   - Note: `_t_drive` still exists in this phase (it goes away in A1); the stack of pedal
     shaping + torque lag is temporarily doubled smoothing — acceptable for one phase.
4. Watch perf: physics cost doubles. Add a TEMPORARY probe print of
   `Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)` avg, confirm headroom on
   the M1, then REMOVE the probe (repo convention).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Baseline intact: top speed on the drag strip still ≈ 259 km/h in 6th; rally-loop lap
  time within a couple of seconds of the ghost; no new vibration/jitter at speed or at rest.
- [ ] Brake taps now modulate — trail braking into a dirt corner is possible without
  instant lockup.
- [ ] Throttle feels progressive, not switch-like, especially in 1st–2nd on dirt.
- [ ] FPS unchanged (V-Sync 60).

### Phase A1 — Engine as a real inertia + clutch + neutral + stall/anti-stall

**Files:** `vehicle_m2.gd` (drivetrain block ~650–756, `_engine_torque`, `respawn`,
`get_engine`), `world.gd` (input map), `hud.gd` (gear display), `tuning_panel.gd`.

1. **Engine state:** add `_omega_e` (rad/s). Integrate inside the substep loop:
   `I_e·ω̇_e = T_comb − T_fric(ω_e) − T_clutch`, where:
   - `T_comb = throttle_pedal · _engine_torque(rpm)` through a first-order intake lag
     `intake_tau` (~0.07 s, export) — the physical remnant of the retired `_t_drive`.
   - `T_fric(ω) = c0 + c1·ω` with `c0`, `c1` DERIVED from two exports:
     `engine_brake_idle` (~18 N·m) and `engine_brake_redline` (~55 N·m) (see §3.1).
   - Active idle (VPP-style): below `idle_rpm`, inject up to `idle_torque_frac`-anchored
     torque to hold idle — keeps the existing no-stall default behaviour.
   - Rev limiter: keep the existing `rev_cut` shape, applied to `T_comb`.
2. **Clutch:** engagement `_clutch` (0..1). Capacity
   `T_cap = _clutch · clutch_margin · peak_torque` (`clutch_margin` export ~1.4).
   - Slipping: `T_clutch = T_cap · tanh(Δω / ω_smooth)` (Karnopp-style smoothing band);
     reaction torque drives the gearbox input (wheel side) through the existing gear maths.
   - Locked (|Δω| small AND through-torque < T_cap): switch to today's kinematic path —
     engine rpm follows driven-wheel average, reflected engine inertia exactly as now
     (torque-share weighting stays). Unlock when through-torque exceeds capacity.
   - **Auto-clutch (default):** engagement scheduled from rpm vs `bite_rpm` (~1800,
     export) and gear state; **anti-stall** (export `anti_stall := true`, Tab toggle)
     dips the clutch when rpm falls toward stall.
   - **Manual clutch toggle:** export `manual_clutch := false` + Tab toggle; new input
     action `clutch` on LEFT SHIFT (add in `world.gd`). Held = disengaged. If the engine
     stalls (manual mode, anti-stall off): rpm → 0, torque 0; restart by holding the
     clutch ~0.5 s (re-fires at idle), or bump-start by releasing the clutch in gear while
     rolling.
3. **Neutral:** remap `_gear`: **−1 = R, 0 = N, 1..6 forward** (Q from 1st → N, Q again →
   R; E from R → N → 1st). Update: shift logic (~line 651), `reverse` flag, gear display
   in `hud.gd` and `get_engine()` (grep ALL consumers of `get_engine()["gear"]` and
   `_gear` — hud.gd, sound.gd, component_hud.gd), and the shift-light gating (`_gear > 0`).
4. **Retire `_t_drive`** and its exports `torque_rise_time`/`torque_fall_time` (remove the
   Tab rows). Keep `slip_ref_speed`, substeps, semi-implicit pattern untouched. Fold the
   clutch torque into `k_stiff` on the wheel side for stability (same pattern as
   `lsd_lock`).
5. `respawn()`: reset `_omega_e` (to idle), `_clutch`, pedal states, stall flag.
6. New Tab rows: `clutch_margin`, `bite_rpm`, `intake_tau`, `engine_brake_idle`,
   `engine_brake_redline`, `anti_stall` (toggle), `manual_clutch` (toggle).

**Compile gate:** `./check.sh` clean. Use a temporary print probe to sanity-check rpm
convergence headlessly (engine settles to idle in N; revs to redline at WOT in N), then
remove it.
**User drive checklist:**
- [ ] In N at standstill: throttle revs the engine freely and the DRONE PITCH follows
  (this is the audible proof the engine state is real).
- [ ] 1st gear, anti-stall ON: pull away cleanly with just throttle; launch on grass is no
  longer ice-like — wheelspin responds to throttle taps ([[rally-sim-grass-standstill]]
  closure test).
- [ ] Manual clutch ON: it's possible to stall it; restart works; a clutch-drop launch in
  1st lights the tyres on asphalt.
- [ ] 3rd gear at 30 km/h WOT: the engine BOGS (labours below the power band) instead of
  instantly delivering.
- [ ] Nothing regressed at speed: top-speed run and dirt lap feel unchanged from Phase 0.

### Phase A2 — Emergent engine braking, overrun & auto-blip

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Delete the old `engine_brake` constant and its `throttle < 0.05` gate — overrun drag
   now flows automatically: closed throttle → `T_comb ≈ 0` → `T_fric(ω)` decelerates the
   engine → the locked/slipping clutch drags the driven wheels (through the diffs — note
   engine braking is split by the SAME paths as drive torque; verify it appears in
   `t_axle` with negative sign).
2. **Auto-blip / rev-match** (export `auto_blip := true`, Tab toggle): on downshift, while
   the auto-clutch re-engages, feed throttle to bring `ω_e` toward the post-shift target
   (`ω_wheels · gr · final`); cap the blip duration (~0.4 s). The target is COMPUTED, not
   a magic throttle constant. With `auto_blip` OFF the downshift lands with a felt
   engine-braking jolt (and, RWD on dirt, a rear twitch).
3. Verify lift-off behaviour end-to-end: mid-corner lift in 2nd–3rd should transfer load
   forward and tuck the nose (the tyre model already does this given the drag + weight
   transfer).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Lift at speed in 3rd: the car decelerates noticeably harder in gear than in N
  (coasting in N now exists!).
- [ ] Lift mid-corner on dirt: nose tucks in, slight rotation — repeatable.
- [ ] Downshift into a hairpin, blip ON: smooth; blip OFF: a felt jolt + momentary slide.
- [ ] Engine-braking strength changes with the `engine_brake_redline` slider, felt within
  one lap.

### Phase A3 — Differentials: selectable types, Salisbury LSD, centre coupling

**Files:** `vehicle_m2.gd` (replace the per-wheel torque line ~726 and `eff_split`
plumbing), `tuning_panel.gd`.

1. **Axle diff abstraction.** Exports `front_diff_type`, `rear_diff_type`
   (0 = OPEN, 1 = VISCOUS, 2 = CLUTCH-PACK, 3 = LOCKED; Tab slider with a name
   formatter). Per axle, compute the wheel-pair transfer torque `T_x`:
   - OPEN: `T_x = 0` (plus tiny friction, ~5 N·m).
   - VISCOUS: `T_x = visc_lock · Δω` (today's model; per-axle exports `front_visc`,
     `rear_visc` replacing the single `lsd_lock`).
   - CLUTCH-PACK: capacity `T_cap = preload + ramp·|t_axle|`, `ramp = power_ramp` when
     `t_axle` drives forward, `coast_ramp` on overrun; `T_x = clamp(k_smooth·Δω, −T_cap,
     T_cap)` — Coulomb with a Karnopp band, added into `k_stiff` for the semi-implicit
     update. Exports per axle: `front_preload`/`rear_preload` (N·m, ~30–120),
     `front_power_ramp`/`rear_power_ramp` (0..1, AC-style), `front_coast_ramp`/
     `rear_coast_ramp`.
   - LOCKED: very high coupling (implemented as clutch-pack with huge preload — one code
     path, no special case).
   - Wheel pairing stays `_wheels[i]`/mate as today (FL–FR, RL–RR).
2. **Centre coupling (AWD only).** Keep `torque_split` as the base epicyclic split. Add
   `centre_coupling` (N·m per rad/s of front-rear average-speed difference, export,
   ~0–200) and `centre_preload` (N·m). The coupling transfers torque between axles when
   they overspeed each other (front axle spin on loose exit → torque migrates rearward —
   THE AWD rally feel). Handbrake interaction lands in A5.
3. Engine-rpm source: driven-wheel average must now respect the centre device (weight by
   actual torque share, as today — verify after refactor).
4. Defaults that match the current feel as closely as possible (VISCOUS both axles,
   `visc = 90`) so this phase STARTS neutral; character comes from the user moving Tab
   sliders. Then bake preferred defaults per drive mode after the drive test (expected
   rally baseline: clutch-pack front ~low power ramp, clutch-pack/locked rear, AWD centre
   coupling moderate).

**Compile gate:** `./check.sh` clean.
**User drive checklist** (drive each on the rally loop hairpins + asphalt ring):
- [ ] FWD + OPEN front: inside front spins out of hairpins, car washes wide (watch the
  HUD per-wheel slip).
- [ ] FWD + CLUTCH-PACK front (moderate power ramp): pulls straight and tight on exit —
  clearly different from open within one corner.
- [ ] RWD + LOCKED rear on dirt: throttle steers the car; slides are stable and long.
- [ ] Coast ramp high vs low (rear): entry stability vs eager lift-off rotation — felt.
- [ ] AWD: with centre coupling up, loose-surface exits feel "four paws digging"; with 0
  it reverts to today's uncoupled feel.

### Phase A4 — Gearshift model + launch assist + stability assist

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. **Shift model:** shifting takes `shift_time` (~0.18 s, export): auto-clutch dips,
   ratio swaps mid-dip, clutch re-engages (with A2 blip on downshifts). Money-shift guard
   (export `overrev_guard := true`, Tab toggle): refuse a downshift that would send
   `ω_e` past redline; with the guard OFF the overrev is allowed and adds `_damage`
   (small, via the existing M8 accumulator) — training-wheel semantics.
2. **Launch assist** (export `launch_assist := false`, Tab toggle): at standstill in 1st
   with throttle held, hold rpm at the COMPUTED peak-slip launch rpm and manage clutch
   engagement toward `peak_slip_*` for the current surface; cancel on brake. (It is an
   automated version of what manual clutch + throttle discipline achieves — an aid, not a
   different physics path.)
3. **Stability assist** (export `stability_assist := false`, Tab toggle): compute target
   yaw rate from the bicycle model (`ψ̇_target = v·δ / (L + K_us·v²)` — a FUNCTION of
   geometry, not a constant); when actual yaw exceeds target by a margin, apply a small
   counter-torque via per-wheel brake torque (ESC-style, gentle, clearly an aid).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Full-throttle upshifts on the drag strip have a rhythmic dip (and cost a tenth or
  two vs Phase A3 — check the timer).
- [ ] Overrev guard OFF + deliberate money shift: engine screams past redline and the
  damage bar ticks up; guard ON: the shift is refused.
- [ ] Launch assist ON: consistent hard launches on asphalt AND dirt; OFF: manual
  technique still beats or matches it with practice (it must not be strictly superior).
- [ ] Stability assist ON: big dirt slides get visibly tamed (learning mode); OFF: raw.

### Phase A5 — Handbrake refinement (small)

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Delete the `Fy *= rear_grip_cut` hack (line ~780). Locked rears must lose lateral grip
   EMERGENTLY: verify that full handbrake locks the rear ω in the spin ODE, slip ratio
   saturates, and the friction ellipse trims `Fy`. If the emergent effect is too weak,
   the fix is in the tyre/ellipse maths, not a grip multiplier — investigate before
   reaching for any constant. Remove the `rear_grip_cut` export + Tab row.
2. Handbrake OPENS the centre coupling (A3) while held (`handbrake_opens_centre := true`,
   export) — AWD can now do proper handbrake turns without fighting the front axle.
3. Auto-clutch dips while the handbrake is held at speed (rally technique: clutch in so
   the engine doesn't fight/stall the rear lock) — with `manual_clutch` ON, that's the
   driver's job.
4. Cleanup from D10: remove the dead `brake_force` export + its Tab row; remove the
   orphan `handbrake_torque` Tab row (or wire a real `handbrake_torque` export replacing
   `brake_torque · handbrake_strength` — prefer the wire-up, it's the more honest name).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Space-tap into a dirt hairpin at ~60–80: the rear steps out predictably, the car
  rotates, release + throttle exits cleanly (all three drive modes; AWD notably better
  than before).
- [ ] The handbrake no longer feels like a "grip switch" — rotation builds with how long
  Space is held.
- [ ] Engine doesn't stall/fight during the pull (auto-clutch dip working).

### Phase B1 — Derived suspension setup (functions replace constants)

**Files:** `vehicle_m2.gd` (suspension block ~611–648, exports), `tuning_panel.gd`.

1. Compute static corner masses from `chassis_mass` + CoM position (INCLUDING the
   per-mode `_com_bias()` z-shift — front/rear split changes with drive mode).
2. Replace `spring_k` with derived per-axle rates: exports `ride_freq_front` (default
   1.4 Hz), `ride_freq_rear` (1.6 Hz); `k_axle = m_corner·(2π·f)²`. Replace `damper_c`
   with `zeta` (default 0.65): `c = 2·ζ·√(k·m_corner)` (asymmetry comes in B2).
3. Replace `arb_front`/`arb_rear` with `roll_gradient_target` (deg/g, default 4.5 —
   gravel-soft) + `roll_couple_front` (%, default 55): compute total needed roll
   stiffness from mass, CoM height and track width, subtract the springs' contribution,
   split the remainder into the two bar rates (§3.3 sources).
4. Fz clamp: raise the hard 20 000 N clamp to a DERIVED cap (e.g. 6× static corner load)
   as an interim until B3's bump stops replace it properly.
5. Tab panel: remove `spring_k`/`damper_c`/`arb_front`/`arb_rear` rows; add
   `ride_freq_front`, `ride_freq_rear`, `zeta`, `roll_gradient_target`,
   `roll_couple_front`. (The raw N/m / N·s/m values should be printed once via a
   temporary probe for sanity — expect front k ≈ 24–28 k at 1.4 Hz — then remove.)

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] The car is immediately softer and more alive over the rally loop (1.4/1.6 Hz + ζ 0.65
  vs the old 1.8 Hz / ζ 1.13) without floating or bottoming everywhere.
- [ ] `roll_gradient_target` slider: 2.5 = flat/dead, 6 = wallowy — pick the sweet spot.
- [ ] `roll_couple_front` slider audibly/visibly shifts balance (more front = understeer).
- [ ] Changing drive mode (T) re-derives the setup sensibly (FWD noses down slightly, etc.).
- [ ] The inside DRIVEN wheel no longer cooks and wears on gentle turns — the symptom that
  exposed the roll-couple bug on the first B1 drive. Watch the component HUD through a few
  steady corners in each drive mode.
- [ ] **Added 2026-08-13, because B1's verdict now covers them too:** ride height is 5 cm taller
  (B3's travel-budget resolution) — does the car still feel planted, or tall and rolly? The CoM
  is up 5 cm, so the roll moment grew ~16% and `roll_couple_front` deserves a second look at the
  new height.
- [ ] **Added 2026-08-13:** the Tab panel's Car weight slider now drives `chassis_mass` rather
  than the body's `mass` alone, so it re-rates springs, bars and the tyre load reference live.
  Drag it and confirm the car changes CHARACTER (softer/firmer, different balance), not just
  inertia. Previously it changed only how heavy the body was.

### Phase B2 — Damper model: bump/rebound asymmetry + digressive knee

**Files:** `vehicle_m2.gd` (damper force line ~633), `tuning_panel.gd`.

1. Replace `damper_c · comp_vel` with a physical damper FUNCTION per corner:
   - Asymmetry: `zeta_bump` (default 0.55) for compression, `zeta_rebound` (default 0.85)
     for extension (real dampers: rebound > bump).
   - Digressive knee: full slope below `knee_speed` (default 0.08 m/s, export); above it
     the incremental slope multiplies by `hs_blowoff` (default 0.35, export) — low-speed
     handles roll/pitch/transitions, high-speed swallows washboard and rocks.
   - Force = piecewise-linear in damper velocity, built from those four physical params;
     keep the ±3 m/s velocity clamp (safety) but it should rarely engage now.
2. Remove the interim single `zeta` from B1 (it splits into bump/rebound); keep the Tab
   panel tidy: `zeta_bump`, `zeta_rebound`, `knee_speed`, `hs_blowoff`.

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Washboard/berm sections at speed: the car stays planted and reads the texture
  instead of skipping/pogoing (compare the centre dirt patch ruts too).
- [ ] Left-right flick chain on dirt: the body takes a set and returns with a rhythm you
  can time — try an actual Scandinavian flick into a hairpin.
- [ ] Crest landings: compress-and-settle, no double bounce (rebound doing its job).
- [ ] `hs_blowoff` slider low→high changes rough-road harshness audibly/visibly.

### Phase B3 — Bump stops + honest load path

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Progressive bump stop: in the last `bumpstop_zone` (default 20 %, export) of
   `max_travel`, add a stiffening force (quadratic or cubic ramp, `bumpstop_stiffness`
   export scaled from corner load — derived default) so bottoming is an EVENT with a
   ramp, not a silent clamp. Set `w.bottomed := true` on engagement (new Wheel field).
2. Remove the interim Fz cap from B1 — loads are now bounded physically by the bump stop.
   Verify the ARB pass can no longer produce absurd Fz (the M7 note about 40 000 N).
3. `w.bottomed` is exposed for M7: it is THE clean hard-hit puncture trigger the roadmap
   asked for (`impact_punctures` stays OFF; wiring it to `bottomed` is a one-line
   follow-up the user can opt into later — note it in ROADMAP).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Jump landings and kerb strikes on the asphalt ring feel progressive — firm, not
  crashy, no physics spikes.
- [ ] Deliberately slam the biggest rally-loop crest flat-out: the car survives with a
  hard-but-controlled bottoming, and the HUD Fz numbers stay sane.

### Phase B4 — Transition rhythm: lateral relaxation + surface-derived `By` + CoM height

**Files:** `vehicle_m2.gd` (lateral force site ~777–778, `_mf_peak_u` reuse), `tuning_panel.gd`.

1. **Relaxation length:** per wheel, add a relaxed slip-angle state:
   `w.alpha_rel += (α_ss − w.alpha_rel) · clamp(v/σ_lat · dt, 0, 1)` with `sigma_lat`
   export (default 0.55 m ≈ 1.6× wheel radius) and `v` floored at `slip_ref_speed`.
   Feed `w.alpha_rel` (not raw α) into the lateral `_mf`. Longitudinal stays as-is.
2. **Surface-derived `By`:** mirror the Bx derivation — exports `peak_alpha_tarmac`
   (default 9°) and `peak_alpha_gravel` (default 14°); derive `By` per wheel via
   `_mf_peak_u(Cy, Ey)` and blend by surface grip exactly like `bxw` (line ~736). Remove
   the fixed `By = 10`. Gravel now holds a deeper slide before letting go — the DiRT-1
   "lean on it" gravel feel.
3. **CoM height** as an export `com_height` (default −0.45, the current value). After 1+2
   feel right, test raising toward −0.30/−0.25 with the user: more honest roll and load
   transfer, tamed by the now-real ARBs/dampers. Bake whatever the user prefers; keep the
   slider.

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Steering feels less darty; the car "takes a set" into corners with a beat of delay
  that makes flicks timeable (σ slider 0.2 vs 0.9 must feel clearly different).
- [ ] Gravel slides hold longer/deeper before breaking away vs asphalt (peak-α split).
- [ ] No shimmy or weaving at parking speeds or at 250 km/h on the strip (low-speed floor
  working).
- [ ] CoM A/B: raised CoM verdict recorded (keep or revert — user's call).

### Phase B5 — Bake, prune, end-to-end

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`, `docs/ROADMAP.md`.

1. Bake the user's preferred slider values from ALL phases into the `@export` defaults.
2. Prune dead code/exports/panel rows: `_t_drive` remnants, `engine_brake` constant,
   `lsd_lock` (replaced per-axle), `rear_grip_cut`, `brake_force`, old suspension
   constants — grep the panel `_specs` against the vehicle's actual properties.
   **KEEP the [1]/[2]/[3] differential presets** (`DIFF_PRESETS`, `apply_diff_preset`,
   `diff_preset_index/name`, the keyboard + touchpad bindings, the HUD readout): the user
   asked for them to stay as a permanent setup-comparison tool, not a temporary eval aid.
   Re-bake their values if later phases change what "rally" should mean, but don't delete.
3. Run the FULL end-to-end verification (§8) with the user.
4. Update `docs/ROADMAP.md`: mark M15 done, record the drivetrain/suspension state, note
   the `w.bottomed` puncture-trigger option, retire superseded notes (e.g. the Tier-3
   torque-delivery entry is superseded by the real engine/clutch model — say so
   explicitly so future sessions don't resurrect `_t_drive`).

---

### Phase C1 — Surface roughness the wheels actually feel

**Files:** a new `scripts/centreline.gd`, a new `scripts/roughness.gd`, `vehicle_m2.gd` (the
suspension raycast block), `stage.gd` (builds centrelines; surface classification already there),
`tuning_panel.gd`, `hud.gd`.

**Scope change 2026-08-13 (user's call): C1 absorbs the centreline abstraction that was Arc D's
phase D2.** The reason is §6.2 of `docs/PLAN-stages-ground-map.md`: C1 keys washboard to `s`,
distance along the road centreline, and Arc D was going to redefine how `s` is computed. Building
C1 on a θ-derived `s` and then changing that definition would move every washboard ridge on the
existing map — silently invalidating C1's own drive-verified feel and any braking points learned
on it. Building the real `s` first costs one extra sub-phase now and removes a whole class of
rework later. **Do C1.0 before C1.1.**

#### C1.0 The centreline — build this FIRST

`Centreline` holds sampled points, a **cumulative arc-length table**, and per-sample width,
heading, curvature and superelevation. It exposes:
- `point_at(s) -> {pos, heading, curvature, width}`
- `nearest_point(x, z) -> {s, lateral, heading, curvature, width}`
- `length() -> float`, `is_loop() -> bool`

Splines are not naturally arc-length parameterised — equal steps in the curve parameter are not
equal distances along the road — so build a cumulative-distance table at dense samples and invert
it by binary search ([arc-length parameterisation
primer](https://www.geometrictools.com/Documentation/MovingAlongCurveSpecifiedSpeed.pdf)). That
table IS the `s` axis, and it is the same axis `wear.gd` and `pace_notes.gd` already build for
themselves.

**In C1 the existing polar roads are simply expressed as centrelines** — sampled from `_road(θ)`
and `_asphalt_r(θ)` exactly as `wear.gd` (`:50`) and `pace_notes.gd` (`:52-57`) already sample
them. No geometry changes; it is the same points reached through a new interface. `is_loop()` is
true for all three circuits and stays true. Arc D later adds open roads (`is_loop() == false`)
and generated stages — that is additive and cannot move anything C1 tuned.

**`nearest_point` is the one query that can get expensive** — it is called per wheel per frame.
Do not brute-force it over thousands of samples. Bin the samples into a coarse uniform grid keyed
by world position so each query searches a handful of candidates. Budget it in the probe below.

**Two C1 amendments that cost nothing now and a refactor later** (full list in
`docs/PLAN-stages-ground-map.md` §6):
- Ask a function `road_class_at(x, z)` for the ISO class rather than reading the per-surface
  export inline — Arc D's D1 replaces that function's body and nothing else moves.
- Write the centre-patch exclusion as a query, not a hardcoded radius test — it becomes the
  ground map's `deformable` flag.

**The problem, measured 2026-08-11.** The stage's collision grid is `cells 320` over
`size 720` — **2.25 m per cell** — and the hills use `octaves 2` with the source comment
"fewer octaves = smoother (less high-freq bumps)". A 0.34 m tyre on a 2.25 m grid cannot
feel anything below that scale, so outside the centre deformable patch the entire world is
geometrically smooth and "dirt vs asphalt" is nothing but a friction scalar from
`grip_at()`. Arc B makes the suspension *respond* better; C1 is what gives it something to
respond to.

**Chosen mechanism (user's call, 2026-08-11): a procedural roughness FIELD**, sampled per
wheel at the contact point and injected into the suspension — not baked geometry. It costs
no mesh or collider resolution, reaches wavelengths far below any practical grid, works on
every surface at once, and is keyed to world position so it is **repeatable** — the same
bump is in the same place every lap, which is what makes a stage learnable. The trade is
that you feel the texture without seeing it; that was accepted.

#### C1.1 The roughness field (functions over constants)

- **Broadband component from the ISO 8608 standard.** Road profiles are classified by the
  displacement PSD `Gd(n) = Gd(n₀)·(n/n₀)^(−w)` with `n₀ = 0.1` cycles/m and waviness
  `w = 2`, where the single coefficient `Gd(n₀)` selects road class A (excellent) through H
  (very poor) — [ISO 8608 profile simulation](https://www.researchgate.net/publication/320302446_Simulated_Road_Profiles_According_to_ISO_8608_in_Vibration_Analysis),
  [PSD generation methods review](http://www.scielo.org.co/scielo.php?script=sci_arttext&pid=S0120-56092017000100007).
  Realise it as octave-spaced `FastNoiseLite` layers whose amplitudes follow that power law,
  so ONE physically meaningful export per surface (`road_class_gravel`, `road_class_tarmac`)
  sets the whole spectrum instead of a pile of hand-tuned bump knobs.
  **Caveat from the sources:** ISO 8608 does not say which real roads map to which class,
  and synthesised classes differ measurably from real road spectra — so treat the class as a
  physically-grounded starting point and let the drive test move it, exactly as with the
  ride-frequency numbers in B1.
- **Washboard / corrugation** (the user's first priority) is NOT broadband noise — it is a
  coherent transverse ripple train, and it needs its own term. Published figures:
  **wavelength 300–1000 mm, depth up to ~50 mm**, forming spontaneously on dry loose surfaces
  and prevalent in arid regions (which matches this stage's dusty Acropolis-style gravel) —
  [Royal Society: corrugation under vehicle weight](https://royalsocietypublishing.org/rspa/article/476/2241/20200323/80815/Corrugation-of-an-unpaved-road-surface-under),
  [review of corrugation mechanisms](https://www.tandfonline.com/doi/full/10.1080/14680629.2025.2554717).
  Model as `washboard_amp · sin(2π · s / washboard_lambda)` where **`s` is distance ALONG the
  road centreline** so the ridges run transverse to travel, as they do in reality — a noise
  field cannot produce this, which is why it is a separate term.
  **Place it where it physically forms:** corrugation is driven by repeated
  braking/accelerating traffic, so it belongs in braking zones and corner entries.
  `wear.gd` ALREADY computes exactly that field (`curv_min`, `brake_dist`) to place the wear
  line — reuse it as the washboard amplitude mask rather than inventing a second one. That
  also makes the two systems agree: the line that gets worn is the line that gets ribbed.
- **Tarmac detail** (the user's other priority): a much lower road class, plus discrete
  features — expansion joints at a set interval and occasional patched repairs. Kerbs are
  already real geometry in `stage.gd` and stay that way.

#### C1.2 The enveloping filter — do not skip this

**A tyre bridges anything shorter than its contact patch.** The tyre filters road wavelengths
shorter than the contact length, so the *effective* profile at the wheel differs from the
actual profile; this is the standard "enveloping" behaviour that MF-SWIFT models with
elliptical cams — [MF-SWIFT](https://www.researchgate.net/publication/298445350_The_MF-Swift_tyre_model_Extending_the_Magic_Formula_with_rigid_ring_dynamics_and_an_enveloping_model),
[enveloping at low speed](https://www.researchgate.net/publication/232816823_Experimental_analysis_of_tyre-enveloping_characteristics_at_low_speed).

This is the difference between texture and buzz. The contact patch here is ~0.2 m: washboard
at 0.3–1.0 m is LONGER than the patch and must come through, while fine gravel grain at
1–5 cm is SHORTER and must be largely filtered out. Feeding the raw field to a single-point
raycast would over-transmit exactly the frequencies a real tyre swallows, and the car would
feel like it is running on gravel-shaped teeth.

Implement cheaply: sample the field at N points spanning `contact_patch_len` along the
wheel's heading and combine (weighted mean, biased toward the peak — a tyre rides over a
crest, it does not sink into every trough). Export `contact_patch_len` (~0.2 m) and the
sample count; the count is a perf/quality dial, not a feel parameter.

#### C1.3 Injection point

Add the effective roughness offset to the **suspension raycast hit distance** in
`vehicle_m2.gd`, i.e. shorten/lengthen the measured ground distance. One line, and
everything downstream inherits it for free and correctly: compression → spring → damper →
B3's bump stop → `Fz` → load-sensitive grip → weight transfer → tyre heat/wear. Also offset
`w.contact_point` so dust, marks, terrain dig and audio stay consistent.

**Exclude the centre deformable patch** (`terrain.gd` already puts REAL geometry there);
double-counting would give that patch texture twice. Blend the field out over its border.

#### C1.4 Known interaction — the travel budget (read B3's open item first)

B3 recorded that **all four corners already peg at 100% of travel on the rough rally loop at
100 km/h**, because B1's softer springs moved static sag from 7.7 cm to 12.7 cm. C1 adds
input on top of that, so it will make bottoming worse before it makes it better. C1 must
re-measure the bottoming statistics and, if they degrade, force the decision B3 left open:
raise `ride_freq_*`, or raise ride height (`rest_length` + `max_travel` 0.45 → 0.50, gravel
style, at ~5 cm of CoM height). Do not paper over it by shrinking `roughness_gain` — that
would be tuning a magic number to hide a real geometry problem.

**Compile gate:** `./check.sh` clean.
**Headless probes (then remove):**
0a. **Centreline geometry identity.** Compare `Centreline` samples against direct
   `_road(θ)`/`_asphalt_r(θ)` evaluation at 2000 positions per circuit. Pass: max deviation
   **< 1 mm**. The existing map must not shift.
0b. **`nearest_point` correctness and cost.** Against brute force at 500 random positions:
   same `s` within one sample spacing. Report cost for 4 wheels × 120 Hz against the 1.84 ms/tick
   baseline.
1. **Spectrum:** sample the field along a straight line and dump RMS per octave band; the
   slope must follow the ISO power law, and the gravel class must sit clearly above tarmac.
2. **Enveloping:** a 3 cm bump 4 cm wide must be strongly attenuated at the wheel while a
   0.6 m washboard passes at near full amplitude. This is the phase's key correctness test.
3. **Repeatability:** sample the same world position twice, on different frames and after a
   respawn — identical values, or the stage is not learnable.
4. **Travel budget:** peak `Fz`, max compression and bottomed-frame count on the rally loop at
   100 km/h, before vs after, against B3's recorded numbers.

**User drive checklist:**
- [ ] Lap times, sector splits, pace notes and the wear line are all unchanged — C1.0 is a
  refactor and must be invisible on its own.
- [ ] Braking hard into a dirt corner: washboard is felt — the car skips and dances, and it
  is a handling event to manage, not a cosmetic vibration.
- [ ] The rally loop reads as a SURFACE at speed rather than a smooth floor, and tarmac reads
  smooth-but-alive (joints and patches, not dead glass).
- [ ] `roughness_gain` 0 restores today's glass-smooth car exactly — the A/B that proves what
  the phase bought.
- [ ] No buzz or jitter at parking speed, and none at 250 km/h down the drag strip.
- [ ] Bottoming is no worse than B3's baseline, or the ride-height/frequency call has been
  made deliberately with the user.

### Phase C2 — Self-aligning torque: the steering signal (no hardware required)

**Files:** `vehicle_m2.gd` (lateral force site, after B4's relaxation length), `hud.gd`,
`tuning_panel.gd`.

This is the half of "force feedback" that is REAL PHYSICS and buildable today. What a driver
feels through a wheel is not "the car" — it is the torque the front tyres exert about their
steering axis. Getting this right is worth doing even if no wheel ever arrives: it is the
roadmap's M13 SAT, it can drive a controller-rumble cue, and it is the exact signal C3 would
send to a motor.

1. **Pneumatic + mechanical trail.** Lateral force acts BEHIND the contact centre by the
   pneumatic trail `t_p`; caster adds mechanical trail `t_m`. Per front wheel:
   `Mz = Fy · (t_p + t_m)`, summed and divided by the steering ratio to get rack torque.
2. **The trail must COLLAPSE as the tyre saturates.** This is the whole point: pneumatic
   trail shrinks toward zero as slip angle approaches peak, so the wheel goes LIGHT just
   before the front washes out. That lightening is the most informative cue in a sim —
   more than raw force. Model `t_p = t_p0 · (1 − |α_rel| / α_peak)` clamped at 0 (α_peak is
   already available from B4's `peak_alpha_*`), or the Pacejka Mz form if it proves cleaner.
3. Exports + Tab rows: `trail_pneumatic` (m, ~0.03), `trail_mechanical` (m, ~0.02 from
   caster), `steer_ratio` (~15:1), `sat_gain` (output scaling, 0..2).
4. Expose `get_steer_torque()` (N·m at the rack) and show it on the HUD. Optionally drive
   gamepad rumble from |torque| as a poor-man's cue — `Input.start_joy_vibration()` is
   rumble, NOT force feedback, and must not be described as FFB anywhere.
5. **Headless probe:** sweep slip angle 0 → 2×peak at constant load and print the torque
   curve. It MUST rise, peak BEFORE the lateral-force peak, then fall — if it rises
   monotonically the trail collapse is wrong and the signal is worthless for feel.

**Compile gate:** `./check.sh` clean.
**User checklist (works on keyboard/pad — no wheel needed):**
- [ ] HUD steering torque rises with cornering load, then drops distinctly as the front
  starts to push wide — visible a beat BEFORE the car actually washes out.
- [ ] Torque is near zero at a standstill and on a straight, and reverses sign with
  steering direction.
- [ ] Gravel vs tarmac differ (they have different peak slip angles).

### Phase C3 — Wheel input path (gated: needs the wheel in hand)

**Files:** `world.gd` (input map + device detection), `vehicle_m2.gd` (steering block),
`hud.gd`, `README.md`.

A wheel is not a big analog stick — the existing steering path would actively fight it.
`_steer` ramps toward the target (built for binary keys) and `steer_speed_falloff` reduces
lock at speed; both are compensations for input devices that have no self-centring and no
range. A real wheel supplies its own, so it must bypass them.

1. Detect a wheel (Godot exposes it as a joypad; identify by name/axis count and by a
   rotation range far beyond a thumbstick's). Store a `_wheel_mode` flag.
2. Steering in wheel mode: **direct, unfiltered mapping** — no `steer_rate` ramp, no
   `steer_return_rate`, no speed falloff. Add `wheel_range_deg` (the wheel's physical
   rotation, e.g. 900) and map it onto the car's `max_steer_deg` through `steer_ratio` so
   the ratio is PHYSICAL rather than a normalised 0..1 fudge.
3. Pedals: separate axes for throttle / brake / clutch (wheels report these independently);
   they already bypass the virtual-pedal shaping via the analog path from Phase 0. Add
   per-axis calibration (rest point + full travel) — cheap, and unusable without it if the
   pedals report inverted or half-range, which is common.
4. Shifter: H-pattern (each gear is a button), sequential, or paddles — map to the existing
   `shift_up`/`shift_down` plus optional direct-to-gear actions. A handbrake axis if present.
5. **Keyboard and the DS4 must keep working unchanged** — this is an added path, not a
   replacement, and it is the regression risk of the whole phase.

**Compile gate:** `./check.sh` clean, plus a headless probe printing the detected device
name, axis count and live axis values (the same approach that verified the DS4 bindings).
**User checklist:**
- [ ] Wheel steers the car 1:1 with no lag, no snap-back, and full lock reachable.
- [ ] Pedals read full 0..1 travel (HUD pedal line), clutch included.
- [ ] Shifter selects gears including R and N; handbrake works.
- [ ] Unplug the wheel: keyboard and DS4 still drive correctly.

### Phase C4 — FFB output (gated: **spike before committing to this phase**)

**Files:** a new `scripts/ffb.gd` output layer + whatever the spike concludes.

**Read §7's FFB risk entry before starting.** Godot 4 has NO built-in force-feedback API —
`Input.start_joy_vibration()` is rumble only. This phase therefore begins as a
research spike, not an implementation, and it is entirely legitimate for it to conclude
"not feasible on this machine without engine work."

1. **Spike (timebox it).** Prove that Godot 4.4 on Apple Silicon can emit a single constant
   force to the connected wheel. Candidate routes, cheapest first:
   - a GDExtension wrapping SDL_Haptic (macOS routes it through the ForceFeedback
     framework) — note the existing community plugin is **GDNative**, i.e. the Godot 3 API,
     so it needs porting, and supports constant force only;
   - a small external bridge process that owns the device and takes torque over a socket;
   - vendor SDKs, if the specific wheel has macOS support at all.
   Deliverable: the wheel physically pushes back, or a written "no, because…".
2. Only if the spike succeeds: map C2's rack torque → constant force with `ffb_gain`
   (master, 0..1), a slew-rate clamp, and a hard output clamp.
3. **Safety, non-negotiable:** zero the output on pause, focus loss, respawn, stall and
   quit. A wheel commanded to full torque with nobody holding it can hurt someone or
   damage itself — the "zero on every exit path" test comes BEFORE any feel tuning.
4. Layer road texture on top once Arc B exists: suspension velocity and `w.bottomed` give
   kerb/washboard/bottoming cues that are far more convincing than SAT alone.
5. If the spike fails: C2's signal still drives the HUD and rumble; record the finding in
   ROADMAP.md so no future session re-litigates it, and park C3.

**Compile gate:** `./check.sh` clean.
**User checklist:**
- [ ] Wheel goes light exactly when the front starts to wash out (the C2 cue, now felt).
- [ ] Kerbs, ruts and bottoming come through as texture, distinct from cornering load.
- [ ] `ffb_gain` from 0 → 1 scales cleanly with no oscillation or clipping.
- [ ] Every exit path (pause, alt-tab, respawn, quit) leaves the wheel limp.

## 6. What must NOT break (regression surface)

- **The tyre model core** (`_mf`, `_mf_slope`, `_mf_peak_u`, friction ellipse, `_mu_load`,
  surface-blended `Bx`): Arc A routes torque INTO it; B4 adds a state in FRONT of the
  lateral path. Never restructure the ellipse (ROADMAP: "refine, don't rebuild").
- **M7 tyre thermal/wear/puncture:** `_update_tyre(w, Fx, Fy, v_long, v_lat, dt)` call
  signature and the `w.tyre_grip` fold-in sites must keep working; `[P]` debug key; the
  deflated-visual + shake path.
- **M8 damage:** `damage_power_loss` must keep multiplying engine output (relocates into
  `T_comb`), grip-loss sites unchanged, steering pull unchanged.
- **M6 wear line:** `surface_source.grip_at()` is wrapped by `wear.gd` — every grip query
  must keep going through `surface_source` (never call `stage.grip_at` directly).
- **Consumers of vehicle state:** `hud.gd` (per-wheel Fz/slip/grip + `get_engine()`),
  `component_hud.gd`, `sound.gd` (rpm→pitch, slip→tyre audio, puncture flap), `world.gd`
  (skid-mark gate reads base grip; `w.slip` feeds terrain dig + dust), `terrain.gd`
  (`w.slip` wheelspin excavation), `time_trial.gd`/`pace_notes.gd` (untouched). After the
  gear remap (A1), grep EVERY consumer of `_gear`/`get_engine()["gear"]`.
- **Respawn contract:** R must reset every new state added by every phase (engine ω,
  clutch, pedals, alpha_rel, bottomed, assist states). Check `respawn()` at the end of
  each phase.
- **Keyboard drivability at every phase boundary** — the user must always be able to test.
- **Headless check** must stay clean — no phase may introduce editor-only dependencies.

## 7. Risks & unknowns, and de-risking

- **120 Hz perf on the M1** (raycasts, wear sampling, terrain all tick 2×): measure with
  the Performance monitor probe in Phase 0 before building on it. Fallback: 90 Hz
  (`physics_ticks_per_second=90`, substeps 4 = 360 Hz driveline) — decide with data.
- **120 Hz feel drift:** damper forces sampled 2× as often behave slightly differently.
  Phase 0's checklist explicitly re-baselines (top speed, lap vs ghost) BEFORE any model
  changes, so any drift is caught in isolation.
- **Clutch ODE stiffness:** a locked clutch is a rigid constraint; the plan avoids
  stiffness blowups by keeping the LOCKED state kinematic (today's proven path) and only
  integrating during slip, with the tanh/Karnopp band + `k_stiff` fold-in. If chatter
  appears at the lock boundary, widen the Karnopp band or raise `drive_substeps` — do NOT
  add damping constants.
- **Gear remap fallout (A1):** `_gear` semantics change; the de-risk is the explicit
  grep step for all consumers + the shift-light/reverse checklist items.
- **Salisbury sign conventions** (power vs coast under reverse gear / negative torque):
  test reverse explicitly in A3's headless probe; the ramp selection must use the SIGN of
  axle input torque, not the throttle.
- **Removing `rear_grip_cut` (A5) may reveal the ellipse under-trimming locked-wheel
  lateral force.** That would be a genuine tyre-model finding — investigate the ellipse
  maths rather than restoring the hack; worst case keep the export defaulted to 1.0
  (= off) and document.
- **Relaxation length at near-zero speed** can oscillate — floored `v` and the clamp on
  the blend factor prevent it; the parking-speed checklist item verifies.
- **Raising the CoM (B4)** risks rollovers on berms; it's gated behind a user A/B with
  the old value one slider-drag away.
- **Softer springs (B1) + existing 1.35-ish jump geometry** may bottom more: B3's bump
  stops are deliberately ordered right after; if B1 testing bottoms violently, temporary
  mitigation is a higher `ride_freq` until B3 lands.
- **Assists masking physics bugs:** all assists land LAST in their arc (A4) and default
  OFF (except anti-stall) — raw physics is always the tested baseline first.
- **C1 without the enveloping filter will feel like buzz, not texture.** A real tyre bridges
  everything shorter than its contact patch (~0.2 m here); a single-point raycast bridges
  nothing. Inject the raw field and every 2 cm stone arrives at full amplitude — high-
  frequency noise the car cannot possibly ride. The enveloping sample-and-combine in C1.2 is
  not polish, it is the thing that makes the phase work; if the drive test reports "vibration"
  rather than "surface", suspect the filter before touching amplitudes.
- **C1 fights the travel budget B3 already flagged.** All four corners peg at 100% travel on
  the rough loop at 100 km/h today. More input makes that worse, and the honest fixes are ride
  frequency or ride height — NOT quietly lowering `roughness_gain`, which would hide a real
  geometry problem behind a tuned constant.
- **C1 must not double-count the centre deformable patch**, where `terrain.gd` already puts
  real ruts in the collider. Blend the field out across that border.
- **C1 changes the baseline every earlier phase was judged against.** Dampers, bump stops and
  tyre wear were all tuned on a smooth road. Expect to revisit B2's `hs_blowoff`/knee (see the
  ordering note in §4) and to see tyre temperatures and wear move. `roughness_gain = 0` is the
  A/B that separates "C1 broke it" from "C1 revealed it".
- **FFB may simply not be reachable from Godot on this Mac (C4).** Verified 2026-08-05:
  Godot 4 ships **no** force-feedback API — `Input.start_joy_vibration()` is rumble
  (weak/strong motors), which is a different thing and must never be labelled FFB. The
  engine proposal to add constant/spring/damper/friction effects is still open
  ([godot-proposals#8309](https://github.com/godotengine/godot-proposals/issues/8309)),
  and the main community workaround
  ([Dechode/Godot-FFB-SDL](https://github.com/Dechode/Godot-FFB-SDL)) is a **GDNative**
  (Godot 3 API) SDL2 wrapper supporting constant force only, with no documented macOS
  support; a downstream example needed rebuilding for Godot 4.4 and broke again on 4.5's
  SDL3 switch ([FFB example](https://cairerocha.itch.io/godot-force-feedback-example-ffb)).
  Stack that on top of patchy macOS/Apple-Silicon driver support for consumer wheels and
  C4 is genuinely uncertain. **De-risk by ordering:** C1 (surface texture) and C2 (the
  steering signal) deliver standalone value with zero hardware, C3 makes a wheel usable even
  with dead FFB, and C4 starts as a timeboxed spike whose honest outcome may be "no". Do not
  buy hardware on the assumption that C4 will work.
- **An FFB wheel is a physical actuator.** Unlike everything else in this plan, a bug here
  moves a real object with real force. Output clamps, slew limiting and zero-on-every-exit
  come before feel tuning, not after.

## 8. End-to-end verification (after B5)

Compile: `./check.sh` clean, plus one windowed run for audio/TTS sanity.

User drive-through, all in one session, keyboard:
1. **Cold start ritual:** spawn, N, free-rev (pitch follows), 1st, pull away — no stall
   with anti-stall ON; deliberately stall with manual clutch ON; restart.
2. **Drag strip:** launch-assist OFF manual launch, then ON — compare; full upshift run
   to ~259 km/h in 6th (baseline preserved); money-shift guard test at speed.
3. **Rally loop, 3 laps AWD:** flick chain through the esses (rhythm), handbrake hairpin,
   lift-off rotation test, washboard section planted, one deliberate crest slam
   (bump-stop event, no spike), lap time within reach of the pre-plan ghost (feel must
   not have cost pace unless the user prefers it).
4. **Diff character A/B on the same corner:** open vs clutch-pack front (FWD), locked vs
   open rear (RWD) — each change felt within a lap.
5. **Asphalt ring, 2 laps:** tarmac tyres bite at low slip angles (derived By), trail
   braking works, kerb strikes progressive.
6. **Consumables intact:** [P] puncture visual+flap+shake; tyre temps move sensibly; a
   deliberate crash damages power/grip/steer-pull; R repairs and resets everything.
7. **Systems intact:** ghost + sector splits + pace notes on both circuits, wear line
   darkens the dirt racing line, [B]/[C]/[T]/[L]/Tab all work.
8. User records a verdict per acceptance criterion in §1 — anything unmet becomes a
   follow-up tuning session, not a silent pass.

## 9. Phase status (executor updates this)

- [x] Phase 0 — 120 Hz + virtual pedals — DONE 2026-08-02: user confirms top speed, throttle ramp, and 120 Hz all feel correct/more concrete; steady physics 1.84 ms/tick (huge M1 headroom).
- [x] A1 — Engine inertia + clutch + neutral — DONE 2026-08-03: headless probe PASS (N coast-down 3000→988 rpm, N WOT →7150/7200); user drove the checklist and verdict is "feels good".
- [x] A2 — Engine braking + auto-blip — implemented 2026-08-03 (`./check.sh` clean; headless probe PASS: 2s coast 20→ in 3rd drops 4.29 m/s vs 3.74 in N (overrun drag reaches the axles); blipped 3→2 dips clutch to 0.00, lands 14 rpm off the computed target, re-locks; jolt A/B 0.3s post-shift: 0.28 m/s lost blipped vs 1.10 raw; probe removed). Note: `engine_brake` constant already deleted during A1's rewrite; shifts now break the clutch lock so the ratio jump resolves through the plates. First drive feedback 2026-08-04: engine braking too weak in 3rd + no felt tuck → friction anchors raised to competition-spec 25/90 N·m (probe: in-gear coast extra 0.55→0.90 m/s per 2s); added [I] ignition starter (stabs clutch + 1.2s anti-stall grace so a worst-case 1st-gear restart survives, probe PASS). Eager lift-off ROTATION beyond this is A3's coast-ramp territory. Re-drive verdict 2026-08-04: engine braking "good now, feels comfortable" at 25/90; lift-off tuck accepted as A3 coast-ramp territory. A2 DONE.
- [x] A3 — Differentials — DONE 2026-08-05: user drove the [3] RALLY preset and reports it
  "feels good"; presets stay in the game as a permanent A/B tool (see §5 B5 — do NOT prune).
  Also closes the A2 lift-off item: the mid-corner tuck that felt flat under A2's defaults
  reads properly now that the rear coast ramp carries it — so coast lock was the right
  diagnosis, and no further tyre/suspension work is owed on that specific complaint.
  Implemented 2026-08-04 (`./check.sh` clean; headless probe PASS: airborne pair split 20 rad/s after 0.25s → OPEN 18.2 / VISCOUS 0.00 / LOCKED 0.00; AWD launch 14.7 m/s, reverse −9.3 m/s, centre 150/80 stable. Found+fixed: saturated-Coulomb chatter on LOCKED — transfer torque now impulse-capped at the one-substep pair equaliser, same for the centre. Ramp power/coast selected by sign of engine-side torque `t_gb` → reverse-safe. Defaults VISCOUS 90/90 + centre 0/0 = pre-A3 feel; probe removed). Stall-restart report re-checked same day: all four paths (detect / Shift-hold / release pull-away / bump-start) PASS headless on current build — user's failures were on the pre-`[I]`/pre-grace build. AWAITING user drive checklist verdict.
- [x] A4 — Shift model + assists — DONE 2026-08-11 (drive-verified)
  (`./check.sh` clean; headless probe PASS on all four areas, then removed).
  **Shift model:** a request now starts a `shift_time` (0.18 s) manoeuvre instead of swapping the
  ratio in a tick — the auto-clutch dips, the dogs take the new gear at MID-dip, the plates feed
  back in. Probe: swap lands 0.09 s after the request with the clutch already at 0.00, home again
  0.27 s later. This EXTENDS the A2 path rather than duplicating it — the mid-dip swap is where
  A2's `_clutch_locked = false` / `_blip_t` / `_clutch = 0.0` now fire, so the heel-toe ordering
  (plates open BEFORE the new ratio bites) is preserved by construction; probe confirms a blipped
  5th→4th at 40 m/s still re-locks. A fresh request while the box is busy is ignored.
  **Overrev guard:** decided by the COMPUTED post-shift rpm (driven-wheel speed through the new
  ratio), not by shift direction — so it catches N→1st and selecting R at speed as well as the
  4th→2nd grab. Probe at 40 m/s: 5th→4th allowed (5694 rpm), 3rd→2nd refused with the guard on,
  allowed with it off for +0.110 damage through the M8 accumulator.
  **Launch assist:** both numbers derived. Slip target = the surface's peak-grip slip under the
  driven wheels (the same blend that derives `Bx`); launch rpm = the grip-limited wheel torque at
  that peak, carried at the clutch's own design margin (`clutch_margin`) and reflected through the
  gearing + motoring drag, inverted through the torque curve. Emergent result: dirt 2850 rpm /
  0.28 slip, asphalt 4300 rpm / 0.14. The throttle governs the revs; the clutch is A1's schedule
  with its bite point computed instead of fixed, trimmed on measured wheelspin. Probe (4 s
  standing start): dirt 45.7 m vs 40.5 m raw, asphalt 48.2 m vs 38.6 m raw — an aid over a crude
  pedal-to-the-floor launch, not a physics shortcut (it only sets throttle and engagement).
  NOTE for the drive test: the baseline it beat is the WORST manual technique; whether a practised
  manual-clutch launch still matches it is a feel question only the user can settle.
  **Stability assist:** reference yaw from the bicycle model, with the wheelbase read off the wheel
  mounts and `K_us` derived live from axle load over the tyre model's own cornering stiffness
  (so it moves with weight transfer and the drive-mode CoM bias). Excess yaw is trimmed with outer-
  front brake through the existing pedal brake path (inheriting its semi-implicit slope), impulse-
  capped per substep per A3, and ceilinged at the torque that would just LOCK that tyre — braking
  past lock would cost the lateral grip the correction depends on. Probe: an induced 1.60 rad/s
  spin at 25 m/s decays to 0.17 rad/s in 1 s vs 0.30 raw, peak correction 2154 N·m.
  New Tab rows: `shift_time`, `overrev_guard`, `launch_assist`, `stability_assist`,
  `stability_gain`, `stability_margin`. All new state resets in `respawn()`.
  **User drive verdict 2026-08-11:** upshifts "okay"; overrev guard off works (~12% damage per
  money shift); launch assist works AND is easy to match manually — so it passes the "must not be
  strictly superior" bar. Stability assist FAILED its item: "not that noticeable at slides,
  although I do feel its effect". Two causes found and fixed, then re-probed:
  (1) **Real bug** — the yaw error was compared as MAGNITUDES (`|yaw| - |yaw_ref|`). A slide is
  counter-steered, so the bicycle-model reference points the *other way* and its magnitude is
  large, which RAISED the intervention threshold exactly when the car was sideways. A 1.2 rad/s
  slide on opposite lock read as 0.2 rad/s of excess instead of 2.0. The error is now signed.
  (2) **Brake-only authority is physically capped**: in a developed slide the outer front tyre is
  already on its friction circle, so braking it rotates its force vector rather than adding one —
  the probe showed the correction saturating at the tyre's lock limit while yaw barely moved. The
  assist now also withholds engine demand over the same band (`stability_margin` IS the band, so a
  small excess trims and twice the margin lifts fully) — the first thing a driver or a real ESC
  does. This is a deliberate extension of §5's brake-only wording, made because brake-only could
  not meet §5's own acceptance criterion ("big dirt slides get visibly tamed").
  **The engine-torque withholding was WRONG and has been reverted** — user re-drive same day:
  "when turning rpm gets severely handicapped, to the point that if I play with the wheel while
  pressing full throttle the car almost comes to a stop and loses all power". Root cause: the
  intervention was gated on `|err| > margin` with no sign test, and a cornering car normally yaws
  LESS than its reference (plain understeer), so the large opposite-signed error fired the assist
  through every ordinary corner. Three fixes, all probe-verified:
  1. **Oversteer gate** — only act when the error runs the SAME way the car is rotating
     (`err * yaw > 0`). This alone fixes the reported power loss.
  2. **Grip-ceilinged reference** — `yaw_ref` is now clamped to `mu*g/v` (mu averaged live over the
     contacting tyres, so it falls with speed and surface). The bicycle term is the KINEMATIC
     no-slip yaw rate and this car's balance makes `K_us ≈ 0`, so at road speeds it asked for a
     yaw rate no tyre could hold and every real slide still read as "under reference". The grip
     ceiling is what makes the reference mean anything.
  3. **Counter-steer standoff** — the aid stands down once the driver is already correcting
     (`steer_angle * yaw >= 0` to act). MEASURED FINDING, worth keeping: braking a saturated outer
     front during opposite lock makes the slide WORSE (probe: 1.23 rad/s vs 0.55 with the assist
     off). Opposite lock works through the front tyres' lateral force, whose moment arm about the
     CoM is the front-axle distance 1.35 m, against the brake's half-track 0.82 m — so trading
     lateral for longitudinal at a tyre already on its friction circle gives up more yaw authority
     than it buys. This is also why the torque cut looked like it helped in the first probe: that
     scenario held opposite lock from frame zero, and neither actuator was really working.
  Final probe: full-throttle full-lock cornering — assist ON 52.4 km/h / 0.56 rad/s yaw vs OFF
  40.9 km/h / 0.95 (the aid now COSTS nothing and keeps the car pointed); counter-steered slide —
  ON 0.58 vs OFF 0.55 (no longer interferes); rotation building before opposite lock — ON 0.61 vs
  OFF 1.06 rad/s (the regime the aid owns, and it clearly catches it). The assist touches brakes
  only; engine demand is untouched. Re-drive verdict 2026-08-11: **"stability is good"** — the
  power-cut-through-corners artefact is gone and the aid is accepted. **A4 DONE.**
- [x] A5 — Handbrake refinement — DONE 2026-08-11 (drive-verified)
  (`./check.sh` clean; headless probe PASS on all four items, then removed).
  **1. The grip hack is gone.** `Fy *= rear_grip_cut` deleted along with the export and its Tab
  row. The plan flagged that this might expose the ellipse under-trimming a locked wheel — it does
  not. Probe (22 m/s, 3rd, steering held): lever OFF yaw 0.23 rad/s and rear slip angle 7.8 deg;
  lever ON yaw **0.58** rad/s and rear slip angle **18.8** deg. The rear omega goes 64.7 -> 0.11
  rad/s, slip ratio saturates at -1.00 and ellipse utilisation hits 1.00, so the lateral force is
  being trimmed by the friction ellipse exactly as intended. No constant needed anywhere.
  **2. The lever releases the centre** (`handbrake_opens_centre := true`). With it OFF the locked
  rears drag the front axle down through the coupling (front omega 64.7 -> 14.1); with it ON the
  fronts keep rolling at 52.9. That is the difference between an AWD car that ploughs on the lever
  and one that rotates.
  **3. Auto-clutch dips** while the lever is up above `slip_ref_speed` (probe: clutch 0.00), so the
  engine is not fighting the locked axle. Below that it is just a parking brake and the existing
  anti-stall clamp covers it; with `manual_clutch` ON it is the driver's job, so the dip lives in
  the auto branch only.
  **4. D10 cleanup.** `handbrake_torque` is now a REAL export (N*m per rear wheel) replacing
  `brake_torque * handbrake_strength` — the honest name the plan preferred — defaulted to 2600 so
  the lever feels identical to before. Dead `brake_force` and `handbrake_strength` exports and
  their Tab rows are gone (both were M1-only; `world.gd` only ever loads `vehicle_m2.gd`, so those
  rows were unreachable). New Tab row: `handbrake_opens_centre`. NOTE for B5: other dead "(M1)"
  rows remain in `_specs` (`engine_power`, `launch_boost`) — they belong to B5's prune, not here.
  **First drive verdict 2026-08-11: REJECTED** — "felt good beforehand, now way too strong, most
  times just slows the car and [kills] the swing". Root cause found, and it is the tyre model, not
  the handbrake: **the friction ellipse only RESCALES the Fx:Fy ratio the two independent Magic
  Formula curves produce, it never CORRECTS it.** Invisible until a wheel truly lets go — at slip
  ratio −1 the longitudinal curve is saturated while the lateral curve still reads a modest slip
  angle, so the ellipse returns a force far too lateral for a locked tyre. Measured on a locked
  rear at ~10° of slip: **1740 N of lateral force where opposing the slip velocity gives ~460 N —
  nearly 4× too much grip.** That is precisely what `rear_grip_cut = 0.2` was standing in for
  (1740 × 0.2 ≈ 350 N ≈ the true 460 N), which is why deleting it made the car brake instead of
  rotate. Fixed per §5's own instruction ("the fix is in the tyre/ellipse maths, not a grip
  multiplier"): past the ellipse, a tyre's force DIRECTION is handed over to its slip velocity,
  blended in over `SLIDE_BAND` of utilisation and capped by the ellipse's own radius along that
  direction (so the tyre stays anisotropic). Export `slide_friction` (default ON, Tab toggle) for
  A/B. Probe, same handbrake pull: yaw **0.60 → 0.90 rad/s** and rear slip angle **24° → 44°**
  (rotation ×1.5), while straight-line braking is unchanged to the decimal (44.7 km/h lost either
  way) — the correction only touches tyres that have genuinely let go. **Re-drive verdict
  2026-08-11: "now it feels better" — A5 DONE.** NOTE for Arc B and beyond: the sliding-friction
  correction is a TYRE-MODEL change, not a handbrake one. Every genuinely saturated tyre now takes
  its force direction from its slip velocity, so limit behaviour (big slides, locked-brake entries)
  differs from every phase before A5. `slide_friction` (default ON) A/Bs it.
- [x] B1 — Derived suspension setup — **DONE 2026-08-13, drive-verified: "feels good"**, with the
  5 cm ride height (B3's travel-budget resolution) and the `chassis_mass` slider fix both included
  in the same drive. One usability finding from that drive, now addressed: the user could not tell
  what `roll_gradient_target` was doing, because the Tab panel listed ~76 unlabelled sliders with no
  explanation anywhere. The panel now sorts A-Z and shows a one-line explanation of whatever is
  under the cursor. **Treat that as a phase lesson, not a side quest:** a derived-setup phase hands
  the user physical handles (Hz, damping ratio, deg/g) instead of magic numbers, and those handles
  are only an improvement if the panel says what they mean. Any future phase that adds a derived
  tunable adds its HELP line in the same commit.
  Implemented 2026-08-11 —
  (`./check.sh` clean; headless probe PASS, then removed). `spring_k` / `damper_c` / `arb_front` /
  `arb_rear` are gone; the suspension now derives from `ride_freq_front` (1.4 Hz),
  `ride_freq_rear` (1.6 Hz), `zeta` (0.65), `roll_gradient_target` (4.5 deg/g) and
  `roll_couple_front` (55%), via `_derive_setup()` each tick — so live slider edits AND the
  drive-mode CoM shift both re-rate the car immediately. Corner masses come from the CoM position
  including `_com_bias()`, so switching to FWD genuinely loads and re-rates the front axle.
  Probe (AWD): front **24 181 N/m** / rear 31 583, dampers 3574 / 4084, static compression 0.127 m
  of 0.45 m travel — the plan predicted 24–28 k at 1.4 Hz, so the derivation lands where expected.
  Versus the retired constants, which worked out at **1.80 Hz and zeta 1.13** (stiff AND
  overdamped): the car is now softer and much less damped, and roll goes **1.28 -> 3.07 deg/g**.
  **Interaction to know about:** at the current CoM height (-0.45, ~0.31 m above the contact plane)
  the springs alone already give 3.07 deg/g, and a bar can only ADD roll stiffness — so the bars
  correctly solve to ZERO in AWD and FWD, and `roll_gradient_target` only bites below ~3.1. RWD is
  the exception: its rearward CoM leaves the front soft (17 016 N/m), so a front bar of 1967
  appears to hold the 55% roll couple. When B4 raises the CoM the roll moment grows and the target
  becomes reachable, at which point this slider starts doing something across its whole range.
  `_fz_cap` was an interim 6x static corner load; B3 (brought forward) has since removed it.
  **Correction 2026-08-11, after the first drive:** the user reported the inside DRIVEN wheel
  overheating and wearing out — front in FWD, rear in AWD/RWD — even on gentle turns. Measured on a
  steady arc: `roll_couple_front` had NO AUTHORITY. Sizing the bars only to reach the roll-gradient
  target left them at zero, so the springs' own distribution set the balance, and flat-ride tuning
  (stiffer rear) handed the rear the load transfer: **43.4% front in AWD and 33.8% in RWD against a
  55% setting** (pre-B1 it was 53.1% in every mode). That unloads the driven axle's inside wheel,
  which then spins, heats and wears — exactly the symptom, in exactly the modes reported.
  `_derive_setup` now sizes the bars to ENFORCE the couple first (the axle short of its share gets
  the bar), and only then stiffens both ends together if the roll gradient is still under target.
  Measured after: 55.0% front in all three modes, and the inside rear gains load in RWD
  (3.53 -> 4.04 kN). The cost is less total roll (AWD 3.07 -> 2.44 deg/g), unavoidable because a
  bar can only add stiffness — `ride_freq_rear` is the handle to give roll back.
- [x] B2 — Damper model — DONE 2026-08-13 (drive-verified: "feels good") (`./check.sh` clean;
  headless probe PASS, then removed). `zeta` splits into `zeta_bump` (0.55) and `zeta_rebound`
  (0.85) with a digressive knee at `knee_speed` 0.08 m/s and `hs_blowoff` 0.35 above it; the
  damper force is now a piecewise-linear FUNCTION of damper velocity built from those four
  physical parameters, replacing `damper_c · comp_vel`. `_ccrit_*` holds 2·√(k·m) per corner and
  the ratios are applied per-direction at force time.
  Probe: rebound/bump ratio **1.55× at every velocity** (0.85/0.55 ✓); incremental rate 3024 Ns/m
  below the knee vs 1058 above it = **0.35× exactly** ✓; and with `zeta_bump = zeta_rebound = 0.65`
  and `hs_blowoff = 1.0` it reproduces B1's linear damper with a **max error of 0.000000 N** —
  that exact equivalence is the A/B that proves what the phase bought.
  **Bottoming re-measure, rally loop at ~100 km/h (this is the interesting part, and it did NOT go
  as predicted).** The B3 revision named B2 as the most likely fix for the pegging. It is not.
  B1 linear damper: 4/4 corners pegged, 31 frames on the stops, **max Fz 37.2 kN**. B2 asymmetric +
  digressive: 4/4 corners still pegged, **50** frames on the stops, **max Fz 28.8 kN**.
  So B2 does not reduce how OFTEN the car reaches the stops — it slightly increases it — but it
  cuts peak load by **23%**. That is exactly what a blow-off valve is for: it lets the suspension
  move instead of transmitting the spike into the chassis, so the car rides INTO the stop more
  often but arrives much more gently.
  **Consequence for the B3 revision:** hypothesis (b) is now disproven, and (a) stands — the bump
  stop is a pure displacement spring that returns energy instead of dissipating it. Note also that
  `rest_length`/`max_travel` are now **0.50 m** (the ride-height lever was taken), giving 0.373 m
  of bump travel — MORE than a real WRC car's entire stroke — and it still pegs 100%. Travel is
  not the constraint. The hydraulic (velocity-dependent, dissipative) bump stop is the remaining
  candidate, and it should be measured on **energy absorbed per impact**, not peak load.
  **Travel reverted to realistic 2026-08-13 (user's call).** `rest_length` / `max_travel`
  500 → **320 mm**, the top of the real gravel-WRC range, keeping B1's spring rates untouched.
  Measured 500 vs 320 on the rally loop at 100 km/h: still 4/4 pegged either way, frames on the
  stops 50 → 177, but **peak Fz 28.8 → 23.1 kN** — less travel gave LOWER peak load, because the
  spring builds force over the whole stroke (12.1 kN of spring force at full compression at
  500 mm vs 7.7 kN at 320 mm). The inflated travel was manufacturing its own load spikes. Body
  clearance 538 → 358 mm against a real gravel car's ~300 mm. Riding the stops often is now the
  EXPECTED state, not a defect — which makes the hydraulic bump stop the last open item.
- [x] B3 — Bump stops — DONE 2026-08-11, **brought forward ahead of B2** because B1 testing
  bottomed (the plan's own §7 risk), so this was the blocking fix. Progressive cubic stop over the
  last `bumpstop_zone` (20%) of travel, sized off the corner's OWN static load (`bumpstop_g`, in g)
  so it scales with the car; `w.bottomed` is set while engaged and is now available to M7 as the
  clean hard-hit puncture trigger the roadmap asked for (still a one-line opt-in, NOT wired).
  B1's interim `_fz_cap` is gone — loads are bounded by the stop instead of a flat clamp.
  Default `bumpstop_g` 3.0 chosen from a sweep on the rally loop at 100 km/h, which showed the stop
  trades peak load against collapsed time very steeply: 0g = 26.5 kN peak / 235 frames pegged,
  3g = 35.7 / 188, 6g = 44.9 / 194, 10g = 57.1 / 160. Past ~3g loads climb far faster than the
  bottoming falls — that is the "crashy" §5 warns against.
  **Open item — travel budget, not stop strength.** Even at 10g all four corners still peg at 100%
  of travel on the rough loop at 100 km/h, because the input exceeds what the travel can absorb:
  B1's softer springs took static sag from 7.7 cm (pre-B1) to 12.7 cm, spending 5 cm of the bump
  travel that used to swallow those hills. The stop makes bottoming progressive, but only ride
  height or ride frequency can give the travel back. Levers, for the user to choose:
  `ride_freq_front/rear` up (less sag, back toward the old stiffness), or `rest_length` +
  `max_travel` 0.45 -> 0.50 (jack the car up, gravel-style, keeping B1's softness — costs ~5 cm of
  CoM height, so ~16% more roll moment).
  **RESOLVED 2026-08-13 (user's call): jacked up.** `rest_length` and `max_travel` are both 0.50.
  The ride frequencies were deliberately NOT touched, because stiffening them would walk back the
  softness B1 exists to provide. Measured after (headless, settled on the rally loop, probe removed):
  no corner bottomed at rest, per-wheel static compression 0.091 / 0.157 / 0.140 / 0.049 m on the
  loop's camber, and the bump stop now engages from 0.40 m instead of 0.36 m — roughly **+4 cm of
  free bump travel per corner, +15% total bump travel**. Spring rates are unchanged (they derive
  from corner mass and ride frequency, not from ride height), so static sag in metres is the same;
  what changed is the room above it. **Two things to carry forward:** the CoM is 5 cm higher, so
  B1's roll couple wants a re-check on the next drive, and this is the travel headroom that C1's
  roughness field and any Arc D crests/jumps will spend — measure against these numbers, do not
  shrink the feature to fit.
  **REVISION REQUIRED, 2026-08-13 — the bump stop is the wrong KIND, not the wrong strength.**
  The user asked whether the stop's range should be "tougher". It should not: the sweep already
  showed that raising `bumpstop_g` spikes peak load hard (0g = 26.5 kN, 3g = 35.7, 6g = 44.9,
  10g = 57.1, and a quadratic ramp at 12g hit **63.3 kN**) while barely reducing bottoming.
  Research says why. Real end-of-travel control is **hydraulic**: a short-stroke pressurised
  damper that is *velocity-sensitive* — faster impact, more resistance — and which **dissipates
  the energy as heat** rather than storing it. The staging is documented as roughly soft first
  third (gas spring), stiffer middle third, with **the majority of the energy absorbed in the
  last third by oil through a piston**; above ~5 m/s impact velocity an elastomer stop cannot
  dissipate fast enough on its own.
  ([Superior Engineering](https://www.superiorengineering.com.au/hydraulic-bump-stops),
  [Crawlpedia hydraulic bump stop guide](https://www.crawlpedia.com/bump_stops.htm),
  [R53 Suspension technologies](https://www.r53suspension.com/technologies))
  **Our stop is a pure displacement spring (`bumpstop_g · x³`), so it stores the impact and gives
  it straight back — it pogos.** That is exactly why stiffening it raised loads without buying
  travel. The fix is a velocity-dependent dissipative term alongside the progressive spring, i.e.
  a hydraulic bump stop, with its own probe on *energy absorbed per impact* rather than peak load.
  **Second finding, which reframes the whole "travel budget":** gravel WRC cars run **250–300 mm
  of total suspension travel**, with softer springs than tarmac and dampers deliberately *soft in
  compression, firm in rebound*
  ([gravel setup overview](https://www.rallynews.autospeedmarket.com/rallynews/how-suspension-setup-affects-performance-on-gravel-stages/),
  [WRCwings on suspension](https://www.wrcwings.tech/2020/05/24/suspension-grip-and-aerodynamics/)).
  This car has `max_travel` 0.45 m with 0.127 m of static sag — **323 mm of bump travel, MORE than
  a real rally car's entire stroke.** So "not enough travel" is probably the wrong diagnosis, and
  raising ride height should NOT be the first move. The likelier causes, in order: (1) the stop
  returns energy instead of absorbing it, (2) **B2 is not implemented yet** — its asymmetric
  bump/rebound split is precisely the "soft compression, firm rebound" real cars use, and it is
  the single most likely fix, (3) the heightmap's input may simply be more severe than a real
  rally road. **Consequence for ordering: do B2 before revisiting the bump stop or the ride
  height, and re-measure the bottoming statistics after it.** Treat the spring-rate figures in
  those sources with caution — one quotes gravel rates as "450–600 N/mm", which is an order of
  magnitude above a plausible wheel rate and is almost certainly a units error.

- [x] B4 — Relaxation length + By + CoM — DONE 2026-08-13 (drive-verified: "feels good")
  (`./check.sh` clean; probe PASS, removed). Relaxation measured at 0.533 m (8 m/s) and 0.500 m
  (30 m/s) to reach 63% of a step — same distance at both speeds, proving it is a distance
  property. Derived `By` peaks land on exactly 9.0 deg (tarmac) and 14.0 deg (gravel). Straight-
  line stability 0.000 rad/s peak yaw at both 1 m/s and 250 km/h. `com_height` is now a slider,
  still at -0.45, for the A/B the plan asks for. `hs_blowoff` baked to 0.45 per the B2 drive.
  **Post-drive follow-up, same day:** the first B4 drive reported "much easier to lose control of
  the slide, harder to hold a good entry". Diagnosed and resolved without changing the B4 defaults
  — see the CHANGELOG. Root cause: the retired `By = 10` put the lateral peak at **114.8 deg**, so
  every drivable slip angle sat on the RISING side and a slide was always self-correcting; B4's
  realistic 9/14 deg peaks flipped that to the falling side. A `cy_gravel` lever was added (post-
  peak curve shape per surface, default = `Cy` = no change) and a latent `_mf_peak_u` bracket bug
  fixed. Re-drive verdict: **"feels good"** on the shipped defaults, with the user noting they may
  tune again later — `peak_alpha_gravel` first, then `cy_gravel`.
- [ ] B5 — Bake, prune, end-to-end — prune + audit DONE 2026-08-13, and **the bake is now settled
  too**: every phase's defaults are the drive-verified values (B1 1.4/1.6 Hz + zeta split, B2
  0.55/0.85 with knee 0.08 and `hs_blowoff` 0.45, B3 320 mm travel + 3 g stop, B4 9/14 deg peaks,
  `sigma_lat` 0.55, `Cy` = `cy_gravel` = 1.4, `com_height` -0.45). **Only the §8 end-to-end
  drive-through still needs the user** — after that Arc B closes. Prune found nothing outstanding: every retired system
  was already removed by the phase that retired it (`_t_drive`, `lsd_lock`, `rear_grip_cut`,
  `brake_force`, `spring_k`/`damper_c`/`arb_*`, interim `zeta`) — only explanatory comments
  remain. Panel audit: 83 rows, 83 HELP entries, no gaps and no orphans. The two M1-only rows are
  kept deliberately (the panel skips rows the loaded car lacks). ROADMAP updated with M15 done and
  a "do not resurrect `_t_drive`" warning on the superseded Tier-3 entry.
- [x] C1 — Surface roughness — implemented 2026-08-15 (`./check.sh` clean; all six headless
  probes PASS, then removed). **AWAITING USER DRIVE VERDICT — checkbox ticked for "built and
  probe-verified", not for feel; see the driving checklist below §9.**
  **C1.0 centreline** (`scripts/centreline.gd`, new): arc-length table + binary-search inversion
  + a spatial grid for `nearest_point`, exposing `point_at(s)` / `nearest_point(x,z)` / `length()`
  / `is_loop()`. Built from `_road(th)`/`_asphalt_r(th)` exactly as `wear.gd`/`pace_notes.gd`
  already sample them — no geometry change, same points through a shared interface. Probe 0a:
  reconstructed position vs the direct polar formula at 2000 positions/circuit, **max deviation
  0.0000 mm** (pass < 1 mm) on both the rally loop and the asphalt ring. Probe 0b: `s` from
  `nearest_point` vs brute force agrees to 0.29 m against a 0.32 m sample spacing (pass), and
  4 wheels x 120 Hz of queries cost **1.05 ms/tick** against the 1.84 ms/tick baseline — real, but
  budgeted.
  **C1.1 roughness field** (`scripts/roughness.gd`, new): ISO 8608 broadband noise as 5 octave-
  spaced `FastNoiseLite` layers whose amplitude follows `Gd(n)=Gd(n0)*(n/n0)^-2`, one coefficient
  per surface (`road_class_gravel` 128, `road_class_tarmac` 4, both x1e-6 m^3 — roughly ISO class
  D vs A/B). Washboard is `washboard_amp * sin(2*PI*s/washboard_lambda)` keyed to the C1.0
  centreline's `s` (not theta), masked by **`wear.gd`'s own corner/braking-zone field** via a new
  `wear.is_tracked(x,z)` — the line that gets worn is the line that gets ribbed, per
  `docs/PLAN-stages-ground-map.md` §6.4, no new mask invented. Tarmac gets expansion joints
  (`joint_spacing`/`joint_amp`) + noise-thresholded patch repairs instead of washboard. Probe 1:
  measured RMS ratio between successive octaves of the ACTUAL noise output (not just the formula)
  averaged **~0.71** across both classes against the ISO-implied 0.5 (generous tolerance because
  each octave is one finite noise sample) - PASS; gravel total RMS 0.00077 m vs tarmac's
  0.00014 m, more than 5x - PASS.
  **C1.2 enveloping filter**: `contact_patch_len` (0.2 m) sampled at 9 points, combined with a
  weighted mean whose weight floor (`ENVELOPE_FLOOR` 0.5) biases toward the patch's own peak
  without reproducing it outright — a plain mean already does the real filtering (a feature much
  narrower than the patch is diluted by the samples that miss it). Probe 2, ridden dead-centre
  (worst case): a 3 cm x 4 cm bump comes through at **31% of its raw amplitude** (pass < 40%),
  a 0.6 m washboard crest comes through at **83%** (pass > 80%) - correctly differentiated.
  **C1.3 injection**: `vehicle_m2.gd`'s suspension raycast offsets `hit_pos` along the wheel's own
  `up` axis by the enveloped sample before computing compression, and `w.contact_point` moves with
  it so dust/marks/terrain-dig/audio inherit it automatically. New export `roughness_gain`
  (default 1.0, Tab row "Roughness gain (M2)") is the phase's A/B — 0 skips the sample entirely.
  Excluded via `stage.deformable_patch_factor()` (a query, not a hardcoded radius, per §6.3) so
  the centre patch's real geometry is never double-counted.
  **C1.4 travel budget, headless autopilot probe (rally loop, curvature-governed speed, NOT a
  clean 100 km/h — see caveat below):** `roughness_gain` 0.0: avg 47.8 km/h, peak Fz **22.8 kN**,
  4/4 corners pegged, 350/5401 frames with a bottomed wheel. `roughness_gain` 1.0 (shipped
  default): avg 41.0 km/h, peak Fz **22.6 kN**, 4/4 corners pegged, 335/5401 frames bottomed. The
  gain-0 run lands within 1% of B3's recorded baseline (23.1 kN, 4/4 pegged) - the injection is
  confirmed inert at 0, which is the load-bearing half of this measurement. The gain-1 run shows
  only a small, second-order change (peak Fz and bottoming both slightly LOWER, not higher), which
  does **not** confirm-or-refute B3's "C1 will make bottoming worse before better" prediction
  either way. **Caveat, honestly: the probe's synthetic autopilot (pure-pursuit steering + a
  curvature-governed speed target) only sustains ~45 km/h average on this track, well under the
  100 km/h B2/B3 measured at** - it is not a racing driver, so the comparison is suggestive, not
  load-bearing. Probe 3 (repeatability): identical field value at the same point, same frame,
  and after a respawn (0.000185 m in all three reads) - PASS, the stage stays learnable.
  **Files:** `scripts/centreline.gd` (new), `scripts/roughness.gd` (new), `scripts/wear.gd`
  (+`is_tracked`), `scripts/stage.gd` (+`is_tarmac_at`, +`deformable_patch_factor`),
  `scripts/vehicle_m2.gd` (+`roughness_gain`, +`roughness_field`, raycast injection),
  `scripts/world.gd` (wires `Roughness` + the rally-loop `Centreline`), `scripts/tuning_panel.gd`
  (+1 row, +1 HELP entry, 86/86).
  **Follow-up same day, first drive report ("feels pretty smooth, only the asphalt kerb edges feel
  like anything"):** the individual amplitudes (`road_class_gravel/tarmac`, `washboard_amp`,
  `joint_amp`, `patch_amp`) were exports on the `Roughness` node, unreachable from the Tab panel
  (it only touches `vehicle` properties) — mirrored onto `vehicle_m2.gd` and synced into
  `roughness_field` once per tick so they're live-tunable for exactly this kind of pass/fail test.
  Panel: 91/91, no dupes.
  **REAL BUG FOUND AND FIXED same day, from a second session's verdict ("out of control on
  grass"):** `wear.is_tracked(x,z)` — the washboard placement mask above — only checked the
  angular sector from the map centre, never lateral distance from the road, so full-amplitude
  washboard was firing on open grass wherever the angle happened to match a tracked corner/braking
  zone, potentially hundreds of metres off the actual corridor. Fixed by delegating to `_cell(x,z)
  >= 0`, which already does the correct two-part test (tracked flag AND lateral corridor bound).
  Verified headless: a tracked-angle point 250 m past the road now reads `is_tracked = false`,
  `washboard = 0.0` (previously full amplitude). See `CHANGELOG.md` 2026-08-15 for the full
  writeup — this is very possibly also the root cause of the "FPS drops on loose surfaces" the
  other parallel session was chasing (erratic, aliased Fz/compression from a term that should
  never have been active off the drivable corridor).
  **DRIVE VERDICT 2026-08-15 — the phase's central A/B FAILED, C1 stays UNTICKED for feel.**
  User: *"i couldnt differentiate when the roughness gain was on and when it was off, washboard was
  only noticeable when driving slow otherwise the suspension smooths it completely"*. (The bottoming
  item PASSES: *"bottoming when going uphill is fixed as far as i saw"*.) Three findings, full
  numbers in `CHANGELOG.md` 2026-08-15 — **amplitude is NOT what is wrong, do not just turn the
  knobs up**: (1) the washboard is at or below the spatial Nyquist limit at speed, because the field
  is sampled once per tick and that interval is a DISTANCE that grows with speed — 8.6 samples per
  wavelength at 30 km/h, 2.59 at 100, and **1.73 (below Nyquist) at 150**, which is exactly the
  reported "only at slow speed"; (2) a 46 Hz input against a 1.4 Hz suspension has ~3%
  transmissibility, so the BODY correctly should not move — a real car sends washboard to the driver
  through the steering, through tyre-load fluctuation, and through structure, and this car has no
  unsprung mass so it has no wheel-hop mode either; (3) **a real model gap — the damper never sees
  the road.** `comp_vel` is body-side only and omits the rate of change of ground height, so
  roughness produces a spring force change (484 N, a 12% wobble) and NO damping response, where a
  road-aware damper would return ~4.98 kN at the same input. Harmless before C1 (smooth ground);
  C1 is what makes it matter. **Open item, deliberately not fixed in C1** — it is a real physics
  change with real harshness risk, and wants its own energy-per-impact probe and drive test, the
  same way B3's hydraulic bump stop does. Fixing (3) is the highest-value next move for C1's feel.
- [x] C2 — Self-aligning torque — implemented 2026-08-15 (`./check.sh` clean; headless probe PASS
  on every item, then removed). **AWAITING USER DRIVE VERDICT.**
  `Mz = Fy * (t_pneumatic + t_mechanical)` per front wheel, summed and divided by `steer_ratio`,
  exposed as `get_steer_torque()` (N·m at the rack) and shown on the HUD as `steer Nm`. Taken from
  the FINAL `Fy` — after the friction ellipse and after A5's gross-sliding correction — so a tyre
  already trimmed by combined slip reports the weaker signal it physically would. `alpha_peak` per
  wheel is recovered by INVERTING `_lat_shape`'s own derivation (`_peak_alpha_rad`), so the collapse
  follows the surface blend automatically and cannot drift from where the grip peak really is.
  **The trail shape was wrong on the first pass and the probe caught it.** §5's suggested linear
  collapse `t_p0 * (1 - |alpha|/alpha_peak)` put the torque peak at **1.1 deg against a 9 deg grip
  peak** — 12% of the way to the limit — because `Fy` saturates 98% by 2.2 deg, so the wheel
  lightened across the whole range and the lightening carried no information about the limit.
  Switched to the **cosine (Pacejka Mz) form** that §5 explicitly permitted as the alternative, and
  which is what the physics says: trail holds near static while the patch ADHERES, then collapses as
  the rear starts sliding. After: peak at 1.6 deg (tarmac) / 2.8 deg (gravel), weight held longer
  early and shed harder late — 4.5→9 deg now sheds **51%** of the torque vs 43% before.
  Probe: Mz peaks before Fy on both surfaces PASS; down to **42%** of its own peak at 2x peak slip
  PASS; sign reverses and is exactly 0.000 N·m on centre PASS.
  **Honest limitation:** the peak is still early in absolute terms, and that is B4's drive-verified
  lateral curve saturating at ~2 deg, not the trail model. B4 was deliberately not touched.
  New Tab rows `trail_pneumatic` / `trail_mechanical` / `steer_ratio` / `sat_gain` (95/95 HELP).
  No rumble wired — `Input.start_joy_vibration()` is rumble, NOT force feedback, per §5.4.
- [ ] C3 — Wheel input path (needs a wheel; pull forward the day one arrives)
- [ ] C4 — FFB output (spike first — may honestly conclude "not feasible", see §7)
