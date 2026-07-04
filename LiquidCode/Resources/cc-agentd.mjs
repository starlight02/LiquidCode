#!/usr/bin/env node
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { existsSync } from 'node:fs';

const SIDECAR_VERSION = '0.3.0';
const PROTOCOL_VERSION = 1;
const __dirname = dirname(fileURLToPath(import.meta.url));
const requireFromHere = createRequire(import.meta.url);
const rl = readline.createInterface({ input: process.stdin });
const sessions = new Map();

const keepAliveTimer = setInterval(() => {}, 60 * 60 * 1000);

let sdkModulePromise = null;
let sdkLoadError = null;

class AsyncMessageQueue {
  constructor() {
    this.items = [];
    this.waiters = [];
    this.closed = false;
  }

  push(message) {
    if (this.closed) return;
    const waiter = this.waiters.shift();
    if (waiter) waiter({ value: message, done: false });
    else this.items.push(message);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true });
  }

  [Symbol.asyncIterator]() { return this; }

  next() {
    if (this.items.length) return Promise.resolve({ value: this.items.shift(), done: false });
    if (this.closed) return Promise.resolve({ value: undefined, done: true });
    return new Promise(resolve => this.waiters.push(resolve));
  }
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function result(id, value) {
  send({ jsonrpc: '2.0', id, result: value });
}

function rpcError(id, code, message, details = {}) {
  send({ jsonrpc: '2.0', id, error: { code, message, details } });
}

function event(sessionId, type, payload = {}) {
  send({ jsonrpc: '2.0', method: 'event', params: { sessionId, type, payload } });
}

function sidecarLog(sessionId, line) {
  event(sessionId, 'stderr', { line });
}

function asArray(value) {
  return Array.isArray(value) ? value.filter(v => typeof v === 'string') : [];
}

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function normalizeSDKUserMessage(content) {
  return {
    type: 'user',
    message: { role: 'user', content: content ?? '' },
    parent_tool_use_id: null,
  };
}

function buildDefaultCLIArgs(params) {
  const args = [
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--replay-user-messages',
    '--strict-mcp-config',
  ];
  if (params.mcpConfigPath) args.push('--mcp-config', params.mcpConfigPath);
  if (params.resumeSessionID || params.resume) args.push('--resume', params.resumeSessionID || params.resume);
  if (params.model) args.push('--model', params.model);
  args.push('--permission-mode', params.permissionMode || 'default', '--permission-prompt-tool', 'stdio');
  return args;
}

function writeJSON(child, obj) {
  child.stdin.write(JSON.stringify(obj) + '\n');
}

function consumeLines(runtime, key, chunk, callback) {
  runtime[key] += chunk;
  let index;
  while ((index = runtime[key].indexOf('\n')) >= 0) {
    const line = runtime[key].slice(0, index).trim();
    runtime[key] = runtime[key].slice(index + 1);
    if (line) callback(line);
  }
}

function candidateSDKPaths() {
  const envPaths = (process.env.LIQUIDCODE_AGENT_SDK_PATHS || process.env.LIQUIDCODE_CLAUDE_AGENT_SDK_PATH || '')
    .split(':')
    .filter(Boolean);
  return [
    ...envPaths,
    join(__dirname, 'claude-agent-sdk.mjs'),
    join(__dirname, 'sdk.mjs'),
    join(__dirname, 'vendor/claude-agent-sdk/sdk.mjs'),
    join(__dirname, 'claude-agent-sdk/sdk.mjs'),
    join(__dirname, '../vendor/claude-agent-sdk/sdk.mjs'),
  ];
}

async function loadSDK() {
  if (sdkModulePromise) return sdkModulePromise;
  sdkModulePromise = (async () => {
    if (process.env.LIQUIDCODE_FORCE_CLI_SIDECAR === '1') {
      throw new Error('SDK disabled by LIQUIDCODE_FORCE_CLI_SIDECAR=1');
    }
    try {
      return await import('@anthropic-ai/claude-agent-sdk');
    } catch (packageError) {
      let last = packageError;
      for (const candidate of candidateSDKPaths()) {
        try {
          const resolvedCandidate = isAbsolute(candidate) ? candidate : resolve(__dirname, candidate);
          if (!existsSync(resolvedCandidate)) continue;
          return await import(pathToFileURL(resolvedCandidate).href);
        } catch (error) {
          last = error;
        }
      }
      try {
        const resolvedPackage = requireFromHere.resolve('@anthropic-ai/claude-agent-sdk', { paths: [process.cwd(), __dirname] });
        return await import(pathToFileURL(resolvedPackage).href);
      } catch (requireError) {
        last = requireError;
      }
      throw last;
    }
  })().catch(error => {
    sdkLoadError = error;
    sdkModulePromise = null;
    throw error;
  });
  return sdkModulePromise;
}

