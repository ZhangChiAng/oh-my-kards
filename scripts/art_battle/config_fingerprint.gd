extends RefCounted
## Stable identity of resource configuration; no asset loading or pixel inspection.

static func of(value: Variant) -> String:
	return JSON.stringify(_plain(value)).sha256_text()


static func _plain(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		for key in keys: result[str(key)] = _plain(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value: result.append(_plain(item))
		return result
	if value is Resource:
		var data: Dictionary = {"type": value.get_class()}
		if value.get_script() != null: data["script"] = value.get_script().resource_path
		for property in value.get_property_list():
			var key: String = property.name
			if int(property.usage) & PROPERTY_USAGE_STORAGE and key not in ["script", "resource_path", "resource_name", "resource_local_to_scene"]:
				data[key] = _plain(value.get(key))
		return _plain(data)
	if value == null or value is String or value is bool or value is int or value is float: return value
	return var_to_str(value)
