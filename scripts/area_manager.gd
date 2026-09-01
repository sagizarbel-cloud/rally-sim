extends Node3D
class_name AreaManager
## D5 — which AREA the car is in, and the tunnel that joins them
## (docs/PLAN-stages-ground-map.md §5 Phase D5).
##
## THE CONNECTOR IS A TUNNEL, AND THAT IS WHY THIS WORKS AT ALL. Measured before designing it: the
## generated stage's start line sits **4149 m** from the calibration map, because StageGen lays its
## spine from one corner of a 4 km box and the start IS that corner. A continuous road link would be
## as long as the stage itself, and the stage cannot simply be moved closer - its elevation is
## sampled at ABSOLUTE world coordinates, so relocating the area changes the road. A tunnel dissolves
## that: **its two mouths do not have to be geometrically adjacent.**
##
## THE SHAPE OF IT IS THE DRIVER'S DESIGN (2026-08-31), and it is better than what it replaced:
##   * a TRANSITION PAD flattens the ground at each connection and grades out into the terrain, the
##     way the drag strip's runoff pad does;
##   * the tunnel then starts from that known flat height at the MAP EDGE and runs outward into
##     empty space, so it is INDEPENDENT of the terrain it leaves - no following the ground, no
##     weird shapes, and its geometry can be changed without touching either map;
##   * it is long - `tube_len` each side - with the first `straighten_len` reserved for lining the
##     car up, so nothing happens near the mouth.
## The previous version made the tube follow the terrain, which produced an 8.15 m ledge at the
## stage mouth where the ground rose into a hill. Flattening a pad and leaving the tunnel straight is
## both simpler and better: a straight flat tube is four boxes, not 22 rotated segments.
##
## THE HANDOFF IS A PURE TRANSLATION, WHICH IS WHY THE CAMERA DOES NOT MOVE. The calibration tunnel
## is deliberately aligned so its INWARD direction equals the stage tunnel's OUTWARD direction: the
## car's world orientation is then identical either side of the swap, so there is no rotation for a
## chase camera to swing around. The camera is carried across too, because it lerps its position at
## `smooth = 6.0` and would otherwise sail across three kilometres of world.
##
## WHAT THIS MANAGER DOES NOT DO, by decision (2026-08-31): it never unloads the calibration bed.
## A cold rebuild measures 494 ms - 95% in the terrain mesh loop - so making it resumable would mean
## restructuring the build path every baseline in this project rests on. Holding it costs ~20 MB and
## makes §1.1 structural rather than re-proved per transition. The generated stage needs no unload
## either: D4's streamer already drops its chunks to zero when the car is elsewhere.

signal area_changed(which: int)

enum Area { CALIBRATION, STAGE }

var stage                                 ## RallyStage - the calibration bed
var stage_area: StageArea                 ## the generated stage
var car: Node3D
var chase_camera: Node3D                  ## carried across the swap; see above

# --- the tunnel ----------------------------------------------------------------------------------
var tube_len := 800.0                     ## each side
var gate_depth := 400.0                   ## the handoff, at the midpoint - well past the straightening
var straighten_len := 300.0               ## reserved for lining up; the gate is never inside this
var tube_w := 12.0
var tube_h := 6.5
# --- the transition pad --------------------------------------------------------------------------
var pad_len := 60.0                       ## flat approach, measured back from the mouth. SHORT on
                                          ## purpose: taking the highest ground over 200 m made the
                                          ## pad a 12 m embankment at the stage mouth, because the
                                          ## land climbs steeply behind it. A connection pad is a
                                          ## junction, not a runway - it levels the last stretch and
                                          ## the apron does the rest.
