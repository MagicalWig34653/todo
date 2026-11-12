import { describe, expect, it } from 'vitest';
import { createApi } from '../src/lib/api';
import { ageMinutes, panelState, STALE_AFTER_MIN, summarize, type SystemStatusItem, type SystemStatusResponse } from '../src/lib/systemStatus';

const item = (status: Record<string, unknown>, reportedAt = '2026-11-12T10:00:00Z'): SystemStatusItem => ({ source: 'default', label: 'Mac', reportedAt, status });
const full = {
	claude_ampel: 'rot', claude_frei_fuer_brain: 0, claude_nutzbare_konten: [4, 7],
	codex: { verbraucht_pct: 5, erlaubt_bis_jetzt_pct: 19.2, ziel_pct: 75, freigabe: true },
	platte_frei_gb: 104.9, platte_ampel: 'gruen'
};

describe('system status', () => {
	it('ages against the server clock and advances with the local clock', () => {
		const res: SystemStatusResponse = { items: [item(full)], now: '2026-11-12T10:12:00Z' };
		expect(ageMinutes(res.items[0], res.now, 0, 0)).toBe(12);
		expect(ageMinutes(res.items[0], res.now, 1000, 1000 + 3 * 60_000)).toBe(15);
		expect(ageMinutes(res.items[0], '2026-11-12T09:00:00Z', 0, 0)).toBe(0);
	});

	it('summarizes lights, accounts, codex and disk', () => {
		const s = summarize(item(full), 12);
		expect(s.stale).toBe(false);
		expect(s.claude).toEqual({ ampel: 'rot', accounts: [4, 7], freeForBrain: 0 });
		expect(s.codex).toEqual({ used: 5, allowed: 19.2, target: 75, tone: 'success' });
		expect(s.disk).toEqual({ ampel: 'gruen', freeGb: 104.9 });
		expect(s.ageMin).toBe(12);
	});

	it('marks reports older than 30 minutes as stale', () => {
		expect(STALE_AFTER_MIN).toBe(30);
		expect(summarize(item(full), 30).stale).toBe(false);
		expect(summarize(item(full), 31).stale).toBe(true);
	});

	it('codex warns when over budget or not released; tolerates missing and unknown values', () => {
		expect(summarize(item({ codex: { verbraucht_pct: 30, erlaubt_bis_jetzt_pct: 19 } }), 1).codex?.tone).toBe('warning');
		expect(summarize(item({ codex: { verbraucht_pct: 1, erlaubt_bis_jetzt_pct: 19, freigabe: false } }), 1).codex?.tone).toBe('warning');
		const s = summarize(item({ claude_ampel: 'lila', claude_frei_fuer_brain: 1, platte_frei_gb: 'x', platte_ampel: 'gelb' }), 1);
		expect(s.claude?.ampel).toBeNull();
		expect(s.codex).toBeNull();
		expect(s.disk).toEqual({ ampel: 'gelb', freeGb: null });
		expect(summarize(item({ claude_ampel: 'lila', platte_frei_gb: 'x' }), 1).disk).toBeNull();
		expect(summarize(item({}), 1).claude).toBeNull();
	});

	it('api.systemStatus reads GET /v1/system-status', async () => {
		const calls: string[] = [];
		const api = createApi(async (url, init) => {
			calls.push(`${init?.method ?? 'GET'} ${url}`);
			return new Response(JSON.stringify({ items: [], now: '2026-11-12T10:00:00Z' }), { status: 200, headers: { 'content-type': 'application/json' } });
		});
		const r = await api.systemStatus();
		expect(r.items).toEqual([]);
		expect(calls).toEqual(['GET /v1/system-status']);
	});

	it('panel state: loading, empty (no report yet), error (no answer) and rows', () => {
		const ok: SystemStatusResponse = { items: [item(full)], now: '2026-11-12T10:12:00Z' };
		expect(panelState(null, false)).toBe('loading');
		expect(panelState(null, true)).toBe('error');
		expect(panelState({ items: [], now: ok.now }, false)).toBe('empty');
		expect(panelState({ items: [], now: ok.now }, true)).toBe('empty');
		expect(panelState(ok, false)).toBe('rows');
		expect(panelState(ok, true)).toBe('rows');
	});
});
