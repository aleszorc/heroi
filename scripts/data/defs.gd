class_name Defs
extends RefCounted
## Static game data: weapons and unit templates.

## Infantry movement speeds in m/s.
const WALK := 2.2
const RUN := 4.0
const CRAWL := 1.0

## Reaction to effective fire (§3.6b-3): a suppression jolt of at least `trigger` makes
## every free soldier dive for the nearest micro-cover after his own `delay` (seconds),
## then stay low for `stay_low` seconds. `cooldown` limits how often a squad re-reacts.
const REACT := {"trigger": 9.0, "cooldown": 5.0, "delay_min": 0.1, "delay_max": 0.3, "stay_low": 4.0}

## Wounded and walking wounded (§3.6b-3). A stabilized casualty gets up after
## `recover_time` seconds and fights on at `acc` accuracy and `speed` speed.
const WOUNDED_FIGHT := {
	"bleed_time": 120.0,     # s until an untreated casualty bleeds out
	"first_aid_time": 8.0,   # s of treatment to stabilize him
	"recover_time": 10.0,    # s after stabilization before he gets back up
	"acc": 0.55,             # accuracy multiplier while walking wounded
	"speed": 0.6,            # speed multiplier while walking wounded
}

## Campaign (GDD §2b): one operation played as a run. All campaign balance lives here.
## Requisition (RP) is earned per battle and buys replacement men, support charges
## (the campaign ammunition) and whole new units.
const CAMPAIGN := {
	"start_requisition": 6,
	"start_support": {"mortar": 2, "fpv": 4, "bomber": 2},
	"rp_battle": 2,            # for fighting at all
	"rp_victory": 3,
	"rp_objective": 1,         # per objective held when the battle ends
	"cost_man": 1,             # one green replacement into an existing squad
	"cost_support": {"mortar": 2, "fpv": 1, "bomber": 3},
	"cost_unit": {"ua_rifle": 6, "ua_mg": 4, "ua_atgm": 5, "ua_sniper": 4, "ua_drone": 4, "ua_bradley": 12},
	"wounded_out": [1, 2],     # battles a wounded man sits out (min, max)
	"steps": [6, 8],           # operation length in sectors (min, max)
}

## Squad veterancy (GDD §2b.2): [battles survived, morale bonus, suppression recovery
## multiplier] per level, checked highest first. Never accuracy.
const VETERANCY := [
	[4, 10.0, 1.3],   # Veteran
	[2, 5.0, 1.15],   # Experienced
]
const VET_NAMES := ["", "EXPERIENCED", "VETERAN"]

## range: m. reload: s between volleys. acc: hit chance at point blank in the open.
## supp: suppression one volley adds. pen: armour penetration, 0 = cannot hurt armour.
## blast: explosive radius in m, 0 = bullet. at_only: never fired at infantry.
## halt: launcher must be stationary. speed: projectile m/s (visuals and impact delay).
## struct: [power, radius] of damage to buildings (power = wall hit points at the centre).
const WEAPONS := {
	"ak": {"name": "AK-74", "range": 150.0, "reload": 1.3, "acc": 0.30, "supp": 7.0, "pen": 0.0, "blast": 0.0, "speed": 700.0, "fx": "bullet"},
	"pkm": {"name": "PKM", "range": 220.0, "reload": 0.55, "acc": 0.20, "supp": 13.0, "pen": 0.0, "blast": 0.0, "speed": 750.0, "fx": "bullet"},
	"sniper": {"name": "Sniper rifle", "range": 280.0, "reload": 4.0, "acc": 0.80, "supp": 10.0, "pen": 0.0, "blast": 0.0, "speed": 850.0, "fx": "bullet"},
	"rpg": {"name": "RPG-7", "range": 120.0, "reload": 9.0, "acc": 0.55, "supp": 25.0, "pen": 450.0, "blast": 2.5, "speed": 140.0, "fx": "rocket", "struct": [70.0, 2.0]},
	"stugna": {"name": "Stugna-P", "range": 450.0, "reload": 18.0, "acc": 0.90, "supp": 30.0, "pen": 900.0, "blast": 2.0, "speed": 100.0, "fx": "missile", "at_only": true, "halt": true, "struct": [90.0, 2.0]},
	"cannon25": {"name": "M242 25mm", "range": 300.0, "reload": 1.1, "acc": 0.38, "supp": 22.0, "pen": 60.0, "blast": 1.5, "speed": 900.0, "fx": "shell", "struct": [18.0, 1.2]},
	"tow": {"name": "TOW-2", "range": 450.0, "reload": 22.0, "acc": 0.90, "supp": 30.0, "pen": 900.0, "blast": 2.0, "speed": 110.0, "fx": "missile", "at_only": true, "halt": true, "struct": [90.0, 2.0]},
	"cannon30": {"name": "2A42 30mm", "range": 280.0, "reload": 1.1, "acc": 0.35, "supp": 22.0, "pen": 50.0, "blast": 1.5, "speed": 900.0, "fx": "shell", "struct": [20.0, 1.2]},
	"gun125": {"name": "2A46 125mm", "range": 400.0, "reload": 9.0, "acc": 0.65, "supp": 45.0, "pen": 650.0, "blast": 4.5, "speed": 1200.0, "fx": "shell", "struct": [180.0, 3.0]},
	"coax": {"name": "Coax MG", "range": 220.0, "reload": 0.55, "acc": 0.22, "supp": 12.0, "pen": 0.0, "blast": 0.0, "speed": 750.0, "fx": "bullet"},
}

## Infantry: "men" lists one weapon per soldier. Vehicles: "armor" is [front, side, top].
const UNITS := {
	"ua_rifle": {"name": "Rifle Squad", "men": ["ak", "ak", "rpg", "ak", "ak"], "morale": 75.0, "smoke": 2},
	"ua_mg": {"name": "MG Team", "men": ["pkm", "ak", "ak"], "morale": 75.0, "smoke": 1},
	"ua_atgm": {"name": "ATGM Team", "men": ["stugna", "ak"], "morale": 70.0, "smoke": 1},
	"ua_sniper": {"name": "Sniper Team", "men": ["sniper", "ak"], "morale": 80.0, "smoke": 0},
	"ua_drone": {"name": "Drone Team", "men": ["ak", "ak"], "morale": 70.0, "smoke": 0, "drones": true},
	"ua_bradley": {"name": "M2A2 Bradley", "vehicle": true, "mesh": "bradley", "weapons": ["cannon25", "tow", "coax"], "armor": [70.0, 35.0, 20.0], "speed": 9.0, "crew": 3, "morale": 80.0},
	"ru_assault": {"name": "Assault Group", "men": ["ak", "ak", "pkm", "ak", "rpg", "ak"], "morale": 60.0, "smoke": 1},
	"ru_bmp2": {"name": "BMP-2", "vehicle": true, "mesh": "bmp2", "weapons": ["cannon30", "coax"], "armor": [35.0, 18.0, 12.0], "speed": 8.0, "crew": 3, "morale": 60.0},
	"ru_t72": {"name": "T-72B3", "vehicle": true, "mesh": "t72", "weapons": ["gun125", "coax"], "armor": [600.0, 110.0, 40.0], "speed": 7.0, "crew": 3, "morale": 70.0, "cage": true},
	"ru_mtlb": {"name": "MT-LB", "vehicle": true, "mesh": "mtlb", "weapons": ["coax"], "armor": [12.0, 10.0, 8.0], "speed": 9.0, "crew": 2, "morale": 55.0},
}
