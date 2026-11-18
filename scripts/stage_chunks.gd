extends Node3D
class_name StageChunks
## D4 - the generated stage's ground, built as streamed CHUNKS instead of one static slab.
##
## Replaces StageArea._build(). The generator is untouched: every chunk asks `area.sample_at(x, z)`,
## the same pure function of world position and seed that D3's single mesh asked, so chunk contents
## cannot depend on load order (§0 repeatability, §5 probe 4) and a seam cannot be a discontinuity.
##
## WHAT THIS PHASE'S PLAN GOT WRONG, MEASURED BEFORE ANY OF THIS WAS WRITTEN (probe, 2026-08-30).
## §3.4 and the D4 prompt both say the collider COOK is the spike to design around. It is not:
##
##     32 cells (45.0 m span, 1089 verts):  sample_at 15.45 ms | mesh 0.60 ms | cook 0.11 ms
##     64 cells (90.0 m span, 4225 verts):  sample_at 64.27 ms | mesh 2.28 ms | cook 0.35 ms
##
## The cook is 0.5% of the cost. **96% of it is sample_at**, at 11.4 us per corridor vertex, because
## every vertex pays Centreline.nearest_point() - the provably-correct expanding ring search that
## 2026-08-28 installed after the old fixed 3x3 was found wrong at 9.85% of road-edge positions.
## That search is NOT to be traded away for a cheap local one: a stage with a hairpin folds back on
## itself inside a single chunk, which is exactly where a local search picks the wrong branch.
##
## So the spike is not avoided by cooking early - it is avoided by never doing a chunk's work in one
## frame. A build is a RESUMABLE JOB with a hard per-frame time budget, so the worst frame is
## bounded by that budget by construction rather than by hoping a cook lands between wheels. Lead
## distance is then derived from the MEASURED cost of a vertex, the budget, and the car's speed -
## see _derive(). Nothing here is a picked constant.

var area                                  ## StageArea - the height field authority
var car: Node3D
var forest: StageForest                   ## Arc E: the roadside spruces each chunk grows

# --- lattice -------------------------------------------------------------------------------------
# The chunk lattice is GLOBAL and shared by every chunk: vertex (i, j) of chunk k sits at world
# ((k.x * chunk_cells + i) * cell, ., (k.y * chunk_cells + j) * cell). Two neighbours therefore
# compute their shared edge from the IDENTICAL integer expression, so the seam is bit-exact rather
# than nearly-exact - which is what makes §5 probe 3 pass structurally instead of by tolerance.
# `cell` stays the area's own 1.40625 m: D3 found the road's edges stair-step at anything coarser
# (area_cells 320 -> 512 was the fix), and a height-field probe cannot see that - only a screenshot
# can. Chunking must not silently coarsen the corridor.
var cell := 1.40625
var chunk_cells := 32
var span := 45.0

# --- budgets and derived radii -------------------------------------------------------------------
var build_budget_ms := 1.0                ## main-thread build work allowed per physics tick
var chunk_budget := 256.0                 ## how many chunks may be RESIDENT (drawn) at once
var v_max := 66.0                         ## m/s the ground must stay ahead of (car's real top speed)
var r_solid := 0.0                        ## full detail + COLLIDER out to here
var r_detail := 0.0                       ## full detail, mesh only
var r_view := 0.0                         ## coarsest LOD ends here
var _tick := 1.0 / 120.0

# measured, and fed straight back into the lead distance
var _us_per_vertex := 12.0
## LIKE WITH LIKE. `_derive()` turns this into t_chunk, the time to build one FULL-DETAIL chunk whose
## every vertex pays the nearest_point search - the worst kind, and the kind the car is about to
## drive on. So that is the only kind of chunk allowed to move it.
## It used to be `max(this chunk's average, previous * 0.98)` over EVERY chunk. Off-road chunks cost
## ~1 us/vertex against ~12 on the road, so a run of cheap ones decayed the figure 20% in eleven
## chunks and the next road chunk snapped it back: it was tracking the MIX being built, not the
## machine. MEASURED (2026-11-16): 131 re-derives in 55 s of driving, r_solid swinging 65-100 m
## (72-103 m in the running game) and r_detail with it. Every one re-marked the far-field band
## (4 ms in one physics tick) and about every other one moved the band's edge by a whole chunk
## row. That is an 8-10 ms physics tick about twice a second while driving and five times a second
## during the fill after [B] - the "hiccups".
## The figure is now the worst cost seen TWICE among the last few comparable chunks: once could be
## a build the OS interrupted, twice is the machine. Do NOT "fix" a wandering radius by widening the
## 20% re-derive band in _finalise() - that hides the wobble and leaves the lead distance wrong.
var _cost_window := PackedFloat64Array()
const COST_WINDOW := 5
var _worst_build_ms := 0.0
var _peak_chunks := 0
var _built := 0

const LOD_STRIDES := [1, 2, 4]            ## chunk_cells must divide by the largest

var _live: Dictionary = {}                ## Vector2i -> {mi, col, lod}
var _job: Dictionary = {}                 ## the one resumable build in flight
var _mat: ShaderMaterial
var _derived_at_us := 12.0
var _prev_p := Vector3.ZERO
var _have_prev := false
## Chunks that have left the view are KEPT, hidden, instead of being destroyed. Every ArrayMesh
## this class creates has to be uploaded to the GPU the first time it is drawn, and that upload is
## invisible to physics timing and to average fps - which is exactly the shape of the drive report
## "hiccups but i didnt catch any fps drops". Measured before this cache existed: **30.6 new chunk
## meshes per second** while driving, most of them chunks being rebuilt rather than seen for the
## first time. A hidden MeshInstance3D keeps its mesh resident, so coming back costs nothing.
var _cache: Dictionary = {}               ## Vector3i(kx, kz, lod) -> record
var _cache_order: Array = []              ## least-recently-used first
## DERIVED from the resident budget, not picked. It was a hard-coded 256 - SMALLER than the live
## set it is meant to back (338 chunks at the default budget), so it could never hold the ground
## behind you and its own comment above ("coming back costs nothing") was simply untrue.
##
## MEASURED 2026-11-12 over a 1200 m out-and-back, each run from a cold cache:
##     cache 256  -> the return pass rebuilds 101% of the outbound, 156 MB
##     cache 1024 -> 43%, 195 MB
##     cache 2048 -> 30%, 271 MB, and the cache self-limits at ~1155 (the real working set)
## x4 the resident budget lands on 1024 at the default, which is most of the benefit for about a
## third of the extra memory. The cache is the memory ceiling §5 probe 2 cares about, so this is
## deliberately not "as big as possible".
##
## WHAT DOES NOT HELP, so nobody re-tries it: more LOD hysteresis. Measured at 1, 2 and 3 chunk
## spans the total build count is 1148 / 1164 / 1160 - flat. The LOD changes are not band-edge
## dithering, they are genuine transitions as the car drives past ground, so widening the band
## cannot remove them. 68% of all churn is a tile being rebuilt at a different detail.
var cache_max := 1024                     ## set by _derive() from chunk_budget; see above
var _cache_hits := 0
## ARC E: THE FAR FIELD IS A ROAD WINDOW, NOT A BAND OVER THE WHOLE ROUTE.
## Until 2026-11-17 everything within `band_w` of ANY part of the road was eligible, tested by
## straight-line distance - so wherever the route folds back on itself, ground belonging to road you
## drove ten minutes ago (or will drive in ten) sat inside the view radius and was built. MEASURED on
## the default seed, driving 1500 m at 30 m/s: ~600 chunks resident against a slider of 256, and 1909
## chunk builds. The band was also derived WIDE (band_w ~ 4 chunks a side) because a narrow band showed
## its own edge against the sky.
##
## The roadside forest (stage_forest.gd) is what makes a narrow window safe: a sight line through a
## forest survives with probability exp(-density * crown width * depth), which at the forest's own
## density and two chunks (90 m) of depth is ~1e-5. So the window is `band_chunks` chunks either side
## of the road - a slider, default 2 - and only along the stretch of road from `road_behind` metres
## behind the car to `road_ahead` metres ahead of it, MEASURED ALONG THE ROAD. Both lengths derive from
## the chunk budget: it now buys road LENGTH, not width.
##
## The window is re-marked only when the car's arc-length crosses a half-chunk quantum (the step the
## centreline is walked at), so it costs ~one marking per 22 m of road, not one per scan.
var band_chunks := 2              ## lateral reach of the window, whole chunks each side (Tab panel)
var road_ahead := 800.0           ## m of road ahead kept resident - derived in _derive()
var road_behind := 200.0          ## m of road behind - derived in _derive()
var _win: Dictionary = {}         ## Vector2i -> road priority (m); -1 = hysteresis margin, keep only
var _win_q := -(1 << 40)          ## the arc-length quantum the window was marked for
var _win_params := Vector3.ZERO   ## (ahead, behind, reach) it was marked with
var _s_car := 0.0                 ## the car's arc-length when the window was last marked

