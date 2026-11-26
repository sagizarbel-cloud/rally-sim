#!/usr/bin/env python3
"""Compare two tools/baseline/run.sh output directories (A = before, B = after).

For every per-tick CSV: the first tick where the runs part (any column off by more than a
tolerance), and the largest difference per key column. For every summary: each number side by
side with its delta. The ground lattice: byte-identical or not. Prints Markdown, so the table can go
straight into CHANGELOG.md.
"""
import csv, hashlib, json, os, sys

TOL = {"x": 1e-3, "y": 1e-3, "z": 1e-3, "kmh": 1e-2, "rpm": 1.0}

def rows(p):
    with open(p) as f:
        r = list(csv.reader(f))
    return r[0], [[float(x) for x in row] for row in r[1:]]

def flat(d, pre=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flat(v, f"{pre}{k}."))
    elif isinstance(d, list) and all(isinstance(x, (int, float)) for x in d):
        for i, v in enumerate(d):
            out[f"{pre}{i}"] = v
    elif isinstance(d, (int, float)) and not isinstance(d, bool):
        out[pre[:-1]] = d
    return out

def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None

def main(a, b):
    print(f"A: {open(os.path.join(a, 'engine.txt')).read().strip() if os.path.exists(os.path.join(a, 'engine.txt')) else a}")
    print(f"B: {open(os.path.join(b, 'engine.txt')).read().strip() if os.path.exists(os.path.join(b, 'engine.txt')) else b}\n")
    ha, hb = sha(os.path.join(a, "lattice.txt")), sha(os.path.join(b, "lattice.txt"))
    print(f"**Ground lattice:** {'identical' if ha and ha == hb else 'DIFFERENT'} ({(ha or 'missing')[:16]} / {(hb or 'missing')[:16]})\n")
    print("| trace | ticks A / B | first tick apart | max |dx| m | max |d kmh| | max |d rpm| |")
    print("|---|---|---|---|---|---|")
    for name in sorted(os.listdir(a)):
        if not name.endswith(".csv") or not os.path.exists(os.path.join(b, name)):
            continue
        ha_, ra = rows(os.path.join(a, name))
        _, rb = rows(os.path.join(b, name))
        idx = {h: i for i, h in enumerate(ha_)}
        first = None
        mx = {"x": 0.0, "kmh": 0.0, "rpm": 0.0}
        for i, (p, q) in enumerate(zip(ra, rb)):
            for col, tol in TOL.items():
                d = abs(p[idx[col]] - q[idx[col]])
                if d > tol and first is None:
                    first = i
            mx["x"] = max(mx["x"], ((p[1] - q[1]) ** 2 + (p[3] - q[3]) ** 2) ** 0.5)
            mx["kmh"] = max(mx["kmh"], abs(p[idx["kmh"]] - q[idx["kmh"]]))
            mx["rpm"] = max(mx["rpm"], abs(p[idx["rpm"]] - q[idx["rpm"]]))
        fst = "never" if first is None else f"{first} ({first / 120:.2f} s)"
        print(f"| {name} | {len(ra)} / {len(rb)} | {fst} | {mx['x']:.3f} | {mx['kmh']:.3f} | {mx['rpm']:.1f} |")
    print("\n| quantity | A | B | delta |")
    print("|---|---|---|---|")
    for name in sorted(os.listdir(a)):
        if not name.endswith("_summary.json") or not os.path.exists(os.path.join(b, name)):
            continue
        fa = flat(json.load(open(os.path.join(a, name))))
        fb = flat(json.load(open(os.path.join(b, name))))
        test = name[: -len("_summary.json")]
        for k in fa:
            if k.startswith("sectors") or k not in fb:
                continue
            va, vb = fa[k], fb[k]
            print(f"| {test} {k} | {va:.4g} | {vb:.4g} | {vb - va:+.4g} |")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
