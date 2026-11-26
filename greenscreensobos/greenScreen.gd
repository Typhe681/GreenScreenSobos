extends Node

const MEDIA_DIR := "user://greenscreensobos/"
const CFG := "user://greenscreensobos.cfg"
const IMAGE_EXTENSIONS := ["png", "jpg"]
const VIDEO_EXTENSIONS := ["ogv"]

const MESH_PADDING := 3.0
const SMOOTH := 2

var video_players: Array[VideoStreamPlayer] = []
var size_textures: Dictionary = {}
var image_texture: Texture2D
var hide_material: ShaderMaterial
var is_video := false
var was_in_game := false
var patched_sobos: Dictionary = {}
var original_materials: Dictionary = {}
var bumper_alarms: Array[AudioStreamPlayer2D] = []
var bumper_alarm_scene: Node

var broadcaster_connected := false
var mod_enabled := true
var audio_volume := 100.0
var per_sobo := false
var per_size := false
var view_center := Vector2.ZERO
var view_size := Vector2.ZERO

const HIDE_SHADER_CODE := """
shader_type canvas_item;
void fragment() { COLOR.a = 0.0; }
"""

func _ready() -> void:
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS

	var hide_shader := Shader.new()
	hide_shader.code = HIDE_SHADER_CODE
	hide_material = ShaderMaterial.new()
	hide_material.shader = hide_shader

	load_config()
	try_connect_broadcaster()
	load_media()


func load_config() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG)

	mod_enabled = cf.get_value("mod_enabled", "value", true)
	audio_volume = float(cf.get_value("audio_volume", "value", 100.0 if cf.get_value("audio_enabled", "value", true) else 0.0)) # migration to be removed later
	per_sobo = cf.get_value("per_sobo", "value", true)
	per_size = cf.get_value("per_size", "value", false)

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
	cf.set_value("mod_enabled", "description", "enable/disable the effects")
	cf.set_value("mod_enabled", "value", mod_enabled)

	cf.set_value("audio_volume", "type", "float")
	cf.set_value("audio_volume", "label", "video volume")
	cf.set_value("audio_volume", "description", "audio volume for videos")
	cf.set_value("audio_volume", "min", 0.0)
	cf.set_value("audio_volume", "max", 100.0)
	cf.set_value("audio_volume", "step", 1.0)
	cf.set_value("audio_volume", "value", audio_volume)
	cf.set_value("audio_volume", "display", false)

	cf.set_value("per_sobo", "type", "bool")
	cf.set_value("per_sobo", "label", "per-sobo greenscreen")
	cf.set_value("per_sobo", "description", "display the media file on every individual sobo")
	cf.set_value("per_sobo", "value", per_sobo)

	cf.set_value("per_size", "type", "bool")
	cf.set_value("per_size", "label", "per-size greenscreen")
	cf.set_value("per_size", "description", "use images named by sobo size instead of a random file (overrides the per-sobo setting)")
	cf.set_value("per_size", "value", per_size)

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
			for player in video_players:
				if not is_instance_valid(player):
					continue
				if mod_enabled and was_in_game:
					player.play()
				else:
					player.stop()
		"audio_volume":
			audio_volume = float(value)
			for player in video_players:
				if is_instance_valid(player):
					player.volume_db = volume_to_db(audio_volume)
		"per_sobo":
			per_sobo = value
		"per_size":
			per_size = value
			load_media()

func volume_to_db(volume: float) -> float:
	if volume <= 0.0:
		return -80.0
	return linear_to_db(volume / 100.0)

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

func make_player(media_path: String) -> VideoStreamPlayer:
	var stream := load(media_path) as VideoStream
	if stream == null:
		push_error("GreenScreenSobos: Failed to load video: " + media_path)
		return null

	var player := VideoStreamPlayer.new()
	player.stream = stream
	player.loop = true
	player.autoplay = false
	player.expand = true
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.volume_db = volume_to_db(audio_volume)
	add_child(player)
	video_players.append(player)

	if mod_enabled and was_in_game:
		player.play()
	return player

func clear_videos() -> void:
	for player in video_players:
		if is_instance_valid(player):
			player.queue_free()
	video_players.clear()
	is_video = false

func load_media() -> void:
	clear_patched_sobos()
	clear_videos()
	image_texture = null
	size_textures.clear()

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(MEDIA_DIR)
	)

	if per_size:
		load_size_media()
		return

	var media_path := find_media()
	if media_path.is_empty():
		push_warning("GreenScreenSobos: No supported media found in " + MEDIA_DIR)
		return

	var extension := media_path.get_extension().to_lower()

	if extension in VIDEO_EXTENSIONS:
		if make_player(media_path) != null:
			is_video = true
	else:
		var image := Image.load_from_file(media_path)
		if image == null or image.is_empty():
			push_error("GreenScreenSobos: Failed to load image: " + media_path)
			return
		image_texture = ImageTexture.create_from_image(image)

