# open-tabletop
# Copyright (c) 2020-2021 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Node

signal completed(dir_found)
signal importing_file(file, files_imported, files_total)

enum {
	ASSET_AUDIO,
	ASSET_SCENE,
	ASSET_SKYBOX,
	ASSET_TABLE,
	ASSET_TEXTURE
}

const ASSET_DIR_PREFIXES = [
	".",
	"..",
	"{DOWNLOADS}/OpenTabletop",
	"{DOCUMENTS}/OpenTabletop",
	"{DESKTOP}/OpenTabletop"
]

const ASSET_PACK_SUBFOLDERS = {
	"cards": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Card.tscn" },
	
	"containers/cube": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Containers/Cube.tscn" },
	"containers/custom": { "type": ASSET_SCENE, "scene": "" },
	"containers/cylinder": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Containers/Cylinder.tscn" },
	
	"dice/d4": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Dice/d4.tscn" },
	"dice/d6": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Dice/d6.tscn" },
	"dice/d8": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Dice/d8.tscn" },
	
	"games": { "type": ASSET_TABLE, "scene": "" },
	
	"music": { "type": ASSET_AUDIO, "scene": "" },
	
	"pieces/cube": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Pieces/Cube.tscn" },
	"pieces/custom": { "type": ASSET_SCENE, "scene": "" },
	"pieces/cylinder": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Pieces/Cylinder.tscn" },
	
	"skyboxes": { "type": ASSET_SKYBOX, "scene": "" },
	
	"sounds": { "type": ASSET_AUDIO, "scene": "" },
	
	"speakers/cube": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Speakers/Cube.tscn" },
	"speakers/custom": { "type": ASSET_SCENE, "scene": "" },
	"speakers/cylinder": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Speakers/Cylinder.tscn" },
	
	"tables": { "type": ASSET_SCENE, "scene": "" },
	
	"timers/cube": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Timers/Cube.tscn" },
	"timers/custom": { "type": ASSET_SCENE, "scene": "" },
	"timers/cylinder": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Timers/Cylinder.tscn" },
	
	"tokens/cube": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Tokens/Cube.tscn" },
	"tokens/cylinder": { "type": ASSET_TEXTURE, "scene": "res://Pieces/Tokens/Cylinder.tscn" }
}

const VALID_AUDIO_EXTENSIONS = ["mp3", "ogg", "wav"]
const VALID_SCENE_EXTENSIONS = ["dae", "glb", "gltf", "obj"]
const VALID_TABLE_EXTENSIONS = ["ot"]

# List taken from:
# https://docs.godotengine.org/en/3.2/getting_started/workflow/assets/importing_images.html
const VALID_TEXTURE_EXTENSIONS = ["bmp", "dds", "exr", "hdr", "jpeg", "jpg",
	"png", "tga", "svg", "svgz", "webp"]

# The list of extensions that require us to use the TabletopImporter.
const EXTENSIONS_TO_IMPORT = VALID_AUDIO_EXTENSIONS + VALID_SCENE_EXTENSIONS + VALID_TEXTURE_EXTENSIONS

# NOTE: All assets are stored in the database in a directory structure, where
# the first level is the pack name, and the second level is the type name (the
# subfolder within the asset pack). For example, an asset in the
# "OpenTabletop/dice/d6" folder would be in _db["OpenTabletop"]["dice/d6"].
var _db = {}
var _db_mutex = Mutex.new()

var _import_dir_found = false
var _import_file_path = ""
var _import_files_imported = 0
var _import_files_total = 0
var _import_mutex = Mutex.new()
var _import_send_signal = false
var _import_thread = Thread.new()

# From the open_tabletop_godot_module:
# https://github.com/drwhut/open_tabletop_godot_module
var _importer = TabletopImporter.new()

# Clear the AssetDB.
func clear_db() -> void:
	_db_mutex.lock()
	_db.clear()
	_db_mutex.unlock()

