# recommendation-engine/api/main.py
# ─────────────────────────────────────────────────────────────────────────────
# Smart Snooker — FastAPI recommendation server
#
# The /recommend endpoint now receives the FULL table state (cue + every ball +
# phase) and RETURNS THE BEST SHOT — it chooses the target ball, the pocket, the
# aim line and the force, ranked by a makeability model trained on real Godot
# physics (shot_model/train_shots.py). Snooker sequencing (red -> colour -> colour
# order) is enforced by the rules in shot_model/recommend_engine.py.
#
# A geometric fallback runs if the model .pkl is absent.
# ─────────────────────────────────────────────────────────────────────────────
from __future__ import annotations

import sys
from pathlib import Path

import joblib
from fastapi import FastAPI
from pydantic import BaseModel

ENGINE_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE_DIR / "shot_model"))
import recommend_engine as re  # noqa: E402
from recommend_engine import Ball  # noqa: E402

MODEL_PATH = ENGINE_DIR / "models" / "shot_model.pkl"
LANDING_PATH = ENGINE_DIR / "models" / "landing_model.pkl"
model_bundle: dict | None = None
landing_bundle: dict | None = None   # Stage 4: cue-landing model for position play

app = FastAPI(
    title="Smart Snooker Recommendation API",
    description="Physics-trained shot recommender: picks target, pocket, aim, force.",
    version="0.2.0",
)


# ── Request schema: the full table state ──────────────────────────────────────
class BallIn(BaseModel):
    x: float          # normalised 0-1
    y: float
    colour: str       # red|yellow|green|brown|blue|pink|black|cue
    id: int = 0


class RecommendRequest(BaseModel):
    cue_x: float
    cue_y: float
    reds_remaining: int
    must_pot_colour: bool = False
    balls: list[BallIn]


@app.on_event("startup")
async def load_model() -> None:
    global model_bundle, landing_bundle
    if MODEL_PATH.exists():
        model_bundle = joblib.load(MODEL_PATH)
        if not isinstance(model_bundle, dict):
            model_bundle = {"model": model_bundle, "features": list(re.build_features(
                (0.0, 0.0), Ball(0.0, 0.0, "red"), (0.0, 0.0)).keys())}
        print(f"[API] makeability model loaded from {MODEL_PATH}")
    else:
        print(f"[API] WARNING: no model at {MODEL_PATH} — geometric fallback mode.")
    if LANDING_PATH.exists():
        landing_bundle = joblib.load(LANDING_PATH)
        print(f"[API] landing model loaded — strategic (spin/position) mode ON")
    else:
        print(f"[API] no landing model — makeability-only mode (no spin/position yet)")


def _shot_type(cut: float, dist_target_pocket: float) -> str:
    if cut < 10.0 and dist_target_pocket < 0.4:
        return "straight"
    if cut < 28.0:
        return "thin_cut"
    if cut < 58.0:
        return "medium_cut"
    return "heavy_cut"


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "model_loaded": model_bundle is not None,
            "model_path": str(MODEL_PATH)}


@app.post("/recommend")
def recommend_shot(payload: RecommendRequest) -> dict:
    cue = (payload.cue_x, payload.cue_y)
    balls = [Ball(b.x, b.y, b.colour, b.id) for b in payload.balls
             if b.colour != "cue"]

    result = re.recommend_best(
        cue, balls,
        reds_remaining=payload.reds_remaining,
        must_pot_colour=payload.must_pot_colour,
        make_bundle=model_bundle,
        land_bundle=landing_bundle,
        top_k=4,
    )

    if result["mode"] == "none" or not result["recs"]:
        return {"mode": "none", "recommended_shot": None, "alternatives": [],
                "coaching": "No legal shot available."}

    recs = result["recs"]
    resp = {
        "mode": result["mode"],
        "recommended_shot": _shot_dict(cue, recs[0]),
        "alternatives": [
            {
                "target_ball_id": c.target.id,
                "target_x": c.target.x, "target_y": c.target.y,
                "pocket": c.pocket_name,
                "pocket_x": re.POCKETS[c.pocket_name][0],
                "pocket_y": re.POCKETS[c.pocket_name][1],
                "confidence": round(c.confidence * 100.0, 1),
            }
            for c in recs[1:]
        ],
        "coaching": _coaching(result),
        "ball_map": re.ball_makeability(cue, balls, payload.reds_remaining,
                                        payload.must_pot_colour, model_bundle),
    }
    if result["mode"] == "safety":
        s = result["safety"]
        resp["safety"] = {
            "target_x": s["target"].x, "target_y": s["target"].y,
            "cue_landing": s["cue_landing"], "spin": s["spin"],
            "opponent_value": round(s["opponent_value"] * 100.0, 1),
        }
    return resp


