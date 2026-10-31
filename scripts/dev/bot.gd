extends Node
## Scripted "competent player" for the headless balance harness: `-- autostart bot`.
## Issues the same orders and support calls the player UI would (unit.order_move,
## Support.call_mortar/launch_fpv/launch_bomber), on a slow decision tick, and only
## ever acts on enemies the UA side has actually spotted — the same no-cheating rule
## the enemy AI follows. Thresholds here are dev-harness tuning, not combat balance
## (balance numbers live in Defs).

const TICK := 2.5                # s of sim time between decisions
const CLUSTER_MEN := 4           # spotted enemy infantrymen that justify a mortar mission
const CLUSTER_RADIUS := 25.0     # m grouping radius for that cluster
const MORTAR_COOLDOWN := 45.0    # s between mortar missions
const DANGER_CLOSE := 15.0       # m: no mortar aim this close to friendlies
const SNIPER_THREAT := 80.0      # m: a spotted enemy this close pushes the sniper back
const SNIPER_FALLBACK := 35.0    # m fallback distance toward the friendly edge
const ADVANCE_NEAR := 14.0       # m: close enough to an objective to stop ordering
const ADVANCE_HOP := 50.0        # m: advance bound length (cover to cover)
const ADVANCE_CALM := 25.0       # suppression above which a halted unit is left to recover
const ADVANCE_DWELL := 8.0       # s spent fighting from cover between bounds while in contact
const BOMBER_MIN_COVER := 0.3    # bomber targets dug-in infantry, not men in the open

var battle: Battle
var _acc := 0.0
var _mortar_at := -999.0
var _fpv_sent := {}   # Unit -> true: vehicles already given an FPV
var _bombed := {}     # Unit -> true: infantry already given the bomber
var _dwell := {}      # Unit -> sim time its next advance bound is allowed
var _log := false


func _ready() -> void:
	_log = Game.has_arg("log")


func _process(delta: float) -> void:
	if battle == null or battle.phase != Battle.Phase.BATTLE:
		return
	_acc += Game.sim_delta(delta)
	if _acc < TICK:
		return
	_acc = 0.0
	var spotted := _spotted()
	_mortar(spotted)
	_fpv(spotted)
	_bomber(spotted)
	_sniper(spotted)
	_advance()


## Enemies the UA side can see right now (same test the HUD's FPV/bomber taps use).
func _spotted() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in battle.units:
		if u.side == Game.RU and u.is_targetable() and u.seen[Game.UA]:
			out.append(u)
	return out


## One mortar mission on the densest cluster of >= CLUSTER_MEN spotted infantrymen.
func _mortar(spotted: Array[Unit]) -> void:
	if battle.support.mortar_left <= 0 or battle.time - _mortar_at < MORTAR_COOLDOWN:
		return
	var best_men := 0
	var best_aim := Vector3.ZERO
	for anchor in spotted:
		# Shells take ~10 s to land (Defs.ARTILLERY): only clusters anchored on a
		# halted unit are worth a mission, a column on the march walks out from under.
		if anchor.is_vehicle or not anchor.arrived:
			continue
		var men := 0
		var centroid := Vector3.ZERO
		for u in spotted:
			if not u.is_vehicle and u.known_pos[Game.UA].distance_to(anchor.known_pos[Game.UA]) < CLUSTER_RADIUS:
				men += u.alive_count()
				centroid += u.known_pos[Game.UA] * u.alive_count()
		if men > best_men:
			best_men = men
			best_aim = centroid / men
	if best_men < CLUSTER_MEN:
		return
	for u in battle.units:
		if u.side == Game.UA and u.is_effective() and u.position.distance_to(best_aim) < DANGER_CLOSE:
			return
	if battle.support.call_mortar(best_aim):
		_mortar_at = battle.time
		if _log:
			print("[%s] BOT mortar: %d men clustered at (%d, %d)" % [Battle.clock_text(battle.time), best_men, int(best_aim.x), int(best_aim.z)])


## FPV every spotted vehicle once, tanks first.
func _fpv(spotted: Array[Unit]) -> void:
	if not battle.support.can_fpv():
		return
	var best: Unit = null
	for u in spotted:
		if not u.is_vehicle or _fpv_sent.has(u):
			continue
		if best == null or (u.def_id == "ru_t72" and best.def_id != "ru_t72"):
			best = u
	if best != null and battle.support.launch_fpv(best):
		_fpv_sent[best] = true
		if _log:
			print("[%s] BOT FPV at %s" % [Battle.clock_text(battle.time), best.display_name])


