# res://scripts/table.gd
# Attach to root node of res://scenes/table.tscn
extends Node2D

# ── Cue ball ──────────────────────────────────────────────────────────────────
@onready var cue_ball: RigidBody2D = $ball_1

# ── Turn / input state ────────────────────────────────────────────────────────
var _aim_line: Line2D = null        # cue → contact (trajectory preview)
var _obj_line: Line2D = null        # predicted object-ball path (aim preview)
var _cue_after_line: Line2D = null  # predicted cue deflection after contact
var waiting_for_ball_stop: bool = false
var _player_turn: bool = true
# Phase of the CURRENT striker (whoever is at the table): true = a colour is owed after
# potting a red. Reset whenever the turn changes, so it always describes the player to play.
var _must_pot_colour: bool = false
var _ball_potted_this_turn: bool = false
# Colour of the FIRST object ball the cue struck this shot ("" = nothing hit). Reset on
# every shot; read at turn resolution to enforce the "hit the ball on first" foul.
var _first_hit_colour: String = ""
# Foul state, resolved once every ball has settled (never mid-shot). Covers BOTH the
# cue-ball in-off and potting the wrong ball; _foul_points carries the penalty, which
# snooker sets at max(4, value of the ball involved).
var _foul_pending: bool = false
var _foul_points: int = 4
var _foul_respot_cue: bool = false
var _ai_shot_timer: float = 0.0
var _ai_shot_pending: bool = false
var _turn_resolving: bool = false
var _shot_settle_counter: int = 0
const SETTLE_FRAMES: int = 4
var _wait_ticks: int = 0                 # frames spent waiting for balls to stop
const MAX_WAIT_TICKS: int = 600          # ~5 s cap so a jittering ball can't hang the turn
# Bumped by reset_game(). The turn resolution AWAITS a 1 s timer mid-function; if the
# frame is reset during that wait, the coroutine would resume and apply the old turn's
# switch logic to a brand-new frame (e.g. handing the break straight to the AI). It
# captures this counter before the await and bails out if it changed.
var _turn_generation: int = 0

# ── XP / progression ──────────────────────────────────────────────────────────
# The HUD shows XP and a rank bar, and Globals has a ladder up to 15000 — but NOTHING
# in the main game ever called Globals.add_xp(): only drills.gd and challenge.gd did.
# So career play showed "XP: 0 / Amateur I" forever and the whole gamification layer was
# inert in the mode people actually play. The striker earns XP for what they pot, plus a
# bonus for taking the frame. Tune these two numbers to change progression pace.
const XP_PER_POINT: int = 10     # a red = 10 XP, a black = 70 XP
const XP_FRAME_WIN: int = 250    # bonus for winning the frame (~1000 XP per frame won)

# The six colours in ascending value — the order they must be taken in once the reds
# are gone. Single source of truth for "is this ball a colour?" and for the endgame
# sequence, shared by the human rules and the RL rules.
const COLOUR_ORDER: Array[String] = ["yellow", "green", "brown", "blue", "pink", "black"]

# ── Play-area geometry (ball-CENTRE limits inside the real cushions) ──────────
# Walls sit at 0/1280/720; ball radius 22 + cushion face → these bounds. Used by the
# trajectory tracer AND by respot placement, so both agree on what "on the table" means.
const CUSHION_LO_X: float = 47.0
const CUSHION_LO_Y: float = 47.0
const CUSHION_HI_X: float = 1233.0
const CUSHION_HI_Y: float = 673.0
# A respotted ball's centre must be at least this far from every pocket centre.
# pocket radius 28 + ball radius 22 + margin. Without this, the old code CLAMPED
# candidates to 47,47 — only 17 px from the corner pocket at (35,35), i.e. INSIDE the
# 28 px mouth — so a respotted colour was dropped into the pocket and fell straight in.
const RESPOT_POCKET_CLEAR: float = 62.0
# True out-of-bounds test. The scene's walls are at x 0/1280 and y 0/720, and the cushions
# cap a LEGAL resting centre at CUSHION_HI_X/Y (1233/673) — so a centre outside the wall
# box can only mean the ball tunnelled through a cushion.
# NB: Globals.TABLE_W/TABLE_H (1220/685) are NORMALISATION constants, NOT bounds. Using
# them here (as this code used to) declared any ball resting between x=1220 and the right
# cushion at x=1233 "off the table" and teleported it — a false respot on the right rail,
# and in RL a phantom -0.5 penalty for a perfectly legal resting place.
const OOB_MIN_X: float = 0.0
const OOB_MAX_X: float = 1280.0
const OOB_MIN_Y: float = 0.0
const OOB_MAX_Y: float = 720.0

func _is_off_table(p: Vector2) -> bool:
	return p.x < OOB_MIN_X or p.x > OOB_MAX_X or p.y < OOB_MIN_Y or p.y > OOB_MAX_Y


# Progress-shaping weight (RL): reward per shot for the red moving TOWARD a pocket,
# SHAPE_W * max(0, dist_before - dist_after) / TABLE_W — ONE-SIDED by design, so an
# attempt is never punished and the only way to farm it is to keep pushing reds at
# pockets, which IS potting practice.
const SHAPE_W: float = 3.0

# ── Spin ─────────────────────────────────────────────────────────────────────
var spin_offset: Vector2 = Vector2.ZERO         # applied spin: y>0 = follow, y<0 = draw
var current_vertical_spin: float = 0.0
var last_shot_strength: float = 0.0

# ── Human interaction layer (decoupled aim / power / spin) ────────────────────
# AIM comes from the mouse hover (cue → cursor). POWER is a SEPARATE 0-1 value set by the
# gauge, the mouse wheel, OR by pulling the cue stick back — never welded to the aim
# gesture. A press LOCKS the aim, dragging backward loads power, release fires (or, if you
# barely pulled, cancels — so a stray click never shoots).
var _ui_enabled: bool = false
var _power_frac: float = 0.35            # chosen shot power 0-1 (independent of aim)
var _aim_dir: Vector2 = Vector2.RIGHT    # current aim (unit), from hover or locked
var _aiming_locked: bool = false         # true while pulling the cue back
# Persistent aim LOCK (distinct from the transient pull-back above): when true, moving
# the mouse no longer re-aims, so the player can freeze the shot line + its predicted
# trajectory and then set power/spin in peace. Toggled by the band button or right-click.
var _aim_hold_locked: bool = false
var _pull_press_along: float = 0.0       # cue-axis projection at press (for pull power)
var _active_pull: float = 0.0            # px pulled back this stroke
var _cue_in_hand: bool = false           # ball-in-hand placement mode
var _last_rec: Dictionary = {}           # latest full recommendation (for Play AI Shot)
var _band: Node = null                   # control_band.gd instance
var _cue_stick: Node2D = null            # pull-back cue-stick visual
const MAX_DRAW_PULL: float = 300.0       # px of backward drag = 100 % power
const MIN_PULL_TO_FIRE: float = 12.0     # shorter pull on release = cancel, not shot
const MAX_TRAVEL: float = 2000.0         # px the cue could roll at full power (preview)
const CONTROLS_HINT: String = "Aim: mouse   •   Right-click / Aim Lock: freeze aim   •   R: line up the AI shot   •   Power: scroll / drag / pull back   •   Space: shoot   •   Esc: pause"

# ── Child nodes ───────────────────────────────────────────────────────────────
var _api_bridge: Node = null
var _overlay: Node = null
var _career: Node = null
var _rl_controller: Node = null

# ── Ball state ────────────────────────────────────────────────────────────────
var _potted_balls: Array = []
# Colours potted while reds remain are RESPOTTED (real snooker) instead of removed.
# Disabled on pot, then put back on their spots once the shot settles.
var _colours_to_respot: Array[RigidBody2D] = []
# Frames-remaining during which a just-respotted ball is immune to pocket scoring.
# Guards the re-enable race: toggling process_mode on a body that was potted inside a
# pocket area can make Godot emit a spurious body_entered on the NEXT step, before the
# teleport-to-spot is seen — which re-scored a colour every frame (the 39075 runaway).
var _respot_guard: Dictionary = {}
const RESPOT_GUARD_FRAMES: int = 20

var _cue_ball_start_pos: Vector2 = Vector2(245.0, 360.0)
var _initial_ball_data: Array = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# ── RL mode and episode state ─────────────────────────────────────────────────
var is_rl_mode: bool = false
var _rl_must_pot_colour: bool = false
var _rl_reds_potted: int = 0
var _rl_episode_score: int = 0
var _rl_step_count: int = 0
var _rl_episode_done: bool = false
# Pending RL respawns — set from body_entered signals, applied in _physics_process
# (freeze=true is illegal during the physics server's flush-queries phase)
var _rl_cue_foul_pending: bool = false
var _rl_balls_to_respawn: Array[RigidBody2D] = []
var _rl_pre_shot_red_pocket_dist: float = -1.0
var _rl_cue_hit_red_this_turn: bool = false
var _rl_cue_fouled_this_turn: bool = false

# ── Reverse curriculum (V0) ────────────────────────────────────────────────────
# Red-placement difficulty, 0.0 (red hugs a pocket on the cue→pocket line — a
# near-guaranteed straight-stun pot) → 1.0 (fully random, the real task). Adapts to
# the agent's own success (see reset_game) so it stays in the zone where it can
# actually learn to pot, then graduates toward the real task. Reward shaping alone
# could not cross the skill gap (training15/16: pot rate decayed at EVERY SHAPE_W,
# because two-sided shaping punishes the exploration of an agent that can't yet
# pot); the agent must first EXPERIENCE frequent pots to learn the geometry.
var _curriculum_level: float = 0.0

# ── Shot-data simulation mode ───────────────────────────────────────────────────
# The headless recommendation-model data generator lives in its own script,
# sim_generator.gd — it's OFFLINE tooling (launched with --sim-shots=N) that has
# nothing to do with the game you play. table.gd only keeps the mode flag and a
# reference, and forwards three hooks (process / pocket / cue-hit) to it below.
var is_sim_mode: bool = false
var _sim: Node = null             # sim_generator.gd instance (only in --sim-shots runs)

# ── Drill mode ─────────────────────────────────────────────────────────────────
# Single-shot practice launched from drills.gd (Globals.active_drill >= 0). The rack
# is replaced with just the cue + one red at a fixed scenario; potting the red scores
# XP + streak, missing (or potting the cue) fails; a result panel offers Retry / Next
# / Menu. Never runs in RL or sim mode, and guarded so Career play is untouched.
var is_drill_mode: bool = false
var _drill_red_potted: bool = false
var _drill_cue_potted: bool = false
var _drill_streak: int = 0
var _drill_awaiting_choice: bool = false          # result panel up — block shooting
var _drill_hud: CanvasLayer = null
var _drill_title_lbl: Label = null
var _drill_hint_lbl: Label = null
var _drill_status_lbl: Label = null
var _drill_result_panel: Control = null

# ── Sandbox free-play mode ──────────────────────────────────────────────────────
# Solo practice table: full physics + live recommendations, but no AI, no turn loss,
# and no frame end. Right-drag repositions any ball. Launched from the menu.
var is_sandbox_mode: bool = false
var _sandbox_drag_ball: RigidBody2D = null

# ── In-game settings overlay ────────────────────────────────────────────────────
# Lets the player change settings WITHOUT leaving the match (state is preserved).
var _paused: bool = false
var _pause_layer: CanvasLayer = null

# True for normal windowed play (false for headless training/sim). Used to re-assert
# real-time speed against the godot_rl Sync node, which forces its RL speedup on load.
var _is_windowed: bool = false


# ═════════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	# The godot_rl Sync node in this scene (required for RL training) applies its
	# speedup on load — Engine.time_scale + physics tick — EVEN in normal windowed
	# play. With no --speedup arg it defaults to 16×, so the human game ran at 16×
	# time-scale / 960 Hz and stuttered badly. The Sync sets this AFTER our _ready
	# (it awaits the parent's ready), so we also re-assert it in _physics_process.
	_is_windowed = DisplayServer.get_name() != "headless"
	if _is_windowed:
		Engine.time_scale = 1.0
		Engine.physics_ticks_per_second = 120

	_cue_ball_start_pos = cue_ball.global_position
	_tag_balls()
	_frame_table()

	for ball_node: RigidBody2D in _get_table_balls():
		_initial_ball_data.append({
			"name": ball_node.name,
			"pos": ball_node.global_position,
		})

	var wall_mat := PhysicsMaterial.new()
	wall_mat.friction = 0.0
	wall_mat.bounce = 0.8
	for wn: String in ["TopWall", "BottomWall", "LeftWall", "RightWall"]:
		var w: Node = get_node_or_null(wn)
		if w != null: w.physics_material_override = wall_mat

	var ball_mat := PhysicsMaterial.new()
	ball_mat.friction = Globals.BALL_FRICTION
	ball_mat.bounce = Globals.BALL_BOUNCE
	for ball_node: RigidBody2D in _get_table_balls():
		ball_node.physics_material_override = ball_mat
		ball_node.linear_damp = Globals.BALL_LINEAR_DAMP
		ball_node.angular_damp = Globals.BALL_ANGULAR_DAMP
		ball_node.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

		var collision_shape: CollisionShape2D = ball_node.get_node_or_null("CollisionShape2D")
		if collision_shape != null:
			collision_shape.scale = Vector2(1.0, 1.0)
			# Replace the shared scene shape with a per-ball instance at radius 22.
			# The scene default (radius=16) only catches perpendicular-miss < 32 px;
			# at max shot speed (67 px/step) glancing hits fall through.
			# Radius 22 raises the catch threshold to 44 px — enough for thin cuts.
			var new_shape := CircleShape2D.new()
			new_shape.radius = 22.0
			collision_shape.shape = new_shape

	for pos: Vector2 in Globals.POCKET_POSITIONS:
		var area := Area2D.new()
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = Globals.POCKET_RADIUS
		shape.shape = circle
		area.add_child(shape)
		area.position = pos
		area.body_entered.connect(_on_pocket_entered)
		add_child(area)

	var pockets_node := PocketDrawer.new()
	pockets_node.name = "Pockets"
	add_child(pockets_node)

	cue_ball.body_entered.connect(_on_cue_ball_collision)

	_api_bridge = preload("res://scripts/api_bridge.gd").new()
	_api_bridge.name = "ApiBridge"
	_api_bridge.recommendation_ready.connect(_on_recommendation_ready)
	_api_bridge.recommendation_failed.connect(_on_recommendation_failed)
	add_child(_api_bridge)

	_overlay = preload("res://scripts/overlay.gd").new()
	_overlay.name = "Overlay"
	add_child(_overlay)

	_career = preload("res://scripts/career.gd").new()
	_career.name = "Career"
	add_child(_career)

	var rl_path := "res://scripts/rl_controller.gd"
	if ResourceLoader.exists(rl_path):
		var rl_script: GDScript = load(rl_path)
		if rl_script != null:
			_rl_controller = rl_script.new()
			_rl_controller.name = "RLController"
			add_child(_rl_controller)

	# Shot-data simulation (offline model tooling) lives in its own script. Create it,
	# let it decide from the command line whether this is a --sim-shots run.
	_sim = preload("res://scripts/sim_generator.gd").new()
	_sim.name = "SimGenerator"
	_sim.t = self
	add_child(_sim)
	if _sim.start_if_requested():
		return
	_sim.queue_free(); _sim = null   # not a sim run — drop the helper
	# Drill mode: launched from drills.gd via Globals.active_drill. Never in RL/sim.
	is_drill_mode = (not is_rl_mode) and Globals.active_drill >= 0 \
		and Globals.active_drill < Globals.DRILL_SETUPS.size()
	# Sandbox free-play: launched from the menu. Mutually exclusive with drill mode.
	is_sandbox_mode = (not is_rl_mode) and Globals.sandbox_mode and not is_drill_mode
	# Every pre-existing HUD Control becomes click-transparent so the ONLY things
	# that consume mouse input are the felt (aim/shoot) and the control band. Fixes
	# "clicking anywhere fires a shot" AND "clicking a panel fires a shot".
	_set_ignore_recursive(self)
	if DisplayServer.get_name() != "headless":
		_build_player_ui()
	# Build mode HUDs AFTER _set_ignore_recursive so their buttons stay clickable.
	if is_drill_mode:
		_build_drill_hud()
		_setup_drill()
	elif is_sandbox_mode:
		_build_sandbox_hud()
		_setup_sandbox()
	elif Globals.career_resume and Globals.has_career_save():
		# Resume the exact frame the player left (ball layout, scores, whose turn).
		_restore_career_state(Globals.load_career())
	Globals.career_resume = false
	_request_ml_recommendation()


