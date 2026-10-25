class_name MissionTreeline
extends RefCounted
## "Treeline 7": a reinforced Ukrainian platoon holds a posadka, a farm and a crossroads
## against a mechanized assault in four waves. Places and units are fictional.
## Coordinates are world metres: -Z is north (enemy side), +Z is south (our rear).

const T := BattleMap.T


static func build() -> Dictionary:
	return {
		"kind": "defend",
		"seed": 0,
		"title": "TREELINE 7",
		"briefing": "Zaporizhzhia direction, autumn. Your platoon holds a shell-torn treeline, a ruined farm and the crossroads behind them. Drone recon reports armour massing to the north. Hold at least two of the three positions for 12 minutes.\n\nTrees and trenches hide you; firing and moving give you away. Enemy FPV drones hunt anything they can see.",
		"time_limit": 720.0,
		"paint": func(map: BattleMap) -> void: _paint(map),
		"deploy": Rect2(-118.0, -36.0, 236.0, 154.0),
		"vls": [
			["Posadka", Vector3(-20.0, 0.0, 22.0), Game.UA],
			["Farm", Vector3(63.0, 0.0, -14.0), Game.UA],
			["Crossroads", Vector3(-62.0, 0.0, 0.0), Game.UA],
		],
		"ua_units": [
			["ua_rifle", "1st Squad", Vector3(-30.0, 0.0, 24.0)],
			["ua_mg", "MG Team", Vector3(-8.0, 0.0, 24.0)],
			["ua_atgm", "Stugna", Vector3(38.0, 0.0, 24.0)],
			["ua_rifle", "2nd Squad", Vector3(62.0, 0.0, -8.0)],
			["ua_sniper", "Sniper", Vector3(72.0, 0.0, -21.0)],
			["ua_rifle", "3rd Squad", Vector3(-56.0, 0.0, -8.0)],
			["ua_drone", "Drone Team", Vector3(-56.0, 0.0, 56.0)],
			["ua_bradley", "Bradley", Vector3(5.0, 0.0, 45.0)],
		],
		# [rect (x, z, width, depth) on even metres so walls sit on cell edges, ruin 0..1, seed, brick]
		"buildings": [
			[Rect2(50, -24, 8, 8), 0.5, 1, true],
			[Rect2(68, -26, 8, 8), 0.2, 2, false],
			[Rect2(54, -12, 16, 8), 0.4, 3, true],
			[Rect2(-60, -12, 10, 8), 0.5, 4, false],
			[Rect2(-84, 44, 8, 8), 0.1, 5, false],
			[Rect2(-60, 52, 8, 8), 0.3, 6, true],
			[Rect2(-86, 72, 10, 8), 0.0, 7, false],
			[Rect2(-58, 84, 8, 8), 0.4, 8, false],
			[Rect2(-82, 96, 8, 8), 0.0, 9, true],
		],

		# Burnt-out hulks from earlier assaults: cover in no-man's land.
		"wrecks": [
			["bmp2", Vector3(8.0, 0.0, -35.0), 0.6],
			["t72", Vector3(-45.0, 0.0, -55.0), -0.4],
			["mtlb", Vector3(80.0, 0.0, -55.0), 2.2],
		],
		"poles": [Vector3(-76, 0, -100), Vector3(-76, 0, -70), Vector3(-76, 0, -40), Vector3(-76, 0, 30), Vector3(-76, 0, 60), Vector3(-76, 0, 90)],
		"waves": [
			{"time": 25.0, "spawn": Vector3(-35, 0, -110), "msg": "Enemy mechanized assault from the north!",
				"route": [Vector3(-35, 0, -85), Vector3(-30, 0, -40), Vector3(-25, 0, 0), Vector3(-20, 0, 20)],
				"units": [["ru_bmp2", "BMP-2", Vector3(0, 0, 0)], ["ru_assault", "Assault 1", Vector3(-14, 0, 6)], ["ru_assault", "Assault 2", Vector3(14, 0, 6)]]},
			{"time": 150.0, "spawn": Vector3(65, 0, -110), "msg": "Enemy moving on the farm!",
				"route": [Vector3(40, 0, -80), Vector3(34, 0, -45), Vector3(45, 0, -28), Vector3(62, 0, -14)],
				"units": [["ru_mtlb", "MT-LB", Vector3(0, 0, 0)], ["ru_assault", "Assault 3", Vector3(-12, 0, 6)], ["ru_assault", "Assault 4", Vector3(12, 0, 6)]]},
			{"time": 300.0, "spawn": Vector3(99, 0, -110), "msg": "Tank reported in the eastern gully!",
				"route": [Vector3(99, 0, -60), Vector3(99, 0, -10), Vector3(80, 0, 6), Vector3(50, 0, 22)],
				"units": [["ru_t72", "T-72B3", Vector3(0, 0, 0)], ["ru_assault", "Assault 5", Vector3(-6, 0, 10)]]},
			{"time": 450.0, "spawn": Vector3(-10, 0, -110), "msg": "Large infantry assault forming up!",
				"route": [Vector3(-10, 0, -80), Vector3(-40, 0, -30), Vector3(-58, 0, -6), Vector3(-62, 0, 0)],
				"units": [["ru_bmp2", "BMP-2", Vector3(0, 0, 0)], ["ru_assault", "Assault 6", Vector3(-20, 0, 6)], ["ru_assault", "Assault 7", Vector3(0, 0, 10)], ["ru_assault", "Assault 8", Vector3(20, 0, 6)]]},
		],
	}


