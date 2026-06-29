# res://scripts/globals.gd
# AUTOLOAD SINGLETON
#   Project → Project Settings → Autoload
#   Path: res://scripts/globals.gd   Name: Globals
extends Node

# ── Table dimensions ──────────────────────────────────────────────────────────
const TABLE_W: float = 1220.0
const TABLE_H: float = 685.0

# ── Snooker geometry ──────────────────────────────────────────────────────────
const BAULK_X:    float = 292.0
const D_RADIUS:   float = 73.0
const D_CENTER_Y: float = 360.0

# ── Pocket positions ──────────────────────────────────────────────────────────
const POCKET_POSITIONS: Array[Vector2] = [
	Vector2(35.0,   35.0),
	Vector2(640.0,  35.0),
	Vector2(1245.0, 35.0),
	Vector2(35.0,  685.0),
	Vector2(640.0, 685.0),
	Vector2(1245.0,685.0),
]
const POCKET_RADIUS: float = 28.0

# ── Ball physics ──────────────────────────────────────────────────────────────
const BALL_LINEAR_DAMP:  float = 2.0
const BALL_ANGULAR_DAMP: float = 1.8
const BALL_FRICTION:     float = 0.6
const BALL_BOUNCE:       float = 0.7
const STOP_THRESHOLD:    float = 5.0    # px/s below which a ball counts as stopped.
# Was 2.0 — too low: two balls that settle a hair overlapped get pushed apart at
# ~3 px/s FOREVER, so _are_all_balls_stopped() never returned true and the turn (and
# the colour respot) hung indefinitely. 5 px/s clears that jitter while staying low
# enough not to freeze a ball still dribbling into a pocket. A hard timeout in the
# turn resolution catches any worse jitter.

# ── Shot force ────────────────────────────────────────────────────────────────
const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE:       float = 4000.0

# ── Ball point values (standard snooker) ──────────────────────────────────────
const BALL_COLOUR_VALUES: Dictionary = {
	"red": 1, "yellow": 2, "green": 3, "brown": 4,
	"blue": 5, "pink": 6, "black": 7,
}

# ── Player account ────────────────────────────────────────────────────────────
# A simple local "account": a display name shown in the HUD/menu and saved alongside
# progress. No server/login — one profile per install, editable in Settings.
var player_name: String = "Player"

# ── XP / rank ─────────────────────────────────────────────────────────────────
# Persisted to disk: nothing in the game used to save anything, so XP and rank reset to
# zero on every launch — progression could never actually accumulate for the player.
var total_xp: int = 0

const SAVE_PATH: String = "user://progress.cfg"

# ── Player settings (persisted to progress.cfg, [settings] section) ────────────
# assist_level: how much on-table ML guidance the overlay draws.
const ASSIST_OFF:  int = 0   # no on-table guidance
const ASSIST_HINT: int = 1   # aim line + ghost/pocket + confidence only
const ASSIST_FULL: int = 2   # full overlay: + heatmap, alternatives, cue landing
var assist_level: int = ASSIST_FULL

var show_heatmap:      bool = true   # per-ball makeability rings  (FULL only)
var show_alternatives: bool = true   # faded lines for ranked alts (FULL only)
var show_landing:      bool = true   # predicted cue-ball landing  (FULL only)

# ai_difficulty_level: how well the AI opponent plays (used by table._play_ai_shot).
const AI_EASY:   int = 0
const AI_MEDIUM: int = 1
const AI_HARD:   int = 2
var ai_difficulty_level: int = AI_MEDIUM

# ── Drill mode ─────────────────────────────────────────────────────────────────
# Which practice drill table.gd should set up. -1 = normal Career play; >=0 selects
# a DRILL_SETUPS entry. TRANSIENT (never persisted): it's set by drills.gd right
# before loading table.tscn and cleared when leaving a drill to the menu / starting
# a Career match, so Career is never accidentally launched in drill mode.
var active_drill: int = -1

# Free-play Sandbox: when true, table.gd runs a solo practice table (no AI, no turn
# loss, no frame end) where you can drag any ball and shoot with full physics +
# live recommendations. TRANSIENT (never persisted); set by menu.gd, cleared on exit.
var sandbox_mode: bool = false

# Each drill is a single, repeatable practice shot: a fixed cue + one red position
# and the pocket the pot is aimed at. Positions are in table space (0..TABLE_W,
# 0..TABLE_H) and were chosen so the cut angle matches the drill's name (see
# drills.gd DRILLS for the matching names/xp). table.gd::_setup_drill places these.
const DRILL_SETUPS: Array[Dictionary] = [
	{   # 0 — Straight Pot: cue, red and pocket collinear (zero cut).
		"name": "Straight Pot", "xp": 10, "pocket": 5,
		"cue": Vector2(540.0, 319.0), "red": Vector2(850.0, 480.0),
		"hint": "Straight pot into the bottom-right — zero cut. Stun through the centre.",
	},
	{   # 1 — Thin Cut: ~20° cut.
		"name": "Thin Cut", "xp": 20, "pocket": 5,
		"cue": Vector2(453.0, 428.0), "red": Vector2(850.0, 480.0),
		"hint": "A thin cut to the bottom-right. Aim for the ghost-ball contact point.",
	},
	{   # 2 — Medium Cut: ~43° cut.
		"name": "Medium Cut", "xp": 30, "pocket": 5,
		"cue": Vector2(465.0, 588.0), "red": Vector2(850.0, 480.0),
		"hint": "A half-ball cut to the bottom-right. Judge the contact point carefully.",
	},
	{   # 3 — Heavy Cut: ~65° cut.
		"name": "Heavy Cut", "xp": 50, "pocket": 5,
		"cue": Vector2(628.0, 651.0), "red": Vector2(850.0, 480.0),
		"hint": "A fine cut to the bottom-right — maximum precision. Don't over-hit.",
	},
	{   # 4 — Long Pot: near-straight, long distance to the top-right.
		"name": "Long Pot", "xp": 40, "pocket": 2,
		"cue": Vector2(449.0, 628.0), "red": Vector2(1050.0, 180.0),
		"hint": "A long pot to the top-right corner. Control your pace and stay straight.",
	},
]


