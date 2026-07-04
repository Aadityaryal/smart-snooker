# res://scripts/overlay.gd
# ─────────────────────────────────────────────────────────────────────────────
# Draws the full strategic recommendation over the table:
#   • aim line cue → ghost-ball contact point, COLOURED by confidence
#   • white ghost ring at the exact contact point (which side / how much to aim)
#   • amber line object ball → pocket + pocket marker
#   • cyan ghost ball at the PREDICTED cue landing (position play)
#   • spin dial showing the recommended strike point
#   • faded lines for the ranked ALTERNATIVES
#   • SAFETY visualisation (blue) when there's no good pot
#   • HUD panel: mode badge, confidence, shot type, position/risk, coaching text
#
# Fed the FULL API response by table.gd (api_bridge emits the whole dict).
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

var _aim_line:       Line2D = null   # cue → ghost (confidence-coloured)
var _pocket_line:    Line2D = null   # object ball → pocket
var _markers:        Node2D = null   # ghost ring, pocket, cue-landing (custom _draw)
var _alt_lines:      Array[Line2D] = []

# When true (set by the Sandbox), draw the complete overlay regardless of the
# player's assist_level / toggle settings — the sandbox exists to show everything.
var force_full: bool = false

var _hud_layer:      CanvasLayer = null
var _panel:          Panel = null
var _mode_lbl:       Label = null
var _conf_lbl:       Label = null
var _type_lbl:       Label = null
var _pos_lbl:        Label = null
var _coach_lbl:      Label = null
var _spin_dial:      Node2D = null

const COL_HIGH := Color(0.25, 1.0, 0.35, 0.9)   # confident pot
const COL_MED  := Color(1.0, 0.85, 0.2, 0.9)
const COL_LOW  := Color(1.0, 0.4, 0.35, 0.9)
const COL_SAFE := Color(0.35, 0.7, 1.0, 0.9)    # safety
const COL_LAND := Color(0.3, 0.9, 1.0, 0.9)     # cue landing


func _ready() -> void:
	_aim_line = Line2D.new(); _aim_line.width = 3.5; _aim_line.z_index = 1001
	add_child(_aim_line)
	_pocket_line = Line2D.new(); _pocket_line.width = 2.5; _pocket_line.z_index = 1001
	_pocket_line.default_color = Color(1.0, 0.75, 0.1, 0.75)
	add_child(_pocket_line)
	for _i in range(3):
		var l := Line2D.new(); l.width = 1.5; l.z_index = 1000
		l.default_color = Color(0.7, 0.7, 0.75, 0.35)
		add_child(l); _alt_lines.append(l)
	_markers = _Markers.new(); _markers.name = "Markers"; add_child(_markers)

	# No in-table text panel — the control band UNDER the table already shows the
	# recommendation (mode, confidence, power, coaching). We keep only the on-table
	# VISUAL guidance here (aim line, ghost ring, pocket marker, heatmap).


# ═════════════════════════════════════════════════════════════════════════════
# Entry point — full API response
# ═════════════════════════════════════════════════════════════════════════════
func apply_recommendation(data: Dictionary) -> void:
	# force_full (Sandbox) shows the complete overlay regardless of the player's
	# assist setting — the sandbox exists precisely to display the recommendation.
	var assist: int = Globals.ASSIST_FULL if force_full else Globals.assist_level
	var full := assist == Globals.ASSIST_FULL
	_clear_lines()

	# Assist OFF — the player wants no on-table guidance at all. Clear and stop.
	if assist == Globals.ASSIST_OFF:
		_markers.set_meta("data", {})
		_markers.queue_redraw()
		return

	var mode := str(data.get("mode", "pot"))
	var shot_v: Variant = data.get("recommended_shot")
	var shot: Dictionary = shot_v if typeof(shot_v) == TYPE_DICTIONARY else {}

	# Heatmap: a ring around each legal ball tinted by its best makeability.
	# FULL assist only, and only if the player left the toggle on (or Sandbox).
	var heat: Array = []
	if full and (force_full or Globals.show_heatmap):
		var bm_v: Variant = data.get("ball_map")
		if typeof(bm_v) == TYPE_ARRAY:
			for e_v: Variant in bm_v:
				if typeof(e_v) != TYPE_DICTIONARY: continue
				var e: Dictionary = e_v
				heat.append({"pos": _scr(float(e.get("x", 0.0)), float(e.get("y", 0.0))),
							 "make": float(e.get("make", 0.0))})

	_markers.set_meta("data", {"heat": heat})
	_markers.queue_redraw()

	_update_hud(data, mode, shot)

	if mode == "none" or shot.is_empty():
		if mode == "safety":
			_draw_safety(data)
		return

	if mode == "safety":
		_draw_safety(data)
		return

	# HINT and FULL both draw the primary aim line + ghost + pocket (_draw_pot).
	_draw_pot(shot)
	# The ranked alternatives are extra detail — FULL only, toggleable (or Sandbox).
	if full and (force_full or Globals.show_alternatives):
		_draw_alternatives(data.get("alternatives", []))