## AN IDLE STREAMER MUST COST NOTHING, and until 2026-11-16 it cost more than the car.
## `update()` re-asked the whole question on every tick that had no job in flight: walk every
## resident chunk for unloads, then every cell of the view window for wants - 338 + 1521 iterations
## of GDScript. MEASURED IN THE RUNNING GAME, per 16.7 ms frame (two ticks):
##     car PARKED on the start line, nothing left to build:  4.34 ms   (the car's own physics: 2.29)
##     far field filling after [B]:                          4.74 ms
##     car on the LEGACY map, where no chunk can be wanted:  2.25 ms
## So a quarter of every frame went on confirming that nothing had changed - and it was backwards
## under load: a late frame runs up to 8 catch-up ticks, and each one re-ran the scan.
##
## What should be built or dropped is a function of exactly two things: which chunks are resident,
## and where the car is. So the question is asked once per LATTICE CELL the car stands in, and the
## answer is kept as a work list (`_q_keys`) and a drop list (`_drops`). `cell` is the ground's own
## resolution - nothing the streamer builds can tell two positions inside one cell apart - so that
## is a derived quantum, not a tuned one. Taking the next entry off the list is not an approximation
## of rescanning: a chunk's priority depends only on its OWN state and distance, so the list IS
## what a rescan from the same cell would pick, in the same order. Probed against the per-tick scan
## along a driven path - see CHANGELOG 2026-11-16 for the count.
##
## NOT the fix, though it is the first thing to reach for: a timer ("rescan every N ticks"). That
## makes the ground late by a TIME, which at speed is a distance the lead-distance derivation in
## _derive() knows nothing about. A cell is a DISTANCE, and a fixed one.
## Nor is it fewer LOD levels: the scan costs the same with one.
var _scan_q := Vector2i(1 << 30, 1 << 30) ## the lattice cell the last scan was made from
var _scan_valid := false                  ## false once anything the scan read has changed
var _pq := Vector3.ZERO                   ## that cell's centre: the position every decision uses
var _q_keys := PackedInt64Array()         ## work list, nearest-first: (priority in um << 20) | index
var _q_cells: Array = []                  ## index -> chunk key, in scan order
var _q_at := 0
var _drops: Array = []                    ## chunks that scan found droppable, in _live's order
var _drops_at := 0
var _scans := 0
var _scan_us := 0                         ## cumulative time spent scanning, for probes and [J]
var _band_marks := 0
var _finalise_us := 0
var _scanned_r := PackedFloat64Array([0.0, 0.0, 0.0])   ## (r_solid, r_detail, r_view) that scan
                                          ## compared against - 64-bit: a Vector3 would round them

const EDGE_SHADER := """
shader_type spatial;
// The road edge is a DISTANCE FIELD carried in UV.x (metres outside the carriageway edge, negative
// on the road), thresholded HERE - per pixel - instead of per vertex. Interpolating an already
// thresholded colour puts the edge on the triangulation, which is the sawtooth D3 fixed once by
// raising resolution and which came straight back at 1.41 m/cell. This costs no extra vertices.
// D6 carries the SURFACE MIX in UV.y the same way - 0 gravel, 1 sealed - because it is the same
// kind of quantity: a field that must be read per pixel, not a class decided per vertex. It costs
// no extra attribute and no extra nearest_point search, since StageArea memoises that per position
// and sample_at has already paid for it at this very vertex.
// ARC E: `source_color`. Without the hint these sRGB colours were used AS LINEAR, which lifts every
// one of them - the gravel came out near-white and the grass pale (0.58 sRGB drawn as 0.58 linear is
// 0.79 on screen). That, more than any missing polygon, is why the stage looked washed out.
uniform vec3 grass_col : source_color;
uniform vec3 road_col : source_color;
uniform vec3 seal_col : source_color;
uniform vec3 litter_col : source_color = vec3(0.21, 0.17, 0.12);   // needle litter under spruce
uniform vec3 moss_col : source_color = vec3(0.24, 0.30, 0.14);
uniform float blend_m = 2.0;
uniform float forest_edge = 5.0;     // StageForest.clearance: where the trunks start
uniform float rut_pos = 1.3;         // StageArea.rut_pos: the wheel lines, metres inside each edge
varying float edge_d;
varying float mix_t;
varying vec3 wpos;
// Cheap value noise. Surface DETAIL with no textures: the ground is one colour per surface type,
// and real ground is never one colour. A few octaves at sizes from 0.3 m to 30 m break that up,
// and it costs a handful of ALU per pixel rather than texture bandwidth.
// Arithmetic hash (Hoskins' hash12): no sin(), which is a slow multi-instruction op on many GPUs
// and was evaluated 12 times per ground pixel. Per-pixel cost is what the fullscreen drive was bound by.
float hash2(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
			mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}
void vertex() {
	edge_d = UV.x;
	mix_t = UV.y;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = wpos.xz;
	float n_big = vnoise(p * 0.035);                 // ~30 m patches
	float n_mid = vnoise(p * 0.21 + 7.3);            // ~5 m
	float n_fine = vnoise(p * 2.7 + 1.9);            // ~0.4 m: individual stones / tufts
	// --- verge and forest floor ---
	vec3 g = grass_col * mix(0.82, 1.12, n_big) * mix(0.9, 1.08, n_mid);
	g = mix(g, g * vec3(1.08, 1.02, 0.80), smoothstep(0.55, 0.8, n_mid));    // dry yellow tufts
	// under the trees the grass gives way to needle litter and moss
	float wood = smoothstep(forest_edge - 1.0, forest_edge + 4.0, edge_d);
	vec3 floor_c = mix(litter_col, moss_col, smoothstep(0.35, 0.7, n_mid)) * mix(0.8, 1.15, n_fine);
	g = mix(g, floor_c, wood * 0.85);
	// --- the road ---
	vec3 gravel = road_col * mix(0.86, 1.10, n_big) * mix(0.84, 1.12, n_fine);
	// The wheel lines: traffic sweeps the loose stones off them, so they are darker and more
	// compacted; the crown and the edges keep a lighter loose layer.
	float lines = exp(-pow((edge_d + rut_pos) / 0.65, 2.0));
	gravel = mix(gravel, gravel * vec3(0.78, 0.76, 0.74), lines * 0.75);
	gravel = mix(gravel, gravel * 1.08, smoothstep(-0.6, 0.0, edge_d) * (1.0 - lines));
	vec3 seal = seal_col * mix(0.9, 1.06, n_big) * mix(0.94, 1.04, n_fine);
	vec3 surf = mix(gravel, seal, mix_t);
	float t = 1.0 - smoothstep(0.0, blend_m, edge_d + (n_mid - 0.5) * 0.8);
	ALBEDO = mix(g, surf, t);
	// Sealed road is a smoother surface than gravel, and only where it IS road.
	ROUGHNESS = mix(mix(0.95, 0.88, lines * t), 0.62, mix_t * t);
	SPECULAR = 0.35;
}
"""