# The felt used to fill the whole 1280×720 window while the cushions/pockets sit at
# ~1255/695 — so a strip of green showed BEYOND the pockets and the pockets looked
# like they floated inside the table. Shrink the felt to the real play area (the wall
# faces) and put a rail frame behind, so the pockets sit at the boundary/corners.
func _frame_table() -> void:
	var rail := ColorRect.new()
	rail.name = "Rail"
	rail.color = Color(0.20, 0.12, 0.06, 1.0)      # dark wood frame
	rail.offset_right = 1280.0
	rail.offset_bottom = 720.0
	rail.z_index = -2
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rail)
	var felt: ColorRect = get_node_or_null("Felt") as ColorRect
	if felt != null:
		felt.offset_left = 25.0
		felt.offset_top = 25.0
		felt.offset_right = 1255.0
		felt.offset_bottom = 695.0


func _set_ignore_recursive(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Node in n.get_children():
		_set_ignore_recursive(c)


# ═════════════════════════════════════════════════════════════════════════════
# Ball tagging and iteration
# ═════════════════════════════════════════════════════════════════════════════
func _tag_balls() -> void:
	for ball_node: RigidBody2D in _get_table_balls():
		var sprite: Node = ball_node.get_node_or_null("Sprite2D")
		if sprite == null or sprite.texture == null:
			ball_node.set_meta("ball_colour", "unknown"); continue
		var path: String = sprite.texture.resource_path.to_lower()
		if "white" in path: ball_node.set_meta("ball_colour", "cue")
		elif "red" in path: ball_node.set_meta("ball_colour", "red")
		elif "yellow" in path: ball_node.set_meta("ball_colour", "yellow")
		elif "green" in path: ball_node.set_meta("ball_colour", "green")
		elif "brown" in path: ball_node.set_meta("ball_colour", "brown")
		elif "blue" in path: ball_node.set_meta("ball_colour", "blue")
		elif "pink" in path: ball_node.set_meta("ball_colour", "pink")
		elif "black" in path: ball_node.set_meta("ball_colour", "black")
		else: ball_node.set_meta("ball_colour", "unknown")

# active_only=true skips PROCESS_MODE_DISABLED (potted) balls
func _get_table_balls(active_only: bool = false) -> Array:
	var out: Array = []
	for child in get_children():
		if not (child is RigidBody2D): continue
		if child.is_queued_for_deletion(): continue
		if active_only and child.process_mode == Node.PROCESS_MODE_DISABLED: continue
		out.append(child)
	return out

func _find_nearest_red_ball_position(from_pos: Vector2) -> Vector2:
	var nearest := from_pos
	var nd := INF
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		if ball.get_meta("ball_colour", "") != "red": continue
		var d := from_pos.distance_to(ball.global_position)
		if d < nd: nd = d; nearest = ball.global_position
	return nearest

func _find_nearest_colour_ball_position(from_pos: Vector2) -> Vector2:
	var nearest := from_pos
	var nd := INF
	var clist := ["yellow", "green", "brown", "blue", "pink", "black"]
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		if ball.get_meta("ball_colour", "") in clist:
			var d := from_pos.distance_to(ball.global_position)
			if d < nd: nd = d; nearest = ball.global_position
	return nearest

func _find_nearest_legal_ball_position(from_pos: Vector2) -> Vector2:
	if Globals.rl_version < 2:
		return _find_nearest_red_ball_position(from_pos)
	if _rl_must_pot_colour:
		return _find_nearest_colour_ball_position(from_pos)
	return _find_nearest_red_ball_position(from_pos)

func _active_ball_of_colour(cname: String) -> RigidBody2D:
	for ball: RigidBody2D in _get_table_balls(true):
		if str(ball.get_meta("ball_colour", "")) == cname: return ball
	return null


# The ball the CURRENT striker is legally on — used by the AI opponent so it doesn't
# hammer a red while it owes a colour (which is now a foul) or stand idle in the endgame.
# Mirrors _is_legal_pot exactly. Returns from_pos when there is nothing legal to hit.
func _legal_target_position(from_pos: Vector2) -> Vector2:
	if _count_active_reds() > 0:
		if _must_pot_colour:
			return _find_nearest_colour_ball_position(from_pos)
		return _find_nearest_red_ball_position(from_pos)
	var req := _required_colour()
	if req == "": return from_pos
	var b := _active_ball_of_colour(req)
	return b.global_position if b != null else from_pos


func _count_active_reds() -> int:
	var n := 0
	for ball: RigidBody2D in _get_table_balls(true):
		if ball.get_meta("ball_colour", "") == "red": n += 1
	return n

func _count_active_colours() -> int:
	var n := 0
	var clist := ["yellow", "green", "brown", "blue", "pink", "black"]
	for ball: RigidBody2D in _get_table_balls(true):
		if ball.get_meta("ball_colour", "") in clist: n += 1
	return n


# ═════════════════════════════════════════════════════════════════════════════
# RL config file (Python writes this to upgrade version)
# ═════════════════════════════════════════════════════════════════════════════
func _load_rl_config() -> void:
	var exe := OS.get_executable_path()
	var config_path: String
	if exe.is_empty():
		config_path = OS.get_user_data_dir() + "/rl_config.json"
	else:
		config_path = exe.get_base_dir() + "/rl_config.json"
	if not FileAccess.file_exists(config_path):
		return
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null: return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(data) == TYPE_DICTIONARY and data.has("rl_version"):
		Globals.rl_version = int(data["rl_version"])


# ═════════════════════════════════════════════════════════════════════════════
# Episode setup — randomises ball placement per version
# ═════════════════════════════════════════════════════════════════════════════
func _setup_episode() -> void:
	_load_rl_config()
	_rng.randomize()

	# Restore all balls: enable FIRST, then freeze→reposition→unfreeze so the
	# physics body moves to the new position before the engine can detect any
	# lingering pocket overlap from the previous episode.
	for bd: Dictionary in _initial_ball_data:
		var bn: RigidBody2D = get_node_or_null(NodePath(str(bd["name"]))) as RigidBody2D
		if bn == null or not is_instance_valid(bn): continue
		bn.process_mode = Node.PROCESS_MODE_INHERIT
		bn.show()
		bn.freeze = true
		bn.global_position = bd["pos"] as Vector2
		bn.linear_velocity = Vector2.ZERO
		bn.angular_velocity = 0.0
		bn.freeze = false

	match Globals.rl_version:
		0: _setup_v0()
		1: _setup_v1()
		_: _setup_v2_plus()

func _setup_v0() -> void:
	_place_cue_ball_in_d()
	var first_red: RigidBody2D = null
	for ball: RigidBody2D in _get_table_balls():
		if ball.get_meta("ball_colour", "") == "red": first_red = ball; break
	if first_red != null:
		_place_red_curriculum(first_red)
	for ball: RigidBody2D in _get_table_balls():
		if ball == cue_ball or ball == first_red: continue
		ball.process_mode = Node.PROCESS_MODE_DISABLED
		ball.hide()

func _setup_v1() -> void:
	_place_cue_ball_in_d()
	var occupied: Array[Vector2] = [cue_ball.global_position]
	for ball: RigidBody2D in _get_table_balls():
		var colour: String = ball.get_meta("ball_colour", "")
		if colour == "red":
			_place_ball_no_overlap(ball, occupied, 50.0)
			occupied.append(ball.global_position)
		elif colour != "cue":
			ball.process_mode = Node.PROCESS_MODE_DISABLED
			ball.hide()

func _setup_v2_plus() -> void:
	# Full snooker rack — balls already at initial positions
	_place_cue_ball_in_d()

func _place_cue_ball_in_d() -> void:
	var angle := _rng.randf() * PI
	var r := _rng.randf() * Globals.D_RADIUS * 0.85
	var center := Vector2(Globals.BAULK_X - r * 0.5, Globals.D_CENTER_Y)
	cue_ball.freeze = true
	cue_ball.global_position = center + Vector2(-cos(angle), sin(angle)) * r
	cue_ball.linear_velocity = Vector2.ZERO
	cue_ball.angular_velocity = 0.0
	cue_ball.freeze = false

func _place_ball_random_right_half(ball: RigidBody2D, avoid: Vector2, min_dist: float) -> void:
	var pos := Vector2(Globals.TABLE_W * 0.75, Globals.TABLE_H * 0.5)
	for _i in range(100):
		var x := _rng.randf_range(Globals.TABLE_W * 0.35, Globals.TABLE_W - 60.0)
		var y := _rng.randf_range(60.0, Globals.TABLE_H - 60.0)
		var candidate := Vector2(x, y)
		if candidate.distance_to(avoid) >= min_dist:
			pos = candidate; break
	ball.freeze = true
	ball.global_position = pos
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.freeze = false

# Reverse-curriculum red placement. At level 0 the red sits just in front of a
# pocket, directly on the cue→pocket line — a near-guaranteed straight-stun pot
# (equal-mass head-on collision stops the cue dead, so no in-off foul), teaching the
# potting motion. As _curriculum_level rises the red is set farther back from the
# pocket and offset sideways (forcing cut shots), converging to fully random
# placement at level 1 (the real V0 task, unchanged).
func _place_red_curriculum(ball: RigidBody2D) -> void:
	var cue_pos := cue_ball.global_position if is_instance_valid(cue_ball) else _cue_ball_start_pos
	var lvl := clampf(_curriculum_level, 0.0, 1.0)
	if lvl >= 0.999:
		_place_ball_random_right_half(ball, cue_pos, 200.0)
		return
	# Pick a pocket with enough room between it and the cue for a real shot.
	var target_pocket: Vector2 = Globals.POCKET_POSITIONS[0]
	var found := false
	for _try in range(16):
		var cand: Vector2 = Globals.POCKET_POSITIONS[_rng.randi() % Globals.POCKET_POSITIONS.size()]
		if cue_pos.distance_to(cand) > 300.0:
			target_pocket = cand; found = true; break
	if not found:
		for pk: Vector2 in Globals.POCKET_POSITIONS:
			if cue_pos.distance_to(pk) > cue_pos.distance_to(target_pocket): target_pocket = pk
	var dir := (target_pocket - cue_pos).normalized()
	# How far back from the pocket the red sits along the cue's line; grows with level.
	var back := lerpf(90.0, Globals.TABLE_W * 0.45, lvl)
	# Sideways offset forces cut shots as difficulty rises.
	var perp := Vector2(-dir.y, dir.x)
	var lateral := _rng.randf_range(-1.0, 1.0) * lerpf(0.0, 130.0, lvl)
	var pos := target_pocket - dir * back + perp * lateral
	pos.x = clamp(pos.x, 60.0, Globals.TABLE_W - 60.0)
	pos.y = clamp(pos.y, 60.0, Globals.TABLE_H - 60.0)
	# Never spawn on top of the cue ball.
	if pos.distance_to(cue_pos) < 160.0 and pos.distance_to(cue_pos) > 0.1:
		pos = cue_pos + (pos - cue_pos).normalized() * 160.0
		pos.x = clamp(pos.x, 60.0, Globals.TABLE_W - 60.0)
		pos.y = clamp(pos.y, 60.0, Globals.TABLE_H - 60.0)
	ball.freeze = true
	ball.global_position = pos
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.freeze = false


func _place_ball_no_overlap(ball: RigidBody2D, occupied: Array[Vector2], min_dist: float) -> void:
	var pos := Vector2(
		_rng.randf_range(200.0, Globals.TABLE_W - 100.0),
		_rng.randf_range(100.0, Globals.TABLE_H - 100.0))
	for _i in range(150):
		var x := _rng.randf_range(Globals.TABLE_W * 0.20, Globals.TABLE_W - 60.0)
		var y := _rng.randf_range(60.0, Globals.TABLE_H - 60.0)
		var candidate := Vector2(x, y)
		var ok := true
		for occ: Vector2 in occupied:
			if candidate.distance_to(occ) < min_dist: ok = false; break
		if ok: pos = candidate; break
	ball.freeze = true
	ball.global_position = pos
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.freeze = false


# ═════════════════════════════════════════════════════════════════════════════
# RL observation data — called by rl_controller.gd
# ═════════════════════════════════════════════════════════════════════════════
func get_rl_observation_data() -> Dictionary:
	var reds: Array[Vector2] = []
	var colours: Array[Vector2] = []
	var clist := ["yellow", "green", "brown", "blue", "pink", "black"]
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		var c: String = ball.get_meta("ball_colour", "")
		if c == "red": reds.append(ball.global_position)
		elif c in clist: colours.append(ball.global_position)
	return {
		"cue_pos": cue_ball.global_position if is_instance_valid(cue_ball) else Vector2.ZERO,
		"cue_vel": cue_ball.linear_velocity if is_instance_valid(cue_ball) else Vector2.ZERO,
		"red_positions": reds,
		"colour_positions": colours,
		"phase": 1 if _rl_must_pot_colour else 0,
		"reds_remaining": reds.size(),
		"episode_score": _rl_episode_score,
		"reds_potted": _rl_reds_potted,
		"must_pot_colour": _rl_must_pot_colour,
		"step_count": _rl_step_count,
		"episode_done": _rl_episode_done,
		"curriculum": _curriculum_level,
	}


# ═════════════════════════════════════════════════════════════════════════════
# RL interface
# ═════════════════════════════════════════════════════════════════════════════
func execute_agent_shot(impulse_vector: Vector2, offset: Vector2 = Vector2.ZERO) -> void:
	if waiting_for_ball_stop or _turn_resolving: return
	if not is_instance_valid(cue_ball): return
	_rl_cue_hit_red_this_turn = false
	_rl_cue_fouled_this_turn = false
	if Globals.rl_version == 0:
		_rl_pre_shot_red_pocket_dist = _nearest_red_pocket_dist()
	cue_ball.apply_impulse(impulse_vector, offset * 5.0)
	current_vertical_spin = offset.y
	last_shot_strength = impulse_vector.length()
	waiting_for_ball_stop = true
	_shot_settle_counter = SETTLE_FRAMES
	_ball_potted_this_turn = false
	_rl_step_count += 1
	if _rl_step_count >= _get_max_steps():
		_rl_episode_done = true
		print("[RL] ep done  steps=%d  reds=%d  score=%d  curr=%.2f" % [_rl_step_count, _rl_reds_potted, _rl_episode_score, _curriculum_level])

func _get_max_steps() -> int:
	match Globals.rl_version:
		0: return Globals.V0_MAX_STEPS
		1: return Globals.V1_MAX_STEPS
		2: return Globals.V2_MAX_STEPS
		_: return Globals.V3_MAX_STEPS

# Returns the minimum distance from any active red ball to any pocket.
# Returns -1.0 if no active red balls exist.
func _nearest_red_pocket_dist() -> float:
	var min_dist := INF
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		if ball.get_meta("ball_colour", "") != "red": continue
		for pocket: Vector2 in Globals.POCKET_POSITIONS:
			var d := ball.global_position.distance_to(pocket)
			if d < min_dist: min_dist = d
	return min_dist if min_dist < INF else -1.0


func get_game_result() -> Dictionary:
	if is_rl_mode:
		return {"is_over": _rl_episode_done, "winner": "", "reward": float(_rl_episode_score)}
	if _career == null:
		return {"is_over": false, "winner": "", "reward": 0}
	var winner: String = _career.check_frame_winner()
	return {"is_over": winner != "", "winner": winner,
			"reward": 100 if winner == "player" else (-100 if winner != "" else 0)}


# ═════════════════════════════════════════════════════════════════════════════
# Pocket entered
# ═════════════════════════════════════════════════════════════════════════════
func _on_pocket_entered(body: Node) -> void:
	if not body is RigidBody2D: return
	if is_sim_mode:
		_sim.on_pocket(body)
		return
	if is_drill_mode:
		_on_pocket_entered_drill(body as RigidBody2D)
		return
	if body == cue_ball: _handle_cue_ball_foul(); return
	if _potted_balls.has(body.name): return
	# A ball respotted within the last few frames cannot be scored again yet — blocks the
	# spurious re-enable body_entered that otherwise re-scored a colour every frame.
	if int(_respot_guard.get(body.name, 0)) > 0: return

	_potted_balls.append(body.name)
	_ball_potted_this_turn = true
	var colour: String = body.get_meta("ball_colour", "unknown")

	if is_rl_mode:
		# Legality and the respot decision must BOTH be read before the ball leaves play,
		# exactly like the human path below: _count_active_reds() and _required_colour()
		# have to see the pre-pot table or the endgame order can never be checked (the
		# ball just potted would already be gone, so it could never be "the one on").
		var rl_is_colour := colour in COLOUR_ORDER
		var rl_legal := _is_legal_pot(colour, rl_is_colour, _rl_must_pot_colour)
		var rl_reds_after := _count_active_reds() - (1 if colour == "red" else 0)
		# V0: respawn the red so the episode keeps running.
		# body.name stays in _potted_balls until _physics_process handles the respawn,
		# blocking any duplicate body_entered signal in the meantime.
		if Globals.rl_version == 0 and colour == "red":
			_rl_balls_to_respawn.append(body)
		else:
			# MUST disable before _apply_rl_pot_reward(): that call counts active
			# reds/colours via _count_active_reds()/_count_active_colours() to decide
			# episode-done. If disable happened after, the ball just potted still
			# counted as "active" during that check, so ar/ac never reached 0 on the
			# LAST ball — episode-done never fired and every V1+ episode silently
			# ran to the full step cap regardless of clearing the table (confirmed:
			# training19 showed reds=15 steps=400 on literally every V1 episode).
			body.hide()
			body.linear_velocity = Vector2.ZERO
			body.angular_velocity = 0.0
			body.process_mode = Node.PROCESS_MODE_DISABLED
			# V2+ plays REAL snooker, so a colour goes back on its spot while any red
			# remains. Without this the six colours were gone for good after six pots:
			# the striker was then owed a colour that no longer existed, every further
			# red pot fell through to the -0.3 illegal branch, and episode score was
			# hard-capped at 34 — against a graduation threshold of 30. That is why V2
			# never graduated in training19/20 despite ~25 h in it (ep_len_mean pinned
			# at the 1200 cap, ep_rew_mean drifting to -12.8).
			# A colour comes back while any red remains — and ALWAYS comes back when it
			# was potted illegally, even in the endgame, because it is still needed to
			# finish the ascending sequence. (Matches the human path; without the
			# `not rl_legal` half, one out-of-order pot deleted a ball the agent then
			# had to score, making the endgame unfinishable.) A wrongly potted RED, by
			# contrast, correctly stays down.
			if Globals.rl_version >= 2 and rl_is_colour and (not rl_legal or rl_reds_after > 0):
				_colours_to_respot.append(body)
		if _rl_controller != null:
			_apply_rl_pot_reward(colour, rl_legal)
		return

	# Snooker phase + respotting. The just-potted ball is still counted as "active"
	# below (not removed yet), so subtract it when it's a red.
	var is_colour := colour in COLOUR_ORDER
	var reds_after := _count_active_reds() - (1 if colour == "red" else 0)

	# ── Was this the ball the striker was actually ON? ────────────────────────
	# Previously nothing enforced this: after potting a red you were told "pot a colour",
	# then potting another red simply scored +1. Real snooker calls that a foul.
	var legal := _is_legal_pot(colour, is_colour, _must_pot_colour)
	if not legal:
		# Foul: no score for the striker; the opponent gets max(4, value of the ball).
		_foul_pending = true
		_foul_points = maxi(_foul_points, maxi(4, int(Globals.BALL_COLOUR_VALUES.get(colour, 1))))
		# A wrongly potted COLOUR always comes back up; a wrongly potted red stays down.
		body.hide()
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.process_mode = Node.PROCESS_MODE_DISABLED
		if is_colour:
			_colours_to_respot.append(body)
		return

	# After potting a red (with reds still on) the striker must pot a colour next; a
	# colour pot returns to reds. Tracks whoever is at the table, not just the human.
	_must_pot_colour = (colour == "red" and reds_after > 0)
	if _career != null:
		var pts: int = int(Globals.BALL_COLOUR_VALUES.get(colour, 1))
		if _player_turn:
			_career.add_player_points(pts)
			Globals.add_xp(pts * XP_PER_POINT)   # progression only for the human striker
		else:
			_career.add_ai_points(pts)
		_refresh_hud()
	# Colours are RESPOTTED while any red remains (the rule this game was missing —
	# without it the colours ran out and "you must pot a colour" had no target left).
	# Disable now (safe in this signal); reposition after the shot settles.
	# Out of play either way — but NEVER queue_free(). reset_game() restores the next
	# frame by looking each ball up by name, so a freed node is silently skipped and that
	# ball is gone for every later frame (measured: pot 5 reds → next frame starts with
	# 17/22 balls, draining permanently). Disabling keeps the node so it can come back.
	body.hide()
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.process_mode = Node.PROCESS_MODE_DISABLED
	if is_colour and reds_after > 0:
		_colours_to_respot.append(body)

# Once the reds are gone the colours must be taken in ascending value:
# yellow(2) → green(3) → brown(4) → blue(5) → pink(6) → black(7).
# Returns the colour the striker is ON, or "" if no colours are left.
func _required_colour() -> String:
	for c: String in COLOUR_ORDER:
		if _active_ball_of_colour(c) != null: return c
	return ""


# Is potting `colour` legal for the striker right now? Called BEFORE the ball is taken
# out of play, so the just-potted ball still counts as active.
# `must_colour` is the caller's phase flag — `_must_pot_colour` for human play,
# `_rl_must_pot_colour` for training. The RULE is identical in both modes; only the
# bookkeeping differs, so it lives here once rather than being reimplemented per mode.
func _is_legal_pot(colour: String, is_colour: bool, must_colour: bool) -> bool:
	if colour == "red":
		return not must_colour                # a red is only on when no colour is owed
	if not is_colour:
		return false                          # unknown ball — never legal
	if _count_active_reds() > 0:
		return must_colour                    # mid-frame: a colour is on only when owed
	return colour == _required_colour()       # endgame: strictly ascending order


# Foul value for the FIRST ball the cue struck this shot (0 = legal contact, no foul).
# Snooker: you must first hit the ball you are ON; the penalty is max(4, value of the
# ball on, value of the ball actually hit). Mirrors _is_legal_pot but for CONTACT.
func _first_contact_foul_value() -> int:
	var hit := _first_hit_colour
	var hit_val := int(Globals.BALL_COLOUR_VALUES.get(hit, 0))
	if _count_active_reds() > 0:
		if _must_pot_colour:
			# On a colour (any): a colour-first is legal; a red-first (or a miss) fouls.
			if hit == "" or hit == "red":
				return 4
			return 0
		# On a red: a red-first is legal; a colour-first (or a miss) fouls.
		if hit == "red":
			return 0
		if hit == "":
			return 4                          # struck nothing
		return maxi(4, hit_val)               # struck a colour first
	# Endgame — must hit the required colour in ascending order.
	var req := _required_colour()
	if req == "":
		return 0                              # nothing left to be on
	if hit == req:
		return 0
	var req_val := int(Globals.BALL_COLOUR_VALUES.get(req, 0))
	if hit == "":
		return maxi(4, req_val)               # missed the ball on
	return maxi(4, maxi(req_val, hit_val))    # struck the wrong colour first


func _apply_rl_pot_reward(colour: String, legal: bool = true) -> void:
	var v := Globals.rl_version
	if v <= 1:
		if colour == "red":
			# +10 (was +2): the pot must dominate IN EXPECTATION, not just as an
			# outcome. At +2, an unskilled agent's potting attempt had negative EV
			# (2% pot chance × 2.0 < foul risk + shaping noise), so caution always
			# won — the root cause of every plateau through training16. At +10,
			# even a 2% pot rate earns +0.2/shot, beating every passive strategy,
			# and the margin grows with skill.
			_rl_controller.add_reward(10.0)
			_rl_reds_potted += 1
			_rl_episode_score += 1
			print("[RL] RED POTTED  reds_this_ep=%d  step=%d" % [_rl_reds_potted, _rl_step_count])
			# V0: episode continues until max_steps; red ball respawns in _on_pocket_entered
	else:
		# V2+ is the real game: red → colour (respotted while reds remain) → red, then
		# the six colours in ascending order. `legal` was decided in _on_pocket_entered
		# against the PRE-pot table by the same _is_legal_pot() the human path uses, so
		# wrong-ball and out-of-order pots are penalised identically in both modes.
		if not legal:
			_rl_controller.add_reward(-0.3)
		elif colour == "red":
			_rl_controller.add_reward(1.0)
			_rl_reds_potted += 1; _rl_episode_score += 1
			# Reds gone → the striker moves on to the ascending colour sequence, where
			# nothing is "owed"; _is_legal_pot ignores the flag once reds hit zero.
			_rl_must_pot_colour = _count_active_reds() > 0
		else:
			var val: int = Globals.BALL_COLOUR_VALUES.get(colour, 1)
			_rl_controller.add_reward(float(val) / 7.0)
			_rl_episode_score += val
			_rl_must_pot_colour = false
			if v >= 3: _apply_positional_reward()

	# Episode end for V1+ (table cleared)
	if v >= 1 and not _rl_episode_done:
		var ar := _count_active_reds()
		var ac := _count_active_colours()
		# A colour waiting in _colours_to_respot is DISABLED, so it is missing from `ac`
		# even though it is coming straight back. Without this guard the table could read
		# as cleared during that one-shot window and end the episode early.
		var pending := _colours_to_respot.size()
		var cleared := (v == 1 and ar == 0) or (v >= 2 and ar == 0 and ac == 0 and pending == 0)
		if cleared:
			_rl_episode_done = true
			print("[RL] ep done (CLEARED)  steps=%d  reds=%d  score=%d  curr=%.2f" % [_rl_step_count, _rl_reds_potted, _rl_episode_score, _curriculum_level])

func _apply_positional_reward() -> void:
	if not is_instance_valid(cue_ball): return
	var target := _find_nearest_legal_ball_position(cue_ball.global_position)
	if target == cue_ball.global_position: return
	var dist := cue_ball.global_position.distance_to(target)
	_rl_controller.add_reward(0.3 * (1.0 - clamp(dist / Globals.TABLE_W, 0.0, 1.0)))

func _handle_cue_ball_foul() -> void:
	_ball_potted_this_turn = false
	if is_rl_mode:
		_rl_cue_fouled_this_turn = true # prevents double-penalty in turn resolution

	if _rl_controller != null and _rl_controller.has_method("add_reward"):
		# V0 is potting school: hard shots at pockets are exactly the shots that
		# sometimes sink the cue, so a harsh foul penalty (-1.0) taught the agent
		# to avoid potting attempts altogether (trainings 13-16). Keep the foul
		# barely negative in V0 so aggression stays positive-EV; real snooker foul
		# discipline returns from V1 onward.
		_rl_controller.add_reward(-0.2 if Globals.rl_version == 0 else -1.0)

	if is_rl_mode:
		# Signal fires during physics flush-queries — can't call freeze here.
		# Flag is picked up by _physics_process on the very next physics tick.
		_rl_cue_foul_pending = true
		return

	# Non-RL: just FLAG the foul. It's resolved in the turn resolution once every ball
	# has settled — so the incoming turn never plays into a still-moving table. (The old
	# code switched turns and fired the opponent 1 s later while balls were still rolling,
	# scattering everything, which looked like the game restarting.)
	_foul_pending = true
	_foul_points = maxi(_foul_points, 4)     # in-off is a 4-point foul at minimum
	_foul_respot_cue = true


func _respot_cue_ball() -> void:
	if not is_instance_valid(cue_ball): return
	cue_ball.freeze = true
	cue_ball.global_position = _cue_ball_start_pos
	cue_ball.linear_velocity = Vector2.ZERO
	cue_ball.angular_velocity = 0.0
	cue_ball.freeze = false


# Return each potted colour to its spot (or the nearest free point if occupied),
# re-enabling it. Called from _physics_process where freeze is safe.
func _process_colour_respots() -> void:
	for body: RigidBody2D in _colours_to_respot:
		if not is_instance_valid(body): continue
		var spot := _nearest_free_spot(_home_pos(body.name), body)
		# Move the ball to its spot WHILE still disabled/frozen, THEN re-enable — so the
		# body is never re-activated sitting inside a pocket area (the re-enable race that
		# caused the runaway). Order matters: position first, process_mode last.
		body.freeze = true
		body.global_position = spot
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.rotation = 0.0
		body.process_mode = Node.PROCESS_MODE_INHERIT
		body.show()
		body.freeze = false
		# Insurance: ignore any pocket hit on this ball for a few frames (see decl).
		_respot_guard[body.name] = RESPOT_GUARD_FRAMES
		_potted_balls.erase(body.name)
	_colours_to_respot.clear()


func _home_pos(ball_name: String) -> Vector2:
	for bd: Dictionary in _initial_ball_data:
		if str(bd["name"]) == ball_name:
			return bd["pos"] as Vector2
	return Vector2(Globals.TABLE_W * 0.5, Globals.TABLE_H * 0.5)


# Where a potted colour goes back, following the real snooker rules:
#   1. its own spot;
#   2. if occupied, the HIGHEST-VALUE spot that is free (black→pink→blue→brown→green→yellow);
#   3. if every spot is occupied, as near as possible to its own spot on the line
#      toward the top cushion, then toward the bottom;
#   4. only then a widening search — every candidate validated, never clamped.
# The old version spiralled and CLAMPED to the table box, which could drop the ball in a
# pocket mouth or hard against a cushion. Nothing here is clamped: illegal candidates are
# rejected by _spot_is_free, so a returned point is always genuinely legal.
func _nearest_free_spot(home: Vector2, ignore: RigidBody2D) -> Vector2:
	if _spot_is_free(home, ignore): return home

	for s: Vector2 in _colour_spots_by_value_desc():
		if s.distance_to(home) < 1.0: continue
		if _spot_is_free(s, ignore): return s

	# Along the spot line: up toward the top cushion first, then down (official rule).
	for dir_y: float in [-1.0, 1.0]:
		var step := 8.0
		while step <= 340.0:
			if _spot_is_free(home + Vector2(0.0, dir_y * step), ignore):
				return home + Vector2(0.0, dir_y * step)
			step += 8.0

	for radius: float in [46.0, 70.0, 96.0, 130.0, 170.0, 220.0]:
		for i: int in range(12):
			var a := TAU * float(i) / 12.0
			var cand := home + Vector2(cos(a), sin(a)) * radius
			if _spot_is_free(cand, ignore): return cand

	# Last resort: any legal point on the table at all.
	var gx := CUSHION_LO_X
	while gx <= CUSHION_HI_X:
		var gy := CUSHION_LO_Y
		while gy <= CUSHION_HI_Y:
			if _spot_is_free(Vector2(gx, gy), ignore): return Vector2(gx, gy)
			gy += 40.0
		gx += 40.0
	return home


# The six colour spots, highest value first — read from the balls' starting positions.
func _colour_spots_by_value_desc() -> Array[Vector2]:
	var entries: Array = []
	for bd: Dictionary in _initial_ball_data:
		var n: Node = get_node_or_null(NodePath(str(bd["name"])))
		if n == null: continue
		var c: String = str(n.get_meta("ball_colour", ""))
		if c == "" or c == "red" or c == "cue" or c == "unknown": continue
		entries.append({"pos": bd["pos"] as Vector2,
						"val": int(Globals.BALL_COLOUR_VALUES.get(c, 0))})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["val"]) > int(b["val"]))
	var out: Array[Vector2] = []
	for e: Dictionary in entries: out.append(e["pos"] as Vector2)
	return out