func _clear_lines() -> void:
	_aim_line.clear_points()
	_pocket_line.clear_points()
	for l: Line2D in _alt_lines:
		l.clear_points()


func _scr(nx: float, ny: float) -> Vector2:
	return Vector2(nx * Globals.TABLE_W, ny * Globals.TABLE_H)


# ── POT recommendation ───────────────────────────────────────────────────────
func _draw_pot(shot: Dictionary) -> void:
	var conf := float(shot.get("confidence", 0.0))
	var cue := _cue_point(shot)
	var target := _scr(float(shot.get("target_x", 0.0)), float(shot.get("target_y", 0.0)))
	var aim := target
	if shot.has("aim_point") and typeof(shot["aim_point"]) == TYPE_ARRAY:
		var a: Array = shot["aim_point"]
		if a.size() >= 2: aim = _scr(float(a[0]), float(a[1]))
	var pocket := _scr(float(shot.get("pocket_x", 0.0)), float(shot.get("pocket_y", 0.0)))

	# Confidence colour.
	var col := COL_LOW
	if conf >= 55.0: col = COL_HIGH
	elif conf >= 30.0: col = COL_MED
	_aim_line.default_color = col
	_aim_line.width = 3.0 + conf * 0.03
	# Only draw the cue→aim line if we actually KNOW where the cue is. _cue_point returns
	# a far-off sentinel when the response carries no cue_path; feeding that straight into
	# the Line2D drew a huge stray line across the whole table.
	if _cue_point_valid(cue):
		_aim_line.add_point(cue); _aim_line.add_point(aim)

	_pocket_line.add_point(target); _pocket_line.add_point(pocket)

	# Markers: ghost ring at contact, pocket, cue landing (merge, keep heatmap).
	var md: Dictionary = _markers.get_meta("data", {})
	md["ghost"] = aim
	md["pocket"] = pocket
	# Predicted cue landing (position play) — FULL assist only, toggleable (or Sandbox).
	if force_full or (Globals.assist_level == Globals.ASSIST_FULL and Globals.show_landing):
		if shot.has("cue_landing") and typeof(shot["cue_landing"]) == TYPE_ARRAY:
			var cl: Array = shot["cue_landing"]
			if cl.size() >= 2: md["landing"] = _scr(float(cl[0]), float(cl[1]))
	_markers.set_meta("data", md)
	_markers.queue_redraw()

	# Spin dial.
	if shot.has("spin") and typeof(shot["spin"]) == TYPE_ARRAY:
		var sp: Array = shot["spin"]
		if sp.size() >= 2 and _spin_dial != null:
			_spin_dial.set_meta("spin", Vector2(float(sp[0]), float(sp[1])))
			_spin_dial.queue_redraw()


func _draw_alternatives(alts: Variant) -> void:
	if typeof(alts) != TYPE_ARRAY: return
	var i := 0
	for alt_v: Variant in alts:
		if i >= _alt_lines.size(): break
		if typeof(alt_v) != TYPE_DICTIONARY: continue
		var alt: Dictionary = alt_v
		var tgt := _scr(float(alt.get("target_x", 0.0)), float(alt.get("target_y", 0.0)))
		var pk := _scr(float(alt.get("pocket_x", alt.get("pocket_x", 0.0))),
					   float(alt.get("pocket_y", 0.0)))
		_alt_lines[i].add_point(tgt)
		if pk.length() > 1.0: _alt_lines[i].add_point(pk)
		i += 1


