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
var _pending := 0.0
var _last_params := Vector4.ZERO

func _process(delta: float) -> void:
	## Live regeneration. The drive checklist asks the user to change `seed` and see a genuinely
	## different stage, and to change `sinuosity` and feel the character move - neither is testable
	## if the parameters only exist in code. Rebuilding terrain is not a per-slider-tick operation,
	## so edits are DEBOUNCED: move the slider freely, and the stage rebuilds once you stop.
	if car == null:
		return
	var now := Vector4(float(car.stage_seed), float(car.stage_sinuosity),
			float(car.stage_elevation), float(car.stage_design_speed))
	if now != _last_params:
		_last_params = now
		_pending = 0.55
		return
	if _pending <= 0.0:
		return
	_pending -= delta
	if _pending <= 0.0:
		_regenerate(now)

func _regenerate(p: Vector4) -> void:
	def.seed = int(p.x)
	def.sinuosity = p.y
	def.elevation_character = p.z
	def.design_speed_kmh = p.w
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
	## Base terrain, with the road corridor cut into it. The road holds the elevation the generator
	## solved for (grade-limited, so it is NOT simply the terrain height) and the ground blends up or
	## down to meet it over `shoulder` metres - which is where the cut and fill becomes visible.
	var base: float = def.elevation_at(x, z)
	if gen == null or gen.centreline == null or not near_road(x, z):
		return base
	var np := gen.centreline.nearest_point(x, z)
	var lat: float = absf(float(np["lateral"]))
	var half: float = float(np["width"]) * 0.5
	if lat >= half + shoulder:
		return base
	var road: Dictionary = gen.centreline.point_at(float(np["s"]))
	var road_y: float = (road["pos"] as Vector3).y
	# superelevation: lean the road surface into the corner it is in
	var k: float = float(np["curvature"])
	var bank := clampf(k * bank_gain, -bank_max, bank_max) * float(np["lateral"])
	var t := 1.0 - smoothstep(half, half + shoulder, lat)
	return lerpf(base, road_y + bank, t)

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
	## On the start line, facing down the road.
	var cl := gen.centreline
	var p0: Dictionary = cl.point_at(0.0)
	var pos: Vector3 = p0["pos"]
	var h: Vector2 = p0["heading"]
	var t := Transform3D()
	t.origin = Vector3(pos.x, height_at(pos.x, pos.z) + 1.2, pos.z)
	t.basis = Basis().rotated(Vector3.UP, atan2(h.x, h.y))
	return t

# ---------------------------------------------------------------- build

func _build() -> void:
	var verts := PackedVector3Array(); verts.resize(_n * _n)
	var norms := PackedVector3Array(); norms.resize(_n * _n)
	var cols := PackedColorArray(); cols.resize(_n * _n)
	var heights := PackedFloat32Array(); heights.resize(_n * _n)
	var half := _size * 0.5
	for j in range(_n):
		for i in range(_n):
			var x := _origin.x - half + float(i) * _cs
			var z := _origin.z - half + float(j) * _cs
			var h := height_at(x, z)
			var idx := j * _n + i
			verts[idx] = Vector3(x, h, z)
			heights[idx] = h
			cols[idx] = grass_color.lerp(road_color, _road_blend(x, z))
	# normals from the height field
	for j in range(_n):
		for i in range(_n):
			var i0 := maxi(i - 1, 0); var i1 := mini(i + 1, _n - 1)
			var j0 := maxi(j - 1, 0); var j1 := mini(j + 1, _n - 1)
			var hx: float = heights[j * _n + i1] - heights[j * _n + i0]
			var hz: float = heights[j1 * _n + i] - heights[j0 * _n + i]
			norms[j * _n + i] = Vector3(-hx, 2.0 * _cs, -hz).normalized()

	var idxs := PackedInt32Array()
	for j in range(_n - 1):
		for i in range(_n - 1):
			var a := j * _n + i
			var b := j * _n + i + 1
			var c := (j + 1) * _n + i
			var d := (j + 1) * _n + i + 1
			# WOUND SO THE TOP IS THE FRONT FACE. Reversing these two triangles makes the terrain
			# invisible from above and solid from below - this project has hit that exact bug before
			# (see docs/ROADMAP.md M5 gotchas), and it looks like a shader or normals problem while
			# actually being winding order. This matches stage.gd's index order deliberately; do not
			# "tidy" it into a,c,b.
			idxs.append_array([a, b, c, b, d, c])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "AreaMesh"
	mi.mesh = mesh
	add_child(mi)

	var shape := HeightMapShape3D.new()
	shape.map_width = _n
	shape.map_depth = _n
	shape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# HeightMapShape3D is centred on its own origin and spans map_width x map_depth UNITS, so it has
	# to be scaled to the cell size and moved to the area centre.
	cs.scale = Vector3(_cs, 1.0, _cs)
	cs.position = Vector3(_origin.x, 0.0, _origin.z)
	add_child(cs)

func _road_blend(x: float, z: float) -> float:
	if gen == null or gen.centreline == null or not near_road(x, z):
		return 0.0
	var np := gen.centreline.nearest_point(x, z)
	var lat: float = absf(float(np["lateral"]))
	var half: float = float(np["width"]) * 0.5
	return 1.0 - smoothstep(half, half + 2.0, lat)

func _build_markers() -> void:
	_gate(0.0, "START")
	_gate(gen.centreline.length(), "FINISH")

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