# A point is a legal resting place only if it is inside the cushions, clear of every
# pocket mouth, and not overlapping another ball. The pocket/cushion checks are the
# ones the old code was missing entirely.
func _spot_is_free(p: Vector2, ignore: RigidBody2D) -> bool:
	if p.x < CUSHION_LO_X or p.x > CUSHION_HI_X: return false
	if p.y < CUSHION_LO_Y or p.y > CUSHION_HI_Y: return false
	for pk: Vector2 in Globals.POCKET_POSITIONS:
		if p.distance_to(pk) < RESPOT_POCKET_CLEAR: return false
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == ignore: continue
		if ball.global_position.distance_to(p) < 46.0: return false
	return true

# ═════════════════════════════════════════════════════════════════════════════
# Physics process
# ═════════════════════════════════════════════════════════════════════════════
func _physics_process(delta: float) -> void:
	if is_sim_mode:
		_sim.process()
		return
	# Re-assert real-time speed for windowed play. The godot_rl Sync node sets its RL
	# speedup (time_scale 16 / 960 Hz by default) AFTER our _ready, so we correct it on
	# the first simulated frame. Two cheap comparisons; never touches headless/training.
	if _is_windowed:
		if Engine.time_scale != 1.0:
			Engine.time_scale = 1.0
		if Engine.physics_ticks_per_second != 120:
			Engine.physics_ticks_per_second = 120
	# ── RL respawn handling ─────────────────────────────────────────────────
	# _physics_process runs BEFORE the physics engine, so freeze=true is safe here.
	# Flags/arrays are set inside body_entered signals (flush-queries phase) where
	# freeze=true would crash; we defer the actual work to this safe context.
	if is_rl_mode:
		if _rl_cue_foul_pending:
			_rl_cue_foul_pending = false
			_place_cue_ball_in_d()
		for ball: RigidBody2D in _rl_balls_to_respawn:
			if not is_instance_valid(ball): continue
			_potted_balls.erase(ball.name)
			ball.linear_velocity = Vector2.ZERO
			ball.angular_velocity = 0.0
			_place_red_curriculum(ball)
		_rl_balls_to_respawn.clear()
		# OOB safety: if cue ball escapes the table (tunnelled through a wall),
		# respawn it immediately rather than letting it disappear off-screen.
		if is_instance_valid(cue_ball):
			if _is_off_table(cue_ball.global_position):
				if _rl_controller != null:
					_rl_controller.add_reward(-0.5)
				_place_cue_ball_in_d()

	# OOB safety for HUMAN play too. RL had this; normal play did not — so a cue ball that
	# tunnelled through a cushion was simply gone, leaving the frame unplayable forever.
	if not is_rl_mode:
		if is_instance_valid(cue_ball) and _is_off_table(cue_ball.global_position):
			push_warning("[Table] cue ball left the table — respotting")
			_respot_cue_ball()
		# An OBJECT ball that tunnels out is worse than it looks: it still counts as
		# "active", so the frame can never clear and never ends. Put it back in play.
		for ball: RigidBody2D in _get_table_balls(true):
			if ball == cue_ball: continue
			if not _is_off_table(ball.global_position): continue
			push_warning("[Table] %s left the table — returning it to play" % ball.name)
			ball.freeze = true
			ball.global_position = _nearest_free_spot(_home_pos(ball.name), ball)
			ball.linear_velocity = Vector2.ZERO
			ball.angular_velocity = 0.0
			ball.freeze = false

	if abs(current_vertical_spin) > 0.001 and waiting_for_ball_stop:
		current_vertical_spin *= 0.98
		if abs(current_vertical_spin) < 0.01: current_vertical_spin = 0.0

	if not is_rl_mode and _ai_shot_pending:
		_ai_shot_timer -= delta
		if _ai_shot_timer <= 0.0:
			_ai_shot_pending = false; _ball_potted_this_turn = false
			_ai_take_visual_shot()
			waiting_for_ball_stop = true; _shot_settle_counter = SETTLE_FRAMES

	# Count down the just-respotted immunity windows (see _respot_guard decl).
	if not _respot_guard.is_empty():
		for k: String in _respot_guard.keys():
			var v := int(_respot_guard[k]) - 1
			if v <= 0: _respot_guard.erase(k)
			else: _respot_guard[k] = v

	# Respot safety net: a colour can be potted in the physics step of the SAME frame
	# the one-shot turn resolution already ran (the colour was queued a frame too
	# late), stranding it in the pocket. Whenever the table is idle and settled, respot
	# anything still queued. freeze is safe here (before the physics step).
	if not waiting_for_ball_stop and not _turn_resolving \
			and not _colours_to_respot.is_empty():
		_process_colour_respots()

	if not waiting_for_ball_stop: return
	if _turn_resolving: return
	if _shot_settle_counter > 0: _shot_settle_counter -= 1; return
	# Resolve when all balls stop OR after a hard cap — a ball can jitter just above
	# STOP_THRESHOLD indefinitely (slight overlap), which would otherwise hang the turn
	# forever (no colour respot, no next recommendation). The cap force-stops and
	# resolves regardless, so the game can never get stuck.
	_wait_ticks += 1
	if not _are_all_balls_stopped() and _wait_ticks < MAX_WAIT_TICKS:
		return
	if _wait_ticks >= MAX_WAIT_TICKS:
		for ball: RigidBody2D in _get_table_balls(true):
			ball.linear_velocity = Vector2.ZERO
			ball.angular_velocity = 0.0
		push_warning("[Table] turn-resolve timeout — force-stopped jittering balls")
	_wait_ticks = 0

	_turn_resolving = true
	# Put any potted colours back on their spots now that the shot has settled
	# (freeze is safe here in _physics_process, before the physics step).
	if not _colours_to_respot.is_empty():
		_process_colour_respots()
	if not is_rl_mode:
		var gen := _turn_generation
		await get_tree().create_timer(1.0).timeout
		# The frame may have been reset while we waited — this resolution now describes a
		# table that no longer exists, so drop it rather than switching turns on a fresh rack.
		if gen != _turn_generation or not is_inside_tree():
			_turn_resolving = false
			return
	waiting_for_ball_stop = false
	_turn_resolving = false

	# Sandbox: solo free play — no turn switch, AI, or frame end. Respot the cue on an
	# in-off, drop the snooker phase so any shot is suggested, refresh the recommendation.
	if is_sandbox_mode:
		_resolve_sandbox_shot()
		return

	# Drill mode resolves on its own terms: score the single red, show the result
	# panel, and stop — no turn switching, AI, or foul handoff.
	if is_drill_mode:
		_resolve_drill_shot()
		return

	# Career: striking the WRONG ball first (or missing everything) is a foul. The game
	# previously only checked POTS, so hitting e.g. the pink first on the break — or any
	# wrong-ball-first contact — went unpunished. Skip if a pot-foul is already pending.
	if not is_rl_mode and not _foul_pending:
		var fc := _first_contact_foul_value()
		if fc > 0:
			_foul_pending = true
			_foul_points = maxi(_foul_points, fc)

	if is_rl_mode:
		if _rl_controller != null:
			# Potential-based shaping (Ng et al. 1999): reward the red's progress
			# toward a pocket. Φ(s) = -dist(red, nearest pocket); F = Φ(s') - Φ(s)
			# = (dist_before - dist_after). Closer → +, knocked away → -, unmoved → 0.
			# This is the ONLY shaping form that cannot create new local optima or be
			# farmed: it telescopes to zero over any cycle returning the red to its
			# start, so the only way to keep earning it is to keep potting. Replaces
			# the old flat +0.05 contact bonus, which paid the same whether the red
			# went toward a pocket or into the far cushion — a plateau, not a slope.
			# Skipped on potting shots: a pot already gives +2.0 and respawns the red,
			# making the post-shot distance meaningless.
			if not _ball_potted_this_turn and _rl_pre_shot_red_pocket_dist >= 0.0:
				var post_dist := _nearest_red_pocket_dist()
				if post_dist >= 0.0:
					var progress := (_rl_pre_shot_red_pocket_dist - post_dist) / Globals.TABLE_W
					_rl_controller.add_reward(SHAPE_W * maxf(0.0, progress))
		_rl_cue_hit_red_this_turn = false
		_rl_cue_fouled_this_turn = false
		_rl_pre_shot_red_pocket_dist = -1.0
		_ball_potted_this_turn = false
	elif _foul_pending:
		# Foul resolved now that the table has settled: penalty to the opponent, respot the
		# cue if it went down, hand over the turn. No mid-shot chaos. Covers both the in-off
		# and potting the wrong ball; _foul_points is max(4, value of the ball involved).
		_foul_pending = false
		_ball_potted_this_turn = false
		if _foul_respot_cue: _respot_cue_ball()
		_foul_respot_cue = false
		if _career != null:
			if _player_turn: _career.add_ai_points(_foul_points)
			else: _career.add_player_points(_foul_points)
			_refresh_hud()
		_foul_points = 4
		_must_pot_colour = false          # incoming striker starts on a red
		if _player_turn:
			_player_turn = false; _ai_shot_pending = true; _ai_shot_timer = 1.0
		else:
			_player_turn = true; _request_ml_recommendation()
	elif _player_turn:
		if _ball_potted_this_turn:
			_ball_potted_this_turn = false; _request_ml_recommendation()
		else:
			# Missed: turn over, and the incoming striker starts on a red.
			_player_turn = false; _must_pot_colour = false
			_ai_shot_pending = true; _ai_shot_timer = 1.0
	else:
		_player_turn = true; _ball_potted_this_turn = false
		_must_pot_colour = false   # fresh turn: pot a red first
		_request_ml_recommendation()

	if not is_rl_mode:
		_save_career_state()          # persist the frame after every settled turn
		var winner := _frame_winner_now()
		if winner != "": _handle_frame_won(winner)

