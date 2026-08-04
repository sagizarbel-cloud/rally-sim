extends RigidBody3D
## M1 vehicle - the real thing (replaces the M0 placeholder box).
##
## 4x raycast wheels, each with:
##   * spring-damper SUSPENSION producing the wheel's vertical load Fz
##   * a brush / Fiala TIRE model: lateral force from slip angle, longitudinal force
##     from drive/brake, both bounded by a combined-slip FRICTION ELLIPSE (|F| <= mu*Fz)
## AWD, power-limited engine, speed-sensitive steering, handbrake locks the rears.
##
## Grounded in: raycast-vehicle model (Bullet btRaycastVehicle / Godot VehicleBody3D),
## brush tire + friction ellipse (Gillespie, Beckman, Pacejka linear region). The full
## Pacejka Magic Formula with per-wheel spin state (true slip RATIO) lands in M2; engine
## torque curve + gearbox + AWD diffs in M4; deformable-terrain forces in M3.

# --- Chassis ---
@export var chassis_mass := 1250.0
@export var body_size := Vector3(1.8, 0.55, 4.2)   # W, H, L (forward = -Z)

# --- Suspension (per wheel) ---
@export var wheel_radius := 0.34
@export var rest_length := 0.45          # suspension free length (m)
@export var spring_k := 44000.0          # N/m (stiffer = less body roll)
@export var damper_c := 5400.0           # N*s/m
@export var max_travel := 0.42           # compression limit (m)

# --- Tire ---
@export var mu_long := 1.75              # longitudinal grip (accel / brake / handbrake) - punchy
@export var mu_lat := 1.3                 # lateral grip (cornering) - lower = more slide / rally feel
@export var corner_stiffness := 14.0     # lateral brush slope (force per rad per unit Fz)
@export var roll_resist := 0.02          # rolling resistance coefficient

# --- Drive / brake ---
@export var engine_power := 520000.0     # W  (~700 hp) - lots of overall power
@export var max_drive_force := 20000.0   # N  total traction cap at low speed
@export var launch_boost := 2.8          # extra low-speed drive (fakes a short 1st gear)
@export var launch_taper := 16.0         # m/s over which the boost fades to 1.0
@export var brake_force := 22000.0       # N  total
@export var handbrake_strength := 0.9    # rear braking under handbrake (x brake_force)
@export var rear_grip_cut := 0.2         # rear lateral grip while handbraking (lower = slidier)
@export var max_steer_deg := 34.0
@export var steer_speed_falloff := 0.35  # reduce steer lock as speed rises
@export var drag_k := 1.6                # aero drag: F = drag_k * v^2

var spawn_transform := Transform3D(Basis(), Vector3(0, 1.4, 0))

class Wheel:
	var pos: Vector3            # local mount offset
	var steer: bool
	var drive: bool
	var vis: MeshInstance3D
	var contact := false
	var Fz := 0.0
	var slip_angle := 0.0       # rad
	var util := 0.0             # 0..1 grip usage
	var spin := 0.0             # visual roll angle

var _wheels: Array[Wheel] = []

func _ready() -> void:
	mass = chassis_mass
	can_sleep = false
	# Low CoM near axle height -> high rollover threshold (rally cars sit low).
	# Godot computes torque about the CoM, so forces applied at contact points still
	# resolve correctly with this offset.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.32, 0)
	collision_layer = 2          # car = layer 2
	collision_mask = 1 | 4       # collide with ground/static (1) + cones (4)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.3            # chassis-vs-world if it ever bottoms out / hits things
	physics_material_override = pm
	_build_body()
	_build_wheels()
	respawn()

func _build_body() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = body_size
	col.shape = box
	add_child(col)

	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = body_size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.80, 0.16, 0.13)
	mesh.material_override = mat
	add_child(mesh)

	var nose := MeshInstance3D.new()
	var nb := BoxMesh.new(); nb.size = Vector3(0.6, 0.28, 0.5)
	nose.mesh = nb; nose.position = Vector3(0, 0.32, -body_size.z * 0.5)
	var nmat := StandardMaterial3D.new(); nmat.albedo_color = Color(1.0, 0.9, 0.15)
	nose.material_override = nmat
	add_child(nose)

func _build_wheels() -> void:
	var defs := [
		[Vector3(-0.82, -0.1, -1.35), true,  true],   # FL
		[Vector3( 0.82, -0.1, -1.35), true,  true],   # FR
		[Vector3(-0.82, -0.1,  1.35), false, true],   # RL
		[Vector3( 0.82, -0.1,  1.35), false, true],   # RR
	]
	for d in defs:
		var w := Wheel.new()
		w.pos = d[0]; w.steer = d[1]; w.drive = d[2]
		var vis := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = wheel_radius; cyl.bottom_radius = wheel_radius; cyl.height = 0.24
		vis.mesh = cyl
		vis.rotation_degrees = Vector3(0, 0, 90)   # axle across the car (X)
		var wmat := StandardMaterial3D.new(); wmat.albedo_color = Color(0.07, 0.07, 0.08)
		vis.material_override = wmat
		add_child(vis)
		w.vis = vis
		_wheels.append(w)