var pad_w := 70.0
var pad_grade := 0.10                     ## the apron grades out at this slope, so it stays drivable
var pad_cell := 4.0
# --- lighting ------------------------------------------------------------------------------------
# An 800 m unlit tube is not a road, it is a cave: photographed from inside, the first version was
# pitch black with a pinhole of daylight 400 m away. Real road tunnels are lit, and this is the
# cheapest honest version - an emissive strip you can see receding, plus enough omnis to put light
# on the car itself without paying for one every few metres.
var light_spacing := 60.0
var light_range := 46.0
var pad_apron_max := 200.0         ## cap on the graded apron, per portal
var pad_target_y := 1e9            ## if set, the pad RAMPS to this height at pad_target_u
var pad_target_u := 0.0
var pad_core_w := 20.0                    ## the FLAT part. Only as wide as the road needs: taking
                                          ## the highest ground across the pad's full 70 m width set
                                          ## the stage pad from the valley WALLS either side of a
                                          ## road that sits in a cut, which is how a junction pad
                                          ## became a 12 m embankment. Outside this the pad blends
                                          ## up or down to meet the natural ground, which is what a
                                          ## cutting looks like.

var _portals: Array = []
var _current := Area.CALIBRATION
var _armed := true
var _transitions := 0

# ---------------------------------------------------------------- build

func build() -> void:
	var cl: Centreline = stage_area.gen.centreline
	var p0: Dictionary = cl.point_at(0.0)
	var start: Vector3 = p0["pos"]
	var h: Vector2 = p0["heading"]
	var road_dir := Vector3(h.x, 0.0, h.y).normalized()

	_portals.resize(Area.size())
	# STAGE: the mouth goes at the AREA'S EDGE, not on the start line. Putting it on the start line
	# meant the pad - which has to grade out into the terrain - sat on the road itself and raised the
	# first 100 m of a stage that is already drive-verified. Walking back to the boundary puts the
	# mouth off the road entirely, so the pad bridges the gap between the tunnel and the run-up and
	# NOTHING of the stage proper is touched. It is also what the driver asked for: the tunnel starts
	# at the edge of the map, and only the transition pad is affected.
	var back_d := 0.0
	var mouth_s := start
	while back_d < 600.0:
		var q: Vector3 = start - road_dir * back_d
		if not stage_area.in_area(q.x, q.z):
			break
		mouth_s = q
		back_d += 4.0
	# the pad then has to reach from that mouth to where the road begins, plus room to grade out
	pad_len = maxf(back_d + 30.0, 60.0)
	pad_target_y = float(stage_area.height_at(start.x, start.z))
	pad_target_u = maxf(back_d, 1.0)
	_portals[Area.STAGE] = _make_portal(Vector3(mouth_s.x, 0.0, mouth_s.z), -road_dir, "PortalStage",
			Callable(stage_area, "height_at"))
	pad_len = 60.0
	pad_target_y = 1e9
	# CALIBRATION: on the map edge, pointed so that driving IN goes the same way in world space as
	# driving OUT of the stage portal. That is what makes the swap a pure translation.
	# ON THE SQUARE'S EDGE, not at a fixed radius. The map is a square and `road_dir` is whatever
	# heading the stage happens to start on, so a fixed radius left the mouth well inside the map on
	# a diagonal - and the tube then ran ~100 m through terrain before clearing it, which is the
	# reported "environment clips the returning tunnel at 100m". Walking out to the boundary makes
	# the tunnel leave the map immediately whatever direction it points.
	var half: float = float(stage.size) * 0.5
	var d := 0.0
	var mouth_c := Vector3.ZERO
	while d < half * 2.0:
		var q: Vector3 = road_dir * d
		if absf(q.x) > half - 6.0 or absf(q.z) > half - 6.0:
			break
		mouth_c = q
		d += 2.0
	# --- #1/#5: a SHORT pad here. 200 m of graded apron reached back over the asphalt ring and
	# blocked it. The driver asked for 20-60 m, just enough to be flat for the mouth.
	pad_len = 20.0
	pad_apron_max = 25.0
	_portals[Area.CALIBRATION] = _make_portal(mouth_c, road_dir, "PortalCalibration",
			Callable(stage, "_height"))
	pad_apron_max = 200.0
	stage.ground_map.areas.append(self)

