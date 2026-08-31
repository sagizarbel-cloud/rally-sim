# Changelog

Newest first. One entry per working day, grouped by what changed and why it mattered — not a
copy of the commit log. **`docs/ROADMAP.md` remains the authoritative state**; this file is the
history of how it got there, so a future session can answer "when did this change, and why?"
without reading every diff.

**Keep it current:** add an entry when a plan phase closes, when a bug is fixed, or when a
measured finding changes what we believe about the car. Feel verdicts belong here too — they are
the only verification this project has for feel, and they are otherwise lost in chat.

**Write entries to be SEARCHED, because that is what this file is for.** Its main job is
forensic: when something breaks, or an old bug comes back, this is where you grep for hints
before touching code. So every entry must name the **symptom in the words you would use while
driving** — "inside rear wheel cooking on gentle turns", "car pogos above 400 km/h", "top speed
capped around 130", "launches on grass feel like ice" — not only the mechanism or the name of the
fix. A symptom you cannot search for is a symptom you will diagnose twice. Record the measured
numbers alongside it (before/after, per-wheel loads, distances), since a recurrence is usually
recognised by the numbers drifting back rather than by the symptom returning in full.

---

## 2026-08-31 — D5: the two worlds are joined by a tunnel. And four green probes were hiding a car being flung into open air

**PHASE D5 BUILT AND PROBE-VERIFIED — AWAITING DRIVE VERDICT.** `scripts/area_manager.gd` owns which
area the car is in and the tunnel that joins them. Drive into a portal beside the asphalt ring, drive
out of a portal on SHAKEDOWN's start line.

**TWO DESIGN FORKS, BOTH DECIDED BY THE USER, and both worth not re-litigating:**

1. **The calibration bed is NEVER unloaded.** A cold rebuild of it measures **494 ms — 468 ms of
   that in `_build()` alone**, i.e. 95% in the terrain mesh loop, so making it resumable would have
   meant restructuring the build path every baseline in this project rests on. Holding it costs
   ~20 MB. It is now built once and never torn down, which makes §1.1's "the calibration map stays
   untouched" **structural** rather than something a probe must re-prove after every transition.
   The generated stage needs no unload either: D4's streamer already drops its chunks to zero when
   the car is elsewhere (measured: 0 resident after a round trip).
2. **The connector is a TUNNEL used as a PORTAL, not a road.** Measured first: the stage's start
   line is **4149 m** from the calibration map (its finish end 2122 m), because StageGen lays its
   spine from one corner of a 4 km box and the start IS that corner. A continuous road link would
   be as long as the stage itself, and the stage cannot simply be moved closer — its elevation is
   sampled at ABSOLUTE world coordinates, so relocating the area changes the road. A tunnel dissolves
   that: **its two mouths do not have to be geometrically adjacent.**

**THE BUG THAT MATTERS, AND IT PASSED EVERY PROBE.** The swap took its 180 degree yaw about the
tunnel MOUTH. Both tubes are entered from their mouths, so a car crossing 55 m *inside* tube A
mapped to 55 m **OUTSIDE** tube B — the tunnel was flinging the car into open air beyond the far
portal, and it only looked like it worked because the car landed and drove on. All four probes
reported PASS throughout, because none of them could see WHERE the car was: probe 3 only asserted
that *some* ground existed beneath it, and open terrain satisfies that perfectly.

What caught it was refusing a number that made no physical sense — a car resting a **constant**
3.12 m above the floor it should have been on. Two plausible explanations were tested and refuted
first (terrain poking up through the floor; the approach ramp launching the car), and only the third
attempt stopped guessing and printed the car's actual local coordinates: `z = +55` where it should
have read `-55`. The yaw is now taken about the TRANSITION PLANE. Ray gap **3.12 m -> 0.63 m**,
which is a car's ride height on the tunnel floor.

**GREEN PROBES MEAN "NOTHING I THOUGHT TO ASSERT HAS BROKEN", NOT "IT WORKS."** That is the entry
to grep. In this phase THREE defects were cancelling each other into four passes: the swap threw the
car outside the far tube, which happened to satisfy the manager's re-arm rule, which was the only
reason the probe could complete more than one trip — so fixing the swap *broke* the probe, twice.

**Two more real geometry bugs, both found by driving the probe rather than reading the code:**
- **The tube was buried in the hillside.** The first version put the mouth at local terrain height
  and let the tube burrow in, so the car was wedged between the tunnel floor and the terrain
  collider and stopped dead. Neither terrain may be carved to fix it — the calibration bed is
  untouchable and the stage is the road the user has just verified — so the tube is raised to clear
  the highest ground anywhere UNDER it (sampled across its width, not just down its centre line)
  and an approach ramp lifts the road to the mouth.
- **The approach ramp was a staircase.** Twelve stacked boxes; the car hit them at 22 m/s, launched,
  crossed the transition plane ballistic and slammed into walls — and the damage model, quite
  correctly, read the landings as crashes and pegged damage at **1.0**. It is now one rotated slab
  at 12%, the same max grade the stage generator builds roads to.

**Probe results, all four passing over 10 round trips:**
- **1. Calibration bed bit-identical:** lattice `3dea9c62879b62c6…` before and after. Identical.
- **2. Memory across transitions:** **+0 nodes, +0 colliders**, 0 stage chunks resident once the
  streamer settles. (Counting before it settles reads streaming residue as a leak — it is not.)
- **3. Ground present at every emergence:** 0 of 10 emerged over nothing; worst gap 0.641 m.
- **4. State survives the swap:** **0 of 10** swaps altered damage, tyre wear or temperature.
  DECIDED: state is PRESERVED — a tunnel is a road, not a service park. It still drifts while
  DRIVING, which is the tyre model working.

**One small extension to the ground map:** a layer may now name its own surface via `surface_at()`.
That is how the tunnel reads as ASPHALT without grip, audio, dust and roughness each having to learn
what a tunnel is — and it is the same hook D6 wants for mixed surfaces.

---

## 2026-08-30 (D4 drive verdict) — "felt good", and the stair-stepped edges are back. Half of them were never geometry at all

**DRIVE VERDICT on the streamed 4.9 km stage: "i test drove the stage and it felt good".** Three
things reported, all acted on:

**1. "stair stepped edges ... they still occur"**, with the steer that raising resolution may be a
performance problem and *"it will need a creative solution"*. Photographed from directly overhead
before touching anything, and the picture splits the problem in two:

- **HALF OF IT WAS NEVER GEOMETRY — it was the COLOUR.** The grass/road boundary was a per-VERTEX
  colour, so the rasteriser interpolated an already-thresholded value across each triangle and put
  the road edge on the TRIANGULATION. That is a sawtooth whose period is the mesh, and no amount of
  height-field accuracy affects it. Fixed for free: `sample_at` now also returns the **edge distance
  field** (metres outside the carriageway edge, negative on the road), the chunk mesh carries it in
  UV, and a small shader thresholds it PER PIXEL. `d` is near-linear across a quad, so the edge comes
  out as a smooth curve at *the same vertex count*. Confirmed by photograph: the sawtooth is gone.
- **The rest is genuinely geometric, and it is the BERM.** `berm_width` is 1.6 m and the lattice is
  1.41 m, so the berm's Gaussian ridge is about ONE vertex across - it cannot help but scallop, and
  its shadow is the serration still visible along the outside of a corner. This is the part that a
  resolution increase would fix and the part the user was right to flag as expensive: a 2x-denser
  corridor chunk is 4x the vertices, and vertices are 96% of chunk cost. **Not fixed here, and named
  rather than quietly left:** the principled answer is a road-aligned ribbon mesh for the
  carriageway and its shoulders, where the cross-section is resolved ACROSS the road (12-16
  vertices) instead of by a square lattice that happens to pass through it. That is a real piece of
  work and it belongs with D6/D7, which already touch the corridor.

**2. "maybe a lesser LOD for the continuation should be considered so the user wont see the stage
popping in."** View distance was 361 m, derived from a draw-call budget spent on a DISC. It is now a
**driving horizon**: `v_max * 12 s`, i.e. roughly the next twelve seconds of road at the speed the
car can actually reach.

**3. "there is a lot of dead space that is loaded to the sides."** Correct, and it was most of the
budget: beyond the driveable shell the streamer was filling a full disc, beyond which the road only
occupies a thin strip. The far field is now **corridor-only**, marked once at chunk resolution by
walking the centreline, and the freed draw calls are spent on making that band as WIDE as the budget
allows rather than on ground nobody looks at.

**The first attempt at 3 looked worse than the problem, which is why it was photographed twice.**
Reusing the existing corridor mask gave a ~106 m ribbon - the mask is sized for collision queries,
not for looking at - so the world ended in a hard jagged edge a few metres from the road. The band
width is now derived: whatever the draw-call budget has left after the full-detail disc, spread
across the length of road in view.

**Also fixed while photographing: seam exactness had silently regressed to 0.000488 m** (it had been
exactly 0). `1/2048` is the tell - a float32 ulp. When the area grew to 4 km the cell size stopped
being exactly representable (720/512 = 1.40625 is, 4000/2844 is not), and the mesh built vertices as
`origin + i*step` while the sampler used the integer lattice index: `a*c + b*c` and `(a+b)*c` are
not the same float. Vertices now come from the integer index, one multiply, so neighbours derive a
shared edge from an identical expression. **Back to 0.000000000 m over 2673 shared vertices**, with
order independence still bit-identical over 48 chunks.

**A probe harness lesson, recorded because it wasted a round.** The first screenshots came out as
three identical pictures of the car with the HUD over them (world.gd re-points its own camera every
physics frame, so setting `current` once does nothing), and the next set photographed the procedural
sky's ground hemisphere and nearly got read as "the terrain is rendering dark" - because the camera
was 2.2 km from the CAR, and the streamer builds around the car, so there was simply nothing there.
Take the world's processing down, hide the CanvasLayers, re-assert `current` on the captured frame,
and **put the car where the camera is**.

---

## 2026-08-30 (later still) — ONE `nearest_point` call cost 478 ms. Driving away from a road made the whole game 60x slower, and it was never D4's fault

**Symptom in driving words: on the generated stage the game ran at about two frames a second,
while the legacy circuits were fine.** Measured: **482 ms per physics tick** against the 8.33 ms a
120 Hz tick allows and the 1.84 ms baseline. Found while probing D4 and fixed there, but **this bug
predates D4** — it is in `Centreline`, which D2/C1.0 own, and any code path that asks a centreline
about a point far away from it hits it.

**Four hypotheses were measured and REFUTED before the real one was found.** Recording them because
each looked obviously right, and the wrong one nearly got "fixed":

| suspected | test | result |
|---|---|---|
| the chunk streamer | disabled `update()`, hid every chunk mesh | 497 → 487 ms (2%) |
| some script's per-frame work | bisected the node tree, processing off one by one | ~0% |
| many shapes on one `StaticBody3D` | detached all 23 chunk colliders | 483 ms (0%) |
| … scaling with shape count | re-attached 1, then 12 | 483 → 486 ms (0%) |

**The actual cause: `Centreline._nearest_sample()`'s ring walk is O(max_ring³).** It iterated the
whole `(2r+1)²` square at every ring and `continue`d past the interior, instead of walking only the
ring's perimeter. On-road queries return at ring 0, so this never showed. But the ring cap is
DERIVED from the road's extent over its cell size — 202 rings for the rally loop — so a query from
far away walks about **11 million `Vector2i` + dictionary probes**: profiled at **478 ms for a
single call**, i.e. **99.7% of the entire physics tick**.

The caller was `time_trial.gd` asking the ACTIVE circuit where the car is, while the car sat on
SHAKEDOWN 2.6 km away. In normal play `[B]` sets the active circuit to the one you are on, which is
why nobody has felt this yet — but `wear`, `roughness`, the ground map and D5's connecting tunnel
all query centrelines they may be far from, so it was a landmine, not a curiosity.

**Two fixes, both derived rather than tuned:**
1. **Walk the perimeter, not the square.** A stride does the skipping: on the two edge columns every
   `dz` is scanned, between them only `dz = ±r`. Same cells, and the same ORDER (dx outer, dz
   ascending), so the winner among any exact tie is unchanged — which matters because C1's washboard
   phase is keyed off *which sample* comes back, not merely a nearby position.
2. **Far queries skip straight to brute force.** Reaching distance d costs ~`4(d/cell)²` cell probes
   while brute force costs `_n`, so brute force wins beyond `d = cell·sqrt(_n/4)` — that crossover
   is the threshold, not a picked number.

**Proved equivalent, not assumed.** Against brute-force truth over the centre line, road edge,
shoulder, well off-road and far-away positions: **0 mismatches in 3220 tests on every one of the
four centrelines** (DIRT CIRCLE, RALLY LOOP, ASPHALT RING, SHAKEDOWN), worst arc-length difference
0.0000 m. This is the same standard the 2026-08-28 rewrite was held to, and for the same reason: the
old fixed 3x3 was wrong at 9.85% of road-edge positions and scrambled the washboard.

**Cost of one far query: 478 ms → 0.289 ms on the rally loop — 1650x.** SHAKEDOWN's is 1.229 ms
(it has 4765 samples, so its brute-force fallback is proportionally bigger).

**A probe was the reason this stayed hidden, and that is the lesson worth keeping.** The driven
probe reported a "worst physics frame" of 1.05 ms while the process was managing 2.7 ticks per
second, because it timed only its OWN `_physics_process` — the cost sat entirely outside the
measurement window. A probe that measures the thing it can see rather than the thing you care about
will confirm whatever you already believe. It now reads
`Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)`, the engine's own number.

---

## 2026-08-30 (later) — D4: the stage is streamed, and it is 4.9 km. The plan's "the collider cook is the spike" was wrong by two orders of magnitude

**PHASE D4 BUILT AND PROBE-VERIFIED — AWAITING DRIVE VERDICT.** SHAKEDOWN's ground is no longer one
513x513 mesh and one collider over a 720 m box; it is chunks on a global lattice, streamed around
the car with detail and colliders that follow it. That is what lifts the stage from D3's static
~900 m to **4779 m timed / 4905 m of road** in a 4 km box, inside the arc's 4–6 km target.

**THE PLAN'S CENTRAL ASSUMPTION IS WRONG, AND IT WAS MEASURED BEFORE ANY CODE WAS WRITTEN.**
§3.4 and the D4 prompt both say collider cooking is the frame-time spike to design around, and that
cook-ahead distance is therefore the whole game. Measured cost of building one chunk on the
corridor:

| chunk | `sample_at` | mesh | **cook** |
|---|---|---|---|
| 32 cells (45.0 m span, 1089 verts) | 15.45 ms | 0.60 ms | **0.11 ms** |
| 64 cells (90.0 m span, 4225 verts) | 64.27 ms | 2.28 ms | **0.35 ms** |

**The cook is 0.5% of the cost. 96% of it is `sample_at`, at 11.4 us per corridor vertex**, because
every vertex pays `Centreline.nearest_point()` — the provably-correct expanding ring search that
2026-08-28 installed after the old fixed 3x3 was found wrong at 9.85% of road-edge positions. That
search was deliberately NOT traded for a cheap local one: this stage has a hairpin, a hairpin folds
the road back on itself *inside a single chunk*, and that is exactly where a local search locks onto
the wrong branch. So the spike is not avoided by cooking early — **it is avoided by never doing a
chunk's work in one frame.** A build is a resumable job with a hard per-tick time budget, so the
worst frame is bounded by construction rather than by hoping a cook lands between wheels.

**Everything else is derived from that measurement**, not picked: lead distance from the measured
cost of a vertex, the budget and the car's own top speed; hysteresis from the chunk span; the view
radius from the triangle and draw-call cost of the static area it replaces (which is why it lands
at ~406 m — more ground than the legacy map shows in any direction). The one dial is
**Stage streaming budget** (Tab, default 1.00 ms/tick).

**Probe 3, seam continuity — the phase's central probe — PASSES EXACTLY, not within tolerance.**
75 adjacent full-detail chunk pairs, 2475 shared vertices: **worst position step 0.000000000 m,
worst normal discontinuity 0.000000000 deg.** Two things make that structural rather than lucky.
The lattice is GLOBAL, so neighbours compute a shared edge from the identical integer expression;
and every chunk samples a one-vertex APRON outside itself, so normals use a true central difference
at the border instead of a one-sided one. Without the apron every seam reads as a crease under a
low sun — the "a stencil breaks at a spacing discontinuity" trap that got D3 three times, in its
D4 costume.

**Probe 4, order independence — PASSES.** 45 chunks dropped and rebuilt in the reverse order:
**0 differing vertices**, bit-identical.

**Probe 2, memory ceiling — PASSES, and it is FLAT.** Driving the full 4906 m: resident chunks sit
at **256–264 across the entire middle of the stage** (peak 283, peak colliders 38), falling only
near the area edge where the disc is clipped. Bounded, not growing with distance travelled — which
is the property that is invisible over 900 m and fatal over 5 km.

**Probe 5, bottoming over the full streamed stage — no worse than the rally loop.** 4/4 corners
pegged, 598 frames on the stops over 4906 m = **0.122 frames/m** against B3's rally-loop baseline of
177 over ~1290 m = **0.143 frames/m**; peak Fz **24.1 kN** against 23.1 kN. And the car never fell
through the world: worst sink **-0.366 m** (negative = always above the height field), so the
streamer stayed ahead of it for the whole stage.

**Probe 1, frame-time spikes — DOES NOT MEET ITS STATED PASS CONDITION, and the reason is not
chunking.** Worst physics frame **23.73 ms** against the 8.333 ms a 120 Hz tick allows, with
**359 of 33,109 frames (1.1%) over budget**. But the streamer's own contribution is bounded and
small: **worst chunk finalise 2.20 ms**, and the worst frame happened with **no chunk build in
flight**. The control settles it — the same autopilot on the LEGACY RALLY LOOP, which is one mesh,
one collider and no streaming at all:

| | worst physics frame | frames over 8.333 ms |
|---|---|---|
| streamed stage (D4) | 23.73 ms | 359 / 33109 (1.1%) |
| legacy rally loop (control) | **62.10 ms** | **721 / 36001 (2.0%)** |

**The calibration bed spikes harder than the streamed stage** — 2.6x the worst frame and twice the
proportion over budget. Spikes of this size are therefore a pre-existing property of the car and the
physics step, not something D4 introduced. Caveat recorded honestly: the control autopilot drove
worse (off-road 10.8% of frames vs 3.3%, bottoming 1.24 frames/m vs 0.122), so its 62 ms is not a
clean like-for-like; the clean attribution is the 2.20 ms finalise measured on the stage itself.
**Whether any of this is FELT is the drive verdict's job, not a probe's.**

**Unloading is budgeted too, as of this phase.** Building was time-sliced but freeing was not, so one
tick could `queue_free` a dozen ArrayMeshes and HeightMapShape3Ds and pay for all of them at
end-of-frame. Chunks leave the disc at about v/span per second (~0.4/s at 18 m/s), so the cap is two
per TICK — 240/s, two orders of magnitude more headroom than the rate needs, while still bounding
the spike.