func _ready() -> void:
	load_progress()


func load_progress() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return                                  # no save yet — start at 0, not an error
	total_xp = maxi(int(cfg.get_value("progress", "total_xp", 0)), 0)
	player_name = str(cfg.get_value("progress", "player_name", "Player"))
	if player_name.strip_edges().is_empty():
		player_name = "Player"
	assist_level        = clampi(int(cfg.get_value("settings", "assist_level", ASSIST_FULL)), ASSIST_OFF, ASSIST_FULL)
	show_heatmap        = bool(cfg.get_value("settings", "show_heatmap", true))
	show_alternatives   = bool(cfg.get_value("settings", "show_alternatives", true))
	show_landing        = bool(cfg.get_value("settings", "show_landing", true))
	ai_difficulty_level = clampi(int(cfg.get_value("settings", "ai_difficulty_level", AI_MEDIUM)), AI_EASY, AI_HARD)


func save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "total_xp", total_xp)
	cfg.set_value("progress", "player_name", player_name)
	cfg.set_value("settings", "assist_level", assist_level)
	cfg.set_value("settings", "show_heatmap", show_heatmap)
	cfg.set_value("settings", "show_alternatives", show_alternatives)
	cfg.set_value("settings", "show_landing", show_landing)
	cfg.set_value("settings", "ai_difficulty_level", ai_difficulty_level)
	cfg.save(SAVE_PATH)

const RANKS: Array[Dictionary] = [
	{"xp": 15000, "rank": "World Class"},
	{"xp": 10000, "rank": "Elite"},
	{"xp": 7000,  "rank": "Pro Circuit"},
	{"xp": 4500,  "rank": "Semi-Pro"},
	{"xp": 2500,  "rank": "Regional"},
	{"xp": 1200,  "rank": "Club Player"},
	{"xp": 500,   "rank": "Amateur II"},
	{"xp": 0,     "rank": "Amateur I"},
]

func add_xp(amount: int) -> void:
	if amount <= 0: return
	total_xp += amount
	save_progress()

# Wipe accumulated progression (XP → rank) back to zero. Keeps the player name and
# the gameplay settings; only the earned progress is cleared. Persisted immediately.
func reset_progress() -> void:
	total_xp = 0
	save_progress()


# ── Career frame save/resume ────────────────────────────────────────────────────
# A snapshot of the in-progress Career frame (ball positions, scores, whose turn) so
# the player can leave to the menu and pick up exactly where they left off. Stored in
# its own file so it's independent of settings/XP. `career_resume` is a TRANSIENT flag
# the menu sets to tell table.gd whether to restore on load.
const CAREER_SAVE_PATH: String = "user://career_save.cfg"
var career_resume: bool = false

func save_career(data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("career", "data", data)
	cfg.save(CAREER_SAVE_PATH)

func load_career() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(CAREER_SAVE_PATH) != OK:
		return {}
	var d: Variant = cfg.get_value("career", "data", {})
	return d if typeof(d) == TYPE_DICTIONARY else {}

func has_career_save() -> bool:
	return FileAccess.file_exists(CAREER_SAVE_PATH)

func clear_career_save() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.file_exists("career_save.cfg"):
		d.remove("career_save.cfg")

func get_rank() -> String:
	for entry: Dictionary in RANKS:
		if total_xp >= int(entry["xp"]):
			return String(entry["rank"])
	return "Amateur I"

# ── RL Curriculum version ─────────────────────────────────────────────────────
# 0=V0  1=V1  2=V2  3=V3
# Modified at runtime: train_rl.py writes rl_config.json, table.gd reads it on reset.
var rl_version: int = 0

# ── Max steps per episode per version ─────────────────────────────────────────
# Right-sized to ~20-30 shots per pot needed. The old caps (2000/5000/8000) were
# 5-10x too large: since V1+ episodes end when the balls are cleared, an agent that
# leaves one stubborn ball ran the FULL cap every episode — bleeding step cost and,
# fatally, preventing the graduation window from ever filling within the budget.
const V0_MAX_STEPS: int = 200    # 1 red, respawns → fixed-length episode
const V1_MAX_STEPS: int = 400    # 15 reds  (~27 shots/red)
const V2_MAX_STEPS: int = 1200   # 15 reds + colours alternating
const V3_MAX_STEPS: int = 1600   # full frame + spin

# ── Graduation criteria (checked by CurriculumCallback in train_rl.py) ────────
const V0_GRADUATE_REWARD: float = 0.75  # avg episode reward over 1000 eps
const V1_GRADUATE_REDS:   float = 10.0  # avg reds potted per ep over 500 eps
const V2_GRADUATE_SCORE:  float = 30.0  # avg snooker points per ep over 500 eps