def _spin_name(sx: float, sy: float) -> str:
    parts = []
    if sy > 0.3:
        parts.append("follow (top)")
    elif sy < -0.3:
        parts.append("draw (back)")
    if sx > 0.3:
        parts.append("right-hand side")
    elif sx < -0.3:
        parts.append("left-hand side")
    return " + ".join(parts)


def _difficulty(conf: float, cut: float) -> str:
    """Plain-language read of the shot, so the % has context."""
    shape = "cut" if cut >= 28.0 else "pot"
    if conf >= 70.0:
        return f"A comfortable {shape}"
    if conf >= 45.0:
        return f"A makeable {shape}"
    if conf >= 30.0:
        return f"A tricky {shape} — the best that's on"
    return f"A long-odds {shape}"


def _coaching(result: dict) -> str:
    recs = result["recs"]
    best = recs[0]
    conf = best.confidence * 100.0
    if result["mode"] == "safety":
        opp = result["safety"]["opponent_value"] * 100.0
        return (f"No pot worth taking (best only {conf:.0f}%) — play safe and "
                f"leave your opponent a tough table (~{opp:.0f}% for them).")
    f = best.features
    pv = f.get("position_value_2ply", f.get("position_value", 0.0)) * 100.0
    risk = f.get("miss_risk", 0.0) * 100.0
    spin = _spin_name(f.get("spin_x", 0.0), f.get("spin_y", 0.0))
    out = [f"{_difficulty(conf, best.cut_angle)} ({conf:.0f}%). "
           f"Power ~{best.force_frac * 100:.0f}%."]
    if spin:
        out.append(f"Use {spin}")
        out.append("to leave position." if pv >= 30 else "for cue control.")
    if pv >= 45:
        out.append(f"Great position after (~{pv:.0f}%).")
    elif pv < 20:
        out.append("Position after is tricky.")
    if risk >= 45:
        out.append(f"⚠ Miss and you hand them ~{risk:.0f}%.")
    return " ".join(out)


def _shot_dict(cue: tuple, best) -> dict:
    ppos = re.POCKETS[best.pocket_name]
    d = {
        "target_ball_id": best.target.id,
        "target_x": best.target.x,
        "target_y": best.target.y,
        "target_colour": best.target.colour,
        "pocket": best.pocket_name,
        "pocket_x": ppos[0],
        "pocket_y": ppos[1],
        "confidence": round(best.confidence * 100.0, 1),
        "cut_angle": round(best.cut_angle, 1),
        "shot_type": _shot_type(best.cut_angle, best.features["dist_target_pocket"]),
        "force": round(best.force_frac, 3),
        "aim_point": list(best.aim_point),
        "cue_path": [[cue[0], cue[1]], [best.target.x, best.target.y]],
    }
    # Stage 4 strategic extras (present when the landing model is loaded).
    if "spin_x" in best.features:
        d["spin"] = [round(best.features["spin_x"], 2), round(best.features["spin_y"], 2)]
        pv = best.features.get("position_value_2ply", best.features.get("position_value", 0.0))
        d["position_value"] = round(pv * 100.0, 1)
        d["miss_risk"] = round(best.features.get("miss_risk", 0.0) * 100.0, 1)
        d["cue_landing"] = [round(v, 4) for v in best.features.get("cue_landing", [0, 0])]
    return d


# ── Cue-ball placement (ball in hand: break / after foul) ─────────────────────
class PlaceRequest(BaseModel):
    reds_remaining: int
    must_pot_colour: bool = False
    balls: list[BallIn]


@app.post("/place_cue")
def place_cue(payload: PlaceRequest) -> dict:
    balls = [Ball(b.x, b.y, b.colour, b.id) for b in payload.balls if b.colour != "cue"]
    res = re.recommend_cue_placement(
        balls, payload.reds_remaining, payload.must_pot_colour,
        model_bundle, landing_bundle)
    if res is None:
        return {"cue_placement": None, "reason": "no makeable shot from the D"}
    return {
        "cue_placement": {"cue_x": res["cue_x"], "cue_y": res["cue_y"]},
        "then_play": _shot_dict((res["cue_x"], res["cue_y"]), res["best_shot"]),
    }
