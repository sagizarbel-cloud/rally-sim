extends Node3D
class_name AreaManager
## D5 — which AREA the car is in, and the tunnel that joins them
## (docs/PLAN-stages-ground-map.md §5 Phase D5).
##
## THE CONNECTOR IS A TUNNEL, AND THAT IS WHY THIS WORKS AT ALL. Measured before designing it: the
## generated stage's start line sits **4149 m** from the calibration map, because StageGen lays its
## spine from one corner of a 4 km box and the start is that corner. A continuous road link would
## therefore be as long as the stage itself, and the stage cannot simply be moved closer - its
## elevation is sampled at ABSOLUTE world coordinates, so relocating the area changes the road.
##
## A tunnel dissolves the problem instead of paying it: **its two mouths do not have to be
## geometrically adjacent.** You drive into a portal at the calibration map and out of a portal at
## the stage start; the handoff happens at a plane in the middle of the tube, where there is nothing
## to see. That is what a tunnel is for, and it is why the user proposed one (2026-08-13).
##
## WHAT THIS MANAGER DOES NOT DO, by decision (2026-08-31): it never unloads the calibration bed.
## A cold rebuild of it measures 494 ms - 95% of that in the terrain mesh loop - so making it
## resumable would mean restructuring the build path that every baseline in this project rests on.
## Holding it costs ~20 MB. The bed is built once and never torn down, which makes §1.1's "the
## calibration map stays untouched" structural rather than something a probe must re-prove after
## every transition. The generated stage needs no unloading either: D4's streamer already drops its
## chunks to zero when the car is elsewhere.

signal area_changed(which: int)

enum Area { CALIBRATION, STAGE }

var stage                                 ## RallyStage - the calibration bed
var stage_area: StageArea                 ## the generated stage
var car: Node3D

## Tube geometry. Derived, not styled: the width is the widest road either end offers plus room to
## be off-line, and the height clears the car with a lorry's worth of margin so it reads as a road
## tunnel rather than a pipe.
var tube_w := 11.0
var tube_h := 6.0
var tube_len := 110.0

var _portals: Array = []                  ## [{frame, name}] index matches Area
var _current := Area.CALIBRATION
var _armed := true                        ## false while the car is still on the plane it just used
var _transitions := 0

# ---------------------------------------------------------------- build

func build() -> void:
	_portals.resize(Area.size())
	_portals[Area.CALIBRATION] = _make_portal(_calibration_mouth(), "PortalCalibration")
	_portals[Area.STAGE] = _make_portal(_stage_mouth(), "PortalStage")
	# The tunnel floor is a SURFACE, so it goes through the ground map like everything else rather
	# than being a special case in the car. D1's layer stack takes an area with in_area/on_road; the
	# optional surface_at() below is what lets this one say ASPHALT instead of the DIRT a generated
	# area reports.
	stage.ground_map.areas.append(self)

func _calibration_mouth() -> Transform3D:
	## Just outside the asphalt ring on the south side, facing OUT of the map.
	var mouth := Vector3(0.0, 0.0, -335.0)
	return _frame_at(mouth, Vector3(0.0, 0.0, -1.0), Callable(stage, "_height"))

func _stage_mouth() -> Transform3D:
	## At the very start of the stage road, facing BACKWARDS along it, so driving out of the tunnel
	## puts you on the run-up heading for the start line.
	var cl: Centreline = stage_area.gen.centreline
	var p: Dictionary = cl.point_at(0.0)
	var pos: Vector3 = p["pos"]
	var h: Vector2 = p["heading"]
	return _frame_at(Vector3(pos.x, 0.0, pos.z), Vector3(-h.x, 0.0, -h.y).normalized(),
			Callable(stage_area, "height_at"))

