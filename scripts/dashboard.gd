extends Node3D
## In-cabin gauge cluster, styled after a modern LCD racing display: a dark screen in a black
## pod carrying an analog TACHOMETER (left) and SPEEDOMETER (right), with the current gear as a
## blue badge in the middle of the speedo. Built procedurally from primitives like the rest of
## the car and parented to the vehicle, so it rides with it.
##
## It sits alongside the existing binnacle rev bar, which stays: the bar is the peripheral-vision
## shift cue you catch without looking, the dials are the instruments you read.
##
## Both faces graduate themselves off the CAR, not off constants: the tacho runs to the next whole
## 1000 past redline_rpm with its red zone starting at shift_light_frac, and the speedo's range is
## the car's theoretical top speed (redline through the tallest gear and the final drive). Change
## a gear ratio or the redline on the Tab panel and the faces re-scale to match.

var car                                   # the vehicle (untyped so get_engine() resolves dynamically)

@export var cluster_pos := Vector3(-0.35, 0.582, -0.205)   # driver's side (LHD), LOW on the dash: the
                                                           # pod must stay under the horizon so it never
                                                           # eats the road in cockpit view
@export var cluster_tilt := -24.0         # deg about X: the screen aims at the cockpit camera
@export var screen_size := Vector2(0.300, 0.158)   # trimmed to the content: dead margin here
                                                  # is screen area stolen from the road ahead
@export var dial_radius := 0.062
@export var dial_gap := 0.072              # centre-to-centre half-spacing of the two dials
@export var dial_y := -0.016               # dials sit low on the screen, clearing the shift strip
@export var needle_tau := 0.05             # s, instrument damping (a real needle has mass)

const SWEEP_START := 215.0                 # deg, needle at zero (lower left)
const SWEEP := 250.0                       # deg of travel, clockwise to lower right

# palette lifted from the reference display
const C_POD := Color(0.055, 0.055, 0.062)
const C_SCREEN := Color(0.035, 0.055, 0.105)
const C_GLOW := Color(0.06, 0.11, 0.22)
const C_FACE := Color(0.022, 0.035, 0.075)
const C_TICK := Color(0.36, 0.86, 0.96)
const C_TICK_MINOR := Color(0.20, 0.52, 0.66)
const C_RED := Color(0.97, 0.24, 0.16)
const C_TEXT := Color(0.94, 0.97, 1.0)
const C_DIM := Color(0.52, 0.66, 0.78)
const C_NEEDLE := Color(0.97, 0.98, 1.0)
const C_HUB := Color(0.10, 0.42, 0.95)
const C_BADGE := Color(0.07, 0.34, 0.88)

var _tach_needle: Node3D
var _speed_needle: Node3D
var _gear_lbl: Label3D
var _speed_lbl: Label3D
var _rpm_max := 8000.0
var _kmh_max := 280.0
var _rpm_shown := 0.0
var _kmh_shown := 0.0

func _mat(c: Color) -> StandardMaterial3D:
	# unshaded: the cluster reads the same at noon and at night, and never eats a light pass.
	# (An unshaded StandardMaterial3D ignores emission - colour goes in albedo, see CLAUDE.md.)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m

func _box(size: Vector3, pos: Vector3, col: Color, roll_deg := 0.0, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(col)
	mi.position = pos
	if not is_zero_approx(roll_deg):
		mi.rotation.z = deg_to_rad(roll_deg)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else self).add_child(mi)
	return mi

