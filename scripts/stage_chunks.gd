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
var v_max := 66.0                         ## m/s the ground must stay ahead of (car's real top speed)
var r_solid := 0.0                        ## full detail + COLLIDER out to here
var r_detail := 0.0                       ## full detail, mesh only
var r_view := 0.0                         ## coarsest LOD ends here
var _tick := 1.0 / 120.0

# measured, and fed straight back into the lead distance
var _us_per_vertex := 12.0
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
var _band: Dictionary = {}
var _band_built := false
var band_w := 200.0        ## far-field band half-width, derived in _derive()

const EDGE_SHADER := """
shader_type spatial;
// The road edge is a DISTANCE FIELD carried in UV.x (metres outside the carriageway edge, negative
// on the road), thresholded HERE - per pixel - instead of per vertex. Interpolating an already
// thresholded colour puts the edge on the triangulation, which is the sawtooth D3 fixed once by
// raising resolution and which came straight back at 1.41 m/cell. This costs no extra vertices.
uniform vec3 grass_col;
uniform vec3 road_col;
uniform float blend_m = 2.0;
varying float edge_d;
void vertex() {
	edge_d = UV.x;
}
void fragment() {
	float t = 1.0 - smoothstep(0.0, blend_m, edge_d);
	ALBEDO = mix(grass_col, road_col, t);
	ROUGHNESS = 1.0;
}
"""

func _ready() -> void:
	var sh := Shader.new()
	sh.code = EDGE_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("grass_col", Vector3(area.grass_color.r, area.grass_color.g, area.grass_color.b))
	_mat.set_shader_parameter("road_col", Vector3(area.road_color.r, area.road_color.g, area.road_color.b))

# ---------------------------------------------------------------- derived sizes

func configure() -> void:
	cell = area._cs
	span = float(chunk_cells) * cell
	_tick = 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
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
	var verts := float(chunk_cells + 3) * float(chunk_cells + 3)
	var work_s: float = verts * _us_per_vertex * 1e-6
	var ticks_needed: float = work_s / maxf(build_budget_ms * 1e-3, 1e-6)
	var t_chunk: float = ticks_needed * _tick
	# QUEUE_DEPTH: turning onto a new heading can make several chunks newly required at once, and
	# they are built one after another. A car crossing a chunk diagonally touches at most 3 new
	# chunks per span, so 4 is the depth that covers the worst turn with a chunk in hand.
	var queue_depth := 4.0
	r_solid = span + v_max * t_chunk * queue_depth
	# Beyond the solid shell the ground is scenery: no collider, and detail falls off in strides.
	r_detail = r_solid * 2.0
	# r_view is a RENDERING budget, not a physical distance, so it is derived from what the static
	# area it replaces already cost and the user already accepted: one 512x512-cell mesh over a
	# 720 m square = 524288 triangles, and one draw call per chunk. Whichever budget binds first
	# wins. In practice the draw-call budget does, and it gives ~400 m of visible ground - more
	# than the legacy area shows in any direction from its centre.
	# The reference is D3's ACCEPTED static area - a 512x512-cell mesh over a 720 m square - not the
	# current box, which D4 has grown to 4 km. Deriving the budget from the current box would let the
	# rendering cost grow with the stage, which is the thing streaming exists to prevent.
	var tri_budget := 2.0 * 512.0 * 512.0
	var tri_per_m2_full := 2.0 / (cell * cell)
	# rings: full inside r_detail, then stride 2, then stride 4 out to r_view
	var tri_inner: float = PI * r_detail * r_detail * tri_per_m2_full
	var r_mid := r_detail * 2.0
	var tri_mid: float = PI * (r_mid * r_mid - r_detail * r_detail) * tri_per_m2_full / 4.0
	var left: float = maxf(tri_budget - tri_inner - tri_mid, 0.0)
	var r_tri: float = sqrt(maxf(left * 16.0 / (PI * tri_per_m2_full) + r_mid * r_mid, 0.0))
	# 256 draw calls is this subsystem's share; the static area it replaces used one mesh, but one
	# mesh cannot stream.
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
	r_view = clampf(v_max * 12.0, r_detail, area._size * 0.5)
	r_view = minf(r_view, r_tri)
	# A winding road covers about 1.3 m of length per metre of radius, so this many chunks lie ALONG
	# the far field; the remaining draw calls set how many lie ACROSS it.
	var along: float = maxf(1.3 * (r_view - r_detail) / span, 1.0)
	var across: float = maxf((256.0 - disc_chunks) / along, 3.0)
	band_w = across * span * 0.5
	_band_built = false          # the band depends on band_w, so it has to be re-marked
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

