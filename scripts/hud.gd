extends CanvasLayer
## Telemetry overlay. M1: live per-wheel load Fz, slip angle, and grip utilisation.

var car   # the vehicle (untyped so custom methods resolve cleanly)
var _fs := 20   # HUD font size (-/+ to resize)
var _v_prev := Vector3.ZERO   # for the G-meter (accel = dv/dt)
var _g_lat := 0.0
var _g_lon := 0.0
var time_trial   # the TimeTrial node (owns lap timing for all circuits); wired by world.gd

# ONE LABEL PER LINE, AND THE LINES TAKE TURNS.
# This overlay used to be a single Label whose whole text - about a thousand characters, three
# hundred of them the key help that never changes - was rebuilt and assigned every frame. A Label
# lays out ALL of its text again when any of it changes, so the frame paid for shaping the static
# help line sixty times a second: measured 2026-11-17, 120 us of string building plus 580 us of
# text layout a frame (headless, cloud host), the largest single item left in the idle step once
# the pace notes stopped scanning every route.
# Two changes, both about not doing work nobody can see:
#  - each line is its own Label, so a line that did not change is not laid out again (a Label
#    ignores being handed the text it already has). The help, the table header and the blank
#    lines are written once.
#  - the lines that do change are split into REFRESH_GROUPS groups and one group is rewritten per
#    frame. Every number therefore refreshes at frame rate / REFRESH_GROUPS - 20 Hz at 60 fps -
#    which is still several times faster than a changing digit can be read, and the cost per
#    frame is level instead of spiking every third frame as a plain "update every N frames" would.
# The G-meter's smoothing below still runs every frame, so its filter is unchanged.
const REFRESH_GROUPS := 3
const ROWS := ["title", "input", "gap0", "speed", "pedals", "steer_nm", "gear", "drive", "trial",
	"gap1", "wheel_head", "w0", "w1", "w2", "w3", "gap2", "help"]
const HELP_TEXT := "[W/S] gas/brake  [A/D] steer  [Q/E] gears (R-N-1..6)  [Shift] clutch  [I] ignition  [T] AWD/RWD/FWD  [1/2/3] diff open/visc/rally  [Space] handbrake  [C] cam  [V]/R3 look back  [R-stick] look around  [B] circuit  [L] time  [P] test puncture  [Tab] tune  [-/+] hud  [R] reset"
var _box: VBoxContainer
var _theme: Theme
var _rows := {}          # row name -> Label
var _turn := 0
var _filled := false     # the first frame writes every group, so the overlay never shows half empty

func _ready() -> void:
	# one Theme on the box instead of four overrides on each Label: the font size is then changed
	# in one place and every line follows
	_theme = Theme.new()
	_theme.set_font_size("font_size", "Label", _fs)
	_theme.set_color("font_color", "Label", Color(0.88, 1.0, 0.9))
	_theme.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	_theme.set_constant("outline_size", "Label", 4)
	_box = VBoxContainer.new()
	_box.position = Vector2(16, 12)
	_box.theme = _theme
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# the gap between two Labels in a column = the gap between two lines inside one Label, so the
	# overlay is laid out exactly where the single Label put it
	_box.add_theme_constant_override("separation", ThemeDB.get_default_theme().get_constant("line_spacing", "Label"))
	add_child(_box)
	for key in ROWS:
		var l := Label.new()
		# rows that depend on what the car can report stay out of the column until first written
		l.visible = key.begins_with("gap") or key == "wheel_head" or key == "help"
		_box.add_child(l)
		_rows[key] = l
	_rows["wheel_head"].text = "wheel  Fz(kN) slipR  slipA   temp wear  grip"
	_rows["help"].text = HELP_TEXT

func _put(key: String, txt: String) -> void:
	var l: Label = _rows[key]
	l.text = txt             # a no-op inside Label when the text is the one it already shows
	if not l.visible:
		l.visible = true

