# res://scripts/rl_controller.gd
# ─────────────────────────────────────────────────────────────────────────────
# SETUP (do once before first training run):
#   1. Install Godot RL Agents via the Asset Library.
#   2. Change line below:  extends Node  →  extends AIController2D
#   3. Add a Sync node (from plugin) as direct child of the Table scene root.
#   4. Export game as Linux binary, run train_rl.py.
#
# OBSERVATION — 73 floats (fixed for V0 through V3; unused slots are 0.0)
#   [0,1]    cue ball x,y
#   [2–31]   15 red ball positions x,y  (0,0 if potted)
#   [32–43]  6 colour ball positions x,y (0,0 if potted)
#   [44–55]  6 pocket positions x,y  (fixed)
#   [56]     phase: 0=must pot red  1=must pot colour
#   [57]     reds remaining / 15
#   [58]     episode score / 147
#   [59]     rl_version / 5
#   [60]     must_pot_colour flag
#   [61,62]  cue ball velocity x,y  (normalised)
#   [63]     distance cue → nearest legal ball  (normalised)
#   [64,65]  nearest legal ball x,y
#   [66]     step fraction  (step_count / max_steps)
#   [67,68]  aim direction unit vector cue → nearest ball  (ghost-ball aim)
#   [69]     ghost-ball alignment dot product (cue→ball)·(ball→nearest pocket)
#   [70–72]  reserved (0.0)
#
# ACTION — 4 continuous values  (always 4; spin ignored in V0-V2)
#   [0]  aim_offset  -1..+1  →  ±AIM_RANGE around the cue→nearest-ball direction
#                              (0 = straight at the ball; agent learns the cut)
#   [1]  shot_force  -1..+1  →   0..MAX_IMPULSE
#   [2]  spin_x      -1..+1  →  side-spin  (active in V3+)
#   [3]  spin_y      -1..+1  →  top/back   (active in V3+)
# ─────────────────────────────────────────────────────────────────────────────
extends AIController2D

const OBS_SIZE: int = 73

# Shot aim is RELATIVE to the cue→nearest-ball direction, within ±AIM_RANGE, rather
# than an absolute compass heading. Absolute aiming mapped action[0]∈[-1,1] onto the
# full 360° circle, so the policy's own exploration noise (std≈0.32 → ±58°) dwarfed
# the ~5° precision a pot needs — the potting signal drowned in aim scatter and no
# reward change (trainings 13-17) could rescue it. Anchoring on the ball guarantees
# contact and cuts the scatter to ±19°; at curriculum 0 (red on the cue→pocket line)
# the optimal action is simply 0, making the first pots trivially learnable.
const AIM_RANGE: float = PI / 3.0   # ±60°: covers every realistic cut with margin

# Base aim angle (cue → nearest legal ball), cached each get_obs so set_action reuses
# exactly the direction the observation encoded in obs[67,68].
var _aim_base_angle: float = 0.0

# Total step-cost budget spread across a full episode, so EVERY version keeps the
# same ~-10/episode passivity pressure regardless of length (per-shot cost is
# EP_STEP_BUDGET / max_steps, computed in set_action). A flat per-shot cost was the
# trap that stalled V1: -0.05 was calibrated for V0's 200-step episodes but bled
# -100 over V1's 2000-step episodes, capping reward and flattening the gradient.
# -10/ep makes passivity strictly losing (worse than any honest pot) at every level.
const EP_STEP_BUDGET: float = -10.0

var _table: Node = null


func _ready() -> void:
	super._ready()  # adds this node to the "AGENT" group so Sync can find it
	process_mode = Node.PROCESS_MODE_ALWAYS
	_table = get_parent()
	# Do NOT set is_rl_mode here — the script exists on disk even during normal
	# play. is_rl_mode is set only when Sync actually connects and calls
	# set_heuristic("model"), so the career/drill modes are unaffected.

func set_heuristic(h: String) -> void:
	super.set_heuristic(h)
	if _table != null:
		# "model" = SB3 training,  "onnx" = inference — both are RL modes.
		# "human" = editor play without Python — leave normal game alone.
		_table.is_rl_mode = h in ["model", "onnx"]

func _physics_process(_delta: float) -> void:
	if needs_reset:
		reset()