# The frame is over when someone has the points (75), OR when there is simply nothing
# left to pot. The second case was missing entirely: clearing the table below 75 left the
# game DEADLOCKED — no balls, no winner, no reset, nothing legal for the player to do.
func _frame_winner_now() -> String:
	if _career == null: return ""
	var w: String = _career.check_frame_winner()
	if w != "": return w
	if _count_active_reds() == 0 and _count_active_colours() == 0:
		return "player" if _career.player_score >= _career.ai_score else "ai"
	return ""


func _handle_frame_won(winner: String) -> void:
	if _rl_controller != null and _rl_controller.has_method("add_reward"):
		_rl_controller.add_reward(100.0 if winner == "player" else -100.0)
	if winner == "player": Globals.add_xp(XP_FRAME_WIN)
	print("[Table] Frame won by: " + winner)
	call_deferred("reset_game")

func _are_all_balls_stopped() -> bool:
	for ball: RigidBody2D in _get_table_balls(true):
		if ball.linear_velocity.length() >= Globals.STOP_THRESHOLD: return false
	for ball: RigidBody2D in _get_table_balls(true):
		ball.linear_velocity = Vector2.ZERO; ball.angular_velocity = 0.0
	return true



# ═════════════════════════════════════════════════════════════════════════════
# Player input — DECOUPLED aim / power / spin
# ═════════════════════════════════════════════════════════════════════════════
# AIM = mouse hover (cue → cursor), live and continuous.
# POWER = a separate 0-1 value (gauge / wheel / cue pull-back) — NOT the aim drag.
# Press over the felt LOCKS the aim, then dragging backward pulls the cue stick and
# loads power; releasing fires (or cancels if you barely pulled). Space / the Shoot
# button fires at the current aim + gauge power. Every HUD control is click-through
# (see _set_ignore_recursive) so only the felt and the band consume the mouse.
func _unhandled_input(event: InputEvent) -> void:
	if is_rl_mode or is_sim_mode or not _ui_enabled: return
	# Esc toggles the pause menu (Resume / Restart / Settings / Main Menu) — it no
	# longer dumps you straight to the menu and loses the frame.
	if event.is_action_pressed("ui_cancel"):
		if _paused: _close_pause()
		else: _open_pause()
		return
	if _paused: return                             # overlay owns input while up
	if is_drill_mode and _drill_awaiting_choice: return   # result panel up
	if not is_instance_valid(cue_ball): return

	# Ball-in-hand: clicking the felt places the cue ball, nothing else.
	if _cue_in_hand:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_place_cue_at(event.position)
		return

	if not _player_turn or waiting_for_ball_stop or _turn_resolving: return

	# Sandbox: right-drag repositions any ball (replaces the AI-lineup right-click).
	if is_sandbox_mode and _handle_sandbox_drag(event):
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var d := mb.position - cue_ball.global_position
				if d.length() < 1.0: return
				# When the aim is held-locked, a press starts the pull-back WITHOUT
				# re-aiming to the click point — the frozen shot line stays put.
				if not _aim_hold_locked:
					_aim_dir = d.normalized()
				_aiming_locked = true
				_active_pull = 0.0
				_pull_press_along = (mb.position - cue_ball.global_position).dot(_aim_dir)
				_update_cue_stick(true); _refresh_trajectory()
			elif _aiming_locked:
				_aiming_locked = false
				if _active_pull >= MIN_PULL_TO_FIRE:
					_fire_shot(_aim_dir, _power_frac)
				else:
					_active_pull = 0.0
					_update_cue_stick(true); _refresh_trajectory()   # tap = cancel, keep aiming
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Right-click = toggle the aim lock (freeze/unfreeze the shot line).
			_toggle_aim_lock()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_power(_power_frac + 0.05)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_power(_power_frac - 0.05)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _aiming_locked:
			# Pull-back: how far the cursor moved BACKWARD along the locked cue axis.
			var cur_along := (mm.position - cue_ball.global_position).dot(_aim_dir)
			_active_pull = clampf(_pull_press_along - cur_along, 0.0, MAX_DRAW_PULL)
			_set_power(_active_pull / MAX_DRAW_PULL)
			_update_cue_stick(true); _refresh_trajectory()
		elif not _aim_hold_locked:
			var d := mm.position - cue_ball.global_position
			if d.length() > 1.0:
				_aim_dir = d.normalized()
				_update_cue_stick(true); _refresh_trajectory()

	elif event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_SPACE:
			_fire_shot(_aim_dir, _power_frac)
		elif ke.pressed and not ke.echo and ke.keycode == KEY_R:
			# R = line up the AI's recommended shot (adopt its exact aim/power/spin,
			# without firing) so you can play it as-is with Space, or tweak first.
			if _line_up_ai_shot():
				if _band != null and _band.has_method("set_status"):
					_band.set_status("Lined up on the recommended shot — press Space to play it, or adjust.")
			elif _band != null and _band.has_method("set_status"):
				_band.set_status("No recommendation to line up yet.")


