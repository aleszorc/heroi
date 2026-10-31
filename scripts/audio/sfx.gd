class_name Sfx
extends Node3D
## Sound effects, the audio sibling of Fx. One-shots (shots, blasts, cracks) play through a
## pool of positional players; drones and vehicles get looping players attached by polling
## the battle each frame, so the sim scripts never manage audio state themselves.
## Respects Game.paused via stream_paused; the field ambience keeps playing while paused.

const S_AK: Array[AudioStream] = [
	preload("res://assets/audio/shot_ak_1.wav"),
	preload("res://assets/audio/shot_ak_2.wav"),
	preload("res://assets/audio/shot_ak_3.wav"),
	preload("res://assets/audio/shot_ak_4.wav"),
]
const S_MG: Array[AudioStream] = [
	preload("res://assets/audio/burst_mg_1.wav"),
	preload("res://assets/audio/burst_mg_2.wav"),
]
const S_SNIPER: Array[AudioStream] = [
	preload("res://assets/audio/shot_sniper_1.wav"),
	preload("res://assets/audio/shot_sniper_2.wav"),
]
const S_CANNON := preload("res://assets/audio/shot_cannon.wav")
const S_GUN125 := preload("res://assets/audio/shot_gun125.wav")
const S_RPG := preload("res://assets/audio/rpg_launch.wav")
const S_EXPL_BIG := preload("res://assets/audio/expl_big.wav")
const S_EXPL_FAR := preload("res://assets/audio/expl_far.wav")
const S_CRACK := preload("res://assets/audio/crack.wav")
const S_WHISTLE: Array[AudioStream] = [
	preload("res://assets/audio/whistle_1.wav"),
	preload("res://assets/audio/whistle_2.wav"),
	preload("res://assets/audio/whistle_3.wav"),
	preload("res://assets/audio/whistle_4.wav"),
]
const S_COLLAPSE := preload("res://assets/audio/collapse.wav")
const S_TICK := preload("res://assets/audio/ui_tick.wav")
const S_DISTANT: Array[AudioStream] = [
	preload("res://assets/audio/distant_battle.wav"),
	preload("res://assets/audio/arty_out.wav"),
]
const L_ENGINE := preload("res://assets/audio/engine_loop.mp3")
const L_FPV := preload("res://assets/audio/drone_fpv_loop.mp3")
const L_RECON := preload("res://assets/audio/drone_recon_loop.mp3")
const L_HEAVY := preload("res://assets/audio/drone_heavy_loop.mp3")
const L_AMBIENCE := preload("res://assets/audio/ambience_field.mp3")

const POOL_SIZE := 24

var battle: Battle
var _pool: Array[AudioStreamPlayer3D] = []
var _pool_i := 0
## Looping players keyed by the followed node's instance id: {player, kind}.
var _loops := {}
var _ambience: AudioStreamPlayer
var _ui: AudioStreamPlayer
var _was_paused := true
var _distant_in := 12.0


func _ready() -> void:
	for m: AudioStream in [L_ENGINE, L_FPV, L_RECON, L_HEAVY, L_AMBIENCE]:
		m.loop = true
	for i in POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.max_polyphony = 1
		add_child(p)
		_pool.append(p)
	_ambience = AudioStreamPlayer.new()
	_ambience.stream = L_AMBIENCE
	_ambience.volume_db = -16.0
	_ambience.autoplay = true
	add_child(_ambience)
	_ui = AudioStreamPlayer.new()
	_ui.stream = S_TICK
	_ui.volume_db = -12.0
	add_child(_ui)


## Playbacks alive at engine shutdown are reported as leaks; stop everything on the way out.
func _exit_tree() -> void:
	if is_instance_valid(_ambience):
		_ambience.stop()
	if is_instance_valid(_ui):
		_ui.stop()
	for p in _pool:
		if is_instance_valid(p):
			p.stop()
	for e: Dictionary in _loops.values():
		var lp: Variant = e["player"]
		if is_instance_valid(lp):
			lp.stop()


# --- One-shot events (called from the sim) ---

func shot(from: Vector3, wid: String) -> void:
	match wid:
		"ak":
			_play(S_AK.pick_random(), from, -2.0, 18.0)
		"pkm", "coax":
			_play(S_MG.pick_random(), from, 0.0, 22.0)
		"sniper":
			_play(S_SNIPER.pick_random(), from, 0.0, 24.0)
		"cannon25", "cannon30":
			_play(S_CANNON, from, 2.0, 30.0)
		"gun125":
			_play(S_GUN125, from, 5.0, 45.0)
		"rpg", "stugna", "tow":
			_play(S_RPG, from, 1.0, 26.0)