func _make_portal(mouth_xz: Vector3, inward: Vector3, pname: String, height_fn: Callable) -> Dictionary:
	# The pad's height is the highest ground it must cover, so nothing pokes up through it; the apron
	# then grades DOWN to meet the natural terrain.
	var back := -inward
	var side := Vector3(-inward.z, 0.0, inward.x).normalized()
	var top := -1e9
	var u := -40.0
	while u <= pad_len:
		for j in range(-2, 3):
			var q: Vector3 = mouth_xz + back * u + side * (pad_core_w * 0.5 * float(j) / 2.0)
			top = maxf(top, float(height_fn.call(q.x, q.z)))
		u += pad_cell
	var pad_y: float = top + 0.15

	var body := StaticBody3D.new()
	body.name = pname
	body.collision_layer = 1
	body.collision_mask = 0
	var origin := Vector3(mouth_xz.x, pad_y, mouth_xz.z)
	body.transform = Transform3D(Basis(), origin).looking_at(origin + inward, Vector3.UP)
	add_child(body)

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.30, 0.30, 0.32)
	wall_mat.roughness = 0.95
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = Color(0.40, 0.39, 0.37)   # the roadway, not the walls
	road_mat.roughness = 1.0
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.46, 0.44, 0.40)      # made road surface, not a hole in the map
	pad_mat.roughness = 1.0

	# The tube: straight, flat, four boxes. It runs OUTWARD from the map edge into empty space, so
	# past the first few tens of metres there is no terrain for it to argue with at all.
	var half_w := tube_w * 0.5
	_slab(body, Vector3(tube_w, 0.5, tube_len), Vector3(0.0, -0.25, -tube_len * 0.5), road_mat)
	_slab(body, Vector3(tube_w, 0.5, tube_len), Vector3(0.0, tube_h, -tube_len * 0.5), wall_mat)
	_slab(body, Vector3(0.6, tube_h, tube_len), Vector3(-half_w, tube_h * 0.5, -tube_len * 0.5), wall_mat)
	_slab(body, Vector3(0.6, tube_h, tube_len), Vector3(half_w, tube_h * 0.5, -tube_len * 0.5), wall_mat)
	_slab(body, Vector3(tube_w + 4.0, 1.4, 1.2), Vector3(0.0, tube_h + 0.7, -0.6), wall_mat)

	_light_tube(body)
	_build_pad(body, origin, inward, height_fn, pad_mat)
	return {"frame": body.transform, "name": pname, "body": body, "pad_y": pad_y}

func _light_tube(body: StaticBody3D) -> void:
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.95, 0.90, 0.75)
	glow.emission_enabled = true                     # NOT unshaded - unshaded ignores emission
	glow.emission = Color(1.0, 0.93, 0.75)
	glow.emission_energy_multiplier = 2.4
	var n: int = int(tube_len / light_spacing)
	for i in range(n + 1):
		var z: float = -float(i) * light_spacing - 4.0
		if z < -tube_len:
			break
		# a lit panel on the ceiling, which is what you actually SEE receding down the tunnel
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.6, 0.18, 5.0)
		mi.mesh = bm
		mi.material_override = glow
		mi.position = Vector3(0.0, tube_h - 0.35, z)
		body.add_child(mi)
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(0.0, tube_h - 0.9, z)
		lamp.omni_range = light_range
		lamp.light_energy = 1.5
		lamp.light_color = Color(1.0, 0.94, 0.82)
		lamp.shadow_enabled = false                  # 13 shadow-casting omnis per tunnel is not free
		body.add_child(lamp)

