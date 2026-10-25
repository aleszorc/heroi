class_name Defs
extends RefCounted
## Static game data: weapons and unit templates.

## Infantry movement speeds in m/s.
const WALK := 2.2
const RUN := 4.0
const CRAWL := 1.0

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
