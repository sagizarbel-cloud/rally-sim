#!/usr/bin/env python3
"""TEMPORARY - reads a drive log written by scripts/probe_framelog.gd (v2) and says, for every
long frame, WHERE the time went. Delete together with the probe when D4's hiccup item closes.

    python3 tools/framelog_report.py "<path to framelog-....csv>"

The newest log is in:  ~/Library/Application Support/Godot/app_userdata/Rally Sim (M0)/

One row of the log is the interval between two _process starts, cut into the sections the engine
executes:  idle scripts | pre | draw (render + the vsync wait) | post | the next physics ticks.
A frame is LATE when that interval is over 25 ms (a 60 Hz frame is 16.7) and a STALL at 41+ ms.
Each late frame is blamed on the section that grew the most over its own normal, and inside
physics/idle on the system that grew the most. Late frames within half a second are one BURST,
and the burst is blamed on its first frame - the rest is usually catch-up.
"""
import sys
from collections import Counter, defaultdict

LATE_US = 25000
STALL_US = 41000


def load(path):
    hdr, rows, events, meta = None, [], [], []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#EVT"):
                a = line.split(",", 3)
                events.append((float(a[1]), a[2], a[3] if len(a) > 3 else ""))
            elif line.startswith("#"):
                meta.append(line)
            elif hdr is None:
                hdr = line.split(",")
            else:
                v = line.split(",")
                if len(v) == len(hdr):
                    rows.append({k: float(x) for k, x in zip(hdr, v)})
    return hdr, rows, events, meta


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))] if v else 0.0


def ms(us):
    return us / 1000.0


