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
# 2026-11-17 (drive request): the testing read-outs and the key help are collapsed behind a MENU
# (default [H], rebindable from inside it). By default only the track + time line and fps show; the
# menu cycles a DISPLAY MODE - minimal / all / key help only (bottom left) / test metrics only (top
# left) - and has a tick box for each of the two default lines. Choices persist in user://hud.cfg.
const ROWS := ["fps", "trial", "title", "input", "gap0", "speed", "pedals", "steer_nm", "gear", "drive",
	"gap1", "wheel_head", "w0", "w1", "w2", "w3"]
const METRIC_ROWS := ["title", "input", "gap0", "speed", "pedals", "steer_nm", "gear", "drive",
	"gap1", "wheel_head", "w0", "w1", "w2", "w3"]
const HELP_TEXT := "[W/S] gas/brake  [A/D] steer  [Q/E] gears (R-N-1..6)  [Shift] clutch  [I] ignition  [T] AWD/RWD/FWD  [1/2/3] diff open/visc/rally  [Space] handbrake  [C] cam  [V]/R3 look back  [R-stick] look around  [B] circuit  [L] time  [P] test puncture  [Tab] tune  [-/+] hud size  [R] reset  [%s] HUD menu"
enum Mode { MINIMAL, ALL, KEYS, METRICS }
const MODE_NAMES := ["Minimal (track + fps)", "All", "Key help only (bottom left)", "Test metrics only (top left)"]
const CFG_PATH := "user://hud.cfg"
var mode: int = Mode.MINIMAL
var show_fps := true
var show_trial := true
var _box: VBoxContainer
var _help: Label
var _theme: Theme
var _rows := {}          # row name -> Label
var _has := {}           # rows the car has actually reported (some cars lack some read-outs)
var _turn := 0
var _filled := false     # the first frame writes every group, so the overlay never shows half empty
# --- the menu ---
var _menu: PanelContainer
var _mode_btn: Button
var _fps_box: CheckBox
var _trial_box: CheckBox
var _bind_btn: Button
var _rebinding := false
var _notes_slider: HSlider
var note_height := 0.85                  # pace notes' vertical position (fraction of screen height)
var _vp_rid: RID

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
		l.visible = false
		_box.add_child(l)
		_rows[key] = l
		if key.begins_with("gap") or key == "wheel_head":
			_has[key] = true
	_rows["wheel_head"].text = "wheel  Fz(kN) slipR  slipA   temp wear  grip"
	# the key help lives in the BOTTOM-LEFT corner, wrapped, so it never runs off the screen
	_help = Label.new()
	_help.theme = _theme
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_help.anchor_left = 0.0
	_help.anchor_right = 0.62
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_left = 16
	_help.offset_bottom = -12
	_help.offset_top = -12
	_help.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_help)
	# GPU frame time, for the "120 fps of GPU headroom on a 60 Hz screen" target: vsync hides how
	# much of each 16.7 ms frame the GPU actually needs, so fps alone cannot show the headroom.
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_load_cfg()
	_build_menu()
	_apply_mode()
	_apply_notes.call_deferred()

func _apply_notes() -> void:
	var pn := get_parent().get_node_or_null("PaceNotes") if get_parent() != null else null
	if pn != null and pn.has_method("set_note_height"):
		pn.set_note_height(note_height)

# ---------------------------------------------------------------- display modes + the menu

func _metrics_on() -> bool:
	return mode == Mode.ALL or mode == Mode.METRICS

func _keys_on() -> bool:
	return mode == Mode.ALL or mode == Mode.KEYS

func _apply_mode() -> void:
	for key in ROWS:
		var on: bool = _has.get(key, false)
		if key == "fps":
			on = on and show_fps
		elif key == "trial":
			on = on and show_trial
		else:
			on = on and _metrics_on()
		_rows[key].visible = on
	_help.text = HELP_TEXT % _binding_name()
	_help.visible = _keys_on()
	if _mode_btn != null:
		_mode_btn.text = "Display: %s" % MODE_NAMES[mode]
		_fps_box.button_pressed = show_fps
		_trial_box.button_pressed = show_trial
		_bind_btn.text = "Press a key or pad button..." if _rebinding else "Menu key: %s  (click to rebind)" % _binding_name()

func _binding_name() -> String:
	var evs := InputMap.action_get_events("hud_menu") if InputMap.has_action("hud_menu") else []
	if evs.is_empty():
		return "unbound"
	var e: InputEvent = evs[0]
	if e is InputEventKey:
		var k: Key = (e as InputEventKey).physical_keycode
		return OS.get_keycode_string(k) if k != KEY_NONE else e.as_text()
	if e is InputEventJoypadButton:
		return "pad button %d" % (e as InputEventJoypadButton).button_index
	return e.as_text()