**§8 risk 6 asserted at the new length, and it HOLDS — better than at 1 km.** The prompt calls this
"the assumption the whole arc rests on". `nearest_point` on the 4.9 km centreline:
centre line **0.0177 ms/tick** for 4 wheels (D3 at ~1 km: 0.018), road edge **0.0308** (was 0.046),
shoulder **0.0299** (was 0.071), against the 1.84 ms budget. Cost did not grow with stage length.

**Three defects found by measuring rather than by reasoning, all fixed:**
1. **The streamer followed the car around the LEGACY map.** With no area clipping it built 293
   chunks of SHAKEDOWN's landform 3 km from the stage, on top of the circuits §1.1 says stay
   untouched. Chunks now exist only inside the generated area, as D3's single slab did.
2. **LOD thrash: 702 chunk builds in the first 155 m** of the stage against ~245 resident — most of
   the streaming budget went on rebuilding ground that was already there at a different detail.
   Fixed with one-sided hysteresis on the LOD bands (a chunk resists being coarsened but is refined
   immediately), and by re-deriving the radii only when the measured cost actually moves rather than
   every 16 builds, which was itself pushing chunks back across band edges.
3. **A collider was cooked for every full-detail chunk** — 79 heightfields in the physics world when
   ~30 can ever be touched. Colliders now exist only within `r_solid`, attached and dropped from
   kept heights without rebuilding the chunk.

**Deviations from §5 worth not re-litigating.** Chunks are indexed on a global XZ lattice and
streamed by distance from the CAR, not "along `s`" as §5 says. Along-`s` chunking cannot answer what
happens when the driver leaves the road, and an `s`-aligned ribbon cannot be a `HeightMapShape3D`
(which is an axis-aligned grid) without falling back to a trimesh. The lattice version makes seam
continuity and order independence structural rather than tested-for, which is worth more than
matching the plan's wording. §8 risk 7 (erosion) remains NOT implemented and still baked-per-seed if
it ever is, exactly as D3 left it.

**Also fixed in passing:** `height_at` and `_road_blend` were two functions each paying their own
11.4 us `nearest_point` for the same vertex; they are now one `sample_at` returning both, by value
rather than through a Dictionary (D1 measured a Dictionary on a per-vertex path at 0.487 ms/tick
against 0.153 for the same work returned by value). And `StageDef.area_cells` is now DERIVED from
`cell_size_m`, so growing the area adds cells instead of enlarging them — D3's stair-stepped road
edges came from cells that were too big, and only a screenshot could see it.

---

## 2026-08-30 — D3 DRIVE-VERIFIED. The finish was called 80 m late, the co-driver went silent on 30% of the rally loop, and "same seed = same stage" was not true

**D3 IS ACCEPTED.** Drive verdict: *"road is drivable and feels like a road"*, *"corners do have
rhythm but we might improve it in the future"*, *"pace notes describe correctly and there is
finish"*, *"the hairpin is tight — can be tighter in future seeds, meaning this should not be the
limit"*. Two defects reported, and chasing the second one uncovered three more.

Noted for a later phase, NOT defects: corner rhythm is accepted but wants improving, and the
hairpin is not to be treated as the tightness limit — a future seed may go tighter. (The lever
named in D3 is a design speed that VARIES along the stage.)

**"Finish pace notes referring to the end of the road instead of the finish line."** The FINISH
call sat at `arc[count - 1]` — the far end of the 80 m RUNOFF, not the finish gate. So the
co-driver called the finish **80.6 m after you had already crossed it**, while the clock and the
finish banner used the real gate. `pace_notes._build_route` now takes the gate
(`StageGen.timed_end_s`, the same arc length `time_trial` stops the clock on) and places the call
there: measured error **80.6 m → 0.00 m**.

**The co-driver went SILENT over 30% of the RALLY LOOP and the ASPHALT RING** — a regression D3
introduced on the legacy map without touching it. `_rn`/`_rloop` are written per route while
building routes, so they held whichever route was built LAST: the open SHAKEDOWN stage, 1007
samples against a circuit's 1440. `_idx` then CLAMPED every index past 1007, so `_heading_at`
returned a heading between two unrelated points, `fwd` fell under the 0.25 gate, and no note was
called. Measured: **434 of 1440 samples (30.1%) wrong on BOTH legacy circuits, worst error 180°,
all 434 silencing**. Topology now travels with the route dict (`loop`, `n`) and `_process` adopts
the active route's. After: **0 wrong on all three routes.** Symptom to grep for if it returns:
*co-driver stops calling corners on part of a circuit that used to work*.

**"Seed change works but keeps the ghost from last seed."** Three separate faults under one root
cause, all found chasing this:

