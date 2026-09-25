#!/usr/bin/env node
/**
 * Compatibility entry point for minimal-godot-mcp 0.1.6 + Godot 4.7.2.
 *
 * The pinned upstream client sends didOpen for every check. Godot rejects an
 * already-open document, leaving diagnostics for the previous text cached.
 * Track documents per connection, send full-text didChange after the first
 * didOpen, and wait for fresh diagnostics plus a post-save request response.
 * The documentSymbol response is a processing barrier for this pinned Godot
 * server, preventing a delayed second notification from fulfilling the next
 * check. This is not a general ordering guarantee for every LSP server.
 * A timeout/closed connection is an error, never an empty diagnostic result.
 *
 * Upstream also frames LSP messages using JavaScript string lengths. LSP lengths
 * are UTF-8 bytes; Chinese source text and split UTF-8 packets require Buffer
 * framing in both directions. These overrides affect only LSP transport and
 * document synchronization, preserving upstream MCP schemas and DAP behavior.
 * No files in node_modules are patched; npm ci reproduces the pinned package.
 * Remove/re-evaluate this adapter when upgrading the exact version below.
 */
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { LSPClient } from './node_modules/@ryanmazzolini/minimal-godot-mcp/dist/lsp-client.js';
import { fromFileUri, toFileUri } from './node_modules/@ryanmazzolini/minimal-godot-mcp/dist/uri-utils.js';

const packageRoot = new URL('./node_modules/@ryanmazzolini/minimal-godot-mcp/', import.meta.url);
const packageInfo = JSON.parse(await readFile(new URL('package.json', packageRoot), 'utf8'));
if (packageInfo.version !== '0.1.6') {
  throw new Error(`Godot diagnostics adapter requires minimal-godot-mcp 0.1.6; found ${packageInfo.version}. Review the adapter before upgrading.`);
}

const prototype = LSPClient.prototype;
const originals = {};
for (const method of ['connect', 'disconnect', 'getDiagnostics', 'handleMessage', 'handlePublishDiagnostics', 'openFile', 'sendMessage', 'handleData']) {
  if (typeof prototype[method] !== 'function') {
    throw new Error(`Incompatible minimal-godot-mcp 0.1.6: missing LSPClient.${method}`);
  }
  originals[method] = prototype[method];
}

const states = new WeakMap();
const diagnosticTimeoutMs = 10_000;

function documentKey(filePath) {
  const absolute = resolve(filePath);
  return process.platform === 'win32' ? absolute.toLowerCase() : absolute;
}

function resetState(client, state, reason) {
  state.generation += 1;
  state.documents.clear();
  state.queues.clear();
  state.incoming = Buffer.alloc(0);
  for (const waiter of [...state.pending.values()]) waiter.finish(new Error(reason));
  client.cache.clearAll();
}

function stateFor(client) {
  let state = states.get(client);
  if (!state) {
    state = {
      generation: 0,
      documents: new Map(),
      queues: new Map(),
      pending: new Map(),
      barriers: new Map(),
      nextRequestId: 1_000_000,
      incoming: Buffer.alloc(0),
    };
    states.set(client, state);
    client.on('close', () => resetState(client, state, 'Godot LSP connection closed while waiting for diagnostics'));
  }
  return state;
}

prototype.connect = function (...args) {
  resetState(this, stateFor(this), 'Godot LSP connection is being re-established');
  return originals.connect.apply(this, args);
};

prototype.disconnect = function (...args) {
  resetState(this, stateFor(this), 'Godot LSP disconnected while waiting for diagnostics');
  return originals.disconnect.apply(this, args);
};

prototype.handlePublishDiagnostics = function (params) {
  const state = stateFor(this);
  const receivedPath = fromFileUri(params.uri);
  const key = documentKey(receivedPath);
  const currentVersion = state.documents.get(key);
  // Reject known-old notifications before they can replace the fresh cache.
  if (params.version != null && currentVersion != null && params.version < currentVersion) return;
  originals.handlePublishDiagnostics.call(this, params);
  // Windows URI casing may differ from the requested path. Cache lookups must
  // use the same key as the waiter, or a real diagnostic can look like [] .
  const diagnostics = this.cache.get(receivedPath);
  this.cache.clear(receivedPath);
  this.cache.set(key, diagnostics);
  const waiter = state.pending.get(key);
  // Some Godot versions omit the optional document version. When present, only
  // accept this version or newer; in all cases require a newly received event.
  if (waiter && (params.version == null || params.version >= waiter.version)) {
    waiter.diagnosticsReceived = true;
    if (waiter.barrierReceived) waiter.finish();
  }
};

prototype.getDiagnostics = function (filePath) {
  return originals.getDiagnostics.call(this, documentKey(filePath));
};