def main(path):
    hdr, R, events, meta = load(path)
    if not R:
        print("no frames in", path)
        return
    systems = [h[2:] for h in hdr if h.startswith("p_")]
    for m in meta:
        print(m)
    t0, t1 = R[0]["t_s"], R[-1]["t_s"]
    print(f"\n{len(R)} frames, {t1 - t0:.1f} s  (t = seconds since the engine started; the log starts at {t0:.1f})")

    # ---- events ---------------------------------------------------------------------------
    kinds = Counter(e[1] for e in events)
    print("events:", ", ".join(f"{k} x{n}" for k, n in sorted(kinds.items())) or "none")
    for e in events:
        if e[1] in ("APP", "WIN", "WINMODE", "AREA", "TEST", "OS"):
            print(f"   {e[0]:8.2f}  {e[1]} {e[2]}")
    unfocused = sum(1 for r in R if r["focus"] == 0)
    if unfocused:
        print(f"!! {unfocused} frames ({100.0 * unfocused / len(R):.0f}%) ran WITHOUT window focus - a covered or "
              "background window is not vsynced and macOS throttles it; ignore those stretches")

    # ---- what a normal frame costs, on and off the stage -------------------------------------
    sections = ["phys_us", "idle_us", "pre_us", "draw_us", "post_us"]
    norm = {}
    for st in (0, 1):
        rows = [r for r in R if r["on_stage"] == st and r["focus"] == 1 and r["dt_us"] < LATE_US]
        if len(rows) < 30:
            continue
        norm[st] = {k: q([r[k] for r in rows], .5) for k in hdr[1:]}
        n = norm[st]
        top = sorted(((n["p_" + s], s) for s in systems), reverse=True)[:5]
        print(f"\nNORMAL FRAME {'on SHAKEDOWN' if st else 'on the legacy map'} ({len(rows)} frames): "
              f"physics {ms(n['phys_us']):.2f} ms in {n['ticks']:.0f} ticks | idle {ms(n['idle_us']):.2f} | "
              f"pre {ms(n['pre_us']):.2f} | draw {ms(n['draw_us']):.2f} (render cpu "
              f"{ms(n['setup_us'] + n['vp_cpu_us'] + n['mir_cpu_us']):.2f}, the rest is the vsync wait) | post {ms(n['post_us']):.2f}")
        print("   physics by system: " + ", ".join(f"{s} {ms(v):.2f}" for v, s in top)
              + f", jolt step {ms(n['step_sum_us']):.2f}")
        topi = sorted(((n["i_" + s], s) for s in systems), reverse=True)[:3]
        print("   idle by system:    " + ", ".join(f"{s} {ms(v):.2f}" for v, s in topi))
    if not norm:
        print("not enough normal frames to establish a baseline")
        return
    for st in (0, 1):
        norm.setdefault(st, norm[1 - st])

    # ---- pacing by speed ---------------------------------------------------------------------
    print("\nPACING BY SPEED (focused frames only)")
    print("   km/h       frames   late(>25ms)  stalls(>41ms)   per 1000 frames")
    for lo, hi in [(0, 2), (2, 30), (30, 70), (70, 120), (120, 400)]:
        rows = [r for r in R if lo <= r["speed_kmh"] < hi and r["focus"] == 1]
        if not rows:
            continue
        late = sum(1 for r in rows if r["dt_us"] > LATE_US)
        stall = sum(1 for r in rows if r["dt_us"] > STALL_US)
        print(f"   {lo:3d}-{hi:<3d}   {len(rows):7d}   {late:8d}   {stall:10d}       {1000.0 * late / len(rows):6.2f}")

    # ---- blame each late frame ---------------------------------------------------------------
    def near_events(t, before=1.0, after=0.3):
        return [e for e in events if t - before <= e[0] <= t + after]

    pc_cols = ["pc_canvas", "pc_mesh", "pc_surface", "pc_draw", "pc_spec"]
    prev = {}
    for i, r in enumerate(R):
        prev[id(r)] = R[i - 1] if i > 0 else r
    cal_med = q([r["cal_us"] for r in R], .5)

    def blame(r):
        n = norm[int(r["on_stage"])]
        ev = near_events(r["t_s"])
        tags = []
        if any(e[1] == "TEST" and e[2].startswith("stall") for e in near_events(r["t_s"], 0.1, 0.1)):
            return "injected by the probe's self-test", ""
        if r["focus"] == 0 or any(e[1] in ("APP", "WIN", "WINMODE") for e in ev):
            return "window focus / mode change (the OS, not the game)", ", ".join(f"{e[1]} {e[2]}" for e in ev if e[1] in ("APP", "WIN", "WINMODE"))
        ex = {k: r[k] - n[k] for k in sections}
        sec = max(ex, key=lambda k: ex[k])
        detail = f"{sec[:-3]} +{ms(ex[sec]):.1f} ms"
        if r["cal_us"] > 2.0 * cal_med:
            tags.append(f"CPU itself slow (calibration loop x{r['cal_us'] / cal_med:.1f})")
        keys = [e for e in ev if e[1] in ("KEY", "PAD")]
        if keys:
            tags.append("input: " + " ".join(f"{e[1]}:{e[2]}" for e in keys[-3:]))
        if sec == "phys_us":
            sysx = sorted(((r["p_" + s] - n["p_" + s] * r["ticks"] / max(n["ticks"], 1), s) for s in systems), reverse=True)
            jolt = r["step_sum_us"] - n["step_sum_us"] * r["ticks"] / max(n["ticks"], 1)
            name, amount = sysx[0][1], sysx[0][0]
            if jolt > amount:
                name, amount = "jolt step", jolt
            if r["ticks"] > n["ticks"] and amount < 0.5 * ex[sec]:
                cause = f"physics catch-up ({r['ticks']:.0f} ticks, each at its normal cost)"
            elif name == "stage_area":
                what = []
                if r["tick_max_us"] > 40000:
                    what.append("PRIME after a teleport")
                if r.get("band_marks", 0) > 0:
                    what.append("band re-marked")
                if r.get("scan_us", 0) > 0:
                    what.append(f"scan {ms(r['scan_us']):.1f} ms")
                if r.get("finalise_us", 0) > 0:
                    what.append(f"finalise {ms(r['finalise_us']):.1f} ms ({r['built']:.0f} built)")
                cause = "physics: the STREAMER (stage_area) - " + (", ".join(what) or "build steps")
            else:
                cause = f"physics: {name} (+{ms(amount):.1f} ms over its normal for {r['ticks']:.0f} ticks)"
            detail += f", worst tick {ms(r['tick_max_us']):.1f} ms"
        elif sec == "idle_us":
            sysx = sorted(((r["i_" + s] - n["i_" + s], s) for s in systems), reverse=True)
            cause = f"_process scripts: {sysx[0][1]} (+{ms(sysx[0][0]):.1f} ms)"
        elif sec == "pre_us":
            cause = "between scripts and draw (deferred calls, HUD redraw, transform flush)"
        elif sec == "post_us":
            cause = "after draw (OS event pump / frame limiter) - usually the OS"
        else:
            p = prev[id(r)]
            comp = sum(r[c] - p[c] for c in pc_cols)
            cpu = (r["setup_us"] + r["vp_cpu_us"] + r["mir_cpu_us"]) - (n["setup_us"] + n["vp_cpu_us"] + n["mir_cpu_us"])
            if comp > 0:
                cause = f"draw: {comp:.0f} pipeline(s) compiled this frame (first use of a shader variant)"
            elif cpu > 0.5 * ex[sec]:
                cause = f"draw: render CPU work (+{ms(cpu):.1f} ms: setup {ms(r['setup_us']):.1f}, main view {ms(r['vp_cpu_us']):.1f}, mirror {ms(r['mir_cpu_us']):.1f})"
            else:
                cause = "draw: blocked in present with no extra CPU work - GPU-bound or the compositor"
            detail += f", fx particles ~{r['fx_live']:.0f}"
        return cause, "; ".join([detail] + tags)

    late = [r for r in R if r["dt_us"] > LATE_US]
    bursts = []
    for r in late:
        if bursts and r["t_s"] - bursts[-1][-1]["t_s"] < 0.5:
            bursts[-1].append(r)
        else:
            bursts.append([r])
    print(f"\nLATE FRAMES: {len(late)} of {len(R)} ({1000.0 * len(late) / len(R):.2f} per 1000), in {len(bursts)} bursts")
    print("     t_s  frames  lost ms  km/h  area    cause")
    by_cause = defaultdict(lambda: [0, 0.0])
    for b in bursts:
        r = b[0]
        cause, detail = blame(r)
        lost = sum(x["dt_us"] - 16667 for x in b) / 1000.0
        key = cause.split(" (")[0].split(" - ")[0]
        by_cause[key][0] += 1
        by_cause[key][1] += lost
        print(f"  {r['t_s']:7.2f}  {len(b):4d}  {lost:7.1f}  {r['speed_kmh']:5.1f}  {'stage ' if r['on_stage'] else 'legacy'}  {cause}")
        if detail:
            print(f"                                          {detail}")
    print("\nBY CAUSE (bursts, ms lost):")
    for k, (n_, lost) in sorted(by_cause.items(), key=lambda kv: -kv[1][1]):
        print(f"   {n_:4d}  {lost:8.1f} ms   {k}")

    # ---- the streamer ------------------------------------------------------------------------
    st_rows = [r for r in R if r["on_stage"] == 1]
    if st_rows and "scan_us" in hdr:
        dur = max(st_rows[-1]["t_s"] - st_rows[0]["t_s"], 1e-9)
        scans = sum(r["scans"] for r in st_rows)
        scan_ms = [ms(r["scan_us"]) for r in st_rows if r["scans"] > 0]
        fin = [ms(r["finalise_us"]) for r in st_rows if r["finalise_us"] > 0]
        print(f"\nSTREAMER on stage ({dur:.0f} s): {sum(r['built'] for r in st_rows) / dur:.1f} chunks built/s | "
              f"{scans / dur:.1f} scans/s, {q(scan_ms, .5):.2f} ms typical, {max(scan_ms or [0]):.2f} worst | "
              f"finalise per frame {q(fin, .5):.2f} typical, {max(fin or [0]):.2f} worst | "
              f"band re-marked {sum(r['band_marks'] for r in st_rows):.0f} times | "
              f"r_solid {min(r['r_solid'] for r in st_rows):.0f}..{max(r['r_solid'] for r in st_rows):.0f} m | "
              f"worst physics tick {ms(max(r['tick_max_us'] for r in st_rows)):.1f} ms")
        heavy = sum(1 for r in st_rows if r["phys_us"] > 8333)
        print(f"   frames whose physics alone took over half the frame (8.3 ms): {heavy} of {len(st_rows)}")

    # ---- shaders and the CPU itself ----------------------------------------------------------
    print("\nPIPELINE COMPILATIONS (canvas/mesh/surface/draw/specialization) - a jump mid-drive is a first-use hitch:")
    last = None
    for r in R:
        cur = tuple(int(r[c]) for c in pc_cols)
        if cur != last:
            print(f"   t={r['t_s']:7.2f}  {cur}")
            last = cur
    slow = [r for r in R if r["cal_us"] > 2.0 * cal_med]
    print(f"\nCALIBRATION LOOP: {cal_med:.0f} us typical, {q([r['cal_us'] for r in R], .99):.0f} at p99; "
          f"{len(slow)} frames over 2x (the processor itself slow: throttled, or the thread descheduled)")
    print(f"MEMORY: {R[0]['mem_mb']:.0f} -> {R[-1]['mem_mb']:.0f} MB static, video {R[0]['vram_mb']:.0f} -> {R[-1]['vram_mb']:.0f} MB, "
          f"nodes {R[0]['nodes']:.0f} -> {R[-1]['nodes']:.0f}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