func _build_pad(body: StaticBody3D, origin: Vector3, inward: Vector3, height_fn: Callable,
		mat: StandardMaterial3D) -> void:
	## A flat approach that grades out into the terrain - the drag strip's runoff pad, applied to a
	## tunnel mouth. THIS is what lets the tunnel be straight and flat: the pad guarantees a known
	## height at the mouth, so the tube never has to chase the ground. Built as its OWN mesh and
	## collider, so neither `stage._height` nor the stage's height field is touched and the
	## calibration bed stays bit-identical (§1.1).
	var back := -inward
	var side := Vector3(-inward.z, 0.0, inward.x).normalized()
	# The apron is as long as the drop it must cover at `pad_grade` - derived, not picked.
	var lo := 1e9
	var u0 := -40.0
	while u0 <= pad_len + 160.0:
		var w0: Vector3 = origin + back * u0
		lo = minf(lo, float(height_fn.call(w0.x, w0.z)))
		u0 += pad_cell
	var apron: float = clampf((origin.y - lo) / pad_grade, 15.0, pad_apron_max)

	var inv: Transform3D = body.transform.affine_inverse()
	# The pad MESH starts just under the mouth. Running it 40 m into the tube laid a second, lighter
	# surface on top of the tunnel floor - photographed as a bright wedge on a dark roadway.
	var pad_start := -4.0
	var nu: int = int((pad_len + apron - pad_start) / pad_cell) + 1
	var nv: int = int(pad_w / pad_cell) + 1
	var verts := PackedVector3Array()
	var idxs := PackedInt32Array()
	for iu in range(nu):
		var uu: float = pad_start + float(iu) * pad_cell
		for iv in range(nv):
			var vv: float = -pad_w * 0.5 + float(iv) * pad_cell
			var w: Vector3 = origin + back * uu + side * vv
			var nat: float = float(height_fn.call(w.x, w.z))
			# The core is not necessarily FLAT. Where the tunnel has to meet a road at a known
			# height - the stage's run-up sits 8 m below the area edge the mouth stands on - the pad
			# RAMPS to it instead, which is what a road does. Holding it flat left a shelf over the
			# hollow with a cliff at its end.
			var core_y: float = origin.y
			if pad_target_y < 1e8 and pad_target_u > 1.0:
				core_y = lerpf(origin.y, pad_target_y, clampf(uu / pad_target_u, 0.0, 1.0))
			var t_u: float = 1.0 - clampf((uu - pad_len) / maxf(apron, 1.0), 0.0, 1.0)
			var t_v: float = 1.0 - clampf((absf(vv) - pad_core_w * 0.5)
					/ maxf(pad_w * 0.5 - pad_core_w * 0.5, 1.0), 0.0, 1.0)
			var t: float = minf(t_u, t_v)
			t = t * t * (3.0 - 2.0 * t)               # smoothstep: no kink where pad meets grass
			# Built in the BODY'S LOCAL space, not world with top_level: a CollisionShape3D is
			# registered by its transform RELATIVE to the body, so top_level would have moved the
			# mesh and left the collider behind the portal's own rotation.
			verts.append(inv * Vector3(w.x, lerpf(nat, core_y, t), w.z))
	for iu in range(nu - 1):
		for iv in range(nv - 1):
			var a: int = iu * nv + iv
			var b: int = a + 1
			var c: int = a + nv
			var d: int = c + 1
			idxs.append_array([a, b, c, b, d, c])     # top is the front face - see CLAUDE.md
	# NORMALS. Without them the pad renders unlit and comes out very nearly black against pale
	# terrain - which is what the first photograph of it showed, and what no amount of height
	# measurement would ever have revealed. Central differences across the grid, one-sided at the
	# border, the same way the chunk builder does it.
	var norms := PackedVector3Array(); norms.resize(verts.size())
	for iu in range(nu):
		for iv in range(nv):
			var i0: int = maxi(iu - 1, 0) * nv + iv
			var i1: int = mini(iu + 1, nu - 1) * nv + iv
			var j0: int = iu * nv + maxi(iv - 1, 0)
			var j1: int = iu * nv + mini(iv + 1, nv - 1)
			var du: float = verts[i1].y - verts[i0].y
			var dv: float = verts[j1].y - verts[j0].y
			norms[iu * nv + iv] = Vector3(-dv, 2.0 * pad_cell, -du).normalized()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.name = "Pad"
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var shp := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	for i in range(idxs.size()):
		faces.append(verts[idxs[i]])
	shp.set_faces(faces)
	cs.shape = shp
	body.add_child(cs)