## ARC E - THE BACKDROP. The road window ends a couple of chunks from the road, and past it there was
## nothing: from a crest, or from the chase camera over a rise, the world stopped at a ragged forest
## edge with the sky's ground colour below it. One coarse mesh of the base terrain under the whole
## stage, shaded as distant forest canopy, fills that - one draw call, a few thousand triangles, built
## once per stage. It sits BELOW the true ground by the most its coarse triangles can over-shoot the
## fine ground (measured at build), so the real chunks always cover it where they exist.
const BACKDROP_SHADER := """
shader_type spatial;
uniform vec3 canopy_col : source_color = vec3(0.13, 0.19, 0.12);
uniform vec3 canopy_hi : source_color = vec3(0.20, 0.27, 0.16);
varying vec3 wpos;
// Arithmetic hash (Hoskins' hash12): no sin(), which is a slow multi-instruction op on many GPUs
// and was evaluated 12 times per ground pixel. Per-pixel cost is what the fullscreen drive was bound by.
float hash2(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
			mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	// crowns ~5 m across, and stands of lighter and darker trees on a ~60 m scale
	float crowns = vnoise(wpos.xz * 0.2);
	float stands = vnoise(wpos.xz * 0.017 + 4.1);
	vec3 c = mix(canopy_col, canopy_hi, stands * 0.8) * mix(0.65, 1.1, crowns);
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
"""
var _backdrop: MeshInstance3D

func _build_backdrop() -> void:
	var t0 := Time.get_ticks_usec()
	var cells := 96
	var size: float = area._size * 1.6        # past the area's own edge, so the horizon is not a cliff
	var c0: Vector3 = area._origin - Vector3(size * 0.5, 0.0, size * 0.5)
	var step: float = size / float(cells)
	var n := cells + 1
	var hs := PackedFloat32Array(); hs.resize(n * n)
	for j in range(n):
		for i in range(n):
			hs[j * n + i] = area.def.elevation_at(c0.x + float(i) * step, c0.z + float(j) * step)
	# How far can a coarse triangle stand ABOVE the fine ground? Compare each cell's centre with the
	# interpolated value there; the worst over-shoot is how far the whole sheet is lowered.
	var drop := 0.0
	for j in range(cells):
		for i in range(cells):
			var a: int = j * n + i
			var mid: float = (hs[a] + hs[a + 1] + hs[a + n] + hs[a + n + 1]) * 0.25
			var real: float = area.def.elevation_at(c0.x + (float(i) + 0.5) * step, c0.z + (float(j) + 0.5) * step)
			drop = maxf(drop, mid - real)
	drop += 1.0
	var verts := PackedVector3Array(); verts.resize(n * n)
	var norms := PackedVector3Array(); norms.resize(n * n)
	for j in range(n):
		for i in range(n):
			var a: int = j * n + i
			verts[a] = Vector3(c0.x + float(i) * step, hs[a] - drop, c0.z + float(j) * step)
			var hx: float = hs[j * n + mini(i + 1, n - 1)] - hs[j * n + maxi(i - 1, 0)]
			var hz: float = hs[mini(j + 1, n - 1) * n + i] - hs[maxi(j - 1, 0) * n + i]
			norms[a] = Vector3(-hx, 2.0 * step, -hz).normalized()
	var idxs := PackedInt32Array()
	for j in range(cells):
		for i in range(cells):
			var a: int = j * n + i
			var bb: int = a + 1
			var c: int = a + n
			var d: int = a + n + 1
			idxs.append_array([a, bb, c, bb, d, c])     # same winding as the chunks: top is the front
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var sh := Shader.new()
	sh.code = BACKDROP_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	mesh.surface_set_material(0, m)
	_backdrop = MeshInstance3D.new()
	_backdrop.name = "Backdrop"
	_backdrop.mesh = mesh
	_backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_backdrop.visible = false            # _scan() shows it once the car is on the stage
	add_child(_backdrop)
	_backdrop_info = {"drop": drop, "ms": float(Time.get_ticks_usec() - t0) / 1000.0}

var _backdrop_info := {}

func _ready() -> void:
	var sh := Shader.new()
	sh.code = EDGE_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	# Passed as COLOR, not Vector3: a `source_color` uniform is converted from sRGB only when it is
	# given a Color. A Vector3 goes in raw - the second half of why the stage was washed out.
	_mat.set_shader_parameter("grass_col", area.grass_color)
	_mat.set_shader_parameter("road_col", area.road_color)
	_mat.set_shader_parameter("seal_col", area.seal_color)

# ---------------------------------------------------------------- derived sizes

func configure() -> void:
	cell = area._cs
	# The quantum lives on the DEF (see StageDef.ground_bounds): the road's ends and the tunnel's
	# transition pad both have to know where the built ground stops, and that is set by this number
	# together with `cell`. Keeping a second copy here is what let them disagree by 25 m.
	chunk_cells = area.def.chunk_cells
	span = float(chunk_cells) * cell
	_tick = 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	if forest == null and area.gen != null and (car == null or bool(car.get("stage_forest") != false)):
		forest = StageForest.new(area)
	if forest != null:
		_mat.set_shader_parameter("forest_edge", forest.clearance)
	else:
		_mat.set_shader_parameter("forest_edge", 1e6)       # no forest: no needle-litter floor
	_mat.set_shader_parameter("rut_pos", area.rut_pos)
	if _backdrop == null:
		_build_backdrop()
	if car != null and car.has_method("top_speed_kmh"):
		# The ground has to be solid at any speed the CAR can reach, not at a speed we hope it
		# drives. Taking the car's own derived top speed means re-gearing the car re-derives this.
		v_max = maxf(float(car.top_speed_kmh()) / 3.6, 30.0)
	_derive()

