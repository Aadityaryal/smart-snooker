#!/usr/bin/env python3
"""
Train the shot-makeability model from real physics outcomes (shots.jsonl).

Target: `potted` (did the object ball drop into the AIMED pocket).
Because the ghost-ball aim is provably correct and the game computes execution
(aim + distance-matched force) analytically, the model's job is to score how
MAKEABLE a target->pocket geometry is, given realistic aim error — i.e. the
confidence the recommender ranks shots by.

Outputs:
    models/shot_model.pkl   (the trained pipeline; loaded by api/main.py)
Prints held-out AUC + a calibration table (predicted vs actual pot rate).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent

# Geometry features the recommender can compute at query time (no aim/force needed:
# execution is analytic). This is a MAKEABILITY model, not a per-execution model.
FEATURES = [
    "dist_cue_target",
    "dist_target_pocket",
    "cut_angle",
    "cue_x", "cue_y",
    "target_x", "target_y",
    "pocket_x", "pocket_y",
    "num_in_path", "path_clear",   # obstruction-aware (traffic)
    "spin_x", "spin_y",            # spin-aware (spin reduces pot chance)
]
# NOTE: do NOT add aim_offset / force_frac here. Tried it (per-execution confidence);
# the GBM overfits sharp peaks at scattered aim offsets, so querying it pointwise
# hallucinated ~74% on thin cuts that truly pot ~2%. This MARGINAL model (averaged
# over the sim's aim spread) is honest and well-ranked: easy shots ~40-48%, thin
# cuts ~1-6%, matching the measured best-execution pot rates. Higher HONEST numbers
# need more forgiving physics (bigger pockets), not more features.


def load(path: Path) -> pd.DataFrame:
    rows = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    df = pd.DataFrame(rows)
    return df


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(HERE / "shots.jsonl"))
    ap.add_argument("--out", default=str(ENGINE / "models" / "shot_model.pkl"))
    args = ap.parse_args()

    df = load(Path(args.data))
    print(f"loaded {len(df):,} shots   pot rate={df['potted'].mean():.1%}   "
          f"foul rate={df['foul'].mean():.1%}")

    X = df[FEATURES]
    y = df["potted"].astype(int)
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.2, random_state=0, stratify=y)

    model = GradientBoostingClassifier(
        n_estimators=300, max_depth=3, learning_rate=0.05, subsample=0.8, random_state=0
    )
    model.fit(Xtr, ytr)

    p = model.predict_proba(Xte)[:, 1]
    auc = roc_auc_score(yte, p)
    print(f"\nheld-out ROC-AUC = {auc:.3f}   (0.5=useless, 1.0=perfect ranking)")

    # Calibration: bucket predictions, compare to actual pot rate.
    print("\ncalibration (predicted confidence -> actual pot rate):")
    dfte = pd.DataFrame({"p": p, "y": yte.values})
    for lo, hi in [(0, .05), (.05, .1), (.1, .2), (.2, .35), (.35, 1.0)]:
        b = dfte[(dfte.p >= lo) & (dfte.p < hi)]
        if len(b):
            print(f"  pred {lo:.2f}-{hi:.2f}: actual={b.y.mean():5.1%}  (n={len(b)})")

    # Feature importances — sanity check the model relies on real geometry.
    print("\ntop features:")
    for name, imp in sorted(zip(FEATURES, model.feature_importances_),
                            key=lambda t: -t[1])[:6]:
        print(f"  {name:22s} {imp:.3f}")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({"model": model, "features": FEATURES}, args.out)
    print(f"\nsaved -> {args.out}")


if __name__ == "__main__":
    main()