# ── SAFETY recommendation ────────────────────────────────────────────────────
func _draw_safety(data: Dictionary) -> void:
	var sv: Variant = data.get("safety")
	if typeof(sv) != TYPE_DICTIONARY: return
	var s: Dictionary = sv
	# We don't get the cue pos in safety payload directly; use recommended_shot cue
	# path if present, else the first alternative's implied cue. Draw target + landing.
	var target := _scr(float(s.get("target_x", 0.0)), float(s.get("target_y", 0.0)))
	var md: Dictionary = _markers.get_meta("data", {})
	md["safe_target"] = target
	if s.has("cue_landing") and typeof(s["cue_landing"]) == TYPE_ARRAY:
		var cl: Array = s["cue_landing"]
		if cl.size() >= 2: md["landing"] = _scr(float(cl[0]), float(cl[1]))
	_aim_line.default_color = COL_SAFE
	_aim_line.width = 3.0
	_markers.set_meta("data", md)
	_markers.queue_redraw()


func _cue_point_valid(p: Vector2) -> bool:
	return p.x > -9000.0 and p.y > -9000.0


func _cue_point(shot: Dictionary) -> Vector2:
	if shot.has("cue_path") and typeof(shot["cue_path"]) == TYPE_ARRAY:
		var cp: Array = shot["cue_path"]
		if cp.size() >= 1 and typeof(cp[0]) == TYPE_ARRAY and (cp[0] as Array).size() >= 2:
			return _scr(float(cp[0][0]), float(cp[0][1]))
	return Vector2(-9999, -9999)


# ═════════════════════════════════════════════════════════════════════════════
# HUD
# ═════════════════════════════════════════════════════════════════════════════
func _build_hud() -> void:
	_hud_layer = CanvasLayer.new(); _hud_layer.name = "OverlayHUD"; add_child(_hud_layer)

	_panel = Panel.new()
	_panel.position = Vector2(8, 210)   # below the score HUD (top-left) so both are visible
	_panel.custom_minimum_size = Vector2(320, 132)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # informational — never eat table clicks
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.10, 0.82)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", sb)
	_hud_layer.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.position = Vector2(12, 8)
	vb.custom_minimum_size = Vector2(300, 0)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(vb)

	_mode_lbl = _mk_label(vb, 18, Color(0.9, 0.95, 1.0))
	_conf_lbl = _mk_label(vb, 16, COL_HIGH)
	_type_lbl = _mk_label(vb, 13, Color(0.8, 0.8, 0.85))
	_pos_lbl  = _mk_label(vb, 13, Color(0.6, 0.85, 1.0))
	_coach_lbl = _mk_label(vb, 13, Color(1.0, 0.95, 0.8))
	_coach_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_coach_lbl.custom_minimum_size = Vector2(296, 0)

	# Spin dial, top-right of the panel.
	_spin_dial = _SpinDial.new()
	_spin_dial.position = Vector2(276, 30)
	_panel.add_child(_spin_dial)


