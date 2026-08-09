extends CanvasLayer
## Telemetry overlay. M1: live per-wheel load Fz, slip angle, and grip utilisation.

var car   # the vehicle (untyped so custom methods resolve cleanly)
var _label: Label
var _fs := 20   # HUD font size (-/+ to resize)
var _v_prev := Vector3.ZERO   # for the G-meter (accel = dv/dt)
var _g_lat := 0.0
var _g_lon := 0.0
var time_trial   # the TimeTrial node (owns lap timing for all circuits); wired by world.gd

func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", _fs)
	_label.add_theme_color_override("font_color", Color(0.88, 1.0, 0.9))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)

func _set_fs(v: int) -> void:
	_fs = clampi(v, 10, 48)
	_label.add_theme_font_size_override("font_size", _fs)

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("hud_bigger"):
		_set_fs(_fs + 2)
	if Input.is_action_just_pressed("hud_smaller"):
		_set_fs(_fs - 2)
	if car == null:
		return
	var v: Vector3 = car.linear_velocity
	var speed_kmh: float = v.length() * 3.6
	var fwd: Vector3 = -car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	var fwd_kmh: float = v.dot(fwd) * 3.6
	var steer := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	# G-meter: smoothed longitudinal + lateral acceleration in g
	var accel := (v - _v_prev) / maxf(delta, 0.001)
	_v_prev = v
	_g_lon = lerpf(_g_lon, accel.dot(fwd) / 9.81, 0.25)
	_g_lat = lerpf(_g_lat, accel.dot(right) / 9.81, 0.25)

	var lines := PackedStringArray()
	if car.has_method("get_engine"):
		lines.append("RALLY SIM - M2  (slip-ratio drivetrain)     fps %d" % Engine.get_frames_per_second())
	else:
		lines.append("RALLY SIM - M1  (raycast wheels + brush tire)     fps %d" % Engine.get_frames_per_second())
	lines.append("")
	lines.append("speed     %7.1f km/h   (fwd %7.1f)" % [speed_kmh, fwd_kmh])
	lines.append("throttle  %4.2f   brake %4.2f   steer %+4.2f" % [
		Input.get_action_strength("throttle"),
		Input.get_action_strength("brake"),
		steer])
	if car.has_method("get_engine"):
		var e: Dictionary = car.get_engine()
		var g := int(e["gear"])
		var gtxt := "N"                      # A1 gear map: -1 = R, 0 = N, 1..6 forward
		if g == -1:
			gtxt = "R"
		elif g > 0:
			gtxt = str(g)
		var rpm := float(e["rpm"])
		var redline: float = car.redline_rpm
		var max_gear: int = car.gear_ratios.size()
		var frac := clampf(rpm / maxf(redline, 1.0), 0.0, 1.0)
		var shift := "   <<< UPSHIFT >>>" if frac > 0.92 and g > 0 and g < max_gear else ""
		if bool(e.get("stalled", false)):
			shift = "   ** STALLED - [I] ignition **"
		lines.append("gear  %s   rpm %5.0f %s%s" % [gtxt, rpm, _rev_bar(frac), shift])
		var diff_txt := ""
		if car.has_method("diff_preset_name"):
			diff_txt = "  diff %-9s" % car.diff_preset_name()
		lines.append("drive %s%s   G  lon %+4.2f  lat %+4.2f" % [str(e["mode"]), diff_txt, _g_lon, _g_lat])
	if time_trial != null:
		var ti: Dictionary = time_trial.active_info()
		lines.append("%-12s lap %s  last %s  best %s" % [ti["name"], _fmt_time(ti["lap"]), _fmt_time(ti["last"]), _fmt_time(ti["best"])])
	lines.append("")

	var wheels: Array = car.get_wheels()
	var names := ["FL", "FR", "RL", "RR"]
	lines.append("wheel  Fz(kN) slipR  slipA   temp wear  grip")
	for i in range(wheels.size()):
		var w = wheels[i]
		var grounded: String = " " if w.contact else "air"
		var tail: String = "PUNCTURE!" if w.punctured else _bar(w.util)
		lines.append("  %s %s %6.2f %5.2f %+6.1f %4.0fC %3.0f%% %s" % [
			names[i], grounded, w.Fz / 1000.0, w.slip, rad_to_deg(w.slip_angle), w.temp, w.tyre_wear * 100.0, tail])

	lines.append("")
	lines.append("[W/S] gas/brake  [A/D] steer  [Q/E] gears (R-N-1..6)  [Shift] clutch  [I] ignition  [T] AWD/RWD/FWD  [1/2/3] diff open/visc/rally  [Space] handbrake  [C] cam  [B] circuit  [L] time  [P] test puncture  [Tab] tune  [-/+] hud  [R] reset")
	_label.text = "\n".join(lines)

func _fmt_time(t: float) -> String:
	if t <= 0.0:
		return "  --  "
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]

func _rev_bar(frac: float) -> String:
	# 14-segment rev bar; the last few segments read as the shift-light zone
	var n := int(round(clampf(frac, 0.0, 1.0) * 14.0))
	var s := ""
	for k in range(14):
		if k >= n:
			s += "."
		elif k >= 12:
			s += "!"      # redline zone
		else:
			s += "|"
	return "[" + s + "]"

func _bar(u: float) -> String:
	var n := int(round(clampf(u, 0.0, 1.0) * 10.0))
	return "[" + "|".repeat(n) + " ".repeat(10 - n) + "]"
