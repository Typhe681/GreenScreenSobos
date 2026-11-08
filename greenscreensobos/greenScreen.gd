extends Node

const MEDIA_DIR := "user://greenscreensobos/"
const CFG := "user://greenscreensobos.cfg"
const IMAGE_EXTENSIONS := ["png", "jpg"]
const VIDEO_EXTENSIONS := ["ogv"]

var video_player: VideoStreamPlayer
var image_texture: Texture2D
var shader: Shader
var is_video := false
var patched_sobos: Dictionary = {}
var original_materials: Dictionary = {}
var audio_enabled := true
var audio_toggle: SoboMenuButtonBool
var bumper_alarms: Array[AudioStreamPlayer2D] = []
var bumper_alarm_scene: Node
var was_in_game := false

const SHADER_CODE := """
shader_type canvas_item;

uniform sampler2D test_texture;
uniform vec2 image_size;
uniform vec2 view_center;
uniform vec2 view_size;
uniform bool flipped_screen;

varying vec2 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float scale = max(
		view_size.x / image_size.x,
		view_size.y / image_size.y
	);

	vec2 sample_position = world_position;

	if (flipped_screen) {
		sample_position = view_center * 2.0 - sample_position;
	}

	vec2 uv = (sample_position - view_center) / (image_size * scale) + vec2(0.5);

	COLOR = texture(test_texture, uv);
}
"""


func _ready() -> void:
	process_priority = 100
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		audio_enabled = cf.get_value("greenScreen", "audio_enabled", true)

	var media_path := find_media()
	if media_path.is_empty():
		push_error("GreenScreenSobos: No supported media found in " + MEDIA_DIR)
		return

	var extension := media_path.get_extension().to_lower()
	is_video = extension in VIDEO_EXTENSIONS
	if is_video:
		video_player = VideoStreamPlayer.new()
		video_player.stream = load(media_path) as VideoStream
		video_player.loop = true
		video_player.autoplay = false
		video_player.expand = true
		video_player.volume_db = 0.0 if audio_enabled else -80.0
		add_child(video_player)
		if video_player.stream == null:
			push_error("GreenScreenSobos: Failed to load video: " + media_path)
			return
	else:
		var image := Image.load_from_file(media_path)
		if image == null or image.is_empty():
			push_error("GreenScreenSobos: Failed to load image: " + media_path)
			return
		image_texture = ImageTexture.create_from_image(image)
	shader = Shader.new()
	shader.code = SHADER_CODE
	SignalBus.on_game_mode_start.connect(on_game_mode_start)
	if is_video:
		install_audio_toggle()

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

func on_game_mode_start(scene: GameScene) -> void:
	clear_patched_sobos()
	if is_video:
		video_player.stop()
		video_player.play()
	was_in_game = true
	update_bumper_alarm(scene)

func _process(_delta: float) -> void:
	var scene = GameModeManager.current_scene
	var in_game := scene != null
	if in_game and not was_in_game:
		if is_video:
			video_player.stop()
			video_player.play()
	elif not in_game and was_in_game:
		if is_video:
			video_player.stop()
		clear_patched_sobos()
	was_in_game = in_game

	update_bumper_alarm(scene)

	if not in_game:
		return

	if scene.world_play_area == null:
		return

	var media_texture: Texture2D

	if is_video:
		if not video_player.is_playing():
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
	mat.set_shader_parameter("test_texture", media_texture)
	mat.set_shader_parameter("image_size", image_size)
	mat.set_shader_parameter("view_center", view_center)
	mat.set_shader_parameter("view_size", view_size)
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
			bumper_alarms.append(node as AudioStreamPlayer2D)

	for alarm in bumper_alarms:
		if is_instance_valid(alarm):
			alarm.volume_db = -80.0

func install_audio_toggle() -> void:
	var model: SoboMenuButtonBool = null
	model = get_tree().root.find_child("LiveFriendScores", true, false)

	if model == null:
		push_warning("GreenScreenSobos: LiveFriendScores toggle not found")
		return

	var button: SoboMenuButtonBool = model.duplicate(
		Node.DUPLICATE_GROUPS |
		Node.DUPLICATE_SCRIPTS |
		Node.DUPLICATE_USE_INSTANTIATION
	)

	for prop: Dictionary in model.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
			button.set(
				prop.name,
				value_for_copy(model.get(prop.name), model, button)
			)

	button.name = "GreenScreenAudio"
	button.label.text = "video audio"
	button.tooltip_text = "play audio from the background video"
	button.release_press.connect(on_audio_toggle_pressed)
	model.add_sibling(button)
	var settings_list := model.get_parent() as Control
	var partial_button_height := button.get_combined_minimum_size().y / 2.5
	settings_list.position.y += partial_button_height
	audio_toggle = button
	audio_toggle.set_value(audio_enabled)

func on_audio_toggle_pressed() -> void:
	audio_enabled = not audio_enabled
	audio_toggle.set_value(audio_enabled)
	if video_player != null:
		video_player.volume_db = 0.0 if audio_enabled else -80.0

	var cf := ConfigFile.new()
	cf.set_value("greenScreen", "audio_enabled", audio_enabled)
	cf.save(CFG)

func value_for_copy(value: Variant, original: Node, copy: Node) -> Variant:
	if value is Node:
		if value == original:
			return copy
		if original.is_ancestor_of(value):
			return copy.get_node_or_null(original.get_path_to(value))
		return value

	if value is Array:
		var mapped: Array = value.duplicate()
		for i in mapped.size():
			mapped[i] = value_for_copy(mapped[i], original, copy)
		return mapped
	return value
