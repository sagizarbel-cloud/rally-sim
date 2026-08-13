# Changelog

Newest first. One entry per working day, grouped by what changed and why it mattered — not a
copy of the commit log. **`docs/ROADMAP.md` remains the authoritative state**; this file is the
history of how it got there, so a future session can answer "when did this change, and why?"
without reading every diff.

**Keep it current:** add an entry when a plan phase closes, when a bug is fixed, or when a
measured finding changes what we believe about the car. Feel verdicts belong here too — they are
the only verification this project has for feel, and they are otherwise lost in chat.

---

## 2026-08-13 (later)

**B1 CLOSED — drive verdict: "feels good".** The derived suspension setup is accepted, and the
verdict covers the 5 cm ride height and the `chassis_mass` slider fix as well, since both landed
before the drive. B2 is now unblocked.

**Tuning panel: A–Z ordering and a live explanation banner.** The B1 drive surfaced that
`roll_gradient_target` was unintelligible — and the cause was structural, not that one label: the
panel was ~76 sliders in one flat list, in source order, with no explanation of any of them
anywhere in the game. Every control now carries a one-line explanation, shown in a fixed banner
under the title on hover (and as the native tooltip), and the list is sorted alphabetically so a
control can be found by name. Each explanation opens with the system it belongs to — ENGINE,
DIFF, SUSPENSION, TYRE — because alphabetical order scatters related knobs and the tag is what
carries the grouping. Coverage is verified: 76 of 76 sliders have help, with no orphaned entries.
*Convention added: a phase that adds a tunable adds its HELP line in the same commit.*

## 2026-08-13

**Drag strip extended to 4 km, with markers and barriers.** `strip_x1` now derives from a new
`strip_len` (4000 m) instead of being hand-set, so the strip re-marks itself if the length
changes. Distance posts every 100 m down both shoulders as a single MultiMesh (taller and orange
on each kilometre), a billboard call-out per kilometre, and a W-beam guard-rail arc round the far
lip of the runoff pad — 46 collision panels, 183 posts, beam top 0.75 m. `_guard_rail(polyline)`
lays panels and posts along any polyline and is reusable for new areas. *Note for top-speed runs:
at 259 km/h you need ~174 m to stop but there are only 91 m from the 4 km mark to the rail, so be
on the brakes by the 3.9 km post — or raise `runoff_r`.*

**B3 travel budget resolved — the car is jacked up 5 cm.** `rest_length` and `max_travel` 0.45 →
0.50, settling the item B3 left open. Ride frequencies deliberately untouched: stiffening them
would walk back the softness B1 exists to provide. Spring rates derive from corner mass and ride
frequency rather than ride height, so static sag in metres is unchanged — what changed is the room
above it. Measured: no corner bottoms at rest, and the bump stop now engages from 0.40 m instead
of 0.36 m, about **+4 cm of free bump travel per corner, +15% total**. Costs ~5 cm of CoM height
and so ~16% more roll moment, so **B1's roll couple wants a re-check on the next drive**.

**Fixed: the car-weight slider desynced the body from its own suspension.** `mass = chassis_mass`
is assigned once in `_ready()`, and the Tab panel's "Car weight" row drove the RigidBody's `mass`
only — so `chassis_mass`, the single authority for corner masses, roll gradient, the tyre load
reference (`_mu_load`) and rolling resistance, stayed at 1250 whatever the slider read. The row now
drives `chassis_mass`, and `_derive_setup` keeps the body's `mass` following it, so a live weight
edit re-rates the whole car. Only reachable by moving the slider to an extreme, which is why a
stress test found it and normal driving never would.

**Stress-test findings (user drove every slider to its goes-faster extreme).** None of these are
defects; they characterise the model's edges. Recorded in full in `docs/ROADMAP.md`.
- **Top speed is a numeric clamp, not a force balance.** 490 km/h is the wheel-spin clamp
  (±400 rad/s × 0.34 m = 489.6 km/h), with the valve-float ceiling (1.35 × redline through 6th)
  landing within half a km/h of it by coincidence. `top_speed_kmh()` knows about neither, so the
  speedo it graduates can under-read by >100 km/h at extreme settings.