# Get the list of asset directory paths the game will scan.
# Returns: The list of asset directory paths.
func get_asset_paths() -> Array:
	var out = []
	for prefix in ASSET_DIR_PREFIXES:
		var path = prefix + "/assets"
		path = path.replace("{DOWNLOADS}", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS))
		path = path.replace("{DOCUMENTS}", OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
		path = path.replace("{DESKTOP}", OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP))
		out.append(path)
	return out

# Get the asset database.
# Returns: The asset database.
func get_db() -> Dictionary:
	return _db

# Search a pack's type directory for an asset with the given name.
# Returns: The asset's entry in the DB if it exists, empty otherwise.
# pack: The asset pack to search.
# type: The type directory to search.
# asset: The name of the asset to query.
func search_type(pack: String, type: String, asset: String) -> Dictionary:
	if _db.has(pack):
		if _db[pack].has(type):
			# The array of assets should be sorted by name, so we can use
			# binary search!
			var array: Array = _db[pack][type]
			var index = array.bsearch_custom(asset, self, "_search_assets")
			if index < array.size():
				if array[index]["name"] == asset:
					return array[index]
	
	return {}

# Start the importing thread.
func start_importing() -> void:
	if _import_thread.is_active():
		_import_thread.wait_to_finish()
	_import_thread.start(self, "_import_all")

func _ready():
	connect("tree_exiting", self, "_on_exiting_tree")

func _process(_delta):
	_import_mutex.lock()
	if _import_send_signal:
		if _import_file_path.empty():
			emit_signal("completed", _import_dir_found)
		else:
			emit_signal("importing_file", _import_file_path,
				_import_files_imported, _import_files_total)
		_import_send_signal = false
	_import_mutex.unlock()

# Import assets from all directories.
# _userdata: Ignored, required for it to be run by a thread.
func _import_all(_userdata) -> void:
	var catalog = _catalog_assets()
	
	var files_imported = 0
	for pack in catalog["packs"]:
		var pack_catalog = catalog["packs"][pack]
		var pack_path = pack_catalog["path"]
		
		for type in pack_catalog["types"]:
			var type_catalog = pack_catalog["types"][type]
			var type_path = pack_path + "/" + type
			
			var config_file = ConfigFile.new()
			if type_catalog["config_file"]:
				var config_file_path = type_path + "/config.cfg"
				var err = config_file.load(config_file_path)
				if err == OK:
					print("Loaded: %s" % config_file_path)
				else:
					push_error("Failed to load '%s' (error %d)!" % [config_file_path, err])
			
			for file in type_catalog["files"]:
				var file_path = type_path + "/" + file
				_send_importing_file_signal(file_path, files_imported,
					catalog["file_count"])
				
				var err = _import_asset(file_path, pack, type, config_file)
				if err != OK:
					push_error("Failed to import '%s' (error %d)!" % [file_path, err])
				
				files_imported += 1
			
			var type_meta = ASSET_PACK_SUBFOLDERS[type]
			var asset_scene = type_meta["scene"]
			
			var is_stackable = false
			if not asset_scene.empty():
				var piece = load(asset_scene).instance()
				is_stackable = piece is StackablePiece
				piece.free()
			
			if is_stackable and type_catalog["stacks_file"]:
				var stacks_file_path = type_path + "/stacks.cfg"
				var stacks_config = ConfigFile.new()
				var err = stacks_config.load(stacks_file_path)
				if err == OK:
					_import_stack_config(pack, type, stacks_config)
					print("Loaded: %s" % stacks_file_path)
				else:
					push_error("Failed to load '%s' (error %d)!" % [stacks_file_path, err])
			
			if _db.has(pack):
				if _db[pack].has(type):
					var array: Array = _db[pack][type]
					array.sort_custom(self, "_sort_assets")
	
	_send_completed_signal(catalog["asset_dir_exists"])

