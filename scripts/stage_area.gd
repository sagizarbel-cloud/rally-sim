extends StaticBody3D
class_name StageArea
## D3 — a generated stage, built as its OWN AREA (docs/PLAN-stages-ground-map.md §5 Phase D3, §1.1).
##
## §1.1 is settled: new maps go in a NEW area and the legacy map is preserved untouched as the
## calibration bed, because every baseline this project owns - drag-strip top speed, rally-loop lap
## feel, B3's bottoming statistics, A2's coast-down figures - is expressed in its terms. So this is
## additive: a separate body, a separate mesh, a separate collider, sharing nothing with stage.gd
## but the ground map it registers a layer with.
##
## Being a self-contained node is also the shape D5 wants, since the area manager loads and unloads
## whole areas. §5 D3's file list says stage.gd "becomes able to build a generated stage"; building
## it as its own node instead is a deliberate deviation, made because an area that can be unloaded
## in one piece is what D5 actually needs, and folding it into stage.gd would have to be undone.
##
## Static and short by design (§5): one heightmap, no streaming. D4 replaces the BUILD step, not
## the generator.

var gen: StageGen                        ## owns the centreline and the elevation field
var def: StageDef

@export var shoulder := 6.0              ## metres of blend from road edge out to open terrain
@export var bank_gain := 3.0             ## superelevation: camber follows local curvature, as the
                                         ## legacy road does, so corners lean INTO the turn
@export var bank_max := 0.08
# --- berms and ruts: what a gravel road looks like after cars have used it -----------------------
# Traffic pushes material OUT of the corners, so it piles into a berm just past the road edge, and
# wears grooves along the edges of the used width. Both are lateral-profile features, so they live
# in height_at() alongside the corridor blend rather than being separate geometry.
@export var berm_height := 0.28          ## ridge height just outside the road edge (m).
                                         ## 0.55 drove as too aggressive; halved on the drive verdict.
@export var berm_pos := 1.1              ## how far past the edge the ridge peaks (m)
@export var berm_width := 1.6            ## ridge falloff width (m) - the "1-2 m" asked for
@export var berm_corner_gain := 0.7      ## extra berm on the OUTSIDE of a corner, where material goes
@export var rut_depth := 0.11            ## groove worn along each edge of the used width (m)
@export var rut_pos := 1.3               ## how far inside the road edge the groove sits (m)
@export var rut_width := 1.2             ## groove width (m)
@export var grass_color := Color(0.40, 0.42, 0.25)
@export var road_color := Color(0.58, 0.51, 0.39)

# Coarse occupancy of the road corridor, built by walking the centreline once. Without it, building
# the mesh asks nearest_point() about all 103k terrain vertices, and for a vertex 500 m from the road
# the provably-correct ring search expands ~38 rings before it can stop - which took the build from
# instant to minutes. Most of the area is nowhere near the road, and this says so in one hash lookup.
var _corridor: Dictionary = {}
var _corridor_cell := 24.0
var _cs := 0.0
var _n := 0
var _size := 0.0
var _origin := Vector3.ZERO

var car                                  # set by world.gd: watched for live stage-parameter edits
var chunks: StageChunks                  # D4: the streamed ground
var _pending := 0.0
var _last_params: Array = []

func _process(delta: float) -> void:
	## Live regeneration. The drive checklist asks the user to change `seed` and see a genuinely
	## different stage, and to change `sinuosity` and feel the character move - neither is testable
	## if the parameters only exist in code. Rebuilding terrain is not a per-slider-tick operation,
	## so edits are DEBOUNCED: move the slider freely, and the stage rebuilds once you stop.
	if car == null:
		return
	# The parameters travel as an ARRAY, never a Vector4. Vector4 stores 32-bit floats, and that
	# quietly broke the one promise this panel makes - "same seed = same stage, exactly":
	#   * the seed is a ~2e7 integer, where float32 spacing is 2, so every ODD seed was rounded to
	#     an even neighbour. Half of all seeds were unreachable and seed N vs N+1 gave the SAME road.
	#   * sinuosity 0.85 round-trips through float32 as 0.850000023841858, so the FIRST rebuild
	#     silently built a different road from the one the identical-looking parameters had built at
	#     startup - measured: the startup road and a rebuild with untouched sliders had different
	#     centrelines. That also made returning to a seed unable to reproduce its own stage.
	# GDScript int and float are both 64-bit, so an Array carries all four exactly.
	var now: Array = [int(car.stage_seed), float(car.stage_sinuosity),
			float(car.stage_elevation), float(car.stage_design_speed)]
	if _last_params.is_empty():
		# First tick: the area is ALREADY built from these values by _ready(). Recording them without
		# arming the debounce is what stops a spurious rebuild ~0.55 s into every session, which used
		# to throw away the road _ready() had just built and (see above) replace it with a different one.
		_last_params = now
		return
	if now != _last_params:
		_last_params = now
		_pending = 0.55
		return
	if _pending <= 0.0:
		return
	_pending -= delta
	if _pending <= 0.0:
		_regenerate(now)

