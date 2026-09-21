extends Resource
## Shared design coordinates and text constraints. No textures or skin overrides.
@export var geometry_id: String = ""
@export var layout: Dictionary = {}
@export var templates: Dictionary = {}


func template(mode: String) -> Resource:
	return templates.get(mode) as Resource


func spec() -> Dictionary:
	var definitions: Dictionary = {}
	var modes: Array = templates.keys()
	modes.sort()
	for mode in modes:
		var definition: Resource = template(str(mode))
		definitions[mode] = definition.spec() if definition != null else {}
	return {"geometry_id": geometry_id, "layout": layout.duplicate(true), "templates": definitions}