async function sdkAvailable() {
  try {
    const sdk = await loadSDK();
    return typeof sdk?.query === 'function';
  } catch {
    return false;
  }
}

function buildSDKOptions(runtime, params) {
  const env = { ...process.env, ...asObject(params.environment) };
  env.CLAUDE_AGENT_SDK_CLIENT_APP = env.CLAUDE_AGENT_SDK_CLIENT_APP || 'LiquidCode/0.1';

  const extraArgs = {};
  if (params.mcpConfigPath) {
    extraArgs['mcp-config'] = params.mcpConfigPath;
    extraArgs['strict-mcp-config'] = null;
  }
  if (params.argsExtra && typeof params.argsExtra === 'object') {
    Object.assign(extraArgs, params.argsExtra);
  }

  const options = {
    cwd: runtime.cwd,
    env,
    includePartialMessages: params.includePartialMessages !== false,
    includeHookEvents: true,
    forwardSubagentText: true,
    enableFileCheckpointing: params.enableFileCheckpointing !== false,
    permissionMode: params.permissionMode || 'default',
    abortController: runtime.abortController,
    canUseTool: (toolName, input, permissionOptions) => requestPermission(runtime, toolName, input, permissionOptions),
  };

  if (Object.keys(extraArgs).length) options.extraArgs = extraArgs;
  if (params.resumeSessionID || params.resume) options.resume = params.resumeSessionID || params.resume;
  if (params.model) options.model = params.model;
  if (Number.isFinite(params.maxTurns)) options.maxTurns = params.maxTurns;
  if (Number.isFinite(params.maxBudgetUsd)) options.maxBudgetUsd = params.maxBudgetUsd;
  if (params.permissionMode === 'bypassPermissions') options.allowDangerouslySkipPermissions = true;
  if (params.executablePath && params.executablePath !== '/usr/bin/env' && params.executablePath !== 'claude') {
    options.pathToClaudeCodeExecutable = params.executablePath;
  }
  if (params.thinkingLevel && params.thinkingLevel !== 'off') {
    options.effort = params.thinkingLevel;
    options.thinking = { type: 'adaptive' };
  } else if (params.thinkingLevel === 'off') {
    options.thinking = { type: 'disabled' };
  }
  return options;
}

function requestPermission(runtime, toolName, input, permissionOptions = {}) {
  const requestId = permissionOptions.requestId || randomUUID();
  const payload = {
    type: 'control_request',
    request_id: requestId,
    request: {
      subtype: 'can_use_tool',
      tool_name: toolName,
      toolName,
      input: input || {},
      description: permissionOptions.description || permissionOptions.title || permissionOptions.displayName || '',
      title: permissionOptions.title,
      display_name: permissionOptions.displayName,
      blocked_path: permissionOptions.blockedPath,
      decision_reason: permissionOptions.decisionReason,
      permission_suggestions: permissionOptions.suggestions || [],
      tool_use_id: permissionOptions.toolUseID,
      parent_tool_use_id: permissionOptions.parentToolUseID,
      agent_id: permissionOptions.agentID,
    },
  };

  event(runtime.sessionId, 'permission.requested', payload);

  return new Promise(resolve => {
    const abort = () => {
      runtime.pendingPermissions.delete(requestId);
      resolve({
        behavior: 'deny',
        message: 'Permission request cancelled',
        toolUseID: permissionOptions.toolUseID,
        decisionClassification: 'user_reject',
      });
    };
    runtime.pendingPermissions.set(requestId, { resolve, toolUseID: permissionOptions.toolUseID, abort });
    if (permissionOptions.signal) {
      if (permissionOptions.signal.aborted) abort();
      else permissionOptions.signal.addEventListener('abort', abort, { once: true });
    }
  });
}

