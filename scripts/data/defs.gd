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

## Cover against fire (GDD §3.5-3.6). Terrain cover c (BattleMap.PROPS) keeps
## (1 - c)^hit_power of the hit chance, so a trench or a wood is worth far more than
## a crater. Terrain cover faces the threat it was taken against: inside +-flank_arc
## of that facing it counts in full, falling to flank_keep of it from straight behind
## (walls and wrecks are already directional, buildings protect all round).
const COVER := {
	"hit_power": 1.8,
	"flank_arc": PI / 3.0,
	"flank_keep": 0.4,
	"blast_top": 0.65,       # top attack (shells, drones): lethality × (1 - cover × blast_top)
	"blast_miss": 2.5,       # a missed rocket or shell scatters this much further than a bullet
	"dodge_cover": 0.5,      # in cover this good a squad stays down instead of running from an FPV
}

## Suppression (GDD §3.6): what a volley landing on a unit really does to it.
## impact_cover / unit_cover: share of the cover value taken off the suppression at
## the impact and again at the unit (a trench keeps ~25% of it). shooter_state /
## range: suppression also scales with how well aimed the fire is, 1 - x at worst.
## under_fire: a unit in cover keeps recovering while fire is still coming in, at
## cover * under_fire of its normal rate (men duck below the lip between bursts).
const SUPPRESSION := {
	"impact_cover": 0.85,
	"unit_cover": 0.5,
	"shooter_state": 0.5,
	"range": 0.5,
	"under_fire": 0.6,
}

## Breaking under fire (GDD §3.6). A panicked unit never runs across a field: with
## stay_cover of directional cover it goes to ground where it is, otherwise it dashes
## at most `dash` m to the best cover close by, and when the panic passes it crawls
## back to the post it was holding.
const PANIC := {"time_min": 7.0, "time_max": 12.0, "stay_cover": 0.3, "dash": 8.0}

## Spotting (GDD §3.4): concealment changes with what the unit is doing. Firing
## reveals it for fire_time s, scaled by the weapon's "signature" (1 = a rifle burst;
## a single suppressed sniper shot has far less). Units may add a "stealth" bonus.
const STEALTH := {
	"still_bonus": 0.12,     # stationary for 3 s
	"prone_bonus": 0.2,      # infantry: per man lying flat (crouch_bonus: kneeling)
	"crouch_bonus": 0.05,
	"run_factor": 0.5,
	"sneak_bonus": 0.1,
	"ambush_bonus": 0.15,    # holding fire, unseen
	"fire_factor": 0.35,     # concealment left just after firing (signature 1)
	"fire_time": 3.0,
}

## Target choice (Unit.pick_target): score is distance in m, lower is better.
## small_team: added per man short of three, so a two-man team far off is a poor
## pick next to a squad that is closer and firing.
const TARGETING := {"small_team": 40.0, "arc_out": 80.0}

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
	"disband_refund": 0.5,     # share of cost_unit returned when a unit is disbanded
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
## signature: how much a shot reveals the shooter (Defs.STEALTH), default 1.
const WEAPONS := {
	"ak": {"name": "AK-74", "range": 150.0, "reload": 1.3, "acc": 0.30, "supp": 7.0, "pen": 0.0, "blast": 0.0, "speed": 700.0, "fx": "bullet"},
	"pkm": {"name": "PKM", "range": 220.0, "reload": 0.55, "acc": 0.20, "supp": 13.0, "pen": 0.0, "blast": 0.0, "speed": 750.0, "fx": "bullet"},
	"sniper": {"name": "Sniper rifle", "range": 280.0, "reload": 4.0, "acc": 0.80, "supp": 10.0, "pen": 0.0, "blast": 0.0, "speed": 850.0, "fx": "bullet", "signature": 0.3},
	"rpg": {"name": "RPG-7", "range": 120.0, "reload": 9.0, "acc": 0.55, "supp": 25.0, "pen": 450.0, "blast": 2.5, "speed": 140.0, "fx": "rocket", "struct": [70.0, 2.0]},
	"stugna": {"name": "Stugna-P", "range": 450.0, "reload": 18.0, "acc": 0.90, "supp": 30.0, "pen": 900.0, "blast": 2.0, "speed": 100.0, "fx": "missile", "at_only": true, "halt": true, "struct": [90.0, 2.0]},
	"cannon25": {"name": "M242 25mm", "range": 300.0, "reload": 1.1, "acc": 0.38, "supp": 22.0, "pen": 60.0, "blast": 1.5, "speed": 900.0, "fx": "shell", "struct": [18.0, 1.2]},
	"tow": {"name": "TOW-2", "range": 450.0, "reload": 22.0, "acc": 0.90, "supp": 30.0, "pen": 900.0, "blast": 2.0, "speed": 110.0, "fx": "missile", "at_only": true, "halt": true, "struct": [90.0, 2.0]},
	"cannon30": {"name": "2A42 30mm", "range": 280.0, "reload": 1.1, "acc": 0.35, "supp": 22.0, "pen": 50.0, "blast": 1.5, "speed": 900.0, "fx": "shell", "struct": [20.0, 1.2]},
	"gun125": {"name": "2A46 125mm", "range": 400.0, "reload": 9.0, "acc": 0.65, "supp": 45.0, "pen": 650.0, "blast": 4.5, "speed": 1200.0, "fx": "shell", "struct": [180.0, 3.0]},
	"coax": {"name": "Coax MG", "range": 220.0, "reload": 0.55, "acc": 0.22, "supp": 12.0, "pen": 0.0, "blast": 0.0, "speed": 750.0, "fx": "bullet"},
}