func _slab(body: StaticBody3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	## The CollisionShape3D goes DIRECTLY on the StaticBody3D, never under an intermediate node.
	## Godot only registers shapes that are direct children of the CollisionObject3D; nesting them
	## once silently removed every collider in the tunnel and the car fell 15 m through the floor.
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)

# ---------------------------------------------------------------- the swap

func _physics_process(_d: float) -> void:
	if car == null or _portals.is_empty():
		return
	var local: Vector3 = _local_in(_current, car.global_position)
	var inward: float = -local.z
	if inward < 0.0:
		_armed = true                      # back outside: a swap cannot bounce you straight back
	if not _armed or inward < gate_depth:
		return
	if absf(local.x) > tube_w * 0.5:
		return
	_swap()

func _swap() -> void:
	var from: int = _current
	var to: int = Area.STAGE if from == Area.CALIBRATION else Area.CALIBRATION
	# Gate frames at the transition plane rather than the mouth: both tubes are entered from their
	# mouths, so the car crosses at `gate_depth` in whichever it is in and must arrive at the same
	# depth in the other, heading out. Taking this about the MOUTH flung the car out of the far end.
	var gate := Transform3D(Basis(), Vector3(0.0, 0.0, -gate_depth))
	var g_from: Transform3D = (_portals[from]["frame"] as Transform3D) * gate
	var g_to: Transform3D = (_portals[to]["frame"] as Transform3D) * gate
	var f_out := g_to * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var rel: Transform3D = g_from.affine_inverse() * car.global_transform
	var dst: Transform3D = f_out * rel
	# NO height correction. Each tube is FLAT and its frame origin IS its floor, so the car's local y
	# is already measured from the floor it is standing on - carrying it across is all that is needed.
	# The old correction dated from the version whose tubes followed the terrain and had different
	# floor heights at the gate; left in after the rebuild it double-corrected, and coming back from
	# the stage put the car 1.72 m BELOW the calibration tunnel's floor, which is the reported
	# "teleports below the tunnel and drops to the void".
	var v_local: Vector3 = g_from.basis.inverse() * car.linear_velocity
	var w_local: Vector3 = g_from.basis.inverse() * car.angular_velocity
	# STATE IS PRESERVED, DELIBERATELY (§5 D5 probe 4). Damage, tyre temperature and wear are things
	# you did to the car; a tunnel is a road, not a service park.
	var was: Vector3 = car.global_position
	car.global_transform = dst
	car.linear_velocity = f_out.basis * v_local
	car.angular_velocity = f_out.basis * w_local
	# The chase camera LERPS its position, so without this it sails across three kilometres of world
	# after every transition. Carrying it by the same delta keeps its framing identical.
	if chase_camera != null:
		chase_camera.global_position += dst.origin - was
	_current = to
	_armed = false
	_transitions += 1
	emit_signal("area_changed", to)

func _local_in(which: int, p: Vector3) -> Vector3:
	return (_portals[which]["frame"] as Transform3D).affine_inverse() * p

# ---------------------------------------------------------------- ground map layer

func in_area(x: float, z: float) -> bool:
	for prt in _portals:
		var l: Vector3 = (prt["frame"] as Transform3D).affine_inverse() * Vector3(x, 0.0, z)
		if l.z <= 0.0 and l.z >= -tube_len and absf(l.x) <= tube_w * 0.5:
			return true
	return false

func on_road(x: float, z: float) -> bool:
	return in_area(x, z)

func surface_at(_x: float, _z: float) -> int:
	## A road tunnel is paved. This optional hook lets a layer say something other than the
	## generated-area default without every consumer learning what a tunnel is.
	return GroundMap.Surface.ASPHALT

func current_area() -> int:
	return _current

func transitions() -> int:
	return _transitions