func _regenerate(p: Array) -> void:
	def.seed = int(p[0])
	def.sinuosity = float(p[1])
	def.elevation_character = float(p[2])
	def.design_speed_kmh = float(p[3])
	gen = StageGen.new(def)
	gen.generate()
	_corridor.clear()
	for c in get_children():
		c.queue_free()
	_mark_corridor()
	_build()
	_build_markers()
	emit_signal("regenerated")

signal regenerated

func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	_size = def.area_size
	_n = def.area_cells + 1
	_cs = _size / float(def.area_cells)
	_origin = def.origin
	_mark_corridor()
	_build()
	_build_markers()

# ---------------------------------------------------------------- the ground

func _mark_corridor() -> void:
	var cl := gen.centreline
	if cl == null:
		return
	_corridor_cell = def.width_m * 0.5 + shoulder + 8.0
	var s := 0.0
	var stepm := _corridor_cell * 0.4
	while s <= cl.length():
		var p: Dictionary = cl.point_at(s)
		var pos: Vector3 = p["pos"]
		var k := _ckey(pos.x, pos.z)
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				_corridor[Vector2i(k.x + dx, k.y + dz)] = true
		s += stepm

func _ckey(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / _corridor_cell)), int(floor(z / _corridor_cell)))

func near_road(x: float, z: float) -> bool:
	return _corridor.has(_ckey(x, z))

func height_at(x: float, z: float) -> float:
	return sample_at(x, z).x

func _road_blend(x: float, z: float) -> float:
	return sample_at(x, z).y