func _derive() -> void:
	## r_solid: the radius inside which the ground must already be built and collidable.
	## A chunk costs (chunk_cells/lod + 3)^2 vertices - the +3 is the one-vertex APRON on each side
	## that lets normals use a true central difference at the chunk edge, which is what stops a
	## normal discontinuity showing as a crease along every seam. At `build_budget_ms` per tick, one
	## chunk takes t_chunk seconds of wall time; the car covers v_max * t_chunk in that time. The
	## radius must cover one whole chunk beyond that, because the car enters a chunk at its edge.
	# The retire cache scales with the resident budget: it exists to hold the ground just behind
	# you, and "how much ground is around you" is exactly what chunk_budget sets. x4 is the measured
	# knee - see cache_max's own comment for the sweep and for what does NOT work.
	cache_max = int(maxf(chunk_budget, 1.0) * 4.0)
	var verts := float(chunk_cells + 3) * float(chunk_cells + 3)
	var work_s: float = verts * _us_per_vertex * 1e-6
	var ticks_needed: float = work_s / maxf(build_budget_ms * 1e-3, 1e-6)
	var t_chunk: float = ticks_needed * _tick
	# QUEUE_DEPTH: turning onto a new heading can make several chunks newly required at once, and
	# they are built one after another. A car crossing a chunk diagonally touches at most 3 new
	# chunks per span, so 4 is the depth that covers the worst turn with a chunk in hand.
	var queue_depth := 4.0
	# NOTHING can usefully reach past the area's own edge - there is no ground out there to build.
	# Both radii are bounded by it BEFORE anything derives from them, because `_us_per_vertex` is
	# measured and can spike: a spike inflates t_chunk, r_solid and r_detail together, and r_detail
	# then leaked past this ceiling through the clampf below (see there). Measured escaping to
	# 7893 m in a 4000 m area, which put 1543 chunks resident where the default holds ~340.
	var r_max: float = area._size * 0.5
	r_solid = minf(span + v_max * t_chunk * queue_depth, r_max)
	# Beyond the solid shell the ground is scenery: no collider, and detail falls off in strides.
	r_detail = minf(r_solid * 2.0, r_max)
	# (r_view used to be derived from a TRIANGLE budget for a disc of rings. Arc E bounds the far
	# field by the chunk budget along a road window instead - see _mark_window - and r_view is now
	# just the straight-line ceiling of that window, set below.)
	# `chunk_budget` draw calls is this subsystem's share; the static area it replaces used one
	# mesh, but one mesh cannot stream. It defaults to the 256 D4 was accepted at and is on the Tab
	# panel so a performance run can sweep it - it is the ONE number that says how much ground is
	# resident, and every far-field size below derives from it.
	#
	# Beyond r_detail the far field is CORRIDOR-ONLY, so the budget no longer buys a disc - it buys
	# LENGTH OF ROAD, which is what you actually see when driving. A full disc out to R costs
	# pi*R^2/span^2 chunks; a corridor costs (corridor width / span + 1) x (road length in R) / span,
	# and a winding road covers roughly 1.3 R of length per R of radius. That is why the view can now
	# reach kilometres instead of ~400 m for the same draw calls - the drive verdict asked for the
	# continuation to stop popping in, and this is where the budget for it came from.
	# HOW FAR YOU SEE is a driving horizon, not a disc: you should be able to see roughly the next
	# twelve seconds of road at the speed the car can actually reach, which is what stops the
	# continuation arriving in front of you. Everything LEFT of the budget after that then goes into
	# how WIDE the far field is, because a narrow band shows its own edge.
	var disc_chunks: float = PI * (r_detail + span) * (r_detail + span) / (span * span)
	# ARC E - the budget left after the disc buys ROAD LENGTH. A window `band_chunks` wide either side
	# covers (2 * reach + 1) chunks per chunk-span of road, so that is the price of a metre of road.
	# Ahead gets the driving horizon (twelve seconds at the car's top speed, as before); behind gets
	# what is left, capped at a quarter of ahead - enough for the chase camera and the mirror, which
	# look back over a few hundred metres at most.
	var reach: int = maxi(band_chunks, 1)
	var per_m: float = float(2 * reach + 1) / span
	var road_len: float = maxf((chunk_budget - disc_chunks) / per_m, span * 4.0)
	road_ahead = minf(v_max * 12.0, road_len * 0.8)
	road_behind = clampf(road_len - road_ahead, span, road_ahead * 0.25)
	# clampf(value, MIN, MAX) returns MIN when MIN > MAX - verified: clampf(791, 7893, 2000) = 7893.
	# So writing the area's edge as the MAX here did not bound anything once r_detail passed it; the
	# ceiling quietly stopped applying exactly when it was needed. r_detail is now bounded above, so
	# min <= max holds by construction and this reads as intended.
	# r_view is now only the straight-line CEILING on anything the window can hold: road ahead can be
	# no further away in a straight line than its length along the road, plus the window's width.
	r_view = clampf(road_ahead + span * float(reach + 1), r_detail, r_max)
	# The window is marked in whole chunks along a quantised arc-length, so it only has to be redone
	# when one of the three numbers it was marked with actually moves. _finalise() re-derives
	# whenever the measured vertex cost drifts 20% (see _cost_window), and re-marking on every
	# call was a measured 4 ms spike in a physics tick under the old band (CHANGELOG 2026-11-16).
	var wp := Vector3(road_ahead, road_behind, float(reach))
	if wp != _win_params:
		_win_q = -(1 << 40)
		_scan_valid = false
	# ...and the last scan's answer is void only if a radius it compared against actually moved.
	if r_solid != _scanned_r[0] or r_detail != _scanned_r[1] or r_view != _scanned_r[2]:
		_scan_valid = false
	_derived_at_us = _us_per_vertex

func lod_for(d: float, have: int = 0) -> int:
	## 0 means "not resident". Distance is measured to the chunk's nearest point, not its centre, so
	## a chunk is not demoted because its far corner is far away.
	##
	## HYSTERESIS ON THE LOD BANDS, not just on unloading. Without it a chunk sitting near a band
	## edge is rebuilt every time the car breathes across it: measured on the first driven run,
	## 702 chunk builds in the first 155 m of a 4.9 km stage, against ~245 resident - i.e. most of
	## the streamer's budget went on rebuilding ground that was already there at a different detail.
	## The margin is one whole chunk span, the same scale the unload hysteresis uses. It is ONE-SIDED
	## deliberately: a chunk resists being COARSENED, but is refined the moment it is close enough,
	## because detail arriving late is something the driver can see and detail leaving late is not.
	var m: float = span
	if d <= r_detail + (m if have == 1 else 0.0):
		return 1
	if d <= r_detail * 2.0 + (m if have == 2 else 0.0):
		return 2
	if d <= r_view:
		return 4
	return 0