func _on_spin_changed(new_spin: Vector2) -> void:
	# Screen Y is down-positive, but "top of the cue ball" = follow (top spin). Negate
	# Y so the TOP of the dial gives follow (+y) and the BOTTOM gives draw, matching
	# real snooker AND the model/overlay convention (spin_y>0 = follow).
	spin_offset = Vector2(new_spin.x, -new_spin.y)
	_refresh_trajectory()


# ── Firing ────────────────────────────────────────────────────────────────────
func _fire_shot(dir: Vector2, power_frac: float) -> void:
	if is_rl_mode or is_sim_mode or _cue_in_hand: return
	if _paused: return
	if is_drill_mode and _drill_awaiting_choice: return
	if not _player_turn or waiting_for_ball_stop or _turn_resolving: return
	if not is_instance_valid(cue_ball): return
	var d := dir.normalized() if dir.length() > 0.01 else Vector2.RIGHT
	power_frac = maxf(0.05, clampf(power_frac, 0.0, 1.0))
	var imp := power_frac * Globals.MAX_IMPULSE
	_aiming_locked = false; _active_pull = 0.0
	cue_ball.apply_impulse(d * imp, spin_offset * 5.0)
	current_vertical_spin = spin_offset.y
	last_shot_strength = imp
	waiting_for_ball_stop = true
	_shot_settle_counter = SETTLE_FRAMES
	_ball_potted_this_turn = false
	_first_hit_colour = ""          # fresh contact tracking for this shot
	# Release the aim lock so the next shot starts free.
	if _aim_hold_locked:
		_aim_hold_locked = false
		if _band != null and _band.has_method("set_aim_lock_display"):
			_band.set_aim_lock_display(false)
	_hide_player_controls()


func _set_power(frac: float) -> void:
	_power_frac = clampf(frac, 0.0, 1.0)
	if _band != null and _band.has_method("set_power_display"):
		_band.set_power_display(_power_frac)
	_refresh_trajectory()


# ── Aim lock ──────────────────────────────────────────────────────────────────
# Freeze the current aim so moving the mouse no longer re-aims — the player can then
# study the predicted trajectory and set power/spin without the line drifting. Toggled
# by the control-band button or right-click. The pull-back and Shoot/Space still work.
func _toggle_aim_lock() -> void:
	if not _ui_enabled or _cue_in_hand or _paused: return
	if not _player_turn or waiting_for_ball_stop or _turn_resolving: return
	_aim_hold_locked = not _aim_hold_locked
	if _band != null and _band.has_method("set_aim_lock_display"):
		_band.set_aim_lock_display(_aim_hold_locked)
	if _band != null and _band.has_method("set_status"):
		if _aim_hold_locked:
			_band.set_status("Aim LOCKED — set power/spin, then Shoot (Space). Right-click or ‘Aim Lock’ to release.")
		else:
			_band.set_status(CONTROLS_HINT)
	_update_cue_stick(true)
	_refresh_trajectory()


# ── Adopt the AI's recommended aim + power + spin WITHOUT firing ──────────────
# Bound to right-click: "line me up exactly like the AI, but let me pull the
# trigger." This is the fix for "I can't line up the point by hand" — the mouse
# only has to be roughly right, then right-click snaps onto the exact shot.
func _line_up_ai_shot() -> bool:
	if _last_rec.is_empty() or not is_instance_valid(cue_ball): return false
	var shot_v: Variant = _last_rec.get("recommended_shot")
	if typeof(shot_v) != TYPE_DICTIONARY: return false
	var shot: Dictionary = shot_v
	var dir := _aim_world_from_shot(shot) - cue_ball.global_position
	if dir.length() < 1.0: return false
	_aim_dir = dir.normalized()
	# Adopt the recommended spin (model y is follow-positive; dial shows -y).
	if shot.has("spin") and typeof(shot["spin"]) == TYPE_ARRAY and (shot["spin"] as Array).size() >= 2:
		var sp: Array = shot["spin"]
		spin_offset = Vector2(float(sp[0]), float(sp[1]))
		if _band != null and _band.has_method("set_spin_display"):
			_band.set_spin_display(Vector2(spin_offset.x, -spin_offset.y))
	_set_power(float(shot.get("force", _power_frac)))
	_update_cue_stick(true); _refresh_trajectory()
	return true


# "Play AI Shot" button: line up the exact shot, then fire it — perturbed by the
# selected difficulty so easier AIs miss more (a pot needs ~5° of aim precision, so
# a few degrees of noise is the difference between potting and missing).
func _play_ai_shot() -> void:
	if not _line_up_ai_shot():
		return
	var aim_noise_deg := 0.0
	var power_jitter := 0.0
	if Globals.ai_difficulty_level == Globals.AI_EASY:
		aim_noise_deg = 7.0
		power_jitter = 0.12
	elif Globals.ai_difficulty_level == Globals.AI_MEDIUM:
		aim_noise_deg = 2.5
		power_jitter = 0.05
	# HARD: no noise — plays the exact recommended shot.
	var dir := _aim_dir
	if aim_noise_deg > 0.0:
		dir = dir.rotated(deg_to_rad(_rng.randf_range(-aim_noise_deg, aim_noise_deg)))
	var power := clampf(_power_frac + _rng.randf_range(-power_jitter, power_jitter), 0.05, 1.0)
	_fire_shot(dir, power)


func _aim_world_from_shot(shot: Dictionary) -> Vector2:
	if shot.has("aim_point") and typeof(shot["aim_point"]) == TYPE_ARRAY and (shot["aim_point"] as Array).size() >= 2:
		var a: Array = shot["aim_point"]
		return _world_from_norm(float(a[0]), float(a[1]))
	return _world_from_norm(float(shot.get("target_x", 0.5)), float(shot.get("target_y", 0.5)))


func _world_from_norm(nx: float, ny: float) -> Vector2:
	return Vector2(nx * Globals.TABLE_W, ny * Globals.TABLE_H)


# ── Ball in hand (placement) ──────────────────────────────────────────────────
func _on_place_cue_pressed() -> void:
	if is_drill_mode and _drill_awaiting_choice: return   # result panel up
	if _aim_hold_locked:
		_aim_hold_locked = false
		if _band != null and _band.has_method("set_aim_lock_display"):
			_band.set_aim_lock_display(false)
	_cue_in_hand = true
	_aiming_locked = false
	_hide_player_controls()
	if _band != null and _band.has_method("set_status"):
		_band.set_status("Ball in hand: click inside the D (the white semicircle) to place the cue ball — AI is also finding the best spot…")
	# Ask the server for the optimal placement in parallel; it applies only if the
	# player hasn't already placed by hand (guarded in _on_placement_ready).
	if _api_bridge != null and _api_bridge.has_method("request_cue_placement"):
		var balls: Array = []
		var bid := 0
		for ball: RigidBody2D in _get_table_balls(true):
			if ball == cue_ball: continue
			bid += 1
			balls.append({"pos": ball.global_position,
				"colour": ball.get_meta("ball_colour", "red"), "id": bid})
		_api_bridge.request_cue_placement(balls, _count_active_reds(), _must_pot_colour)


func _on_placement_ready(data: Dictionary) -> void:
	if not _cue_in_hand:
		return   # player already placed by hand — respect that
	var cp_v: Variant = data.get("cue_placement")
	if typeof(cp_v) != TYPE_DICTIONARY:
		if _band != null and _band.has_method("set_status"):
			_band.set_status("No AI placement — click the table to place the cue ball yourself.")
		return
	var cp: Dictionary = cp_v
	_place_cue_at(_world_from_norm(float(cp.get("cue_x", 0.25)), float(cp.get("cue_y", 0.5))))


func _place_cue_at(screen_pos: Vector2) -> void:
	if not is_instance_valid(cue_ball): return
	# Ball in hand is played from inside the "D" (real snooker rule), so snap any
	# click to the nearest legal spot within the semicircle rather than the whole felt.
	var p := _clamp_to_d(screen_pos)
	cue_ball.freeze = true
	cue_ball.global_position = p
	cue_ball.linear_velocity = Vector2.ZERO
	cue_ball.angular_velocity = 0.0
	cue_ball.freeze = false
	_cue_in_hand = false
	if _band != null and _band.has_method("set_status"):
		_band.set_status(CONTROLS_HINT)
	_request_ml_recommendation()


# Nearest point inside the "D": the baulk-side (x ≤ baulk line) half-disc of
# radius D_RADIUS centred on the baulk line at D_CENTER_Y.
func _clamp_to_d(p: Vector2) -> Vector2:
	var center := Vector2(Globals.BAULK_X, Globals.D_CENTER_Y)
	var d := p - center
	if d.x > 0.0: d.x = 0.0                                  # stay on the baulk side
	if d.length() > Globals.D_RADIUS: d = d.normalized() * Globals.D_RADIUS
	return center + d


