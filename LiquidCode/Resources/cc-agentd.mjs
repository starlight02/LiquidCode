#!/usr/bin/env node
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const rl = readline.createInterface({ input: process.stdin });
const sessions = new Map();
function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }
function result(id, value) { send({ jsonrpc: '2.0', id, result: value }); }
function error(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }
function event(sessionId, type, payload) { send({ jsonrpc: '2.0', method: 'event', params: { sessionId, type, payload } }); }

function startSession(id, params) {
  const sessionId = params.sessionId || randomUUID();
  const args = ['--input-format','stream-json','--output-format','stream-json','--verbose','--include-partial-messages','--replay-user-messages','--permission-mode', params.permissionMode || 'default','--permission-prompt-tool','stdio'];
  if (params.model) args.push('--model', params.model);
  if (params.resume) args.push('--resume', params.resume);
  const child = spawn('claude', args, { cwd: params.projectPath || process.cwd(), stdio: ['pipe','pipe','pipe'], env: { ...process.env, ...(params.environment || {}) } });
  sessions.set(sessionId, child);
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => chunk.split(/\n/).filter(Boolean).forEach(line => {
    let parsed; try { parsed = JSON.parse(line); } catch { return; }
    if (parsed.type === 'control_request') event(sessionId, 'permission.requested', parsed);
    else event(sessionId, 'claude.raw', parsed);
  }));
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => event(sessionId, 'stderr', chunk));
  child.on('exit', code => { sessions.delete(sessionId); event(sessionId, 'session.exited', { code }); });
  if (params.initialMessage?.content) {
    child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: params.initialMessage.content } }) + '\n');
  }
  result(id, { sessionId, runtimeId: sessionId, projectPath: params.projectPath || process.cwd() });
}

rl.on('line', line => {
  let req; try { req = JSON.parse(line); } catch { return; }
  try {
    if (req.method === 'engine.initialize') return result(req.id, { protocolVersion: 1, sidecarVersion: '0.1.0', features: { streamingInput: true, partialMessages: true, permissions: true, sessions: true, mcp: true } });
    if (req.method === 'session.start') return startSession(req.id, req.params || {});
    if (req.method === 'session.send') { const child = sessions.get(req.params.sessionId); if (!child) throw new Error('session not found'); child.stdin.write(JSON.stringify({ type: 'user', message: req.params.message }) + '\n'); return result(req.id, { queued: true }); }
    if (req.method === 'session.interrupt') { const child = sessions.get(req.params.sessionId); if (child) child.stdin.write(JSON.stringify({ type: 'control_request', request_id: randomUUID(), request: { subtype: 'interrupt' } }) + '\n'); return result(req.id, { interrupted: true }); }
    if (req.method === 'permission.respond') { const child = [...sessions.values()][0]; if (!child) throw new Error('session not found'); child.stdin.write(JSON.stringify({ type: 'control_response', response: { subtype: 'success', request_id: req.params.requestId, response: req.params.decision } }) + '\n'); return result(req.id, { ok: true }); }
    error(req.id, 'METHOD_NOT_FOUND', req.method);
  } catch (e) { error(req.id, 'REQUEST_FAILED', e.message); }
});