func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("reset"):
		respawn(); return

	var throttle := Input.get_action_strength("throttle")
	var brake := Input.get_action_strength("brake")
	var handbrake := Input.get_action_strength("handbrake")
	var steer_in := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")

	var speed := linear_velocity.length()
	var steer_reduce := 1.0 - clampf(speed / 45.0, 0.0, 1.0) * steer_speed_falloff
	var steer_angle := deg_to_rad(max_steer_deg) * steer_in * steer_reduce

	var n_drive := 0
	for w in _wheels:
		if w.drive: n_drive += 1
	n_drive = maxi(n_drive, 1)

	var space := get_world_3d().direct_space_state
	var up := global_transform.basis.y

	for w in _wheels:
		var mount_world := global_transform * w.pos
		var ray_len := rest_length + wheel_radius
		var q := PhysicsRayQueryParameters3D.create(mount_world, mount_world - up * ray_len)
		q.exclude = [get_rid()]
		q.collision_mask = 1                       # ride only on ground/static/ramps
		var hit := space.intersect_ray(q)

		if hit.is_empty():
			w.contact = false; w.Fz = 0.0; w.slip_angle = 0.0; w.util = 0.0
			# keep the wheel properly oriented (axle across the car) while airborne
			var steer_a := Basis(Vector3.UP, steer_angle) if w.steer else Basis.IDENTITY
			var tip_a := Basis(Vector3(0, 0, 1), PI * 0.5)
			w.vis.global_transform = Transform3D(global_transform.basis * (steer_a * tip_a), mount_world - up * rest_length)
			continue

		w.contact = true
		var hit_pos: Vector3 = hit.position
		var n: Vector3 = hit.normal
		var dist := mount_world.distance_to(hit_pos)
		var compression := clampf((rest_length + wheel_radius) - dist, 0.0, max_travel)

		var contact_off := hit_pos - global_position
		var point_vel := linear_velocity + angular_velocity.cross(contact_off)
		var comp_vel := -point_vel.dot(up)          # +ve while compressing

		# --- suspension: vertical load ---
		var Fz := maxf(0.0, spring_k * compression + damper_c * comp_vel)
		w.Fz = Fz
		apply_force(n * Fz, contact_off)

		# --- tire frame (steered, projected onto the ground plane) ---
		var fwd := -global_transform.basis.z
		if w.steer:
			fwd = fwd.rotated(up, steer_angle)
		fwd = (fwd - n * fwd.dot(n)).normalized()
		var right := n.cross(fwd).normalized()

		var v_long := point_vel.dot(fwd)
		var v_lat := point_vel.dot(right)

		# lateral: slip-angle brush force, saturated by friction
		var slip_angle := atan2(v_lat, absf(v_long) + 0.6)
		w.slip_angle = slip_angle
		var Fy := clampf(-corner_stiffness * Fz * slip_angle, -mu_lat * Fz, mu_lat * Fz)

		# longitudinal: drive + brake/reverse + rolling resistance
		var Fx := 0.0
		if w.drive and throttle > 0.0:
			var gear1 := 1.0 + (launch_boost - 1.0) * (1.0 - clampf(absf(v_long) / launch_taper, 0.0, 1.0))
			var drive := minf(max_drive_force * gear1, engine_power / maxf(absf(v_long), 3.0))
			Fx += (drive * throttle) / float(n_drive)
		# handbrake: decelerate opposing motion in EITHER direction; lock + slide the rears
		if handbrake > 0.0:
			if not w.steer:
				Fy *= rear_grip_cut                             # rears lose lateral grip -> slide
			if absf(v_long) > 0.2:
				Fx -= (brake_force * handbrake_strength * signf(v_long)) / 4.0  # scrub speed either way
		# foot brake: decelerate when moving forward, reverse when stopped / rolling back
		if brake > 0.0:
			if v_long > 0.5:
				Fx -= (brake_force * brake) / 4.0
			else:
				Fx -= (max_drive_force * 0.4 * brake) / 4.0     # hold to reverse
		Fx -= roll_resist * Fz * signf(v_long)

		# elliptical combined-slip limit (separate longitudinal / lateral grip)
		var cap_long := mu_long * Fz
		var cap_lat := mu_lat * Fz
		if cap_long > 0.001 and cap_lat > 0.001:
			var nx := Fx / cap_long
			var ny := Fy / cap_lat
			var e := sqrt(nx * nx + ny * ny)
			if e > 1.0:
				Fx /= e
				Fy /= e
			w.util = minf(e, 1.0)
		else:
			w.util = 0.0

		apply_force(fwd * Fx + right * Fy, contact_off)

		# visual wheel: axle across the car (X), yaw by steer, roll by spin
		w.spin += (v_long / wheel_radius) * delta
		var steer_b := Basis(Vector3.UP, steer_angle) if w.steer else Basis.IDENTITY
		var tip_b := Basis(Vector3(0, 0, 1), PI * 0.5)   # cylinder axis (Y) -> car X
		var roll_b := Basis(Vector3(1, 0, 0), w.spin)    # spin about the axle
		var wb := steer_b * roll_b * tip_b
		w.vis.global_transform = Transform3D(global_transform.basis * wb, hit_pos + up * wheel_radius)

	# aero drag
	if speed > 0.1:
		apply_central_force(-linear_velocity.normalized() * drag_k * linear_velocity.length_squared())

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = spawn_transform

# --- telemetry for the HUD ---
func get_wheels() -> Array[Wheel]:
	return _wheels