# ═════════════════════════════════════════════════════════════════════════════
# Cue stick + power/spin-aware trajectory preview
# ═════════════════════════════════════════════════════════════════════════════
func _build_player_ui() -> void:
	# YOUR shot preview is drawn WHITE/blue so it never blends into the AI's green
	# recommendation line. White = your cue path, pale = the ball you'd hit, cyan =
	# where your cue would end up.
	_aim_line = Line2D.new(); _aim_line.name = "AimLine"
	_aim_line.width = 3.0; _aim_line.default_color = Color(1.0, 1.0, 1.0, 0.95)
	_aim_line.z_index = 1000; _aim_line.top_level = true; add_child(_aim_line)
	_obj_line = Line2D.new(); _obj_line.name = "ObjLine"
	_obj_line.width = 2.5; _obj_line.default_color = Color(1.0, 0.9, 0.5, 0.55)
	_obj_line.z_index = 1000; _obj_line.top_level = true; add_child(_obj_line)
	_cue_after_line = Line2D.new(); _cue_after_line.name = "CueAfterLine"
	_cue_after_line.width = 2.0; _cue_after_line.default_color = Color(0.3, 0.8, 1.0, 0.5)
	_cue_after_line.z_index = 1000; _cue_after_line.top_level = true; add_child(_cue_after_line)

	_cue_stick = _CueStick.new()
	_cue_stick.name = "CueStick"
	add_child(_cue_stick)

	_band = preload("res://scripts/control_band.gd").new()
	_band.name = "ControlBand"
	add_child(_band)
	_band.spin_changed.connect(_on_spin_changed)
	_band.power_changed.connect(_set_power)
	_band.shoot_pressed.connect(func() -> void: _fire_shot(_aim_dir, _power_frac))
	_band.play_ai_pressed.connect(_play_ai_shot)
	_band.place_cue_pressed.connect(_on_place_cue_pressed)
	_band.lock_aim_pressed.connect(_toggle_aim_lock)
	if _api_bridge != null:
		_api_bridge.placement_ready.connect(_on_placement_ready)

	# A single "Pause" button (top-right) opens the pause menu — Resume / Restart /
	# Settings / Main Menu. Previously a one-click "Menu" button dumped you back to the
	# menu and lost the frame; now leaving is a deliberate choice inside the pause menu.
	var nav_layer := CanvasLayer.new()
	nav_layer.name = "NavLayer"
	nav_layer.layer = 30
	add_child(nav_layer)
	var pause_btn := Button.new()
	pause_btn.text = "⏸  Pause"
	pause_btn.position = Vector2(1120.0, 12.0)
	pause_btn.custom_minimum_size = Vector2(140.0, 38.0)
	pause_btn.tooltip_text = "Pause — resume, restart, settings, or quit to menu (Esc)"
	pause_btn.pressed.connect(_open_pause)
	nav_layer.add_child(pause_btn)

	_ui_enabled = true
	_set_power(_power_frac)
	if _band.has_method("set_status"):
		_band.set_status(CONTROLS_HINT)


