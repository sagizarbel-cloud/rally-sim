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
## THE HANDOFF CARRIES THE CAMERA THROUGH THE SAME RIGID MOTION AS THE CAR, which is what makes it
## indistinguishable. Applying the swap transform to the camera as well preserves their relative pose
## exactly, so the view is continuous even where a pair is NOT aligned - and it is what lets a portal
## point wherever the road wants instead of wherever the maths needs. (The calibration/stage-start
## pair happens to be aligned as well, so that one is a pure translation with heading change
## 0.000 deg.) Without carrying the camera it lerps at `smooth = 6.0` and sails three kilometres.
##
## PORTALS ARE A DIRECTED GRAPH, NOT A TWO-STATE TOGGLE (driver, 2026-09-01: "the tunnel should
## always work - regardless of where i started from"). The manager no longer tracks which area it
## THINKS you are in and test the matching tube; it asks which tube the car is ACTUALLY inside and
## sends it wherever that tube's `links_to` points. So arriving by [B], by a tunnel, by respawn or by
## any future means all behave the same, because none of them are consulted.
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
# THE MOUTH IS OFF-MAP, AND AT THE HEIGHT OF THE ROAD THAT REACHES IT (driver, 2026-09-02). Those two
# together are the whole design. Off-map, no terrain can ever bury it - that failure repeated on
# every seed whose ground rose near the boundary. At the approach's own height, the pad bridges
# DISTANCE ONLY and never height, which is what removes the climb rather than trying to grade it:
# "make the mouth of the tunnel off map but make it always at the hight of the start-up path's
# hight, that way the transition pad only bridges the distance and not the hight".
var portal_offmap_m := 60.0        ## how far beyond the map boundary the mouth stands
var pad_into_map_m := 20.0         ## how far the pad may reach BACK onto the map. Driver's cap.
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
	_build_portals()
	stage.ground_map.areas.append(self)

func rebuild() -> void:
	## THE STAGE MOVED, SO THE PORTALS MUST MOVE. Every portal is placed FROM the road - its position
	## is the road's end at the map edge and its height is the road's height there - so a new seed is
	## a new road and the old portals are simply in the wrong place. They were not being rebuilt:
	## world.gd's `regenerated` handler re-pointed the centrelines, the timing, the pace notes and the
	## spawn, and left these alone. The result was a tunnel that lined up perfectly on whichever seed
	## happened to be live at startup and was wrong on every other one - reported as "on some seeds it
	## lines up perfectly ... and on others its messed up". The ground-map layer is NOT re-registered,
	## because this node is already in that list and appending again would resolve it twice.
	for prt in _portals:
		var b: Node = prt["body"]
		if is_instance_valid(b):
			b.queue_free()
	_portals.clear()
	_armed = true
	_build_portals()

func _build_portals() -> void:
	var cl: Centreline = stage_area.gen.centreline
	var p0: Dictionary = cl.point_at(0.0)
	var start: Vector3 = p0["pos"]
	var h: Vector2 = p0["heading"]
	var road_dir := Vector3(h.x, 0.0, h.y).normalized()

	# THREE portals, wired as a directed graph:
	#   0 CALIBRATION  -> 1   drive off the calibration map, arrive on SHAKEDOWN's run-up
	#   1 STAGE START  -> 0   drive back down the run-up, arrive on the calibration map
	#   2 STAGE FINISH -> 1   drive on past the finish, arrive back on the run-up to RE-RUN it
	# The finish tunnel returns you to the STAGE START rather than to the calibration map, which is
	# the more useful of the two the driver was weighing: a rally stage is a thing you re-run, and
	# the calibration map is still one tunnel away from where this puts you. Sending it to
	# calibration instead would make re-running the stage the long way round. Flipping it is one
	# number, which is the point of making the destinations data rather than an enum.
	_portals.resize(3)
	# Where each approach CROSSES THE BOUNDARY, and how high it is there. D5's run-up extension
	# already carries the stage road to within a metre or two of the edge, so these are simply the
	# road's own ends - which is what makes the pad level.
	var a0: Vector3 = cl.point_at(0.0)["pos"]
	var a1: Vector3 = cl.point_at(cl.length())["pos"]
	var he: Vector2 = cl.point_at(cl.length())["heading"]
	var end_dir := Vector3(he.x, 0.0, he.y).normalized()
	pad_w = 44.0
	_portals[1] = _make_portal(Vector3(a0.x, 0.0, a0.z), -road_dir, "PortalStageStart",
			Callable(stage_area, "height_at"), stage_area.height_at(a0.x, a0.z))
	_portals[2] = _make_portal(Vector3(a1.x, 0.0, a1.z), end_dir, "PortalStageFinish",
			Callable(stage_area, "height_at"), stage_area.height_at(a1.x, a1.z))
	# CALIBRATION: walk out along road_dir to the square's edge. Aligned with the stage-start portal
	# so that pair's swap is a pure translation.
	var half: float = float(stage.size) * 0.5
	var d := 0.0
	var edge_c := Vector3.ZERO
	while d < half * 2.0:
		var q: Vector3 = road_dir * d
		if absf(q.x) > half - 6.0 or absf(q.z) > half - 6.0:
			break
		edge_c = q
		d += 2.0
	pad_w = 52.0
	_portals[0] = _make_portal(edge_c, road_dir, "PortalCalibration",
			Callable(stage, "_height"), float(stage._height(edge_c.x, edge_c.z)))
	pad_w = 70.0

	_portals[0]["links_to"] = 1
	_portals[1]["links_to"] = 0
	_portals[2]["links_to"] = 1
	_portals[0]["area"] = Area.CALIBRATION
	_portals[1]["area"] = Area.STAGE
	_portals[2]["area"] = Area.STAGE
	stage.ground_map.areas.append(self)