func _set_fs(v: int) -> void:
	_fs = clampi(v, 10, 48)
	_theme.set_font_size("font_size", "Label", _fs)

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("hud_bigger"):
		_set_fs(_fs + 2)
	if Input.is_action_just_pressed("hud_smaller"):
		_set_fs(_fs - 2)
	if car == null:
		return
	var v: Vector3 = car.linear_velocity
	var fwd: Vector3 = -car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	# G-meter: smoothed longitudinal + lateral acceleration in g
	var accel := (v - _v_prev) / maxf(delta, 0.001)
	_v_prev = v
	_g_lon = lerpf(_g_lon, accel.dot(fwd) / 9.81, 0.25)
	_g_lat = lerpf(_g_lat, accel.dot(right) / 9.81, 0.25)

	_turn = (_turn + 1) % REFRESH_GROUPS
	var all := not _filled
	_filled = true
	var has_eng: bool = car.has_method("get_engine")

	if all or _turn == 0:
		var speed_kmh: float = v.length() * 3.6
		var fwd_kmh: float = v.dot(fwd) * 3.6
		var steer := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
		var eng := {}
		if has_eng:
			eng = car.get_engine()
			_put("title", "RALLY SIM - M2  (slip-ratio drivetrain)     fps %d" % Engine.get_frames_per_second())
		else:
			_put("title", "RALLY SIM - M1  (raycast wheels + brush tire)     fps %d" % Engine.get_frames_per_second())
		# which input device is actually live - a pad that Godot can't see simply won't be listed
		var pads := Input.get_connected_joypads()
		if pads.is_empty():
			_put("input", "input     keyboard   (no gamepad detected)")
		else:
			_put("input", "input     %s" % Input.get_joy_name(pads[0]))
		_put("speed", "speed     %7.1f km/h   (fwd %7.1f)" % [speed_kmh, fwd_kmh])
		# pedal travel as the PHYSICS sees it (shaped from keys, or straight through from triggers)
		_put("pedals", "throttle  %4.2f   brake %4.2f   clutch %4.2f   steer %+4.2f" % [
			float(eng.get("throttle", Input.get_action_strength("throttle"))),
			float(eng.get("brake", Input.get_action_strength("brake"))),
			float(eng.get("clutch", 0.0)),
			steer])
		# C2: self-aligning torque at the rack. Watch it LIGHTEN as the front starts to wash out - that
		# drop arrives a beat before the grip actually goes, which is the cue the whole phase exists for.
		if car.has_method("get_steer_torque"):
			_put("steer_nm", "steer Nm  %+7.1f" % car.get_steer_torque())

	if all or _turn == 1:
		if has_eng:
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
			_put("gear", "gear  %s   rpm %5.0f %s%s" % [gtxt, rpm, _rev_bar(frac), shift])
			var diff_txt := ""
			if car.has_method("diff_preset_name"):
				diff_txt = "  diff %-9s" % car.diff_preset_name()
			_put("drive", "drive %s%s   G  lon %+4.2f  lat %+4.2f" % [str(e["mode"]), diff_txt, _g_lon, _g_lat])
		if time_trial != null:
			var ti: Dictionary = time_trial.active_info()
			# D2: "lap" only means something on a closed circuit. A point-to-point stage has a RUN.
			var unit: String = "lap" if bool(ti.get("loop", true)) else "run"
			_put("trial", "%-12s %s %s  last %s  best %s" % [ti["name"], unit, _fmt_time(ti["lap"]), _fmt_time(ti["last"]), _fmt_time(ti["best"])])

	if all or _turn == 2:
		var wheels: Array = car.get_wheels()
		var names := ["FL", "FR", "RL", "RR"]
		for i in range(mini(wheels.size(), 4)):
			var w = wheels[i]
			var grounded: String = " " if w.contact else "air"
			var tail: String = "PUNCTURE!" if w.punctured else _bar(w.util)
			_put("w%d" % i, "  %s %s %6.2f %5.2f %+6.1f %4.0fC %3.0f%% %s" % [
				names[i], grounded, w.Fz / 1000.0, w.slip, rad_to_deg(w.slip_angle), w.temp, w.tyre_wear * 100.0, tail])

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