# Leave the current match/drill/sandbox and return to the main menu. Clears the
# transient mode flags so Career play always starts as a normal match afterwards.
func _go_to_menu() -> void:
	_save_career_state()          # snapshot the Career frame so it can be resumed (no-op otherwise)
	Globals.active_drill = -1
	Globals.sandbox_mode = false
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ═════════════════════════════════════════════════════════════════════════════
# Sandbox free-play mode
# ═════════════════════════════════════════════════════════════════════════════
func _build_sandbox_hud() -> void:
	# Hide the Career score HUD — there's no opponent in free play.
	if _career != null:
		var chud: Node = _career.get_node_or_null("HUD")
		if chud is CanvasLayer:
			(chud as CanvasLayer).visible = false

	var hud := CanvasLayer.new()
	hud.name = "SandboxHUD"
	hud.layer = 22
	add_child(hud)

	var title := Label.new()
	title.position = Vector2(20.0, 12.0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	title.text = "Scenario Sandbox"
	hud.add_child(title)

	var info := Label.new()
	info.position = Vector2(20.0, 44.0)
	info.custom_minimum_size = Vector2(720.0, 0.0)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	info.text = "Build a position with the buttons + right-drag, then left-drag from the cue and pull back to shoot. The coach shows the best shot, which side of the cue to strike (spin dial) and where the cue will land."
	hud.add_child(info)

	# Scenario-editing controls — this is what makes it a lab, not a Career match.
	var bx := 20.0
	_mk_sandbox_btn(hud, "＋ Red",    Vector2(bx, 92.0), _sandbox_add_red);    bx += 120.0
	_mk_sandbox_btn(hud, "＋ Colour", Vector2(bx, 92.0), _sandbox_add_colour); bx += 120.0
	_mk_sandbox_btn(hud, "Clear",     Vector2(bx, 92.0), _sandbox_clear);      bx += 120.0
	_mk_sandbox_btn(hud, "Full rack", Vector2(bx, 92.0), reset_game);          bx += 120.0


func _mk_sandbox_btn(parent: Node, txt: String, pos: Vector2, cb: Callable) -> void:
	var b := Button.new()
	b.text = txt
	b.position = pos
	b.custom_minimum_size = Vector2(112.0, 36.0)
	b.pressed.connect(cb)
	parent.add_child(b)


# Sparse starting scenario (cue + 3 reds + the black) — deliberately NOT the full
# Career rack, so the sandbox reads as a practice lab you build up yourself.
func _setup_sandbox() -> void:
	_potted_balls.clear()
	_colours_to_respot.clear()
	_respot_guard.clear()
	_must_pot_colour = false
	_player_turn = true
	_ball_potted_this_turn = false
	var red_spots: Array[Vector2] = [Vector2(760.0, 300.0), Vector2(835.0, 400.0), Vector2(915.0, 330.0)]
	var red_i := 0
	var black_done := false
	for ball: RigidBody2D in _get_table_balls():
		var c: String = ball.get_meta("ball_colour", "")
		if ball == cue_ball or c == "cue":
			_freeze_ball_to(ball, _cue_ball_start_pos)
			continue
		if c == "red" and red_i < red_spots.size():
			_freeze_ball_to(ball, red_spots[red_i]); red_i += 1
			continue
		if c == "black" and not black_done:
			_freeze_ball_to(ball, Vector2(1050.0, 360.0)); black_done = true
			continue
		ball.process_mode = Node.PROCESS_MODE_DISABLED
		ball.hide()
	for ball: RigidBody2D in _get_table_balls(true):
		_respot_guard[ball.name] = RESPOT_GUARD_FRAMES


func _sandbox_add_red() -> void:
	_sandbox_enable_next(true)

func _sandbox_add_colour() -> void:
	_sandbox_enable_next(false)


# Bring one more disabled ball of the requested kind back onto the table, near centre.
func _sandbox_enable_next(want_red: bool) -> void:
	for ball: RigidBody2D in _get_table_balls():
		if ball == cue_ball: continue
		if ball.process_mode != Node.PROCESS_MODE_DISABLED: continue
		var c: String = ball.get_meta("ball_colour", "")
		var is_red := c == "red"
		var matches := is_red if want_red else (c in COLOUR_ORDER)
		if matches:
			var spot := _nearest_free_spot(Vector2(Globals.TABLE_W * 0.6, Globals.TABLE_H * 0.5), ball)
			_freeze_ball_to(ball, spot)
			_respot_guard[ball.name] = RESPOT_GUARD_FRAMES
			_request_ml_recommendation()
			return


# Clear every ball except the cue, for building a scenario from scratch.
func _sandbox_clear() -> void:
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		ball.hide()
		ball.linear_velocity = Vector2.ZERO
		ball.angular_velocity = 0.0
		ball.process_mode = Node.PROCESS_MODE_DISABLED
	_request_ml_recommendation()


# Right-drag to grab and move a ball. Returns true if the event was consumed.
func _handle_sandbox_drag(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_sandbox_drag_ball = _sandbox_ball_at(event.position)
			if _sandbox_drag_ball != null:
				_sandbox_drag_ball.freeze = true
				return true
		elif _sandbox_drag_ball != null:
			_sandbox_drag_ball.linear_velocity = Vector2.ZERO
			_sandbox_drag_ball.angular_velocity = 0.0
			_sandbox_drag_ball.freeze = false
			_sandbox_drag_ball = null
			_request_ml_recommendation()          # layout changed — re-suggest
			return true
		return false
	elif event is InputEventMouseMotion and _sandbox_drag_ball != null:
		var p := (event as InputEventMouseMotion).position
		p.x = clampf(p.x, CUSHION_LO_X, CUSHION_HI_X)
		p.y = clampf(p.y, CUSHION_LO_Y, CUSHION_HI_Y)
		_sandbox_drag_ball.global_position = p
		return true
	return false


func _sandbox_ball_at(pos: Vector2) -> RigidBody2D:
	var hit: RigidBody2D = null
	var best := 42.0                                # grab radius (px)
	for ball: RigidBody2D in _get_table_balls(true):
		var d := pos.distance_to(ball.global_position)
		if d <= best:
			best = d
			hit = ball
	return hit


func _resolve_sandbox_shot() -> void:
	# In-off: just put the cue back on its spot, no penalty/turn loss.
	if _foul_pending:
		_foul_pending = false
		if _foul_respot_cue: _respot_cue_ball()
		_foul_respot_cue = false
		_foul_points = 4
	_ball_potted_this_turn = false
	_must_pot_colour = false                        # any shot is fair game in the sandbox
	_player_turn = true
	_request_ml_recommendation()


# ═════════════════════════════════════════════════════════════════════════════
# Pause menu — Resume / Restart / Settings / Main Menu, without losing the frame
# ═════════════════════════════════════════════════════════════════════════════
func _open_pause() -> void:
	if _paused:
		return
	_paused = true
	_hide_player_controls()

	_pause_layer = CanvasLayer.new()
	_pause_layer.name = "PauseOverlay"
	_pause_layer.layer = 40
	add_child(_pause_layer)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP    # eats clicks behind the panel
	_pause_layer.add_child(dim)

	var panel := Panel.new()
	panel.size = Vector2(600.0, 780.0)
	panel.position = Vector2(640.0 - 300.0, 470.0 - 390.0)
	_pause_layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(20.0, 20.0)
	scroll.size = Vector2(560.0, 740.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.custom_minimum_size = Vector2(540.0, 0.0)
	vb.add_theme_constant_override("separation", 12)
	scroll.add_child(vb)

	var title := Label.new()
	title.text = "Paused"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	vb.add_child(title)

	# Primary actions first — the reason the menu exists.
	var resume := Button.new()
	resume.text = "▶  Resume"
	resume.custom_minimum_size = Vector2(540.0, 46.0)
	resume.pressed.connect(_close_pause)
	vb.add_child(resume)

	var restart := Button.new()
	restart.text = _restart_label()
	restart.custom_minimum_size = Vector2(540.0, 44.0)
	restart.pressed.connect(_restart_current)
	vb.add_child(restart)

	var sec := Label.new()
	sec.text = "Settings"
	sec.add_theme_font_size_override("font_size", 18)
	sec.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	vb.add_child(sec)

	var sp: VBoxContainer = preload("res://scripts/settings_panel.gd").new()
	sp.progress_reset.connect(_on_settings_progress_reset)
	sp.name_changed.connect(func(_n: String) -> void: _refresh_hud())
	vb.add_child(sp)

	var to_menu := Button.new()
	to_menu.text = "⊗  Quit to Main Menu"
	to_menu.custom_minimum_size = Vector2(540.0, 44.0)
	to_menu.tooltip_text = "Leaves this frame (it is not saved)"
	to_menu.pressed.connect(_go_to_menu)
	vb.add_child(to_menu)


func _restart_label() -> String:
	if is_drill_mode: return "↻  Restart Drill"
	if is_sandbox_mode: return "↻  Reset Sandbox"
	return "↻  Restart Frame"


# Start the current mode over (fresh), then resume.
func _restart_current() -> void:
	_close_pause()
	if is_drill_mode:
		_drill_streak = 0
		_setup_drill()
		_request_ml_recommendation()
	elif is_sandbox_mode:
		_setup_sandbox()
		_request_ml_recommendation()
	else:
		reset_game()


func _close_pause() -> void:
	_paused = false
	if _pause_layer != null and is_instance_valid(_pause_layer):
		_pause_layer.queue_free()
	_pause_layer = null
	_refresh_hud()
	if is_drill_mode:
		_update_drill_status()
	_show_player_controls()


func _on_settings_progress_reset() -> void:
	_refresh_hud()
	if is_drill_mode:
		_update_drill_status()


func _show_player_controls() -> void:
	if not _ui_enabled or _cue_in_hand: return
	if _paused: return
	if is_drill_mode and _drill_awaiting_choice: return
	if not _player_turn or waiting_for_ball_stop or _turn_resolving: return
	_update_cue_stick(true)
	_refresh_trajectory()


func _hide_player_controls() -> void:
	_aiming_locked = false; _active_pull = 0.0
	_update_cue_stick(false)
	if _aim_line != null: _aim_line.clear_points()
	if _obj_line != null: _obj_line.clear_points()
	if _cue_after_line != null: _cue_after_line.clear_points()


func _update_cue_stick(show_it: bool) -> void:
	if _cue_stick == null or not is_instance_valid(cue_ball): return
	var pull := _active_pull if _aiming_locked else _power_frac * 90.0
	var visible_now := show_it and _player_turn and not waiting_for_ball_stop \
		and not _turn_resolving and not _cue_in_hand
	_cue_stick.set_state(cue_ball.global_position, _aim_dir, pull, visible_now)


# Power- AND spin-aware preview: the line length is limited by how far the cue can
# roll at the chosen power (heavy damping), and the post-contact cue path curves
# with follow (forward) / draw (backward) / side english — not a naive tangent.
func _refresh_trajectory() -> void:
	if not _ui_enabled or _aim_line == null: return
	_aim_line.clear_points(); _obj_line.clear_points(); _cue_after_line.clear_points()
	if not _player_turn or waiting_for_ball_stop or _turn_resolving or _cue_in_hand:
		return
	if not is_instance_valid(cue_ball): return
	var cue_pos := cue_ball.global_position
	var aim := _aim_dir
	if aim.length() < 0.01: return
	aim = aim.normalized()
	var reach := maxf(30.0, clampf(_power_frac, 0.0, 1.0) * MAX_TRAVEL)

	# Trace the cue with cushion bounces AND ball detection on every segment, so the
	# preview shows it STRIKING a ball even after a reflection — never a line through it.
	var trace := _trace_cue(cue_pos, aim, reach, 2)
	_add_polyline(_aim_line, trace["path"])
	var hit: RigidBody2D = trace["hit"]
	if hit == null:
		return

	var contact_pt: Vector2 = trace["contact"]
	var in_dir: Vector2 = trace["in_dir"]      # cue heading at contact (post-bounce)
	var rem: float = trace["rem"]

	# Object ball departs along the line of centres; it gets the cos(cut) share.
	var obj_dir := (hit.global_position - contact_pt).normalized()
	var along := clampf(in_dir.dot(obj_dir), 0.0, 1.0)
	# Ignore the struck ball itself; every OTHER ball is a genuine obstruction.
	_add_polyline(_obj_line, _ray_bounce(hit.global_position, obj_dir, 1, rem * along, [hit]))

	# Cue deflection from the incoming heading: base = tangent (stun). Follow bends it
	# toward the object's line (spin_offset.y>0 → +obj_dir), draw bends it back; side
	# english adds a small perpendicular curve.
	var tangent := in_dir - obj_dir * in_dir.dot(obj_dir)
	var perp_dir := Vector2(-obj_dir.y, obj_dir.x)
	var cue_dir := tangent + obj_dir * (spin_offset.y * 0.9) + perp_dir * (spin_offset.x * 0.35)
	var cue_reach := rem * (tangent.length() + maxf(0.0, spin_offset.y) * 0.5) \
		+ rem * maxf(0.0, -spin_offset.y) * 0.45
	if cue_dir.length() > 0.05 and cue_reach > 8.0:
		# The object ball is moving away, so it isn't an obstacle for the cue — but every
		# other ball is, so the cue-after preview now stops instead of ghosting through.
		_add_polyline(_cue_after_line,
			_ray_bounce(contact_pt, cue_dir.normalized(), 1, cue_reach, [hit]))


# Trace the cue from `start` along `dir`, bouncing off cushions, stopping at the FIRST
# ball it would strike — checked on every segment, so a ball beyond a bounce is caught.
# Capped at `reach` px. Returns { path, hit, contact, in_dir (heading at contact), rem }.
func _trace_cue(start: Vector2, dir: Vector2, reach: float, max_bounces: int) -> Dictionary:
	var path := PackedVector2Array([start])
	var pos := start
	var d := dir.normalized()
	var remaining := reach
	var lo_x := CUSHION_LO_X
	var lo_y := CUSHION_LO_Y
	var hi_x := CUSHION_HI_X
	var hi_y := CUSHION_HI_Y
	for _b in range(max_bounces + 1):
		if remaining <= 0.5: break
		# nearest ball whose centre is within contact range of this segment
		var ball_t := INF
		var ball_hit: RigidBody2D = null
		for ball: RigidBody2D in _get_table_balls(true):
			if ball == cue_ball: continue
			var to_ball := ball.global_position - pos
			var proj := to_ball.dot(d)
			if proj <= 0.0: continue
			var perp := (to_ball - d * proj).length()
			if perp < 44.0:
				var back := sqrt(maxf(0.0, 44.0 * 44.0 - perp * perp))
				var t := proj - back
				if t > 0.5 and t < ball_t: ball_t = t; ball_hit = ball
		# nearest cushion
		var tx := INF
		var ty := INF
		if d.x > 0.0001: tx = (hi_x - pos.x) / d.x
		elif d.x < -0.0001: tx = (lo_x - pos.x) / d.x
		if d.y > 0.0001: ty = (hi_y - pos.y) / d.y
		elif d.y < -0.0001: ty = (lo_y - pos.y) / d.y
		var wall_t := minf(tx, ty)
		# a ball is struck before the cushion (and within reach)?
		if ball_hit != null and ball_t <= wall_t and ball_t <= remaining:
			var contact := pos + d * ball_t
			path.append(contact)
			return {"path": path, "hit": ball_hit, "contact": contact,
					"in_dir": d, "rem": maxf(0.0, remaining - ball_t)}
		# runs out of travel before any cushion?
		if wall_t == INF or remaining <= wall_t:
			path.append(pos + d * remaining)
			return {"path": path, "hit": null, "contact": Vector2.ZERO,
					"in_dir": d, "rem": 0.0}
		# bounce off the cushion and continue tracing
		pos = pos + d * wall_t
		path.append(pos)
		remaining -= wall_t
		if wall_t == tx: d.x = -d.x
		else: d.y = -d.y
	return {"path": path, "hit": null, "contact": Vector2.ZERO, "in_dir": d, "rem": 0.0}


func _add_polyline(line: Line2D, pts: PackedVector2Array) -> void:
	for p: Vector2 in pts:
		line.add_point(p)


# Polyline that bounces off cushions AND STOPS at the first ball in the way, capped at
# max_len (px of travel). `ignore` skips balls that aren't obstacles for this particular
# path (e.g. the object ball the cue just struck, which is moving away).
#
# Ball detection used to be missing here entirely — this function only reflected off
# cushions — so the predicted object-ball path and the cue's post-contact path were drawn
# straight THROUGH whole clusters of reds, including after a cushion bounce. That is why
# the preview promised a route that was plainly blocked.
func _ray_bounce(start: Vector2, dir: Vector2, bounces: int, max_len: float,
		ignore: Array = []) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var pos := start
	var d := dir.normalized()
	var remaining := max_len
	for _b in range(bounces + 1):
		if remaining <= 0.5: break
		# Nearest ball whose centre lies within contact range of this segment.
		var ball_t := INF
		for ball: RigidBody2D in _get_table_balls(true):
			if ball == cue_ball or ignore.has(ball): continue
			var to_ball := ball.global_position - pos
			var proj := to_ball.dot(d)
			if proj <= 0.0: continue
			var perp := (to_ball - d * proj).length()
			if perp < 44.0:
				var back := sqrt(maxf(0.0, 44.0 * 44.0 - perp * perp))
				var tb := proj - back
				if tb > 0.5 and tb < ball_t: ball_t = tb
		var tx := INF
		var ty := INF
		if d.x > 0.0001: tx = (CUSHION_HI_X - pos.x) / d.x
		elif d.x < -0.0001: tx = (CUSHION_LO_X - pos.x) / d.x
		if d.y > 0.0001: ty = (CUSHION_HI_Y - pos.y) / d.y
		elif d.y < -0.0001: ty = (CUSHION_LO_Y - pos.y) / d.y
		var t := minf(tx, ty)
		# A ball is struck before the cushion (and within the remaining travel) → stop.
		if ball_t <= t and ball_t <= remaining:
			pts.append(pos + d * ball_t)
			return pts
		if t == INF or t <= 0.5:
			break
		if t >= remaining:
			pos = pos + d * remaining
			pts.append(pos)
			break
		pos = pos + d * t
		pts.append(pos)
		remaining -= t
		if t == tx: d.x = -d.x
		else: d.y = -d.y
	return pts


# Pull-back cue stick, drawn in world space behind the cue ball along -aim.
class _CueStick extends Node2D:
	const STICK_LEN: float = 360.0
	var cue_pos: Vector2 = Vector2.ZERO
	var aim_dir: Vector2 = Vector2.RIGHT
	var pull: float = 0.0
	var shown: bool = false

	func _ready() -> void:
		z_index = 999
		queue_redraw()

	func set_state(cp: Vector2, ad: Vector2, pl: float, sh: bool) -> void:
		cue_pos = cp
		aim_dir = ad.normalized() if ad.length() > 0.01 else Vector2.RIGHT
		pull = pl
		shown = sh
		queue_redraw()

	func _draw() -> void:
		if not shown: return
		var back := -aim_dir
		var gap := 20.0 + pull
		var tip := cue_pos + back * gap
		var butt := tip + back * STICK_LEN
		draw_line(tip, butt, Color(0.72, 0.52, 0.26, 0.95), 6.0)      # wooden shaft
		draw_line(tip, tip + back * 16.0, Color(0.85, 0.86, 0.9, 0.95), 6.0)  # ferrule
		draw_line(tip, tip + back * 4.0, Color(0.3, 0.55, 0.95, 1.0), 6.0)    # blue tip
		draw_circle(butt, 4.5, Color(0.15, 0.1, 0.06, 0.95))         # butt cap


# ═════════════════════════════════════════════════════════════════════════════
# ML recommendation
# ═════════════════════════════════════════════════════════════════════════════
func _request_ml_recommendation() -> void:
	if is_rl_mode or is_sim_mode: return
	if _api_bridge == null or not is_instance_valid(cue_ball): return
	# Send the FULL table state; the server picks the best legal shot.
	var balls: Array = []
	var bid := 0
	for ball: RigidBody2D in _get_table_balls(true):
		if ball == cue_ball: continue
		bid += 1
		balls.append({
			"pos": ball.global_position,
			"colour": ball.get_meta("ball_colour", "red"),
			"id": bid,
		})
	# Only claim "must pot a colour" if a colour is actually on the table — otherwise
	# the recommender would find no legal target and report "no shot" even with reds
	# available (a degenerate state that respotting now prevents, but guard anyway).
	var must_colour := _must_pot_colour and _count_active_colours() > 0
	_api_bridge.request_full_recommendation(
		cue_ball.global_position, balls, _count_active_reds(), must_colour)
	_show_player_controls()

func _on_recommendation_ready(data: Dictionary) -> void:
	_last_rec = data
	var assist_on := Globals.assist_level != Globals.ASSIST_OFF
	# The overlay self-gates by assist level (including OFF), so always hand it the data.
	if _overlay != null: _overlay.apply_recommendation(data)
	if _band != null and _band.has_method("show_recommendation"):
		if assist_on:
			_band.show_recommendation(data)
		else:
			_band.show_recommendation({"mode": "none", "recommended_shot": null,
				"coaching": "Assist is off — no suggestions (change in Settings)."})
	# Point the resting cue stick at the suggested ball so it reads sensibly. Power
	# and spin stay under the player's control — "Play AI Shot" adopts them on demand.
	# Skip when assist is off, or the stick angle would leak the hidden suggestion.
	if assist_on and not _aim_hold_locked:
		var shot_v: Variant = data.get("recommended_shot")
		if typeof(shot_v) == TYPE_DICTIONARY and is_instance_valid(cue_ball):
			var aw := _aim_world_from_shot(shot_v as Dictionary)
			var dd := aw - cue_ball.global_position
			if dd.length() > 1.0: _aim_dir = dd.normalized()
	_show_player_controls()


# Called when a recommendation request fails — most often because the ML server
# isn't running. Surface it in the control band instead of failing silently, so the
# player knows why no suggestion appeared. _band is created after _ready, so guard it.
func _on_recommendation_failed(reason: String) -> void:
	push_warning("[Table] API: " + reason)
	if _band != null and _band.has_method("set_status"):
		_band.set_status("⚠ ML server offline — run ./run_smart_snooker.sh (see server.log). Playing without shot suggestions.")

func _ai_take_visual_shot() -> void:
	if not is_instance_valid(cue_ball): return
	# Aim at the ball the AI is legally ON. It used to always target the nearest RED, which
	# under the enforced rules would foul every time it owed a colour, and leave it frozen
	# in the endgame once the reds were gone.
	var target := _legal_target_position(cue_ball.global_position)
	if target == cue_ball.global_position: return
	_first_hit_colour = ""          # fresh contact tracking for the AI's shot
	cue_ball.apply_central_impulse((target - cue_ball.global_position).normalized()
		* _rng.randf_range(1500.0, 3000.0))
	waiting_for_ball_stop = true; _shot_settle_counter = SETTLE_FRAMES

func _on_cue_ball_collision(body: Node) -> void:
	if is_sim_mode:
		_sim.on_cue_collision(body)
	# Record the FIRST object ball the cue strikes this shot — used to enforce the
	# "hit the ball you're on first" foul in Career (walls are StaticBody2D, so they're
	# skipped by the RigidBody2D check and never count as a contact).
	if body is RigidBody2D and _first_hit_colour == "":
		var c: String = body.get_meta("ball_colour", "")
		if c != "" and c != "cue" and c != "unknown":
			_first_hit_colour = c
	if is_rl_mode and body is RigidBody2D:
		if body.get_meta("ball_colour", "") == "red":
			_rl_cue_hit_red_this_turn = true
	if not body is RigidBody2D or abs(current_vertical_spin) < 0.01: return
	var dir: Vector2 = ((body as Node2D).global_position - cue_ball.global_position).normalized()
	var force: float = abs(current_vertical_spin) * last_shot_strength * 0.3
	cue_ball.apply_central_impulse(dir * force if current_vertical_spin > 0.0 else -dir * force)
	current_vertical_spin *= 0.5


# ═════════════════════════════════════════════════════════════════════════════
# Game reset
# ═════════════════════════════════════════════════════════════════════════════
func reset_game() -> void:
	# Adapt reverse-curriculum difficulty from the episode that just ended (read
	# _rl_reds_potted BEFORE it is cleared below): potting comfortably → harder
	# placement; shut out → easier. Asymmetric steps (+0.02 up, -0.01 down) keep the
	# agent in the "frequent success" learning zone and prevent it getting stranded
	# at a difficulty it can't handle — the failure mode a monotonic ramp would risk.
	if is_rl_mode and Globals.rl_version == 0:
		if _rl_reds_potted >= 3:
			_curriculum_level = min(1.0, _curriculum_level + 0.02)
		elif _rl_reds_potted == 0:
			_curriculum_level = max(0.0, _curriculum_level - 0.01)

	_turn_generation += 1        # invalidate any turn resolution still inside its await
	_potted_balls.clear()
	_colours_to_respot.clear()
	_respot_guard.clear()
	_player_turn = true; _ball_potted_this_turn = false; _first_hit_colour = ""
	_foul_pending = false; _foul_points = 4; _foul_respot_cue = false; _must_pot_colour = false
	waiting_for_ball_stop = false; _turn_resolving = false; _shot_settle_counter = 0; _wait_ticks = 0
	_ai_shot_pending = false; _ai_shot_timer = 0.0
	_aim_hold_locked = false
	if _band != null and _band.has_method("set_aim_lock_display"):
		_band.set_aim_lock_display(false)
	_rl_must_pot_colour = false; _rl_reds_potted = 0; _rl_episode_score = 0
	_rl_step_count = 0; _rl_episode_done = false
	_rl_cue_foul_pending = false; _rl_balls_to_respawn.clear()
	_rl_pre_shot_red_pocket_dist = -1.0
	_rl_cue_hit_red_this_turn = false; _rl_cue_fouled_this_turn = false
	if _career != null: _career.player_score = 0; _career.ai_score = 0

	if is_rl_mode:
		_setup_episode()
	else:
		for bd: Dictionary in _initial_ball_data:
			var bn: Node = get_node_or_null(NodePath(str(bd["name"])))
			if bn == null or not is_instance_valid(bn): continue
			bn.global_position = bd["pos"] as Vector2
			bn.linear_velocity = Vector2.ZERO; bn.angular_velocity = 0.0
			bn.show(); bn.process_mode = Node.PROCESS_MODE_INHERIT

	_refresh_hud(); _request_ml_recommendation()
	_save_career_state()          # persist the fresh frame (no-op outside Career)


# ═════════════════════════════════════════════════════════════════════════════
# Career frame save / resume
# ═════════════════════════════════════════════════════════════════════════════
func _save_career_state() -> void:
	if not _is_windowed: return   # only real windowed Career play
	if is_rl_mode or is_sim_mode or is_drill_mode or is_sandbox_mode: return
	if not is_instance_valid(cue_ball): return
	var balls: Array = []
	for b: RigidBody2D in _get_table_balls():
		balls.append({
			"name": String(b.name),
			"x": b.global_position.x,
			"y": b.global_position.y,
			"active": b.process_mode != Node.PROCESS_MODE_DISABLED,
		})
	Globals.save_career({
		"balls": balls,
		"player_score": _career.player_score if _career != null else 0,
		"ai_score": _career.ai_score if _career != null else 0,
		"player_turn": _player_turn,
		"must_pot_colour": _must_pot_colour,
	})


func _restore_career_state(data: Dictionary) -> void:
	var balls_v: Variant = data.get("balls", [])
	if typeof(balls_v) != TYPE_ARRAY: return
	for entry_v: Variant in (balls_v as Array):
		if typeof(entry_v) != TYPE_DICTIONARY: continue
		var entry: Dictionary = entry_v
		var bn := get_node_or_null(NodePath(str(entry.get("name", "")))) as RigidBody2D
		if bn == null: continue
		if bool(entry.get("active", true)):
			_freeze_ball_to(bn, Vector2(float(entry.get("x", 0.0)), float(entry.get("y", 0.0))))
			_respot_guard[bn.name] = RESPOT_GUARD_FRAMES
		else:
			bn.hide()
			bn.linear_velocity = Vector2.ZERO
			bn.angular_velocity = 0.0
			bn.process_mode = Node.PROCESS_MODE_DISABLED
	if _career != null:
		_career.player_score = int(data.get("player_score", 0))
		_career.ai_score = int(data.get("ai_score", 0))
	_player_turn = bool(data.get("player_turn", true))
	_must_pot_colour = bool(data.get("must_pot_colour", false))
	# If it was the AI's turn when saved, let it take its shot on resume.
	if not _player_turn:
		_ai_shot_pending = true
		_ai_shot_timer = 1.0
	_refresh_hud()


func _refresh_hud() -> void:
	if is_rl_mode: return
	if _career == null: return
	var hud_root: Node = _career.get_node_or_null("HUD/Control/VBoxContainer")
	if hud_root == null: return
	_career.update_hud(
		hud_root.get_node_or_null("RankLabel"),
		hud_root.get_node_or_null("ScoreLabel"),
		hud_root.get_node_or_null("XpLabel"),
		hud_root.get_node_or_null("XpProgressBar"),
		Globals, _career.player_score, _career.ai_score)


# ═════════════════════════════════════════════════════════════════════════════
# Drill mode — single-shot practice (Globals.active_drill)
# ═════════════════════════════════════════════════════════════════════════════
func _setup_drill() -> void:
	var d: Dictionary = Globals.DRILL_SETUPS[Globals.active_drill]
	_drill_red_potted = false
	_drill_cue_potted = false
	_drill_awaiting_choice = false
	_potted_balls.clear()
	_colours_to_respot.clear()
	_respot_guard.clear()
	_must_pot_colour = false
	_player_turn = true
	_ball_potted_this_turn = false
	waiting_for_ball_stop = false
	_turn_resolving = false
	# Hide the Career score HUD — Player/AI scoring is meaningless in a drill.
	if _career != null:
		var chud: Node = _career.get_node_or_null("HUD")
		if chud is CanvasLayer:
			(chud as CanvasLayer).visible = false
	# Place the cue and exactly ONE red; disable every other ball.
	var red_placed := false
	var placed_red: RigidBody2D = null
	for ball: RigidBody2D in _get_table_balls():
		var colour: String = ball.get_meta("ball_colour", "")
		if ball == cue_ball or colour == "cue":
			_freeze_ball_to(ball, d["cue"])
			continue
		if colour == "red" and not red_placed:
			_freeze_ball_to(ball, d["red"])
			red_placed = true
			placed_red = ball
			continue
		ball.process_mode = Node.PROCESS_MODE_DISABLED
		ball.hide()
	# Immunity window: ignore any pocket hit on the just-(re)placed cue/red for a few
	# frames, so re-enabling a previously-potted ball can't trigger a spurious pot.
	if is_instance_valid(cue_ball):
		_respot_guard[cue_ball.name] = RESPOT_GUARD_FRAMES
	if placed_red != null:
		_respot_guard[placed_red.name] = RESPOT_GUARD_FRAMES
	_refresh_drill_hud_labels()
	_update_drill_status()


func _freeze_ball_to(ball: RigidBody2D, pos: Vector2) -> void:
	# Mirror reset_game()'s PROVEN re-placement: set the transform/velocity on the
	# (possibly DISABLED) node FIRST, then re-enable it — NO freeze toggling. The old
	# freeze/unfreeze version didn't reliably move a previously-potted ball when called
	# from a button callback, so on "Next Drill" the red stayed at its old pocket until
	# a Retry. process_mode=INHERIT re-adds the physics body at the node's current
	# transform, so positioning before enabling is what makes it land correctly.
	ball.global_position = pos
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.rotation = 0.0
	ball.show()
	ball.process_mode = Node.PROCESS_MODE_INHERIT


func _on_pocket_entered_drill(body: RigidBody2D) -> void:
	# A ball re-enabled within the last few frames (Retry/Next re-placement) can emit a
	# spurious pocket hit BEFORE its teleport-to-spot is seen — the same re-enable race
	# the Career path guards against. Without this, the re-placed red was instantly
	# "re-potted" every retry: it vanished and every shot reported "Potted!".
	if int(_respot_guard.get(body.name, 0)) > 0:
		return
	if body == cue_ball:
		_drill_cue_potted = true
		_ball_potted_this_turn = true
		return
	if _potted_balls.has(body.name):
		return
	_potted_balls.append(body.name)
	_ball_potted_this_turn = true
	if body.get_meta("ball_colour", "") == "red":
		_drill_red_potted = true
	body.hide()
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.process_mode = Node.PROCESS_MODE_DISABLED


func _resolve_drill_shot() -> void:
	var success := _drill_red_potted and not _drill_cue_potted
	var xp_earned := 0
	if success:
		_drill_streak += 1
		var base_xp := int(Globals.DRILL_SETUPS[Globals.active_drill].get("xp", 10))
		# Same streak bonus as the drills.gd session score (STREAK_BONUS_PER_POT = 5).
		xp_earned = base_xp + (_drill_streak - 1) * 5
		Globals.add_xp(xp_earned)
	else:
		_drill_streak = 0
	_show_drill_result(success, xp_earned)


func _build_drill_hud() -> void:
	_drill_hud = CanvasLayer.new()
	_drill_hud.name = "DrillHUD"
	_drill_hud.layer = 25
	add_child(_drill_hud)

	_drill_title_lbl = Label.new()
	_drill_title_lbl.position = Vector2(20.0, 16.0)
	_drill_title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drill_title_lbl.add_theme_font_size_override("font_size", 22)
	_drill_title_lbl.add_theme_color_override("font_color", Color(0.55, 0.95, 0.7))
	_drill_hud.add_child(_drill_title_lbl)

	_drill_hint_lbl = Label.new()
	_drill_hint_lbl.position = Vector2(20.0, 48.0)
	_drill_hint_lbl.custom_minimum_size = Vector2(560.0, 0.0)
	_drill_hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drill_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_drill_hint_lbl.add_theme_font_size_override("font_size", 14)
	_drill_hint_lbl.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	_drill_hud.add_child(_drill_hint_lbl)

	_drill_status_lbl = Label.new()
	_drill_status_lbl.position = Vector2(20.0, 80.0)
	_drill_status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drill_status_lbl.add_theme_font_size_override("font_size", 15)
	_drill_status_lbl.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	_drill_hud.add_child(_drill_status_lbl)


func _refresh_drill_hud_labels() -> void:
	if Globals.active_drill < 0 or Globals.active_drill >= Globals.DRILL_SETUPS.size():
		return
	var d: Dictionary = Globals.DRILL_SETUPS[Globals.active_drill]
	if _drill_title_lbl != null:
		_drill_title_lbl.text = "Drill:  %s" % str(d.get("name", ""))
	if _drill_hint_lbl != null:
		_drill_hint_lbl.text = str(d.get("hint", ""))


func _update_drill_status() -> void:
	if _drill_status_lbl != null:
		_drill_status_lbl.text = "Streak: %d   •   XP: %d   •   %s" % [
			_drill_streak, Globals.total_xp, Globals.get_rank()]


func _show_drill_result(success: bool, xp_earned: int) -> void:
	_drill_awaiting_choice = true
	_hide_player_controls()
	_clear_drill_result_panel()
	if _drill_hud == null:
		return

	var panel := Panel.new()
	panel.size = Vector2(440.0, 250.0)
	panel.position = Vector2(640.0 - 220.0, 480.0 - 125.0)
	_drill_hud.add_child(panel)
	_drill_result_panel = panel

	var vb := VBoxContainer.new()
	vb.position = Vector2(24.0, 20.0)
	vb.custom_minimum_size = Vector2(392.0, 0.0)
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var head := Label.new()
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.custom_minimum_size = Vector2(392.0, 0.0)
	head.add_theme_font_size_override("font_size", 26)
	if success:
		head.text = "✓  Potted!   +%d XP" % xp_earned
		head.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	else:
		head.text = "✗  " + ("Cue potted — foul." if _drill_cue_potted else "Missed — try again.")
		head.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	vb.add_child(head)

	var sub := Label.new()
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.custom_minimum_size = Vector2(392.0, 0.0)
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	sub.text = "Streak: %d" % _drill_streak
	vb.add_child(sub)

	var retry := Button.new()
	retry.text = "↻  Retry"
	retry.custom_minimum_size = Vector2(392.0, 44.0)
	retry.pressed.connect(_on_drill_retry)
	vb.add_child(retry)

	var nxt := Button.new()
	nxt.text = "Next Drill  →"
	nxt.custom_minimum_size = Vector2(392.0, 44.0)
	nxt.pressed.connect(_on_drill_next)
	vb.add_child(nxt)

	var menu := Button.new()
	menu.text = "←  Back to Menu"
	menu.custom_minimum_size = Vector2(392.0, 44.0)
	menu.pressed.connect(_on_drill_menu)
	vb.add_child(menu)

	_update_drill_status()


func _clear_drill_result_panel() -> void:
	if _drill_result_panel != null and is_instance_valid(_drill_result_panel):
		_drill_result_panel.queue_free()
	_drill_result_panel = null


func _on_drill_retry() -> void:
	_clear_drill_result_panel()
	_setup_drill()
	_request_ml_recommendation()


func _on_drill_next() -> void:
	Globals.active_drill = (Globals.active_drill + 1) % Globals.DRILL_SETUPS.size()
	_drill_streak = 0
	_clear_drill_result_panel()
	_setup_drill()
	_request_ml_recommendation()


func _on_drill_menu() -> void:
	_go_to_menu()


# ═════════════════════════════════════════════════════════════════════════════
# Inner classes
# ═════════════════════════════════════════════════════════════════════════════
class PocketDrawer extends Node2D:
	func _ready() -> void: queue_redraw()
	func _draw() -> void:
		# Baulk line + the "D" (ball-in-hand semicircle), so the player can see where
		# the cue ball may be placed at the break / after a foul.
		var mark := Color(0.85, 0.9, 1.0, 0.22)
		draw_line(Vector2(Globals.BAULK_X, 35.0), Vector2(Globals.BAULK_X, Globals.TABLE_H), mark, 2.0)
		draw_arc(Vector2(Globals.BAULK_X, Globals.D_CENTER_Y), Globals.D_RADIUS,
			PI * 0.5, PI * 1.5, 40, mark, 2.0)
		for pos: Vector2 in Globals.POCKET_POSITIONS:
			draw_circle(pos, Globals.POCKET_RADIUS, Color(0.08, 0.04, 0.01, 1.0))

class SpinSelector extends Control:
	signal spin_changed(new_spin: Vector2)
	var selector_radius: float = 50.0
	var _dragging: bool = false
	var _current_spin: Vector2 = Vector2.ZERO
	func _ready() -> void:
		anchor_left = -0.0; anchor_right = 1.0; anchor_top = 0.0; anchor_bottom = 0.0
		anchor_left = 1.0; offset_left = -120.0; offset_top = 10.0
		offset_right = -10.0; offset_bottom = 120.0
		custom_minimum_size = Vector2(110, 110); mouse_filter = Control.MOUSE_FILTER_STOP
	func _draw() -> void:
		var c := size / 2.0
		draw_circle(c, selector_radius, Color(1, 1, 1, 0.25))
		for i in range(64):
			var a1 := float(i) / 64.0 * TAU; var a2 := float(i + 1) / 64.0 * TAU
			draw_line(c + Vector2(cos(a1), sin(a1)) * selector_radius,
					  c + Vector2(cos(a2), sin(a2)) * selector_radius, Color(1, 1, 1, 0.6), 1.5)
		draw_line(c + Vector2(-selector_radius, 0), c + Vector2(selector_radius, 0), Color(1, 1, 1, 0.15), 1.0)
		draw_line(c + Vector2(0, -selector_radius), c + Vector2(0, selector_radius), Color(1, 1, 1, 0.15), 1.0)
		var cp := c + _current_spin * selector_radius
		draw_circle(cp, 5.0, Color(1, 0.15, 0.15, 1.0))
		draw_line(cp + Vector2(-8, 0), cp + Vector2(8, 0), Color(1, 0.15, 0.15, 0.9), 2.0)
		draw_line(cp + Vector2(0, -8), cp + Vector2(0, 8), Color(1, 0.15, 0.15, 0.9), 2.0)
	func _gui_input(event: InputEvent) -> void:
		var c := size / 2.0
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			var lp: Vector2 = event.position - c
			if event.pressed and lp.length() <= selector_radius:
				_dragging = true; _update_spin(lp); accept_event()
			elif not event.pressed and _dragging:
				_dragging = false; accept_event()
		elif event is InputEventMouseMotion and _dragging:
			_update_spin(event.position - c); accept_event()
	func _update_spin(lp: Vector2) -> void:
		if lp.length() > selector_radius: lp = lp.normalized() * selector_radius
		_current_spin = lp / selector_radius; spin_changed.emit(_current_spin); queue_redraw()