# Add an asset entry to the database.
# pack: The name of the pack.
# type: The type of the asset.
# entry: The entry to add.
func _add_entry_to_db(pack: String, type: String, entry: Dictionary) -> void:
	_db_mutex.lock()
	
	if not _db.has(pack):
		_db[pack] = {}
	
	if not _db[pack].has(type):
		_db[pack][type] = []
	
	_db[pack][type].push_back(entry)
	_db_mutex.unlock()
	
	print("Added: %s/%s/%s" % [pack, type, entry["name"]])

# Calculate the bounding box of a 3D scene.
# Returns: A 2-length array containing the min and max corners of the box.
# scene: The scene to calculate the bounding box for.
func _calculate_bounding_box(scene: Spatial) -> Array:
	return _calculate_bounding_box_recursive(scene, Transform.IDENTITY)

# A helper function for calculating the bounding box of a 3D scene.
# Returns: A 2-length array containing the min and max corners of the box.
# scene: The scene to calculate the bounding box for.
# transform: The transform of the scene up to this point.
func _calculate_bounding_box_recursive(scene: Spatial, transform: Transform) -> Array:
	var new_basis     = transform.basis * scene.transform.basis
	var new_origin    = transform.origin + scene.transform.origin
	var new_transform = Transform(new_basis, new_origin)
	
	var bounding_box = [Vector3.ZERO, Vector3.ZERO]
	
	if scene is MeshInstance:
		var mesh  = scene.mesh
		var shape = mesh.create_convex_shape()
		for point in shape.points:
			var adj_point = new_transform * point
			
			bounding_box[0].x = min(bounding_box[0].x, adj_point.x)
			bounding_box[0].y = min(bounding_box[0].y, adj_point.y)
			bounding_box[0].z = min(bounding_box[0].z, adj_point.z)
			
			bounding_box[1].x = max(bounding_box[1].x, adj_point.x)
			bounding_box[1].y = max(bounding_box[1].y, adj_point.y)
			bounding_box[1].z = max(bounding_box[1].z, adj_point.z)
	
	for child in scene.get_children():
		if child is Spatial:
			var child_box = _calculate_bounding_box_recursive(child, new_transform)
			
			bounding_box[0].x = min(bounding_box[0].x, child_box[0].x)
			bounding_box[0].y = min(bounding_box[0].y, child_box[0].y)
			bounding_box[0].z = min(bounding_box[0].z, child_box[0].z)
			
			bounding_box[1].x = max(bounding_box[1].x, child_box[1].x)
			bounding_box[1].y = max(bounding_box[1].y, child_box[1].y)
			bounding_box[1].z = max(bounding_box[1].z, child_box[1].z)
	
	return bounding_box

# Catalog all the assets from every asset directory.
# Returns: A catalog of all asset files.
func _catalog_assets() -> Dictionary:
	var dir = Directory.new()
	
	var asset_dir_exists = false
	var file_count = 0
	var packs = {}
	for asset_dir in get_asset_paths():
		var err = dir.open(asset_dir)
		if err == OK:
			asset_dir_exists = true
			dir.list_dir_begin(true, true)
			
			var folder = dir.get_next()
			while folder:
				if dir.current_is_dir():
					var pack_path = dir.get_current_dir() + "/" + folder
					var pack_dir = Directory.new()
					err = pack_dir.open(pack_path)
					if err == OK:
						var pack_catalog = _catalog_pack_dir(pack_dir)
						var pack_name = folder
						
						if packs.has(pack_name):
							var new_pack = pack_name
							var i = 1
							while packs.has(new_pack):
								new_pack = "%s (%d)" % [pack_name, i]
								i += 1
							print("Pack %s already exists, renaming to %s." % [pack_name, new_pack])
							pack_name = new_pack
						
						packs[pack_name] = pack_catalog
						file_count += pack_catalog["file_count"]
					else:
						push_error("Failed to open '%s' (error %d)!" % [pack_path, err])
				
				folder = dir.get_next()
		elif err == ERR_INVALID_PARAMETER:
			# The folder doesn't exist.
			pass
		else:
			push_error("Failed to open '%s' (error %d)!" % [asset_dir, err])
	
	return {
		"asset_dir_exists": asset_dir_exists,
		"packs": packs,
		"file_count": file_count
	}