1. **`Vector4` is a 32-bit float carrier, and the stage parameters travelled in one.** The seed is
   a ~2e7 integer, where float32 spacing is **2**, so every ODD seed was silently rounded to an
   even neighbour: **half of all seeds were unreachable, and seed N vs N+1 gave the SAME road.**
   Worse, `sinuosity 0.85` round-trips through float32 as `0.850000023841858`, so a rebuild with
   *untouched sliders* produced a **different centreline from the startup road**. Parameters now
   travel as an `Array` (GDScript int and float are 64-bit). Measured after: same seed reproduces
   its road exactly, a different seed gives a different one (seed 20260829 now yields 1011 samples
   / 1025.95 m vs 20260828's 1007 / 1026.54 m — before the fix the two were byte-identical).
   **This was a live violation of §0's hard repeatability requirement for Arc D**, and it would
   have propagated straight into D4's chunk generation.
2. **The stage silently rebuilt itself ~0.55 s into every session.** `_last_params` started at
   `Vector4.ZERO`, so the first `_process` always read a "change" and armed the debounce — throwing
   away the road `_ready()` had just built and (per 1) replacing it with a subtly different one.
   The first tick now records the parameters without arming. Measured: idle 180 frames →
   **1 regeneration → 0**, road unchanged; a real slider edit still gives exactly 1.
3. **The seed slider could not express the seed the stage starts on.** Range was `1..99999`
   against a default seed of `20260828`, so the slider clamped its own display to 99999: once you
   moved it you could never get back to the stage you had been driving, and **Reset could not
   restore it either**, because Reset writes the captured default *through* the slider. Range is
   now `1..99999999`. The panel's promise — *"change it back to get the first one again exactly"* —
   is true for the first time.

**And the ghost itself:** a best lap and its ghost belong to the ROAD they were driven on, not to
the `[B]` slot. Bests are now filed under `Centreline.fingerprint()` (a hash of the road's own
samples, not of the parameter list — the parameter list grows, and a fingerprint that missed a new
one would hand back a ghost for a different road). Changing seed **puts your ghost away**; coming
back to that seed **takes it out again**. Nothing is cleared and nothing is misattributed, and a
run in progress when the road changes is reset because it can no longer be scored. Verified: plant
a best → change seed → best 0.0 → change back → **best and all three sector times restored, road
fingerprint identical**. The legacy circuits' bests are never touched.

---

## 2026-08-29 (later — a real hairpin that widens for runoff, calmer berms, later notes, 50/50 diff; and the compile gate was silently passing)

Drive feedback: *"hairpin- the turn is too big- it should be smaller tighter radius and the road
should get a little wider at the turn to allow a bit of runoff to the side- so the design speed of
60/30km/h can be dropped and we will give another criteria instead"*, *"berms are too aggressive"*,
*"notes might go a little to early sometimes"*, *"its only a 2 turn and should be less then 1 or
close to 1"*, and *"i would like the diff default value to be 50/50- less oversteer"*.
**AWAITING DRIVE VERDICT.**

### THE COMPILE GATE WAS SILENTLY PASSING — read this first

`Godot.app` moved from `~/Downloads` to `/Applications`. `check.sh` had that path hard-coded, and
when it could not find the binary it printed a note to stderr and **`exit 0`**. So the gate reported
success while verifying nothing, and every `./check.sh && <next step>` chain sailed straight through.
This was caught by luck - the "skipping" line happened to be the one `tail -1` showed.

**A gate that passes when it cannot run is worse than no gate at all.** Now: `check.sh` searches the
known install locations, and a missing binary is a **hard failure (exit 1)** with the fix printed.
Environments that genuinely cannot run Godot (remote sessions on claude.ai/code) set `GODOT_SKIP=1`
and get the old behaviour explicitly, with `NOTHING WAS VERIFIED` in the message. Verified all three
paths: found = 0, missing = 1, missing + `GODOT_SKIP` = 0. `CLAUDE.md`'s documented command updated
to the new path. **Note the related trap, also now in `CLAUDE.md`: `check.sh` only verifies scripts
the running game actually LOADS**, so a new file nothing instantiates yet can be badly broken and
still pass - check it directly with `--check-only --script`.

### The hairpin: its own design speed, and widening from off-tracking

The user's instinct was right and the fix is a real road-design criterion, not a fudge. **A mountain
road signed for 30 km/h still posts 15-20 on its hairpins** - one tight turn does not set the
standard for the whole road. Using the single global design speed for everything produced a 34.5 m
hairpin, which `pace_notes.gd` correctly read as a mere **"2"**. Giving the hairpin its own design
speed of **20 km/h puts it at 13.7 m**, and the note it earns is now **0 - which in this severity
scale IS "hairpin"** (`<12 m = 0`, `<22 m = 1`, `<35 m = 2`).

| | before | after |
|---|---|---|
| hairpin radius built / delivered | 34.5 / 30.3 m | **13.7 / 13.1 m** |
| pace note it earns | 2 | **0 (hairpin)** |
| road width at the hairpin | 7.76 m | **9.93 m (+2.43)** |

**The widening is derived, not decorative.** A long vehicle's rear wheels cut inside its front ones
through a bend, so its swept path is wider than the vehicle: **W = L²/(2R)**. Roads are built wider
on tight curves for exactly that reason, and that is precisely the runoff room a hairpin wants. The
design vehicle is a **rigid truck at 8 m**, not the rally car - mountain roads are built for whatever
has to get up them. That gives **+2.43 m at the hairpin** and **+0.89 m through the ordinary 36 m
weave**, so the whole road now breathes through its corners.

**A bug this exposed:** the first attempt widened correctly and the hairpin still came out at 7.76 m,
because the road's pinch/open `width_var` profile happened to bottom out exactly there and cancelled
it. **A road narrows on straights and open bends; it does not narrow at a hairpin.** The pinch is now
suppressed in proportion to local curvature, so the two profiles no longer fight.

Guarantees all still hold with the much tighter arc: **away from the hairpin, worst radius 30.4 m
against the road's own 30.8 m limit with zero violations, zero self-intersections**, and the vertical
input actually improved to **0.40 g peak at 108 km/h against the rally loop's 1.10 g**.

### The other three

- **Berms halved.** `berm_height` 0.55 -> **0.28 m**, `berm_corner_gain` 1.4 -> 0.7. They read as too
  aggressive; the shape and the physical reasoning are unchanged, only the amount.
- **Notes called later.** `lead_base` 30 -> 24 m and `lead_time` 1.7 -> 1.35 s. At 80 km/h that was
  calling **67 m ahead**; it is now ~51 m, about **2.3 s of warning**.
- **Centre diff 50/50.** `torque_split` 0.6 -> **0.50**. This is a drive-verified A3 value being
  changed deliberately on the user's call for less oversteer, not a default nobody had looked at -
  noted so a future session does not "restore" it.

---

## 2026-08-29 (SHAKEDOWN drive feedback: a hairpin, berms and ruts, 10.7 corners/km, a FINISH call — and the jagged edges were mesh resolution)

Drive report on D3: pace notes good but *"dont describe finish"*; road drivable but *"i would like it
to be more complex, have a wider berms and ruts on the sides (1-2meters) and include a hairpin"*;
*"a bit of noise where the surrounding ground connects to the track- like jagged edges"*; and — the
one that closes probe 4 — ***"the car doesnt bottom out"***. All addressed. **AWAITING RE-DRIVE.**

**Probe 4's deferred half is now answered by the driver: the car does not bottom out on SHAKEDOWN.**
That was the measurement the synthetic autopilot could not produce honestly, and it agrees with the
vertical-input figures (peak 0.65-1.06 g against the rally loop's 1.10 g).

### The jagged edges were MESH RESOLUTION, and no height-field measurement could have found it

Three things were measured before anything was changed. Two were real and one was a red herring:

1. **Banking noise (real).** `nearest_point()` returns `_curvature[best_i]` - a raw per-sample
   numerical second difference - and the bank multiplied it by the FULL lateral distance, out to the
   far edge of the shoulder. Measured: curvature swinging **0.0226 1/m over 2 m** of road, 70% of the
   entire design range, giving neighbouring terrain vertices wildly different bank. Fixed by a
   curvature smoothed over the **superelevation runoff length** (the distance covered in ~2 s at
   design speed, derived not picked) and by clamping the lever arm to the carriageway, since
   superelevation is a property of the road, not of the field next to it.
2. **Mesh resolution (the actual cause).** The road is 7.5 m wide on a **2.25 m grid** - about three
   vertices across - so its edges stair-step no matter how smooth the height function underneath is.
   **No measurement in this session could see it**, because every probe samples the height FUNCTION
   and the artefact is in the MESH. A screenshot found it in one look, and `area_cells` 320 -> 512
   (1.41 m/cell, 2.6x the vertices) removed it. Photographed before and after.
3. **Transverse "roughness" (red herring).** The first metric compared height steps ACROSS the road,
   which conflated intentional shape with noise - adding berms made the number worse while the road
   got better. Jaggedness is the edge wobbling ALONG its length; measuring that instead separated
   the two.

### Berms and ruts

Traffic pushes material out of corners, so it piles just past the road edge and wears grooves along
the used width. Both are lateral-profile terms in `height_at()`: a **0.55 m berm peaking 1.1 m past
the edge over a 1.6 m falloff**, with **40% more berm on the OUTSIDE of a corner** (the side that
gets pushed), and **0.11 m ruts 1.2 m wide**. Ruts sit a fixed distance from the CENTRELINE, not from
the edge - pinning them to a varying road width made them snake in and out.

### The hairpin needed the spine to bend

**A graph over a straight spine can never turn more than 90 degrees**, so the previous router could
not produce a hairpin at any sinuosity - the guarantee that made it self-intersection-proof also made
it hairpin-proof. The spine now runs out to an apex and doubles back, filleted at **1.12x the minimum
radius**, and the offset tapers to zero through the fillet - which is both what a real hairpin looks
like (a clean constant-radius turn, not a wiggly one) and what keeps the graph property safe where
spine curvature is highest. **Delivered: a 154-degree continuous turn, worst radius 30.3 m against
the 30.8 m limit, zero over-limit samples, zero self-intersections.**

Three defects surfaced getting there, all found by probes:
- **The taper was itself a corner.** Ramping the offset from zero to amplitude A over length L peaks
  at ~6A/L^2 of curvature; a picked 60 m ramp produced **12.2 m corners against a 30.8 m limit**, and
  the relaxation could not fix them because the taper recreated them on every refit. Taper length is
  now derived as sqrt(6A/kmax), and smoothstep rather than linear (a linear ramp has a kink at each
  end).
- **The relaxation was flattening the hairpin.** Smoothing a vertex toward its neighbours' midpoint
  flattens an arc, and running that on a legally-constructed hairpin walked a 130-degree turn down to
  96 without converging. The arc is now exempt from relaxation AND from the violation count - counting
  it made the non-convergence warning permanent, since relaxation was not allowed to act on it.
- **A constant tied to a retired assumption.** `_fit_spline` used a fixed 18 samples per control
  segment, a number that only made sense for the 22 m spacing the first router happened to use.
  Halving the spine step to 2 m silently made the spline 9x denser and generation went from seconds
  to minutes. Sample density now follows segment length.

### Length and character were fighting each other

Solving the spine for a fraction of the target and bisecting AMPLITUDE for the rest chased its own
tail: after tapering around the hairpin and both ends the wiggle adds almost nothing to length, so
the stage came out **~10% short no matter what the target was**. They are separate knobs now:
**`sinuosity` sets the weave amplitude** as a fraction of what the curvature limit allows - and since
that bound is A <= kmax*L^2/(4*PI^2), the weave's curvature works out at exactly `sinuosity * kmax`,
so the parameter means "what fraction of the tightest legal corner does this road habitually turn
at" - while **the apex position is bisected so the FINISHED road hits `length_m`**. Timed length is
now **900 m against a 900 m target**, exactly, with no shortfall warning.

### The road is 3.7x busier, and the notes now end properly

Two things were holding the corner count down, both measured:
- sinuosity 0.55 means 56 m corners, which read as a long road with nothing on it. **0.85 gives 36 m
  corners.**
- the end taper was a half-sine across the WHOLE road, which held the weave below the
  corner-detection threshold for the entire first and last third: **every corner on a 1 km stage fell
  between 397 m and 718 m**. Its only job is to put the start and finish on the spine, so it is now a
  fixed distance at each end.

Road book before and after, same seed:

    before:  3 corners over 1026 m   2.9/km   1 left / 2 right   2 severity bands
    after:  11 corners over 1026 m  10.7/km   5 left / 6 right   3 severity bands, gap 45 m

**And the co-driver calls the FINISH.** A closed circuit has nothing to call - you just come round
again - but on a point-to-point stage knowing the finish is coming is the difference between
committing and lifting. It is a call, not a corner (no direction, no severity), so it renders without
an arrow.

---

## 2026-08-28 (SHAKEDOWN gets a run-up and a runoff; the car was spawning backwards; and the runoff was hanging off the edge of the world)

Two drive reports: *"i want the car to have a little track to start and a small runoff to finish"*
and *"the car currently spawns backwards - looking towards the end of the map"*. Both fixed, and
chasing the first one turned up a third bug neither of us had seen.

**1. The car spawned facing exactly backwards.** `spawn_transform()` built its basis with
`atan2(h.x, h.y)`. A Y-rotation by theta puts forward at `(-sin, 0, -cos)`, so matching a heading
`(h.x, h.y)` needs `atan2(-h.x, -h.y)` - the version shipped pointed the car 180 degrees the wrong
way, every time. Now built with `looking_at()`, the way `stage.get_spawn_for()` has always done it:
Godot's forward is -Z and `looking_at` already knows that, so it cannot get the sign wrong.
Verified numerically rather than by eye - `forward · road_heading = +1.0000`.

**2. A stage does not begin at its start line.** There is now **45 m of run-up** before the START
gate and **80 m of runoff** past the FINISH gate. Both are real road (`on_road` true along their
whole length, gravel to the ground map); neither is TIMED. The car spawns at the very beginning of
the run-up, so you launch, cross the line, and the clock starts on the line - the same arrangement
the legacy circuits have always had via `start_runup`. Timing triggers moved onto the gates
(start 45.4 m, splits 325.2 / 605.1, finish 885.0), and the gate posts mark the timed window rather
than the ends of the road.

**3. The runoff was hanging 21.9 m off the edge of the terrain** - you would have driven off the
world while braking. The spine started at a fixed 86% of the box half-width, which left no room for
extensions that stick out past both of its ends. The inset is now DERIVED from what has to fit: the
spine runs the box diagonal, so an extension of length E costs E/sqrt(2) in each axis, and the
margin also has to clear half a road width plus its shoulder blend, because a centreline that merely
fits still leaves the road surface overhanging. **Closest approach to the edge: -21.9 m (outside)
-> +22.6 m (inside).**

**One more trap, found by measuring instead of assuming.** The first version of the extensions used
a fixed 4 m point spacing against the road's own ~1.6 m samples. That 2.4x spacing jump at each join
wrecked the vertical profile, because the vertical-curve smoother - like every stencil of its kind -
assumes uniform spacing and cannot settle across a discontinuity:

| | peak d2y/ds2 | at 108 km/h |
|---|---|---|
| rally loop (calibration bed) | 0.01195 | 1.10 g |
| extensions at a fixed 4 m step | 0.05118 | **4.70 g** |
| extensions at the road's own spacing | 0.00707 | **0.65 g** |

**4.7 g of wheel acceleration from nothing but two joins.** This is the same class of bug as the
spline's phantom endpoints and the grade smoother's uniform-spacing assumption - the third time in
this phase that a non-uniform sample spacing has quietly broken a stencil. The start area and runoff
pad are also held FLAT now, the way real built platforms are, which keeps terrain roughness out of
the two joins entirely.

**Net effect on the stage:** 965 m of road (45 run-up + 840 timed + 80 runoff), and the vertical
input is now **gentler than the rally loop on both measures** - rms 0.00203 vs 0.00290, peak 0.65 g
vs 1.10 g. Geometry constraints still hold exactly: worst radius 31.0 m against the 30.8 m limit,
zero over-limit samples, zero self-intersections.

**`length_m` now means what it says.** Clearing the run-up, runoff and corridor width from the area
edge shortens the usable spine, and at the old 1200 m target the generator silently shipped 20%
short. The default is now an achievable 870 m, **and the generator warns when the constraint set
beats the target** instead of quietly missing it - length is a soft goal, while minimum radius,
maximum grade and the area's own edges are hard, and it should be visible when they win.

---

## 2026-08-28 (fixed: the SHAKEDOWN terrain was see-through from above and solid from below — backwards winding, again)

Drive report: *"the map normals are upside down - the same mistake that often happens because of
godot. the map is see through from above and looks normal from below."* Correct diagnosis, and it
was **triangle winding, not normals**.

`stage_area.gd` wound its grid quads `a,c,b` / `b,c,d`; the working `stage.gd` winds them
`a,b,c` / `b,d,c` with the comment *"wound so the top is the front face"*. Both of my triangles
were reversed, so backface culling removed the terrain when viewed from above and kept it when
viewed from below. **The normals were already right** - `Vector3(hl-hr, 2*cs, hd-hu)` is
character-for-character what `stage.gd` computes - which is exactly why this bug is misleading: it
presents as a lighting or normals problem and is neither.

**This is the second time this project has hit it** (see `docs/ROADMAP.md` M5: *"mesh winding was
backwards -> half invisible/upside-down"*), so it is now in `CLAUDE.md`'s gotcha list with the
correct index order written out, rather than left to be re-derived.

**Verified by photograph, not by assertion** - the project's own lesson about screenshotting before
reasoning about shader maths:

| camera | terrain pixels | sky pixels |
|---|---|---|
| above the stage | **99.1%** | 0.9% |
| below the stage | 3.5% | **96.5%** |

Exactly inverted from the reported symptom. The legacy map photographed from the same height for
comparison reads 94.2% terrain, and its colours match SHAKEDOWN's closely - so the pale, washed-out
look from directly overhead is the noon sun, not a second bug in the new area.

**Also checked while in there, because a screenshot cannot see it:** the collider agrees with the
visual mesh to **8 mm over 20 points along the road, with no ray misses**, so the car drives on
exactly what it is shown. A mis-scaled `HeightMapShape3D` would drop the car through the floor and
look perfectly fine in a picture.

---

## 2026-08-28 (D3 — SHAKEDOWN: the first road in this project that nobody drew, and three road-design constraints that had to be discovered the hard way)

Arc D generates a stage. `StageDef` describes one as PARAMETERS (seed, length, sinuosity, elevation
character, design speed, width profile, authored control points); `StageGen` solves geometry from
them; `StageArea` builds it as its own area well clear of the legacy map (§1.1 - the calibration bed
stays untouched). It appears as **SHAKEDOWN**, the fourth `[B]` entry, and it is a point-to-point
ROUTE, not a circuit. **AWAITING DRIVE VERDICT.**

**What D1 and D2 bought, made concrete.** The generated stage grips, sounds, throws dust, lays wear
and gets pace notes **without one line changing** in `stage.gd`, `sound.gd`, `effects.gd`,
`roughness.gd` or `wear.gd`. The ground map took it as one extra LAYER; pace notes took it as one
more `Centreline`. Two refactor phases that changed nothing you could feel are why this phase is
additive rather than invasive - and SHAKEDOWN is also the first thing to actually exercise D2's
open-road timing in the game rather than in a probe.

**Probe 1, determinism - PASS.** Same seed, bit-identical centreline; different seed, different
road. Same stage twice is the same stage (§1.3).

**Probe 2, geometric sanity - PASS on every seed**, but only after three real defects, each found by
the probe and each a lesson worth keeping:

1. **A 60 km/h design speed was geometrically impossible and the generator could not say so.**
   R = V^2/(127(e+f)) puts the minimum radius at 123 m, and one 180-degree turn then costs 387 m of
   road - so 1200 m of road inside a 720 m box would spend two thirds of the stage on two U-turns.
   The relaxation ran its full pass budget every time and shipped a road with 12 m corners against
   its own 123 m limit. **A tighter design speed buys BOTH length and corner count**: at 30 km/h
   (R = 30.8 m, a normal narrow forest road) the same box holds 1200 m with ~7 corners. Raising the
   design speed makes a stage STRAIGHTER and SHORTER, never faster.
2. **A free heading walk tied knots.** With no sense of progress the route doubled back and crossed
   itself, and easing a corner open cannot untie a knot. Rebuilt as a bounded lateral offset along a
   straight SPINE between start and finish: parameterised monotonically, that is a GRAPH over the
   spine and **cannot self-intersect at all** - the property is structural, not tested-for. A stage
   is a route from A to B, and building it that way is what makes it one.
3. **The relaxation was relaxing the wrong thing.** It smoothed the DENSE spline samples (1.2 m
   apart) while its own comment claimed it relaxed the control polygon; moving a 1.2 m point barely
   changes curvature measured across its neighbours, so it took hundreds of passes to achieve
   nothing. Relaxing the 22 m polygon and refitting converges in 7-14 passes.

Final geometry, three seeds: length 1099-1168 m against a 1200 m target, **worst radius 30.9-31.5 m
against the 30.8 m limit with zero over-limit samples**, zero self-intersections, worst heading step
3.4 deg, and authored control points hit to **0.000 m**. Length is a target and the constraint set
is hard - where they conflict, the constraints win and the road comes out slightly short.

**Probe 3, the pace-note grammar test (§3.6's "real acceptance test") - PASS.** `pace_notes.gd`
reads the generated road as a road book:

    12 m RIGHT 2 | 88 m LEFT 3 long | 252 m RIGHT 2 long | 437 m LEFT 3 long
    622 m RIGHT 2 long | 777 m LEFT 2 long crest | 877 m RIGHT 2 long crest | 999 m LEFT 3 long crest

8 corners over 1129 m (7.1/km, against the rally loop's 9 over 1290 m), **4 left / 4 right**, mean
gap 57 m, two severity bands. **Honest limitation:** severity clusters, because the relaxation drives
every corner to the constraint boundary so they all read alike. A character envelope (slow sections
of open sweepers alternating with tight technical sections) took it from 7x sev2 + 2x sev3 to
5x + 3x, which is better but not a road book's full 1-6 range. **The lever for a future phase is a
design speed that VARIES along the stage** - which is what real roads have.

**Probe 4, vertical budget (§8.2) - and this one nearly shipped a stage that would have destroyed
the car.** Measured as the INPUT rather than the response: the vertical acceleration a wheel sees is
`a = v^2 * d2y/ds^2`, so comparing `d2y/ds^2` between two roads compares their severity at equal
speed with no driver in the loop.

| | rally loop (B3 bed) | SHAKEDOWN, grade limit only | SHAKEDOWN shipped |
|---|---|---|---|
| max grade | 20.68% | 12.00% | 10.13% |
| d2y/ds2 rms | 0.00290 | 0.01017 (**3.5x**) | 0.00182 (0.63x) |
| d2y/ds2 max | 0.01195 | 0.11034 (**9.2x**) | 0.01224 (1.02x) |
| peak wheel accel @108 km/h | 1.10 g | **10.12 g** | 1.12 g |

**The middle column is the trap: a road that was GENTLER than the rally loop by every slope measure
and nine times worse by the measure that matters.** Limiting the grade clamps the slope, and a clamp
leaves a CORNER where it stops biting - a kink is a curvature spike. Real roads join their grades
with parabolic vertical curves sized so vertical acceleration stays comfortable at the design speed
(AASHTO, ~0.3 m/s^2), and adding that constraint brought the peak input to **1.02x the rally loop**.
Two constraints, and the vertical one only looks redundant until you measure the second derivative.

**Also worth recording, because it cost real time:** three different algorithms were tried for grade
limiting before the right one. Laplacian smoothing is a diffusion process (relaxing a run of k
samples costs O(k^2) passes - 256 passes left 24.6% against a 12% limit); splitting each violating
segment's excess between its endpoints is a valid convex projection but Gauss-Seidel-slow (1024
passes left 18.7%). The standard slope-limited forward/backward sweep is **exact in four sweeps**:
min-clamping gives the highest feasible profile (pure cut), max-clamping the lowest (pure fill), and
since the feasible set is convex their average is feasible too - and averaging balances cut against
fill instead of only digging. Earthworks come out at 3.0-3.8 m of cut and fill, which is what makes
the road read as built rather than painted on.

**Two smaller bugs the probes caught:** `Centreline`'s spline had degenerate first and last segments
(centripetal Catmull-Rom needs phantom endpoints; clamping them collapses the knot spacing), leaving
a single 22 m gap in an otherwise 1.2 m polyline - which then broke the grade limiter, since it
smooths against neighbours and cannot cope with a 20x spacing jump. And building the area asked
`nearest_point()` about all 103k terrain vertices, most of them hundreds of metres from the road
where the now-provably-correct ring search expands ~38 rings before it can stop; a coarse corridor
occupancy mask takes the build from minutes back to instant.

**Cost.** The extra ground-map layer is free on the legacy map - **2.38 us/call, unchanged**, because
a box test rejects every query before any centreline work. Inside the generated area it is
5.16 us/call = **0.272 ms/tick at D1's measured 52.8 calls/tick, 15% of the 1.84 ms budget.**

**Deferred, and said plainly:** §5 asks probe 4 for peak Fz and bottomed-frame count from a driven
lap. The synthetic autopilot written for it could not drive either road representatively - the RALLY
LOOP reference run spent **1103 of 2400 frames off the road**, and on SHAKEDOWN it managed 19 m in
20 s - so rather than publish a number produced by a bad driver, that half goes to the drive test.
C1.4 recorded the same limitation about its own autopilot.

**Not built, by design:** the heightmap-import seam is DESIGNED per §5 (`StageDef.elevation_source`;
every elevation read in the generator goes through `elevation_at()`, so swapping in a DEM is a
one-place change) but there is no importer. Hydraulic erosion (§3.3) stays a named seam too - it is
a global iterative process and §3.3's own resolution is to bake it per seed into area data, which
belongs with D5.

Stage parameters are live on the Tab panel (**Stage seed / sinuosity / elevation / design speed**);
editing one rebuilds the stage about half a second after you stop dragging, and re-points timing and
pace notes at the new road.

---

## 2026-08-28 (drive verdict on both fixes: ACCEPTED — and a new one found: "tyre audio only plays when I pull the handbrake")

**USER DRIVE VERDICT: "all read correctly".** The tyre-audio surface fix and the
`Centreline.nearest_point()` fix are both ACCEPTED. Notably the washboard item passed — with its
phase correct off the centreline for the first time, the corrugation reads properly through corners.

**NEW SYMPTOM, reported in the same drive and NOT fixed:** *"the audio seems to almost exclusively
play when pressing space (handbrake)"*. Diagnosed by reading the code; the mechanism is unambiguous
and it is a real gap, not a tuning issue.

**`sound.gd`'s tyre voice is gated on LONGITUDINAL slip only, and the gate is high.**
`vehicle_m2.gd:1800` defines `w.slip` as the **absolute longitudinal slip ratio**,
`|(omega*R - v_long) / max(|v_long|, slip_ref_speed)|` clamped to 0..3 — a pure drive/brake
quantity. `sound.gd` then takes `tv = clamp((slip - 0.25) / 1.4, 0, 1)` and uses it for both
audible layers:

    roll_level   = (0.3 * roll + 0.7 * tv) * (1 - 0.7 * asph)
    squeal_level = tv * asph

So:

| condition | longitudinal slip | tv | tyre voice |
|---|---|---|---|
| ordinary driving / cornering | ~0.02 - 0.10 | **0.00** | silent (only the 0.3 speed term) |
| **handbrake, rear wheels locked** | **1.00** | **0.54** | loud |
| full wheelspin | up to 3.00 | 1.00 (from 1.65) | loud |

**A locked or spinning wheel is essentially the only way to cross the 0.25 threshold**, which is
exactly the reported symptom. **The deeper problem: `w.slip_angle` — lateral slip — does not appear
in the expression at all.** A rally car sliding sideways through a gravel corner is precisely when
a tyre should be shouting, and it is silent, because sliding sideways barely changes the
longitudinal slip RATIO.

**`sound.gd` is now the odd one out among the three systems that read tyre slip**, which is what
makes the fix direction obvious rather than a matter of taste:
- `wear.gd:915` uses `|w.slip| + |w.slip_angle|` — both components.
- `effects.gd` (M11) uses **contact-patch slip VELOCITY** and tyre temperature.
- `sound.gd` uses longitudinal slip ratio alone, with a 0.25 deadband.

**Fix direction when this gets its own phase:** drive the tyre voice from the same contact-patch
slip velocity `effects.gd` already computes (`slip_speed(w, v)`), so what you HEAR, what you SEE
(dust, smoke, marks) and what WEARS all agree on when a tyre is sliding — the same
one-authority argument D1 made for surface, applied to slip. A velocity in m/s also scales
naturally with speed, where a ratio does not. Wants a drive test and an A/B, so it is not being
smuggled in beside D3.

---

## 2026-08-28 (later — the gravel loop stops sounding like tarmac, and nearest_point was quietly wrong 10% of the time)

Two fixes the D1/D2 probes had put on the record but deliberately left alone. **AWAITING DRIVE VERDICT.**

### 1. "Sliding on the rally loop plays a tarmac squeal, and the gravel rumble is too quiet"

`sound.gd` decided surface with `asph = (grip - 1.0) / 0.25`. That expression is exact only while
`dirt_grip` is 1.0 — and it has been **1.1** for a long time, so every gravel point read **0.400**.
The rally loop was mixed as 40% tarmac. Now it asks D1's ground map for the surface class, which
removes the LAST of the four independent surface decisions D1 catalogued.

Measured per surface (old asph -> new asph, and what it does to the mix):

| surface | grip | old | new | rolling rumble | asphalt squeal layer |
|---|---|---|---|---|---|
| grass | 0.80 | 0.000 | 0.000 | unchanged | none, unchanged |
| **dirt (rally loop)** | 1.10 | **0.400** | **0.000** | **x1.389 (39% louder)** | **0.4 -> 0, gone** |
| **patch (dirt circle)** | 1.10 | **0.400** | **0.000** | **x1.389** | **0.4 -> 0, gone** |
| asphalt (ring) | 1.52 | 1.000 | 1.000 | unchanged | unchanged |
| asphalt (drag strip) | 1.52 | 1.000 | 1.000 | unchanged | unchanged |

So only the two dirt surfaces move; grass and tarmac are untouched. A/B toggle
`tyre_audio_surface` (Tab, default ON) reverts to the old threshold. **If the corrected gravel
rumble is now too loud, `tyre_gain` is the handle** — the level was always meant to be this, it was
just being cut 28% by a surface test that thought it was on tarmac.

### 2. `Centreline.nearest_point()` was returning the WRONG sample off the centreline

Chasing D2's "two centrelines disagree on `s`" warning found something worse than an
inconsistency: the query was **incorrect on a single centreline**. It scanned a fixed 3x3 block of
grid cells, which only guarantees a hit within ONE cell (~2.58 m on the rally loop) — while the car
drives 4 m off the centreline through corners and the roughness field queries out to the 7 m
shoulder. Past that radius it silently returned a farther sample. Checked against brute-force
truth on C1's rally-loop centreline:

| query distance off centreline | wrong before | worst error before | after |
|---|---|---|---|
| on the line (0 m) | 0.00% | 0.000 m | 0.00%, 0.000 m |
| mid-lane (2 m) | 0.00% | 0.003 m | 0.00%, 0.003 m |
| **road edge (4 m)** | **9.85%** | **3.72 m = 6.21 washboard ridges** | **0.00%, 0.007 m** |
| **shoulder (7 m)** | **7.30%** | **3.28 m = 5.47 ridges** | **0.00%, 0.009 m** |

**Why this matters for feel:** washboard phase is `sin(2*PI*s/0.6 m)`, and washboard is MASKED to
corners and braking zones — precisely where a car is off-centre. So the ripple train was being
scrambled exactly where it lives, jumping several ridges as the car moved laterally. That is a
plausible contributor to C1's long-running *"I can't feel the washboard"* reports, which survived
three revisions of amplitude and filtering work: **the term was there, but its phase was
incoherent across the road.**

The search now expands ring by ring until the answer is **provable** — once the best candidate is
nearer than the distance to the edge of the already-scanned square, nothing unscanned can beat it.
The ring cap is DERIVED from the grid extent, not picked, per the `_mf_peak_u` lesson. Cost, 4
wheels/tick against the 1.84 ms budget: **0.018 ms on the line, 0.046 at the road edge, 0.071 at
the shoulder** — it costs more only where it previously cheated.

**This closes D2's D3/D4 warning at the root.** The two rally-loop centrelines (4000 vs 4320
samples) now agree: **max \|ds\| 4.35 m -> 0.025 m (7.24 ridges -> 0.04), and 2.57% of positions
over half a ridge -> 0.000%.** Varying centreline density is no longer a trap, though C1's
centreline is still not unified with D2's since there is no longer any reason to.

**Verified not to move anything else:** D2's timing probe re-run against its saved baseline is
byte-identical, so lap, sector and split times are untouched. The only other caller is C1's
washboard, which is the intended correction. No A/B toggle for this one — the old path was
measurably wrong, and `washboard_amp` / `roughness_gain` already isolate the affected term.

---

## 2026-08-28 (D2 drive verdict: laps, splits, notes, ghost and the wear line all unchanged — Arc D can now build a road)

**USER DRIVE VERDICT: "all four hold" — D2 ACCEPTED.** Lap timing, sector splits and the
purple/red best-sector flash behave as before on all three circuits; pace notes call the same
corners at the same moments on both routes; the ghost still records and replays; and the wear line
still forms in the same places.

Two refactor phases in a row have now landed with the driver noticing nothing, which is the
intended result both times. **What Arc D actually has after this:** `time_trial.gd`,
`pace_notes.gd` and `wear.gd` no longer know that a road is `r = f(theta)` about the origin, and
`Centreline` handles open topology — so D3 can generate a point-to-point stage without any of them
changing. The probe that mattered was #4 (a synthetic open road: start once, splits in order,
finish TERMINATES the run), because nothing in the shipped game can exercise that path yet.

**Carried forward, unchanged and still open:**
- The centreline `s`-divergence warning for D3/D4 (>0.30 m at 2.57% of positions, worst 4.35 m =
  7.2 washboard wavelengths). C1's roughness centreline is still deliberately NOT unified with
  D2's. **Do not vary centreline density with streaming/LOD without re-driving C1's washboard**,
  or the corrugation moves where the driver learned it.
- `wear._cell()` still maps position to cell by polar radial offset. The general path belongs with
  the first non-polar road, i.e. D3/D7.
- D1's two pre-existing bugs (`sound.gd` hears the rally loop as 40% asphalt; the centre patch has
  two shapes) remain open by design.

---

## 2026-08-28 (D2 — laps, notes and wear come off theta and onto arc length; a latent centreline trap measured)

`time_trial.gd`'s `atan2` crossings and `RMIN`/`RMAX` radius bands are gone, replaced by
**arc-length triggers on a per-circuit `Centreline`**: "did `nearest_point().s` cross this
trigger, travelling forward, since the last tick?" `pace_notes.gd` and `wear.gd` now take their
geometry from the same shared centrelines instead of sampling `theta` themselves. None of the three
knows the road is polar any more, which is the entire point — D3 swaps the road out and they do not
change. **AWAITING DRIVE VERDICT.**

**Probe 1, timing equality — PASS, and stronger than asked.** §5 wanted lap/sector/split times to
match "within one physics tick"; a synthetic kinematic path around all three circuits produced a
**byte-identical event trace** (start, both splits, lap, on every circuit, every lap). The trick
that makes it exact: **split positions are the arc lengths at the OLD theta-thirds, not equal
thirds of the total.** Arc length is not uniform in theta on a winding road, so equal-s splits
would have silently moved every sector boundary — the kind of change nobody notices until a
personal best stops comparing.

**Probes 2 + 3, pace-note and wear-field equality — PASS, bit-identical.** All 15 corners on both
routes (index span, arc position, direction, severity, modifiers) and the whole wear field
(245/1080 tracked samples, plus `_cell(x, z)` over a 1381-hit lattice) are unchanged. The wear
field IS C1's washboard mask, so this also proves the ribbed line did not move.

**Probe 4, open-road behaviour — PASS. This is the one that shows D2 bought something**, since
every road in the game today is a loop and nothing else can exercise it. On a synthetic 1000 m open
centreline: start fires once on entry, splits fire in order at 333/667 m, the finish fires at
1000 m and **the run TERMINATES instead of wrapping** — verified by driving 200 m past the end with
no second run beginning. `Centreline` gained an open topology (`from_points`, and every wrap-around
in build / `point_at` / `nearest_point` is now conditional on `is_loop()`).

**Real bug found by probe 1, worth remembering:** the split triggers fired *never*, because the
port advanced `_prev_s` BEFORE the split check, so `_crossed()` always saw zero travel. The old
detector could sit after its `_prev_theta` update because it read the current angle directly rather
than a crossing. **Porting a level-test to an edge-test moves where in the tick it has to live.**

**MEASURED WARNING for D3/D4 — two centrelines over the same road do NOT agree on `s`.** §6.2 calls
a divergence here "the single most likely way Arc D silently breaks Arc C", so it was measured
rather than assumed. C1's roughness centreline (4000 samples) vs D2's (4320) on the rally loop:

| | value |
|---|---|
| total length | 1290.067717 vs 1290.067853 m — **agree to 0.14 mm** |
| mean \|ds\| over 9000 positions | 0.0295 m (5% of a washboard wavelength) |
| positions off by > 0.30 m (half a ridge) | **2.57%** |
| worst case | **4.35 m = 7.2 ridges**, at (-100.3, -47.7) |

The divergence is **bimodal, not a drift** — nearly all positions agree to millimetres, and a small
minority jump by metres, because `nearest_point` resolves those to a *different segment* depending
on sample density. So the reassuring total length is a trap: it says nothing about local phase.
**C1 is untouched — the roughness centreline was deliberately NOT unified with D2's** — and it must
not be unified without re-driving C1's washboard checklist. **The sharper warning is for D4:** if
streaming or LOD ever varies centreline density, washboard ridges move under the driver at ~2.6% of
the road, and the symptom would be *"the corrugation isn't where I learned it"* with nothing in the
logs.

**Also:** `active_info()` now reports topology and the HUD says **"lap" on a circuit, "run" on a
point-to-point stage** (§5's wording item). Sector splits still derive from the legacy theta-thirds
on the old map; a generated stage gets equal arc-length splits. `wear._cell()` deliberately keeps
its polar radial-offset mapping — the general path belongs with the first non-polar road, and
changing it now would move both the wear line and the washboard for no gain (plan §1.1: the
existing map is the preserved calibration bed).

---

## 2026-08-27 (D1 drive verdict: nothing moved — the ground map is in, and Arc D's foundation is verified)

**USER DRIVE VERDICT: "goood all four hold" — D1 ACCEPTED.** All four checklist items pass on the
shipped build: all three circuits feel identical, skid marks still appear only on asphalt, tyre
audio still changes on the same lines, the wear line still darkens and still adds grip on the rally
loop, and dust plumes / gravel particles / asphalt smoke all still trigger on the same surfaces.

This is the verdict a refactor phase wants and it is worth stating plainly: **the driver could not
tell the ground map was there, which is exactly the pass condition.** D1's golden-equality probe
already proved byte-identical classification over 6608 points (SHA-256 `80bffdd150893337…`); the
drive confirms the same thing through the only instrument that can judge feel. Grip, surface
effects, audio switching and the M6 wear line are now all downstream of one authority
(`scripts/ground_map.gd`) instead of four independent surface decisions, at a measured cost of
0.153 ms/tick against the 1.84 ms baseline.

**Still open, and deliberately so** — both surfaced by D1's probe 2 and left unfixed because a feel
change must not hide inside a refactor (full detail in the 2026-08-24 entry below):
- `sound.gd` hears the rally loop as **40% asphalt** (1504/1504 gravel points), because its
  `(grip-1.0)/0.25` split is only exact at `dirt_grip = 1.0` and the value is now 1.1. Symptom to
  listen for: **an asphalt squeal underneath a gravel slide, and gravel rumble 28% too quiet.**
- The centre patch has **two shapes** — euclidean for grip, chebyshev for the roughness exclusion —
  disagreeing on 392/6608 points, so roughness is damped in the square's corners for no reason the
  grip model knows about.
Each wants its own phase with a drive test. Neither blocks D2.

**Arc D's foundation is now verified**, which is what D2 (timing, notes and wear re-parameterised
onto arc length) builds on.

---

## 2026-08-27 (B5 §8 driven — Arc B CLOSES; and the C2 steering spike diagnosed, fixed, and two theories killed)

### B5 §8 end-to-end drive-through — Arc B is done

User drove the whole checklist. **Items 1, 2, 5, 6, 7 pass outright** (cold-start ritual and
restart, launch assist, money-shift guard, asphalt ring, `[P]` puncture, damage, ghost, sector
splits, pace notes, wear line, every toggle). **Item 3 passes with notes; item 4 FAILS.** Arc B
closes on that, but the drive-through earned its keep — it turned up four separate things:

- **NOT a regression — the 259 km/h baseline was stale. Measured and closed the same day** (see
  the dedicated entry below): the car does **237 km/h** at stock torque with roughness ON or OFF,
  and 267 at max torque. The user's 236 and 267 both reproduce exactly.
- **FAIL, item 4 — "i dont think it changed, hard to tell" on the diff presets.** This is a
  REGRESSION: A3 was drive-verified on this exact test (2026-08-05, "feels good") and the presets
  were kept deliberately as a permanent A/B tool. Something since then masks axle-locking
  character. Grep `[1]/[2]/[3]` and `apply_diff_preset` when picking this up.
- **Handling notes, explicitly DEFERRED by the user to a future session — a note, not a bug
  report:** AWD **"seems too slippery - too easy to get into oversteer AND understeer"**; RWD
  **"constantly oversteers"**; the car **"feels too light, too easy to lose control for a 4wd"**.
  Lap times are close to the pre-plan ghost, so pace is intact — this is controllability, not speed.
  Worth checking against the 1 kN-scale one-tick Fz steps documented below, which would make grip
  genuinely unpredictable.
- **Stage request (M6 / Arc D):** widen the band of full-traction surface beyond the track edge so
  running a little wide does not instantly throw the car off; would also help the tight hairpins.

### The 259 km/h top-speed "regression" was a stale baseline, not a regression

The user spotted it: *"with max torque and other settings on default it hit 267 km/h when I tested
it now — but 236 km/h with default torque."* Measured on the drag strip, terminal velocity in 6th,
starting already rolling so it converges inside the strip:

| peak_torque | roughness_gain | terminal speed in 6th |
|---|---|---|
| 500 (stock) | 0.0 | **237.4 km/h** |
| 500 (stock) | 1.0 | **237.5 km/h** |
| 1500 (max) | 0.0 | 267.5 km/h |
| 1500 (max) | 1.0 | 267.5 km/h |

**Both of the user's readings reproduce exactly, and roughness costs 0.1 km/h — i.e. nothing.**
C1, the 4.5x broadband recalibration and D1's classification are all exonerated in one run; none of
the three suspects listed earlier in this entry survives.

**Where 259 came from: it is a Phase 0 number (2026-08-02) that was never re-baselined.** It first
appears in the initial repository snapshot and got carried forward through every later checklist as
"the baseline". Two days after it was taken, **A2 raised motoring friction to competition-spec
25/90 N·m** (2026-08-04) to fix "engine braking too weak in 3rd" — a deliberate, drive-verified
change ("engine braking good now, feels comfortable"). Motoring friction subtracts directly from
drive force at high rpm, and at ~6200 rpm in 6th it now eats ~80 N·m of the ~455 available, so the
drag-limited top speed necessarily fell. Everything after it (M7 tyre model, B1 suspension, the
load-sensitive grip work) pushes the same way.

**Note the gearing ceiling for orientation: 275.2 km/h** (0.86 x 3.9 through a 0.34 m wheel at
7200 rpm). Stock torque is drag-limited well below it; max torque gets within 8 km/h of it, which
is why tripling torque buys only 30 km/h. The car's own `top_speed_kmh()` solver — which graduates
the speedometers — lands on the measured figure, so the dial has been right all along; only the
documentation was stale. **Every doc reference re-baselined to 237 km/h** (drivetrain plan Phase 0
and §8, `PROMPT-arc-d-stages.md`, ROADMAP).

### C2 — the steering spike was NOT what either theory said

**Drive verdict: gravel vs tarmac clearly differ (PASS)** — the 16 deg / 9 deg peak slip angles
read as intended. **The wash-out cue is UNCONFIRMED**, which is the phase's whole point, so **C2 is
not done.** And a real artefact: *"steering jumps to ~15 in each direction for a split second when
turning, or when going straight into a turn doing nothing, before correcting to an opposite lower
value, 3-10 usually."*

**Two plausible theories were both WRONG, and a probe killed them — do not re-chase these:**
1. *"`_apply_arb()` bails when either wheel of a pair lifts, snapping the Fz split"* (the lead
   recorded but not pursued in the 2026-08-25 entry below). Measured: **contact gain/loss coincides
   with only 0.2% of large jumps.** Also note `_apply_arb`'s existing `clampf(t, -a.Fz, b.Fz)`
   already drives the transfer smoothly to zero as a wheel unloads, so the early return is
   redundant rather than harmful.
2. *"an airborne front wheel silently drops out of the `_sat_moment` sum"* — same 0.2%, same
   verdict.

**What it actually is: vertical load stepping by kN in a single tick while the tyre never leaves
the ground.** Measured over 4802 ticks of the rally loop: the raw rack torque jumps >3 N.m on
**22.9% of ticks**, and **99.9% of those coincide with an Fz step over 1 kN**. The worst single
event, with both front wheels marked `GND` throughout:

```
torque +0.00 -> -29.70 N.m in one tick
w0 GND Fz 6991 (d +6991)  util 0.94  aRel +1.78 deg  slip +2.30 deg
w1 GND Fz 7441 (d +7441)  util 0.95  aRel +1.69 deg  slip +2.23 deg
```

Slip angles are small and steady, so this is **not** a slip-angle or relaxation transient — it is
purely `Fz = max(spring + damper, 0)` riding its zero floor and slamming off it, driven by C1's
road-aware damper term.

**Fix: the reported signal now goes through the steering system's own inertia.** A column, rack and
pair of arms cannot follow an 8 ms load spike — that is a tiny angular impulse, not a jolt — and we
were reporting the raw per-tick tyre moment with no filtering whatsoever. `steer_filter_tau`
(0.04 s, Tab row "Steer response", 0 = RAW for A/B) is a first-order lag, so **steady cornering
torque passes through untouched while impulses are killed**. Same probe after:

| | jumps >3 N.m | sign FLIPPED | worst jump |
|---|---|---|---|
| raw | 22.9% of ticks | 21.8% | 29.70 N.m |
| filtered | **4.2%** | **0.0%** | **11.02 N.m** |

**The sign reversal — the exact thing the user described — goes to zero.** The survivors still
correlate 100% with real Fz steps, which is correct: a genuinely large load change SHOULD reach
your hands. **The load steps themselves are deliberately NOT suppressed** — they are real, they are
shared with the "body jumps at max slider settings" report, and they are a candidate for the AWD
controllability note above. Panel: 97 rows, 97 HELP.

- **Still open on C2:** the wash-out cue, and *"very hard to get out of an oversteer when the
  wheels are hot"* — start at M7's `overheat_grip` (0.85) compounding with B4's post-peak lateral
  shape (`cy_gravel`).

## 2026-08-25 (SECOND attempt at the slide-stop jerk - the first fix was real but not it; found a stale relaxed slip angle)

The binary-force-switch fix below did NOT resolve the report - user confirmed *"the jerking bug is
not fixed as of now."* Went back with the user for a better description: happens on **both** the
dirt circle and the rally loop/asphalt (rules out anything terrain-specific - kerbs, camber,
washboard), and feels like *"a force pushes the car in the opposite direction of the slide, like a
spring."* Default car (auto clutch, AWD).

**Found a second, real mechanism, and it matches "like a spring" almost exactly.** B4's relaxation
length (`alpha_rel`, `sigma_lat`) is deliberately RATE-limited **per distance rolled**, not per
time - documented and correct for how a real tyre carcass twists in. But at the tail of a slide the
car's speed collapses toward zero while it is *still rotating fast*, so distance-rolled nearly
stops even though the true slip angle is changing quickly - `alpha_rel` gets stuck.

Measured with a scripted slide-then-countersteer on FLAT ground (dirt circle, no terrain
involved): at the moment the car is essentially stopped (v = 0.2 m/s), the TRUE front-wheel slip
angle had already unwound to **6 deg**, but the RELAXED angle the tyre force actually uses was
still sitting at **45 deg** - a stale value from ~1.5 s earlier, well past the tyre's peak grip
angle. Because Magic Formula force depends only on angle, not on how fast the tyre is actually
moving, that stale 45 deg commanded close to full lateral grip (`util` pinned at 1.00) on a wheel
carrying almost no speed to justify it - a real spring-back force, aimed opposite the slide (that
is the geometric meaning of "relaxing" back toward zero), applied at a moment the driver already
felt the car had stopped sliding.

**Fix:** lateral (slip-angle) force now fades to zero as the wheel's own ground speed drops below
`LOW_SPEED_LAT_FLOOR` (1.2 m/s) - a physical floor, not a hack: slip angle is fundamentally a rate
quantity, and a tyre that is not rolling has no rate left to generate a cornering force from,
however stale or fresh the number sitting in `alpha_rel` is. Verified on the same scripted repro:
utilisation at the near-stop moment drops from **1.00 to 0.21** - the phantom force is mostly gone
exactly where it was diagnosed. The gate only engages in the last ~1 m/s before a stop, so it
changes nothing about how a slide FEELS while it is still happening - B4's relaxation lag during an
active slide is untouched.

**Honesty about verification, per the project's own rule (`CLAUDE.md`): this is NOT confirmed to
fix the reported feel.** The countersteer repro shows the mechanism and its mitigation cleanly, but
(unlike the VM_BAND fix below, which had a crisp single-tick before/after on the exact same
scenario) it did not produce an equally clean before/after on the whole-car velocity trace - the
scripted repro may not be hitting the same conditions as an actual drive. **Please test again and
say whether this one lands.** If it does not, the next lead worth chasing (found but NOT pursued
this session, to avoid guessing a third time without evidence): `_apply_arb()` skips load transfer
entirely the instant either wheel of a pair loses contact (`if not (a.contact and b.contact):
return`), which snaps that axle's Fz split back to the un-transferred value in one tick when a
wheel goes briefly airborne under hard weight transfer - plausible on any surface, not reproduced
cleanly here because the synthetic test that found airborne wheels also had bad spawn-orientation
artifacts on sloped terrain that make its numbers untrustworthy.

## 2026-08-25 (fixed: hard jerk coming to a stop during a slide — a binary force switch, not a snap in the model)

Drive report: *"the car jerks really hard when coming to a stop during a slide."* Real bug, in the
gross-sliding block of the friction ellipse (A5): once a tyre is saturated past the ellipse
(`e > 1`), its force is blended away from the raw two-curve Magic Formula result and toward a force
that opposes the contact patch's actual slip VELOCITY - physically correct, and it is what makes a
locked rear axle let go on its own. That blend was gated by `if vm > 0.2:` where `vm` is the slip
speed magnitude: above 0.2 m/s, full physical-direction force; at or below, an instant, complete
switch back to the raw ellipse-scaled force. **A slide ending is exactly a wheel's `vm` decaying
toward zero**, so every wheel crossed this line once, right as the car settled - the symptom's own
words, "coming to a stop during a slide," describe the crossing exactly.

Measured the size of the switch directly, headless (a standalone car over a flat floor, braked
hard through a 13 m/s mostly-sideways slide, same seed before and after): at the instant `vm`
ticked below 0.2, front-R went from **(-2432, 1557) N to (-2041, 1973) N in one 120 Hz physics
tick** - an 11 degree, ~570 N snap in the force actually applied to the chassis, and all four
wheels take their own such snap at their own moment as the slide runs out (front-L 249 N, rear-R
207 N, rear-L 16 N in this run), so the car takes several of these in quick succession right at the
end - which is what a slide-to-stop looks like from the driver's seat as one hard jerk, not four.

Fix: the binary gate is gone. `vm_gate := clampf(vm / VM_BAND, 0.0, 1.0)` (new `VM_BAND = 0.4`)
fades the SAME blend continuously to zero as the patch actually stops sliding, instead of cutting
it. Re-measured on the identical scenario: the same four crossings now move the applied force by
**9 N, 37 N, 25 N and 80 N** - a 6-26x reduction, and nothing changes for a wheel that is still
genuinely sliding (`vm` well above `VM_BAND`), where `vm_gate` is already 1 and the blend behaves
exactly as before. The division `vsx/vm, vsy/vm` that gives the slip direction still guards against
literal `vm == 0` (`if vm > 0.001`), but its result is now weighted toward zero by `vm_gate` well
before it gets there, so the guard threshold itself is no longer where the car feels anything.

Reproduced and verified with a temporary standalone probe (car + flat floor, no World/stage needed)
that read `_brake_pedal`/`Input.action_press("brake")` directly and logged Fx/Fy at the exact
before/after tick of each wheel's crossing; removed once the fix was confirmed. `stability_assist`
(default OFF) was ruled out as a contributor - it is gated on speed above `slip_ref_speed` (2 m/s)
and never touched in this scenario.

**Housekeeping, not a fix:** while diagnosing this, also read the earlier stall/restart entry -
`a7d849f`, *"A stalled engine can be restarted again, and stalls far less often"* - which had
already landed (and the user separately confirmed: *"good the change works"*) for the anti-stall/
ignition/bump-start bug reported alongside this one. Nothing further was needed there.

## 2026-08-24 (D1 — one authority for what the ground is; two surface bugs surfaced, neither fixed)

Arc D opens. `scripts/ground_map.gd` is now the single answer to "what is the ground at (x, z)?" —
`sample()` returns surface / road_class / deformable / grip / colour / audio, composed of **layers
resolved in priority order**, each a pure function of position. `stage.grip_at`, `is_tarmac_at`,
`deformable_patch_factor` and `_surface_color` are now one-line delegations; `roughness.gd`'s
`road_class_at` and `effects.gd`'s tarmac gate read the map. **Nothing about the car changed, and
that was the hard part** — the phase's success condition is that nothing moves.

**Probe 1, golden equality — THE phase.** 6608 lattice points spanning all four surfaces, both
circuit shoulders (radial sweeps at 1 m steps across each edge), the drag strip to its far end and
the centre patch past its blend. Captured from the unmodified build first, then re-run on the
shipped build: **byte-identical, SHA-256 `80bffdd150893337…`**, across grip, tarmac classification,
patch factor AND vertex colour. Surface census: 4182 grass / 1504 dirt / 922 asphalt.
The probe is kept at `scripts/probe_ground_lattice.gd` (not wired; wiring instructions in its
header) because **D5 reuses it verbatim** to prove the calibration bed rebuilds bit-identically
after an area transition.

**Probe 2, consumer agreement — two pre-existing bugs found. NEITHER IS FIXED**, because a feel
change hidden inside a refactor is exactly what this phase must not do. Both are recorded here so
the next session finds them by symptom:

1. **"The rally loop plays a tarmac squeal when you slide, and the gravel rumble is too quiet."**
   `sound.gd`'s tyre-audio split is `asph = (grip - 1.0) / 0.25`, which reads **0.400 on every
   gravel point — 1504 of 1504 dirt samples**, i.e. the audio hears the rally loop as 40% asphalt.
   That drives two things: the asphalt squeal layer plays at 40% strength while sliding on gravel
   (`squeal_level = tv * asph`), and the gravel rumble is cut 28% (`* (1.0 - 0.7 * asph)`).
   **Cause is drift, not the formula:** the `/0.25` divisor is exact when `dirt_grip = 1.0`, which
   is what `docs/ROADMAP.md` still documents — but `dirt_grip` is **1.1** in code. The moment that
   value moved, the split stopped landing on zero. Fixing it is a real audio change and wants a
   drive test, so it is left alone and `sound.gd` carries a comment saying why.
2. **The centre patch has two different shapes.** `grip_at` decides PATCH with a **euclidean**
   radius test (`r < 75`); `deformable_patch_factor` — which C1 uses to suppress the roughness
   field — uses a **chebyshev** one (square, blended 75→93). They disagree on **392 of 6608
   points**, e.g. `(-84, -84)`: grip says grass, the patch factor says 0.5 (half-suppressed
   roughness). So there is a ring of ground in the square's corners where the roughness field is
   damped for no reason the grip model knows about. Both shapes preserved exactly.

`effects.gd`'s gate was the third suspect and it is **clean**: its retired `asphalt_grip = 1.2`
threshold agreed with the surface test on **0 disagreements / 6608 points**, so switching it to the
map was a measured no-op. The export is gone; the gate is now a class, not a number.

**Probe 3, cost — and it changed a decision.** Measured 52.8 classifier calls per physics tick
(min 1, max 74) with the car settled and effects running. Per call: `ground_map.grip_at` **2.90 µs**,
`stage.grip_at` (through the delegation) **3.81 µs**, `sample()` **9.22 µs**. So the shipped scalar
path costs **0.153 ms/tick = 8.3% of the 1.84 ms baseline**, of which the refactor's own share is
only the extra call hop (~0.9 µs × 52.8 ≈ **0.048 ms/tick, ~2.6%**) — the trig was always there.
**§5 specifies `grip_at` as a delegation to `sample().grip`; it is a delegation to
`ground_map.grip_at()` instead**, because `sample()` builds a Dictionary the caller throws away and
routing everything through it would cost **0.487 ms/tick — 26.5% of the whole physics budget**.
Same classifier, same values (byte-identical), one third the cost. `sample()` remains the API for
consumers that genuinely want several fields.
**Budget note for D4:** C1.0's centreline already costs 1.05 ms/tick. Ground map + centreline is
now ~1.2 ms against a 1.84 ms baseline, so streaming arrives with less headroom than Arc D assumed.

**Godot gotcha that cost a build:** a NEW `class_name` script is not resolvable until the global
class cache is rebuilt — `GroundMap.new()` failed with *"Nonexistent function 'new' in base
'GDScript'"* even though the file parsed. This project never opens the editor, so the cache only
refreshes on `godot --headless --path . --import`. Added to `CLAUDE.md`.

---

## 2026-08-24 (fixed: the engine dies and NOTHING starts it again - no ignition, no bump start)

Drive report: *"when having manual clutch off, sometimes the car still stalls - even with anti stall
on - and the bug is that it doesn't turn on when doing bump starts or when pressing ignition (and
because there is no manual clutch there is no holding it with that option) so it makes it so that on
default start settings there is no way to reignite the engine after stalling."* Both halves are real
and they are different bugs. **Nothing in this file mentioned stalling before today** - grep
`_stalled`, `_dead_t`, `w_stall`.