async function runSDKSession(runtime, params, id) {
  const sdk = await loadSDK();
  if (!sdk?.query) throw new Error('Claude Agent SDK query() is unavailable');

  const options = buildSDKOptions(runtime, params);
  runtime.query = sdk.query({ prompt: runtime.inputQueue, options });
  runtime.mode = 'sdk';
  runtime.status = 'running';
  result(id, {
    sessionId: runtime.sessionId,
    runtimeId: runtime.sessionId,
    projectPath: runtime.cwd,
    mode: 'sdk',
    sdkVersion: sdk.SDK_VERSION || sdk.version || null,
  });

  if (params.initialMessage?.content) {
    runtime.inputQueue.push(normalizeSDKUserMessage(params.initialMessage.content));
  }

  (async () => {
    try {
      for await (const message of runtime.query) {
        event(runtime.sessionId, 'claude.raw', message);
      }
      runtime.status = runtime.status === 'interrupted' ? 'interrupted' : 'completed';
      sessions.delete(runtime.sessionId);
      event(runtime.sessionId, 'session.exited', { code: 0, mode: 'sdk' });
    } catch (error) {
      runtime.status = 'failed';
      sessions.delete(runtime.sessionId);
      event(runtime.sessionId, 'session.failed', { message: error?.message || String(error), code: error?.name || 'SDK_QUERY_FAILED', mode: 'sdk' });
      event(runtime.sessionId, 'session.exited', { code: 1, mode: 'sdk' });
    } finally {
      rejectPendingPermissions(runtime, 'Session ended');
      runtime.inputQueue.close();
    }
  })();
}

function startCLISession(runtime, params, id, reason = null) {
  const executable = params.executablePath || 'claude';
  const args = asArray(params.args).length ? asArray(params.args) : buildDefaultCLIArgs(params);
  const env = { ...process.env, ...asObject(params.environment) };
  const child = spawn(executable, args, { cwd: runtime.cwd, stdio: ['pipe', 'pipe', 'pipe'], env });
  runtime.mode = 'cli';
  runtime.child = child;
  runtime.stdoutBuffer = '';
  runtime.stderrBuffer = '';
  runtime.status = 'running';

  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => consumeLines(runtime, 'stdoutBuffer', chunk, line => {
    let parsed;
    try { parsed = JSON.parse(line); }
    catch { event(runtime.sessionId, 'stdout.text', { line }); return; }
    if (parsed.type === 'control_request') event(runtime.sessionId, 'permission.requested', parsed);
    else event(runtime.sessionId, 'claude.raw', parsed);
  }));

  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => consumeLines(runtime, 'stderrBuffer', chunk, line => {
    event(runtime.sessionId, 'stderr', { line });
  }));

  child.on('error', err => {
    runtime.status = 'failed';
    event(runtime.sessionId, 'session.failed', { message: err.message, code: err.code || 'SPAWN_FAILED', mode: 'cli' });
  });

  child.on('exit', (code, signal) => {
    runtime.status = signal ? 'interrupted' : 'completed';
    sessions.delete(runtime.sessionId);
    rejectPendingPermissions(runtime, 'CLI session ended');
    event(runtime.sessionId, 'session.exited', { code, signal, mode: 'cli' });
  });

  if (params.initialMessage?.content) {
    writeJSON(child, { type: 'user', message: { role: 'user', content: params.initialMessage.content } });
  }

  result(id, { sessionId: runtime.sessionId, runtimeId: runtime.sessionId, projectPath: runtime.cwd, mode: 'cli', fallbackReason: reason });
}