## Infantry: "men" lists one weapon per soldier; "stealth" adds to concealment.
## Vehicles: "armor" is [front, side, top].
const UNITS := {
	"ua_rifle": {"name": "Rifle Squad", "men": ["ak", "ak", "rpg", "ak", "ak"], "morale": 75.0, "smoke": 2},
	"ua_mg": {"name": "MG Team", "men": ["pkm", "ak", "ak"], "morale": 75.0, "smoke": 1},
	"ua_atgm": {"name": "ATGM Team", "men": ["stugna", "ak"], "morale": 70.0, "smoke": 1},
	"ua_sniper": {"name": "Sniper Team", "men": ["sniper", "ak"], "morale": 80.0, "smoke": 0, "stealth": 0.1},
	"ua_drone": {"name": "Drone Team", "men": ["ak", "ak"], "morale": 70.0, "smoke": 0, "drones": true},
	"ua_bradley": {"name": "M2A2 Bradley", "vehicle": true, "mesh": "bradley", "weapons": ["cannon25", "tow", "coax"], "armor": [70.0, 35.0, 20.0], "speed": 9.0, "crew": 3, "morale": 80.0},
	"ru_assault": {"name": "Assault Group", "men": ["ak", "ak", "pkm", "ak", "rpg", "ak"], "morale": 60.0, "smoke": 1},
	"ru_bmp2": {"name": "BMP-2", "vehicle": true, "mesh": "bmp2", "weapons": ["cannon30", "coax"], "armor": [35.0, 18.0, 12.0], "speed": 8.0, "crew": 3, "morale": 60.0},
	"ru_t72": {"name": "T-72B3", "vehicle": true, "mesh": "t72", "weapons": ["gun125", "coax"], "armor": [600.0, 110.0, 40.0], "speed": 7.0, "crew": 3, "morale": 70.0, "cage": true},
	"ru_mtlb": {"name": "MT-LB", "vehicle": true, "mesh": "mtlb", "weapons": ["coax"], "armor": [12.0, 10.0, 8.0], "speed": 9.0, "crew": 2, "morale": 55.0},
}

## Indirect fire (GDD §3.7b/§7). Each entry: rounds per fire mission, delay (s) to the
## first impact, spacing (s) between rounds, scatter (m) around the aim point, and the
## blast itself: radius (m), lethal (hit chance per man at the centre, scaled down by
## distance, cover and posture), supp (suppression at the centre, felt out to 3×radius,
## so a near miss within ~10 m pins a squad), pen (top-attack armour penetration) and
## struct (wall hit points at the centre; a brick wall has 130).
## Tuned so that six rounds on a squad in the open are usually crippling, six on a
## trench still cost a man or two and pin the rest; the prep barrage is a notch below
## (it is the opening act, not the decider) and spread over a band, not a point.
const ARTILLERY := {
	"mortar": {"rounds": 6, "delay": 10.0, "spacing": 0.9, "scatter": 9.0, "radius": 8.0, "lethal": 0.75, "supp": 60.0, "pen": 25.0, "struct": 90.0},
	"ru_arty": {"rounds": 6, "delay": 8.0, "spacing": 1.3, "scatter": 14.0, "radius": 9.0, "lethal": 0.70, "supp": 65.0, "pen": 45.0, "struct": 220.0},
	"prep": {"spacing": 1.4, "radius": 8.0, "lethal": 0.50, "supp": 50.0, "pen": 40.0, "struct": 180.0},
}