static func _paint(map: BattleMap) -> void:
	# Fields
	map.paint_rect(-110, -110, -20, -40, T.FIELD)
	map.paint_rect(10, -110, 110, -50, T.FIELD)
	map.paint_rect(-20, 40, 110, 110, T.FIELD)
	# Treelines (posadky): ours, theirs, a north-south one towards the farm, a grove
	map.paint_rect(-112, 16, 104, 26, T.TREES)
	map.paint_rect(16, 16, 24, 26, T.OPEN)
	map.paint_rect(-104, -80, 110, -71, T.TREES)
	map.paint_rect(28, -62, 35, -12, T.TREES)
	map.paint_disc(Vector2(-95, -25), 9.0, T.TREES)
	# Eastern gully
	map.paint_line(Vector2(99, -120), Vector2(97, 45), 8.0, T.GULLY)
	# Roads
	map.paint_line(Vector2(-71, -120), Vector2(-67, 120), 5.0, T.ROAD)
	map.paint_line(Vector2(-120, 1), Vector2(120, -3), 5.0, T.ROAD)
	# Trenches behind our treeline, communication trenches and the farm trench
	map.paint_line(Vector2(-60, 29), Vector2(12, 29), 2.0, T.TRENCH)
	map.paint_line(Vector2(30, 29), Vector2(85, 29), 2.0, T.TRENCH)
	map.paint_line(Vector2(-20, 29), Vector2(-20, 45), 2.0, T.TRENCH)
	map.paint_line(Vector2(50, 29), Vector2(50, 40), 2.0, T.TRENCH)
	map.paint_line(Vector2(48, -30), Vector2(78, -30), 2.0, T.TRENCH)
	# Farm rubble
	map.paint_disc(Vector2(64, -19), 3.0, T.RUBBLE)
	# Shell craters, thickest in no-man's land
	var rng := RandomNumberGenerator.new()
	rng.seed = 2023
	var soft := [T.OPEN, T.FIELD, T.ROAD]
	for i in 80:
		var c := Vector2(rng.randf_range(-110, 110), rng.randf_range(-68, 12))
		map.paint_disc(c, rng.randf_range(1.0, 2.5), T.CRATER, soft)
	for i in 20:
		var c := Vector2(rng.randf_range(-100, 95), rng.randf_range(8, 40))
		map.paint_disc(c, rng.randf_range(1.0, 2.0), T.CRATER, soft + [T.TREES])
