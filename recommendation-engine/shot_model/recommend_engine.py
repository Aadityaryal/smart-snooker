#!/usr/bin/env python3
"""
Recommendation engine: given a full table state, pick the best shot.

The pipeline is:
  1. snooker RULES decide the legal target set (red -> colour -> ... -> colour order)
  2. enumerate every legal (target ball x pocket) candidate
  3. drop candidates that are geometrically impossible (cut too fine) or blocked
  4. score each survivor's MAKEABILITY with the physics-trained model
  5. rank; return the best + alternatives, each with an ANALYTIC execution
     (ghost-ball aim + distance-matched force) the overlay can draw

Coordinates are normalised 0-1 (x by TABLE_W, y by TABLE_H) to match api_bridge.gd
and the training data. Distances are computed in pixels then divided by TABLE_W,
exactly as the Godot sim recorded them, so features line up with the model.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

TABLE_W = 1220.0
TABLE_H = 685.0
BALL_D_PX = 44.0          # cue<->object contact distance (measured empirically)
BALL_R_NORM = 22.0 / TABLE_W
MAX_CUT_DEG = 75.0        # beyond this the pocket is effectively behind the ball

# Six pockets, normalised (mirrors Globals.POCKET_POSITIONS / _POCKET_COORDS).
POCKETS = {
    "top_left":      (35 / TABLE_W, 35 / TABLE_H),
    "top_middle":    (640 / TABLE_W, 35 / TABLE_H),
    "top_right":     (1245 / TABLE_W, 35 / TABLE_H),
    "bottom_left":   (35 / TABLE_W, 685 / TABLE_H),
    "bottom_middle": (640 / TABLE_W, 685 / TABLE_H),
    "bottom_right":  (1245 / TABLE_W, 685 / TABLE_H),
}

# A pot is HARD-rejected when another ball sits within BLOCK_PX of the line the CUE
# travels (cue->ghost) OR the line the OBJECT travels (target->pocket). At that
# clearance a collision is unavoidable — cue radius 22 + ball radius 22 = 44 px
# contact — so the recommended ball could never actually be reached / potted. This
# is the fix for "the AI says 95 % but there's a ball in the way": the old threshold
# (0.12 ≈ 5 px) only caught a ball sitting dead-centre on the line, so a ball 20 px
# off — a guaranteed clip — passed as "clear". The model's num_in_path / path_clear
# features still price PARTIAL traffic (near-grazes at 40-44 px) smoothly on top.
BLOCK_PX = 40.0
BLOCK_CLEAR = BLOCK_PX / 44.0     # corridor is 44 px wide; min_clear below this = struck

COLOUR_ORDER = ["yellow", "green", "brown", "blue", "pink", "black"]
COLOUR_VALUE = {"red": 1, "yellow": 2, "green": 3, "brown": 4,
                "blue": 5, "pink": 6, "black": 7}


@dataclass
class Ball:
    x: float          # normalised 0-1
    y: float
    colour: str
    id: int = 0


@dataclass
class Candidate:
    target: Ball
    pocket_name: str
    confidence: float
    cut_angle: float
    aim_point: tuple[float, float]     # ghost-ball aim point (normalised)
    force_frac: float
    features: dict = field(default_factory=dict)


def _px(p: tuple[float, float]) -> tuple[float, float]:
    return (p[0] * TABLE_W, p[1] * TABLE_H)


def _dist_px(a: tuple[float, float], b: tuple[float, float]) -> float:
    ax, ay = _px(a)
    bx, by = _px(b)
    return math.hypot(ax - bx, ay - by)


def legal_targets(reds_remaining: int, must_pot_colour: bool,
                  balls: list[Ball]) -> list[Ball]:
    """Return the balls the player is allowed to hit next, per snooker rules."""
    if reds_remaining > 0:
        if must_pot_colour:
            # A red was just potted -> any colour is on.
            return [b for b in balls if b.colour in COLOUR_ORDER]
        # Otherwise a red must be struck.
        return [b for b in balls if b.colour == "red"]
    # No reds left: colours in ascending value order; only the lowest is on.
    remaining = [b for b in balls if b.colour in COLOUR_ORDER]
    if not remaining:
        return []
    lowest = min(remaining, key=lambda b: COLOUR_VALUE[b.colour])
    return [b for b in remaining if b.colour == lowest.colour]


def _cut_angle_deg(cue: tuple, target: tuple, pocket: tuple) -> float:
    cx, cy = _px(cue)
    tx, ty = _px(target)
    px, py = _px(pocket)
    v1 = (tx - cx, ty - cy)
    v2 = (px - tx, py - ty)
    n1 = math.hypot(*v1) or 1e-9
    n2 = math.hypot(*v2) or 1e-9
    dot = (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)
    return math.degrees(math.acos(max(-1.0, min(1.0, dot))))


def _path_blocked(a: Ball | tuple, b: tuple, balls: list[Ball],
                  ignore: Ball, clearance_norm: float) -> bool:
    """Is any other ball within `clearance` of the segment a->b?"""
    ax, ay = (a.x, a.y) if isinstance(a, Ball) else a
    bx, by = b
    for ball in balls:
        if ball is ignore or (isinstance(a, Ball) and ball is a):
            continue
        # distance from ball centre to segment a-b (in normalised space, roughly)
        dx, dy = bx - ax, by - ay
        seg2 = dx * dx + dy * dy or 1e-9
        t = ((ball.x - ax) * dx + (ball.y - ay) * dy) / seg2
        if t < 0.0 or t > 1.0:
            continue
        px, py = ax + t * dx, ay + t * dy
        if math.hypot(ball.x - px, ball.y - py) < clearance_norm:
            return True
    return False


def _ghost_aim(target: tuple, pocket: tuple) -> tuple[float, float]:
    """Ghost-ball aim point (normalised): BALL_D_PX behind the target on the
    target->pocket line."""
    tx, ty = _px(target)
    px, py = _px(pocket)
    dx, dy = tx - px, ty - py
    n = math.hypot(dx, dy) or 1e-9
    gx, gy = tx + BALL_D_PX * dx / n, ty + BALL_D_PX * dy / n
    return (gx / TABLE_W, gy / TABLE_H)


def _corridor_obstruction(a: tuple, b: tuple, balls: list, ignore) -> tuple:
    """(count, min_clear) of balls within a ball-width of segment a→b. Mirrors the
    sim's obstruction measure so the model's num_in_path/path_clear features align.
    min_clear: 0 = a ball dead on the line, 1 = clear."""
    ax, ay = _px(a)
    bx, by = _px(b)
    sx, sy = bx - ax, by - ay
    seg_len = math.hypot(sx, sy)
    if seg_len < 1.0:
        return (0, 1.0)
    dx, dy = sx / seg_len, sy / seg_len
    corridor = 44.0
    count = 0
    min_perp = corridor
    for ball in balls:
        if ball is ignore:
            continue
        px, py = _px((ball.x, ball.y))
        tox, toy = px - ax, py - ay
        proj = tox * dx + toy * dy
        if proj <= 25.0 or proj >= seg_len - 25.0:
            continue
        perp = math.hypot(tox - dx * proj, toy - dy * proj)
        if perp < corridor:
            count += 1
            min_perp = min(min_perp, perp)
    return (count, min_perp / corridor)


def _shot_blocked(cue: tuple, target: Ball, pocket: tuple, balls: list) -> bool:
    """Physically-exact block test: True if the cue cannot reach the ghost, or the
    object cannot reach the pocket, without striking another ball. Checks the CUE's
    real travel line (cue->ghost, not cue->target) so a ball just short of the ghost
    is caught. Used to hard-reject impossible pots before ranking by the model."""
    ghost = _ghost_aim((target.x, target.y), pocket)
    oc = _corridor_obstruction(cue, ghost, balls, target)                    # cue -> ghost
    if oc[0] > 0 and oc[1] < BLOCK_CLEAR:
        return True
    op = _corridor_obstruction((target.x, target.y), pocket, balls, target)  # object -> pocket
    if op[0] > 0 and op[1] < BLOCK_CLEAR:
        return True
    return False


def build_features(cue: tuple, target: Ball, pocket: tuple,
                   balls: list | None = None, spin: tuple = (0.0, 0.0)) -> dict:
    """Model features for one candidate. `balls` enables obstruction features;
    `spin` lets the pot model account for spin reducing the pot chance."""
    dct = _dist_px((cue[0], cue[1]), (target.x, target.y)) / TABLE_W
    dtp = _dist_px((target.x, target.y), pocket) / TABLE_W
    if balls is not None:
        oc = _corridor_obstruction(cue, (target.x, target.y), balls, target)
        op = _corridor_obstruction((target.x, target.y), pocket, balls, target)
        num_in_path = oc[0] + op[0]
        path_clear = min(oc[1], op[1])
    else:
        num_in_path, path_clear = 0, 1.0
    return {
        "dist_cue_target": dct,
        "dist_target_pocket": dtp,
        "cut_angle": _cut_angle_deg(cue, (target.x, target.y), pocket),
        "cue_x": cue[0], "cue_y": cue[1],
        "target_x": target.x, "target_y": target.y,
        "pocket_x": pocket[0], "pocket_y": pocket[1],
        "num_in_path": num_in_path, "path_clear": path_clear,
        "spin_x": spin[0], "spin_y": spin[1],
    }


# ─────────────────────────────────────────────────────────────────────────────
# PER-EXECUTION ("best-aim") confidence
# The makeability model, if trained WITH aim_offset + force_frac, predicts the pot
# chance for a SPECIFIC execution. Averaging over the sim's wild ±17° aim window made
# every shot read ~25 %. Instead we score each shot at the BEST aim offset for the
# recommended (distance-matched) force — what a skilled player / "Play AI Shot" does —
# so an easy shot reads ~85 % and a hard cut ~5 %: honest, discriminating confidence.
# Falls back to the plain model automatically if it lacks the execution features.
# ─────────────────────────────────────────────────────────────────────────────
def _dm_force(dct: float, dtp: float) -> float:
    """Distance-matched force the recommender/sim use (object arrives droppable)."""
    return max(0.22, min(1.0, 0.20 + 0.80 * (dct + dtp)))


def _uses_execution(make_bundle: dict) -> bool:
    return "aim_offset" in make_bundle.get("features", [])


def _best_aim_probs(make_bundle: dict, feat_rows: list[dict],
                    forces: list[float]) -> list[tuple]:
    """Execution pot probability for each shot: the model scored at the GEOMETRIC
    ghost aim (aim_offset = 0) and the distance-matched force — i.e. the exact shot
    the recommender/overlay/"Play AI Shot" execute.

    NOTE: an earlier version maxed over an aim-offset grid to find the "best aim".
    That was a bug: on thin cuts (cut ≳ 55°, which truly pot ~0-3%) the GBM
    hallucinates ~74% at non-zero offsets where there is almost no training data, and
    the max picked that garbage — so the AI confidently recommended near-impossible
    cuts. At offset 0 (dense data) the model is correct: straight ≈ 96%, thin cut
    ≈ 2%. So we score the aim actually used, never the grid maximum.

    Returns (prob, 0.0) per row. Plain predict if the model lacks execution features.
    """
    import pandas as pd
    cols = make_bundle["features"]
    if not _uses_execution(make_bundle):
        P = make_bundle["model"].predict_proba(pd.DataFrame(feat_rows)[cols])[:, 1]
        return [(float(p), 0.0) for p in P]
    rows = [{**fr, "aim_offset": 0.0, "force_frac": force}
            for fr, force in zip(feat_rows, forces)]
    P = make_bundle["model"].predict_proba(pd.DataFrame(rows)[cols])[:, 1]
    return [(float(p), 0.0) for p in P]




def recommend(cue: tuple, balls: list[Ball], reds_remaining: int,
              must_pot_colour: bool, model_bundle: dict | None,
              top_k: int = 4) -> list[Candidate]:
    """Rank legal shots best-first. model_bundle = {"model","features"} or None."""
    import pandas as pd

    targets = legal_targets(reds_remaining, must_pot_colour, balls)
    cands: list[Candidate] = []
    for tgt in targets:
        for pname, ppos in POCKETS.items():
            cut = _cut_angle_deg(cue, (tgt.x, tgt.y), ppos)
            if cut >= MAX_CUT_DEG:
                continue
            feats = build_features(cue, tgt, ppos, balls)   # obstruction-aware
            if _shot_blocked(cue, tgt, ppos, balls):
                continue                                     # cue/object line is blocked
            aim = _ghost_aim((tgt.x, tgt.y), ppos)
            # Distance-matched force, BOOSTED for the cut angle: a thin hit only
            # transfers force*cos(cut) to the object, so the cue needs more pace to
            # send it the same distance. Err slightly high — too soft never pots, a
            # touch of extra pace still drops it. (Was 0.20+0.80·d with no cut term,
            # which under-powered cuts — "the power wasn't even enough to pot".)
            total = feats["dist_cue_target"] + feats["dist_target_pocket"]
            cos_cut = max(math.cos(math.radians(cut)), 0.55)
            force = max(0.30, min(1.0, (0.24 + 0.82 * total) / cos_cut))
            cands.append(Candidate(
                target=tgt, pocket_name=pname, confidence=0.0,
                cut_angle=cut, aim_point=aim, force_frac=force, features=feats))

    if not cands:
        return []

    if model_bundle is not None:
        # Per-execution confidence: pot chance at the ghost aim + matched force.
        probs = _best_aim_probs(model_bundle, [c.features for c in cands],
                                [c.force_frac for c in cands])
        for c, (p, _off) in zip(cands, probs):
            c.confidence = p
    else:
        # Geometric fallback if the model is missing.
        for c in cands:
            c.confidence = max(0.0, 1.0 - c.cut_angle / 90.0
                               - c.features["dist_target_pocket"])

    cands.sort(key=lambda c: c.confidence, reverse=True)
    return cands[:top_k]


# ═════════════════════════════════════════════════════════════════════════════
# STAGE 4 — strategic layer: spin, position play, cue-ball placement
# ═════════════════════════════════════════════════════════════════════════════

# Spin options tried per shot (side_x, top/back_y): none, follow, draw, L/R side,
# and the four diagonals. The recommender keeps the pocket/target from makeability
# and picks the spin that best sets up the NEXT shot.
SPIN_GRID = [(0.0, 0.0), (0.0, 0.8), (0.0, -0.8), (0.8, 0.0), (-0.8, 0.0),
             (0.6, 0.6), (-0.6, 0.6), (0.6, -0.6), (-0.6, -0.6)]

# score = pot_prob * (POS_A + POS_B * position_value). Pot-DOMINANT: the surest
# pot is #1, position only breaks near-ties and still picks the best spin. (Raise
# POS_B toward 0.45 for a more position-first "break-building" style.)
POS_A, POS_B = 0.80, 0.20


def _cut_signed(cue: tuple, target: tuple, pocket: tuple) -> float:
    cx, cy = _px(cue); tx, ty = _px(target); px, py = _px(pocket)
    v1 = (tx - cx, ty - cy); v2 = (px - tx, py - ty)
    cross = v1[0] * v2[1] - v1[1] * v2[0]
    return _cut_angle_deg(cue, target, pocket) * (1.0 if cross >= 0 else -1.0)


def landing_features(cue: tuple, target: Ball, pocket: tuple,
                     force: float, spin: tuple, balls: list | None = None) -> dict:
    f = build_features(cue, target, pocket, balls, spin)
    f["cut_signed"] = _cut_signed(cue, (target.x, target.y), pocket)
    f["force_frac"] = force
    return f


def _predict_landings(land_bundle: dict, rows: list[dict]) -> list[tuple]:
    import pandas as pd
    cols = land_bundle["features"]
    X = pd.DataFrame(rows)[cols]
    xs = land_bundle["model_x"].predict(X)
    ys = land_bundle["model_y"].predict(X)
    return [(float(a), float(b)) for a, b in zip(xs, ys)]


def position_value(cue_landing: tuple, balls_after: list[Ball],
                   reds_after: int, must_colour_after: bool,
                   make_bundle: dict, land_bundle: dict | None = None,
                   depth: int = 1) -> float:
    """Best makeability of the NEXT legal shot from the predicted cue landing.
    depth>1 (with land_bundle) looks further ahead — break-building: value a shot
    by whether it also leaves position for the shot AFTER it."""
    import pandas as pd
    cl = (min(1.0, max(0.0, cue_landing[0])), min(1.0, max(0.0, cue_landing[1])))
    nexts = legal_targets(reds_after, must_colour_after, balls_after)
    rows, cands = [], []
    for tgt in nexts:
        for pname, ppos in POCKETS.items():
            if _cut_angle_deg(cl, (tgt.x, tgt.y), ppos) >= MAX_CUT_DEG:
                continue
            f = build_features(cl, tgt, ppos, balls_after)
            if _shot_blocked(cl, tgt, ppos, balls_after):
                continue
            rows.append(f)
            cands.append((tgt, ppos))
    if not rows:
        return 0.0
    # Score the next shots at their best execution (offset 0 ≈ optimal, cheap enough
    # for a lookahead) so position value is consistent with the recommender's scale.
    if _uses_execution(make_bundle):
        for r in rows:
            r["aim_offset"] = 0.0
            r["force_frac"] = _dm_force(r["dist_cue_target"], r["dist_target_pocket"])
    pots = make_bundle["model"].predict_proba(pd.DataFrame(rows)[make_bundle["features"]])[:, 1]
    if depth <= 1 or land_bundle is None:
        return float(pots.max())

    # 2-ply: for the few best next shots, add the position they leave after that.
    order = sorted(range(len(pots)), key=lambda i: -pots[i])[:4]
    best = 0.0
    for i in order:
        tgt, ppos = cands[i]
        dtot = (_dist_px(cl, (tgt.x, tgt.y)) + _dist_px((tgt.x, tgt.y), ppos)) / TABLE_W
        force = max(0.22, min(1.0, 0.20 + 0.80 * dtot))
        lf = landing_features(cl, tgt, ppos, force, (0.0, 0.0), balls_after)
        land2 = _predict_landings(land_bundle, [lf])[0]
        balls2 = [b for b in balls_after if b is not tgt]
        reds2 = reds_after - (1 if tgt.colour == "red" else 0)
        mc2 = (tgt.colour == "red")
        pv2 = position_value(land2, balls2, reds2, mc2, make_bundle, None, 1)
        best = max(best, float(pots[i]) * (0.5 + 0.5 * pv2))
    return best


def recommend_strategic(cue: tuple, balls: list[Ball], reds_remaining: int,
                        must_pot_colour: bool, make_bundle: dict | None,
                        land_bundle: dict | None, top_k: int = 4) -> list[Candidate]:
    """Rank shots by pot × position, choosing the best spin for each. Falls back
    to plain makeability ranking if the landing model is absent."""
    base = recommend(cue, balls, reds_remaining, must_pot_colour, make_bundle, top_k=8)
    if land_bundle is None or make_bundle is None or not base:
        return base[:top_k]

    import pandas as pd
    make_cols = make_bundle["features"]
    scored: list[Candidate] = []
    for c in base:
        ppos = POCKETS[c.pocket_name]
        # state after potting this target (the game removes the potted ball)
        balls_after = [b for b in balls if b is not c.target]
        reds_after = reds_remaining - (1 if c.target.colour == "red" else 0)
        must_colour_after = (c.target.colour == "red")  # a red is always followed by a colour

        # Predict cue landing AND pot probability for each spin option (spin-aware:
        # spin steers the cue for position but also lowers the pot chance).
        land_rows = [landing_features(cue, c.target, ppos, c.force_frac, s, balls) for s in SPIN_GRID]
        landings = _predict_landings(land_bundle, land_rows)
        pot_rows = [build_features(cue, c.target, ppos, balls, s) for s in SPIN_GRID]
        # best-aim pot chance for each spin option (side spin lowers it)
        pots = [p for p, _ in _best_aim_probs(make_bundle, pot_rows,
                                              [c.force_frac] * len(SPIN_GRID))]

        best = None
        for s, land, pot in zip(SPIN_GRID, landings, pots):
            pv = position_value(land, balls_after, reds_after, must_colour_after, make_bundle)
            sc = float(pot) * (POS_A + POS_B * pv)
            if best is None or sc > best[0]:
                best = (sc, s, pv, land, float(pot))
        sc, spin, pv, land, pot = best
        c.confidence = pot                       # pot chance WITH the chosen spin
        c.features["spin_x"], c.features["spin_y"] = spin
        c.features["position_value"] = pv
        c.features["cue_landing"] = list(land)
        c.features["score"] = sc
        # Miss risk: if you MISS, the target stays and the opponent plays from where
        # the cue lands — how good is their best shot then? (high = dangerous)
        c.features["miss_risk"] = position_value(land, balls, reds_remaining, False, make_bundle)
        scored.append(c)

    scored.sort(key=lambda c: c.features["score"], reverse=True)
    return scored[:top_k]


# Below this best-pot confidence, playing a pot is a poor bet — recommend safety.
SAFETY_THRESHOLD = 0.30
SAFETY_FORCES = [0.22, 0.32, 0.45]


def _best_safety(cue: tuple, balls: list[Ball], reds_remaining: int,
                 must_pot_colour: bool, make_bundle: dict, land_bundle: dict) -> dict | None:
    """Pick the soft, legal shot that leaves the OPPONENT the worst position.
    Still contacts a legal ball (so it's not a foul); uses low force so the cue
    stays back, and searches spin to bury the cue where nothing is on."""
    base = recommend(cue, balls, reds_remaining, must_pot_colour, make_bundle, top_k=10)
    if not base:
        return None
    best = None
    for c in base:
        ppos = POCKETS[c.pocket_name]
        rows, combos = [], []
        for f in SAFETY_FORCES:
            for s in SPIN_GRID:
                rows.append(landing_features(cue, c.target, ppos, f, s, balls))
                combos.append((f, s))
        landings = _predict_landings(land_bundle, rows)
        for (f, s), land in zip(combos, landings):
            # After a safety nothing is potted; the opponent must pot a red next.
            opp = position_value(land, balls, reds_remaining, False, make_bundle)
            if best is None or opp < best[0]:
                best = (opp, c.target, c.pocket_name, land, f, s)
    if best is None:
        return None
    opp, tgt, pname, land, f, s = best
    return {"target": tgt, "pocket": pname, "cue_landing": list(land),
            "force": f, "spin": list(s), "opponent_value": opp}


def ball_makeability(cue: tuple, balls: list[Ball], reds_remaining: int,
                     must_pot_colour: bool, make_bundle: dict | None) -> list[dict]:
    """Best makeability of each LEGAL ball from the current cue position (for the
    table heatmap). Returns [{x, y, make, colour, id}]."""
    import pandas as pd
    if make_bundle is None:
        return []
    out = []
    for tgt in legal_targets(reds_remaining, must_pot_colour, balls):
        rows = []
        for ppos in POCKETS.values():
            if _cut_angle_deg(cue, (tgt.x, tgt.y), ppos) >= MAX_CUT_DEG:
                continue
            f = build_features(cue, tgt, ppos, balls)
            if _shot_blocked(cue, tgt, ppos, balls):
                continue
            rows.append(f)
        best = 0.0
        if rows:
            forces = [_dm_force(r["dist_cue_target"], r["dist_target_pocket"]) for r in rows]
            best = max(p for p, _ in _best_aim_probs(make_bundle, rows, forces))
        out.append({"x": tgt.x, "y": tgt.y, "make": round(best, 3),
                    "colour": tgt.colour, "id": tgt.id})
    return out


def recommend_best(cue: tuple, balls: list[Ball], reds_remaining: int,
                   must_pot_colour: bool, make_bundle: dict | None,
                   land_bundle: dict | None, top_k: int = 4) -> dict:
    """Top-level: recommend a POT if a decent one exists, else a SAFETY. Returns a
    dict with mode + ranked pot options (+ safety when relevant)."""
    recs = recommend_strategic(cue, balls, reds_remaining, must_pot_colour,
                               make_bundle, land_bundle, top_k=max(top_k, 4))
    if not recs:
        return {"mode": "none", "recs": []}
    if recs[0].confidence >= SAFETY_THRESHOLD or land_bundle is None:
        # Break-building: re-score the top few with 2-ply lookahead (does this shot
        # also leave position for the shot AFTER the next one?) and re-rank.
        if land_bundle is not None:
            for c in recs[:4]:
                balls_after = [b for b in balls if b is not c.target]
                reds_after = reds_remaining - (1 if c.target.colour == "red" else 0)
                mc_after = (c.target.colour == "red")
                pv2 = position_value(tuple(c.features["cue_landing"]), balls_after,
                                     reds_after, mc_after, make_bundle, land_bundle, depth=2)
                c.features["position_value_2ply"] = pv2
                c.features["score"] = c.confidence * (POS_A + POS_B * pv2)
            recs.sort(key=lambda c: c.features["score"], reverse=True)
        return {"mode": "pot", "recs": recs[:top_k]}
    safety = _best_safety(cue, balls, reds_remaining, must_pot_colour,
                          make_bundle, land_bundle)
    if safety is None:
        return {"mode": "pot", "recs": recs[:top_k]}
    return {"mode": "safety", "safety": safety, "recs": recs[:top_k]}


def _d_grid(n: int = 9) -> list[tuple]:
    """Candidate cue-ball spots across the baulk 'D' (left semicircle)."""
    # Mirrors Globals: D centred near baulk line, left third of the table.
    cx, cy, r = 0.16, 0.5, 0.11
    pts = [(cx, cy)]
    import math
    for i in range(n):
        ang = math.pi * (0.5 + i / (n - 1))   # left semicircle
        pts.append((cx + r * math.cos(ang) * 0.4, cy + r * math.sin(ang)))
    return [(min(0.3, max(0.03, x)), min(0.95, max(0.05, y))) for x, y in pts]


def recommend_cue_placement(balls: list[Ball], reds_remaining: int,
                            must_pot_colour: bool, make_bundle: dict | None,
                            land_bundle: dict | None) -> dict | None:
    """Ball-in-hand: search the D for the spot giving the best first shot."""
    best = None
    for spot in _d_grid():
        recs = recommend_strategic(spot, balls, reds_remaining, must_pot_colour,
                                   make_bundle, land_bundle, top_k=1)
        if not recs:
            continue
        score = recs[0].features.get("score", recs[0].confidence)
        if best is None or score > best[0]:
            best = (score, spot, recs[0])
    if best is None:
        return None
    _, spot, rec = best
    return {"cue_x": spot[0], "cue_y": spot[1], "best_shot": rec}