func _mk_label(parent: Node, size: int, col: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l


func _update_hud(data: Dictionary, mode: String, shot: Dictionary) -> void:
	if _mode_lbl == null:
		return   # in-table panel removed — the band shows this instead
	if mode == "safety":
		_mode_lbl.text = "◆  PLAY SAFE"
		_mode_lbl.add_theme_color_override("font_color", COL_SAFE)
	elif mode == "none":
		_mode_lbl.text = "—  no shot"
		_mode_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	else:
		_mode_lbl.text = "●  POT"
		_mode_lbl.add_theme_color_override("font_color", COL_HIGH)

	var conf := float(shot.get("confidence", 0.0))
	if not shot.is_empty():
		var c := COL_LOW
		if conf >= 55.0: c = COL_HIGH
		elif conf >= 30.0: c = COL_MED
		_conf_lbl.add_theme_color_override("font_color", c)
		_conf_lbl.text = "Confidence: %.0f%%" % conf
		_type_lbl.text = "Shot: " + str(shot.get("shot_type", "")).replace("_", " ").capitalize()
		var pos := float(shot.get("position_value", 0.0))
		var risk := float(shot.get("miss_risk", 0.0))
		var power := float(shot.get("force", 0.0)) * 100.0
		_pos_lbl.text = "Power: %.0f%%   Position: %.0f%%   Miss risk: %.0f%%" % [power, pos, risk]
	else:
		_conf_lbl.text = ""
		_type_lbl.text = ""
		_pos_lbl.text = ""

	_coach_lbl.text = str(data.get("coaching", ""))


# ═════════════════════════════════════════════════════════════════════════════
# Custom-drawn markers (ghost ring, pocket, cue landing, safety)
# ═════════════════════════════════════════════════════════════════════════════
class _Markers extends Node2D:
	func _ready() -> void:
		z_index = 1002
		queue_redraw()

	func _draw() -> void:
		if not has_meta("data"): return
		var d: Variant = get_meta("data")
		if typeof(d) != TYPE_DICTIONARY: return
		var md: Dictionary = d
		# Heatmap: ring around each legal ball, green (easy) → red (hard).
		if md.has("heat"):
			for e_v: Variant in (md["heat"] as Array):
				var e: Dictionary = e_v
				var mk: float = e["make"]
				var col := Color(1.0, 0.35, 0.3, 0.7)          # hard = red
				if mk >= 0.55: col = Color(0.3, 1.0, 0.4, 0.7)  # easy = green
				elif mk >= 0.30: col = Color(1.0, 0.85, 0.2, 0.7)
				draw_arc(e["pos"], 26.0, 0.0, TAU, 28, col, 2.0)
		# Ghost-ball contact ring (white).
		if md.has("ghost"):
			var g: Vector2 = md["ghost"]
			draw_arc(g, 22.0, 0.0, TAU, 40, Color(1, 1, 1, 0.95), 2.5)
			draw_line(g - Vector2(6, 0), g + Vector2(6, 0), Color(1, 1, 1, 0.9), 1.5)
			draw_line(g - Vector2(0, 6), g + Vector2(0, 6), Color(1, 1, 1, 0.9), 1.5)
		# Pocket marker (amber).
		if md.has("pocket"):
			var p: Vector2 = md["pocket"]
			draw_arc(p, 18.0, 0.0, TAU, 32, Color(1.0, 0.75, 0.1, 0.5), 4.0)
			draw_circle(p, 7.0, Color(1.0, 0.75, 0.1, 0.9))
		# Predicted cue landing (cyan dashed ghost ball) — where the cue ends up.
		if md.has("landing"):
			var c: Vector2 = md["landing"]
			var col := Color(0.3, 0.9, 1.0, 0.85)
			for k in range(16):
				var a0 := TAU * k / 16.0
				var a1 := a0 + TAU / 32.0
				draw_arc(c, 22.0, a0, a1, 3, col, 2.0)
			draw_circle(c, 3.0, col)
		# Safety target (blue).
		if md.has("safe_target"):
			var st: Vector2 = md["safe_target"]
			draw_arc(st, 20.0, 0.0, TAU, 32, Color(0.35, 0.7, 1.0, 0.8), 3.0)


# ═════════════════════════════════════════════════════════════════════════════
# Spin dial — shows the recommended strike point on the cue ball
# ═════════════════════════════════════════════════════════════════════════════
class _SpinDial extends Node2D:
	func _ready() -> void:
		queue_redraw()

	func _draw() -> void:
		var r := 22.0
		# cue-ball outline
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(0.9, 0.9, 0.95, 0.8), 2.0)
		draw_line(Vector2(-r, 0), Vector2(r, 0), Color(1, 1, 1, 0.2), 1.0)
		draw_line(Vector2(0, -r), Vector2(0, r), Color(1, 1, 1, 0.2), 1.0)
		var spin := Vector2.ZERO
		if has_meta("spin"):
			var v: Variant = get_meta("spin")
			if typeof(v) == TYPE_VECTOR2: spin = v
		# spin_y: + = follow (top), - = draw (bottom). spin_x: + = right.
		var dot := Vector2(spin.x, -spin.y) * (r - 5.0)
		draw_circle(dot, 5.0, Color(1.0, 0.3, 0.3, 0.95))
