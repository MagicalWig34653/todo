import type { SystemStatusItem, SystemStatusResponse } from './api.js';

export type { SystemStatusItem, SystemStatusResponse };

/** A report older than this many minutes is shown grey (contracts/system-status.yaml). */
export const STALE_AFTER_MIN = 30;

export type Ampel = 'gruen' | 'gelb' | 'rot';
export type LightTone = 'success' | 'warning' | 'destructive' | 'default';

const AMPELN: readonly string[] = ['gruen', 'gelb', 'rot'];
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const ampelOf = (v: unknown): Ampel | null => (typeof v === 'string' && AMPELN.includes(v) ? (v as Ampel) : null);

/**
 * Age in whole minutes: server time minus report time, advanced by the time that passed locally since the answer
 * arrived (`fetchedAt`, both in ms of the local clock). Never negative.
 */
export function ageMinutes(item: SystemStatusItem, serverNow: string, fetchedAt: number, localNow: number): number {
	const ms = Date.parse(serverNow) - Date.parse(item.reportedAt) + Math.max(0, localNow - fetchedAt);
	return Number.isFinite(ms) ? Math.max(0, Math.floor(ms / 60_000)) : 0;
}

export function toneOf(ampel: Ampel | null): LightTone {
	return ampel === 'gruen' ? 'success' : ampel === 'gelb' ? 'warning' : ampel === 'rot' ? 'destructive' : 'default';
}

export interface StatusSummary {
	ageMin: number;
	stale: boolean;
	claude: { ampel: Ampel | null; accounts: number[]; freeForBrain: number | null } | null;
	codex: { used: number; allowed: number | null; target: number | null; tone: LightTone } | null;
	disk: { ampel: Ampel | null; freeGb: number | null } | null;
}

/** Tolerant reading of the watcher's document: unknown or malformed values simply drop out. */
export function summarize(item: SystemStatusItem, ageMin: number): StatusSummary {
	const s = item.status ?? {};
	const claudeAmpel = ampelOf(s.claude_ampel);
	const accounts = Array.isArray(s.claude_nutzbare_konten) ? s.claude_nutzbare_konten.filter((n): n is number => num(n) !== null) : [];
	const freeForBrain = num(s.claude_frei_fuer_brain);
	const claude = claudeAmpel || accounts.length || freeForBrain !== null ? { ampel: claudeAmpel, accounts, freeForBrain } : null;

	const c = s.codex && typeof s.codex === 'object' ? (s.codex as Record<string, unknown>) : null;
	const used = c ? num(c.verbraucht_pct) : null;
	let codex: StatusSummary['codex'] = null;
	if (c && used !== null) {
		const allowed = num(c.erlaubt_bis_jetzt_pct);
		const over = allowed !== null && used > allowed;
		codex = { used, allowed, target: num(c.ziel_pct), tone: over || c.freigabe === false ? 'warning' : 'success' };
	}

	const diskAmpel = ampelOf(s.platte_ampel);
	const freeGb = num(s.platte_frei_gb);
	const disk = diskAmpel || freeGb !== null ? { ampel: diskAmpel, freeGb } : null;
	return { ageMin, stale: ageMin > STALE_AFTER_MIN, claude, codex, disk };
}

export type PanelState = 'loading' | 'empty' | 'error' | 'rows';

/** What the bar shows: never nothing once the first load ended (no report yet and an unreachable endpoint both say so). */
export function panelState(data: SystemStatusResponse | null, failed: boolean): PanelState {
	if (!data) return failed ? 'error' : 'loading';
	return data.items.length ? 'rows' : 'empty';
}