func _make_portal(edge_xz: Vector3, inward: Vector3, pname: String, height_fn: Callable,
		mouth_y: float) -> Dictionary:
	## `edge_xz` is where the APPROACH crosses the map boundary; the mouth then stands
	## `portal_offmap_m` further out, at `mouth_y` - the height of that approach. Nothing about the
	## terrain under the tube is consulted any more, because there is none out there to consult.
	var mouth_xz: Vector3 = edge_xz + inward * portal_offmap_m
	var pad_y: float = mouth_y

	var body := StaticBody3D.new()
	body.name = pname
	body.collision_layer = 1
	body.collision_mask = 0
	var origin := Vector3(mouth_xz.x, pad_y, mouth_xz.z)
	body.transform = Transform3D(Basis(), origin).looking_at(origin + inward, Vector3.UP)
	# The pad reaches from the mouth back across the gap and a little way onto the map.
	pad_len = portal_offmap_m + pad_into_map_m
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
	# The pad's REAL reach and width, recorded rather than left to be guessed. A probe that assumed a
	# generic footprint reported 245 m of road buried under a pad that had already been shortened.
	var reach: float = _build_pad(body, origin, inward, height_fn, pad_mat)
	return {"frame": body.transform, "name": pname, "body": body, "pad_y": pad_y, "links_to": 0,
		"area": 0, "pad_reach": reach, "pad_half_w": pad_w * 0.5}

func _light_tube(body: StaticBody3D) -> void:
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.95, 0.90, 0.75)
	glow.emission_enabled = true                     # NOT unshaded - unshaded ignores emission
	glow.emission = Color(1.0, 0.93, 0.75)
	glow.emission_energy_multiplier = 2.4
	# ANCHORED ON THE GATE, not the mouth. Both tubes are entered from their mouths but the car
	# travels through them in OPPOSITE senses, so mouth-anchored lighting puts the next lamp 24 m
	# ahead on one side of the transition and 36 m ahead on the other - a visible jump in the rhythm
	# at the exact moment the swap happens. Spacing them symmetrically about the gate makes the
	# pattern continuous through it, whichever way you are going.
	var k0: int = int(ceil(-gate_depth / light_spacing)) - 1
	var k1: int = int((tube_len - gate_depth) / light_spacing) + 1
	for i in range(k0, k1 + 1):
		var z: float = -(gate_depth + float(i) * light_spacing)
		if z > -1.0 or z < -tube_len:
			continue
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
		mat: StandardMaterial3D) -> float:
	## A flat approach that grades out into the terrain - the drag strip's runoff pad, applied to a
	## tunnel mouth. THIS is what lets the tunnel be straight and flat: the pad guarantees a known
	## height at the mouth, so the tube never has to chase the ground. Built as its OWN mesh and
	## collider, so neither `stage._height` nor the stage's height field is touched and the
	## calibration bed stays bit-identical (§1.1).
	var back := -inward
	var side := Vector3(-inward.z, 0.0, inward.x).normalized()
	# NO RAMP AND NO DERIVED APRON ANY MORE. The mouth stands at the height of the approach that
	# reaches it, so the pad is LEVEL over its whole length - there is nothing to climb, which was
	# half the driver's report ("sometimes the transition pad being to steep to climb"). Only the
	# last stretch, where the pad meets the map, blends into the natural ground; and that stretch is
	# capped at `pad_into_map_m` because the pad must not lie across the stage.
	var apron: float = pad_into_map_m
	var inv: Transform3D = body.transform.affine_inverse()
	# The pad MESH starts just under the mouth. Running it 40 m into the tube laid a second, lighter
	# surface on top of the tunnel floor - photographed as a bright wedge on a dark roadway.
	var pad_start := -2.0
	# The mesh ENDS where the blend ends. Running it a further `apron` past that just laid
	# terrain-following surface nobody needs, and made in_area() claim 100 m of asphalt where the pad
	# is really 80: portal_offmap_m off the map plus pad_into_map_m on it, which is the driver's cap.
	var nu: int = int((pad_len - pad_start) / pad_cell) + 1
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
			# blend to natural ground only over the final `apron` metres, i.e. the on-map end
			var t_u: float = 1.0 - clampf((uu - (pad_len - apron)) / maxf(apron, 1.0), 0.0, 1.0)
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
	return pad_len

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
	# WHICH TUBE IS THE CAR ACTUALLY IN? Not "which area do I believe it is in" - that belief was
	# only ever updated by a tunnel transition, so arriving on the stage with [B] left the manager
	# testing the calibration tube while the car sat in the stage one, and the tunnel simply did
	# nothing. Asking the world instead of a stored flag is what makes every route in behave alike.
	var here := _tube_containing(car.global_position)
	if here < 0:
		_armed = true                      # outside every tube: a swap cannot bounce you back
		return
	if not _armed:
		return
	if -(_local_in(here, car.global_position).z) < gate_depth:
		return
	_swap(here, int(_portals[here]["links_to"]))