# Catalog the assets in a pack directory.
# Returns: A catalog of the pack directory.
# pack_dir: The pack directory to catalog.
func _catalog_pack_dir(pack_dir: Directory) -> Dictionary:
	print("Scanning pack '%s'..." % pack_dir.get_current_dir())
	
	var file_count = 0
	var types = {}
	for type in ASSET_PACK_SUBFOLDERS:
		if pack_dir.dir_exists(type):
			var type_dir = Directory.new()
			var type_path = pack_dir.get_current_dir() + "/" + type
			var err = type_dir.open(type_path)
			if err == OK:
				var type_catalog = _catalog_type_dir(type_dir)
				types[type] = type_catalog
				file_count += type_catalog["file_count"]
			else:
				push_error("Failed to open '%s' (error %d)!" % [type_path, err])
	
	return {
		"path": pack_dir.get_current_dir(),
		"types": types,
		"file_count": file_count
	}

# Catalog the assets in a type directory.
# Returns: A catalog of the type directory.
# type_dir: The type directory to catalog.
func _catalog_type_dir(type_dir: Directory) -> Dictionary:
	print("Scanning subfolder '%s'..." % type_dir.get_current_dir())
	var config_file = type_dir.file_exists("config.cfg")
	var stacks_file = type_dir.file_exists("stacks.cfg")
	
	var files = []
	type_dir.list_dir_begin(true, true)
	
	var file = type_dir.get_next()
	while file:
		if not (file == "config.cfg" or file == "stacks.cfg"):
			# Make sure that scenes are imported last, since they can depend on
			# other files like textures and binary files.
			if VALID_SCENE_EXTENSIONS.has(file.get_extension()):
				files.push_back(file)
			else:
				files.push_front(file)
		
		file = type_dir.get_next()
	
	return {
		"config_file": config_file,
		"stacks_file": stacks_file,
		"files": files,
		"file_count": files.size()
	}

# Get the directory of a pack's type in the user://assets directory.
# Returns: The directory as a Directory object.
# pack: The name of the pack.
# type_dir: The relative path from the pack directory.
func _get_asset_dir(pack: String, type_dir: String) -> Directory:
	var dir = Directory.new()
	var dir_error = dir.open("user://")
	
	if dir_error == OK:
		var path = "assets/" + pack + "/" + type_dir
		dir.make_dir_recursive(path)
		dir.change_dir(path)
	else:
		print("Cannot open user:// directory (error ", dir_error, ")")
	
	return dir

# Get an asset's config value. It will search the config file with wildcards
# from right to left (e.g. Card -> Car* -> Ca* -> C* -> *).
# Returns: The config value. If it doesn' exists, returns default.
# config: The config file to query.
# section: The section to query (this is the value that is wildcarded).
# key: The key to query.
# default: The default value to return if the value doesn't exist.
func _get_file_config_value(config: ConfigFile, section: String, key: String, default):
	var next_section = section
	
	if section.length() == 0:
		return default
	
	var take_away = 1
	if section.ends_with("*"):
		take_away += 1
	
	var new_len = max(section.length() - take_away, 0)
	
	next_section = section.substr(0, new_len)
	if section != "*":
		next_section += "*"
	
	return config.get_value(section, key, _get_file_config_value(config, next_section, key, default))

# Given a file path, get the file name without the extension.
# Returns: The file name of file_path without the extension.
# file_path: The file path.
func _get_file_without_ext(file_path: String) -> String:
	var file = file_path.get_file()
	return file.substr(0, file.length() - file.get_extension().length() - 1)

