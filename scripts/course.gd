extends Node3D
## M1 test course: distance markers (speed feel), a cone slalom, a knockable-cone
## oval circuit (handling/lapping), a jump ramp, and obstacle blocks.
##
## Collision layers:  1 = ground/static/ramp/blocks,  2 = car,  4 = knockables.

func _ready() -> void:
	_build_start_gate()
	_build_distance_markers()
	_build_slalom()
	_build_ramp()
	_build_circuit()
	_build_obstacles()

# ---------------------------------------------------------------- start gate
func _build_start_gate() -> void:
	_post(Vector3(-3.5, 0, -3), "START", Color(0.3, 1.0, 0.4), 2.6)
	_post(Vector3( 3.5, 0, -3), "START", Color(0.3, 1.0, 0.4), 2.6)

# --------------------------------------------------- distance markers (fwd = -Z)
func _build_distance_markers() -> void:
	# long straight for gear/top-speed testing: poles every 100 m, labels every 200 m, to 2 km
	for d in range(100, 2100, 100):
		var z := -float(d)
		_pole(Vector3(-5.0, 0, z), Color(0.9, 0.9, 0.95), 3.0)
		_pole(Vector3( 5.0, 0, z), Color(0.9, 0.9, 0.95), 3.0)
		if d % 200 == 0:
			_label(Vector3(-5.0, 3.6, z), "%d m" % d, Color(1, 0.95, 0.3))

# ---------------------------------------------------------------- cone slalom
func _build_slalom() -> void:
	var x := -35.0
	for i in range(8):
		var z := -30.0 - i * 12.0
		var off := 3.0 if i % 2 == 0 else -3.0
		_cone(Vector3(x + off, 0, z))

# ---------------------------------------------------------------- jump ramp
func _build_ramp() -> void:
	var ramp := StaticBody3D.new()
	ramp.name = "Ramp"
	ramp.collision_layer = 1
	ramp.collision_mask = 1 | 2 | 4
	# shallow rotated slab; car approaches from the +Z (low) end driving toward -Z
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(8, 0.4, 16)
	mi.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.45, 0.45, 0.5)
	mi.material_override = mat
	ramp.add_child(mi)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(8, 0.4, 16)
	col.shape = box
	ramp.add_child(col)
	ramp.rotation_degrees = Vector3(9, 0, 0)      # ~9 deg incline
	ramp.position = Vector3(-70, 1.25, -120)      # off the straight (clear drag strip)
	add_child(ramp)
	_label(Vector3(-70, 3.5, -120), "RAMP", Color(0.8, 0.9, 1.0))

# ---------------------------------------------------------------- oval circuit
func _build_circuit() -> void:
	var cx := 120.0
	var cz := -55.0
	var a := 52.0      # radius along X
	var b := 34.0      # radius along Z
	var n := 30
	for i in range(n):
		var t := TAU * float(i) / float(n)
		var p := Vector3(cx + cos(t) * a, 0, cz + sin(t) * b)
		_cone(p)
	_label(Vector3(cx, 3.0, cz), "CIRCUIT", Color(1.0, 0.6, 0.2))

# ---------------------------------------------------------------- obstacles
func _build_obstacles() -> void:
	# a few solid blocks to bump into (static)
	_block(Vector3(55, 0, -15), Vector3(3, 2, 3), Color(0.4, 0.4, 0.45))
	_block(Vector3(62, 0, -22), Vector3(2, 1, 6), Color(0.4, 0.4, 0.45))
	# a knockable box pyramid to smash
	var base := Vector3(-60, 0, -18)
	for row in range(3):
		var count := 3 - row
		for c in range(count):
			var p := base + Vector3((c - (count - 1) * 0.5) * 1.1, row * 1.05 + 0.5, 0)
			_knock_box(p, Vector3(1, 1, 1))

# ---------------------------------------------------------------- helpers
func _cone(pos: Vector3) -> void:
	var body := RigidBody3D.new()
	body.mass = 1.2
	body.collision_layer = 4
	body.collision_mask = 1 | 2 | 4
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.03; cyl.bottom_radius = 0.22; cyl.height = 0.55
	mesh.mesh = cyl
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(1.0, 0.45, 0.05)
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new(); shape.radius = 0.2; shape.height = 0.55
	col.shape = shape
	body.add_child(col)
	body.position = pos + Vector3(0, 0.3, 0)
	add_child(body)

func _knock_box(pos: Vector3, size: Vector3) -> void:
	var body := RigidBody3D.new()
	body.mass = 4.0
	body.collision_layer = 4
	body.collision_mask = 1 | 2 | 4
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.85, 0.7, 0.35)
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new(); shape.size = size
	col.shape = shape
	body.add_child(col)
	body.position = pos
	add_child(body)

func _block(pos: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 1 | 2 | 4
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = color
	mesh.material_override = mat
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new(); shape.size = size
	col.shape = shape
	body.add_child(col)
	body.position = pos + Vector3(0, size.y * 0.5, 0)
	add_child(body)

func _pole(pos: Vector3, color: Color, height: float) -> void:
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(0.12, height, 0.12)
	mesh.mesh = bm
	var mat := StandardMaterial3D.new(); mat.albedo_color = color
	mesh.material_override = mat
	mesh.position = pos + Vector3(0, height * 0.5, 0)
	add_child(mesh)

func _post(pos: Vector3, text: String, color: Color, height: float) -> void:
	_pole(pos, color, height)
	_label(pos + Vector3(0, height + 0.4, 0), text, color)

func _label(pos: Vector3, text: String, color: Color) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 120
	lbl.pixel_size = 0.012
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = color
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.position = pos
	add_child(lbl)