**The soft-lock: `_stalled` described the SETTINGS, not the engine.** Entry required
`manual_clutch and not anti_stall`, so on the default car (auto clutch, anti-stall ON) the flag
could never be set - while the crank could still reach zero, because nothing else stopped it. And
every restart route sits behind that flag: `[I]`, the 0.5 s clutch-hold starter, and the bump-start
catch. Measured on the default car with the engine at **0.0 rpm**: `[I]` did nothing, a **40 km/h
bump start in gear** did nothing, neutral + `[I]` did nothing, coasting did nothing. The HUD's
`** STALLED - [I] ignition **` line is also behind the same flag, so the driver was not even told
what had happened. `_stalled` is now a statement about the engine - below the firing floor
`_engine_torque()` returns zero and motoring friction only drags the crank further down, so it is
dead however it got there - and `[I]` fires whenever the engine is not turning over rather than only
when the flag happens to be set.

**Why it was only "sometimes", which is the useful part to remember.** Combustion torque decays
through the intake lag (`intake_tau` 0.07 s) rather than vanishing, so a crank flicked briefly under
the floor can still pick itself up on the residual charge, and usually does. Only a *sustained* dip
is fatal. So the stall test has a **dwell of `intake_tau * 3` (0.21 s)** - long enough to keep every
self-recovery that already worked, short enough that a genuinely dead engine is admitted quickly.
Proof it matters: a hard brake to a stop in 3rd dips to **430.8 rpm, below the 500 rpm floor**, and
recovers on its own with no stall declared.