# Import an asset. If it has already been imported before, and it's contents
# have not changed, it is not reimported, but the piece entry is still added to
# the database.
# Returns: An error.
# from: The file path of the asset.
# pack: The name of the pack to import the asset to.
# type: The relative file path from the pack directory.
# config: The configuration file for the asset's directory.
func _import_asset(from: String, pack: String, type: String, config: ConfigFile) -> int:
	var ignore = _get_file_config_value(config, from.get_file(), "ignore", false)
	if ignore:
		return OK
	
	var dir = _get_asset_dir(pack, type)
	var to = dir.get_current_dir() + "/" + from.get_file()
	var import_err = _import_file(from, to)
	if not (import_err == OK or import_err == ERR_ALREADY_EXISTS):
		return import_err
	
	var type_meta = ASSET_PACK_SUBFOLDERS[type]
	var asset_scene = type_meta["scene"]
	var asset_type = type_meta["type"]
	
	# We usually deal with the config values at the end, but some assets need
	# these values for the entry initialization.
	var scale = _get_file_config_value(config, from.get_file(), "scale", Vector3.ONE)
	
	var entry = {}
	if asset_type == ASSET_AUDIO:
		if VALID_AUDIO_EXTENSIONS.has(to.get_extension()):
			entry = { "audio_path": to }
	elif asset_type == ASSET_SCENE:
		if VALID_SCENE_EXTENSIONS.has(to.get_extension()):
			# If the file has been imported before, check that the custom scene
			# has a cached bounding box (.box) file, so we don't have to go and
			# calculate it again.
			var box_file_path = to + ".box"
			var box_file = File.new()
			var bounding_box = []
			
			if import_err == ERR_ALREADY_EXISTS and box_file.file_exists(box_file_path):
				box_file.open(box_file_path, File.READ)
				var box = box_file.get_var()
				box_file.close()
				
				if box is Array:
					if box.size() == 2:
						var box_min = box[0]
						var box_max = box[1]
						if box_min is Vector3 and box_max is Vector3:
							bounding_box = box
						else:
							push_error("Elements in %s are not Vector3!" % box_file_path)
					else:
						push_error("Array in %s is not of size 2!" % box_file_path)
				else:
					push_error("%s does not contain an array!" % box_file_path)
			
			# If we couldn't read it for whatever reason, we should make a new
			# one by doing the calculation now.
			if bounding_box.size() != 2:
				var custom_scene = load(to).instance()
				bounding_box = _calculate_bounding_box(custom_scene)
				custom_scene.free()
				
				box_file.open(box_file_path, File.WRITE)
				box_file.store_var(bounding_box)
				box_file.close()
			
			# For convenience, we'll scale the bounding box here by the
			# configured value so we don't have to do it every time we use it
			# later on.
			if scale != Vector3.ONE:
				bounding_box[0] = Vector3(
					bounding_box[0].x * scale.x,
					bounding_box[0].y * scale.y,
					bounding_box[0].z * scale.z
				)
				
				bounding_box[1] = Vector3(
					bounding_box[1].x * scale.x,
					bounding_box[1].y * scale.y,
					bounding_box[1].z * scale.z
				)
			
			entry = {
				"bounding_box": bounding_box,
				"scene_path": to,
				"texture_path": null
			}
	elif asset_type == ASSET_SKYBOX:
		if VALID_TEXTURE_EXTENSIONS.has(to.get_extension()):
			entry = { "texture_path": to }
	elif asset_type == ASSET_TABLE:
		if VALID_TABLE_EXTENSIONS.has(to.get_extension()):
			entry = { "table_path": to }
	elif asset_type == ASSET_TEXTURE:
		if asset_scene and VALID_TEXTURE_EXTENSIONS.has(to.get_extension()):
			entry = { "scene_path": asset_scene, "texture_path": to }
	
	# The file is the wrong file type for this type of asset.
	if entry.empty():
		return OK
	
	entry["name"] = _get_file_without_ext(to)
	entry["description"] = _get_file_config_value(config, from.get_file(), "desc", "")
	
	if type == "games":
		pass
	elif type == "music":
		entry["main_menu"] = _get_file_config_value(config, from.get_file(), "main_menu", false)
	elif type == "skyboxes":
		var default = _get_file_config_value(config, from.get_file(), "default", false)
		var rotation = _get_file_config_value(config, from.get_file(), "rotation", Vector3.ZERO)
		var strength = _get_file_config_value(config, from.get_file(), "strength", 1.0)
		if strength < 0.0:
			push_error("Skybox ambient light strength cannot be negative!")
			strength = 1.0
		
		entry["default"] = default
		entry["rotation"] = rotation
		entry["strength"] = strength
	elif type == "sounds":
		pass
	elif type == "tables":
		# These values don't mean anything, but they are needed if we want to
		# display the table like an object in an object preview.
		entry["mass"] = 1.0
		entry["scale"] = Vector3.ONE
		
		var bounce = _get_file_config_value(config, from.get_file(), "bounce", 0.5)
		if bounce < 0.0 or bounce > 1.0:
			push_error("Table bounce value must be between 0.0 and 1.0!")
			bounce = 0.5
		
		var default = _get_file_config_value(config, from.get_file(), "default", false)
		var hands = _get_file_config_value(config, from.get_file(), "hands", [])
		if hands.empty():
			push_warning("No hand positions have been configured!")
		else:
			for hand in hands:
				if hand is Dictionary:
					if hand.has("pos"):
						if not hand["pos"] is Vector3:
							push_error("'pos' key in hand position is not a Vector3!")
					else:
						push_error("Hand position missing 'pos' key!")
						
					if hand.has("dir"):
						if not (hand["dir"] is float or hand["dir"] is int):
							push_error("'dir' key in hand position is not a number!")
					else:
						push_error("Hand position missing 'dir' key!")
				else:
					push_error("Hand position is not a dictionary!")
		
		var paint_plane = _get_file_config_value(config, from.get_file(), "paint_plane", 100.0 * Vector2.ONE)
		if paint_plane.x <= 0.0 or paint_plane.y <= 0.0:
			push_error("Paint plane size must be positive!")
			paint_plane = 100.0 * Vector2.ONE
		
		entry["bounce"] = bounce
		entry["default"] = default
		entry["hands"] = hands
		entry["paint_plane"] = paint_plane
	else: # Objects.
		# Converting from g -> kg -> (Ns^2/cm, since game units are in cm) = x10.
		var mass = 10 * _get_file_config_value(config, from.get_file(), "mass", 1.0)
		if mass < 0.0:
			push_error("Mass cannot be negative!")
			mass = 10.0
		
		entry["mass"] = mass
		entry["scale"] = scale
		
		if type == "cards":
			var back_path = _get_file_config_value(config, from.get_file(), "back_face", "")
			if not back_path.empty():
				if "/" in back_path or "\\" in back_path:
					push_error("'%s' is invalid - back_face cannot point to another folder!" % back_path)
				else:
					back_path = from.get_base_dir() + "/" + back_path
					var back_to = dir.get_current_dir() + "/" + back_path.get_file()
					var back_err = _import_file(back_path, back_to)
					
					if back_err == OK or back_err == ERR_ALREADY_EXISTS:
						entry["texture_path_1"] = back_to
						print("Loaded back face: %s" % back_path)
					else:
						push_error("Failed to import '%s' (error %d)!" % [back_path, back_err])
		
		elif type.begins_with("containers"):
			entry["shakable"] = _get_file_config_value(config, from.get_file(), "shakable", false)
	
	_add_entry_to_db(pack, type, entry)
	
	return OK

