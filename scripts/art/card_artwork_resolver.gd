extends RefCounted
## Resolves saved artwork references equally for the editor and battle.
const ArtworkLibrary = preload("res://scripts/art/artwork_library.gd")
const LIBRARY_PATH := "res://resources/art/illustrations/library.tres"


static func resolve_source(source: String, image_root: String) -> Texture2D:
	if source.is_empty(): return null
	if source.begins_with("library:"):
		var library: Resource = load(LIBRARY_PATH)
		return library.resolve(source) if library != null else null
	if source.begins_with("image:"):
		var id: String = source.trim_prefix("image:")
		if id.length() != 32 or not id.is_valid_hex_number(false): return null
		var path: String = image_root.path_join(id + ".png")
		if not FileAccess.file_exists(path): return null
		var loaded_image := Image.load_from_file(path)
		if loaded_image == null or loaded_image.is_empty(): return null
		return ImageTexture.create_from_image(loaded_image)
	return null


static func configure_profile(profile: Resource, records: Array, image_root: String) -> void:
	var resolved: Resource = ArtworkLibrary.new()
	var has_artwork: bool = false
	for record: Dictionary in records:
		var source: String = str(record.get("artwork", {}).get("source", ""))
		if source.is_empty(): continue
		var texture: Texture2D = resolve_source(source, image_root)
		if texture == null: continue
		has_artwork = true
		if source.begins_with("library:"): resolved.images[source.trim_prefix("library:")] = texture
		else: resolved.register_texture(source, texture)
	profile.artworks = resolved if has_artwork else null