**Two routes dragged the crank under the floor even with anti-stall ON, and both were in the
locked-clutch follow.**

1. **Selecting reverse while still rolling forwards** - `omega_gb` goes negative, and the follow
   `_omega_e = clampf(omega_gb, 0.0, ...)` clamped the crank to **zero in a single tick**. The
   "follow hit a physical limit -> plates must slip" test was written *after* the assignment, so it
   noticed only once the engine was already dead. Measured **2658.4 -> 0.0 rpm**. The follow is now
   tested before it is taken.
2. **Hitting something solid while the plates are locked** - the lock slaves the crank straight to a
   stopped wheel, and the clutch travels at pedal rate (`CLUTCH_OUT_RATE` 25/s, ~40 ms), which at
   120 Hz is far too slow to save it. Measured **2517.2 -> 31.0 rpm**. Anti-stall (and any auto
   clutch, which is always clamped) now **opens the plates rather than letting them drag the crank
   below its firing speed** - which is what a real anti-stall is for.

| trial (default car) | min rpm before | min rpm after |
|---|---|---|
| wall impact while plates locked | 31.0 | **971.2** |
| reverse engaged while rolling forward | 0.0 | **929.5** |
| handbrake at walking pace in gear | 886.3 | 886.3 (was already safe) |

**Every recovery route now works, each tested from a fresh dead engine.** Default car (auto clutch,
anti-stall ON): no input at all -> re-fires; `[I]` -> re-fires; rolling in gear -> re-fires. Hardcore
(manual clutch, anti-stall OFF): clutch held -> starter fires; in gear rolling with the clutch out ->
bump start catches at **2277 rpm**; `[I]` -> re-fires. **With an auto clutch, anti-stall now re-fires
the engine about half a second after it dies instead of stranding the driver** - there is no clutch
pedal to hold, so that recovery has to be the car's job.

**No spurious stalls.** Six driving phases (idle in gear, full throttle up through the box, hard
brake to a stop in gear, standing start, handbrake turn, coasting in neutral): **0 stalled frames**,
lowest rpm seen 430.8.

**NOT verified: feel.** Whether a stall now reads as dramatic-but-recoverable, or whether the 0.5 s
auto re-fire is too eager, needs driving. The hardcore config is unchanged in intent: you can still
genuinely kill it and have to bump start.

**Housekeeping:** a parallel session's `commit -a` swept the temporary probe for this bug into commit
`9073979` ("Broadband roughness was 4.5x too quiet") and pushed it; this commit removes it. Second
time this week - see the note under 2026-08-19.

## 2026-08-20 (fixed: dust born on grass turned white the moment you reached tarmac)

Drive report: *"it should also be given color on birth and not change every surface change after
birth - so if it starts green from grass it shouldn't turn white when I hit the asphalt - only the
new ones should be white"*, plus *"on grass it changes, on the rally loop it changes also and also
on asphalt, but on the dirt circle it doesn't change."* **Two separate defects, and the second
sentence is the tell for both.** This is the DIRT/DUST PLUMES and the DIRT/GRAVEL PARTICLES - the
two surface-tinted layers. ASPHALT SMOKE has a fixed white-grey and was never involved.

**1. A particle could not keep the colour it was born with, because it never owned one.**
`ParticleProcessMaterial.color` is a uniform that the particle process shader re-reads **every
frame**, so writing it re-tints every particle already in the air. Measured, because it is not at
all obvious and three plausible escapes all fail: with `color_ramp` (delta 0.54), with `alpha_curve`
instead (0.58), with **no** over-life ramp at all (0.60), and even with a per-particle
`emission_color_texture` whose colours were swapped while emission was OFF (live particles went
green -> red anyway). **There is no way to bake a colour into one particle of a shared emitter** -
the colour belongs to the emitter, not the particle.

So a tinted layer now gets **several emitters per wheel, each holding ONE frozen colour**. A new
ground colour hands over to a different emitter; the retired one just stops emitting and its
particles live out their lifetime in the colour they were born with. `_pick_slot()` prefers an
emitter *already* holding that colour, so grass -> dirt -> grass reuses the green one and never cuts
a cloud short. The count is derived, not picked: a retired emitter must not be wanted again until
its last particle has died, so `gens = ceil(life / tint_hold)`, clamped 2..4 - plume (life 4.6 s)
gets 3, gravel (0.55 s) gets 2, smoke (untinted) stays at 1.

Proof, both clouds on screen at once: a cloud laid down as green, then the ground colour switched to
white and emission moved a few metres sideways - **old cloud (0.34, 0.76, 0.26) still green, new
cloud (0.80, 0.68, 0.55) white**, with `gen0 emitting=false colour=(0.12,0.80,0.16)` and
`gen1 emitting=true colour=(0.95,0.95,0.97)`.

Also removed the sharpest edge of the same bug: winding a plume down over tarmac passed
`Color.WHITE` as its colour, which - being a live uniform - flashed the **whole fading cloud** white
in one frame. Both branches now sample the real ground colour; dust is the colour of the ground it
was lifted off, wherever the car happens to be.

**2. `_surface_color()` did not know the dirt circle existed.** It blends grass -> road -> asphalt
-> drag strip and had **no term for the centre deformable patch**, even though `grip_at()` has
always had one. So across the whole skid-pad it returned plain `grass_color`, and dust kicked up on
the dirt circle was tinted **green** - and, because the value was constant over the entire patch, it
was also the one place the colour never changed in flight, which is exactly what the report says.
Now blended through `deformable_patch_factor()` (the same query C1 uses, so the patch's extent stays
defined in one place). Measured `ground_color()`, before -> after:

| | before | after |
|---|---|---|
| dirt circle centre | (0.496, 0.496, 0.334) — *identical to grass* | **(0.694, 0.532, 0.334)** |
| rally loop | (0.640, 0.577, 0.460) | unchanged |
| grass | (0.496, 0.496, 0.334) | unchanged |
| asphalt ring | (0.298, 0.298, 0.325) | unchanged |

`terrain.gd` still owns that colour; `world.gd` pushes `patch.dirt_color` into `stage.patch_color`
at wiring time so the two cannot drift apart. **Do not re-tune it in `stage.gd`.**

**Cost — the extra emitters are close to free, which is the surprise worth recording.** Worst case
(all four wheels emitting plume AND gravel, ground colour flipped every 1.5 s to force a handover
every time): emitters **12 -> 24**, particle slots **1920 -> 4120**, but draw calls **1452 -> 1463
(+11)** and primitives **3,050,156 -> 3,054,481 (+4.3k)**, with process ms **18.20 -> 18.09**
(inside the run-to-run spread) and FPS pinned at 60 both. A retired emitter that is not emitting and
has no live particles costs essentially nothing, so the cost tracks *colours actually in flight*,
not the number of emitters allocated. Do not "optimise" this back to one emitter per wheel; that is
the bug.

**NOT verified: how it looks while driving.** Tunables are `tint_bin` (0.10 - the RGB distance at
which a colour earns its own emitter) and `tint_hold` (1.6 s).

## 2026-08-19 (C1 revision: washboard enveloping back to the contact patch — "still can't feel it above 20 km/h"; C1 ACCEPTED)

Recorded late — this shipped as `d43713b` and was never written up.

**Symptom:** after the 2026-08-15 revision below, washboard *still* could not be seen or felt above
~20 km/h on the rally loop. **Cause: the swept-footprint filter from that revision was the wrong
call.** Physical tyre enveloping depends on the CONTACT PATCH and is speed-independent — a real
tyre on a 0.6 m ripple follows it at any speed, because 0.6 m is three times its contact length.
Folding the per-tick swept distance into the footprint low-passed the road *by speed* and cost
**74% of the ridge amplitude at 100 km/h** (transmission 82/66/49/26/9% at 0/30/60/100/150 km/h):
a numerical anti-aliasing fix applied as though it were physics, which deleted the feature exactly
where it matters most.

Sampling once per tick is a real limit, but **only past Nyquist**. One wavelength needs two
samples, so filtering now begins only when a tick travels more than half a wavelength — about
**130 km/h at 120 Hz on 0.6 m corrugation**, well above rally-loop corner speeds, where a 0.6 m
ripple still gets **4.3 samples per wavelength at 60 km/h**. Below that threshold the profile is
untouched: **transmission at 60 km/h goes 49% → 83%.**

**USER DRIVE VERDICT 2026-08-24: C1 ACCEPTED.** Arc C's roughness work is drive-verified and Arc D
is unblocked. Note for anyone re-opening this: the accepted build is the contact-patch footprint
plus `damper_reads_road`, not the swept-strip version described in the 2026-08-15 entry below.

---

## 2026-08-19 (fixed: whole dirt tiles go DARK BROWN when they load — a backwards mesh winding)

Drive report: *"the dirt tiles/squares still have the rendering issue where unloaded tiles are much
lighter than loaded ones... whole tiles change color when rendered, from dark brown to light
brown... not talking about the color of berm or ruts, just the color of the dirt in general."*
The user's own hunch — *"maybe this issue is similar to godot's texture flipping we had in the
beginning"* — was exactly right, and is the fastest route to this class of bug.

**`_build_plane()` wound the shared tile mesh back-to-front, so the top of every live tile was its
BACK face.** The shader runs `render_mode cull_disabled`, so nothing went invisible — instead Godot
negates `NORMAL` on back faces, which turned the vertex shader's carefully-built up-normal into a
*down*-normal. `N·L` against a sun at −72° then contributes **nothing**, so every loaded tile was
lit by **ambient sky only**: dark brown, hard-edged, sitting inside a field of correctly-wound
(PlaneMesh) flat squares in full sun. **`cull_disabled` is what hid this for so long** — with
normal culling it would have shown up as the obvious "half invisible / upside-down" symptom the M5
stage mesh had, and been fixed the same day.

Measured from a top-down capture over **undug** ground (`dug: 0`), 2×2 live tiles surrounded by
flat squares:

| | live tile | flat square |
|---|---|---|
| before | (0.184, 0.153, 0.122) | (0.753, 0.565, 0.365) |
| after | **(0.753, 0.565, 0.365)** | (0.753, 0.565, 0.365) |

Byte-identical after the flip. Note the before-ratio is **4.1 / 3.7 / 3.0 per channel, not a flat
scale** — the dark side is relatively *bluer*, which is the signature of ambient-sky-only lighting
and is what pointed at `N·L` rather than at albedo.