# ═════════════════════════════════════════════════════════════════════════════
# OBSERVATION
# ═════════════════════════════════════════════════════════════════════════════
func get_obs() -> Dictionary:
	var obs: Array[float] = []
	if _table == null:
		for _i in range(OBS_SIZE): obs.append(0.0)
		return {"obs": obs}

	var W := Globals.TABLE_W
	var H := Globals.TABLE_H
	var data: Dictionary = _table.get_rl_observation_data()

	# [0,1] Cue ball
	var cue_pos := data.get("cue_pos", Vector2.ZERO) as Vector2
	obs.append(cue_pos.x / W)
	obs.append(cue_pos.y / H)

	# [2–31] 15 red ball positions
	var reds := data.get("red_positions", []) as Array
	for i in range(15):
		if i < reds.size():
			var p := reds[i] as Vector2
			obs.append(p.x / W); obs.append(p.y / H)
		else:
			obs.append(0.0); obs.append(0.0)

	# [32–43] 6 colour ball positions
	var colours := data.get("colour_positions", []) as Array
	for i in range(6):
		if i < colours.size():
			var p := colours[i] as Vector2
			obs.append(p.x / W); obs.append(p.y / H)
		else:
			obs.append(0.0); obs.append(0.0)

	# [44–55] 6 pocket positions (fixed)
	for pocket: Vector2 in Globals.POCKET_POSITIONS:
		obs.append(pocket.x / W); obs.append(pocket.y / H)

	# [56] Phase
	obs.append(float(data.get("phase", 0)))

	# [57] Reds remaining normalised
	obs.append(float(data.get("reds_remaining", 0)) / 15.0)

	# [58] Episode score normalised (max 147)
	obs.append(clamp(float(data.get("episode_score", 0)) / 147.0, 0.0, 1.0))

	# [59] Current RL version normalised
	obs.append(float(Globals.rl_version) / 5.0)

	# [60] Must-pot-colour flag
	obs.append(1.0 if data.get("must_pot_colour", false) else 0.0)

	# [61,62] Cue ball velocity (normalised by MAX_IMPULSE)
	var vel := data.get("cue_vel", Vector2.ZERO) as Vector2
	obs.append(clamp(vel.x / Globals.MAX_IMPULSE, -1.0, 1.0))
	obs.append(clamp(vel.y / Globals.MAX_IMPULSE, -1.0, 1.0))

	# [63] Distance to nearest legal ball
	var nearest := _nearest_legal_pos(data, cue_pos)
	obs.append(clamp(cue_pos.distance_to(nearest) / W, 0.0, 1.0))

	# [64,65] Nearest legal ball position
	obs.append(nearest.x / W); obs.append(nearest.y / H)

	# [66] Step fraction
	var max_steps := _max_steps()
	obs.append(clamp(float(data.get("step_count", 0)) / float(max_steps), 0.0, 1.0))

	# [67,68] Aim direction: cue → nearest legal ball (unit vector).
	# Tells the agent which way to shoot to HIT the ball.
	var aim_dir := (nearest - cue_pos).normalized() if cue_pos.distance_to(nearest) > 1.0 else Vector2.ZERO
	obs.append(aim_dir.x); obs.append(aim_dir.y)
	# Cache the base heading so set_action can aim relative to it (see AIM_RANGE).
	if aim_dir != Vector2.ZERO:
		_aim_base_angle = aim_dir.angle()

	# [69] Ghost-ball alignment: dot product of (cue→ball) and (ball→nearest pocket).
	# +1.0 = perfectly aligned (pot guaranteed if aimed right), 0 = 90°, -1 = facing away.
	# Teaches the agent the geometry of a potting shot without explicit reward hacking.
	var nearest_pocket := _nearest_pocket(nearest)
	var ball_to_pocket := (nearest_pocket - nearest).normalized()
	obs.append(aim_dir.dot(ball_to_pocket))

	# [70,71,72] Reserved
	obs.append(0.0); obs.append(0.0); obs.append(0.0)

	return {"obs": obs}


