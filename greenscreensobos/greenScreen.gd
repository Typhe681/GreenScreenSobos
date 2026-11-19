extends Node

const MEDIA_DIR := "user://greenscreensobos/"
const CFG := "user://greenscreensobos.cfg"
const IMAGE_EXTENSIONS := ["png", "jpg"]
const VIDEO_EXTENSIONS := ["ogv"]

var video_player: VideoStreamPlayer
var image_texture: Texture2D
var shader: Shader
var is_video := false
var was_in_game := false
var patched_sobos: Dictionary = {}
var original_materials: Dictionary = {}
var bumper_alarms: Array[AudioStreamPlayer2D] = []
var bumper_alarm_scene: Node

var broadcaster_connected := false
var mod_enabled := true
var audio_enabled := true
var per_sobo := false

const SHADER_CODE := """
shader_type canvas_item;

uniform sampler2D sobo_texture;
uniform vec2 image_size;
uniform vec2 view_center;
uniform vec2 view_size;
uniform bool flipped_screen;
uniform bool per_sobo = false;
uniform vec2 sobo_center;
uniform vec2 sobo_bounds_size;
uniform float sobo_rotation;

varying vec2 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 uv;

	if (per_sobo) {
		vec2 local_position = world_position - sobo_center;
	
		if (flipped_screen) {
			local_position = -local_position;
		}
	
		float c = cos(-sobo_rotation);
		float s = sin(-sobo_rotation);
		local_position = mat2(vec2(c, -s), vec2(s, c)) * local_position;
	
		vec2 rotated_bounds = vec2(
			abs(c) * sobo_bounds_size.x + abs(s) * sobo_bounds_size.y,
			abs(s) * sobo_bounds_size.x + abs(c) * sobo_bounds_size.y
		);
	
		float scale = max(
			rotated_bounds.x / image_size.x,
			rotated_bounds.y / image_size.y
		);
	
		uv = local_position / (image_size * scale) + vec2(0.5);
	} else {
		float scale = max(
			view_size.x / image_size.x,
			view_size.y / image_size.y
		);

		vec2 sample_position = world_position;

		if (flipped_screen) {
			sample_position = view_center * 2.0 - sample_position;
		}

		uv = (sample_position - view_center) / (image_size * scale) + vec2(0.5);
	}

	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		discard;
	}
	COLOR = texture(sobo_texture, uv);
}
"""

func _ready() -> void:
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS

	load_config()
	try_connect_broadcaster()
	load_media()


func load_config() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG)

	mod_enabled = cf.get_value("mod_enabled", "value",
		cf.get_value("greenScreen", "mod_enabled", true))
	audio_enabled = cf.get_value("audio_enabled", "value",
		cf.get_value("greenScreen", "audio_enabled", true))
	per_sobo = cf.get_value("per_sobo", "value",
		cf.get_value("greenScreen", "per_sobo", false))

	write_config()

func write_config() -> void:
	var cf := ConfigFile.new()

	cf.set_value("meta", "name", "GreenScreenSobos")
	cf.set_value("meta", "description", "Configure GreenScreenSobos")

	cf.set_value("open_folder", "type", "action")
	cf.set_value("open_folder", "label", "open media folder")
	cf.set_value("open_folder", "description", "opens the folder where you place png/jpg/ogv files for the mod to use")

	cf.set_value("refresh_media", "type", "action")
	cf.set_value("refresh_media", "label", "refresh media")
	cf.set_value("refresh_media", "description", "randomly selects a file from the folder again")

	cf.set_value("mod_enabled", "type", "bool")
	cf.set_value("mod_enabled", "label", "enable mod")
	cf.set_value("mod_enabled", "description", "enable/disable the shader effects")
	cf.set_value("mod_enabled", "value", mod_enabled)

	cf.set_value("audio_enabled", "type", "bool")
	cf.set_value("audio_enabled", "label", "video audio")
	cf.set_value("audio_enabled", "description", "play audio from the background video")
	cf.set_value("audio_enabled", "value", audio_enabled)

	cf.set_value("per_sobo", "type", "bool")
	cf.set_value("per_sobo", "label", "per sobo greenscreen")
	cf.set_value("per_sobo", "description", "display the media file on every individual sobo")
	cf.set_value("per_sobo", "value", per_sobo)

	cf.save(CFG)