func _frame_at(mouth: Vector3, inward: Vector3, height_fn: Callable) -> Transform3D:
	## A portal frame: origin at the mouth on the floor, -Z pointing INWARD. Driving "forward" in
	## this frame is driving into the tunnel, which is what makes the swap a plain transform.
	##
	## THE FLOOR SITS ABOVE THE GROUND IT CROSSES, and that is not cosmetic. The first version put
	## the mouth at the local terrain height and let the tube burrow in, so for most of its length
	## the tube was INSIDE the hill: the car was wedged between the tunnel floor and the terrain
	## collider and stopped dead after one transition. Neither terrain may be carved to fix it - the
	## calibration bed is untouchable by §1.1, and the stage is the road the user has just verified -
	## so the tube is raised to clear the highest ground along its own length instead, and an
	## approach ramp lifts the road up to the mouth.
	## Sampled ACROSS the tube as well as along it. Sampling only the centre line left the ground at
	## the tube's edges above the floor on sloping terrain, so a hill poked up through the roadway
	## and the car drove on that instead - measured as a car sitting a constant 3.12 m above the
	## floor it was supposed to be on. The tube is 11 m wide; the ground it must clear is the highest
	## point anywhere under it, not the highest point down its middle.
	var flat := Vector3(mouth.x, 0.0, mouth.z)
	var side := Vector3(-inward.z, 0.0, inward.x).normalized()
	var top := -1e9
	for i in range(25):
		var q: Vector3 = flat + inward * (tube_len * float(i) / 24.0)
		for j in range(-2, 3):
			var r: Vector3 = q + side * (tube_w * 0.5 * float(j) / 2.0)
			top = maxf(top, float(height_fn.call(r.x, r.z)))
	var t := Transform3D(Basis(), Vector3(mouth.x, top + 0.25, mouth.z))
	return t.looking_at(Vector3(mouth.x, top + 0.25, mouth.z) + inward, Vector3.UP)

func _make_portal(frame: Transform3D, pname: String) -> Dictionary:
	var body := StaticBody3D.new()
	body.name = pname
	body.collision_layer = 1
	body.collision_mask = 0
	body.transform = frame
	add_child(body)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.30, 0.32)
	mat.roughness = 0.95
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.22, 0.22, 0.23)
	floor_mat.roughness = 1.0
	# floor, ceiling, two walls - a straight box tube running from the mouth (z = 0) inward (-z)
	var half_w := tube_w * 0.5
	_slab(body, Vector3(tube_w, 0.4, tube_len), Vector3(0.0, -0.2, -tube_len * 0.5), floor_mat)
	_slab(body, Vector3(tube_w, 0.4, tube_len), Vector3(0.0, tube_h, -tube_len * 0.5), mat)
	_slab(body, Vector3(0.5, tube_h, tube_len), Vector3(-half_w, tube_h * 0.5, -tube_len * 0.5), mat)
	_slab(body, Vector3(0.5, tube_h, tube_len), Vector3(half_w, tube_h * 0.5, -tube_len * 0.5), mat)
	# a rim around the mouth so it reads as a portal from outside rather than a hole
	_slab(body, Vector3(tube_w + 3.0, 1.2, 1.0), Vector3(0.0, tube_h + 0.6, -0.5), mat)
	# APPROACH RAMP: the mouth is above the natural ground (see _frame_at), so the road has to climb
	# to it. Length is derived from the lift and a grade the car can take loaded - 12%, the same
	# max_grade the stage generator builds roads to - so this is a road, not a kerb to bump over.
	var lift: float = maxf(frame.origin.y - _ground_under(pname, frame), 0.05)
	var ramp_len: float = maxf(lift / 0.12, 8.0)
	# ONE ROTATED SLAB, not a flight of steps. The first version laid the ramp as twelve stacked
	# boxes, which is a STAIRCASE: the car hit it at speed, launched, crossed the transition plane
	# airborne and arrived at the far portal metres above its floor - and the damage model, quite
	# correctly, read the landings as crashes and pegged damage at 1.0. A continuous incline is the
	# only thing a car can drive up without being thrown.
	var slope: float = atan2(lift, ramp_len)
	var ramp_hyp: float = sqrt(ramp_len * ramp_len + lift * lift)
	var ramp := StaticBody3D.new()
	ramp.name = "Ramp"
	ramp.collision_layer = 1
	ramp.collision_mask = 0
	ramp.transform = Transform3D(Basis(Vector3.RIGHT, -slope), Vector3(0.0, -lift * 0.5, ramp_len * 0.5))
	body.add_child(ramp)
	_slab(ramp, Vector3(tube_w, 0.4, ramp_hyp), Vector3(0.0, -0.2, 0.0), floor_mat)
	return {"frame": frame, "name": pname, "body": body}