func _nearest_legal_pos(data: Dictionary, cue_pos: Vector2) -> Vector2:
	var must_colour := data.get("must_pot_colour", false) as bool
	var pool: Array
	if must_colour:
		pool = data.get("colour_positions", []) as Array
	else:
		pool = data.get("red_positions", []) as Array
	if pool.is_empty():
		pool = data.get("colour_positions", []) as Array
	if pool.is_empty():
		return cue_pos
	var best := pool[0] as Vector2
	var bd   := cue_pos.distance_to(best)
	for item in pool:
		var p := item as Vector2
		var d := cue_pos.distance_to(p)
		if d < bd: bd = d; best = p
	return best


func _nearest_pocket(ball_pos: Vector2) -> Vector2:
	var best := Globals.POCKET_POSITIONS[0]
	var bd   := ball_pos.distance_to(best)
	for p: Vector2 in Globals.POCKET_POSITIONS:
		var d := ball_pos.distance_to(p)
		if d < bd: bd = d; best = p
	return best


func get_obs_size() -> int:
	return OBS_SIZE


# ═════════════════════════════════════════════════════════════════════════════
# ACTION SPACE — always 4 actions so weights transfer across all versions
# ═════════════════════════════════════════════════════════════════════════════
func get_action_space() -> Dictionary:
	return {"shoot": {"size": 4, "action_type": "continuous"}}


func set_action(action: Dictionary) -> void:
	if _table == null: return
	if _table.waiting_for_ball_stop or _table._turn_resolving: return

	var raw: Array = action.get("shoot", [0.0, 0.0, 0.0, 0.0])
	var a:  float = clamp(float(raw[0]) if raw.size() > 0 else 0.0, -1.0, 1.0)
	var f:  float = clamp(float(raw[1]) if raw.size() > 1 else 0.0, -1.0, 1.0)
	var sx: float = clamp(float(raw[2]) if raw.size() > 2 else 0.0, -1.0, 1.0)
	var sy: float = clamp(float(raw[3]) if raw.size() > 3 else 0.0, -1.0, 1.0)

	var angle: float   = _aim_base_angle + a * AIM_RANGE
	var force: float   = (f + 1.0) * 0.5 * Globals.MAX_IMPULSE
	var dir:   Vector2 = Vector2(cos(angle), sin(angle))

	# Spin actions only take effect in V3+
	var offset := Vector2(sx, sy) if Globals.rl_version >= 3 else Vector2.ZERO

	_table.execute_agent_shot(dir * force, offset)
	n_steps += 1
	reward  += EP_STEP_BUDGET / float(_max_steps())


# ═════════════════════════════════════════════════════════════════════════════
# REWARD / DONE / RESET
# ═════════════════════════════════════════════════════════════════════════════
func get_reward() -> float:
	return reward

func get_done() -> bool:
	if _table == null: return false
	return _table.get_game_result().get("is_over", false)

func set_done_false() -> void:
	# SB3 never sends a "reset" message — it auto-resets internally and sends
	# the next episode's first action directly.  set_done_false() is the hook
	# sync.gd calls right after reading done=true, so we do the game reset here.
	super.set_done_false()
	if _table != null:
		_table.reset_game()

func reset() -> void:
	super.reset()
	if _table != null and _table.has_method("reset_game"):
		_table.reset_game()

func add_reward(amount: float) -> void:
	reward += amount


# ═════════════════════════════════════════════════════════════════════════════
# INFO — passed back to Python CurriculumCallback every episode
# ═════════════════════════════════════════════════════════════════════════════
func get_info() -> Dictionary:
	if _table == null: return {}
	var data: Dictionary = _table.get_rl_observation_data()
	return {
		"reds_potted":   data.get("reds_potted",   0),
		"episode_score": data.get("episode_score", 0),
		"rl_version":    Globals.rl_version,
		# Reverse-curriculum difficulty (0=red spawns at pocket, 1=fully random).
		# Python gates V0 graduation on this so easy-placement pots can't graduate.
		"curriculum":    data.get("curriculum", 1.0),
	}


# ═════════════════════════════════════════════════════════════════════════════
# Helpers
# ═════════════════════════════════════════════════════════════════════════════
func _max_steps() -> int:
	match Globals.rl_version:
		0: return Globals.V0_MAX_STEPS
		1: return Globals.V1_MAX_STEPS
		2: return Globals.V2_MAX_STEPS
		_: return Globals.V3_MAX_STEPS
