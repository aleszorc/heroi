class_name CameraRig
extends Node3D
## Orthographic isometric camera: drag to pan, pinch or wheel to zoom, 90-degree rotation steps.
## The rig sits on the ground point the camera looks at.

const PITCH := 0.663  # 38 degrees down
const DISTANCE := 150.0
const MIN_ZOOM := 12.0
const MAX_ZOOM := 170.0
const LIMIT := 118.0

var cam: Camera3D
var zoom := 55.0
var _yaw := PI / 4.0
var _target_yaw := PI / 4.0
var _target_pos := Vector3.ZERO


func _ready() -> void:
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = zoom
	cam.near = 1.0
	cam.far = 600.0
	cam.position = Vector3(0.0, sin(PITCH), cos(PITCH)) * DISTANCE
	cam.rotation = Vector3(-PITCH, 0.0, 0.0)
	add_child(cam)
	cam.current = true
	rotation.y = _yaw


func _process(delta: float) -> void:
	var k := 1.0 - exp(-delta * 12.0)
	_yaw = lerp_angle(_yaw, _target_yaw, k)
	rotation.y = _yaw
	cam.size = lerpf(cam.size, zoom, k)
	var keys := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if keys != Vector2.ZERO:
		var right := global_transform.basis.x
		var fwd := -global_transform.basis.z
		_target_pos += (right * keys.x - fwd * keys.y) * zoom * 0.9 * delta
		_clamp()
	position = position.lerp(_target_pos, 1.0 - exp(-delta * 16.0))


## Moves the view so the ground follows the finger.
func pan(screen_delta: Vector2) -> void:
	var mpp := cam.size / get_viewport().get_visible_rect().size.y
	var right := global_transform.basis.x
	var fwd := -global_transform.basis.z
	_target_pos += (-right * screen_delta.x + fwd * screen_delta.y / sin(PITCH)) * mpp
	_clamp()
	position = _target_pos


func zoom_by(factor: float) -> void:
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)


func rotate_step(dir: int) -> void:
	_target_yaw += dir * PI / 2.0


func focus(p: Vector3) -> void:
	_target_pos = Vector3(p.x, 0.0, p.z)
	_clamp()


func focus_now(p: Vector3) -> void:
	focus(p)
	position = _target_pos


func screen_to_ground(sp: Vector2) -> Vector3:
	var o := cam.project_ray_origin(sp)
	var n := cam.project_ray_normal(sp)
	if absf(n.y) < 0.0001:
		return Vector3.ZERO
	return o + n * (-o.y / n.y)


func _clamp() -> void:
	_target_pos.x = clampf(_target_pos.x, -LIMIT, LIMIT)
	_target_pos.z = clampf(_target_pos.z, -LIMIT, LIMIT)
