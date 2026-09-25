import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { mkdir, writeFile, appendFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

// This client uses the same pinned servers and environment as the Codex config.
// It enables repeatable tool-level acceptance without requiring a live chat restart.
export async function connectServers(outputDir, servers = ['runtime', 'diagnostics']) {
  await mkdir(outputDir, { recursive: true });
  const entries = {
    runtime: ['@satelliteoflove/godot-mcp/dist/cli.js', { GODOT_HOST: '127.0.0.1', GODOT_PORT: '6550' }],
    diagnostics: ['../diagnostics-server.mjs', {
      GODOT_WORKSPACE_PATH: projectRoot, GODOT_LSP_PORT: '6005', GODOT_DAP_PORT: '6006',
    }],
  };
  const clients = {};
  const schemas = {};
  let callIndex = 0;
  async function close() {
    await Promise.allSettled(Object.values(clients).map(client => client.close()));
  }
  try {
    for (const name of servers) {
      const [entry, environment] = entries[name];
      const transport = new StdioClientTransport({
        command: process.execPath,
        args: [path.join(projectRoot, 'tools/mcp/node_modules', entry)],
        cwd: projectRoot,
        env: { ...process.env, ...environment },
        stderr: 'pipe',
      });
      const client = new Client({ name: 'oh-my-kards-verifier', version: '0.1.0' });
      clients[name] = client;
      transport.stderr?.on('data', data => {
        appendFile(path.join(outputDir, `${name}-server.log`), data).catch(() => {});
      });
      await client.connect(transport, { timeout: 60000 });
      const schema = await client.listTools();
      schemas[name] = schema.tools;
      await writeFile(path.join(outputDir, `${name}-tools.json`), JSON.stringify(schema, null, 2));
    }
  } catch (error) { await close(); throw error; }
  async function call(server, name, args = {}, { evidence = false } = {}) {
    const id = String(++callIndex).padStart(3, '0');
    const timestamp = new Date().toISOString();
    const schema = schemas[server]?.find(tool => tool.name === name)?.inputSchema;
    if (!schema) throw new Error(`Tool ${server}/${name} was not discovered in this session.`);
    for (const key of schema.required ?? []) {
      if (!Object.hasOwn(args, key)) throw new Error(`Missing ${name} argument: ${key}`);
    }
    for (const [key, value] of Object.entries(args)) {
      const property = schema.properties?.[key];
      if (!property || (property.enum && !property.enum.includes(value))) {
        throw new Error(`Argument ${name}.${key} does not match the discovered schema.`);
      }
    }
    let result;
    try {
      result = await clients[server].callTool({ name, arguments: args }, undefined, { timeout: 60000 });
    } catch (error) {
      await writeFile(path.join(outputDir, `${id}-${name}-failure.json`), JSON.stringify({ timestamp, server, name, args, error: error.message }, null, 2));
      throw error;
    }
    const record = structuredClone(result);
    const value = result.structuredContent ?? textResult({ result });
    const failed = result.isError || value?.error || value?.runtime_errors?.length;
    for (const [index, item] of (record.content ?? []).entries()) {
      if (item.type === 'image') {
        const filename = `${id}-${name}-${index}.png`;
        await writeFile(path.join(outputDir, filename), Buffer.from(item.data, 'base64'));
        record.content[index] = { type: 'image', mimeType: item.mimeType, file: filename };
      }
    }
    if (evidence || failed) {
      await writeFile(path.join(outputDir, `${id}-${name}.json`), JSON.stringify({ timestamp, server, name, args, result: record }, null, 2));
      console.log(JSON.stringify({ call: id, server, tool: name, action: args.action, isError: !!failed }));
    }
    return { result, record };
  }
  return { call, close };
}

export function textResult(response) {
  const text = (response.result.content ?? []).filter(item => item.type === 'text').map(item => item.text).join('\n');
  try { return JSON.parse(text); } catch { return text; }
}