func load_size_media() -> void:
	var dir := DirAccess.open(MEDIA_DIR)
	if dir == null:
		push_error("GreenScreenSobos: Could not open media folder: " + MEDIA_DIR)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_basename().is_valid_int() and file_name.get_extension().to_lower() in IMAGE_EXTENSIONS:
			var image := Image.load_from_file(MEDIA_DIR + file_name)
			if image == null or image.is_empty():
				push_error("GreenScreenSobos: Failed to load image: " + file_name)
			else:
				size_textures[file_name.get_basename().to_int()] = ImageTexture.create_from_image(image)
		file_name = dir.get_next()
	dir.list_dir_end()

	if size_textures.is_empty():
		push_warning("GreenScreenSobos: No size images (like 2.png) found in " + MEDIA_DIR)

func refresh_media() -> void:
	load_media()
	if is_video:
		for player in video_players:
			player.paused = false
		await RenderingServer.frame_post_draw
		for player in video_players:
			if is_instance_valid(player):
				player.paused = true
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
			if extension in VIDEO_EXTENSIONS:
				files.append(MEDIA_DIR + file_name)
			elif extension in IMAGE_EXTENSIONS and not file_name.get_basename().is_valid_int():
				files.append(MEDIA_DIR + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	files.sort()
	if files.is_empty():
		return ""
	return files.pick_random() # lets go gambling!!

func _process(_delta: float) -> void:
	try_connect_broadcaster()

	var scene = GameModeManager.current_scene
	if scene != null and scene.get_script() != null:
		if scene.get_script().get_global_name() == "SceneSuika":
			clear_patched_sobos()
			for player in video_players:
				if is_instance_valid(player):
					player.stop()
			return

	var in_game := scene != null
	if in_game and not was_in_game:
		if mod_enabled:
			for player in video_players:
				if is_instance_valid(player):
					player.stop()
					player.play()
	elif not in_game and was_in_game:
		for player in video_players:
			if is_instance_valid(player):
				player.stop()
		clear_patched_sobos()
	was_in_game = in_game
	
	for player in video_players:
		if is_instance_valid(player):
			player.paused = get_tree().paused
		
	update_bumper_alarm(scene)
	if not mod_enabled:
		clear_patched_sobos()
		return

	if not in_game:
		return

	if scene.world_play_area == null:
		return

	var play_area: Rect2 = scene.world_play_area.get_global_rect()
	view_center = play_area.get_center()
	view_size = play_area.size

	if per_size:
		if size_textures.is_empty():
			return
		for sobo in SoboManager.all_sobos:
			if not is_instance_valid(sobo):
				continue
			if patched_sobos.has(sobo):
				continue
			var size: int = sobo.data.size
			if not size_textures.has(size):
				continue
			var tex: Texture2D = size_textures[size]
			patch_sobo(sobo, tex, default_region(Vector2i(tex.get_width(), tex.get_height())))
	else:
		var media_texture: Texture2D

		if is_video:
			var player := video_players[0]
			if not is_instance_valid(player) or not player.is_playing():
				return
			media_texture = player.get_video_texture()
		else:
			media_texture = image_texture
		if media_texture == null:
			return

		var region := default_region(Vector2i(media_texture.get_width(), media_texture.get_height()))

		for sobo in SoboManager.all_sobos:
			if not is_instance_valid(sobo):
				continue
			if not patched_sobos.has(sobo):
				patch_sobo(sobo, media_texture, region)

	for sobo in patched_sobos.keys():
		if not is_instance_valid(sobo) or not SoboManager.all_sobos.has(sobo):
			if is_instance_valid(sobo):
				sobo.set_material(original_materials.get(sobo))
				var mi: MeshInstance2D = patched_sobos[sobo]["mi"]
				if is_instance_valid(mi):
					mi.queue_free()
			patched_sobos.erase(sobo)
			original_materials.erase(sobo)
			continue
		update_mesh(sobo, patched_sobos[sobo])

func patch_sobo(sobo: Sobo, tex: Texture2D, region: Rect2) -> void:
	original_materials[sobo] = sobo.get_material()
	sobo.set_material(hide_material)

	var mi := MeshInstance2D.new()
	mi.top_level = true
	mi.texture = tex
	mi.mesh = ArrayMesh.new()
	var outline_z := 0
	if SoboOutline._0 is CanvasItem:
		outline_z = (SoboOutline._0 as CanvasItem).z_index
	mi.z_as_relative = false
	mi.z_index = outline_z + 1
	sobo.add_child(mi)

	var d := {"mi": mi, "tex": tex, "region": region, "flip": null}
	patched_sobos[sobo] = d
	build_uvs(sobo, d)

func default_region(img_size: Vector2i) -> Rect2:
	var side := mini(img_size.x, img_size.y)
	return Rect2(
		(img_size.x - side) / 2.0,
		img_size.y - side,
		side,
		side
	)

func to_tex_uv(uv: Vector2, region: Rect2, tex_size: Vector2) -> Vector2:
	return (region.position + uv * region.size) / tex_size

func ring_spline(ctrl: PackedVector2Array) -> PackedVector2Array:
	var points := ctrl.duplicate()

	for _i in SMOOTH:
		var smooth := PackedVector2Array()
		smooth.resize(points.size() * 2)

		for i in points.size():
			var p1 := points[i]
			var p2 := points[(i + 1) % points.size()]

			smooth[i * 2] = p1.lerp(p2, 0.25)
			smooth[i * 2 + 1] = p1.lerp(p2, 0.75)

		points = smooth

	return points

func build_uvs(sobo: Sobo, d: Dictionary) -> void:
	var rest = sobo.data.circular_positions
	var n: int = sobo.subas.size()
	var tex: Texture2D = d["tex"]
	var region: Rect2 = d["region"]
	var tex_size := Vector2(tex.get_width(), tex.get_height())
	var flip: bool = SettingsManager.settings.flipped_screen
	var hw: float = sobo.visual_half_width
	var r: float = rest[0].length() + hw

	var ctrl := PackedVector2Array()
	ctrl.resize(n)
	for i in n:
		var rp: Vector2 = rest[i]
		var uv := Vector2(0.5, 0.5) + (rp + rp.normalized() * hw) / (2.0 * r)
		if flip:
			uv = Vector2.ONE - uv
		ctrl[i] = uv
	var ring := ring_spline(ctrl)
	var m := ring.size()

	var uvs := PackedVector2Array()
	uvs.resize(m + 1)
	uvs[0] = to_tex_uv(Vector2(0.5, 0.5), region, tex_size)
	var idx := PackedInt32Array()
	for j in m:
		uvs[j + 1] = to_tex_uv(ring[j], region, tex_size)
		idx.append_array([0, 1 + j, 1 + (j + 1) % m])
	d["uvs"] = uvs
	d["idx"] = idx
	d["flip"] = flip
	d["n"] = n

func world_uvs(verts: PackedVector2Array, tex: Texture2D) -> PackedVector2Array:
	var image_size := Vector2(tex.get_width(), tex.get_height())
	var denom := image_size * maxf(view_size.x / image_size.x, view_size.y / image_size.y)
	var flip: bool = SettingsManager.settings.flipped_screen
	var uvs := PackedVector2Array()
	uvs.resize(verts.size())
	for i in verts.size():
		var p := verts[i]
		if flip:
			p = view_center * 2.0 - p
		uvs[i] = (p - view_center) / denom + Vector2(0.5, 0.5)
	return uvs

func update_mesh(sobo: Sobo, d: Dictionary) -> void:
	if d["flip"] != SettingsManager.settings.flipped_screen:
		build_uvs(sobo, d)
	var pos = sobo.get_positions()
	var n: int = pos.size()
	if n == 0 or n != d["n"]:
		return
	var center := sobo.get_visual_center()
	var hw: float = sobo.visual_half_width
	var ctrl := PackedVector2Array()
	ctrl.resize(n)
	for i in n:
		var p: Vector2 = pos[i]
		ctrl[i] = p + (p - center).normalized() * (hw + MESH_PADDING)
	var verts := PackedVector2Array([center])
	verts.append_array(ring_spline(ctrl))

	var uvs: PackedVector2Array = d["uvs"]
	if not per_sobo and not per_size:
		uvs = world_uvs(verts, d["tex"])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = d["idx"]
	var mesh: ArrayMesh = (d["mi"] as MeshInstance2D).mesh
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func clear_patched_sobos() -> void:
	for sobo in patched_sobos.keys():
		if is_instance_valid(sobo):
			sobo.set_material(original_materials.get(sobo))
		var mi: MeshInstance2D = patched_sobos[sobo]["mi"]
		if is_instance_valid(mi):
			mi.queue_free()
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

	var mute := mod_enabled and is_video and audio_volume > 0.0
	
	for alarm in bumper_alarms:
		if is_instance_valid(alarm) and mute:
			alarm.volume_db = -80.0
