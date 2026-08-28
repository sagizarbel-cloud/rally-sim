extends RefCounted
class_name StageDef
## D3 — what a stage IS, as data (docs/PLAN-stages-ground-map.md §5 Phase D3).
##
## The generator takes one of these and solves geometry from it. Everything here is a STAGE
## PARAMETER with physical meaning, not a knob discovered by tuning: length in metres, design speed
## in km/h, sinuosity as a turn budget. That is the functions-over-constants answer to "what does a
## principled stage generator look like" - you describe the road you want and the constraints solve
## it, rather than placing corners by hand.
##
## A StageDef plus the code is a complete description of a stage: same def, same road, every time.
## That is §1.3's "the same stage twice is the same stage", and D3's probe 1 asserts it.

var seed: int = 20260828                  ## the whole stage derives from this; change it, change everything
var name: String = "SHAKEDOWN"

# --- shape -------------------------------------------------------------------------------------
var length_m: float = 1200.0              ## target road length. D3 stays short and static on purpose
                                          ## (§5: "cap it at ~1-1.5 km"); D4 replaces the BUILD step,
                                          ## not the generator, so this becomes a parameter not a rewrite.
var sinuosity: float = 0.55               ## 0 = nearly straight, 1 = as twisty as the design speed allows.
                                          ## Spends a TURN BUDGET; the min-radius constraint still binds.
var elevation_character: float = 0.6      ## 0 = flat valley floor, 1 = climbs and drops over ridges
var width_m: float = 7.5                  ## nominal road width; width_profile varies it along s
var width_var: float = 0.30               ## 0..1, how much the road pinches and opens along its length

# --- the constraint set (§3.2) -----------------------------------------------------------------
# R = V^2 / (127 * (e + f)) is the governing relation for a horizontal curve. These produce a road
# that LOOKS and FLOWS like a real one. Design speed is deliberately set BELOW the car's capability:
# a rally stage is a public road driven far beyond its design speed, and that mismatch IS the sport.
# Do not raise this to "make the stage faster" - raising it makes the road STRAIGHTER.
# 30 km/h -> R = 30.8 m, a normal narrow forest road. NOT arbitrary and NOT "slow": it is what the
# geometry admits, and it was measured. A lateral wiggle of amplitude A and wavelength L peaks at
# curvature A(2*PI/L)^2, so the minimum radius caps how much extra road length a given box can hold
# AND how many corners fit in it. Over this stage's 877 m spine, aiming at 1200 m of road:
#     60 km/h -> R 123.2 m -> infeasible (one U-turn alone costs 387 m)
#     40 km/h -> R  54.8 m -> ~4 corners, and the length target is unreachable
#     30 km/h -> R  30.8 m -> ~7 corners at the full 1200 m, in the same 720 m box
# A tighter design speed buys BOTH length and corner count, which is why real rally roads are
# low-design-speed roads. Raising this makes the stage STRAIGHTER and SHORTER, not faster.
var design_speed_kmh: float = 30.0
var max_grade: float = 0.12               ## the VERTICAL half of the constraint set: steepest
                                          ## longitudinal slope the road is built with. Mountain
                                          ## roads sit around 8-12%; raw terrain here reaches 33%,
                                          ## and a road that simply follows it reads as painted on
                                          ## rather than built. Enforcing it is what creates cut
                                          ## and fill, which is what makes a road look engineered.
# AASHTO's comfort criterion for vertical curves: the vertical acceleration a vehicle feels over a
# crest or through a sag should stay under ~0.3 m/s^2 at the design speed. That fixes the maximum
# vertical curvature at 0.3 / v^2, which is what stops a road from having KINKS in it. Without this
# the grade limiter produced a profile that respected 12% slope everywhere and still fed the
# suspension 9x the rally loop's peak d2y/ds2, because clamping a slope leaves a corner behind.
var vertical_comfort_accel: float = 0.3   ## m/s^2

