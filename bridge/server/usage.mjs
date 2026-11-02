// Nur Kontingentdaten; Konto-IDs, E-Mail, Credits und Anmeldedaten bleiben draußen.
export function usageSnapshot(response, checkedAt = Date.now()) {
  const mapped = response?.rateLimitsByLimitId;
  const entries = mapped && typeof mapped === 'object' ? Object.entries(mapped) : [];
  if (!entries.length && response?.rateLimits) entries.push([response.rateLimits.limitId ?? 'codex', response.rateLimits]);
  const limits = [];
  for (const [key, value] of entries) {
    if (!value || typeof value !== 'object') continue;
    const windows = [];
    for (const field of ['primary', 'secondary']) {
      const window = value[field];
      if (!window || !Number.isFinite(window.usedPercent) || window.usedPercent < 0) continue;
      windows.push({
        usedPercent: window.usedPercent,
        windowDurationMins: Number.isFinite(window.windowDurationMins) && window.windowDurationMins > 0 ? window.windowDurationMins : null,
        resetsAt: Number.isFinite(window.resetsAt) && window.resetsAt > 0 ? window.resetsAt : null
      });
    }
    const id = String(value.limitId ?? key);
    if (windows.length) limits.push({ id, name: value.limitName || (id === 'codex' ? 'Codex' : String(key)), windows });
  }
  return { checkedAt, limits };
}
