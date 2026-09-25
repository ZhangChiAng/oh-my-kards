import { readFile, writeFile, mkdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { connectServers, textResult, projectRoot } from './client.mjs';

const parentDir = process.argv[2] && path.resolve(process.argv[2]);
if (!parentDir || process.argv.length !== 3) throw new Error('Usage: node tools/mcp/verify.mjs <CLI verification directory>');
const manifestPath = path.join(parentDir, 'verification.json');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
if (manifest.automated_status !== 'passed') throw new Error('CLI rules and UI checks must pass first.');
if (path.resolve(manifest.project_path).toLowerCase() !== projectRoot.toLowerCase()) throw new Error('CLI report belongs to another project.');
const scenePath = 'res://scenes/battle.tscn';
if (scenePath !== manifest.scene_path || scenePath !== manifest.checks?.ui?.scene_path) {
  throw new Error('MCP requires the battle scene that passed CLI UI verification.');
}
const outputDir = path.join(parentDir, 'mcp-' + Date.now());
await mkdir(outputDir, { recursive: true });
const report = {
  run_id: manifest.run_id, scene_path: scenePath, status: 'failed', assertions: 0, failures: [], trace: [], screenshots: [],
  coverage: { mulligan: false, geometry: false, card_hover: false, deployment: 'pending', settings: false, development_entries_absent: false, presentation_identity: false, restart: false, history: false, logs: false },
  started_at: new Date().toISOString(),
};
const testSeed = 20260917;
const launchName = '_mcp_launch_' + randomUUID().replaceAll('-', '');
const launchScene = 'res://tests/' + launchName + '.tscn';
const launchScriptPath = path.join(projectRoot, 'tests', launchName + '.gd');
const launchScenePath = path.join(projectRoot, 'tests', launchName + '.tscn');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let session, battleNodePath, gameRunId, lastSnapshot;
let viewportBounds;
let launchPrepared = false;
let mouseSequence = 0;

function check(condition, message) {
  report.assertions++;
  if (!condition) throw new Error(message);
}
async function call(server, name, args = {}, evidence = false) {
  const response = await session.call(server, name, args, { evidence });
  const value = response.result.structuredContent ?? textResult(response);
  check(!response.result.isError && !value?.error && !value?.runtime_errors?.length,
    name + ': ' + JSON.stringify(value));
  return { value, ...response };
}
async function poll(label, read, predicate, timeout = 10000) {
  const deadline = Date.now() + timeout;
  let value;
  do {
    value = await read();
    if (predicate(value)) return value;
    await delay(100);
  } while (Date.now() < deadline);
  throw new Error(label + ' timed out.');
}
function idle(snapshot) {
  return snapshot.interaction.state === 'idle' && !snapshot.interaction.presentation_busy;
}
async function state() {
  const response = await call('runtime', 'godot_exec', { action: 'run', source:
    'var battle = root.get_node_or_null(' + JSON.stringify(battleNodePath) + ')\n' +
    'if battle == null:\n\treturn JSON.stringify({"error": "Battle node disappeared"})\n' +
    'return JSON.stringify({"state": battle._mcp_state(), "scene_path": battle.scene_file_path})' });
  check(typeof response.value.result === 'string', 'State transport did not return a JSON String.');
  const observed = JSON.parse(response.value.result);
  check(observed.scene_path === scenePath, 'Actually running battle differs from the verified target scene.');
  report.loaded_scene_path = observed.scene_path;
  const snapshot = observed.state;
  check(!snapshot.error && !snapshot._truncated && !!snapshot.units && !!snapshot.ui_controls,
    'Battle snapshot is incomplete.');
  check(snapshot.seed === testSeed && typeof snapshot.run_id === 'string' && snapshot.run_id.length > 0,
    'Snapshot lacks the fixed seed or game run ID.');
  gameRunId ??= snapshot.run_id;
  check(snapshot.run_id === gameRunId && Number.isInteger(snapshot.battle_number),
    'Game identity changed during the smoke check.');
  check(snapshot.presentation && ['geometry_id', 'geometry_fingerprint', 'motion_id', 'motion_fingerprint',
    'profile_id', 'render_mode', 'material_fingerprint', 'appearance_fingerprint'].every(key =>
    typeof snapshot.presentation[key] === 'string' && snapshot.presentation[key].length > 0),
    'Snapshot lacks actual presentation configuration identity.');
  check(snapshot.presentation.render_mode === 'material' && snapshot.presentation.background_texture === 'res://assets/art/backgrounds/ancient-metal-v1.png', 'Normal startup did not display the selected tabletop material.');
  report.presentation = snapshot.presentation;
  report.coverage.presentation_identity = true;
  lastSnapshot = snapshot;
  return snapshot;
}
async function checkpoint(label, predicate = idle) {
  const snapshot = await poll(label, state, predicate, 20000);
  const filename = label + '-state.json';
  await writeFile(path.join(outputDir, filename), JSON.stringify(snapshot, null, 2));
  report.trace.push({ label, file: filename, run_id: snapshot.run_id, battle_number: snapshot.battle_number,
    phase: snapshot.phase, turn: snapshot.turn, active_side: snapshot.active_side });
  return snapshot;
}
function hitPoint(snapshot, key, requireEnabled = true) {
  const control = snapshot.ui_controls[key];
  check(control && control.w > 0 && control.h > 0 && Number.isFinite(control.hit_point?.x)
    && Number.isFinite(control.hit_point?.y), 'Missing actual hit point for ' + key);
  check(!requireEnabled || control.enabled, 'Disabled control: ' + key);
  check(viewportBounds && control.hit_point.x >= viewportBounds.x && control.hit_point.y >= viewportBounds.y
    && control.hit_point.x < viewportBounds.x + viewportBounds.w && control.hit_point.y < viewportBounds.y + viewportBounds.h,
  'Safe input point lies outside the actual logical viewport: ' + key);
  return control.hit_point;
}
async function geometry(snapshot) {
  const response = await call('runtime', 'godot_exec', { action: 'run', source:
    'var rect = root.get_visible_rect()\n' +
    'return JSON.stringify({"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y, "window_width": root.size.x, "window_height": root.size.y})' });
  viewportBounds = JSON.parse(response.value.result);
  check(viewportBounds.w > 0 && viewportBounds.h > 0, 'Runtime viewport has no visible area.');
  for (const key of Object.keys(snapshot.ui_controls)) hitPoint(snapshot, key, false);
  report.viewport = viewportBounds;
  report.coverage.geometry = true;
}
async function hoverCard(snapshot) {
  const id = snapshot.sides.player.hand_ids[0];
  if (!id) throw new Error('Expected at least one hand card for the hover smoke check.');
  const before = JSON.stringify({ units: snapshot.units, sides: snapshot.sides, phase: snapshot.phase, turn: snapshot.turn });
  const point = hitPoint(snapshot, 'hand:' + id, false);
  const timing = await call('runtime', 'godot_exec', { action: 'run', source:
    'return root.get_node(' + JSON.stringify(battleNodePath) + ')._view.motion.detail_delay_seconds + root.get_node(' + JSON.stringify(battleNodePath) + ')._view.motion.hover_seconds' });
  check(typeof timing.value.result === 'number' && timing.value.result >= 0, 'Hover motion duration is unavailable.');
  await input(motion(point));
  await delay(timing.value.result * 1000 + 50);
  const response = await call('runtime', 'godot_exec', { action: 'run', source:
    'var battle = root.get_node(' + JSON.stringify(battleNodePath) + ')\n' +
    'var card = battle._view._cards.get(' + JSON.stringify(id) + ')\n' +
    'return JSON.stringify({"hover_id": battle._view._hover_id, "name": card.display_data.get("name", ""), "rule_description": card.display_data.get("rule_description", ""), "full_card": card.mode == "full", "fits": root.get_visible_rect().encloses(card.screen_rect()), "cursor": {"x": battle._view._cursor.x, "y": battle._view._cursor.y}, "detail_key": battle._view._detail_key, "detail_visible": battle._view._rules_detail.visible, "detail_elapsed_ms": Time.get_ticks_msec() - battle._view._detail_started_msec})' });
  const detail = JSON.parse(response.value.result);
  report.hover_observation = { expected_id: id, input_point: point, wait_seconds: timing.value.result, ...detail };
  await writeFile(path.join(outputDir, "hover-observation.json"), JSON.stringify(report.hover_observation, null, 2));
  check(detail.hover_id === id && detail.name === snapshot.units[id].name && detail.rule_description && detail.detail_key === "hand:" + id && detail.detail_visible
    && detail.full_card && detail.fits, 'Actual hand hover does not expose the full card inside the viewport.');
  const after = await state();
  check(JSON.stringify({ units: after.units, sides: after.sides, phase: after.phase, turn: after.turn }) === before,
    'Card hover changed the domain snapshot.');
  report.coverage.card_hover = true;
  await input(motion({ x: 8, y: 8 }, false, point));
  await poll('hover clears before the next input', async () => {
    const cleared = await call('runtime', 'godot_exec', { action: 'run', source:
      'return root.get_node(' + JSON.stringify(battleNodePath) + ')._view._hover_id' });
    return cleared.value.result;
  }, value => value === '');
  return state();
}
function motion(point, held = false, previous = point) {
  const name = 'motion_' + ++mouseSequence;
  return `var ${name} := InputEventMouseMotion.new()
${name}.position = root.get_final_transform() * Vector2(${point.x}, ${point.y})
${name}.global_position = ${name}.position
${name}.relative = root.get_final_transform().basis_xform(Vector2(${point.x - previous.x}, ${point.y - previous.y}))
${name}.button_mask = ${held ? 'MOUSE_BUTTON_MASK_LEFT' : '0'}
Input.parse_input_event(${name})`;
}
function button(point, pressed) {
  const name = 'button_' + ++mouseSequence;
  return `var ${name} := InputEventMouseButton.new()
${name}.position = root.get_final_transform() * Vector2(${point.x}, ${point.y})
${name}.global_position = ${name}.position
${name}.button_index = MOUSE_BUTTON_LEFT
${name}.button_mask = ${pressed ? 'MOUSE_BUTTON_MASK_LEFT' : '0'}
${name}.pressed = ${pressed}
Input.parse_input_event(${name})`;
}
function key(code) {
  const name = 'key_' + ++mouseSequence;
  return `for pressed in [true, false]:
\tvar ${name} := InputEventKey.new()
\t${name}.keycode = ${code}
\t${name}.physical_keycode = ${code}
\t${name}.pressed = pressed
\tInput.parse_input_event(${name})`;
}
function domainSnapshot(snapshot) {
  const { interaction, ui_controls, history, presentation, run_id, battle_number, legal_actions, ...domain } = snapshot;
  return JSON.stringify(domain);
}
async function captureNative(label) {
  // The pinned addon treats zero as native size, preserving 1080p and 4K details.
  const screenshot = await call('runtime', 'godot_editor_read', { action: 'screenshot_game', max_width: 0 }, true);
  const image = screenshot.record.content.find(item => item.type === 'image');
  check(!!image?.file, 'Game screenshot missing: ' + label);
  const png = await readFile(path.join(outputDir, image.file));
  check(png.length >= 24 && png.toString('ascii', 1, 4) === 'PNG', 'Screenshot is not a readable PNG.');
  const dimensions = { width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
  check(dimensions.width === viewportBounds.window_width && dimensions.height === viewportBounds.window_height,
    'MCP screenshot was resized instead of preserving the native viewport.');
  report.screenshot_dimensions = dimensions;
  report.screenshots.push(path.relative(parentDir, path.join(outputDir, image.file)));
  const snapshot = await state();
  const sidecar = path.join(outputDir, image.file + '.json');
  await writeFile(sidecar, JSON.stringify({ run_id: manifest.run_id, game_run_id: snapshot.run_id,
    scene_path: scenePath, seed: testSeed, battle_number: snapshot.battle_number,
    presentation: snapshot.presentation, viewport: viewportBounds, dimensions, state: snapshot }, null, 2));
  report.trace.push({ label: 'screenshot-' + label, dimensions, scene_path: scenePath,
    presentation: snapshot.presentation, sidecar: path.relative(parentDir, sidecar) });
}
async function input(source) {
  await call('runtime', 'godot_exec', { action: 'run', source: source + '\nreturn true' }, true);
}
async function click(snapshot, key) {
  const point = hitPoint(snapshot, key);
  await input(motion(point) + '\n' + button(point, true));
  await delay(35);
  await input(button(point, false));
  await delay(70);
}
async function deploy(snapshot, action) {
  const from = hitPoint(snapshot, 'hand:' + action.unit_id);
  await input(motion(from) + '\n' + button(from, true));
  await poll('deployment press', state, s => s.interaction.state === 'pressed' && s.interaction.source_id === action.unit_id);
  const lifted = { x: from.x, y: from.y - 20 };
  await input(motion(lifted, true, from));
  const dragging = await poll('deployment drag', state, s => s.interaction.state === 'dragging');
  const key = 'support:player:' + action.insert_index;
  check(dragging.interaction.legal_target_keys.includes(key), 'Deployment insertion target is not legal: ' + key);
  const to = hitPoint(dragging, key);
  await input(motion(to, true, lifted));
  await delay(35);
  await input(button(to, false));
  const after = await checkpoint('deployed', s => idle(s) && s.sides.player.support_ids.includes(action.unit_id));
  check(after.sides.player.command_points === snapshot.sides.player.command_points - snapshot.units[action.unit_id].deploy_cost,
    'Deployment did not spend its cost.');
  report.coverage.deployment = 'passed';
  return after;
}
async function prepareLaunch() {
  launchPrepared = true;
  await writeFile(launchScriptPath, 'extends Node\n\nfunc _ready() -> void:\n\tvar battle = load(' + JSON.stringify(scenePath) + ').instantiate()\n\tbattle.seed_override = ' + testSeed + '\n\tadd_child(battle)\n', { flag: 'wx' });
  await writeFile(launchScenePath, '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://tests/' + launchName + '.gd" id="1"]\n\n[node name="MCPFixedSeed" type="Node"]\nscript = ExtResource("1")\n', { flag: 'wx' });
  await call('runtime', 'godot_editor_edit', { action: 'rescan' });
  await call('runtime', 'godot_editor_edit', { action: 'run', scene_path: launchScene }, true);
  const digest = await poll('runtime discovery', async () => {
    const response = await session.call('runtime', 'godot_runtime_state', { action: 'digest', select: 'group', group: 'mcp_watch', include: ['state'] });
    const value = response.result.structuredContent ?? textResult(response);
    if (response.result.isError) {
      check(/TIMEOUT|NOT_RUNNING|NOT_READY|NO_GAME|NO_SESSION|No game|not running/i.test(JSON.stringify(value)),
        'Unexpected startup error: ' + JSON.stringify(value));
      return null;
    }
    const entities = (value.entities ?? []).filter(entity => entity.type === 'Control' && entity.state);
    check(!value.nodes_truncated && entities.length <= 1, 'Ambiguous runtime battle node.');
    return entities[0];
  }, value => !!value, 20000);
  battleNodePath = digest.path;
  report.state_transport = { node_path: battleNodePath, digest_truncated: digest.state._truncated === true,
    snapshot: 'read-only _mcp_state() as JSON String; digest is capped by the pinned addon' };
}
async function verifyLogs(snapshot) {
  let entries = [];
  const records = await poll('current game logs', async () => {
    const response = await call('diagnostics', 'get_console_output');
    entries = response.value.entries ?? [];
    const found = [];
    for (const entry of entries) {
      const message = String(entry.message ?? '');
      check(!/output overflow|print less text|SCRIPT ERROR|ERROR:|Parse Error/i.test(message), 'Game console contains errors or overflow.');
      for (const line of message.split(/\r?\n/)) {
        if (!line.includes('battle_action')) continue;
        const record = JSON.parse(line.trim());
        if (record.run_id !== snapshot.run_id) continue;
        check(record.seed === testSeed && Number.isInteger(record.battle_number)
          && record.battle_number > 0 && record.battle_number <= snapshot.battle_number,
          'Action log has an invalid seed or battle generation.');
        // A real settings restart keeps the game run ID and advances its battle generation.
        if (record.battle_number !== snapshot.battle_number) continue;
        found.push(record);
      }
    }
    return found;
  }, values => values.some(record => record.actor === 'player' && record.action?.type === 'mulligan' && record.accepted));
  await writeFile(path.join(outputDir, 'game-log.json'), JSON.stringify(entries, null, 2));
  report.log_records = records.length;
  report.coverage.logs = true;
}

try {
  session = await connectServers(outputDir);
  const project = await call('runtime', 'godot_project', { action: 'get_info' });
  check(JSON.stringify(project.value).replaceAll('\\\\', '/').toLowerCase().includes(projectRoot.replaceAll('\\', '/').toLowerCase()),
    'MCP is connected to another project.');
  await call('runtime', 'godot_editor_edit', { action: 'stop' });
  await poll('previous game stop', async () => (await call('runtime', 'godot_editor_read', { action: 'get_state' })).value,
    value => !value.is_playing);
  await call('runtime', 'godot_editor_read', { action: 'get_log_messages', clear: true, limit: 1000 });
  await prepareLaunch();
  let snapshot = await checkpoint('opening', s => idle(s) && s.phase === 'mulligan');
  await geometry(snapshot);
  report.game_run_id = snapshot.run_id;
  // Attach before the first input so DAP observes its action log.
  await call('diagnostics', 'get_console_output');
  await click(snapshot, 'mulligan_confirm');
  snapshot = await checkpoint('confirmed', s => idle(s) && s.phase !== 'mulligan'
    && (s.active_side === 'player' || s.phase === 'finished'));
  check(snapshot.sides.player.mulligan_done && snapshot.sides.ai.mulligan_done, 'Opening confirmation failed.');
  report.coverage.mulligan = true;
  await geometry(snapshot);
  snapshot = await hoverCard(snapshot);
  const action = snapshot.legal_actions.find(candidate => candidate.type === 'deploy');
  if (action) snapshot = await deploy(snapshot, action);
  else report.coverage.deployment = 'unavailable in the opening turn; covered by CLI UI smoke';
  const before = domainSnapshot(snapshot);
  const oldBattle = snapshot.battle_number;
  await click(snapshot, 'settings');
  snapshot = await checkpoint('settings', s => idle(s) && !!s.ui_controls.restart);
  check(domainSnapshot(snapshot) === before && !Object.values(snapshot.ui_controls).some(control => control.draggable),
    'Opening settings changed the rules or left a draggable card.');
  await input(key('KEY_SPACE'));
  snapshot = await state();
  check(domainSnapshot(snapshot) === before, 'Settings failed to block the end-turn key.');
  await captureNative('settings');
  check(!Object.keys(snapshot.ui_controls).some(key => /^(?:workshop|theme)/i.test(key))
    && !('workshop' in snapshot), 'Development-only controls or workshop state reappeared in battle.');
  const developmentNodes = await call('runtime', 'godot_exec', { action: 'run', source:
    'var pending = [root.get_node(' + JSON.stringify(battleNodePath) + ')]\n' +
    'while not pending.is_empty():\n\tvar node = pending.pop_back()\n\tvar script = node.get_script()\n' +
    '\tif script != null and script.resource_path == "res://scripts/workshop/card_workshop.gd":\n\t\treturn true\n' +
    '\tpending.append_array(node.get_children())\nreturn false' });
  check(developmentNodes.value.result === false, 'Normal battle instantiated a hidden workshop.');
  report.coverage.development_entries_absent = true;
  await click(snapshot, 'restart');
  // request_restart invalidates the old session, then local assembly attaches the new one.
  snapshot = await checkpoint('restarted', s => idle(s) && s.battle_number === oldBattle + 2 && s.phase === 'mulligan');
  await click(snapshot, 'mulligan_confirm');
  snapshot = await checkpoint('reconfirmed', s => idle(s) && s.phase === 'active' && s.active_side === 'player');
  check(snapshot.history.open === false && !snapshot.ui_controls.history_toggle && !snapshot.ui_controls.history_scroll,
    'Deleted history controls reappeared.');
  report.coverage.settings = true;
  report.coverage.restart = true;
  check(Array.isArray(snapshot.history.entries), 'History entries are not observable.');
  check(snapshot.history.entries.every(entry => !['card_drawn', 'mulligan_completed', 'hand_overflow'].includes(entry.type)
    || Object.values(snapshot.units).every(unit => !JSON.stringify(entry).includes(unit.instance_id) && !JSON.stringify(entry).includes(unit.name))),
  'Public draw or mulligan history exposes a hidden card identity.');
  report.coverage.history = true;
  await captureNative('battle');
  await verifyLogs(snapshot);
  const errors = await call('runtime', 'godot_editor_read', { action: 'get_log_messages', severity: 'error', limit: 1000 }, true);
  check(typeof errors.value === 'string' ? /^No (?:new )?error messages/.test(errors.value)
    : errors.value.returned_count === 0, 'Editor contains unexpected errors.');
  report.status = 'passed';
} catch (error) {
  report.failures.push(error.stack ?? String(error));
  if (lastSnapshot) await writeFile(path.join(outputDir, 'failure-state.json'), JSON.stringify(lastSnapshot, null, 2));
  process.exitCode = 1;
} finally {
  try {
    if (session) await call('runtime', 'godot_editor_edit', { action: 'stop' });
    if (launchPrepared) {
      for (const file of [launchScriptPath, launchScenePath, launchScriptPath + '.uid', launchScenePath + '.uid']) {
        await unlink(file).catch(error => { if (error.code !== 'ENOENT') throw error; });
      }
      if (session) await call('runtime', 'godot_editor_edit', { action: 'rescan' });
    }
    report.launch_cleanup = 'passed';
  } catch (error) {
    report.status = 'failed';
    report.failures.push('Launch cleanup: ' + error.message);
    process.exitCode = 1;
  }
  if (session) await session.close();
  report.completed_at = new Date().toISOString();
  await writeFile(path.join(outputDir, 'mcp-result.json'), JSON.stringify(report, null, 2));
  manifest.mcp = { status: report.status, assertions: report.assertions, scene_path: scenePath,
    report: path.join(outputDir, 'mcp-result.json') };
  manifest.status = report.status === 'failed' ? 'failed' : manifest.automated_status;
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(JSON.stringify({ status: report.status, assertions: report.assertions, coverage: report.coverage, outputDir }));
}