**How it was attributed, in three controls** (worth copying for the next "why is this surface the
wrong colour"): forcing `ALBEDO = dirt` unconditionally **did not change either side** → not the
colour mix; disabling the sun's shadows *and* the tiles' `cast_shadow` changed **nothing** → not
shadowing; `ALBEDO = FRONT_FACING ? green : red` rendered **live tiles RED and flat squares GREEN**
→ winding, conclusively.

**Watch for the recurrence:** any new mesh built by hand for this shader must put its top face
front. `cull_disabled` means a regression will not look like a hole — it will look like *this*, a
whole surface dropping to roughly a third of its brightness and going blue-ish.

## 2026-08-19 (also fixed, but NOT the reported symptom: the ruts you dug vanish when you drive away)

**Read the entry above first — that was the bug the user was actually reporting.** This one is real
and was fixed on the way to it (user confirmed: *"now they do stay in view"*), but it is a separate
defect and diagnosing the report as this one cost a pass. The lesson for next time: *"tiles are
lighter"* meant whole tiles, uniformly — a **lighting** claim. Ruts and berms were explicitly not
what was being described. **Photograph the thing before theorising about the shader maths**; one
top-down capture over undug ground would have separated these two in the first five minutes.

Symptom in driving words: **the ruts and berms you just dug vanish the moment you drive away from
them**, and re-appear when you come back within 36 m. **Rendering only. `t.heights`, the
HeightMapShape collider and the whole Bekker dig model were correct throughout and were not
touched.**

**The centre patch draws its ground two ways and swaps between them by distance.** Within
`unload_radius` (36 m) a tile is live: its own tessellated mesh, its own material, its own
`_tn x _tn` height texture that the wheels rewrite as they dig. Beyond it, the tile is freed and a
flat square takes over. Every one of those 169 squares shared **ONE material pointing at ONE 2x2
texture filled at `bed_height`** — so `vh == bed`, `depth == 0`, and every unloaded square rendered
as **pure `dirt_color`, the lightest value the shader can produce**. Measured on a 10.5 cm rut:
loaded albedo luma **0.245**, unloaded luma **0.502** — a **2.05x brightness step** at the boundary.
Driving away from a rut visually erased it; driving back re-materialised it at 36 m.

**A wrong conclusion recorded on purpose, because the reasoning looked airtight.** This entry
originally claimed undriven ground had no seam, on the grounds that both paths encode pristine
ground as the identical quantised constant (0.1482 m through RGBA8) and both *compute* the same up
normal. Both halves are true and the conclusion was still wrong: the live tile's computed normal
was being **negated by the back-face rule** after the shader had produced it (see the entry above).
**Reading the shader tells you what it computes, not what the rasteriser does with it.**

**The half that is easy to miss: the flat square has 4 vertices.** The shader read the height in
`vertex()` and passed it to `fragment()` as a varying, so colour resolution was the MESH's
resolution. Handing each square its own height texture — the obvious fix — would still have shown
nothing, because 4 corners cannot carry a rut. So the height is now read **per pixel in
`fragment()`**: rut colour is set by the texture, not by how finely the mesh is divided, and the
two paths land on byte-identical colour (rut 0.245/0.245, berm 0.777/0.777 luma).

**What was built.** A released tile no longer throws its visual state away: it hands its heights
*and its height texture* to a `Rut` record, and its square switches to its own material bound to
that texture plus a 32-cell mesh (`flat_vis_cells`, snapped to an exact divisor of `tile_cells` so
the visual's nodes land on tile nodes and the meshes still meet at borders). **Ground that was
never dug keeps the one shared pristine material and its 2-triangle quad**, so undriven field costs
nothing. Reloading a tile now reuses the persisted `Image`/`ImageTexture` instead of re-running a
4,225-pixel `set_pixel` loop. Two smaller bugs fell out on the way: `_mirror()` never marked the
neighbour `dug`, so a tile whose only deformation was a mirrored border row lost it on unload; and
the height sampler was `repeat`-wrapping, so a tile's left edge blended with its own right edge
12 m away — a phantom half-strength rut line at borders. Sampler is now `repeat_disable`.

**Cost, measured on `[J]`** — parked on the dirt circle, whole corridor rutted (34 dug tiles),
whole field on screen, car frozen so the live-tile set is identical (5 tiles) run to run:

| | before | after |
|---|---|---|
| draw calls | 1436 | **1540** (+104) |
| primitives | 3,045,200 | **3,262,084** (+7.1%) |
| process ms | 34.28 (32.9-35.2 over 5 runs) | 34.95 (34.6-35.2) |
| FPS | 37.1 | **35.5** (mean of 3 back-to-back runs each) |
| triangles on the unloaded field | 338 | 69,902 |

**The geometry is not what costs — grep this before "optimising" it by lowering
`flat_vis_cells`.** Forcing the dug squares back to 2 triangles (542 total instead of 69,902)
measured the *same* frame rate. The whole +104 is **draw calls**: ~3 per dug square, i.e. the main
pass plus two shadow splits. The lever that actually works is `cast_shadow` — switching it off on
the flat squares put draw calls at **1432, below the baseline**. It was left ON deliberately: a
rut that self-shadows while loaded and stops when it unloads is the same class of boundary
divergence this entry exists to remove, and 4% of draw calls is not worth reintroducing it. If the
frame-rate hunt needs it back, that is where it is.

**Also worth grepping: an alarming "60 -> 52 FPS" reading here was a measurement artifact.** The
baseline had been captured with a different probe configuration (car not frozen, so it settled onto
a different set of live tiles and pointed the camera somewhere cheaper). Re-baselined with the car
frozen, before and after sit inside each other's run-to-run spread. Pin the car before trusting any
A/B on this patch.

**NOT verified: appearance.** Godot's `--headless` runs a dummy renderer — `ImageTexture.update()`
does not even round-trip through `get_image()` there — so every number above is texture content and
counters, not pixels. Needs a drive on the dirt circle.

**Housekeeping:** this `terrain.gd` change was swept into commit `09d0a7b` ("Measure the grip
channel") by a parallel session's `commit -a` while it was still in progress, and pushed there. The
code in that commit is the finished, verified fix; only its attribution is wrong.

## 2026-08-15 (measured: washboard DOES cost grip — the tyre is airborne 30-43% of the time)

Drive report: *"the C1 roughness is felt at the wheels, but the suspension eats it completely
above 20 km/h."* **The body not responding is correct and is not a bug.** Above resonance a
base-excited spring-mass transmits about `2*zeta/r`; with the body at 1.4 Hz, zeta 0.55 and 0.6 m
corrugation that is **17% at 20 km/h, 8% at 40, 5.5% at 60, 3.3% at 100** — the reported ~20 km/h
threshold is almost exactly where the maths puts it. A real rally car's chassis does not heave at
46 Hz either. Chasing this with more travel, stiffer springs or deeper ridges is the wrong tree.

**So the question became whether the OTHER channel — load fluctuation costing grip — is actually
working.** Measured with a quasi-static quarter car (body held fixed, ground oscillating beneath
it; accurate above ~40 km/h precisely because transmissibility there is only 3-8%) through the real
spring / damper / bump-stop / load-sensitivity code, one front corner, static Fz 3.07 kN:

| speed | Fz mean | Fz min | Fz max | frames unloaded | grip vs smooth |
|---|---|---|---|---|---|
| 20 km/h | 2.83 kN | 0.73 | 4.75 | 0.0% | **90.3%** |
| 40 km/h | 2.82 kN | 0.00 | 6.15 | **30.8%** | **84.3%** |
| 60 km/h | 3.14 kN | 0.00 | 7.47 | **37.5%** | **88.3%** |
| 100 km/h | 3.38 kN | 0.00 | 7.65 | **42.8%** | **91.2%** |

**The tyre is completely off the ground 30-43% of the time at speed, and available lateral force
drops 9-16%.** That is a large handling effect and it is already in the car — washboard should
make it skate, wash wide on entry and refuse to hold a line, even though the body stays calm.
Note the loss is WORST at 40 km/h, not at the top end: past that, mean Fz climbs above static
(3.07 -> 3.38 kN) and partly compensates.

**Second finding, worth watching: that rising mean is rectification.** `Fz = max(spring + damper, 0)`
lets the suspension push but never pull, so an oscillating damper force clips on the down-stroke and
spikes on the up-stroke, netting upward impulse. At 100 km/h it is +0.31 kN per corner — about
**10% of the car's weight pushing it up** over sustained corrugation. Real (washboard does make cars
float and go light), but it is the same mechanism behind the "body jumps and shakes" report at
exaggerated slider settings, so it should be re-checked if bottoming or float behaviour drifts.

**Conclusion: nothing to build yet.** The perceptual channels we lack (unsprung mass / wheel hop,
seat and steering-column shake, camera shake) are all real gaps, but the grip channel is live and
strong, and the enveloping-footprint fix that restored ridge amplitude at speed landed *after* the
drive that produced this report. Re-drive at defaults before adding anything.

## 2026-08-15 (C1 REVISION — the damper can finally see the road; roughness goes from 3% to dominant)

Fixes the *"couldn't differentiate when the roughness gain was on and when it was off, washboard
was only noticeable when driving slow"* verdict below. Both halves are physical; neither is an
amplitude tweak, because amplitude was never what was wrong.

**1. The damper now feels the ROAD's vertical velocity, not just the body's.** `comp_vel` was
`-pv.dot(up)` — purely body-side — so a wheel crossing corrugations registered no damper velocity
at all while the body sat still. A damper responds to RELATIVE velocity across itself, and with no
unsprung mass the wheel follows the ground exactly, so the ground's own vertical speed
(local slope x ground speed) belongs in that term. Slope comes free from a least-squares fit
through the samples the enveloping filter already takes — no extra field evaluations.
**Measured on real washboard (2 cm deep, 0.6 m wavelength, front spring 24 000 N/m):**

| speed | transmitted | spring force | road m/s | DAMPER force | damper:spring |
|---|---|---|---|---|---|
| 30 km/h | 66% | 319 N | 1.38 | **2 008 N** | 6.3x |
| 60 km/h | 49% | 236 N | 2.36 | **3 351 N** | 14.2x |
| 100 km/h | 26% | 123 N | 3.00 | **4 216 N** | 34.2x |
| 150 km/h | 9% | 45 N | 2.73 | **3 844 N** | 85.3x |

The spring column IS the old behaviour: **123 N against a ~4 kN static corner load at 100 km/h,
i.e. 3%** — which is precisely why it could not be felt. The damper term is comparable to the
entire static corner load, so the wheel genuinely unloads and reloads across corrugations.
**And the effect now GROWS with speed instead of shrinking, which inverts the reported symptom** —
correct, because corrugations get more violent the faster you cross them. Road velocity saturates
at its 3.0 m/s clamp around 100 km/h and then eases as the tyre starts skimming the tops.

**2. The enveloping footprint now spans the strip the tyre SWEEPS during a tick, not a fixed
0.2 m patch.** This is both the honest footprint and the correct anti-aliasing filter. The field is
sampled once per tick, so the sampling interval is a DISTANCE that grows with speed: a 0.6 m
washboard gets 8.64 samples/wavelength at 30 km/h, **2.59 at 100, and 1.73 at 150 — past the
Nyquist limit of 2**, where a fixed footprint aliases the ripple into low-frequency garbage.
With the swept footprint, transmission instead rolls off smoothly as a sinc (82 / 66 / 49 / 26 / 9%
across the table above) — the ripple simply gets quieter with speed, the way a real tyre averages
over its contact length, and the way a 120 Hz tick can actually represent.

**Stability checked, because a large new damper force at 120 Hz is exactly how a sim explodes:**
900 frames under full power, all `Fz` finite, **max 23.4 kN** — in line with B3's recorded 23.1 kN
baseline, no divergence. Road velocity is exactly 0 at a standstill by construction (slope x zero
speed), so there is no parked buzz. New Tab row `damper_reads_road` (ON) is the A/B that isolates
this term; 96 rows / 96 HELP.
**Expect this to be STRONG.** If washboard now feels violent rather than informative, the fix is
`washboard_amp` down from 2 cm (it is a slider now), NOT `damper_reads_road` off — that toggle
exists to prove what the term bought, not as a tuning knob.

## 2026-08-15 (C1 drive verdict: "couldn't tell gain on from off"; two root causes found, then C2 built)

**DRIVE VERDICT ON C1 — the phase's central A/B FAILED.** User: *"i couldnt differentiate when the
roughness gain was on and when it was off, washboard was only noticeable when driving slow
otherwise the suspension smooths it completely"*. Also, separately: *"bottoming when going uphill
is fixed as far as i saw"* (that part PASSES — the grass leak fix earlier the same day). C1 stays
UNTICKED for feel. Three findings explain the silence, and **two of them are arithmetic, one is a
genuine model gap** — worth grepping before anyone "turns the amplitudes up" again, because
amplitude is not what is wrong.

**1. The washboard is below the spatial Nyquist limit at speed — this exactly matches "only
noticeable when driving slow."** The field is sampled once per wheel per physics tick, so the
sampling interval is a DISTANCE that grows with speed. At 120 Hz: 30 km/h = 0.069 m/tick =
**8.6 samples per 0.6 m wavelength** (clean). 100 km/h = 0.232 m/tick = **2.59 samples/wavelength**
(barely above the Nyquist limit of 2, so heavily distorted). 150 km/h = 0.347 m/tick =
**1.73 samples/wavelength — BELOW Nyquist**, so the ripple aliases into a low-frequency wobble or
vanishes. Raising `washboard_amp` cannot fix this; it amplifies an alias.

**2. Even sampled perfectly, the BODY should barely move — that part is correct physics, not a
bug.** A 0.6 m ripple at 100 km/h is a 46 Hz input against a 1.4 Hz suspension. Transmissibility
at that frequency ratio (r = 33) is roughly 2*zeta/r = **~3%**, so 2 cm of road becomes ~0.7 mm of
body motion. A real car transmits washboard to the driver through the STEERING, through tyre-load
(and therefore grip) fluctuation, and through structure-borne vibration — not through body heave.
This car has no unsprung mass, so it has no wheel-hop mode either. The conclusion: injecting at
the suspension was necessary but was never going to be sufficient on its own.

**C2 — self-aligning torque, built the same day, and it is the channel finding 2 says is missing.**
What a driver feels through the wheel is not body motion, it is the torque the front tyres exert
about their steering axis: `Mz = Fy * (t_pneumatic + t_mechanical)`, summed over the front wheels
and divided by `steer_ratio`. Taken from the FINAL `Fy` — after the friction ellipse and after A5's
gross-sliding correction — so a tyre trimmed by combined slip reports the weaker signal it
physically would. Read it on the HUD as `steer Nm`.
**The point is the COLLAPSE, and the first implementation got its shape wrong.** Pneumatic trail
shrinks as the contact patch starts sliding, so the wheel goes LIGHT just before the front washes
out — that lightening arrives BEFORE the grip does, which makes it more informative than raw force.
A straight-line collapse (`t_p0 * (1 - |alpha|/alpha_peak)`, what the plan suggested first) measured
with the torque **peaking at 1.1 deg against a 9 deg grip peak — only 12% of the way to the
limit**, because `Fy` saturates extremely early (98% of peak by 2.2 deg). The wheel would lighten
across the entire range and the lightening would carry no information about where the limit is.
Switched to the **cosine (Pacejka Mz) form**, which the plan explicitly permitted and which is what
the physics says: trail holds near its static value while the patch still ADHERES, then falls away
as the rear begins to slide. Measured after: peak moves to 1.6 deg (tarmac) / 2.8 deg (gravel), and
crucially the weight is HELD longer early then dropped harder late — 4.5 deg to 9 deg now sheds
**51%** of the torque versus 43% before, so the cue concentrates where it matters.
Probe (removed): Mz peaks before Fy on both surfaces PASS; falls to **42%** of its own peak by
2x peak slip PASS; reverses sign with steering direction and is exactly 0.000 N·m on centre PASS.
**Honest note:** the torque peak is still early in absolute terms, and that is a property of B4's
drive-verified lateral curve saturating at ~2 deg, NOT of the trail model — B4 is drive-verified and
was deliberately not touched here. New Tab rows: `trail_pneumatic`, `trail_mechanical`,
`steer_ratio`, `sat_gain` (95 rows / 95 HELP, no gaps). No rumble wired: `start_joy_vibration()`
is rumble, not force feedback, and must never be described as FFB.

**3. REAL MODEL GAP — the damper is blind to the road.** `comp_vel` is computed purely from the
BODY's velocity at the contact point (`linear_velocity + angular_velocity.cross(contact_off)`) and
never includes the rate of change of ground height under the wheel. A real damper reacts to
RELATIVE velocity, so a wheel crossing corrugations should see large damper velocities even with
the body dead still. Ours sees none. **Pre-C1 this was harmless — the ground was smooth, so
d(ground)/dt was ~0 — and C1 is what makes it matter.** Consequence: roughness currently produces
only a SPRING force change: 2 cm x 24 181 N/m = **484 N on a ~4 kN static corner, a 12% wobble**.
Had the damper seen the road, the same input at 46 Hz reaches its 3.0 m/s clamp and the digressive
curve returns **~4.98 kN** — an order of magnitude more, and the thing that would actually make the
car skip and dance. NOT fixed here: it is a real physics change with real harshness risk and wants
its own probe (energy per impact) plus its own drive test, exactly like B3's hydraulic bump stop.

## 2026-08-15 (real bug: washboard was firing on open grass, "out of control" - root cause of a loose-surface FPS drop)

**User verdict from a parallel session: the frame-rate drops on loose surfaces traced to C1
roughness "being out of control on grass."** Confirmed and fixed - `wear.is_tracked(x,z)`, added
in C1.1 as the washboard placement mask, only checked the ANGULAR SECTOR (theta from the map
centre), never the lateral distance from the actual road. So any point at ANY radius that shared
an angle with one of the rally loop's tracked corner/braking zones read as "tracked" - including
open grass hundreds of metres out, far past the drivable corridor. Full-amplitude washboard
(`sin(2*PI*s/lambda)`, default depth up to 6 cm now that it's Tab-tunable) was landing on wide-open
grass wherever the driver's angle-from-centre happened to line up with a corner zone, which is
most of the map's angular span once you account for `brake_dist` (32 m of arc before every
corner). At speed and off-road, the raycast's spatial sampling rate can alias the washboard's
0.3-1.0 m wavelength into effectively frame-to-frame noise, which explains both the "out of
control" feel and the FPS cost (erratic Fz/compression every tick from a term that should never
have been active there at all).

**Fix: `is_tracked` now delegates to `_cell(x,z) >= 0`** instead of re-deriving half its logic -
`_cell()` already checks BOTH the tracked flag AND the lateral corridor bound (`lat_extent` around
the centreline) correctly, and is the same test the worn-line placement itself uses. Verified
headless: a point at a tracked angle but 250 m further out than the road now reads `is_tracked =
false` and `washboard = 0.0` (previously would have returned the full sine amplitude). Washboard
is now provably confined to the actual tracked corridor on the actual road - it cannot leak onto
grass regardless of angle or distance.

**First drive report: "feels pretty smooth, only the asphalt kerb edges feel like anything."**
Clarified first — the kerb is real geometry that predates C1 entirely, unrelated to this phase;
washboard only lives on the rally loop's corner/braking zones (`wear.gd`'s mask), and tarmac gets
joints/patches, not washboard. The most likely explanation is that the C1.1 defaults (2 cm
washboard, 6 mm joints, 12 mm patches) are genuine physically-grounded starting points but too
small to clear the perception threshold against 20+ kN of cornering/braking load already in play -
exactly the "let the drive test move it" case the plan called out in advance.

**So the individual amplitudes are now live-tunable, not just `roughness_gain`.** They were
exports on the `Roughness` node, which the Tab panel can't reach (it only ever reads/writes
`vehicle` properties). Mirrored five of them onto `vehicle_m2.gd` instead — `road_class_gravel`,
`road_class_tarmac`, `washboard_amp`, `joint_amp`, `patch_amp` — synced into `roughness_field` once
per physics tick before the raycast pass, so the car stays the single source of truth the panel
already knows how to edit. This lets the amplitudes be dialled up hard (e.g. washboard to 5 cm) as
a quick pass/fail: if a strongly exaggerated value is still not felt, that points to an actual bug
rather than a tuning gap. Panel: 91 rows, 91 HELP entries, no gaps.

