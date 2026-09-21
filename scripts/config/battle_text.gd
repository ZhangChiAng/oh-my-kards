extends Resource
## Visible battle copy and unit explanations, independent of concrete cards.

@export var captions: Dictionary = {}
@export var unit_types: Dictionary = {}


func caption(key: String) -> String:
	return str(captions.get(key, ""))


func type_name(kind: String) -> String:
	return str(unit_types.get(kind, {}).get("name", kind))


func type_brief(kind: String) -> String:
	return str(unit_types.get(kind, {}).get("brief", ""))


func type_description(kind: String) -> String:
	return str(unit_types.get(kind, {}).get("description", ""))
