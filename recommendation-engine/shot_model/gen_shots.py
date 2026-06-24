#!/usr/bin/env python3
"""
Parallel shot-data generator for the Smart Snooker recommendation model.

Launches N headless Godot instances of the exported game binary, each running the
`--sim-shots` mode built into table.gd. Every instance fires scripted shots at the
REAL game physics and appends {geometry, aim, force} -> {potted, foul, cue landing}
records to its own JSONL shard. The shards are concatenated at the end.

This replaces the hand-written formula in data/generate_data.py with ground truth
straight from the physics the game actually runs.

Example:
    python shot_model/gen_shots.py --total 60000 --parallel 4 --speedup 30 \
        --forcebase 0.28 --forcek 0.95 --noise 0.05
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent
BINARY = ENGINE / "smart_snooker.x86_64" / "smart_snooker.x86_64"
OUT = HERE / "shots.jsonl"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--total", type=int, default=60000, help="total shots across all workers")
    ap.add_argument("--parallel", type=int, default=4, help="concurrent Godot instances")
    ap.add_argument("--speedup", type=int, default=30)
    ap.add_argument("--noise", type=float, default=0.05, help="aim error std/half-width (rad)")
    ap.add_argument("--forcebase", type=float, default=0.28)
    ap.add_argument("--forcek", type=float, default=0.95)
    ap.add_argument("--spin", type=float, default=0.0, help="spin magnitude 0-1 (Stage 4 = 1)")
    ap.add_argument("--blockers", type=int, default=0, help="max random blocker balls per shot")
    ap.add_argument("--binary", default=str(BINARY))
    ap.add_argument("--out", default=str(OUT))
    args = ap.parse_args()

    if not Path(args.binary).exists():
        sys.exit(f"binary not found: {args.binary}\n(re-export first)")

    per = max(1, args.total // args.parallel)
    # Godot's FileAccess.open() FAILS on relative OS paths — the sim then never
    # starts and the game idles forever. Always hand the workers ABSOLUTE paths.
    out_path = Path(args.out).resolve()
    shard_dir = out_path.parent / "_shards"
    shard_dir.mkdir(parents=True, exist_ok=True)
    for old in shard_dir.glob("shard_*.jsonl"):
        old.unlink()

    print(f"Generating ~{per * args.parallel:,} shots via {args.parallel} workers "
          f"(speedup {args.speedup})...")
    procs = []
    shards = []
    for i in range(args.parallel):
        shard = shard_dir / f"shard_{i}.jsonl"
        shards.append(shard)
        cmd = [
            args.binary, "--headless",
            f"--sim-shots={per}",
            f"--sim-speedup={args.speedup}",
            f"--sim-noise={args.noise}",
            f"--sim-forcebase={args.forcebase}",
            f"--sim-forcek={args.forcek}",
            f"--sim-spin={args.spin}",
            f"--sim-blockers={args.blockers}",
            f"--sim-out={shard}",
        ]
        procs.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    t0 = time.time()
    checked = False
    while any(p.poll() is None for p in procs):
        done = sum(sum(1 for _ in open(s)) for s in shards if s.exists())
        # Fail fast: if nothing has been written after 40s, the workers are idling
        # (bad path, missing binary, crash) — don't waste hours silently.
        if not checked and time.time() - t0 > 40:
            checked = True
            if done == 0:
                print("\nERROR: no shots after 40s — workers are idling (check paths/binary). Aborting.")
                for p in procs:
                    p.kill()
                sys.exit(1)
        print(f"\r  {done:,}/{per * args.parallel:,} shots "
              f"({done / max(1, time.time() - t0):.1f}/s)", end="", flush=True)
        time.sleep(3)

    # Concatenate shards.
    total = 0
    with open(args.out, "w") as fout:
        for s in shards:
            if not s.exists():
                continue
            for line in open(s):
                line = line.strip()
                if line:
                    fout.write(line + "\n")
                    total += 1
    dt = time.time() - t0
    print(f"\nDone: {total:,} shots in {dt / 60:.1f} min ({total / dt:.1f}/s) -> {args.out}")


if __name__ == "__main__":
    main()