async function startSession(id, params = {}) {
  const sessionId = params.sessionId || randomUUID();
  const old = sessions.get(sessionId);
  if (old) await closeRuntime(old, 'Session replaced');

  const runtime = {
    sessionId,
    cwd: params.projectPath || params.cwd || process.cwd(),
    status: 'starting',
    mode: 'starting',
    inputQueue: new AsyncMessageQueue(),
    abortController: new AbortController(),
    query: null,
    child: null,
    pendingPermissions: new Map(),
  };
  sessions.set(sessionId, runtime);

  const preferSDK = params.preferSDK !== false && process.env.LIQUIDCODE_FORCE_CLI_SIDECAR !== '1';
  if (preferSDK) {
    try {
      await runSDKSession(runtime, params, id);
      return;
    } catch (error) {
      sidecarLog(sessionId, `Claude Agent SDK unavailable; falling back to CLI sidecar: ${error?.message || String(error)}`);
      runtime.abortController = new AbortController();
      startCLISession(runtime, params, id, error?.message || String(error));
      return;
    }
  }
  startCLISession(runtime, params, id, 'SDK disabled');
}

function sessionSend(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (!runtime) throw new Error(`session not found: ${params.sessionId}`);
  const content = params.message?.content ?? params.text ?? '';
  if (runtime.mode === 'sdk') runtime.inputQueue.push(normalizeSDKUserMessage(content));
  else writeJSON(runtime.child, { type: 'user', message: { role: 'user', content } });
  result(id, { queued: true });
}

async function sessionInterrupt(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (runtime) {
    runtime.status = 'interrupted';
    rejectPendingPermissions(runtime, 'Interrupted by user');
    if (runtime.mode === 'sdk' && runtime.query?.interrupt) await runtime.query.interrupt();
    else if (runtime.mode === 'cli') writeJSON(runtime.child, { type: 'control_request', request_id: randomUUID(), request: { subtype: 'interrupt' } });
  }
  result(id, { interrupted: true });
}

async function setPermissionMode(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (!runtime) throw new Error(`session not found: ${params.sessionId}`);
  if (runtime.mode === 'sdk' && runtime.query?.setPermissionMode) await runtime.query.setPermissionMode(params.mode || 'default');
  else if (runtime.mode === 'cli') writeJSON(runtime.child, { type: 'control_request', request_id: randomUUID(), request: { subtype: 'set_permission_mode', mode: params.mode || 'default' } });
  result(id, { ok: true, mode: params.mode || 'default' });
}

function normalizePermissionDecision(params, pending) {
  const decision = asObject(params.decision || params.response);
  const behavior = decision.behavior === 'allow' ? 'allow' : 'deny';
  if (behavior === 'allow') {
    return {
      behavior: 'allow',
      updatedInput: asObject(decision.updatedInput),
      updatedPermissions: decision.updatedPermissions,
      toolUseID: decision.toolUseID || pending?.toolUseID,
      decisionClassification: decision.remember ? 'user_permanent' : 'user_temporary',
    };
  }
  return {
    behavior: 'deny',
    message: decision.message || 'User denied this operation',
    interrupt: Boolean(decision.interrupt),
    toolUseID: decision.toolUseID || pending?.toolUseID,
    decisionClassification: 'user_reject',
  };
}

function permissionRespond(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (!runtime) throw new Error(`session not found: ${params.sessionId}`);
  if (runtime.mode === 'sdk') {
    const pending = runtime.pendingPermissions.get(params.requestId);
    if (!pending) throw new Error(`permission request not found: ${params.requestId}`);
    runtime.pendingPermissions.delete(params.requestId);
    pending.resolve(normalizePermissionDecision(params, pending));
  } else {
    writeJSON(runtime.child, {
      type: 'control_response',
      response: {
        subtype: 'success',
        request_id: params.requestId,
        response: params.decision || params.response || {},
      },
    });
  }
  result(id, { ok: true });
}

async function sessionControl(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (!runtime) throw new Error(`session not found: ${params.sessionId}`);
  const payload = asObject(params.payload);
  const request = asObject(payload.request);
  const subtype = request.subtype || payload.subtype;
  if (runtime.mode === 'sdk' && subtype === 'rewind_files') {
    const checkpoint = request.checkpoint_uuid || request.checkpointUuid || params.checkpointUUID || params.checkpointUuid;
    if (!checkpoint) throw new Error('missing rewind checkpoint UUID');
    if (!runtime.query?.rewindFiles) throw new Error('SDK query does not expose rewindFiles');
    const rewindResult = await runtime.query.rewindFiles(checkpoint, { dryRun: false });
    result(id, { ok: true, result: rewindResult });
    return;
  }
  if (runtime.mode === 'cli') writeJSON(runtime.child, payload);
  else throw new Error(`unsupported control subtype for SDK sidecar: ${subtype || 'unknown'}`);
  result(id, { ok: true });
}