# ---------------------------------------------------------------- streaming

func chunk_origin(k: Vector2i) -> Vector3:
	return Vector3(float(k.x * chunk_cells) * cell, 0.0, float(k.y * chunk_cells) * cell)

func key_at(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / span)), int(floor(z / span)))

func _dist_to_chunk(k: Vector2i, p: Vector3) -> float:
	var o := chunk_origin(k)
	var dx: float = maxf(maxf(o.x - p.x, p.x - (o.x + span)), 0.0)
	var dz: float = maxf(maxf(o.z - p.z, p.z - (o.z + span)), 0.0)
	return sqrt(dx * dx + dz * dz)

func _mark_window(p: Vector3) -> void:
	## Which chunks beyond the full-detail disc may exist: those within `band_chunks` of the road
	## between `road_behind` behind the car and `road_ahead` ahead of it, measured ALONG the road.
	## Each gets a priority = metres of road to reach it (behind counts double: ground you are
	## leaving matters less than ground you are about to see), so the work list builds forward road
	## first. A margin of one chunk-span of road past each end is marked "keep, do not build" (-1):
	## that is the window's hysteresis, so a car parked on a quantum boundary cannot thrash the
	## window's end chunks in and out.
	var cl = area.gen.centreline if area.gen != null else null
	if cl == null:
		return
	var step: float = span * 0.5
	var np: Dictionary = cl.nearest_point(p.x, p.z)
	var q: int = int(floor(float(np["s"]) / step))
	var reach: int = maxi(band_chunks, 1)
	var wp := Vector3(road_ahead, road_behind, float(reach))
	if q == _win_q and wp == _win_params:
		return
	_win_q = q
	_win_params = wp
	_band_marks += 1
	_win.clear()
	var s_c: float = (float(q) + 0.5) * step
	_s_car = s_c
	var length: float = cl.length()
	var lo: float = maxf(s_c - road_behind - span, 0.0)
	var hi: float = minf(s_c + road_ahead + span, length)
	var s: float = lo
	while true:
		var pos: Vector3 = cl.point_at(s)["pos"]
		var ds: float = s - s_c
		var inner: bool = ds >= -road_behind and ds <= road_ahead
		var pri: float = ds if ds >= 0.0 else -ds * 2.0
		var c := key_at(pos.x, pos.z)
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var kk := Vector2i(c.x + dx, c.y + dz)
				var old: float = _win.get(kk, -2.0)
				if inner:
					if old < 0.0 or pri < old:
						_win[kk] = pri
				elif old == -2.0:
					_win[kk] = -1.0
		if s >= hi:
			break
		s = minf(s + step, hi)

func _want_lod(k: Vector2i, d: float, have: int) -> int:
	## The full LOD rule in one place: detail by distance, and beyond the driveable disc only where
	## the road window goes (see _mark_window).
	var l := lod_for(d, have)
	if l == 0:
		return 0
	if d > r_detail:
		var w: float = _win.get(k, -2.0)
		if w == -2.0:
			return 0
		if w < 0.0:
			return have            # the window's margin: keep what is there, build nothing new
	return l

func _in_area(k: Vector2i) -> bool:
	## Chunks exist only INSIDE the generated area, exactly as D3's single slab did.
	## Without this the streamer follows the car around the LEGACY map and builds this stage's
	## landform on top of the rally loop - measured on the first run: 293 chunks of SHAKEDOWN
	## terrain built 3 km from the stage, over the circuits that §1.1 says stay untouched.
	var o := chunk_origin(k)
	var half: float = area._size * 0.5
	var ax0: float = area._origin.x - half
	var ax1: float = area._origin.x + half
	var az0: float = area._origin.z - half
	var az1: float = area._origin.z + half
	return o.x + span > ax0 and o.x < ax1 and o.z + span > az0 and o.z < az1

func prime(p: Vector3) -> void:
	## Everything the car could touch, built NOW. The car spawns into this, so it cannot be streamed
	## in behind it - it would fall through the world for the first few frames.
	# Colliders are judged from where the car is ABOUT to be, and whatever the last scan concluded
	# is void: this changes what is resident behind its back.
	_pq = _cell_centre(_cell_of(p))
	_scan_valid = false
	var r := int(ceil(r_solid / span)) + 1
	var c := key_at(p.x, p.z)
	var want: Array = []
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := Vector2i(c.x + dx, c.y + dz)
			var d := _dist_to_chunk(k, p)
			if d > r_solid or not _in_area(k):
				continue
			if _live.has(k) and int(_live[k]["lod"]) == 1:
				continue          # already full detail; re-priming must not rebuild it
			want.append([d, k])
	want.sort_custom(func(a, b): return a[0] < b[0])
	for w in want:
		_build_chunk(w[1], 1)

func update(p: Vector3) -> void:
	## One resumable job at a time, nearest-first, within a hard per-tick budget.
	if _backdrop != null:
		# The backdrop is 1.6x the area, so it reaches 800 m past the stage's ground on every side -
		# which puts its northern strip over the legacy map's south half, at SHAKEDOWN's elevation,
		# with no collider: "a big square with dark green color all over the map, which sometimes
		# clips the starting area, and has no hitbox" (2026-11-18). It is only ever needed from
		# inside the stage, so it is drawn only while the car is on (or just off) the stage ground.
		_backdrop.visible = StageDef.depth_in(area._gb, p.x, p.z) > -2.0 * span
	# A RESPAWN is a teleport, not driving: pressing [B] for SHAKEDOWN moves the car 3 km in one
	# tick, and the budgeted path would take seconds to lay a solid shell under it - the car would
	# fall through the world while it built. A jump further than the shell itself means none of the
	# shell can be reused, which is exactly the condition for priming again.
	if _have_prev and p.distance_to(_prev_p) > r_solid:
		_job = {}
		prime(p)
		_prev_p = p
		return
	_prev_p = p
	_have_prev = true
	if not _job.is_empty():
		_step_job()
		return
	# Ask again only if the answer can have changed: the car is in a different lattice cell, or
	# something the last scan read has moved under it (a re-derive, a prime). See `_scan_q`.
	var q := _cell_of(p)
	if not _scan_valid or q != _scan_q:
		_scan(q)
	# UNLOADING IS WORK TOO. Freeing a chunk frees an ArrayMesh and possibly a HeightMapShape3D, and
	# a tick that drops a dozen at once pays for all of them at end-of-frame - so the build budget
	# alone does not bound the worst frame. Cap it: chunks leave the disc at about v/span per second
	# (~0.4/s at 18 m/s), so two per TICK is 240/s - two orders of magnitude more headroom than the
	# rate needs, while still bounding the spike.
	var freed := 0
	while freed < 2 and _drops_at < _drops.size():
		var dk: Vector2i = _drops[_drops_at]
		_drops_at += 1
		if _live.has(dk):
			_unload(dk)
			freed += 1
	_next_job()

