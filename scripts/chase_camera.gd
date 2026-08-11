extends Camera3D
## Simple smoothed chase camera. Sits behind + above the target and looks at it.

var target: Node3D

@export var distance := 8.0     # metres behind
@export var height := 3.2       # metres above
@export var look_height := 1.0  # aim point above target origin
@export var smooth := 6.0       # position lerp speed

# Right-stick look (driven by world.gd): the camera ORBITS the car rather than turning in place,
# so third person keeps the car in frame while you look around it. Yaw is taken about world UP,
# not the car's own up, so the orbit doesn't tumble when the car rolls or pitches.
var orbit_yaw := 0.0            # rad, 0 = directly behind
var orbit_pitch := 0.0          # rad, + = rise and look down on the car

func _ready() -> void:
	current = true

func _physics_process(delta: float) -> void:
	if target == null:
		return
	var t := target.global_transform
	# target forward is -Z, so +Z (t.basis.z) is directly behind it
	var behind := t.basis.z.rotated(Vector3.UP, orbit_yaw)
	var desired := t.origin + behind * distance + Vector3.UP * (height + sin(orbit_pitch) * distance)
	global_position = global_position.lerp(desired, clampf(smooth * delta, 0.0, 1.0))
	look_at(t.origin + Vector3.UP * look_height, Vector3.UP)