var superelevation: float = 0.07          ## e, the banking the road is built with (7% is a normal max)
var side_friction: float = 0.16           ## f, the side-friction factor a road is designed against

# --- surface -----------------------------------------------------------------------------------
# Single-surface in D3. Mixed-surface transitions are D6 (§1.2 answer 5), and this is the field that
# will carry them - a profile along s rather than one class for the whole road.
var surface: StringName = &"dirt"

# --- authored control points (§1.2 answer 3) ---------------------------------------------------
# HARD constraints the generated centreline must pass through: an override layer on top of the
# generator, not a parallel system. Empty by default - the shipped stage is pure generation, and
# D3's probe 2 proves the mechanism works by pinning points and checking they are hit.
var control_points: PackedVector2Array = PackedVector2Array()
var control_tolerance_m: float = 2.0

# --- where the area sits ------------------------------------------------------------------------
# §1.1 is settled and not reopened: new maps go in a NEW area; the three circuits, the centre patch
# and the drag strip stay exactly as they are because every calibration baseline is expressed in
# their terms. This origin keeps the stage clear of the legacy map (which spans +-360 m plus the
# drag strip out to x = 4285).
var origin: Vector3 = Vector3(0.0, 0.0, -3000.0)
var area_size: float = 720.0              ## square side. The road WINDS inside this box rather than
                                          ## running across it, so a 1.2 km road needs no more terrain
                                          ## than the legacy map already builds - same mesh cost.
var area_cells: int = 320                 ## matches the legacy map's ~2.25 m/cell

# --- THE HEIGHTMAP-IMPORT SEAM (§5 D3: "Design it; do not build it") ---------------------------
# Elevation must be reachable through ONE function so that swapping the procedural source for an
# imported DEM is a one-place change. stage_gen.gd calls elevation_at() and nothing else, so an
# importer only has to set `elevation_source` to a Callable(x, z) -> float and everything
# downstream - routing, the corridor flatten, the mesh, the collider - follows automatically.
# NOT BUILT: there is no importer, no file format and no resampling here, by design.
var elevation_source: Callable = Callable()

func elevation_at(x: float, z: float) -> float:
	## The single elevation entry point. Returns metres. If an external source is set it wins;
	## otherwise the caller's procedural field is used (stage_gen passes one in via set_fallback).
	if elevation_source.is_valid():
		return float(elevation_source.call(x, z))
	if _fallback.is_valid():
		return float(_fallback.call(x, z))
	return 0.0

var _fallback: Callable = Callable()

func set_fallback(fn: Callable) -> void:
	_fallback = fn

# --- derived ------------------------------------------------------------------------------------

func min_radius_m() -> float:
	## R = V^2 / (127 * (e + f)), the AASHTO/FHWA horizontal-curve relation, V in km/h and R in m.
	## This is the generator's hard constraint: no corner tighter than a road of this design speed
	## would be built with.
	var v := maxf(design_speed_kmh, 5.0)
	return (v * v) / (127.0 * maxf(superelevation + side_friction, 0.01))

func max_vertical_curvature() -> float:
	var v := maxf(design_speed_kmh, 5.0) / 3.6      # m/s
	return vertical_comfort_accel / maxf(v * v, 1.0)

func max_curvature() -> float:
	return 1.0 / maxf(min_radius_m(), 1.0)

func duplicate_def() -> StageDef:
	var d := StageDef.new()
	d.seed = seed; d.name = name
	d.length_m = length_m; d.sinuosity = sinuosity
	d.elevation_character = elevation_character
	d.width_m = width_m; d.width_var = width_var
	d.design_speed_kmh = design_speed_kmh
	d.superelevation = superelevation; d.side_friction = side_friction
	d.max_grade = max_grade
	d.vertical_comfort_accel = vertical_comfort_accel
	d.surface = surface
	d.control_points = control_points.duplicate()
	d.control_tolerance_m = control_tolerance_m
	d.origin = origin; d.area_size = area_size; d.area_cells = area_cells
	d.elevation_source = elevation_source
	return d