func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / cell)), int(floor(p.z / cell)))

func _cell_centre(q: Vector2i) -> Vector3:
	return Vector3((float(q.x) + 0.5) * cell, 0.0, (float(q.y) + 0.5) * cell)

func _beyond_reach(p: Vector3) -> bool:
	## True when the car is so far from the generated area that NO chunk in it can be wanted at any
	## detail - which is the whole time it is on the legacy map, 2-4 km away. Exact, not a shortcut:
	## past max(r_view, 2 r_detail + span) lod_for() answers 0 whatever is resident, and a chunk only
	## has to OVERLAP the area (see _in_area), so it can stand one span outside the box.
	var half: float = area._size * 0.5
	var dx: float = maxf(absf(p.x - area._origin.x) - half, 0.0)
	var dz: float = maxf(absf(p.z - area._origin.z) - half, 0.0)
	return sqrt(dx * dx + dz * dz) > maxf(r_view, r_detail * 2.0 + span) + span

func _scan(q: Vector2i) -> void:
	## The whole question, asked from the centre of lattice cell `q`: what is droppable, which
	## colliders are due, and everything that wants building - sorted, so the ticks that follow only
	## have to take the next entry.
	var t_scan := Time.get_ticks_usec()
	_scan_q = q
	_scan_valid = true
	_scanned_r[0] = r_solid
	_scanned_r[1] = r_detail
	_scanned_r[2] = r_view
	_scans += 1
	_pq = _cell_centre(q)
	_q_keys.clear()
	_q_cells.clear()
	_q_at = 0
	_drops.clear()
	_drops_at = 0
	var p := _pq
	if not _beyond_reach(p):
		_mark_window(p)
	for k in _live:
		# HYSTERESIS is one whole chunk span. That is the natural scale here rather than a tuned
		# margin: a chunk only becomes droppable once the car is a full chunk past the radius that
		# would re-request it, so sitting on a boundary cannot thrash a chunk in and out.
		var dk: float = _dist_to_chunk(k, p)
		if dk > r_view + span:
			_drops.append(k)
		elif dk > r_detail + span and not _win.has(k):
			_drops.append(k)      # off the road window: behind the forest, or road long gone
	var c := key_at(p.x, p.z)
	if not _live.is_empty():
		# keep colliders in step with the car over the small set that could possibly need one
		var rc := int(ceil((r_solid + span) / span)) + 1
		for dz in range(-rc, rc + 1):
			for dx in range(-rc, rc + 1):
				var kk := Vector2i(c.x + dx, c.y + dz)
				if _live.has(kk):
					_sync_collider(kk)
	if _beyond_reach(p):
		_scan_us += Time.get_ticks_usec() - t_scan
		return
	# Candidates are the full-detail disc's block plus the road window - nothing else can be wanted
	# (_want_lod), so nothing else is walked. The old loop walked the whole (2 r_view / span)^2 view
	# square, 1521 cells, and spent ~2.3 ms a scan doing it (MEASURED 2026-11-17, see CHANGELOG).
	var near := int(ceil(r_detail / span)) + 1
	for dz in range(-near, near + 1):
		for dx in range(-near, near + 1):
			_consider(Vector2i(c.x + dx, c.y + dz), p)
	for k in _win:
		if absi(k.x - c.x) <= near and absi(k.y - c.y) <= near:
			continue                       # already considered as part of the disc
		_consider(k, p)
	_q_keys.sort()
	_scan_us += Time.get_ticks_usec() - t_scan

func _consider(k: Vector2i, p: Vector3) -> void:
	if not _in_area(k):
		return
	var d := _dist_to_chunk(k, p)
	var have: int = int(_live[k]["lod"]) if _live.has(k) else 0
	var want_lod := _want_lod(k, d, have)
	if want_lod == 0 or have == want_lod:
		return
	# Inside the disc, nearest first. Beyond it, by metres of ROAD to reach it, so the road ahead
	# is built before ground to the side or behind - never less than the straight distance, so the
	# two orderings agree where they meet.
	var pri: float = d
	if d > r_detail:
		pri = maxf(d, float(_win.get(k, d)))
	# A chunk that is merely too COARSE can wait behind one that does not exist at all.
	if have != 0:
		pri += r_view
	# Sorted natively: the priority in micrometres above the scan index, so equal
	# priorities keep scan order - the same chunk the old first-minimum search picked.
	_q_keys.append((int(pri * 1e6) << 20) | _q_cells.size())
	_q_cells.append(k)

func _next_job() -> void:
	while _q_at < _q_keys.size():
		var k: Vector2i = _q_cells[_q_keys[_q_at] & 0xFFFFF]
		_q_at += 1
		# Re-ask the one question for this one chunk. Nothing but this list's own work touches a
		# listed chunk between scans, so this only ever skips an entry already satisfied.
		var have: int = int(_live[k]["lod"]) if _live.has(k) else 0
		var want_lod := _want_lod(k, _dist_to_chunk(k, _pq), have)
		if want_lod == 0 or have == want_lod:
			continue
		if _restore(k, want_lod):
			return                     # it was still in the cache: no rebuild, no GPU re-upload
		_start_job(k, want_lod)
		_step_job()
		return

func _restore(k: Vector2i, lod: int) -> bool:
	var ck := Vector3i(k.x, k.y, lod)
	if not _cache.has(ck):
		return false
	var rec: Dictionary = _cache[ck]
	var mi: Node = rec["mi"]
	if not is_instance_valid(mi):
		_cache.erase(ck)
		_cache_order.erase(ck)
		return false
	_cache.erase(ck)
	_cache_order.erase(ck)
	if _live.has(k):
		_unload(k)
	mi.visible = true
	rec["col"] = null
	_live[k] = rec
	_cache_hits += 1
	_peak_chunks = maxi(_peak_chunks, _live.size())
	if lod == 1:
		_sync_collider(k)
	return true

func _sync_collider(k: Vector2i) -> void:
	## A collider exists only where a wheel can reach. Hysteresis is a whole chunk span on the way
	## out, so parking on the boundary cannot cook and drop the same shape every tick.
	var rec: Dictionary = _live[k]
	if int(rec["lod"]) != 1:
		return
	# From the position the scan was made for, not the car's raw one: every decision between two
	# scans has to be a function of the same cell, or the work list stops being exact.
	var d: float = _dist_to_chunk(k, _pq)
	var has: bool = rec["col"] != null
	if not has and d <= r_solid:
		var hh: PackedFloat32Array = rec["h"]
		var n: int = chunk_cells + 1
		if hh.size() != n * n:
			return
		var o := chunk_origin(k)
		var shape := HeightMapShape3D.new()
		shape.map_width = n
		shape.map_depth = n
		shape.map_data = hh
		var col := CollisionShape3D.new()
		col.name = "K%d_%d" % [k.x, k.y]
		col.shape = shape
		col.scale = Vector3(cell, 1.0, cell)
		col.position = Vector3(o.x + span * 0.5, 0.0, o.z + span * 0.5)
		area.add_child(col)
		rec["col"] = col
		# ...and the chunk's tree trunks, solid over exactly the same ground.
		if forest != null and rec.has("trunks"):
			var tb: StaticBody3D = forest.trunk_body(rec["trunks"])
			if tb != null:
				tb.name = "T%d_%d" % [k.x, k.y]
				area.add_child(tb)
			rec["tcol"] = tb
	elif has and d > r_solid + span:
		var c: Node = rec["col"]
		if is_instance_valid(c):
			c.queue_free()
		rec["col"] = null
		_free_trunks(rec)