func sample_at(x: float, z: float) -> Vector3:
	## (height, road blend, EDGE DISTANCE) from ONE nearest_point call.
	##
	## The third component is metres OUTSIDE the carriageway edge (negative = on the road). It exists
	## so the chunk mesh can carry a DISTANCE FIELD per vertex and threshold it per PIXEL, instead of
	## carrying an already-thresholded colour and letting the rasteriser interpolate that. Those are
	## not the same picture: a thresholded colour interpolated across a triangle puts the road edge on
	## the triangulation, which is the sawtooth the driver sees. `d` is near-linear across a quad, so
	## thresholding it in the fragment shader gives a smooth curve at the SAME vertex count.
	##
	## D4 measured why this is one function and not two: nearest_point costs 11.4 us on the corridor
	## - 96% of everything a chunk vertex costs, against 0.08 us for the collider cook the plan
	## warned about - and building a chunk needs BOTH the height and the colour blend at every
	## vertex. Asking separately paid that 11.4 us twice. Returns a Vector2 rather than a Dictionary
	## deliberately: D1 measured a Dictionary on a per-vertex path at 0.487 ms/tick against 0.153 for
	## the same work returned by value.
	## Base terrain, with the road corridor cut into it. The road holds the elevation the generator
	## solved for (grade-limited, so it is NOT simply the terrain height) and the ground blends up or
	## down to meet it over `shoulder` metres - which is where the cut and fill becomes visible.
	var base: float = def.elevation_at(x, z)
	if gen == null or gen.centreline == null or not near_road(x, z):
		return Vector3(base, 0.0, 999.0)
	var np := gen.centreline.nearest_point(x, z)
	var lat: float = absf(float(np["lateral"]))
	var half: float = float(np["width"]) * 0.5
	var blend: float = 1.0 - smoothstep(half, half + 2.0, lat)
	if lat >= half + shoulder:
		return Vector3(base, blend, lat - half)
	var s: float = float(np["s"])
	var road: Dictionary = gen.centreline.point_at(s)
	var road_y: float = (road["pos"] as Vector3).y
	var signed: float = float(np["lateral"])

	# SUPERELEVATION. Two things here were the "jagged edges" bug, both measured:
	#   - the curvature came straight from the nearest SAMPLE, a numerical second difference that
	#     swings 70% of its range over 2 m of road, so neighbouring terrain vertices banked
	#     differently. It now comes from gen.bank_curvature_at(), smoothed over the superelevation
	#     runoff length.
	#   - the lever arm was the full lateral distance, out to the far edge of the shoulder, which
	#     amplified that noise the further you got from the road. Superelevation is a property of
	#     the CARRIAGEWAY, so the arm is clamped to the road half-width.
	# Together these took the worst transverse height step from 0.56 m to well under the legacy
	# road's own figure.
	var k: float = gen.bank_curvature_at(s)
	var bank := clampf(k * bank_gain, -bank_max, bank_max) * clampf(signed, -half, half)
	var t := 1.0 - smoothstep(half, half + shoulder, lat)
	var h := lerpf(base, road_y + bank, t)

	# BERM: material pushed out of the corners piles just past the road edge, and piles MORE on the
	# outside of a corner than the inside - which is the side that gets pushed.
	var outside: float = 1.0 if signed * k < 0.0 else 0.0
	var bh: float = berm_height * (1.0 + berm_corner_gain * outside * clampf(absf(k) / maxf(def.max_curvature(), 1e-5), 0.0, 1.0))
	var bd: float = lat - half - berm_pos
	h += bh * exp(-(bd * bd) / maxf(berm_width * berm_width, 0.01))

	# RUT: a groove worn along each edge of the used width. Shallow, and INSIDE the road, so it is
	# something the car runs a wheel into rather than a wall.
	# Ruts sit a FIXED distance from the centreline, not from the edge: they are where wheels run,
	# and the road's width profile varies along its length, so pinning them to the edge made them
	# snake in and out - which showed up as along-road wobble at a fixed offset.
	var rd: float = lat - maxf(def.width_m * 0.5 - rut_pos, 0.0)
	h -= rut_depth * exp(-(rd * rd) / maxf(rut_width * rut_width, 0.01)) * t
	return Vector3(h, blend, lat - half)

func on_road(x: float, z: float) -> bool:
	if gen == null or gen.centreline == null or not near_road(x, z):
		return false
	var np := gen.centreline.nearest_point(x, z)
	return absf(float(np["lateral"])) < float(np["width"]) * 0.5 + 1.0

func in_area(x: float, z: float) -> bool:
	## Cheap bounding test. The ground map calls this FIRST on every classification query, so that
	## driving on the legacy map costs one box test rather than a centreline lookup.
	var half := _size * 0.5
	return absf(x - _origin.x) <= half and absf(z - _origin.z) <= half

func spawn_transform() -> Transform3D:
	## At the BEGINNING of the run-up, facing down the road - so you launch, cross the start line,
	## and the clock starts on the line rather than under the car. Same idea as the legacy circuits'
	## `start_runup`.
	##
	## Orientation uses looking_at, NOT a hand-rolled atan2. The first version computed
	## `atan2(h.x, h.y)`, which spawned the car facing exactly BACKWARDS: a Y-rotation by theta puts
	## forward at (-sin, 0, -cos), so matching a heading (h.x, h.y) needs atan2(-h.x, -h.y). Godot's
	## forward is -Z and looking_at already knows that, so it cannot get the sign wrong.
	## SPAWN 45 m BEFORE THE START LINE, not at s = 0. D5 extended the run-up to reach the map edge,
	## so s = 0 is now the boundary - and the tunnel's transition pad sits on it. Spawning there put
	## the car INSIDE the pad with no way out ("when spawning i spawned inside the transition pad and
	## couldnt get out"). Measuring back from the START GATE instead keeps the launch exactly as it
	## always was, however long the approach becomes.
	var cl := gen.centreline
	var s_spawn: float = clampf(gen.timed_start_s - 45.0, 0.0, cl.length())
	var p0: Dictionary = cl.point_at(s_spawn)
	var pos: Vector3 = p0["pos"]
	var h: Vector2 = p0["heading"]
	var origin := Vector3(pos.x, height_at(pos.x, pos.z) + 1.8, pos.z)
	var fwd := Vector3(h.x, 0.0, h.y).normalized()
	return Transform3D(Basis(), origin).looking_at(origin + fwd, Vector3.UP)

