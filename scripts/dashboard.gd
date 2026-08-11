extends Node3D
## In-cabin gauge cluster: an analog TACHOMETER dial, a SPEEDOMETER dial and a numeric gear
## readout, built procedurally from primitives like the rest of the car and parented to the
## vehicle so it rides with it. Sits alongside the existing binnacle rev bar (which stays -
## the bar is the peripheral-vision shift cue, the clock is the readable instrument).
##
## Both dials scale themselves off the CAR, not off constants: the tacho's range comes from
## redline_rpm and its red zone from shift_light_frac, and the speedo's range is the car's
## theoretical top speed (redline through the tallest gear and final drive). Change a gear
## ratio or the redline on the Tab panel and the faces re-scale to match.

var car                                   # the vehicle (untyped so get_engine() resolves dynamically)

@export var dial_radius := 0.072          # m, face radius of each dial
@export var dial_gap := 0.086             # m, centre-to-centre half-spacing of the two dials
@export var cluster_pos := Vector3(-0.35, 0.585, -0.205)   # binnacle, driver's side (LHD)
@export var cluster_tilt := -24.0         # deg about X: faces aim at the cockpit camera
@export var needle_tau := 0.05            # s, instrument damping (a needle has mass)

const SWEEP_START := 210.0                # deg, needle at zero (lower left)
const SWEEP := 240.0                      # deg of travel, clockwise to lower right

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

func _box(size: Vector3, pos: Vector3, mat: StandardMaterial3D, roll_deg := 0.0, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	if not is_zero_approx(roll_deg):
		mi.rotation.z = deg_to_rad(roll_deg)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else self).add_child(mi)
	return mi

func _disc(radius: float, thickness: float, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	# a CylinderMesh spins about its own Y, so tip it 90 deg to face the driver (cluster +Z)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = thickness
	cm.radial_segments = 40
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _label(txt: String, pos: Vector3, height: float, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = txt
	l.font_size = 64                        # rendered at 64 px then scaled by pixel_size
	l.pixel_size = height / 64.0            # so `height` is the cap height in metres
	l.modulate = col
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

func _build_dial(cx: float, ticks: int, per_tick: float, unit: String, red_from: float, span: float) -> Node3D:
	# one instrument: bezel, face, graduations (red past red_from), numerals, needle, hub
	var r := dial_radius
	_disc(r * 1.06, 0.004, Vector3(cx, 0, -0.002), _mat(Color(0.30, 0.31, 0.34)))   # bezel ring
	_disc(r, 0.004, Vector3(cx, 0, 0.001), _mat(Color(0.045, 0.045, 0.05)))         # face
	var tick_col := _mat(Color(0.88, 0.90, 0.92))
	var red_col := _mat(Color(0.92, 0.14, 0.10))
	var minor := _mat(Color(0.55, 0.57, 0.60))
	for i in range(ticks * 2 + 1):
		var frac := float(i) / float(ticks * 2)
		var value := frac * span
		var is_major := i % 2 == 0
		var a := deg_to_rad(SWEEP_START - SWEEP * frac)
		var len_t: float = (r * 0.20) if is_major else (r * 0.11)
		var wid: float = 0.0055 if is_major else 0.003
		var rad := r * 0.90 - len_t * 0.5
		var col: StandardMaterial3D = tick_col if is_major else minor
		if red_from > 0.0 and value >= red_from:
			col = red_col
		# a tick is a bar laid along the radius, so roll it to stand perpendicular to the arc
		_box(Vector3(wid, len_t, 0.003), Vector3(cx + cos(a) * rad, sin(a) * rad, 0.004),
			col, rad_to_deg(a) - 90.0)
		if is_major:
			var num := int(round(value / per_tick))
			var nr := r * 0.62
			_label(str(num), Vector3(cx + cos(a) * nr, sin(a) * nr, 0.006), r * 0.24,
				Color(0.93, 0.95, 0.97) if (red_from <= 0.0 or value < red_from) else Color(0.95, 0.35, 0.28))
	_label(unit, Vector3(cx, -r * 0.42, 0.006), r * 0.15, Color(0.62, 0.65, 0.70))
	# needle on its own pivot at the dial centre, with a short counterweight tail past the hub
	var pivot := Node3D.new()
	pivot.position = Vector3(cx, 0, 0.010)
	add_child(pivot)
	var nl := r * 0.80
	_box(Vector3(0.0055, nl, 0.004), Vector3(0, nl * 0.5 - r * 0.15, 0), _mat(Color(0.93, 0.20, 0.12)), 0.0, pivot)
	_disc(r * 0.10, 0.006, Vector3(cx, 0, 0.013), _mat(Color(0.18, 0.19, 0.21)))     # hub cap
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
	var red_from: float = _rpm_max
	if car != null:
		red_from = float(car.redline_rpm) * float(car.shift_light_frac)
	# tacho left, speedo right
	_tach_needle = _build_dial(-dial_gap, int(_rpm_max / 1000.0), 1000.0, "x1000 rpm", red_from, _rpm_max)
	_speed_needle = _build_dial(dial_gap, int(_kmh_max / 40.0), 1.0, "km/h", 0.0, _kmh_max)
	# gear number between the dials, with a digital speed under it
	_box(Vector3(0.052, 0.050, 0.004), Vector3(0, 0.004, 0.002), _mat(Color(0.02, 0.02, 0.025)))
	_gear_lbl = _label("N", Vector3(0, 0.004, 0.006), 0.036, Color(0.99, 0.78, 0.16))
	_speed_lbl = _label("0", Vector3(0, -0.040, 0.006), 0.020, Color(0.90, 0.93, 0.96))

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
	_gear_lbl.modulate = Color(0.55, 0.75, 1.0) if g == -1 else Color(0.99, 0.78, 0.16)
	_speed_lbl.text = "%d" % int(round(maxf(_kmh_shown, 0.0)))
