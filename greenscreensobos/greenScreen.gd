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

var green_screen_settings_screen: MenuScreen
var description_label: Label
var global_toggle: SoboMenuButtonBool
var audio_toggle: SoboMenuButtonBool
var per_sobo_toggle: SoboMenuButtonBool
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

	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		mod_enabled = cf.get_value("greenScreen", "mod_enabled", true)
		audio_enabled = cf.get_value("greenScreen", "audio_enabled", true)
		per_sobo = cf.get_value("greenScreen", "per_sobo", false)

	install_green_screen_button()
	load_media()

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
	var scene = GameModeManager.current_scene
	var in_game := scene != null
	if in_game and not was_in_game:
		if is_video and mod_enabled:
			video_player.stop()
			video_player.play()
	elif not in_game and was_in_game:
		if is_video:
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

func on_currently_hovered_changed(new: SoboButton, _old: SoboButton) -> void:
	if new:
		description_label.text = tr(new.tooltip_text)
	else:
		description_label.text = ""

func on_settings_screen_open() -> void:
	if not Ui._0.on_currently_hovered_changed.is_connected(on_currently_hovered_changed):
		Ui._0.on_currently_hovered_changed.connect(on_currently_hovered_changed)
	on_currently_hovered_changed(SoboButton.currently_hovered, null)

func on_settings_screen_close() -> void:
	if Ui._0.on_currently_hovered_changed.is_connected(on_currently_hovered_changed):
		Ui._0.on_currently_hovered_changed.disconnect(on_currently_hovered_changed)
	
func on_global_toggle_pressed() -> void:
	mod_enabled = not mod_enabled

	var cf := ConfigFile.new()
	cf.set_value("greenScreen", "mod_enabled", mod_enabled)
	cf.save(CFG)

	if is_video:
		if mod_enabled:
			video_player.play()
		else:
			video_player.stop()

	refresh_controls()
	
func on_audio_toggle_pressed() -> void:
	audio_enabled = not audio_enabled

	var cf := ConfigFile.new()
	cf.set_value("greenScreen", "audio_enabled", audio_enabled)
	cf.save(CFG)

	if video_player != null:
		video_player.volume_db = 0.0 if audio_enabled else -80.0

	refresh_controls()

func on_per_sobo_toggle_pressed() -> void:
	per_sobo = not per_sobo
	for mat: ShaderMaterial in patched_sobos.values():
		mat.set_shader_parameter("per_sobo", per_sobo)

	var cf := ConfigFile.new()
	cf.set_value("greenScreen", "per_sobo", per_sobo)
	cf.save(CFG)

	refresh_controls()

func open_media_folder() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(MEDIA_DIR)
	)
	OS.shell_show_in_file_manager(
		ProjectSettings.globalize_path(MEDIA_DIR),
		true
	)

func install_green_screen_button() -> void:
	var menu := Menu._0

	green_screen_settings_screen = MenuScreen.new()
	green_screen_settings_screen.name = "GreenScreenSettingsScreen"
	green_screen_settings_screen.side_title_text = "greenscreen"
	green_screen_settings_screen.parent_screen = menu.settings_screen
	green_screen_settings_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu.add_child(green_screen_settings_screen)
	green_screen_settings_screen.hide()
	menu.register_screen("green_screen_settings_screen", green_screen_settings_screen)

	var controls := VBoxContainer.new()
	controls.custom_minimum_size = Vector2(512, 0)
	controls.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	controls.grow_horizontal = Control.GROW_DIRECTION_BOTH
	controls.grow_vertical = Control.GROW_DIRECTION_BOTH
	controls.alignment = BoxContainer.ALIGNMENT_CENTER
	green_screen_settings_screen.add_child(controls)
	var model: SoboMenuButton = menu.settings_screen.find_child("Input", true, false)

	if model == null:
		push_warning("GreenScreenSobos: Input settings button not found")
		return

	var folder_button := model.duplicate(
		Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS
	) as SoboMenuButton

	folder_button.name = "OpenFolder"
	folder_button.tooltip_text = "opens the folder where you place png/jpg/ogv files for the mod to use"
	folder_button.label.text = "open media folder"

	controls.add_child(folder_button)
	folder_button.release_press.connect(open_media_folder)
	
	var refresh_button := model.duplicate(
		Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS
	) as SoboMenuButton
	
	refresh_button.name = "RefreshMedia"
	refresh_button.tooltip_text = "randomly selects a file from the folder again"
	refresh_button.label.text = "refresh media"
	
	controls.add_child(refresh_button)
	refresh_button.release_press.connect(refresh_media)

	var folder_gap := Control.new()
	folder_gap.custom_minimum_size.y = 16
	controls.add_child(folder_gap)

	var button_scene := load("res://ui/button/bool/sobo_menu_button_bool.tscn") as PackedScene

	if button_scene == null:
		push_error("GreenScreenSobos: Could not load toggle button scene")
		return

	global_toggle = button_scene.instantiate() as SoboMenuButtonBool
	global_toggle.name = "Enable"
	global_toggle.tooltip_text = "enable/disable the shader effects"
	global_toggle.label.text = "enable mod"
	controls.add_child(global_toggle)
	global_toggle.release_press.connect(on_global_toggle_pressed)

	audio_toggle = button_scene.instantiate() as SoboMenuButtonBool
	audio_toggle.name = "Audio"
	audio_toggle.tooltip_text = "play audio from the background video"
	audio_toggle.label.text = "video audio"
	controls.add_child(audio_toggle)
	audio_toggle.release_press.connect(on_audio_toggle_pressed)

	per_sobo_toggle = button_scene.instantiate() as SoboMenuButtonBool
	per_sobo_toggle.name = "PerSobo"
	per_sobo_toggle.tooltip_text = "display the media file on every individual sobo"
	per_sobo_toggle.label.text = "per sobo greenscreen"
	controls.add_child(per_sobo_toggle)
	per_sobo_toggle.release_press.connect(on_per_sobo_toggle_pressed)

	controls.add_child(HSeparator.new())

	description_label = Label.new()
	description_label.set_script(load("res://ui/styled_label.gd"))
	description_label.custom_minimum_size = Vector2(512, 128)
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description_label.theme = load("res://ui/theme.tres")
	controls.add_child(description_label)

	green_screen_settings_screen.first_button_hovered = folder_button
	
	refresh_controls()
	
	green_screen_settings_screen.visibility_changed.connect(func():
		if green_screen_settings_screen.visible:
			on_settings_screen_open()
		else:
			on_settings_screen_close()
	)

	var button := model.duplicate(
		Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS
	) as SoboMenuButton

	button.name = "GreenScreenSettings"
	button.label.text = "green screen"
	button.tooltip_text = "Configure GreenScreenSobos."

	button.release_press.connect(func():
		menu.change_screen(green_screen_settings_screen)
	)

	model.add_sibling(button)

	var settings_list := model.get_parent() as Control
	var partial_button_height := button.get_combined_minimum_size().y / 2.5
	settings_list.position.y += partial_button_height

func refresh_controls() -> void:
	if is_instance_valid(global_toggle):
		global_toggle.set_value(mod_enabled)
	if is_instance_valid(audio_toggle):
		audio_toggle.set_value(audio_enabled)
	if is_instance_valid(per_sobo_toggle):
		per_sobo_toggle.set_value(per_sobo)
