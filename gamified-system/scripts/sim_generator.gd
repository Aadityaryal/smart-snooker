# res://scripts/sim_generator.gd
# ═════════════════════════════════════════════════════════════════════════════
# SHOT-DATA SIMULATION  —  recommendation-model ground truth (OFFLINE tooling)
# ═════════════════════════════════════════════════════════════════════════════
# Headless data generator, launched from table.gd when the game is started with
#   --sim-shots=N [--sim-out=/abs/path.jsonl] [--sim-speedup= --sim-noise= ...]
# It fires scripted shots at the REAL game physics (same scene, materials, pockets)
# and logs each shot's geometry + true outcome (potted? foul? cue landing) to JSONL.
#
# This lives in its own script — separate from the game the player actually plays —
# because it has nothing to do with human play or RL: it only runs in --sim-shots
# mode and quits when done. table.gd owns the scene (cue ball, balls, pockets); this
# node reaches back into it through the `t` reference for those shared parts, and
# table.gd delegates the three per-frame/signal hooks (process / pocket / cue-hit) to
# it while is_sim_mode is true.
extends Node

# Ghost-ball offset: at contact the cue-ball centre sits (r_cue + r_target)=44 px
# from the target centre, on the line from the pocket through the target.
const SIM_BALL_D: float = 44.0
const SIM_MAX_FRAMES: int = 420   # hard cap per shot (7 s) so a stray ball can't hang the run
const SETTLE_FRAMES: int = 4      # mirrors Table.SETTLE_FRAMES (frames to ignore after a shot)

var t: Node = null                # the Table (owner of the scene); set by table.gd

# ── Tunables (overridable from the command line) ──────────────────────────────
var _shots_target: int = 0
var _shots_done: int = 0
var _out_path: String = ""
var _file: FileAccess = null
var _ball_d: float = 44.0          # ghost-ball contact distance (--sim-balld=)
var _aim_window: float = 0.30      # ±17° uniform aim spread (--sim-noise=)
var _force_base: float = 0.28      # (--sim-forcebase=)
var _force_k: float = 0.95         # (--sim-forcek=)
var _spin: float = 0.0             # spin magnitude for the cue-landing dataset (--sim-spin=)
var _max_blockers: int = 0         # obstruction balls placed per shot (--sim-blockers=)

# ── Per-shot state ────────────────────────────────────────────────────────────
var _in_flight: bool = false
var _settle: int = 0
var _target: RigidBody2D = null
var _record: Dictionary = {}
var _potted_intended: bool = false
var _potted_any: bool = false
var _cue_fouled: bool = false
var _frames: int = 0
var _intended_pocket: Vector2 = Vector2.ZERO
var _blocker_pool: Array[RigidBody2D] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


# Parse the cmdline, set up the scene for data-gen, fire the first shot.
# Returns true if --sim-shots was given (so table.gd knows to run in sim mode).
func start_if_requested() -> bool:
	var speedup := 16.0
	for a: String in OS.get_cmdline_args():
		if a.begins_with("--sim-shots="):        _shots_target = int(a.split("=")[1])
		elif a.begins_with("--sim-out="):        _out_path     = a.split("=")[1]
		elif a.begins_with("--sim-speedup="):    speedup       = float(a.split("=")[1])
		elif a.begins_with("--sim-balld="):      _ball_d       = float(a.split("=")[1])
		elif a.begins_with("--sim-noise="):      _aim_window   = float(a.split("=")[1])
		elif a.begins_with("--sim-forcebase="):  _force_base   = float(a.split("=")[1])
		elif a.begins_with("--sim-forcek="):     _force_k      = float(a.split("=")[1])
		elif a.begins_with("--sim-spin="):       _spin         = float(a.split("=")[1])
		elif a.begins_with("--sim-blockers="):   _max_blockers = int(a.split("=")[1])
	if _shots_target <= 0:
		return false

	t.is_sim_mode = true
	t.is_rl_mode  = false
	_rng.randomize()
	_out_path = _out_path if _out_path != "" else "user://sim_data.jsonl"
	_file = FileAccess.open(_out_path, FileAccess.WRITE)
	if _file == null:
		push_error("[SIM] cannot open output: " + _out_path)
		return false

	# Run physics faster than real-time (same mechanism godot_rl uses for --speedup).
	Engine.physics_ticks_per_second = int(speedup * 60.0)
	Engine.time_scale = speedup
	Engine.max_fps = 0

	# Keep the cue ball + one red as the target; every other ball becomes a
	# potential blocker (pooled, disabled until placed per shot).
	_target = null
	_blocker_pool.clear()
	for b: RigidBody2D in t._get_table_balls():
		if b == t.cue_ball: continue
		if _target == null and b.get_meta("ball_colour", "") == "red":
			_target = b
			continue
		_blocker_pool.append(b)
		b.hide(); b.process_mode = Node.PROCESS_MODE_DISABLED
	if _target == null:
		push_error("[SIM] no red target ball in scene")
		return false

	print("[SIM] start: %d shots, speedup %d → %s" % [_shots_target, int(speedup), _out_path])
	_setup_next_shot()
	return true