func _tube_containing(p: Vector3) -> int:
	for i in range(_portals.size()):
		var l: Vector3 = _local_in(i, p)
		if l.z <= 0.0 and l.z >= -tube_len and absf(l.x) <= tube_w * 0.5:
			return i
	return -1

func _swap(from: int, to: int) -> void:
	# Gate frames at the transition plane rather than the mouth: both tubes are entered from their
	# mouths, so the car crosses at `gate_depth` in whichever it is in and must arrive at the same
	# depth in the other, heading out. Taking this about the MOUTH flung the car out of the far end.
	var gate := Transform3D(Basis(), Vector3(0.0, 0.0, -gate_depth))
	var g_from: Transform3D = (_portals[from]["frame"] as Transform3D) * gate
	var g_to: Transform3D = (_portals[to]["frame"] as Transform3D) * gate
	var f_out := g_to * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var before: Transform3D = car.global_transform
	var rel: Transform3D = g_from.affine_inverse() * before
	var dst: Transform3D = f_out * rel
	# NO height correction. Each tube is FLAT and its frame origin IS its floor, so the car's local y
	# is already measured from the floor it is standing on - carrying it across is all that is needed.
	# The old correction dated from the version whose tubes followed the terrain and had different
	# floor heights at the gate; left in after the rebuild it double-corrected, and coming back from
	# the stage put the car 1.72 m BELOW the calibration tunnel's floor, which is the reported
	# "teleports below the tunnel and drops to the void".
	#
	# RE-INTRODUCED ONCE, 2026-09-01, by rewriting _swap() wholesale for the portal graph from an
	# older copy instead of editing the current one. If this line ever comes back, that is how.
	# THE RIGID MOTION APPLIED TO THE CAR, applied to the camera as well. Preserving their relative
	# pose is what makes the transition indistinguishable, and it is what frees a portal to point
	# wherever its road wants: without it only pairs whose directions happen to agree can be seamless,
	# and the finish tunnel has to leave along the road's finishing heading. STATE IS PRESERVED
	# DELIBERATELY (§5 D5 probe 4) - a tunnel is a road, not a service park, so damage, tyre
	# temperature and wear all carry through untouched.
	var motion: Transform3D = dst * before.affine_inverse()
	var v_local: Vector3 = g_from.basis.inverse() * car.linear_velocity
	var w_local: Vector3 = g_from.basis.inverse() * car.angular_velocity
	car.global_transform = dst
	car.linear_velocity = f_out.basis * v_local
	car.angular_velocity = f_out.basis * w_local
	if chase_camera != null:
		chase_camera.global_transform = motion * chase_camera.global_transform
	_current = int(_portals[to]["area"])
	_armed = false
	_transitions += 1
	emit_signal("area_changed", _current)

func _local_in(which: int, p: Vector3) -> Vector3:
	return (_portals[which]["frame"] as Transform3D).affine_inverse() * p

# ---------------------------------------------------------------- ground map layer

func in_area(x: float, z: float) -> bool:
	## The tube AND its transition pad. The pad was left out, so it graded and drove like open
	## ground - the driver asked for it to "grip like asphalt", and it is a made surface, so it
	## should. Including it here is all that takes, because surface_at() below then speaks for it.
	for prt in _portals:
		var l: Vector3 = (prt["frame"] as Transform3D).affine_inverse() * Vector3(x, 0.0, z)
		if l.z <= 0.0 and l.z >= -tube_len and absf(l.x) <= tube_w * 0.5:
			return true
		if l.z >= -2.0 and l.z <= float(prt["pad_reach"]) and absf(l.x) <= float(prt["pad_half_w"]):
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
