# res://scripts/xp_system.gd
# ─────────────────────────────────────────────────────────────────────────────
# Thin wrapper that delegates every call to the Globals autoload singleton.
#
# FIX L2 — challenge.gd was creating a LOCAL instance of this class:
#
#   @onready var xp_system = preload("res://scripts/xp_system.gd").new()
#
# That local instance had its own  total_xp = 0  which was discarded when the
# scene changed, so XP earned in challenge mode was never saved.
#
# Now all properties and methods forward to Globals.  Any instantiation of
# XpSystem — whether local (@onready) or shared — writes to the SAME pool.
# challenge.gd does not need to be changed to fix the bug; it just works.
#
# The RANKS constant and get_rank / add_xp interface are kept identical to the
# original so any existing callers remain compatible without modification.
# ─────────────────────────────────────────────────────────────────────────────
extends Node

# ── Mirror of Globals.RANKS for callers that read it directly ─────────────────
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

# ── total_xp delegates to Globals ─────────────────────────────────────────────
# Any read/write of  xp_system.total_xp  now touches  Globals.total_xp.
var total_xp: int:
	get: return Globals.total_xp
	set(v): Globals.total_xp = v


# ─────────────────────────────────────────────────────────────────────────────
func add_xp(amount: int) -> void:
	Globals.add_xp(amount)


func get_rank() -> String:
	return Globals.get_rank()