func _build_band() -> void:
	## Which CHUNKS the far field may contain: everything within `band_w` of the road, marked once by
	## walking the centreline. Reusing area.near_road() for this was wrong - that mask is sized for
	## collision queries (~53 m), so the far field came out as a 106 m ribbon with a hard jagged edge
	## where the world simply stopped, which looks worse than the dead space it replaced.
	_band.clear()
	var cl = area.gen.centreline
	if cl == null:
		return
	var reach: int = maxi(int(ceil(band_w / span)), 1)
	var s := 0.0
	while s <= cl.length():
		var p: Dictionary = cl.point_at(s)
		var pos: Vector3 = p["pos"]
		var c := key_at(pos.x, pos.z)
		for dx in range(-reach, reach + 1):
			for dz in range(-reach, reach + 1):
				_band[Vector2i(c.x + dx, c.y + dz)] = true
		s += span * 0.5
	_band_built = true

func _near_corridor(k: Vector2i) -> bool:
	if not _band_built:
		_build_band()
	return _band.has(k)

func _want_lod(k: Vector2i, d: float, have: int) -> int:
	## The full LOD rule in one place: detail by distance, and beyond the driveable shell only where
	## the road actually goes.
	var l := lod_for(d, have)
	if l == 0:
		return 0
	if d > r_detail and not _near_corridor(k):
		return 0
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
	var r := int(ceil(r_view / span)) + 1
	var c := key_at(p.x, p.z)
	# unload first: cheap, and it frees the memory before the next build claims it
	var drop: Array = []
	for k in _live:
		# HYSTERESIS is one whole chunk span. That is the natural scale here rather than a tuned
		# margin: a chunk only becomes droppable once the car is a full chunk past the radius that
		# would re-request it, so sitting on a boundary cannot thrash a chunk in and out.
		var dk: float = _dist_to_chunk(k, p)
		if dk > r_view + span:
			drop.append(k)
		elif dk > r_detail + span and not _near_corridor(k):
			drop.append(k)      # dead space to the sides of the road: scenery nobody looks at
	# UNLOADING IS WORK TOO. Freeing a chunk frees an ArrayMesh and possibly a HeightMapShape3D, and
	# a tick that drops a dozen at once pays for all of them at end-of-frame - so the build budget
	# alone does not bound the worst frame. Cap it: chunks leave the disc at about v/span per second
	# (~0.4/s at 18 m/s), so two per TICK is 240/s - two orders of magnitude more headroom than the
	# rate needs, while still bounding the spike.
	var freed := 0
	for k in drop:
		if freed >= 2:
			break
		_unload(k)
		freed += 1
	# keep colliders in step with the car over the small set that could possibly need one
	var rc := int(ceil((r_solid + span) / span)) + 1
	for dz in range(-rc, rc + 1):
		for dx in range(-rc, rc + 1):
			var kk := Vector2i(c.x + dx, c.y + dz)
			if _live.has(kk):
				_sync_collider(kk)

	var best_k := Vector2i.ZERO
	var best_d := INF
	var best_lod := 0
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := Vector2i(c.x + dx, c.y + dz)
			if not _in_area(k):
				continue
			var d := _dist_to_chunk(k, p)
			var have: int = int(_live[k]["lod"]) if _live.has(k) else 0
			var want_lod := _want_lod(k, d, have)
			if want_lod == 0:
				continue
			if have == want_lod:
				continue
			# A chunk that is merely too COARSE can wait behind one that does not exist at all.
			var pri: float = d if have == 0 else d + r_view
			if pri < best_d:
				best_d = pri
				best_k = k
				best_lod = want_lod
	if best_lod > 0:
		_start_job(best_k, best_lod)
		_step_job()