async function sessionKill(id, params = {}) {
  const runtime = sessions.get(params.sessionId);
  if (runtime) await closeRuntime(runtime, 'Killed by host');
  result(id, { killed: true });
}

function rejectPendingPermissions(runtime, message) {
  for (const [requestId, pending] of runtime.pendingPermissions.entries()) {
    runtime.pendingPermissions.delete(requestId);
    pending.resolve({
      behavior: 'deny',
      message,
      toolUseID: pending.toolUseID,
      decisionClassification: 'user_reject',
    });
  }
}

async function closeRuntime(runtime, message) {
  sessions.delete(runtime.sessionId);
  rejectPendingPermissions(runtime, message);
  runtime.inputQueue?.close?.();
  try { runtime.query?.close?.(); } catch {}
  try { runtime.abortController?.abort?.(); } catch {}
  if (runtime.child) {
    runtime.child.kill('SIGTERM');
  }
}

async function shutdown(id) {
  const values = Array.from(sessions.values());
  await Promise.all(values.map(runtime => closeRuntime(runtime, 'Sidecar shutdown')));
  result(id, { ok: true });
  clearInterval(keepAliveTimer);
  setTimeout(() => process.exit(0), 10).unref();
}

async function listSessionsRPC(id, params = {}) {
  const sdk = await loadSDK();
  if (!sdk?.listSessions) throw new Error('SDK listSessions() is unavailable');
  const sessionsList = await sdk.listSessions({ dir: params.projectPath || params.dir, limit: params.limit });
  result(id, { sessions: sessionsList });
}

async function messagesRPC(id, params = {}) {
  const sdk = await loadSDK();
  if (!sdk?.getSessionMessages) throw new Error('SDK getSessionMessages() is unavailable');
  const messages = await sdk.getSessionMessages(params.sessionId, { dir: params.projectPath || params.dir, limit: params.limit, offset: params.offset, includeSystemMessages: true });
  result(id, { messages });
}

rl.on('line', line => {
  let req;
  try { req = JSON.parse(line); }
  catch { return; }
  (async () => {
    try {
      if (req.method === 'engine.initialize') {
        const hasSDK = await sdkAvailable();
        return result(req.id, {
          protocolVersion: PROTOCOL_VERSION,
          sidecarVersion: SIDECAR_VERSION,
          sdkAvailable: hasSDK,
          sdkError: hasSDK ? null : (sdkLoadError?.message || null),
          features: {
            streamingInput: true,
            partialMessages: true,
            permissions: true,
            sessions: hasSDK,
            mcp: true,
            fileCheckpointing: true,
            directCLIFallback: true,
          },
        });
      }
      if (req.method === 'session.start') return await startSession(req.id, req.params || {});
      if (req.method === 'session.send') return sessionSend(req.id, req.params || {});
      if (req.method === 'session.interrupt') return await sessionInterrupt(req.id, req.params || {});
      if (req.method === 'session.setPermissionMode') return await setPermissionMode(req.id, req.params || {});
      if (req.method === 'permission.respond') return permissionRespond(req.id, req.params || {});
      if (req.method === 'session.control') return await sessionControl(req.id, req.params || {});
      if (req.method === 'session.kill') return await sessionKill(req.id, req.params || {});
      if (req.method === 'sessions.list') return await listSessionsRPC(req.id, req.params || {});
      if (req.method === 'sessions.messages') return await messagesRPC(req.id, req.params || {});
      if (req.method === 'engine.shutdown') return await shutdown(req.id);
      rpcError(req.id, 'METHOD_NOT_FOUND', req.method || 'unknown');
    } catch (error) {
      rpcError(req.id, 'REQUEST_FAILED', error?.message || String(error), { stack: error?.stack });
    }
  })();
});

process.on('SIGTERM', async () => {
  const values = Array.from(sessions.values());
  await Promise.all(values.map(runtime => closeRuntime(runtime, 'Sidecar SIGTERM')));
  clearInterval(keepAliveTimer);
  process.exit(0);
});