# ---------------------------------------------------------------- build

func _build() -> void:
	## D4: the ground is STREAMED now. This used to build one 513x513 mesh and one HeightMapShape3D
	## over the whole 720 m box, which is why the stage could only ever be ~900 m long - a 5 km
	## stage in one slab is 18 billion cells at the 1.41 m the road edges need. The chunk manager
	## owns the same height function; see scripts/stage_chunks.gd for why the cost that forced this
	## design is sample_at() and not the collider cook the plan expected.
	chunks = StageChunks.new()
	chunks.name = "Chunks"
	chunks.area = self
	chunks.car = car
	add_child(chunks)
	chunks.configure()
	chunks.prime(_prime_point())

func attach_car(c) -> void:
	## world.gd wires the car AFTER the area is in the tree, so _ready() has already primed the
	## ground from the spawn point. Re-derive once the car exists, because the lead distance comes
	## from the car's own top speed - re-gear the car and the streamer follows.
	car = c
	if chunks != null:
		chunks.car = c
		chunks.configure()

func _prime_point() -> Vector3:
	## WHAT A LIVE SEED CHANGE MEANS UNDER STREAMING - decided here rather than left implicit.
	## D3 rebuilt the whole 720 m box on every parameter edit, which was affordable for one slab and
	## is impossible for a 4 km corridor. The rule is: DROP EVERY CHUNK AND RE-STREAM FROM WHERE THE
	## CAR IS. `_regenerate` already frees the chunk manager with the rest of the area's children, so
	## the drop is free; the only real question is where the new ground must be solid FIRST, and the
	## answer is under the car - not at the start line. Priming at the start line was right at
	## startup, when that is where the car is, and wrong for a seed change made from half way down
	## the stage, which would leave the car over ground that had not been built yet.
	## (When the car is on SHAKEDOWN, world.gd also respawns it, because the road it was driving no
	## longer exists - a new seed is a new road, not a repaint of the old one.)
	if car != null and in_area(car.global_position.x, car.global_position.z):
		return car.global_position
	if gen != null and gen.centreline != null:
		var p0: Dictionary = gen.centreline.point_at(0.0)
		return p0["pos"]
	return _origin

func _physics_process(_d: float) -> void:
	if chunks == null or car == null:
		return
	# The Tab panel binds VEHICLE properties, so the streaming budget is mirrored on the car and
	# pushed here - the same pattern stage_seed / stage_sinuosity use.
	var b: float = float(car.stage_chunk_budget_ms)
	if not is_equal_approx(b, chunks.build_budget_ms):
		chunks.build_budget_ms = b
		chunks._derive()                     # the lead distance is derived FROM the budget
	chunks.update(car.global_position)


func _build_markers() -> void:
	# The gates mark the TIMED window: run-up before START, runoff after FINISH.
	_gate(gen.timed_start_s, "START")
	_gate(gen.timed_end_s, "FINISH")

func _gate(s: float, label: String) -> void:
	var p: Dictionary = gen.centreline.point_at(s)
	var pos: Vector3 = p["pos"]
	var h: Vector2 = p["heading"]
	var side := Vector3(-h.y, 0.0, h.x)
	var w: float = float(p["width"]) * 0.5 + 1.5
	for sgn in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.12; cyl.bottom_radius = 0.12; cyl.height = 3.0
		post.mesh = cyl
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.95, 0.95, 0.95) if label == "START" else Color(0.9, 0.2, 0.2)
		post.material_override = m
		var base := pos + side * (w * float(sgn))
		post.position = Vector3(base.x, height_at(base.x, base.z) + 1.5, base.z)
		add_child(post)
	var lbl := Label3D.new()
	lbl.text = label
	lbl.font_size = 96
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = Vector3(pos.x, height_at(pos.x, pos.z) + 4.0, pos.z)
	add_child(lbl)