func _rand_pos() -> Vector2:
	# Inside the cushions and clear of every pocket mouth.
	return Vector2(_rng.randf_range(70.0, Globals.TABLE_W - 70.0),
				   _rng.randf_range(70.0, Globals.TABLE_H - 70.0))

func _set_ball_pos(ball: RigidBody2D, p: Vector2) -> void:
	ball.freeze = true
	ball.global_position = p
	ball.linear_velocity = Vector2.ZERO
	ball.angular_velocity = 0.0
	ball.freeze = false

func _place_blockers(cue_p: Vector2, tgt_p: Vector2) -> int:
	# Disable all blockers, then enable K at random positions clear of cue/target.
	for blk: RigidBody2D in _blocker_pool:
		blk.hide(); blk.process_mode = Node.PROCESS_MODE_DISABLED
	if _max_blockers <= 0 or _blocker_pool.is_empty():
		return 0
	var k := _rng.randi_range(0, mini(_max_blockers, _blocker_pool.size()))
	var occupied: Array[Vector2] = [cue_p, tgt_p]
	for i in range(k):
		var blk: RigidBody2D = _blocker_pool[i]
		var bp := _rand_pos()
		for _tries in range(30):
			var ok := true
			for o: Vector2 in occupied:
				if bp.distance_to(o) < 55.0: ok = false; break
			if ok: break
			bp = _rand_pos()
		occupied.append(bp)
		blk.process_mode = Node.PROCESS_MODE_INHERIT
		blk.show()
		_set_ball_pos(blk, bp)
	return k

func _corridor_obstruction(a: Vector2, b: Vector2) -> Array:
	# [count, min_clear] of active blockers within a ball-width of segment a→b.
	# min_clear: 0 = a blocker dead on the line, 1 = fully clear.
	var seg := b - a
	var seg_len := seg.length()
	if seg_len < 1.0: return [0, 1.0]
	var dir := seg / seg_len
	var corridor := 44.0
	var count := 0
	var min_perp := corridor
	for blk: RigidBody2D in _blocker_pool:
		if blk.process_mode == Node.PROCESS_MODE_DISABLED: continue
		var to_b := blk.global_position - a
		var proj := to_b.dot(dir)
		if proj <= 25.0 or proj >= seg_len - 25.0: continue
		var perp := (to_b - dir * proj).length()
		if perp < corridor:
			count += 1
			if perp < min_perp: min_perp = perp
	return [count, min_perp / corridor]

func _setup_next_shot() -> void:
	# Bring the (possibly potted) target back and place a fresh random layout.
	if _target != null:
		_target.show()
		_target.process_mode = Node.PROCESS_MODE_INHERIT

	var cue_p := _rand_pos()
	var tgt_p := _rand_pos()
	for _i in range(60):
		if tgt_p.distance_to(cue_p) >= 180.0: break
		tgt_p = _rand_pos()
	_set_ball_pos(t.cue_ball, cue_p)
	_set_ball_pos(_target, tgt_p)

	# Pick a geometrically makeable pocket (cut < 75°); a pocket "behind" the target
	# can't be potted, so aiming at one just wastes the sample. Fall back to the
	# straightest pocket if none qualify.
	var makeable: Array[Vector2] = []
	var best_pocket: Vector2 = Globals.POCKET_POSITIONS[0]
	var best_cut := 999.0
	for pk: Vector2 in Globals.POCKET_POSITIONS:
		var c := rad_to_deg(acos(clampf((tgt_p - cue_p).normalized().dot((pk - tgt_p).normalized()), -1.0, 1.0)))
		if c < best_cut: best_cut = c; best_pocket = pk
		if c < 75.0: makeable.append(pk)
	var pocket: Vector2 = makeable[_rng.randi() % makeable.size()] if makeable.size() > 0 else best_pocket
	_intended_pocket = pocket

	# Traffic: place K blockers, then measure obstruction on both shot legs.
	var n_blk := _place_blockers(cue_p, tgt_p)
	var obs_cue := _corridor_obstruction(cue_p, tgt_p)
	var obs_pkt := _corridor_obstruction(tgt_p, pocket)
	var num_in_path: int = int(obs_cue[0]) + int(obs_pkt[0])
	var path_clear: float = minf(float(obs_cue[1]), float(obs_pkt[1]))

	var ghost := tgt_p + _ball_d * (tgt_p - pocket).normalized()
	var ideal_angle := (ghost - cue_p).angle()
	# aim_offset is RECORDED as a feature: the model learns which offset pots for each
	# geometry, which absorbs the physics' cut-dependent throw automatically.
	var aim_offset := _rng.randf_range(-_aim_window, _aim_window)
	var aim_angle := ideal_angle + aim_offset
	var dir := Vector2(cos(aim_angle), sin(aim_angle))

	var v_ct := tgt_p - cue_p
	var v_tp := pocket - tgt_p
	var cut := rad_to_deg(acos(clampf(v_ct.normalized().dot(v_tp.normalized()), -1.0, 1.0)))
	# Signed cut (left/right) so the model can tell which way throw pushes the object.
	var cut_signed := cut * signf(v_ct.cross(v_tp))

	# Force centred on a distance match but sampled BROADLY so the model sees the
	# full force→outcome surface (too-soft falls short, too-hard rattles out).
	var total_dist := (v_ct.length() + v_tp.length()) / Globals.TABLE_W
	var force_center := _force_base + _force_k * total_dist
	var force_frac := clampf(force_center + _rng.randf_range(-0.28, 0.28), 0.22, 1.0)

	# Spin: side (x) + top/back (y), each in [-1,1]*_spin. Applied the same way as a
	# real/agent shot so the physics (and follow/draw in the table's cue collision
	# handler) match the game exactly.
	var spin := Vector2.ZERO
	if _spin > 0.0:
		spin = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _spin

	_record = {
		"cue_x": cue_p.x / Globals.TABLE_W, "cue_y": cue_p.y / Globals.TABLE_H,
		"target_x": tgt_p.x / Globals.TABLE_W, "target_y": tgt_p.y / Globals.TABLE_H,
		"pocket_x": pocket.x / Globals.TABLE_W, "pocket_y": pocket.y / Globals.TABLE_H,
		"dist_cue_target": v_ct.length() / Globals.TABLE_W,
		"dist_target_pocket": v_tp.length() / Globals.TABLE_W,
		"cut_angle": cut,
		"cut_signed": cut_signed,
		"aim_offset": aim_offset,
		"force_frac": force_frac,
		"spin_x": spin.x, "spin_y": spin.y,
		"num_in_path": num_in_path,
		"path_clear": path_clear,
		"n_blockers": n_blk,
	}
	_potted_intended = false
	_potted_any = false
	_cue_fouled = false
	_frames = 0

	var force := force_frac * Globals.MAX_IMPULSE
	t.cue_ball.apply_impulse(dir * force, spin * 5.0)
	t.current_vertical_spin = spin.y
	t.last_shot_strength = force
	_in_flight = true
	_settle = SETTLE_FRAMES