prototype.handleMessage = function (message) {
  originals.handleMessage.call(this, message);
  if (!('result' in message || 'error' in message)) return;
  const waiter = stateFor(this).barriers.get(message.id);
  if (!waiter) return;
  if (message.error) {
    waiter.finish(new Error(`Godot LSP post-save barrier failed: ${JSON.stringify(message.error)}`));
  } else {
    waiter.barrierReceived = true;
    if (waiter.diagnosticsReceived) waiter.finish();
  }
};

prototype.openFile = function (filePath, fileContent) {
  const state = stateFor(this);
  const key = documentKey(filePath);
  const generation = state.generation;
  // Concurrent scans can request the same document. Serialize each document so
  // one notification cannot fulfill requests for two different source versions.
  const previous = state.queues.get(key) ?? Promise.resolve();
  const task = previous.catch(() => {}).then(async () => {
    if (state.generation !== generation || !this.socket || this.socket.destroyed) {
      throw new Error(`Godot LSP is disconnected; cannot refresh diagnostics for ${filePath}`);
    }
    const uri = toFileUri(filePath);
    const previousVersion = state.documents.get(key);
    const version = (previousVersion ?? 0) + 1;
    state.documents.set(key, version);
    this.cache.clear(key);
    await new Promise((resolveWait, rejectWait) => {
      const requestId = state.nextRequestId++;
      const waiter = {
        version,
        diagnosticsReceived: false,
        barrierReceived: false,
        timer: null,
        finish: (error) => {
          if (state.pending.get(key) !== waiter) return;
          clearTimeout(waiter.timer);
          state.pending.delete(key);
          state.barriers.delete(requestId);
          if (error) rejectWait(error);
          else resolveWait();
        },
      };
      state.pending.set(key, waiter);
      state.barriers.set(requestId, waiter);
      waiter.timer = setTimeout(() => waiter.finish(new Error(
        `Timed out after ${diagnosticTimeoutMs} ms waiting for fresh Godot diagnostics: ${filePath} (version ${version})`,
      )), diagnosticTimeoutMs);
      try {
        if (previousVersion == null) {
          this.sendMessage({
            jsonrpc: '2.0',
            method: 'textDocument/didOpen',
            params: { textDocument: { uri, languageId: 'gdscript', version, text: fileContent } },
          });
        } else {
          this.sendMessage({
            jsonrpc: '2.0',
            method: 'textDocument/didChange',
            params: { textDocument: { uri, version }, contentChanges: [{ text: fileContent }] },
          });
        }
        this.sendMessage({
          jsonrpc: '2.0',
          method: 'textDocument/didSave',
          params: { textDocument: { uri }, text: fileContent },
        });
        this.sendMessage({
          jsonrpc: '2.0',
          id: requestId,
          method: 'textDocument/documentSymbol',
          params: { textDocument: { uri } },
        });
      } catch (error) {
        waiter.finish(error);
      }
    });
  });
  state.queues.set(key, task);
  const cleanup = () => {
    if (state.queues.get(key) === task) state.queues.delete(key);
  };
  task.then(cleanup, cleanup);
  return task;
};

prototype.sendMessage = function (message) {
  if (!this.socket || this.socket.destroyed) {
    throw new Error('Cannot send LSP message: Godot is disconnected');
  }
  const content = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.from(`Content-Length: ${content.length}\r\n\r\n`, 'ascii');
  this.socket.write(Buffer.concat([header, content]));
};

prototype.handleData = function (data) {
  const state = stateFor(this);
  const chunk = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (state.incoming.length + chunk.length > this.MAX_BUFFER_SIZE) {
    console.error('[LSP adapter] Buffer size exceeded; disconnecting');
    this.disconnect();
    return;
  }
  state.incoming = Buffer.concat([state.incoming, chunk]);
  while (true) {
    const headerEnd = state.incoming.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = state.incoming.subarray(0, headerEnd).toString('ascii');
    const match = header.match(/^Content-Length:\s*(\d+)\s*$/im);
    if (!match || Number(match[1]) > this.MAX_BUFFER_SIZE) {
      console.error('[LSP adapter] Invalid Content-Length; disconnecting');
      this.disconnect();
      return;
    }
    const start = headerEnd + 4;
    const end = start + Number(match[1]);
    if (state.incoming.length < end) return;
    const content = state.incoming.subarray(start, end).toString('utf8');
    state.incoming = state.incoming.subarray(end);
    try {
      this.handleMessage(JSON.parse(content));
    } catch (error) {
      console.error('[LSP adapter] Failed to handle message:', error);
    }
  }
};

// Dynamic import is intentional: apply overrides before upstream constructs its
// LSP client and starts the otherwise unchanged stdio MCP server.
await import(new URL('dist/index.js', packageRoot).href);