func explosion(pos: Vector3, size: float) -> void:
	if size >= 1.4:
		_play(S_EXPL_BIG, pos, clampf(-4.0 + size * 3.0, -4.0, 6.0), 40.0, 0.92, 1.08)
	else:
		# Small blasts reuse the muffled distant explosion, pitched up.
		_play(S_EXPL_FAR, pos, -2.0 + size * 3.0, 26.0, 1.15, 1.35)


## The snap of a round passing; played for a share of bullet impacts near the fight.
func bullet_crack(pos: Vector3) -> void:
	if randf() < 0.35:
		_play(S_CRACK, pos, -4.0, 12.0, 0.9, 1.15)


## The ~0.9 s incoming rush (trimmed to end just before the source recording's own
## explosion, so the game's blast is the only boom); Support schedules it so the
## sample ends as the shell lands.
func shell_whistle(pos: Vector3) -> void:
	_play(S_WHISTLE.pick_random(), pos + Vector3.UP * 20.0, -1.0, 40.0, 0.95, 1.08)


## A bomber bomb's fall: the same rush, but smaller, higher-pitched (~0.75 s at 1.2x)
## and local to the drop. The bomber schedules it so the tail meets the impact.
func bomb_whistle(pos: Vector3) -> void:
	_play(S_WHISTLE.pick_random(), pos + Vector3.UP * 10.0, -9.0, 22.0, 1.15, 1.3)


func collapse(pos: Vector3) -> void:
	_play(S_COLLAPSE, pos, 4.0, 35.0, 0.9, 1.05)


func ui_tick() -> void:
	_ui.play()


func _play(stream: AudioStream, pos: Vector3, db: float, unit_size: float,
		pitch_lo := 0.94, pitch_hi := 1.06) -> void:
	if Game.paused:
		return
	var p := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % POOL_SIZE
	p.stop()
	p.stream = stream
	p.volume_db = db
	p.unit_size = unit_size
	p.pitch_scale = randf_range(pitch_lo, pitch_hi)
	p.global_position = pos
	p.play()


# --- Loops and ambience ---

func _process(delta: float) -> void:
	if Game.paused != _was_paused:
		_was_paused = Game.paused
		for p in _pool:
			p.stream_paused = Game.paused
		for e: Dictionary in _loops.values():
			(e["player"] as AudioStreamPlayer3D).stream_paused = Game.paused
	if battle == null or Game.paused:
		return
	_sync_loops()
	_distant_in -= delta
	if _distant_in <= 0.0:
		_distant_in = randf_range(25.0, 55.0)
		# A far-off exchange somewhere beyond the Russian map edge.
		var pos := Vector3(randf_range(-100.0, 100.0), 12.0, -BattleMap.HALF - 40.0)
		_play(S_DISTANT.pick_random(), pos, 2.0, 60.0, 0.9, 1.1)


## Attach/detach looping players by looking at what exists in the battle right now.
func _sync_loops() -> void:
	var seen := {}
	for d in battle.drones:
		seen[d.get_instance_id()] = true
		var e: Dictionary = _loops.get(d.get_instance_id(), {})
		if e.is_empty():
			var stream: AudioStream = L_RECON
			var db := -9.0
			var unit := 10.0
			if d.fpv:
				stream = L_FPV
				db = -6.0
			elif d.get("heavy"):  # the bomber; get() so Sfx needs no Drone version coupling
				stream = L_HEAVY
				db = -3.0
				unit = 16.0
			e = {"player": _attach_loop(d, stream, db, unit)}
			_loops[d.get_instance_id()] = e
		if d.fpv:
			var p: AudioStreamPlayer3D = e["player"]
			p.pitch_scale = move_toward(p.pitch_scale, 1.3 if d._committed else 1.0,
					get_process_delta_time() * 0.6)
	for u in battle.units:
		if not (u is VehicleUnit):
			continue
		var v := u as VehicleUnit
		if v.state == Unit.State.DESTROYED:
			continue
		seen[v.get_instance_id()] = true
		var e: Dictionary = _loops.get(v.get_instance_id(), {})
		if e.is_empty():
			e = {"player": _attach_loop(v, L_ENGINE, -12.0, 12.0)}
			_loops[v.get_instance_id()] = e
		var p: AudioStreamPlayer3D = e["player"]
		var load_f := clampf(absf(v.speed_now) / 7.0, 0.0, 1.0)
		p.volume_db = lerpf(-12.0, -5.0, load_f)
		p.pitch_scale = lerpf(0.85, 1.25, load_f)
	# Nodes gone (drone finished, vehicle destroyed): drop their players.
	for id: int in _loops.keys():
		if not seen.has(id):
			var p: AudioStreamPlayer3D = _loops[id]["player"]
			if is_instance_valid(p):
				p.queue_free()
			_loops.erase(id)


func _attach_loop(node: Node3D, stream: AudioStream, db: float, unit_size: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.volume_db = db
	p.unit_size = unit_size
	p.pitch_scale = randf_range(0.96, 1.04)
	node.add_child(p)
	p.play(randf() * 3.0)
	return p