func _build_menu() -> void:
	_menu = PanelContainer.new()
	_menu.anchor_left = 0.5
	_menu.anchor_right = 0.5
	_menu.anchor_top = 0.5
	_menu.anchor_bottom = 0.5
	_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.06, 0.88)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(16)
	_menu.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_menu.add_child(v)
	var t := Label.new()
	t.text = "HUD"
	t.add_theme_font_size_override("font_size", 22)
	v.add_child(t)
	_mode_btn = Button.new()
	_mode_btn.focus_mode = Control.FOCUS_NONE
	_mode_btn.pressed.connect(func():
		mode = (mode + 1) % MODE_NAMES.size()
		_apply_mode()
		_save_cfg())
	v.add_child(_mode_btn)
	_fps_box = CheckBox.new()
	_fps_box.text = "Show fps"
	_fps_box.focus_mode = Control.FOCUS_NONE
	_fps_box.toggled.connect(func(on: bool):
		show_fps = on
		_apply_mode()
		_save_cfg())
	v.add_child(_fps_box)
	_trial_box = CheckBox.new()
	_trial_box.text = "Show track + time"
	_trial_box.focus_mode = Control.FOCUS_NONE
	_trial_box.toggled.connect(func(on: bool):
		show_trial = on
		_apply_mode()
		_save_cfg())
	v.add_child(_trial_box)
	var nl := Label.new()
	nl.text = "Pace notes height (top - bottom)"
	v.add_child(nl)
	_notes_slider = HSlider.new()
	_notes_slider.min_value = 0.05
	_notes_slider.max_value = 0.95
	_notes_slider.step = 0.01
	_notes_slider.value = note_height
	_notes_slider.custom_minimum_size = Vector2(320, 0)
	_notes_slider.focus_mode = Control.FOCUS_NONE
	_notes_slider.value_changed.connect(func(val: float):
		note_height = val
		_apply_notes()
		_save_cfg())
	v.add_child(_notes_slider)
	var unc := CheckBox.new()
	unc.text = "Uncapped fps (vsync off) - to measure headroom"
	unc.focus_mode = Control.FOCUS_NONE
	unc.toggled.connect(func(on: bool):
		# With vsync on, frames are held to the screen's 60 Hz and spare GPU capacity is invisible -
		# and Metal does not report GPU time - so this is how the "120 fps of headroom" target is
		# measured. Not saved: it tears, and is a measuring tool rather than a setting.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if on else DisplayServer.VSYNC_ENABLED)
		Engine.max_fps = 0 if on else 144)
	v.add_child(unc)
	_bind_btn = Button.new()
	_bind_btn.focus_mode = Control.FOCUS_NONE
	_bind_btn.pressed.connect(func():
		_rebinding = true
		_apply_mode())
	v.add_child(_bind_btn)
	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): _menu.visible = false)
	v.add_child(close)
	add_child(_menu)

func _input(event: InputEvent) -> void:
	## Rebinding: the next key or pad button pressed becomes the menu key. Escape cancels.
	if not _rebinding:
		return
	var ev: InputEvent = null
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			_rebinding = false
			_apply_mode()
			get_viewport().set_input_as_handled()
			return
		var k := InputEventKey.new()
		k.physical_keycode = (event as InputEventKey).physical_keycode
		ev = k
	elif event is InputEventJoypadButton and event.pressed:
		var b := InputEventJoypadButton.new()
		b.button_index = (event as InputEventJoypadButton).button_index
		ev = b
	if ev == null:
		return
	_set_binding(ev)
	_rebinding = false
	_apply_mode()
	_save_cfg()
	get_viewport().set_input_as_handled()

func _set_binding(ev: InputEvent) -> void:
	if not InputMap.has_action("hud_menu"):
		InputMap.add_action("hud_menu")
	InputMap.action_erase_events("hud_menu")
	InputMap.action_add_event("hud_menu", ev)

func _save_cfg() -> void:
	var c := ConfigFile.new()
	c.set_value("hud", "mode", mode)
	c.set_value("hud", "show_fps", show_fps)
	c.set_value("hud", "show_trial", show_trial)
	c.set_value("hud", "note_height", note_height)
	var evs := InputMap.action_get_events("hud_menu") if InputMap.has_action("hud_menu") else []
	if not evs.is_empty():
		var e: InputEvent = evs[0]
		if e is InputEventKey:
			c.set_value("hud", "menu_key", int((e as InputEventKey).physical_keycode))
		elif e is InputEventJoypadButton:
			c.set_value("hud", "menu_pad", int((e as InputEventJoypadButton).button_index))
	c.save(CFG_PATH)

func _load_cfg() -> void:
	var c := ConfigFile.new()
	if c.load(CFG_PATH) != OK:
		return
	mode = clampi(int(c.get_value("hud", "mode", mode)), 0, MODE_NAMES.size() - 1)
	show_fps = bool(c.get_value("hud", "show_fps", show_fps))
	show_trial = bool(c.get_value("hud", "show_trial", show_trial))
	note_height = clampf(float(c.get_value("hud", "note_height", note_height)), 0.05, 0.95)
	if c.has_section_key("hud", "menu_key"):
		var k := InputEventKey.new()
		k.physical_keycode = int(c.get_value("hud", "menu_key")) as Key
		_set_binding(k)
	elif c.has_section_key("hud", "menu_pad"):
		var b := InputEventJoypadButton.new()
		b.button_index = int(c.get_value("hud", "menu_pad")) as JoyButton
		_set_binding(b)

func _put(key: String, txt: String) -> void:
	var l: Label = _rows[key]
	l.text = txt             # a no-op inside Label when the text is the one it already shows
	if not _has.get(key, false):
		_has[key] = true     # first report from the car: the row may now be shown
		_apply_mode()

func _set_fs(v: int) -> void:
	_fs = clampi(v, 10, 48)
	_theme.set_font_size("font_size", "Label", _fs)

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("hud_bigger"):
		_set_fs(_fs + 2)
	if Input.is_action_just_pressed("hud_smaller"):
		_set_fs(_fs - 2)
	if InputMap.has_action("hud_menu") and Input.is_action_just_pressed("hud_menu") and not _rebinding:
		_menu.visible = not _menu.visible
		_apply_mode()
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
		var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
		if gpu_ms > 0.0:
			_put("fps", "fps %d   gpu %.1f ms (%d fps headroom)" % [Engine.get_frames_per_second(), gpu_ms, int(1000.0 / gpu_ms)])
		else:
			_put("fps", "fps %d" % Engine.get_frames_per_second())
		if has_eng:
			eng = car.get_engine()
			_put("title", "RALLY SIM - M2  (slip-ratio drivetrain)")
		else:
			_put("title", "RALLY SIM - M1  (raycast wheels + brush tire)")
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