## 2026-08-15 (the A/B toggles were unreachable on macOS; real perf readout added)

**The [F9]/[F10] toggles added earlier never worked, and the reason is worth remembering:
macOS reserves F9 and F10 for Mission Control and volume, so the application never receives them.**
The handlers were fine — nothing in the project calls `set_input_as_handled`, and Tab reaches
`_unhandled_input` normally — the KEYS were unreachable. Any future in-game debug key must avoid
F-keys on this machine.

Replaced with polled letter keys, which cannot be swallowed by input handling either:
- **[G]** all surface effects off/on (dirt/dust plumes, dirt/gravel particles, asphalt smoke)
- **[H]** worn-line overlay off/on
- **[J]** on-screen performance readout

**The readout is the point.** It shows FPS, frame time, **process ms**, **physics ms**, **draw
calls**, **primitives**, and the live emitting-particle count. Those separate the candidates that
a description cannot: if the frame rate falls while draw calls and primitives stay flat, it is not
the particles — it is CPU. If physics ms is what climbs, it is the physics tick, not rendering.

**A suspect worth naming, since the report attributed the drop to the particle-rate increase:
C1 landed at almost the same time**, and it adds a per-wheel roughness sample at 120 Hz whose own
measured cost is **1.05 ms/tick against a 1.84 ms/tick baseline** — a ~57% increase in physics tick
cost, and it is active on exactly the loose surfaces where the drop is reported. That is not an
accusation, it is the other thing that changed; the [J] readout distinguishes them in one drive by
showing whether *physics ms* or *draw calls* is what moves. `roughness_gain = 0` in the Tab panel
disables C1's sampling for the same A/B.

**Also: plumes and asphalt smoke now expand FASTER at speed, not just larger.** Final size already
scaled with speed; this scales the rate. A puff reaches full size 2.07 s after birth at 20 km/h,
1.23 s at 100, and **0.66 s at 160** — three times sooner, which is what a plume torn off at speed
actually does. Implemented as a handful of pre-baked growth curves selected by speed bucket, since
the curve is a texture and rebuilding it per frame would be wasteful; swapping is a pointer
assignment.

## 2026-08-15 (C1 — the ground finally has texture: washboard, ISO gravel/tarmac noise, tyre enveloping)

**"The rally loop was a smooth floor with a friction number" — that's the bug this closes.**
Outside the centre deformable patch the collision grid is 2.25 m/cell, so no amount of suspension
tuning (Arc B) could ever put real bump feel under the tyres; C1 adds a procedural roughness FIELD
sampled per wheel and injected into the suspension raycast's ground distance, not baked geometry -
repeatable (same bump every lap, so the stage stays learnable), and free of collider resolution.

**C1.0 first: a real arc-length `Centreline` (`scripts/centreline.gd`), not a theta hack.** C1
models washboard as `sin(2*PI*s/lambda)` with `s` = distance along the road; the only `s` that
existed before this was theta-derived, and Arc D was always going to replace that with true spline
arc length. Building the real thing first (moved forward from Arc D's D2 on 2026-08-13, see
`docs/PLAN-stages-ground-map.md` §6.2) means the existing map's washboard ridges cannot silently
shift out from under a drive-verified feel later. It reproduces the direct polar formula to
**0.0000 mm** on both circuits and costs 1.05 ms/tick for 4 wheels x 120 Hz of `nearest_point`
against the 1.84 ms/tick baseline - real but budgeted, thanks to a spatial grid instead of brute
force.

**The field itself: ISO 8608 broadband noise + washboard on gravel, joints/patches on tarmac.**
One physically meaningful coefficient per surface (`road_class_gravel` 128, `road_class_tarmac` 4,
roughly ISO class D vs A/B) sets an octave-spaced noise spectrum instead of a pile of bump knobs.
Washboard corrugation reuses **`wear.gd`'s own corner/braking-zone mask** (new `wear.is_tracked`)
so the line that gets worn is the line that gets ribbed - no second mask invented.

**Enveloping filter, measured, not assumed: a tyre bridges anything shorter than its own contact
patch.** Sampling 9 points across `contact_patch_len` (0.2 m) and combining with a peak-biased
weighted mean, a synthetic 3 cm x 4 cm bump ridden dead-centre comes through at only **31% of its
raw depth**, while a 0.6 m washboard crest comes through at **83%** - texture survives, buzz gets
filtered, confirmed by feeding both synthetic profiles through the actual filter function.

**Injection is one line in `vehicle_m2.gd`: shift the raycast's `hit_pos`, not add a force.**
Everything downstream (spring, damper, B3's bump stop, `Fz`, load-sensitive grip, weight transfer,
tyre heat/wear) inherits it for free and correctly, and `w.contact_point` moves with it so dust,
tyre marks, terrain dig and audio all read the same offset ground. New Tab row `roughness_gain`
(default 1.0) is the phase's whole A/B - 0 skips the sample and is bit-for-bit the pre-C1 car.
Excluded over the centre deformable patch via a blend query (`stage.deformable_patch_factor`), not
a hardcoded radius, so `terrain.gd`'s real geometry there is never double-counted.

**Headless probes, all six PASS** (spectrum, enveloping, repeatability, centreline identity,
`nearest_point` cost, travel budget) - full numbers in `docs/PLAN-drivetrain-suspension.md` §9.
**One honest caveat on the travel-budget probe:** its synthetic autopilot only sustains ~45 km/h
average on the rally loop (a curvature-governed pure-pursuit driver, not a racing line), well
under the 100 km/h B2/B3 measured at - so while `roughness_gain=0` reproduces B3's baseline within
1% (22.8 vs 23.1 kN peak, 4/4 pegged either way, confirming the injection is truly inert at zero),
the gain=1 comparison (22.6 kN, slightly FEWER bottomed frames, not more) is suggestive rather than
load-bearing. **This is a feel phase - the real verdict is the user's drive**, per the checklist in
the plan: is washboard felt as a handling event under braking into a dirt corner, does the rally
loop read as a surface at speed, does tarmac stay smooth-but-alive rather than dead glass, is there
no buzz at parking speed or 250 km/h, and is bottoming no worse than B3's baseline.

## 2026-08-15 (frame-rate drops on loose surfaces — two real costs found, plus an A/B instrument)

Symptom reported: *"massive fps drops when going over dirt/grass/gravel"*, and crucially *"even
after dust plumes seem to disappear"*. That last clause is the useful one — it rules out anything
whose cost ends with the visible particles, and points at work that continues.

**1. The worn-line overlay was re-pushing every cell, every physics frame.** `wear.gd
_update_visual()` walked all ~5900 tracked cells at 120 Hz, calling `set_instance_color` on each
worn one. Worse, it DEGRADED as you drove: the "skip unworn cells" early-out stopped firing as the
line developed. Measured: **0.24 ms/frame with a fresh line, rising to 0.57 ms once fully worn** —
28 to 68 ms of CPU per second — against **0.0002 ms/frame** for the four cells the wheels actually
touch. Now only changed cells are pushed (a dirty set filled in `_accum`), which is the same
picture for ~1/2800th of the work. This is dirt-only and independent of particles, so it matches
the "persists after the dust is gone" part of the symptom exactly.

**2. Faded particles still cost full fill rate.** A particle at alpha 0.02 is rasterised exactly
like an opaque one — the GPU shades every pixel of a 4.4 m sprite to blend nothing. With a 4.6 s
plume life and a long fade, the plume kept costing full price for **seconds after it looked gone**.
The growth curve now peaks mid-life and collapses to half diameter over the fade, so the invisible
tail costs a quarter of the area it did. Measured: **peak diameter unchanged at 4.42 m**, whole-life
area-seconds 941 → 820 (87%), and in the faded half specifically **653 → 434 (66%)**.
Also dropped `draw_order` from VIEW_DEPTH back to INDEX: a per-frame depth sort of ~1900 particles
buys nothing here, because the puffs are near-identical in colour so mis-ordered blending is
invisible.

**3. An A/B instrument, because the rest cannot be attributed from a description.**
- **[F9]** kills every surface effect outright (dirt/dust plumes, dirt/gravel particles, asphalt
  smoke) and prints the particle-slot count.
- **[F10]** hides the worn-line overlay.
Neither touches the input map, so nothing can clash. Drive the rally loop watching the frame
counter and toggle one at a time: if F9 restores the frame rate the cost is particle fill; if F10
does, it is the overlay; if neither does, it is neither and the next suspects are the deformable
centre patch (`terrain.gd`) and the per-wheel `ground_color()` sampling.

**Not yet attributed beyond these two.** GPU particles do not simulate under `--headless`, so
fill-rate cost cannot be measured here — only reasoned about and reduced. The toggles turn the
remaining question into one drive.

## 2026-08-14 (particle density and cost — measured, not guessed)

**These particles are FILL-RATE bound, not count bound. That is the whole story, and it should be
grepped before anyone "adds more particles" again.** Every transparent sprite is drawn back-to-front
whether or not something later covers it, so cost scales with AREA on screen, not with how many
there are. Measured at the 160 km/h ceiling: one dirt/dust plume particle is 4.42 m across = 15.3 m2
of sprite, and 600 of them is ~9 200 m2 — roughly **23x full-screen overdraw** if they overlapped in
view. Doubling the count doubles that while barely looking denser, because the cloud is already
opaque where it overlaps.

**So density was bought from alpha and from the sprite, not mainly from count.**
- Alpha ceilings up: plume 0.44 → 0.52, asphalt smoke 0.30 → 0.36. Free — same pixels, more opacity.
- The puff sprite now has a **denser core and a shorter fringe** (alpha x1.35, clamped). A wide band
  of near-transparent pixels costs exactly as much fill as opaque ones and shows almost nothing;
  after the change one frame still carries 564 of 4096 pixels in the near-invisible 0.02–0.25 band,
  which is where any further fill savings would come from.
- Counts raised moderately, paid for by the savings below: plume 150 → 240/wheel, smoke 100 → 170,
  gravel 40 → 70. Total 1160 → 1920 particles across 12 emitters.

**Optimisations applied, all verified present in the API before use:**
- **`fixed_fps = 30` + `interpolate = true`** — particles simulate at 30 Hz instead of every rendered
  frame and are interpolated between steps. Dust has no fast transients to miss, so this is most of
  the simulation cost back, and it is what pays for the extra count.
- **Mipmaps on the atlas** — distant particles sample a smaller level, which stops them shimmering
  and cuts texture-cache pressure when a plume fills the screen. Frames already fade to alpha 0 at
  their borders, so lower mips do not bleed one frame into its neighbour.
- **A fixed `visibility_aabb`** — without one Godot recomputes bounds, and a moving emitter with
  world-space particles can cull a plume that is still plainly visible.