# Import a generic file.
# Returns: An Error.
# from: The file path of the file to import.
# to: The path of where to copy the file to.
func _import_file(from: String, to: String) -> int:
	var copy_err = _importer.copy_file(from, to)
	
	if copy_err:
		return copy_err
	else:
		# With Wavefront files, there's an annoying thing where it will only
		# look for the material file relative to the current working directory.
		# So, after we've copied it (the hash file should have been generated),
		# we'll edit the .obj file such that the path to the .mtl file is
		# an absolute path.
		if to.get_extension() == "obj":
			var obj_file = File.new()
			var open_err = obj_file.open(to, File.READ)
			if open_err == OK:
				var obj_contents = obj_file.get_as_text()
				obj_file.close()
				
				obj_contents = obj_contents.replace("mtllib ", "mtllib " + to.get_base_dir() + "/")
				
				open_err = obj_file.open(to, File.WRITE)
				if open_err == OK:
					obj_file.store_string(obj_contents)
					obj_file.close()
				else:
					push_error("Could not write to file at '%s'." % to)
			else:
				push_error("Could not read file at '%s'." % to)
	
	if EXTENSIONS_TO_IMPORT.has(from.get_extension()):
		return _importer.import(to)
	else:
		return OK

# Import a stack configuration file.
# pack: The name of the pack.
# type: The type of the assets.
# stack_config: The stack config file.
func _import_stack_config(pack: String, type: String, stack_config: ConfigFile) -> void:
	for stack_name in stack_config.get_sections():
		var desc = stack_config.get_value(stack_name, "desc", "")
		var items = stack_config.get_value(stack_name, "items")
		
		if items and items is Array:
			var masses = []
			var texture_paths = []
			var scale = null
			for item in items:
				var mass = 1.0
			
				# We know everything but the scale of the piece at this point.
				# So, we need to scan through the DB to find the texture, then
				# see what the scale of that texture's piece is.
				if not scale:
					if _db.has(pack):
						if _db[pack].has(type) and _db[pack][type] is Array:
							var piece_entry = null
							
							for piece in _db[pack][type]:
								if piece.has("texture_path") and piece["texture_path"] is String:
									if piece["texture_path"].ends_with(item):
										piece_entry = piece
										break
							
							if piece_entry and piece_entry.has("scale"):
								scale = piece_entry["scale"]
								if piece_entry.has("mass"):
									mass = piece_entry["mass"]
							else:
								push_error("Could not determine scale of %s!" % item)
				
				# TODO: Check the file exists.
				masses.push_back(mass)
				var texture_path = "user://assets/" + pack + "/" + type + "/" + item
				texture_paths.push_back(texture_path)
			
			if scale:
				var type_meta = ASSET_PACK_SUBFOLDERS[type]
				var type_scene = type_meta["scene"]
				
				var stack_entry = {
					"description": desc,
					"masses": masses,
					"name": stack_name,
					"scale": scale,
					"scene_path": type_scene,
					"texture_paths": texture_paths
				}
				
				_add_entry_to_db(pack, type, stack_entry)
			else:
				print("Could not determine scale of stack %s!" % stack_name)
		else:
			push_error("Stack %s has no item array!" % stack_name)

# Function used to binary search an array of asset entries by name.
func _search_assets(element: Dictionary, search: String) -> bool:
	return element["name"] < search

# Send the completed signal.
# dir_found: Was there an asset directory?
func _send_completed_signal(dir_found: bool) -> void:
	_import_mutex.lock()
	_import_dir_found = dir_found
	_import_file_path = ""
	_import_send_signal = true
	_import_mutex.unlock()

# Send the importing file signal.
# file: The path of the file being imported.
# files_imported: The number of files imported so far.
# files_total: The total number of files.
func _send_importing_file_signal(file: String, files_imported: int, files_total: int) -> void:
	_import_mutex.lock()
	_import_file_path = file
	_import_files_imported = files_imported
	_import_files_total = files_total
	_import_send_signal = true
	_import_mutex.unlock()

# Function used to sort an array of asset entries.
func _sort_assets(a: Dictionary, b: Dictionary) -> bool:
	return a["name"] < b["name"]

func _on_exiting_tree() -> void:
	if _import_thread.is_active():
		_import_thread.wait_to_finish()
