import { mkdir, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { connectServers, textResult, projectRoot } from './client.mjs';

// Run after changing the diagnostics adapter, MCP dependencies, or Godot.
const runId = 'diagnostics-' + Date.now();
const outputDir = path.join(path.resolve(process.argv[2] ?? path.join(projectRoot, 'artifacts')), runId);
await mkdir(outputDir, { recursive: true });
const report = { run_id: runId, status: 'failed', assertions: 0, failures: [], trace: [] };
const probePath = path.join(projectRoot, 'tests', '_mcp_probe_' + randomUUID().replaceAll('-', '') + '.gd');
const broken = 'extends RefCounted\n# 中文诊断回归：错误与修复必须刷新\nfunc probe( -> int:\n\treturn 42\n';
const repaired = 'extends RefCounted\n# 中文诊断回归：确认 UTF-8 消息边界正确\nfunc probe() -> String:\n\treturn "攻击"\n';
let session, created = false;
function check(condition, message) {
  report.assertions++;
  if (!condition) throw new Error(message);
}
try {
  session = await connectServers(outputDir, ['diagnostics']);
  await writeFile(probePath, broken, { flag: 'wx' });
  created = true;
  // Re-use one URI to cover repeated didOpen/didChange and UTF-8 framing.
  for (const [index, expectError] of [true, false, true, false, true, false].entries()) {
    await writeFile(probePath, expectError ? broken : repaired);
    const response = await session.call('diagnostics', 'get_diagnostics', { file_path: probePath }, { evidence: true });
    const value = response.result.structuredContent ?? textResult(response);
    check(!response.result.isError && !value?.error, 'Diagnostics tool failed: ' + JSON.stringify(value));
    check(value.diagnostics && typeof value.diagnostics === 'object', 'Diagnostics payload is missing.');
    const errors = Object.values(value.diagnostics).flat().filter(item => item.severity === 1 || item.severity === 'error');
    check(expectError ? errors.length > 0 : errors.length === 0, 'Stale diagnostics at step ' + index);
    report.trace.push({ step: index, expected_error: expectError, errors: errors.length });
  }
  report.status = 'passed';
} catch (error) {
  report.failures.push(error.stack ?? String(error));
  process.exitCode = 1;
} finally {
  try {
    if (created) {
      for (const file of [probePath, probePath + '.uid']) {
        await unlink(file).catch(error => { if (error.code !== 'ENOENT') throw error; });
      }
    }
  } catch (error) {
    report.status = 'failed';
    report.failures.push('Probe cleanup: ' + error.message);
    process.exitCode = 1;
  }
  if (session) await session.close();
  await writeFile(path.join(outputDir, 'diagnostics-result.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ status: report.status, assertions: report.assertions, outputDir }));
}