- **The ~1 km stop from 490 km/h is correct physics.** Probed and swept: `mu_long` 0.9 → 856 m /
  1.13 g, 1.6 → 589 m / 1.65 g, 2.6 → 433 m / 2.22 g. With `drag_k` slidered down to 0.05 the aero
  term falls from ~13 kN to ~0.7 kN, so nothing but the tyres slows the car. An earlier attribution
  blaming the weight slider was wrong and has been corrected in the roadmap.
- **The car pogos above ~400 km/h, and it is underdamping — not aero.** Coasting with no input,
  suspension load collapses below 15% of static weight on 0% of frames at 299 km/h, 4% at
  468 km/h and 34–45% at 489.6 km/h. With `drag_k` at 0.0 it is unchanged (drag is a central force
  with no vertical component and no downforce model exists); with `zeta` 1.2 it drops to 3%, and
  2.5 to 0%. **This is B2's target and its headless success metric** — do not "fix" it by raising
  `zeta`, which would undo B1's compliance.
- **Nothing has ceiling behaviour.** Engine torque holds flat above redline instead of collapsing;
  tyre temperature reaches 128–299 °C against an 85 °C optimum with no upper bound. The model is
  well-behaved inside its envelope and simply extrapolates outside it.

**Planning.** Arc D (`docs/PLAN-stages-ground-map.md`) planned: the ground map and real
point-to-point stages, built on Arc C1's roughness field. **Settled decision: new maps go in a NEW
area — the existing circuits, centre patch and 4 km strip stay untouched as the calibration bed**,
because every baseline the project has is expressed in their terms. C1's execution prompt written.

## 2026-08-12

- **Fixed the real top-speed limiter:** Godot's default linear damping (COMBINE mode) was capping
  the car around 130 km/h. The 3rd-gear-redline ~140 reading was a separate red herring.
- **Speedo scales to the car's real top speed**, circular see-through dial.
- **A real engine thermal model** plus a cluster restyle; bottom-right outside-view cluster with
  warning telltales for the exterior cameras.
- **Camera:** right-stick look-around, click to glance behind.

## 2026-08-11

- **B1 — derived suspension setup.** `spring_k`/`damper_c`/`arb_*` are gone; springs come from
  ride frequency (1.4/1.6 Hz), dampers from `zeta` 0.65, bars from a target roll gradient and front
  roll couple, re-derived each tick so live edits and drive-mode CoM shifts both re-rate the car.
  First drive exposed the inside driven wheel overheating: the bars were sized only to reach the
  roll-gradient target, so they solved to zero and the springs' own distribution set the balance
  (43.4% front against a 55% setting). `_derive_setup` now enforces the couple first. **Still
  awaiting its drive verdict.**
- **B3 — bump stops, brought forward ahead of B2** because B1 testing bottomed. Progressive cubic
  stop over the last 20% of travel, sized off each corner's own static load; `w.bottomed` is now
  available to M7 as a clean hard-hit puncture trigger (not yet wired).
- **A4 and A5 closed, both drive-verified.** A5's first attempt was rejected as "way too strong"
  and reworked so sliding tyres take their force direction from the slip velocity.
- Cabin work: analog tacho and speedo dials, restyle, binnacle clipping fixed.
- Plan: Arc C added (surface roughness, self-aligning torque, wheel input, FFB), then C1 inserted
  ahead of the FFB phases.

## 2026-08-09 – 2026-08-10

- **A3 differentials drive-verified**; diff presets `[1]/[2]/[3]` marked a permanent keeper.
- **A4 shift model + launch and stability assists**, including a money-shift guard; stability
  assist later fixed for cutting power through ordinary corners.
- **DualShock 4 support** in an Assetto-Corsa-style rally layout — analog pedals live.
- Plan: the reusable headless input-probe harness pattern recorded in §0.

## 2026-08-04 and earlier

Initial repository snapshot: **M0–M10 complete plus the drivetrain arc through Phase A3.** That
covers the procedural stage (three concentric circuits, drag strip, deformable centre patch), the
combined-slip Pacejka tyre model with load sensitivity, the two-inertia engine and clutch driveline,
selectable differentials, tyre temperature/wear/punctures, the damage model, pace notes over OS TTS,
time-trial ghosts with sector splits, surface wear, and the live tuning panel. See the milestone
history in `docs/ROADMAP.md` for the detail behind each.