func _ground_under(pname: String, frame: Transform3D) -> float:
	if pname == "PortalCalibration":
		return float(stage._height(frame.origin.x, frame.origin.z))
	return float(stage_area.height_at(frame.origin.x, frame.origin.z))

func _slab(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	parent.add_child(cs)

# ---------------------------------------------------------------- the swap

func _physics_process(_d: float) -> void:
	if car == null or _portals.is_empty():
		return
	var here: int = _current
	var local: Vector3 = _local_in(here, car.global_position)
	var inward: float = -local.z                       # metres past the mouth, into the tube
	# Re-arm only once the car is back OUTSIDE the tube, so a swap cannot immediately re-trigger on
	# the far side and bounce the car between the two portals.
	if inward < 0.0:
		_armed = true
	if not _armed:
		return
	if inward < tube_len * 0.5:
		return
	if absf(local.x) > tube_w * 0.5:
		return
	_swap()

func _swap() -> void:
	var from: int = _current
	var to: int = Area.STAGE if from == Area.CALIBRATION else Area.CALIBRATION
	# THE SWAP IS ABOUT THE TRANSITION PLANE, NOT THE MOUTH. Both tubes are entered from their
	# mouths, so the car crosses at DEPTH tube_len/2 in whichever tube it is in and must arrive at
	# the same depth in the other one, heading out. Taking the 180 degree yaw about the mouth
	# instead mapped "55 m inside tube A" to "55 m OUTSIDE tube B" - the car was being flung into
	# open air beyond the far portal, and it only looked like it worked because it landed. Measured
	# as a car arriving at local z = +55 with the ray finding ground 3.2 m below it.
	var gate := Transform3D(Basis(), Vector3(0.0, 0.0, -tube_len * 0.5))
	var g_from: Transform3D = (_portals[from]["frame"] as Transform3D) * gate
	var g_to: Transform3D = (_portals[to]["frame"] as Transform3D) * gate
	# Turned to face back OUT of its tube. A 180 degree yaw is a proper rotation, so it also carries
	# the car's left and right across consistently - you stay on your own side of the road, which is
	# the side of the TUBE that swaps.
	var f_out := g_to * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var rel: Transform3D = g_from.affine_inverse() * car.global_transform
	var dst: Transform3D = f_out * rel
	var v_local: Vector3 = g_from.basis.inverse() * car.linear_velocity
	var w_local: Vector3 = g_from.basis.inverse() * car.angular_velocity
	# STATE IS PRESERVED, DELIBERATELY (§5 D5 probe 4). Damage, tyre temperature and wear are things
	# you did to the car; a tunnel is a road, not a service park. Nothing here touches them - the car
	# is moved, not rebuilt - and the probe asserts that rather than trusting it.
	car.global_transform = dst
	car.linear_velocity = f_out.basis * v_local
	car.angular_velocity = f_out.basis * w_local
	if car.has_method("sync_after_teleport"):
		car.sync_after_teleport()
	_current = to
	_armed = false
	_transitions += 1
	emit_signal("area_changed", to)

func _local_in(which: int, p: Vector3) -> Vector3:
	return (_portals[which]["frame"] as Transform3D).affine_inverse() * p

# ---------------------------------------------------------------- ground map layer

func in_area(x: float, z: float) -> bool:
	## Cheap reject first, like every other layer: the ground map asks this on every classification.
	for prt in _portals:
		var l: Vector3 = (prt["frame"] as Transform3D).affine_inverse() * Vector3(x, 0.0, z)
		if l.z <= 0.0 and l.z >= -tube_len and absf(l.x) <= tube_w * 0.5:
			return true
	return false

func on_road(x: float, z: float) -> bool:
	return in_area(x, z)

func surface_at(x: float, z: float) -> int:
	## A road tunnel is paved. The generated-area layer reports DIRT for its roads; this optional
	## hook is what lets a layer say something else without every consumer learning about tunnels.
	return GroundMap.Surface.ASPHALT

func current_area() -> int:
	return _current

func transitions() -> int:
	return _transitions