# Called by table.gd's _on_pocket_entered while is_sim_mode.
func on_pocket(body: Node) -> void:
	var rb := body as RigidBody2D
	if rb == null: return
	if rb == t.cue_ball:
		_cue_fouled = true
		return
	if rb == _target:
		_potted_any = true
		# Count it only if the target dropped into the pocket we AIMED at — not one
		# it caromed into by luck. Pockets are >200 px apart, so 80 px cleanly
		# distinguishes the intended pocket from any other.
		if rb.global_position.distance_to(_intended_pocket) < 80.0:
			_potted_intended = true
		call_deferred("_disable_body", rb)
	else:
		# A blocker dropped — take it out of play so it can't linger in a pocket.
		call_deferred("_disable_body", rb)

func _disable_body(rb: RigidBody2D) -> void:
	if not is_instance_valid(rb): return
	rb.hide()
	rb.linear_velocity = Vector2.ZERO
	rb.angular_velocity = 0.0
	rb.process_mode = Node.PROCESS_MODE_DISABLED


# Called by table.gd's _on_cue_ball_collision while is_sim_mode.
# Records the cue↔target centre distance at first contact = 2×effective radius.
# Only the first contact per shot matters for calibrating the ghost distance.
func on_cue_collision(body: Node) -> void:
	if body is RigidBody2D and body == _target:
		if not _record.has("contact_dist"):
			_record["contact_dist"] = t.cue_ball.global_position.distance_to(
				(body as Node2D).global_position)


# Called by table.gd's _physics_process while is_sim_mode.
func process() -> void:
	if not _in_flight:
		return
	_frames += 1
	if _settle > 0:
		_settle -= 1
		return
	# Resolve when everything has stopped, or the per-shot frame cap is hit.
	if _frames < SIM_MAX_FRAMES and not t._are_all_balls_stopped():
		return

	# Safety: a target that rolled to rest inside the intended pocket but never fired
	# body_entered (fast crossing) still counts as potted.
	if not _potted_intended and is_instance_valid(_target):
		if _target.global_position.distance_to(_intended_pocket) < Globals.POCKET_RADIUS:
			_potted_intended = true
			_potted_any = true

	_record["potted"]      = 1 if _potted_intended else 0
	_record["potted_any"]  = 1 if _potted_any else 0
	_record["foul"]        = 1 if _cue_fouled else 0
	_record["cue_final_x"] = t.cue_ball.global_position.x / Globals.TABLE_W
	_record["cue_final_y"] = t.cue_ball.global_position.y / Globals.TABLE_H
	_file.store_line(JSON.stringify(_record))

	_shots_done += 1
	if _shots_done % 500 == 0:
		_file.flush()
		print("[SIM] %d/%d" % [_shots_done, _shots_target])

	_in_flight = false
	if _shots_done >= _shots_target:
		_file.flush(); _file.close()
		print("[SIM] DONE %d shots → %s" % [_shots_done, _out_path])
		get_tree().quit()
		return
	_setup_next_shot()