func _unload(k: Vector2i) -> void:
	## Retire a chunk into the cache rather than destroying it. The collider IS freed - a physics
	## shape is cheap to rebuild from the heights we keep, and shapes are not free to hold - but the
	## mesh is only hidden, so its GPU upload survives.
	var rec: Dictionary = _live[k]
	var col: Node = rec["col"]
	if col != null and is_instance_valid(col):
		col.queue_free()
	rec["col"] = null
	_free_trunks(rec)
	_live.erase(k)
	var mi: Node = rec["mi"]
	if not is_instance_valid(mi):
		return
	mi.visible = false
	var ck := Vector3i(k.x, k.y, int(rec["lod"]))
	if _cache.has(ck):
		_evict(ck)
	_cache[ck] = rec
	_cache_order.append(ck)
	while _cache_order.size() > cache_max:
		_evict(_cache_order[0])

func _free_trunks(rec: Dictionary) -> void:
	var tb = rec.get("tcol")
	if tb != null and is_instance_valid(tb):
		tb.queue_free()
	rec["tcol"] = null

func _evict(ck: Vector3i) -> void:
	_cache_order.erase(ck)
	if not _cache.has(ck):
		return
	var rec: Dictionary = _cache[ck]
	var mi: Node = rec["mi"]
	if is_instance_valid(mi):
		mi.queue_free()
	_cache.erase(ck)

# ---------------------------------------------------------------- the resumable build

func _start_job(k: Vector2i, lod: int) -> void:
	var n: int = chunk_cells / lod + 1          # mesh vertices per side
	var ax: int = n + 2                         # + the one-vertex apron for seam-exact normals
	var h := PackedFloat32Array(); h.resize(ax * ax)
	var b := PackedFloat32Array(); b.resize(ax * ax)
	var e := PackedFloat32Array(); e.resize(ax * ax)
	var m := PackedFloat32Array(); m.resize(ax * ax)     # D6 surface mix, 0 gravel .. 1 sealed
	_job = {"k": k, "lod": lod, "n": n, "ax": ax, "h": h, "b": b, "e": e, "m": m, "i": 0, "us": 0}

func _build_chunk(k: Vector2i, lod: int) -> void:
	## Synchronous, used ONLY by prime(). Everything after startup goes through the budgeted path.
	_start_job(k, lod)
	_step_job(1 << 30)

func _step_job(budget_us: int = -1) -> void:
	if budget_us < 0:
		budget_us = int(build_budget_ms * 1000.0)
	var t0 := Time.get_ticks_usec()
	var k: Vector2i = _job["k"]
	var lod: int = _job["lod"]
	var ax: int = _job["ax"]
	var h: PackedFloat32Array = _job["h"]
	var b: PackedFloat32Array = _job["b"]
	var e: PackedFloat32Array = _job["e"]
	var m: PackedFloat32Array = _job["m"]
	var i: int = _job["i"]
	var total: int = ax * ax
	var base_x: int = k.x * chunk_cells
	var base_z: int = k.y * chunk_cells
	while i < total:
		var jj: int = i / ax
		var ii: int = i % ax
		# apron index -1 .. n, so the lattice offset is (ii - 1) * lod
		var x: float = float(base_x + (ii - 1) * lod) * cell
		var z: float = float(base_z + (jj - 1) * lod) * cell
		var s: Vector3 = area.sample_at(x, z)
		h[i] = s.x
		b[i] = s.y
		e[i] = s.z
		# D6. FREE at this point and nowhere else: sample_at has just done this vertex's
		# nearest_point search and StageArea memoises it per position, so asking for the surface mix
		# here costs a float compare. Asking anywhere else would pay the 11.4 us search twice.
		m[i] = area.road_mix_at(x, z)
		i += 1
		if (i & 63) == 0 and Time.get_ticks_usec() - t0 >= budget_us:
			break
	_job["i"] = i
	_job["us"] = int(_job["us"]) + (Time.get_ticks_usec() - t0)
	if i >= total:
		_finalise()