## One bomber run per stationary spotted infantry unit sitting in cover.
func _bomber(spotted: Array[Unit]) -> void:
	if not battle.support.can_bomber():
		return
	for u in spotted:
		if u.is_vehicle or _bombed.has(u) or not u.arrived or u.cover_here() < BOMBER_MIN_COVER:
			continue
		if battle.support.launch_bomber(u):
			_bombed[u] = true
			if _log:
				print("[%s] BOT bomber at %s" % [Battle.clock_text(battle.time), u.display_name])
		return


## Pull the sniper team back when spotted enemies close in: away from the nearest
## threat, biased toward the friendly (south) edge, into the best shielded cover.
func _sniper(spotted: Array[Unit]) -> void:
	for s in battle.units:
		if s.side != Game.UA or s.def_id != "ua_sniper" or not s.is_effective():
			continue
		if not s.arrived or not s.can_move():
			return
		var threat: Unit = null
		var best_d := SNIPER_THREAT
		for u in spotted:
			var d := u.known_pos[Game.UA].distance_to(s.position)
			if d < best_d:
				best_d = d
				threat = u
		if threat == null:
			return
		var tp: Vector3 = threat.known_pos[Game.UA]
		var away := Vector3(s.position.x - tp.x, 0.0, s.position.z - tp.z).normalized()
		var dir := (away + Vector3(0.0, 0.0, 0.7)).normalized()
		var dest := s.position + dir * SNIPER_FALLBACK
		dest.x = clampf(dest.x, -BattleMap.HALF + 4.0, BattleMap.HALF - 4.0)
		dest.z = clampf(dest.z, -BattleMap.HALF + 4.0, BattleMap.HALF - 4.0)
		if s.order_move(battle.map.best_cover_near(dest, 6, {}, tp)) and _log:
			print("[%s] BOT sniper falls back from %s" % [Battle.clock_text(battle.time), threat.display_name])
		return


## Push idle units at the nearest objective we do not hold. Only in the kinds where
## the player must take ground — on defend the line holds its posts; stripping one
## flank to counter-attack across the map loses more than the flag is worth.
func _advance() -> void:
	if String(battle.mission.get("kind", "")) == "defend":
		return
	var goals: Array[VictoryLocation] = []
	for vl in battle.vls:
		if vl.owner_side != Game.UA:
			goals.append(vl)
	if goals.is_empty():
		return
	# Mass on one objective instead of attacking everywhere piecemeal: the
	# uncaptured location closest to the platoon as a whole.
	var centroid := Vector3.ZERO
	var n := 0
	for u in battle.units:
		if u.side == Game.UA and u.is_effective():
			centroid += u.position
			n += 1
	if n == 0:
		return
	centroid /= n
	var focus: VictoryLocation = goals[0]
	for g in goals:
		if g.position.distance_to(centroid) < focus.position.distance_to(centroid):
			focus = g
	var taken := {}
	for u in battle.units:
		if u.side != Game.UA or not u.arrived or not u.can_move() or u.def.get("drones", false):
			continue
		# A unit that halted under fire is left alone to fight and recover in cover;
		# re-ordering it every tick is the death march, not the bound.
		if u.suppression > ADVANCE_CALM or u.state != Unit.State.OK:
			continue
		if u.def_id == "ua_sniper" and not _sniper_safe(u):
			continue
		var vl := focus
		var to := Vector3(vl.position.x - u.position.x, 0.0, vl.position.z - u.position.z)
		if to.length() <= ADVANCE_NEAR:
			continue
		# In contact, fight from this cover for a while before the next bound
		# (fire-then-bound, the same rhythm the enemy AI uses).
		if not _dwell.has(u):
			_dwell[u] = battle.time + (ADVANCE_DWELL if u.known_enemy_distance() < Unit.CONTACT_RANGE else 0.0)
		if battle.time < float(_dwell[u]):
			continue
		_dwell.erase(u)
		# Bound cover to cover: one hop toward the objective, the last hop onto it.
		var dest := vl.position if to.length() <= ADVANCE_HOP else u.position + to * (ADVANCE_HOP / to.length())
		if not u.is_vehicle:
			dest = battle.map.best_cover_near(dest, 5, taken)
		if u.order_move(dest) and _log:
			print("[%s] BOT %s -> %s" % [Battle.clock_text(battle.time), u.display_name, vl.loc_name])


func _sniper_safe(s: Unit) -> bool:
	for u in battle.units:
		if u.side == Game.RU and u.is_targetable() and u.seen[Game.UA] \
				and u.known_pos[Game.UA].distance_to(s.position) < SNIPER_THREAT:
			return false
	return true
