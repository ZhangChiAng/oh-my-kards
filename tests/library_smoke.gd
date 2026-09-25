extends SceneTree
## Runs persistent-library contracts without opening a user's collection.
const StoreTests = preload("res://tests/workshop_store_test.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var output_dir := ""
	var run_id := ""
	var library_root := ""
	for index in range(args.size() - 1):
		if args[index] == "--output-dir": output_dir = args[index + 1]
		elif args[index] == "--run-id": run_id = args[index + 1]
		elif args[index] == "--card-library-root": library_root = args[index + 1]
	var artifact_path: String = ProjectSettings.globalize_path("res://artifacts").replace("\\", "/").simplify_path().to_lower().trim_suffix("/")
	var output_path: String = ProjectSettings.globalize_path(output_dir).replace("\\", "/").simplify_path().to_lower().trim_suffix("/")
	var library_path: String = ProjectSettings.globalize_path(library_root).replace("\\", "/").simplify_path().to_lower().trim_suffix("/")
	if output_dir.is_empty() or run_id.is_empty() or library_root.is_empty() or not output_path.begins_with(artifact_path + "/") or not library_path.begins_with(output_path + "/"):
		push_error("Library tests require explicit output, run ID and isolated library root")
		quit(2)
		return
	var checks: Array = StoreTests.new().run(library_root)
	var failures: Array = []
	for check: Dictionary in checks:
		if not check.ok: failures.append(check.caption)
	var result := {"run_id": run_id, "status": "passed" if failures.is_empty() else "failed", "assertions": checks.size(), "failures": failures, "trace": checks}
	var file := FileAccess.open(output_dir.path_join("library-result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	quit(0 if failures.is_empty() else 1)