func try_connect_broadcaster() -> void:
	if broadcaster_connected:
		return
	var broadcaster = get_tree().root.get_meta("modsettings_broadcaster", null)
	if broadcaster:
		broadcaster.config_changed.connect(on_config_changed)
		if broadcaster.has_signal("action_triggered"):
			broadcaster.action_triggered.connect(on_action_triggered)
		broadcaster_connected = true

func on_config_changed(path: String, section: String, value: Variant) -> void:
	if path.get_file() != CFG.get_file():
		return

	match section:
		"mod_enabled":
			mod_enabled = value
			if is_video and is_instance_valid(video_player):
				if mod_enabled:
					video_player.play()
				else:
					video_player.stop()
		"audio_enabled":
			audio_enabled = value
			if is_instance_valid(video_player):
				video_player.volume_db = 0.0 if audio_enabled else -80.0
		"per_sobo":
			per_sobo = value
			for mat: ShaderMaterial in patched_sobos.values():
				mat.set_shader_parameter("per_sobo", per_sobo)

func on_action_triggered(path: String, section: String) -> void:
	if path.get_file() != CFG.get_file():
		return

	match section:
		"open_folder":
			open_media_folder()
		"refresh_media":
			refresh_media()

func open_media_folder() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(MEDIA_DIR)
	)
	OS.shell_show_in_file_manager(
		ProjectSettings.globalize_path(MEDIA_DIR),
		true
	)

func load_media() -> void:
	clear_patched_sobos()

	if is_instance_valid(video_player):
		video_player.queue_free()
	video_player = null
	image_texture = null
	is_video = false

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(MEDIA_DIR)
	)

	var media_path := find_media()
	if media_path.is_empty():
		push_warning("GreenScreenSobos: No supported media found in " + MEDIA_DIR)
		return

	var extension := media_path.get_extension().to_lower()
	is_video = extension in VIDEO_EXTENSIONS

	if is_video:
		var stream := load(media_path) as VideoStream
		if stream == null:
			is_video = false
			push_error("GreenScreenSobos: Failed to load video: " + media_path)
			return

		video_player = VideoStreamPlayer.new()
		video_player.stream = stream
		video_player.loop = true
		video_player.autoplay = false
		video_player.expand = true
		video_player.process_mode = Node.PROCESS_MODE_ALWAYS
		video_player.volume_db = 0.0 if audio_enabled else -80.0
		add_child(video_player)

		if mod_enabled and was_in_game:
			video_player.play()
	else:
		var image := Image.load_from_file(media_path)
		if image == null or image.is_empty():
			push_error("GreenScreenSobos: Failed to load image: " + media_path)
			return
		image_texture = ImageTexture.create_from_image(image)

	if shader == null:
		shader = Shader.new()
		shader.code = SHADER_CODE

func refresh_media() -> void:
	load_media()
	if is_video and is_instance_valid(video_player):
		video_player.paused = false
		await RenderingServer.frame_post_draw
		video_player.paused = true
	_process(0.0)

