extends RefCounted
## Resolves diagnostic display without mutating or replacing the selected material.
const ArtProfile = preload("res://scripts/art/art_profile.gd")
const DebugStyle = preload("res://resources/art/geometry_debug_style.tres")
const VisualTheme = preload("res://scripts/art/visual_theme.gd")


static func resolve(source: Resource, geometry_debug: bool) -> Resource:
	assert(source != null and source.visual_theme != null, "An explicit material profile is required")
	return geometry_only(source.profile_id) if geometry_debug else source


static func geometry_only(source_id: String = "geometry_inspection") -> Resource:
	var display := ArtProfile.new()
	display.profile_id = source_id
	display.visual_theme = VisualTheme.new()
	# Fixed diagnostic surfaces have no reference to production textures or artwork.
	display.visual_theme.surface = DebugStyle.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	return display
