#!/usr/bin/env python3
"""Summarize a TG18_IR_TRACE file from the emulator.

Usage: python3 ir_decode.py ir_trace.txt [more_traces.txt ...]

Trace lines look like `t_us offset R|W size value`; `#   xN more` lines mean the
previous access repeated N more times (polling). This script prints:
  1. a per-register summary (what was read/written, which values)
  2. the first events with the gap to the previous event in microseconds
  3. a histogram of gaps between WRITES, with a flag when a gap lands near the
     Tamagotchi Connection "Nearly NEC" timings (mark/short ~650 us,
     long space ~1200 us, preamble ~9500 + ~6000 us). A cluster there would mean
     Meets/ON uses the same pulse scheme; no cluster means it does not.
"""
import re
import sys
from collections import Counter, defaultdict

NEC = [(650, "mark/short space"), (1200, "long space"), (6070, "preamble space"), (9485, "preamble mark")]


def parse(path):
    ev, reps = [], []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            m = re.match(r"#\s+x(\d+) more, until t=([\d.]+)", line)
            if m and ev:
                ev[-1]["rep"] = int(m.group(1))
                ev[-1]["until"] = float(m.group(2))
            continue
        t, off, d, size, val = line.split()
        ev.append(dict(t=float(t), off=int(off, 16), w=(d == "W"), size=int(size), val=int(val, 16), rep=0))
    return ev


def main(paths):
    for path in paths:
        ev = parse(path)
        print(f"=== {path}: {len(ev)} events")
        reg = defaultdict(lambda: defaultdict(Counter))
        for e in ev:
            reg[e["off"]]["W" if e["w"] else "R"][e["val"]] += 1 + e["rep"]
        print("\n-- registers (offset: direction -> value x count, top 6)")
        for off in sorted(reg):
            for d in ("W", "R"):
                if reg[off][d]:
                    top = ", ".join(f"{v:X}x{c}" for v, c in reg[off][d].most_common(6))
                    print(f"  +{off:02X} {d}: {top}")

        print("\n-- first 60 events (gap = us since previous event)")
        prev = None
        for e in ev[:60]:
            gap = "" if prev is None else f"+{e['t'] - prev:.1f}"
            rep = f"  x{e['rep']} until {e['until']:.1f}" if e["rep"] else ""
            print(f"  {e['t']:12.1f} {gap:>10}  +{e['off']:02X} {'W' if e['w'] else 'R'} {e['val']:X}{rep}")
            prev = e["t"]

        print("\n-- gaps between consecutive writes (50 us buckets, top 25)")
        ws = [e for e in ev if e["w"]]
        gaps = Counter(int((b["t"] - a["t"]) // 50) * 50 for a, b in zip(ws, ws[1:]) if b["t"] > a["t"])
        for g, c in sorted(gaps.items(), key=lambda kv: -kv[1])[:25]:
            hint = next((f"  <- near {n} ({ref} us)" for ref, n in NEC if abs(g + 25 - ref) <= 60), "")
            print(f"  {g:6d}-{g + 49:<6d} us : {c}{hint}")
        print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
