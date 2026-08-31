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
var tube_segments := 22            ## the tube follows the ground in this many steps
var floor_lift := 0.12             ## floor clearance over the ground, so the terrain collider never wins

var _portals: Array = []                  ## [{frame, name}] index matches Area
var _current := Area.CALIBRATION
var _armed := true                        ## false while the car is still on the plane it just used
var _transitions := 0

# ---------------------------------------------------------------- build

func build() -> void:
	_portals.resize(Area.size())
	_portals[Area.CALIBRATION] = _make_portal(_calibration_mouth(), "PortalCalibration",
			Callable(stage, "_height"))
	_portals[Area.STAGE] = _make_portal(_stage_mouth(), "PortalStage",
			Callable(stage_area, "height_at"))
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
	## A portal frame: origin at the mouth ON THE GROUND, -Z pointing INWARD. Driving "forward" in
	## this frame is driving into the tunnel, which is what makes the swap a plain transform.
	##
	## THE TUBE FOLLOWS THE TERRAIN; it is not a flat box laid over it. Two earlier versions got this
	## wrong in opposite directions. Burrowing at constant height wedged the car between the tunnel
	## floor and the hillside. Raising the whole tube to clear the highest ground beneath it then
	## produced the opposite failure and it is the one the driver hit - the stage portal bores into
	## rising ground (terrain -6.77 m at the mouth, +1.14 m some 64 m in), so clearing the peak left
	## the MOUTH 8.15 m in the air behind a ledge no car can climb. A tunnel through hilly ground has
	## to be built the way a real one is: along the ground, at whatever height the ground is.
	var g: float = float(height_fn.call(mouth.x, mouth.z))
	var o := Vector3(mouth.x, g + floor_lift, mouth.z)
	return Transform3D(Basis(), o).looking_at(o + inward, Vector3.UP)

func _profile(frame: Transform3D, height_fn: Callable) -> PackedFloat32Array:
	## Floor height at each segment joint, in the frame's LOCAL y. The tube is built to this, and the
	## swap reads it too - see _swap, which has to preserve the car's height above the FLOOR rather
	## than above the mouth, because two tubes on different ground have different floors.
	var inward: Vector3 = -frame.basis.z
	var side: Vector3 = frame.basis.x
	var out := PackedFloat32Array()
	for i in range(tube_segments + 1):
		var q: Vector3 = frame.origin + inward * (tube_len * float(i) / float(tube_segments))
		# highest point ACROSS the tube at this station, so the floor never dips under the ground
		var top := -1e9
		for j in range(-2, 3):
			var r: Vector3 = q + side * (tube_w * 0.5 * float(j) / 2.0)
			top = maxf(top, float(height_fn.call(r.x, r.z)))
		out.append(top + floor_lift - frame.origin.y)
	return out

func _make_portal(frame: Transform3D, pname: String, height_fn: Callable) -> Dictionary:
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
	var prof := _profile(frame, height_fn)
	var seg: float = tube_len / float(tube_segments)
	var half_w := tube_w * 0.5
	for i in range(tube_segments):
		var y0: float = prof[i]
		var y1: float = prof[i + 1]
		var mid := Vector3(0.0, (y0 + y1) * 0.5, -(float(i) + 0.5) * seg)
		var dir := Vector3(0.0, y1 - y0, -seg).normalized()
		var sx := Transform3D(Basis(), mid).looking_at(mid + dir, Vector3.UP)
		var hyp: float = sqrt(seg * seg + (y1 - y0) * (y1 - y0)) + 0.05
		_slab(body, Vector3(tube_w, 0.4, hyp), sx * Transform3D(Basis(), Vector3(0.0, -0.2, 0.0)), floor_mat)
		_slab(body, Vector3(tube_w, 0.4, hyp), sx * Transform3D(Basis(), Vector3(0.0, tube_h, 0.0)), mat)
		_slab(body, Vector3(0.5, tube_h, hyp), sx * Transform3D(Basis(), Vector3(-half_w, tube_h * 0.5, 0.0)), mat)
		_slab(body, Vector3(0.5, tube_h, hyp), sx * Transform3D(Basis(), Vector3(half_w, tube_h * 0.5, 0.0)), mat)
	# a rim around the mouth so it reads as a portal from outside rather than a hole
	_slab(body, Vector3(tube_w + 3.0, 1.2, 1.0), Transform3D(Basis(), Vector3(0.0, tube_h + 0.6, -0.5)), mat)
	return {"frame": frame, "name": pname, "body": body, "prof": prof,
		"gate_floor": float(prof[tube_segments / 2])}

func _slab(body: StaticBody3D, size: Vector3, xform: Transform3D, mat: StandardMaterial3D) -> void:
	## The CollisionShape3D goes DIRECTLY on the StaticBody3D, never under an intermediate node.
	## Godot only registers shapes that are direct children of the CollisionObject3D, and when the
	## tube was refactored into ground-following segments each segment got its own Node3D - which
	## silently removed every collider in the tunnel. The car then fell straight through the floor:
	## measured 15.46 m BELOW it by the time it reached the transition plane, which read as a broken
	## swap because the swap faithfully carried that height across.
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.transform = xform
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xform
	body.add_child(cs)

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
	# HEIGHT IS PRESERVED ABOVE THE FLOOR, NOT ABOVE THE MOUTH. Now that each tube follows its own
	# ground, the floor at the transition plane sits at a different local height in each one - the
	# stage tube climbs 8 m from its mouth, the calibration tube falls. Carrying the car's raw local
	# y across would drop it through the floor at one end and leave it in mid-air at the other.
	dst.origin.y += float(_portals[to]["gate_floor"]) - float(_portals[from]["gate_floor"])
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