func _finalise() -> void:
	var t0 := Time.get_ticks_usec()
	var k: Vector2i = _job["k"]
	var lod: int = _job["lod"]
	var n: int = _job["n"]
	var ax: int = _job["ax"]
	var h: PackedFloat32Array = _job["h"]
	var b: PackedFloat32Array = _job["b"]
	var e: PackedFloat32Array = _job["e"]
	var m: PackedFloat32Array = _job["m"]
	var step: float = cell * float(lod)
	var o := chunk_origin(k)
	# Vertex positions come from the INTEGER lattice index, exactly as _step_job sampled them, not
	# from origin + i*step. `a*c + b*c` and `(a+b)*c` are not the same float: when the area grew to
	# 4 km the cell size stopped being exactly representable (720/512 = 1.40625 is, 4000/2844 is
	# not) and the two forms drifted apart by an ulp - a 0.000488 m seam step where there had been
	# exactly zero. Integer index first, one multiply, so neighbours compute a shared edge from an
	# identical expression again.
	var bx: int = k.x * chunk_cells
	var bz: int = k.y * chunk_cells

	var verts := PackedVector3Array(); verts.resize(n * n)
	var norms := PackedVector3Array(); norms.resize(n * n)
	var cols := PackedColorArray(); cols.resize(n * n)
	var uvs := PackedVector2Array(); uvs.resize(n * n)
	var heights := PackedFloat32Array(); heights.resize(n * n)
	for j in range(n):
		for i in range(n):
			var aj: int = j + 1
			var ai: int = i + 1
			var idx: int = j * n + i
			var hh: float = h[aj * ax + ai]
			verts[idx] = Vector3(float(bx + i * lod) * cell, hh, float(bz + j * lod) * cell)
			heights[idx] = hh
			cols[idx] = area.grass_color.lerp(area.road_color, b[aj * ax + ai])
			# the edge distance field and the D6 surface mix, both thresholded per pixel
			uvs[idx] = Vector2(e[aj * ax + ai], m[aj * ax + ai])
			# TRUE central difference at every vertex INCLUDING the border, because the apron
			# supplies the neighbour that lives in the next chunk. Without it the edge row falls
			# back to a one-sided difference and every seam reads as a crease under a low sun -
			# the exact "stencil breaks at a spacing discontinuity" trap D3 hit three times.
			var hx: float = h[aj * ax + ai + 1] - h[aj * ax + ai - 1]
			var hz: float = h[(aj + 1) * ax + ai] - h[(aj - 1) * ax + ai]
			norms[idx] = Vector3(-hx, 2.0 * step, -hz).normalized()

	var idxs := PackedInt32Array()
	for j in range(n - 1):
		for i in range(n - 1):
			var a: int = j * n + i
			var bb: int = j * n + i + 1
			var c: int = (j + 1) * n + i
			var d: int = (j + 1) * n + i + 1
			# WOUND SO THE TOP IS THE FRONT FACE - copied from stage.gd / stage_area.gd, not
			# re-derived. Reversing these makes the terrain invisible from above and solid from
			# below, which this project has now hit three times and which looks like a shader bug.
			idxs.append_array([a, bb, c, bb, d, c])

	if lod > 1:
		_add_skirt(verts, norms, cols, uvs, idxs, n)

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, _mat)
	var mi := MeshInstance3D.new()
	mi.name = "C%d_%d" % [k.x, k.y]
	mi.mesh = mesh
	add_child(mi)
	# Arc E: the chunk's trees, read off the same sample arrays - no extra road search.
	var trunks := PackedVector4Array()
	if forest != null:
		var g: Dictionary = forest.grow(k, lod, h, e, ax, step, o, span)
		forest.attach(mi, g, lod)
		trunks = g["trunks"]

	# Collider only where a wheel can REACH, which is r_solid - not everywhere the ground is drawn at
	# full detail. Cooking one for every full-detail chunk put 79 heightfields in the physics world
	# when ~12 can ever be touched; the cook is cheap (0.11 ms) but the shapes are not free to keep.
	if _live.has(k):
		_unload(k)
	# Heights are KEPT for full-detail chunks so a collider can be attached or dropped later without
	# rebuilding the chunk. 33x33 floats is 4.4 kB; rebuilding to gain a collider would be 15 ms.
	_live[k] = {"mi": mi, "col": null, "lod": lod, "h": heights if lod == 1 else PackedFloat32Array(),
		"trunks": trunks if lod == 1 else PackedVector4Array(), "tcol": null}
	if lod == 1:
		_sync_collider(k)
	_peak_chunks = maxi(_peak_chunks, _live.size())

	# Feed the MEASURED cost straight back into the lead distance, so r_solid tracks what a chunk
	# actually costs on this machine rather than what it cost when this was written.
	# The lead must cover the WORST kind of chunk, not the average one: chunks away from the road
	# cost ~1 us/vertex and corridor chunks 11.4. So only a chunk of that worst kind - full detail,
	# every vertex searched - is allowed to move the figure, and it takes the worst cost seen TWICE
	# among the last few of them. See _cost_window for what the per-chunk max-with-decay that used
	# to live here actually did (it tracked the mix, and the radii swung with it).
	var total_us: float = float(int(_job["us"]) + (Time.get_ticks_usec() - t0))
	if lod == 1 and e.count(StageArea.OFF_CORRIDOR) == 0:
		# A comparable chunk: full detail, every vertex searched. See _cost_window.
		_cost_window.append(total_us / float(ax * ax))
		if _cost_window.size() > COST_WINDOW:
			_cost_window.remove_at(0)
		if _cost_window.size() >= 2:
			var sorted := _cost_window.duplicate()
			sorted.sort()
			_us_per_vertex = sorted[sorted.size() - 2]
	_worst_build_ms = maxf(_worst_build_ms, float(Time.get_ticks_usec() - t0) / 1000.0)
	_finalise_us += Time.get_ticks_usec() - t0
	_built += 1
	_job = {}
	# Re-derive only when the measured cost has actually MOVED. Re-deriving on a fixed build count
	# shifted the LOD radii several times a second, which by itself put chunks back across band
	# edges and fed the rebuild churn the hysteresis above exists to stop.
	if _us_per_vertex > _derived_at_us * 1.2 or _us_per_vertex < _derived_at_us * 0.8:
		_derive()

# ---------------------------------------------------------------- introspection (probes + HUD)

func _add_skirt(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray,
		uvs: PackedVector2Array, idxs: PackedInt32Array, n: int) -> void:
	## A COARSE chunk's edge is a chord between every lod-th lattice point, while its full-detail
	## neighbour keeps the points in between - so the two surfaces meet only at the shared vertices
	## and can part company between them. That is a crack you can see through to the sky.
	##
	## Rather than stitch (which needs to know the neighbour's level, and so re-cracks whenever that
	## changes), hang a vertical curtain from the coarse chunk's border. The DEPTH is derived from
	## this chunk's own geometry, not picked: a chord across one coarse cell cannot depart from the
	## surface by more than the height change across that cell, so the largest step between adjacent
	## border vertices bounds the worst gap. x2 for the two sides it could open on.
	var edge: Array = []
	for i in range(n):
		edge.append(i)                            # top row    j = 0
	for j in range(1, n):
		edge.append(j * n + (n - 1))              # right column
	for i in range(n - 2, -1, -1):
		edge.append((n - 1) * n + i)              # bottom row
	for j in range(n - 2, 0, -1):
		edge.append(j * n)                        # left column
	var drop := 0.0
	for e in range(edge.size()):
		var a: int = edge[e]
		var b: int = edge[(e + 1) % edge.size()]
		drop = maxf(drop, absf(verts[a].y - verts[b].y))
	drop = maxf(drop * 2.0, 0.05)
	var base := verts.size()
	for e in range(edge.size()):
		var src: int = edge[e]
		var v: Vector3 = verts[src]
		verts.append(Vector3(v.x, v.y - drop, v.z))
		norms.append(Vector3(0.0, 1.0, 0.0))
		cols.append(cols[src])
		uvs.append(uvs[src])
	for e in range(edge.size()):
		var e2: int = (e + 1) % edge.size()
		var a: int = edge[e]
		var b: int = edge[e2]
		var al: int = base + e
		var bl: int = base + e2
		# The border was walked clockwise seen from above, so this winding puts the curtain's front
		# face OUTWARD. Getting it backwards makes the skirt invisible from outside and visible from
		# inside - the same class of mistake as the terrain winding bug, just on a vertical surface.
		idxs.append_array([a, al, b, b, al, bl])

func stats() -> Dictionary:
	return {"live": _live.size(), "peak": _peak_chunks, "built": _built, "budget": chunk_budget,
		"us_per_vertex": _us_per_vertex, "worst_finalise_ms": _worst_build_ms,
		"r_solid": r_solid, "r_detail": r_detail, "r_view": r_view, "span": span,
		"colliders": _collider_count(), "cached": _cache.size(), "cache_hits": _cache_hits,
		"scans": _scans, "queued": _q_keys.size() - _q_at, "scan_us": _scan_us,
		"band_marks": _band_marks, "finalise_us": _finalise_us, "window": _win.size(),
		"road_ahead": road_ahead, "road_behind": road_behind, "band_chunks": band_chunks}

func _collider_count() -> int:
	var c := 0
	for k in _live:
		if _live[k]["col"] != null:
			c += 1
	return c