func _disc(radius: float, thickness: float, pos: Vector3, col: Color) -> MeshInstance3D:
	# a CylinderMesh spins about its own Y, so tip it 90 deg to face the driver (cluster +Z)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = thickness
	cm.radial_segments = 44
	mi.mesh = cm
	mi.material_override = _mat(col)
	mi.position = pos
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _label(txt: String, pos: Vector3, height: float, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = txt
	l.font_size = 64                        # rasterised at 64 px, then scaled by pixel_size
	l.pixel_size = height / 64.0            # so `height` is the glyph height in metres
	l.modulate = col
	l.outline_size = 7
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	l.double_sided = true
	l.position = pos
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(l)
	return l

func _dial_angle(frac: float) -> float:
	# needle rotation about the cluster's +Z for a 0..1 reading. The needle mesh points at
	# 12 o'clock when unrotated, so subtract the 90 deg between "up" and the +X datum.
	return deg_to_rad(SWEEP_START - SWEEP * clampf(frac, 0.0, 1.0) - 90.0)

func _build_dial(cx: float, majors: int, per_tick: float, span: float, red_from: float) -> Node3D:
	# one instrument: glow, face, graduations (red past red_from), numerals, needle, hub
	var r := dial_radius
	_disc(r * 1.02, 0.003, Vector3(cx, dial_y, 0.0015), C_GLOW)
	_disc(r * 0.97, 0.003, Vector3(cx, dial_y, 0.0025), C_FACE)
	for i in range(majors * 2 + 1):
		var frac := float(i) / float(majors * 2)
		var value := frac * span
		var is_major := i % 2 == 0
		var a := deg_to_rad(SWEEP_START - SWEEP * frac)
		var len_t: float = (r * 0.17) if is_major else (r * 0.095)
		var wid: float = 0.0045 if is_major else 0.0026
		var rad := r * 0.93 - len_t * 0.5
		var col := C_TICK if is_major else C_TICK_MINOR
		if red_from > 0.0 and value >= red_from:
			col = C_RED
		# a tick is a bar laid along the radius, so roll it to stand perpendicular to the arc
		_box(Vector3(wid, len_t, 0.0025), Vector3(cx + cos(a) * rad, dial_y + sin(a) * rad, 0.004), col,
			rad_to_deg(a) - 90.0)
		if is_major:
			var nr := r * 0.62
			_label(str(int(round(value / per_tick))), Vector3(cx + cos(a) * nr, dial_y + sin(a) * nr, 0.006),
				r * 0.21, C_TEXT if (red_from <= 0.0 or value < red_from) else C_RED)
	# needle on its own pivot at the dial centre, with a short counterweight tail past the hub
	var pivot := Node3D.new()
	pivot.position = Vector3(cx, dial_y, 0.011)
	add_child(pivot)
	var nl := r * 0.78
	_box(Vector3(0.0045, nl, 0.003), Vector3(0, nl * 0.5 - r * 0.16, 0), C_NEEDLE, 0.0, pivot)
	_disc(r * 0.155, 0.006, Vector3(cx, dial_y, 0.014), C_HUB)
	return pivot

func _ready() -> void:
	position = cluster_pos
	rotation_degrees = Vector3(cluster_tilt, 0, 0)
	if car != null:
		# ranges DERIVED from the car: tacho to the next whole 1000 past redline, speedo to the
		# theoretical top speed (redline through the tallest gear), rounded up to a round 20.
		_rpm_max = ceil(float(car.redline_rpm) / 1000.0) * 1000.0
		var ratios: Array = car.gear_ratios
		var top: float = float(ratios[ratios.size() - 1]) * float(car.final_drive)
		var v_max: float = (float(car.redline_rpm) * TAU / 60.0) / maxf(top, 0.01) * float(car.wheel_radius) * 3.6
		_kmh_max = maxf(ceil(v_max / 20.0) * 20.0, 40.0)
	var red_from := _rpm_max * 2.0          # off the scale unless the car tells us otherwise
	if car != null:
		red_from = float(car.redline_rpm) * float(car.shift_light_frac)
	# pod + screen
	_box(Vector3(screen_size.x + 0.026, screen_size.y + 0.016, 0.012), Vector3(0, 0, -0.008), C_POD)
	_box(Vector3(screen_size.x, screen_size.y, 0.004), Vector3(0, 0, 0.0), C_SCREEN)
	# tacho left, speedo right
	_tach_needle = _build_dial(-dial_gap, int(_rpm_max / 1000.0), 1000.0, _rpm_max, red_from)
	_speed_needle = _build_dial(dial_gap, maxi(int(_kmh_max / 40.0), 1), 1.0, _kmh_max, 0.0)
	_label("RPM", Vector3(-dial_gap, dial_y + dial_radius * 0.30, 0.006), dial_radius * 0.16, C_TEXT)
	_label("x1000", Vector3(-dial_gap, dial_y + dial_radius * 0.14, 0.006), dial_radius * 0.12, C_DIM)
	# gear badge in the middle of the speedo, with a digital km/h under it (the reference's layout)
	_label("km/h", Vector3(dial_gap, dial_y + dial_radius * 0.40, 0.016), dial_radius * 0.15, C_DIM)
	_box(Vector3(0.030, 0.028, 0.004), Vector3(dial_gap, dial_y + dial_radius * 0.06, 0.016), C_BADGE)
	_gear_lbl = _label("N", Vector3(dial_gap, dial_y + dial_radius * 0.06, 0.019), 0.021, C_TEXT)
	_box(Vector3(0.040, 0.013, 0.004), Vector3(dial_gap, dial_y - dial_radius * 0.30, 0.016), C_GLOW)
	_speed_lbl = _label("0", Vector3(dial_gap, dial_y - dial_radius * 0.30, 0.019), 0.0095, C_TEXT)

func _process(delta: float) -> void:
	if car == null or _tach_needle == null:
		return
	var e: Dictionary = car.get_engine()
	# instrument damping: a real needle has mass, so chase the value instead of snapping to it
	var k := clampf(delta / maxf(needle_tau, delta), 0.0, 1.0)
	_rpm_shown += (float(e["rpm"]) - _rpm_shown) * k
	_kmh_shown += (float(e["speed_kmh"]) - _kmh_shown) * k
	_tach_needle.rotation.z = _dial_angle(_rpm_shown / _rpm_max)
	_speed_needle.rotation.z = _dial_angle(_kmh_shown / _kmh_max)
	var g := int(e["gear"])                  # A1 gear map: -1 = R, 0 = N, 1..6 forward
	_gear_lbl.text = "N" if g == 0 else ("R" if g == -1 else str(g))
	_speed_lbl.text = "%d" % int(round(maxf(_kmh_shown, 0.0)))