- **`draw_order = VIEW_DEPTH`** for correct back-to-front blending between particles.
- **`density`** export (build-time multiplier on every layer's ceiling) so the ceiling can be raised
  deliberately with the cost understood, rather than by editing three numbers.

**Known next step, not taken:** the 12 emitters (3 layers x 4 wheels) could collapse to 3 using
`emit_particle()` to spawn at arbitrary transforms from one pool per layer — fewer draw calls, and
density could pool where it is needed instead of being split four ways. `emit_particle` is confirmed
to exist, but GPU particles do not simulate under `--headless`, so it cannot be verified without
driving; it was left rather than changed blind.

**Not drive-tested.** If the frame rate drops, `density` is the first knob (try 0.6), then
`plume_d_max_tyres` — halving the diameter quarters the fill cost, which no count change can match.

## 2026-08-14 (four named effects; plumes and gravel split apart)

**The four surface effects now have fixed names, recorded in `CLAUDE.md`** so a future session
cannot blur them: **asphalt smoke**, **asphalt tire tracks**, **dirt/dust plumes**, and
**dirt/gravel particles**. They are four separate systems with unrelated fixes — the user named
them precisely because confusing them was already causing wrong changes. LAYERS keys renamed to
match (`plume`, `gravel`, `smoke`).

**Sizes are now quoted in TYRE DIAMETERS, not metres**, because that is how they are specified
("4-6 times larger than the tires", "half a tire", "2x tire size") and because it stays correct if
the wheel size ever changes. The particle mesh is a 1x1 quad, so a particle's scale IS its diameter
in metres and the arithmetic stays readable. Tyre diameter is read from `car.wheel_radius` (0.68 m).

**DIRT/DUST PLUMES — now speed-driven, and much bigger.** They kick up from 20 km/h, are fully
established by 40, and sliding adds on top (0.60 straight, 1.00 sliding) — a change from the
previous slip-only gate, which meant a fast straight line on gravel threw nothing.
Measured size: 40 km/h → 2.0 tyre diameters, 60 → 2.7, **100 → 4.2, 120 → 5.0, 160 → 6.5**, holding
at the ceiling beyond (checked at 200 km/h). That puts 100 km/h+ in the requested 4–6x band.
**Frequency has two parts now.** Per-metre emission (rate proportional to speed, because particles
live in world space and a fixed rate smears over more ground the faster you go) TIMES a *fluidity
gain* so the plume also thickens in its own right. Measured against 40 km/h: 60 → 1.78x, 100 →
3.91x, **120 → 5.25x**, 160 → 6.99x. Of that 5.25x at 120, 3x is distance and **1.75x is the gain**,
which is the 1.5–2x asked for. Rise speed scales with speed too (x0.6 → x1.7).

**DIRT/GRAVEL PARTICLES — split from the plumes and gated separately.** Mainly slides, but high
speed alone flicks some stones, and the same slide throws fewer of them when slow. Measured:
20 km/h sliding 0.52, 60 sliding 0.66, 120 sliding 0.98; 120 straight 0.12, 160 straight 0.22,
20 straight 0.00. Stones do not scale with the tyre — they stay 7 cm.

**ASPHALT SMOKE — born half a tyre, grown to two.** Baseline is exactly the spec: born 0.34 m
(0.5 tyres), reaching 1.36 m (2.0 tyres). The pressure build-up now grows it BEYOND that baseline
(x1.4 at a full column → 2.8 tyres) rather than up to it. It is also more frequent from the start
(density floor 0.45, so 0.71 at speed with no build-up at all) and rises faster (3.0 vs 1.8 m/s),
and it uses the same speed-based frequency formula as the plumes.

**Not drive-tested — visual.** Knobs: `plume_d_min_tyres` / `plume_d_max_tyres` for plume size,
`fluid_gain` (1.75) for the extra frequency ramp, `plume_speed_start` / `_full` / `_ceiling` for
where it begins and tops out, `gravel_speed_share` for stones without sliding, and
`smoke_d_birth_tyres` / `smoke_d_death_tyres` / `smoke_build_gain` for the smoke column.

## 2026-08-14 (particles: speed-scaled dust, building smoke column)

**Accepted look, refined behaviour** — user verdict on the rebuilt system: *"the particles look
much much better and mimic a lot more closely the behavior i wanted"*. This entry is the tuning
pass on top of it, plus one API change that was needed to do it honestly.

**Moved the emitters from CPUParticles3D to GPUParticles3D**, for one reason: `amount_ratio`. It
scales emission density continuously with no restart. The CPU node has no equivalent — its only
rate control is `amount`, and writing that mid-drive restarts the system and wipes the live cloud.
Verified `amount_ratio` exists on GPUParticles3D and does NOT exist on CPUParticles3D before
committing to the change. The move also brought turbulence, so dust now swirls instead of drifting
in straight lines.

**Dust grows and thickens with speed, from 20 km/h to a ceiling at 120.** Frequency has to scale
with speed, not just size: particles are left in world space, so a fixed emission rate is smeared
over three times the ground at 100 km/h that it covers at 30 — the plume visibly thins exactly when
it should be biggest. Emission per METRE is the honest quantity. Measured: 20 km/h → scale x0.85,
density 0.35; 40 → x1.14, 0.48; 60 → x1.44, 0.61; 90 → x1.88, 0.81; 120 → x2.30, 1.00; and beyond
120 it holds at the ceiling rather than running away.
Particles are also **born bigger, expand faster and settle larger**: the growth curve is now
[birth 0.75 → 2.30 by 32% of life → 3.10 at death] against the old [0.30 → 1.85 linear], and
**life is 4.6 s, up from 3.2 s**. Base sprite 0.42 → 0.52 m.

**Tyre smoke now BUILDS under pressure and subsides slowly**, like a real tyre. It integrates
pressure rather than tracking it, so a long drift makes a column and a quick stab does not, and
lifting tapers instead of switching the smoke off. Measured: under sustained slip the column
reaches 0.39 after 1 s, 0.77 after 2 s and full at 2.6 s; once the pressure is off it falls to 0.60
after 2 s, 0.20 after 4 s and is gone by 6 s. The build-up drives SIZE (x0.75 with no build, x2.00
at a full column) and density, while instantaneous pressure drives opacity.

**Sizes are smoothed before they reach the shader.** `scale_min`/`scale_max` are uniforms the GPU
reads every frame, not values baked at spawn — writing them raw would resize every live particle at
once, the same class of bug as the earlier colour flicker. They ease over ~0.7 s so a change reads
as the cloud swelling.

**Not drive-tested — visual.** Knobs: `dust_size_start` / `dust_size_ceiling` / `dust_size_full`
for the speed ramp, `dust_density_start` / `_ceiling` for frequency, `smoke_build_time` (2.6 s) and
`smoke_decay_time` (5.0 s) for how fast the column comes and goes, and the `grow` arrays in
`LAYERS` for the per-particle expansion.

## 2026-08-14 (particles rebuilt on research)

**Particle system rebuilt as a data-driven layer table, after the first attempt looked wrong.**
Symptoms this closes: *"the plumes are in the middle and move to each side the moment I touch
steering"*, *"they look identical, like a weird oblong shape"*, *"wrong colour"*, *"the single
streak on gravel starts at any speed"*.

**The identical-shape bug, which is worth remembering.** A `CPUParticles3D` has ONE mesh with ONE
texture, so every particle in a system draws the SAME sprite. The previous "5 variants" only varied
between emitters, not between particles — so a 60-particle plume was 60 copies of one shape, which
is exactly what read as a single oblong blob. The fix is the standard flipbook route: a **2x2 atlas**
with `billboard_mode = BILLBOARD_PARTICLES`, `particles_anim_h/v_frames = 2`, and per-emitter
`anim_offset_min/max = 0/1` with `anim_speed = 0`, so each particle picks a random static frame.
Verified: the 4 frames differ in coverage 0.097–0.194 (2x) with distinct centroids.
**Sprites are now clusters of overlapping circles** (max of soft circular falloffs, merged into one
lumpy silhouette), because that is what a dust or smoke puff actually looks like.
**Born small, swelling, fading to nothing:** `scale_amount_curve` takes dust 0.30 → 1.85 over its
life while `color_ramp` alpha ends at 0. Ending on alpha 0 is documented as the single biggest
factor in whether a particle effect reads as believable.
**Emission is from a small BOX** at each contact patch rather than a point, so a cloud has body.
**Soft particles:** `proximity_fade` fades the sprite where it cuts the ground instead of showing a
hard intersection line.

**No more centre streak.** The plume was ONE car-level emitter offset along the velocity vector, so
it sat in the middle and swung sideways the instant the velocity direction changed under steering.
All three layers are now per-wheel, born at the contact patch, and left in world space — the plume
forms behind the car because the car drives away from it, not because it is placed there.

**Dust now needs SPEED and SLIP, multiplied — not added.** The old version added a rolling term, so
it trailed a plume at walking pace. The speed gate takes whichever is larger, road speed or slip
speed, so a spinout still raises dust while a crawl cannot. Measured: crawling 0.00, cruising
90 km/h gripping 0.00, 90 km/h light slide 0.42, 90 km/h big drift 0.94, 40 km/h big drift 0.22,
standing burnout 0.67.

**Colour.** Particles are UNSHADED again but tinted by the sun's current colour and energy. Shaded
billboards are lit through a camera-facing normal, so their brightness changed as the camera swung
— that was the "wrong colour". Tinting keeps them in step with the time of day without the artefact.
Base colour still comes from `ground_color()`, which includes the wear line's dark tint.

**Smoke is deliberately much less than dust**, as asked: alpha ceiling 0.30 against dust's 0.44,
scaled by a further `smoke_scale` 0.55, smaller (0.30 m vs 0.42 m) and shorter-lived (2.4 s vs 3.2 s).

**Structure.** Layers are now declared in a `LAYERS` dictionary — amount, life, size, gravity,
growth curve, alpha ceiling, spread, damping, emission box, render order — and `_build_layer()`
turns a declaration into four per-wheel emitters. Adding water spray, snow or mud is a dictionary
entry, not new code. **Not drive-tested — visual.**

## 2026-08-14

**Particle system rebuilt as THREE layers, plus two rendering artefacts fixed.**
Symptoms this closes: *"the smoke flickers in brightness when braking"*, *"smoke fades in and out
of the tyre tracks"*, *"the particles don't match the colour of the dirt tracks"*, *"the worn line
doesn't darken with the ground at dusk"*.

**Three layers, because they are three phenomena and not one effect at three sizes.**
1. **SMOKE** on hard surfaces — white-grey burnt rubber, from drifts and hard stops.
2. **PLUME** on loose surfaces — the big billowing cloud a rally car drags behind it. Driven by
   SPEED, not just slip: a tyre shears loose material simply by rolling over it, which is why a
   gravel car trails a cloud down a straight at constant throttle. Measured: 0.16 at 29 km/h
   cruising with zero slip, 0.49 at 90 km/h, rising to 0.87 at 90 km/h with half slip. Born
   `plume_back` (2.4 m) behind the car, big (0.85 m), slow, long-lived (2.8 s).
3. **GRIT** on loose surfaces — small stones and sand thrown ballistically from the contact patch.
   Heavy (gravity −19), short-lived (0.55 s), tight 26° fan, no air damping. Needs slip: cruising
   throws a plume and no grit.

**Flicker fix — the cause was mine and it is worth remembering.** `CPUParticles3D.color` is a
UNIFORM over the whole system, not a per-particle value set at spawn. The code wrote it every
physics frame from a raw intensity, so every live particle was re-tinted at once — and under
braking the load pumps through the bump stops at a few Hz, which showed up as the entire cloud
pulsing in brightness. The driving signal now goes through an **envelope follower with fast attack
(0.18 s) and slow release (1.60 s)**: it swells the instant a slide starts but rides over the
troughs instead of dipping into each one. Measured on a 4 Hz oscillating input: raw swings 0.64
peak-to-peak, smoothed swings **0.13 — 80% of the flicker removed**, sitting at 0.87–1.00 rather
than tracking down to 0.36. Grit gets its own short release (0.14 s) because stones are discrete:
they stop when the slip stops, and a lingering trickle of gravel looks wrong.

**Sorting fix.** Smoke drifting over a skid mark could flip behind it and back, because transparent
surfaces are sorted per object. Explicit `render_priority` now pins the order: marks (−1) under
grit (0), plume (1) and smoke (2).

**Colour match.** Dust sampled `stage._surface_color()` — the BASE terrain — but `wear.gd` paints
the driven line toward a dark worn brown at up to 0.84 alpha, and the car spends its life on
exactly that line, so the dust was far too pale for the ground it came off. `ground_color()` now
recovers the wear fraction from the grip the wear node reports versus the stage's base grip
(`wn = (g_worn/g_base − 1) / wear_grip`) and applies the same tint the overlay does — no new
plumbing, and it stays correct if wear.gd's tuning changes.

**The wear line's own rendering issue: it was UNSHADED** while the terrain beneath it is lit. It
kept its noon brightness through the whole time-of-day cycle, so it read as a glowing stripe at
dusk and night instead of darkening with the ground it is painted on. Now `SHADING_MODE_PER_PIXEL`,
as are the particles, so all three stay in the same light.

**Not drive-tested — visual.** First knobs if it is wrong: `plume_speed_ref` (28 m/s for a full
rolling plume), `slip_ref` (6 m/s), `smoke_power_ref` (45 kW), and `release` if any flicker remains.

## 2026-08-13 (evening, later)

**Tyre smoke on hard stops, and particles that look like dust instead of flying squares.**
Symptoms this fixes: *"stamping on the brakes on tarmac produces no smoke"*, *"the particles look
like squares flying"*, *"dust puffs around the car instead of trailing behind it"*.
**Smoke had one cause and needed two.** It gated on M7 tyre temperature alone, so a panic stop
made none — the tread had not had time to heat up, which is precisely when a real tyre smokes
most. Smoke now takes whichever route is stronger: THERMAL (a tyre worked hot over a long drift)
or POWER — friction power at the contact patch, P = mu.Fz.v_slip, which a locked wheel dumps into
the tread instantly. Measured: a hard stop on cold tyres (60 C, 5 kN, 25 m/s of slip) now reads
**1.00 where the temperature-only gate read 0.00**; a cold lock-up at 30 km/h reads 0.68; threshold
braking with small slip reads a faint 0.07; cruising stays at 0.02. Colour is white-grey (0.90,
0.90, 0.92) burnt rubber.
**Particles** now use procedurally generated soft puff sprites — 5 variants, each with its own
lobed silhouette and internal mottling from its own seed, generated in code like everything else
(no image assets). Each particle also gets a random start rotation, its own spin, a wide scale
spread (0.35–1.7), randomised lifetime and air damping, and a gradient that fades it in and
dissolves it rather than blinking it out. Verified: ~145 of 256 sampled pixels per sprite are
partial alpha, where a flat square would be 0. Dust is smaller (0.20 m) and there is more of it
(44 per wheel), which is what reads as dust rather than debris.
**Dust now trails.** Material is thrown BACKWARD along travel (`dust_trail` 0.65 of the kick)
instead of straight up, so a plume streams behind the car rather than puffing around it.
**Still not drive-tested** — visual, so only driving can judge it. `slip_ref` (6 m/s for full
intensity) and `smoke_power_ref` (45 kW) are the first knobs to reach for if it is too eager or
too shy.

## 2026-08-13 (evening)

**M11 dust, smoke and skid marks — now driven by physics instead of a threshold.** New
`scripts/effects.gd`, self-contained; the old inline code in `world.gd` is gone.
Symptoms this fixes, in driving words: *"sliding sideways on gravel throws no dust"*, *"dust
looks identical on grass and on the gravel loop"*, *"tyre smoke on tarmac whenever a wheel
spins, even stone cold"*, *"skid marks vanish mid-corner"*.
The old test was `w.slip > 0.35` — slip RATIO only — so it saw wheelspin and lock-ups and was
blind to everything else. Effects now scale with **contact-patch slip velocity** (m/s of rubber
actually sliding, combining slip ratio AND slip angle) times **load**, so a lightly loaded wheel
throws less. Measured on synthetic cases: a pure sideways slide at 25 km/h reads 12.0 m/s of slip
and full intensity where the old test emitted **nothing**; a big slide on an unloaded wheel drops
to 0.20 intensity where the old test emitted at full; a blip at a standstill drops to 0.19 (a
puff, not a plume); gripping at 108 km/h stays at 0.00.
**Smoke is thermal, not merely frictional** — it gates on M7's per-tyre temperature, starting at
110 °C and reaching full at 165 °C (optimum is 85 °C), so a cold lock-up puffs and a long drift
billows. **Dust takes its colour from the ground it came from** via `stage._surface_color()`, so
the gravel loop throws dusty tan and the grass verge throws olive — no per-surface colour
constants. **Marks** moved from 600 individual nodes to one MultiMesh with per-instance alpha and
a 14 s fade, so the pool wrapping thins the oldest mark out instead of making it disappear.
*Owed follow-up: the new `@export`s (slip_ref, smoke_temp, mark_fade, …) have no tuning-panel rows
or HELP lines yet — `tuning_panel.gd` was held by the B2 session at the time. Add them when it is
free, per the convention.* **Not yet drive-tested — this is a visual change and only driving can
judge it.**

## 2026-08-13 (later — gravel lateral peak to 16 deg, and four sliders renamed)

**`peak_alpha_gravel` 14 -> 16 deg** (user's call, after the "feels good" verdict). Widens the
self-correcting window on gravel: the car stays on the RISING side of the lateral curve to 16 deg
of slip instead of 14, which is where a slide still pulls itself straight. Still inside realistic
gravel numbers.

**"Couldn't find the peak slip angle gravel slider" — four sliders were named almost identically.**
The panel sorts A-Z, and there were FOUR rows beginning "Peak slip", landing adjacent: "Peak slip
angle gravel/tarmac" (LATERAL, degrees of slip angle) and "Peak slip gravel/tarmac" (LONGITUDINAL,
% slip ratio). Two pairs governing completely different axes, distinguished only by the word
"angle" buried mid-label. Renamed so the axis is the first thing you read and the four still group
together:
`Grip peak LAT gravel` / `Grip peak LAT tarmac` (degrees) and `Grip peak LONG gravel` /
`Grip peak LONG tarmac` (% slip). The HELP lines now open with **TYRE, LATERAL (cornering)** or
**TYRE, LONGITUDINAL (drive/brake)** for the same reason. Audit after: 86 rows, no duplicate
labels, no row missing help, no orphaned help.
*Convention reinforced: when two tunables differ only by which AXIS they act on, the axis belongs
at the FRONT of the label, not buried in it.*

## 2026-08-13 (slide fix — new lever + a latent bug found)

**`_mf_peak_u` was silently clamping, putting the force peak in the wrong place.** Latent bug, no
symptom until now. The solve bisects over a hard-coded `[0, 60]` bracket, but the peak parameter
grows fast as the Pacejka shape factor C falls: C 1.65 -> ~4, 1.40 -> ~20, **1.20 -> ~73, 1.10 ->
~181**. Anything below C ~1.3 hit the ceiling, so the derived B came out too small and the force
peaked LATER than the exported angle asked for — measured 17.3 deg at C 1.20 and **42.3 deg at
C 1.10**, against a requested 14. It never bit before because Cx (1.65) and Cy (1.40) both sit
inside the bracket; it would have bitten the moment anyone lowered a shape factor. The bracket is
now derived from C instead of fixed, and the peak holds at 14.0 deg at every C tested.

**New lever for "the car lets go too easily once sideways": `cy_gravel`.** The lateral curve's
post-peak SHAPE is now a surface property, like its peak location already was. `Cy` is the tarmac
shape, `cy_gravel` the gravel one, both on the Tab panel, and `_lat_shape()` returns (B, C) per
wheel so the two stay consistent. **Default `cy_gravel` = 1.40 = identical to the previous car**,
verified — it is new tuning surface, not a feel change.
What it buys, measured as the RESTORING SLOPE per degree past the peak (negative = sliding more
gives less grip, so the slide amplifies itself): C 1.40 gives -0.0006 to -0.0011/deg, C 1.20 about
halves that to -0.0005/-0.0006, and C 1.10 nearly removes it at -0.0002/-0.0001. The peak stays
at 14 deg throughout, so this forgives an overshoot WITHOUT making the tyre unrealistically sticky.
**Framing that matters for tuning:** the dominant term is still `peak_alpha_gravel`, because it
decides where the strongly self-correcting region ENDS — the old By=10 car had roughly +0.006/deg
of restoring gradient still pulling at 25 deg, where the B4 car has -0.0009. `cy_gravel` shapes
what happens beyond the peak; `peak_alpha_gravel` decides where beyond starts.

## 2026-08-13 (B4 diagnosis — RESOLVED, see the entry above)

**"Much easier to lose control of the slide", "maintaining a good entry has got harder" after B4.**
**RESOLVED 2026-08-13 — re-drive verdict "feels good", on the UNCHANGED B4 defaults** (9/14 deg
peaks, `sigma_lat` 0.55, `cy_gravel` 1.40). The fix was the `cy_gravel` lever plus the
`_mf_peak_u` bracket bug above; the user did not need to move a slider in the end, and noted they
may tune again later. **If it comes back: `peak_alpha_gravel` first (it decides where the
self-correcting region ends), then `cy_gravel` (it shapes what happens past the peak).**
Measured cause: **the old fixed
`By = 10` put the lateral force peak at 114.8 degrees of slip angle**, i.e. beyond ANY angle a car
can reach. Every slip angle you could actually drive was on the RISING side of the curve, so grip
kept increasing the further you slid — at 40 deg you still had 0.988 of peak and climbing. The
tyre never let go, and a slide was always self-correcting.
B4's derived `By` moved the peak to **14 deg on gravel and 9 deg on tarmac** (realistic; real tyres
peak at 6–10 deg on tarmac). Past those angles the curve FALLS. So normal cornering moved from the
rising side to the falling side, and that flips the sign of the feedback: on the rising side more
slip gives more restoring force (self-correcting), on the falling side more slip gives less
(self-amplifying). **The magnitude of the drop is tiny — 0.989 of peak at 30 deg on gravel — so
this is not about losing grip, it is about losing the SLOPE that used to catch the car for you.**
Post-peak the curve settles at 0.809 of peak (set by `Cy` 1.40 via sin(Cy*pi/2)).
Secondary contributor: relaxation length adds ~28 ms of lag at 20 m/s before the correction
arrives (`sigma_lat` 0.55 m).
Levers, all on the Tab panel: `peak_alpha_gravel` / `peak_alpha_tarmac` (widen the stable window)
and `sigma_lat` (shorten the lag). If those are not enough the code option is a surface-dependent
`Cy` — a flatter curve on gravel, which forgives past the peak WITHOUT moving the peak.

## 2026-08-13 (B4 + B5)

**B4 — the car takes a set instead of darting.** Symptom this addresses: *"steering feels darty"*,
*"the car changes direction instantly"*, *"a Scandinavian flick can't be timed"*, and *"gravel and
tarmac break away the same way"*. Three changes.
**Relaxation length** (`sigma_lat`, 0.55 m): a tyre must ROLL about sigma metres before its lateral
force builds, so the force now follows a relaxed slip angle (`w.alpha_rel`) rather than the
instantaneous one. Expressed per distance rolled, not per second — measured 63% of a step reached
after **0.533 m at 8 m/s and 0.500 m at 30 m/s**, i.e. the same distance at very different speeds,
which is the proof it is a tyre property and not a frame-rate or speed artefact.
**Surface-derived `By`**: the fixed `By = 10` is gone. Lateral stiffness now derives from where
each surface peaks — `peak_alpha_tarmac` 9 deg, `peak_alpha_gravel` 14 deg — exactly as `Bx`
already did longitudinally. Measured peaks land on 9.0 and 14.0 deg exactly. Gravel now slides
deeper and more progressively before letting go; that gap IS the surface difference.
**CoM height** is an export (`com_height`, still -0.45) so raising it toward -0.30 is a slider A/B
rather than a code edit.
Stability checked on the STRAIGHT drag strip (the asphalt ring is curved, and testing there first
gave a false 0.544 rad/s "weave" that was just the road): peak yaw **0.000 rad/s at both 1 m/s and
250 km/h** — no shimmy, no weave.
`hs_blowoff` baked to **0.45** (user's call after the B2 drive).

**B5 — prune found nothing to prune, which is the point.** Every retired system had already been
cleaned up by the phase that retired it: `_t_drive`, `torque_rise_time`/`torque_fall_time` (A1),
`lsd_lock` (A3), `rear_grip_cut` and `brake_force` (A5), `spring_k`/`damper_c`/`arb_front`/
`arb_rear` (B1) and the interim single `zeta` (B2) are all absent from the code — the only
surviving mentions are comments explaining what was removed and why. Tuning panel audited: **83
spec rows, 83 HELP entries, zero rows missing help and zero orphaned entries.** The two M1-only
rows (`engine_power`, `launch_boost`) are deliberately kept — the panel skips any row whose
property the loaded car lacks, which is what lets one panel serve both vehicles.
`docs/ROADMAP.md` updated: M15 marked done, and the Tier-3 torque-delivery entry now carries an
explicit **"do not resurrect `_t_drive`"** warning, since that entry still describes a system A1
replaced and a future session reading it cold would otherwise rebuild it.

## 2026-08-13 (later still)

**B2 CLOSED — drive verdict: "feels good".** Asymmetric digressive damper accepted.

**Suspension travel cut from 500 mm to 320 mm — the "vertical budget" was never the problem.**
Symptom this closes: *"all four corners bottom out on the rally loop"*, *"suspension bottoming
going uphill at 100 km/h"*, and the instinct that follows it — *"the car needs more travel"* /
*"raise the ride height"*. It does not. Real gravel WRC cars run **250-300 mm of TOTAL wheel
travel**; this car had 500 mm, i.e. **373 mm of BUMP travel alone — more than a real rally car's
entire stroke — and it still pegged 100%**. Travel was never the constraint, and the ride-height
lever taken earlier (0.45 → 0.50) made it worse, not better. Ground clearance had reached 538 mm
against a real gravel car's ~300 mm.
Measured on the rally loop at ~100 km/h, 500 mm vs 320 mm: peak travel 100% in both, 4/4 corners
pegged in both, frames on the stops **50 → 177**, and — the counter-intuitive part — **peak Fz
28.8 kN → 23.1 kN**. Less travel produced LOWER peak loads, because the spring keeps building
force over the whole stroke: at full compression it made 12.1 kN of spring force at 500 mm
against 7.7 kN at 320 mm. The inflated travel was manufacturing its own load spikes.
Static sag is unchanged at 127 mm (springs untouched, B1 is drive-verified), so sag is now 40% of
total travel and bump travel is 193 mm; body clearance 358 mm.
**What to expect, and what NOT to diagnose as a bug:** the car now rides its bump stops often
(177 frames vs 50). That is correct — a real rally car on rough gravel is on the stops constantly.
It is also exactly why the stop wants to become **hydraulic** (velocity-sensitive, dissipating
energy as heat) instead of the current pure displacement spring, which stores the impact and
hands it straight back. That is the outstanding B3 revision, and it is now the ONLY remaining
suspect for bottoming harshness: B2 was tested and disproven as the fix (it cut peak load 23% but
slightly increased stop contact), and travel is ruled out by the numbers above.

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