func _sync_collider(k: Vector2i) -> void:
	## A collider exists only where a wheel can reach. Hysteresis is a whole chunk span on the way
	## out, so parking on the boundary cannot cook and drop the same shape every tick.
	var rec: Dictionary = _live[k]
	if int(rec["lod"]) != 1:
		return
	var d: float = _dist_to_chunk(k, car.global_position) if car != null else 0.0
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
	elif has and d > r_solid + span:
		var c: Node = rec["col"]
		if is_instance_valid(c):
			c.queue_free()
		rec["col"] = null

func _unload(k: Vector2i) -> void:
	var rec: Dictionary = _live[k]
	var mi: Node = rec["mi"]
	if is_instance_valid(mi):
		mi.queue_free()
	var col: Node = rec["col"]
	if col != null and is_instance_valid(col):
		col.queue_free()
	_live.erase(k)

# ---------------------------------------------------------------- the resumable build

func _start_job(k: Vector2i, lod: int) -> void:
	var n: int = chunk_cells / lod + 1          # mesh vertices per side
	var ax: int = n + 2                         # + the one-vertex apron for seam-exact normals
	var h := PackedFloat32Array(); h.resize(ax * ax)
	var b := PackedFloat32Array(); b.resize(ax * ax)
	var e := PackedFloat32Array(); e.resize(ax * ax)
	_job = {"k": k, "lod": lod, "n": n, "ax": ax, "h": h, "b": b, "e": e, "i": 0, "us": 0}

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
			uvs[idx] = Vector2(e[aj * ax + ai], 0.0)     # the edge distance field, thresholded per pixel
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

	# Collider only where a wheel can REACH, which is r_solid - not everywhere the ground is drawn at
	# full detail. Cooking one for every full-detail chunk put 79 heightfields in the physics world
	# when ~12 can ever be touched; the cook is cheap (0.11 ms) but the shapes are not free to keep.
	if _live.has(k):
		_unload(k)
	# Heights are KEPT for full-detail chunks so a collider can be attached or dropped later without
	# rebuilding the chunk. 33x33 floats is 4.4 kB; rebuilding to gain a collider would be 15 ms.
	_live[k] = {"mi": mi, "col": null, "lod": lod, "h": heights if lod == 1 else PackedFloat32Array()}
	if lod == 1:
		_sync_collider(k)
	_peak_chunks = maxi(_peak_chunks, _live.size())

	# Feed the MEASURED cost straight back into the lead distance, so r_solid tracks what a chunk
	# actually costs on this machine rather than what it cost when this was written.
	# The lead must cover the WORST chunk, not the average one. Chunks away from the road cost
	# ~1 us/vertex and corridor chunks 11.4, so an average is dominated by the cheap ones and would
	# shrink the lead exactly when the car is on the road - where the ground has to be there. Track
	# the worst seen, with a slow decay so the figure can still come down on a lighter machine.
	var total_us: float = float(int(_job["us"]) + (Time.get_ticks_usec() - t0))
	_us_per_vertex = maxf(total_us / float(ax * ax), _us_per_vertex * 0.98)
	_worst_build_ms = maxf(_worst_build_ms, float(Time.get_ticks_usec() - t0) / 1000.0)
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
	return {"live": _live.size(), "peak": _peak_chunks, "built": _built,
		"us_per_vertex": _us_per_vertex, "worst_finalise_ms": _worst_build_ms,
		"r_solid": r_solid, "r_detail": r_detail, "r_view": r_view, "span": span,
		"colliders": _collider_count()}

func _collider_count() -> int:
	var c := 0
	for k in _live:
		if _live[k]["col"] != null:
			c += 1
	return c
