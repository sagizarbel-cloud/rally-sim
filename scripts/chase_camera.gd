extends Camera3D
## Simple smoothed chase camera. Sits behind + above the target and looks at it.

var target: Node3D

@export var distance := 8.0     # metres behind
@export var height := 3.2       # metres above
@export var look_height := 1.0  # aim point above target origin
@export var smooth := 6.0       # position lerp speed

func _ready() -> void:
	current = true

func _physics_process(delta: float) -> void:
	if target == null:
		return
	var t := target.global_transform
	# target forward is -Z, so +Z (t.basis.z) is directly behind it
	var behind := t.basis.z
	var desired := t.origin + behind * distance + Vector3.UP * height
	global_position = global_position.lerp(desired, clampf(smooth * delta, 0.0, 1.0))
	look_at(t.origin + Vector3.UP * look_height, Vector3.UP)
