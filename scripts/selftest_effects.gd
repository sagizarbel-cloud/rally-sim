extends SceneTree
func _initialize() -> void:
	var fx = load("res://scripts/effects.gd").new()
	var dt := 1.0 / 120.0
	print("--- flicker: raw vs smoothed drive signal (load pumping at 4 Hz under braking) ---")
	var raw_min := 9.0; var raw_max := -9.0; var sm_min := 9.0; var sm_max := -9.0
	var s := 0.0
	for i in range(360):                       # 3 s at 120 Hz, after a 0.5 s settle
		var t := float(i) * dt
		var raw: float = 0.68 + 0.32 * sin(TAU * 4.0 * t)   # oscillating friction power
		s = fx._smooth(s, raw, dt)
		if t > 0.5:
			raw_min = minf(raw_min, raw); raw_max = maxf(raw_max, raw)
			sm_min = minf(sm_min, s);     sm_max = maxf(sm_max, s)
	print("  raw      swings %.2f .. %.2f  (peak-to-peak %.2f)" % [raw_min, raw_max, raw_max - raw_min])
	print("  smoothed swings %.2f .. %.2f  (peak-to-peak %.2f)  -> %.0f%% of the flicker removed" % [
		sm_min, sm_max, sm_max - sm_min, 100.0 * (1.0 - (sm_max - sm_min) / maxf(raw_max - raw_min, 0.001))])
	print("--- layer 2: plume rises from ROLLING, not just sliding (gravel) ---")
	for spd in [8.0, 15.0, 25.0, 35.0]:
		print("  %5.0f km/h cruising, no slip -> plume %.2f   |  same speed, half slip -> %.2f" % [
			spd * 3.6, fx.plume_frac(spd, 0.0), fx.plume_frac(spd, 0.5)])
	print("--- layer separation ---")
	print("  asphalt cruise : smoke %.2f (cold, no slip)" % fx.smoke_frac(70.0, 3000.0, 0.1, 1.52))
	print("  asphalt drift  : smoke %.2f" % fx.smoke_frac(140.0, 4000.0, 9.0, 1.52))
	print("  gravel cruise  : grit  %.2f (no slip = no stones thrown)" % 0.0)
	quit()