func find_media() -> String:
	var dir := DirAccess.open(MEDIA_DIR)
	if dir == null:
		push_error("GreenScreenSobos: Could not open media folder: " + MEDIA_DIR)
		return ""

	var files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir():
			var extension := file_name.get_extension().to_lower()
			if extension in IMAGE_EXTENSIONS or extension in VIDEO_EXTENSIONS:
				files.append(MEDIA_DIR + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	files.sort()
	if files.is_empty():
		return ""
	return files.pick_random() # lets go gambling!!

func get_sobo_local_bounds(sobo: Sobo) -> Dictionary:
	var points = sobo.get_draw_polygon_points()
	if points.is_empty():
		return {"center": sobo.get_visual_center(), "size": Vector2.ZERO}

	var min_point: Vector2 = points[0]
	var max_point: Vector2 = points[0]

	for point: Vector2 in points:
		min_point = min_point.min(point)
		max_point = max_point.max(point)

	var rect := Rect2(min_point, max_point - min_point).grow(10.0)

	return {
		"center": rect.get_center(),
		"size": rect.size
	}

func _process(_delta: float) -> void:
	try_connect_broadcaster()

	var scene = GameModeManager.current_scene
	if scene is SceneSuika:
		clear_patched_sobos()
		if is_video and is_instance_valid(video_player):
			video_player.stop()
		return

	var in_game := scene != null
	if in_game and not was_in_game:
		if is_video and mod_enabled and is_instance_valid(video_player):
			video_player.stop()
			video_player.play()
	elif not in_game and was_in_game:
		if is_video and is_instance_valid(video_player):
			video_player.stop()
		clear_patched_sobos()
	was_in_game = in_game
	
	if is_video and is_instance_valid(video_player):
		video_player.paused = get_tree().paused
		
	update_bumper_alarm(scene)
	if not mod_enabled:
		clear_patched_sobos()
		return

	if not in_game:
		return

	if scene.world_play_area == null:
		return

	var media_texture: Texture2D

	if is_video:
		if not is_instance_valid(video_player) or not video_player.is_playing():
			return
		media_texture = video_player.get_video_texture()
	else:
		media_texture = image_texture
	if media_texture == null:
		return

	var play_area: Rect2 = scene.world_play_area.get_global_rect()
	var view_center := play_area.get_center()
	var view_size := play_area.size

	var image_size := Vector2(
		media_texture.get_width(),
		media_texture.get_height()
	)

	for sobo in SoboManager.all_sobos:
		if not is_instance_valid(sobo):
			continue
		if not patched_sobos.has(sobo):
			patch_sobo(sobo, media_texture, image_size, view_center, view_size)
	for sobo in patched_sobos.keys():
		if not is_instance_valid(sobo) or not SoboManager.all_sobos.has(sobo):
			if is_instance_valid(sobo):
				sobo.set_material(original_materials.get(sobo))
			patched_sobos.erase(sobo)
			original_materials.erase(sobo)
			continue
		var mat: ShaderMaterial = patched_sobos[sobo]
		var rotation := 0.0
		var positions = sobo.get_positions()
		if not positions.is_empty():
			var relative: Vector2 = positions[0] - sobo.get_visual_center()
			rotation = relative.angle()
		mat.set_shader_parameter("sobo_rotation", rotation)
		
		var b := get_sobo_local_bounds(sobo)
		mat.set_shader_parameter("sobo_center", b.center)
		mat.set_shader_parameter("sobo_bounds_size", b.size)
		mat.set_shader_parameter("view_center", view_center)
		mat.set_shader_parameter("view_size", view_size)
		mat.set_shader_parameter("flipped_screen", SettingsManager.settings.flipped_screen)

func patch_sobo(
	sobo: Sobo,
	media_texture: Texture2D,
	image_size: Vector2,
	view_center: Vector2,
	view_size: Vector2
) -> void:
	original_materials[sobo] = sobo.get_material()
	
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("sobo_texture", media_texture)
	mat.set_shader_parameter("image_size", image_size)
	mat.set_shader_parameter("view_center", view_center)
	mat.set_shader_parameter("view_size", view_size)
	mat.set_shader_parameter("per_sobo", per_sobo)
	sobo.set_material(mat)
	patched_sobos[sobo] = mat

func clear_patched_sobos() -> void:
	for sobo in patched_sobos.keys():
		if is_instance_valid(sobo):
			sobo.set_material(original_materials.get(sobo))
	patched_sobos.clear()
	original_materials.clear()

func update_bumper_alarm(scene: Node) -> void:
	if bumper_alarm_scene != scene:
		bumper_alarms.clear()
		bumper_alarm_scene = scene

	if scene == null:
		return

	if bumper_alarms.is_empty():
		for node in scene.find_children("AlarmSound", "AudioStreamPlayer2D", true, false):
			var alarm := node as AudioStreamPlayer2D
			bumper_alarms.append(alarm)

	var mute := mod_enabled and is_video and audio_enabled
	
	for alarm in bumper_alarms:
		if is_instance_valid(alarm) and mute:
			alarm.volume_db = -80.0
