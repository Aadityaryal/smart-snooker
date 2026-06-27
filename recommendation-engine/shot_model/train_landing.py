#!/usr/bin/env python3
"""
Train the CUE-LANDING model from the spin-varied dataset (shots_spin.jsonl).

Given a shot's geometry + force + spin, predict where the CUE BALL comes to rest.
This is the engine for position play: the recommender uses it to see where each
candidate shot+spin leaves the cue, then scores how good that is for the NEXT shot.

Only shots where the cue actually CONTACTED the target are used (the cue's post-
contact path — hence its landing — is only meaningful once it has struck the ball).
The object ball potting or not doesn't change where the cue goes, so we are NOT
limited to the rare potted shots.

Outputs: models/landing_model.pkl  ({"model_x","model_y","features"})
Prints held-out MAE in table pixels.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error
from sklearn.model_selection import train_test_split

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent
TABLE_W, TABLE_H = 1220.0, 685.0

FEATURES = [
    "cue_x", "cue_y", "target_x", "target_y", "pocket_x", "pocket_y",
    "dist_cue_target", "dist_target_pocket", "cut_angle", "cut_signed",
    "force_frac", "spin_x", "spin_y",
    "num_in_path", "path_clear",   # traffic can deflect the cue en route
]


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
    # keep only contact shots (cue struck the target) — those have a meaningful landing
    if "contact_dist" in df.columns:
        df = df[df["contact_dist"].notna()]
    return df


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(HERE / "shots_spin.jsonl"))
    ap.add_argument("--out", default=str(ENGINE / "models" / "landing_model.pkl"))
    args = ap.parse_args()

    df = load(Path(args.data))
    print(f"contact shots: {len(df):,}")

    X = df[FEATURES]
    yx = df["cue_final_x"]
    yy = df["cue_final_y"]
    Xtr, Xte, yxtr, yxte, yytr, yyte = train_test_split(
        X, yx, yy, test_size=0.2, random_state=0)

    common = dict(n_estimators=300, max_depth=3, learning_rate=0.05,
                  subsample=0.8, random_state=0)
    mx = GradientBoostingRegressor(**common).fit(Xtr, yxtr)
    my = GradientBoostingRegressor(**common).fit(Xtr, yytr)

    px = mx.predict(Xte)
    py = my.predict(Xte)
    mae_x_px = mean_absolute_error(yxte, px) * TABLE_W
    mae_y_px = mean_absolute_error(yyte, py) * TABLE_H
    euclid = np.mean(np.hypot((yxte.values - px) * TABLE_W,
                              (yyte.values - py) * TABLE_H))
    print(f"held-out landing MAE:  x={mae_x_px:.0f}px  y={mae_y_px:.0f}px  "
          f"euclidean={euclid:.0f}px   (table is {TABLE_W:.0f}x{TABLE_H:.0f})")

    # Does spin actually matter? Show its importance.
    print("\ntop features (cue_final_x):")
    for name, imp in sorted(zip(FEATURES, mx.feature_importances_),
                            key=lambda t: -t[1])[:6]:
        print(f"  {name:20s} {imp:.3f}")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({"model_x": mx, "model_y": my, "features": FEATURES}, args.out)
    print(f"\nsaved -> {args.out}")


if __name__ == "__main__":
    main()
