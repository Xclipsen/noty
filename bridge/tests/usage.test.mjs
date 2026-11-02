import test from 'node:test';
import assert from 'node:assert/strict';
import { usageSnapshot } from '../server/usage.mjs';

test('Usage: mehrere Buckets, nur Kontingentdaten', () => {
  const window = { usedPercent: 10, windowDurationMins: 300, resetsAt: 1900000000 };
  const snapshot = usageSnapshot({
    accountId: 'privat', rateLimits: { limitId: 'x', primary: window },
    rateLimitsByLimitId: { codex: { limitId: 'codex', primary: window, secondary: { usedPercent: 5 }, credits: { balance: 'privat' } }, spark: { limitName: 'Spark', primary: { ...window, windowDurationMins: 0 } }, leer: { primary: null }, kaputt: null }
  }, 123);
  assert.deepEqual(snapshot, { checkedAt: 123, limits: [
    { id: 'codex', name: 'Codex', windows: [window, { usedPercent: 5, windowDurationMins: null, resetsAt: null }] },
    { id: 'spark', name: 'Spark', windows: [{ usedPercent: 10, windowDurationMins: null, resetsAt: 1900000000 }] }] });
});

test('Usage: Einzelansicht und leere Antwort', () => {
  assert.equal(usageSnapshot({ rateLimits: { primary: { usedPercent: 1 } } }, 1).limits[0].id, 'codex');
  assert.deepEqual(usageSnapshot(null, 1), { checkedAt: 1, limits: [] });
});
