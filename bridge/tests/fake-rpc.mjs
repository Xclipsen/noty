import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';

/** Spielt das JSON-RPC-Verhalten von Codex nach; `onTurn` steuert den Lauf. */
export class FakeRpc extends EventEmitter {
  constructor({ authType = 'chatgpt', failStart = false, failThread = false, failUsage = false, hangQueries = false, onTurn, answer = 'Antwort [S. 3]', tokens = [], reasoningEffort, rateLimits } = {}) {
    super();
    Object.assign(this, { authType, failStart, failThread, failUsage, hangQueries, onTurn, answer, tokens, reasoningEffort, rateLimits });
    this.calls = []; this.responses = []; this.closed = false;
  }
  emitLater(message) { setImmediate(() => this.emit('message', message)); }
  async start() { if (this.failStart) throw new Error('Synthetischer Startfehler'); return this; }
  async request(method, params) {
    this.calls.push({ method, params });
    if (this.hangQueries) return new Promise(() => {});
    if (method === 'account/read') return { account: this.authType ? { type: this.authType, email: 'privat@example.invalid' } : null };
    if (method === 'model/list') return { data: [
      { id: 'demo', model: 'demo', displayName: 'Demo', isDefault: true, hidden: false },
      { id: 'versteckt', displayName: 'Versteckt', isDefault: false, hidden: true }] };
    if (method === 'account/rateLimits/read') {
      if (this.failUsage) throw new Error('Synthetischer Fehler mit privaten Details');
      return this.rateLimits ?? { accountId: 'privates-konto', rateLimits: { limitId: 'codex', primary: { usedPercent: 32, windowDurationMins: 300, resetsAt: 1900000000 }, secondary: null } };
    }
    if (method === 'thread/start') {
      if (this.failThread) throw new Error('Synthetischer Fehler mit privaten Details');
      return { thread: { id: 'thread-test' }, model: params?.model ?? 'demo', modelProvider: 'openai', reasoningEffort: this.reasoningEffort ?? null };
    }
    if (method === 'turn/start') {
      this.threadId = params.threadId; this.turnId = randomUUID();
      setImmediate(() => (this.onTurn ?? (rpc => rpc.finish()))(this));
      return { turn: { id: this.turnId } };
    }
    if (method === 'turn/interrupt') { this.emitLater({ method: 'turn/completed', params: { threadId: this.threadId, turn: { id: this.turnId, status: 'interrupted' } } }); return {}; }
    return {};
  }
  finish(text = this.answer) {
    const itemId = randomUUID();
    this.emit('message', { method: 'turn/started', params: { threadId: this.threadId, turn: { id: this.turnId } } });
    for (const total of this.tokens) this.usage(total);
    for (const delta of text.split(/(?<=\s)/)) this.emit('message', { method: 'item/agentMessage/delta', params: { threadId: this.threadId, turnId: this.turnId, itemId, delta } });
    this.emit('message', { method: 'item/completed', params: { threadId: this.threadId, item: { id: itemId, type: 'agentMessage', text } } });
    this.complete();
  }
  usage(total) { this.emit('message', { method: 'thread/tokenUsage/updated', params: { threadId: this.threadId, turnId: this.turnId, tokenUsage: { total, last: { ...total, inputTokens: 1 } } } }); }
  quota(rateLimits) { this.emit('message', { method: 'account/rateLimits/updated', params: { rateLimits } }); }
  complete(status = 'completed', error) { this.emit('message', { method: 'turn/completed', params: { threadId: this.threadId, turn: { id: this.turnId, status, error } } }); }
  respond(id, result) { this.responses.push({ id, result }); }
  reject(id, code, message) { this.responses.push({ id, error: { code, message } }); }
  async close() { this.closed = true; }
}
