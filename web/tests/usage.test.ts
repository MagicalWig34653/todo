import { describe, expect, it } from 'vitest';
import { ApiError, createApi } from '../src/lib/api';
import { describeError } from '../src/lib/errors';
import { t } from '../src/lib/i18n';
import {
	DEFAULT_THRESHOLDS, METRIC_ORDER, PART_KEYS, addPriceRow, buildSettingsUpdate, costTrend, formatChange, formatShare, formatTokens, formatUSD,
	labelIndices, localDate, metricTile, niceMax, pageState, partialHint, settingsDraft, stackedBars, verdictText,
	type Metric, type MetricID, type Rating, type UsageSettings, type UsageSummary
} from '../src/lib/usage';

/** Intl puts non-breaking spaces between number and unit; the assertions read better with plain ones. */
const plain = (s: string) => s.replace(/[  ]/g, ' ');

const metric = (id: MetricID, rating: Rating, value?: number, extra: Partial<Metric> = {}): Metric => ({ id, rating, ...(value === undefined ? {} : { value }), ...extra });

function summary(over: Partial<UsageSummary> = {}): UsageSummary {
	return {
		days: 7, from: '2026-11-21', until: '2026-11-27', partial: false, hasData: true, hasAnyData: true, totalCostUSD: 84,
		verdict: { rating: 'medium', best: 'cacheHitRate', worst: 'cacheWriteCostShare', lever: 'cacheWriteCostShare' },
		metrics: [
			metric('costPerDay', 'medium', 12, { previous: 11, change: 0.0909 }),
			metric('cacheHitRate', 'good', 0.95),
			metric('cacheWriteCostShare', 'bad', 0.68),
			metric('outputShare', 'info', 0.006),
			metric('contextPerTurn', 'medium', 84_500),
			metric('opusCostShare', 'info', 0.72),
			metric('costPerDoneCard', 'unknown'),
			metric('idleCostShare', 'good', 0.031)
		],
		series: [], models: [], sessions: [], projects: [], unpricedModels: [],
		...over
	};
}

describe('formatting (US-$ with de-DE)', () => {
	it('formats money, small amounts and zero', () => {
		expect(plain(formatUSD(0))).toBe('0,00 $');
		expect(plain(formatUSD(12.3))).toBe('12,30 $');
		expect(plain(formatUSD(1234.5))).toBe('1.234,50 $');
		expect(plain(formatUSD(0.004))).toBe('< 0,01 $');
	});
	it('formats shares with at most one decimal', () => {
		expect(plain(formatShare(0.95))).toBe('95 %');
		expect(plain(formatShare(0.6789))).toBe('67,9 %');
		expect(plain(formatShare(0.006))).toBe('0,6 %');
		expect(plain(formatShare(0.0002))).toBe('< 0,1 %');
		expect(plain(formatShare(0))).toBe('0 %');
	});
	it('formats tokens compactly', () => {
		expect(formatTokens(950)).toBe('950');
		expect(formatTokens(45_000)).toBe('45k');
		expect(formatTokens(84_500)).toBe('84,5k');
		expect(plain(formatTokens(1_240_000))).toBe('1,2 Mio.');
		expect(plain(formatTokens(999_990))).toBe('1 Mio.');
	});
	it('formats a relative change with sign', () => {
		expect(plain(formatChange(0.22))).toBe('+22 %');
		expect(plain(formatChange(-0.123))).toBe('−12,3 %');
		expect(plain(formatChange(0))).toBe('±0 %');
	});
	it('takes the calendar date of the browser, not of UTC', () => {
		expect(localDate(new Date(2026, 10, 27, 0, 5))).toBe('2026-11-27');
		expect(localDate(new Date(2026, 0, 3, 23, 55))).toBe('2026-01-03');
	});
});

describe('page state, trend and running day', () => {
	it('separates "no data at all" from "nothing in this range"', () => {
		expect(pageState(summary({ hasAnyData: false, hasData: false }))).toBe('setup');
		expect(pageState(summary({ hasData: false }))).toBe('quiet');
		expect(pageState(summary({ hasData: false, hasAnyData: undefined }))).toBe('quiet');
		expect(pageState(summary())).toBe('filled');
	});
	it('describes the trend against the previous period', () => {
		expect(plain(costTrend(summary({ previousCostUSD: 70 }))!)).toBe('+20 % gegenüber den 7 Tagen davor (70,00 $)');
		expect(plain(costTrend(summary({ days: 1, totalCostUSD: 5, previousCostUSD: 10 }))!)).toBe('−50 % gegenüber dem Tag davor (10,00 $)');
		expect(costTrend(summary())).toBe('Kein Vergleich: Im Zeitraum davor gibt es keine Daten.');
		expect(plain(costTrend(summary({ previousCostUSD: 0 }))!)).toBe('Davor 0,00 $.');
	});
	it('hints that the last day is still running', () => {
		expect(partialHint(summary())).toBeNull();
		expect(partialHint(summary({ partial: true }))).toBe('Der 27.11. läuft noch: Die Werte dieses Tages sind vorläufig.');
	});
});

describe('verdict sentence', () => {
	it('names the best value, the worst value and the biggest lever', () => {
		const v = verdictText(summary());
		expect(v.rating).toBe('medium');
		expect(v.label).toBe('Ordentlich');
		expect(plain(v.sentence)).toBe(
			'Ordentlich: Cache trifft zu 95 %, aber Cache-Writes machen 68 % der Kosten. Größter Hebel: weniger Cache neu schreiben, also keine Pausen mitten im Auftrag.'
		);
	});
	it('says that nothing needs work when no metric is worse than good', () => {
		const v = verdictText(summary({ verdict: { rating: 'good', best: 'cacheHitRate' } }));
		expect(v.label).toBe('Gut');
		expect(plain(v.sentence)).toBe('Gut: Cache trifft zu 95 %. Keine bewertete Kennzahl braucht Nachbesserung.');
	});
	it('does not praise a "best" value that is itself not good', () => {
		const s = summary({
			verdict: { rating: 'bad', best: 'contextPerTurn', worst: 'idleCostShare', lever: 'idleCostShare' },
			metrics: [metric('contextPerTurn', 'medium', 84_500), metric('idleCostShare', 'bad', 0.4)]
		});
		expect(plain(verdictText(s).sentence)).toBe('Handlungsbedarf: Leerlauf kostet 40 % der Sitzungskosten. Größter Hebel: Sitzungen ohne Ergebnis früh beenden.');
	});
	it('is honest without any rated metric', () => {
		const v = verdictText(summary({ verdict: { rating: 'unknown' }, metrics: [] }));
		expect(v.label).toBe('Noch offen');
		expect(v.sentence).toBe('Noch offen: Für diesen Zeitraum gibt es keine bewertbare Kennzahl.');
	});
	it('words the cost trend and every lever', () => {
		const rising = summary({ verdict: { rating: 'medium', worst: 'costPerDay', lever: 'costPerDay' }, metrics: [metric('costPerDay', 'bad', 12, { change: 0.22 })] });
		expect(plain(verdictText(rising).sentence)).toContain('Kosten pro Tag steigen um 22 %');
		for (const id of ['costPerDay', 'cacheHitRate', 'cacheWriteCostShare', 'contextPerTurn', 'opusCostShare', 'idleCostShare'] as MetricID[]) {
			const s = summary({ verdict: { rating: 'medium', worst: id, lever: id }, metrics: [metric(id, 'bad', 0.5, { change: 0.5 })] });
			expect(verdictText(s).sentence, id).toMatch(/^Ordentlich: .+ Größter Hebel: .+\.$/);
		}
	});
});

describe('metric tiles', () => {
	const t = DEFAULT_THRESHOLDS;
	const tile = (m: Metric) => metricTile(m, t);
	it('covers all eight metrics with label, rating word and one reason', () => {
		expect(METRIC_ORDER).toEqual(['costPerDay', 'cacheHitRate', 'cacheWriteCostShare', 'outputShare', 'contextPerTurn', 'opusCostShare', 'costPerDoneCard', 'idleCostShare']);
		for (const id of METRIC_ORDER) {
			for (const rating of ['good', 'medium', 'bad', 'info', 'unknown'] as Rating[]) {
				const r = tile(metric(id, rating, rating === 'unknown' ? undefined : 0.5, { change: 0.1 }));
				expect(r.label.length, id).toBeGreaterThan(2);
				expect(r.why.length, `${id} ${rating}`).toBeGreaterThan(10);
				expect(r.ratingLabel).toBe({ good: 'Gut', medium: 'Mittel', bad: 'Schlecht', info: 'Info', unknown: 'Unbekannt' }[rating]);
			}
		}
	});
	it('formats the value by metric kind and shows a dash without value', () => {
		expect(plain(tile(metric('costPerDay', 'good', 12)).value)).toBe('12,00 $');
		expect(plain(tile(metric('costPerDoneCard', 'good', 3.5)).value)).toBe('3,50 $');
		expect(plain(tile(metric('cacheHitRate', 'good', 0.95)).value)).toBe('95 %');
		expect(tile(metric('contextPerTurn', 'good', 45_000)).value).toBe('45k Tokens');
		expect(tile(metric('idleCostShare', 'unknown')).value).toBe('–');
	});
	it('names the threshold that applies, also after the user changed it', () => {
		expect(plain(tile(metric('cacheHitRate', 'good', 0.95)).why)).toBe('Der Cache trägt: ab 92 % ist das gut.');
		expect(plain(metricTile(metric('cacheHitRate', 'bad', 0.7), { ...t, cacheHitMediumPercent: 75 }).why)).toBe('Zu viel Eingabe wird neu gelesen: unter 75 % ist das schlecht.');
		expect(plain(tile(metric('cacheWriteCostShare', 'bad', 0.68)).why)).toContain('über 65 %');
		expect(plain(tile(metric('contextPerTurn', 'medium', 84_500)).why)).toContain('60k bis 120k');
		expect(plain(tile(metric('idleCostShare', 'good', 0.03)).why)).toContain('unter 5 %');
	});
	it('shows the trend for costs', () => {
		expect(plain(tile(metric('costPerDay', 'bad', 12, { change: 0.22 })).why)).toContain('+22 % gegenüber dem Vorzeitraum');
		expect(plain(tile(metric('costPerDoneCard', 'good', 3, { change: -0.2 })).why)).toContain('−20 % gegenüber dem Vorzeitraum');
		expect(tile(metric('costPerDay', 'unknown', 12)).why).toBe('Ohne Daten im Vorzeitraum gibt es keinen Trend.');
	});
	it('explains why a small output share is normal', () => {
		expect(tile(metric('outputShare', 'info', 0.006)).why).toBe('Ein kleiner Output-Anteil ist bei Agenten normal, weil jeder Schritt den ganzen Kontext neu liest.');
	});
	it('judges the Opus share only against a target', () => {
		expect(tile(metric('opusCostShare', 'info', 0.7)).why).toBe('Ohne Vorgabe wird der Opus-Anteil nicht bewertet; die Vorgabe steht unten bei den Schwellen.');
		expect(plain(metricTile(metric('opusCostShare', 'bad', 0.7), { ...t, opusTargetPercent: 40 }).why)).toContain('Vorgabe: 40 %');
	});
	it('says what is missing for unknown values', () => {
		expect(tile(metric('idleCostShare', 'unknown')).why).toBe('Für keine Sitzung wurde ein Ergebnis (Commits, Karten) gemeldet.');
		expect(tile(metric('contextPerTurn', 'unknown')).why).toBe('Es wurden keine Schritte gemeldet.');
		expect(tile(metric('costPerDoneCard', 'unknown')).why).toBe('Braucht erledigte Karten in Projekten mit Nutzung, auch im Vorzeitraum.');
	});
});

describe('stacked day chart', () => {
	const day = (d: string, input: number, cacheWrite: number, cacheRead: number, output: number) => ({
		day: d, costUSD: input + cacheWrite + cacheRead + output, parts: { input, cacheWrite, cacheRead, output }
	});
	it('rounds the axis up to a readable maximum', () => {
		expect(niceMax(0)).toBe(1);
		expect(niceMax(0.07)).toBeCloseTo(0.1);
		expect(niceMax(3)).toBe(4);
		expect(niceMax(17.2)).toBe(20);
		expect(niceMax(41)).toBe(50);
		expect(niceMax(100)).toBe(100);
	});
	it('stacks input, cache write, cache read and output in this order and scales to the axis', () => {
		expect(PART_KEYS).toEqual(['input', 'cacheWrite', 'cacheRead', 'output']);
		const c = stackedBars([day('2026-11-26', 1, 4, 3, 2), day('2026-11-27', 0, 0, 0, 0)]);
		expect(c.max).toBe(10);
		expect(c.bars[0].height).toBe(100);
		expect(c.bars[0].parts.map((p) => p.key)).toEqual(PART_KEYS);
		expect(c.bars[0].parts.map((p) => p.share)).toEqual([10, 40, 30, 20]);
		expect(c.bars[1]).toMatchObject({ height: 0, parts: [] });
		expect(c.bars[0].label).toBe('26.11.');
	});
	it('leaves out parts that are zero', () => {
		expect(stackedBars([day('2026-11-27', 0, 5, 0, 5)]).bars[0].parts.map((p) => p.key)).toEqual(['cacheWrite', 'output']);
	});
	it('labels only a few days so 30 bars fit on a phone', () => {
		expect(labelIndices(1)).toEqual([0]);
		expect(labelIndices(7)).toEqual([0, 1, 2, 3, 4, 5, 6]);
		expect(labelIndices(30)).toEqual([0, 7, 15, 22, 29]);
	});
});

describe('prices and thresholds', () => {
	const settings: UsageSettings = {
		prices: [
			{ model: 'claude-opus-5-5', input: 4, cacheWrite: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20, custom: false },
			{ model: 'my-model', input: 1, cacheWrite: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5, custom: true }
		],
		thresholds: { ...DEFAULT_THRESHOLDS, cacheHitGoodPercent: 90 }
	};
	it('keeps own entries editable and sends all of them, but no defaults', () => {
		const d = settingsDraft(settings);
		expect(d.prices.map((p) => p.model)).toEqual(['my-model']);
		expect(d.prices[0].cacheWrite).toBe('1,25');
		expect(d.thresholds.cacheHitGoodPercent).toBe('90');
		expect(d.thresholds.cacheHitMediumPercent).toBe('');
		const r = buildSettingsUpdate(d);
		expect(r).toEqual({
			ok: true,
			body: { prices: [{ model: 'my-model', input: 1, cacheWrite: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5 }], thresholds: { cacheHitGoodPercent: 90 } }
		});
	});
	it('adds a row for an unpriced model or as override of a default, once', () => {
		let d = addPriceRow(settingsDraft(settings), 'gpt-6.1-codex');
		expect(d.prices[1]).toEqual({ model: 'gpt-6.1-codex', input: '', cacheWrite: '', cacheWrite1h: '', cacheRead: '', output: '' });
		d = addPriceRow(d, 'gpt-6.1-codex');
		expect(d.prices).toHaveLength(2);
		d = addPriceRow(d, 'claude-opus-5-5', settings.prices[0]);
		expect(d.prices[2]).toMatchObject({ model: 'claude-opus-5-5', input: '4', cacheRead: '0,2', output: '20' });
	});
	it('accepts decimal comma and point, and 0', () => {
		const d = addPriceRow(settingsDraft({ prices: [], thresholds: {} }), 'x');
		Object.assign(d.prices[0], { input: '1,5', cacheWrite: '0', cacheWrite1h: '0', cacheRead: '0.15', output: ' 12 ' });
		d.thresholds.opusTargetPercent = '40';
		expect(buildSettingsUpdate(d)).toEqual({
			ok: true,
			body: { prices: [{ model: 'x', input: 1.5, cacheWrite: 0, cacheWrite1h: 0, cacheRead: 0.15, output: 12 }], thresholds: { opusTargetPercent: 40 } }
		});
	});
	it('reads German thousands separators in token thresholds ("60.000" is sixty thousand)', () => {
		const d = settingsDraft({ prices: [], thresholds: {} });
		d.thresholds.contextGoodTokens = '60.000';
		d.thresholds.contextBadTokens = '1.200.000';
		expect(buildSettingsUpdate(d)).toEqual({ ok: true, body: { prices: [], thresholds: { contextGoodTokens: 60000, contextBadTokens: 1200000 } } });
	});
	it('refuses incomplete, invalid and duplicate prices and invalid thresholds with a sentence', () => {
		const row = { model: 'x', input: '1', cacheWrite: '1', cacheWrite1h: '1', cacheRead: '1', output: '1' };
		const error = (prices: (typeof row)[], thresholds: Record<string, string> = {}) => {
			const d = settingsDraft({ prices: [], thresholds: {} });
			const r = buildSettingsUpdate({ prices, thresholds: { ...d.thresholds, ...thresholds } });
			return r.ok ? null : r.error;
		};
		expect(error([{ ...row, model: ' ' }])).toBe('Jeder Preis braucht eine Modellkennung ohne Leerzeichen (höchstens 80 Zeichen).');
		expect(error([{ ...row, model: 'a b' }])).toContain('Modellkennung');
		expect(error([{ ...row, output: '' }])).toBe('x: Bitte alle fünf Preise als Zahl von 0 bis 10000 ausfüllen.');
		expect(error([{ ...row, output: '-1' }])).toContain('x:');
		expect(error([{ ...row, output: '10001' }])).toContain('x:');
		expect(error([{ ...row, output: '1e3x' }])).toContain('x:');
		expect(error([row, { ...row, model: 'X' }])).toBe('X steht zweimal in der Preisliste.');
		expect(error([], { cacheHitGoodPercent: '101' })).toContain('0 bis 100');
		expect(error([], { contextGoodTokens: 'viel' })).toContain('Zahl');
		expect(error([], { costTrendGoodPercent: '-10' })).toBeNull();
	});
	it('names both fields when a pair of limits is in the wrong order, defaults included', () => {
		const error = (thresholds: Record<string, string>) => {
			const d = settingsDraft({ prices: [], thresholds: {} });
			const r = buildSettingsUpdate({ prices: [], thresholds: { ...d.thresholds, ...thresholds } });
			return r.ok ? null : r.error;
		};
		for (const [input, first, second] of [
			[{ cacheHitMediumPercent: '95' }, 'cacheHitMediumPercent', 'cacheHitGoodPercent'],
			[{ cacheWriteGoodPercent: '70' }, 'cacheWriteGoodPercent', 'cacheWriteBadPercent'],
			[{ contextBadTokens: '50000' }, 'contextGoodTokens', 'contextBadTokens'],
			[{ costTrendGoodPercent: '20' }, 'costTrendGoodPercent', 'costTrendBadPercent'],
			[{ idleGoodPercent: '16' }, 'idleGoodPercent', 'idleBadPercent']
		] as const) {
			const message = error(input);
			expect(message).toContain(t(`usage.threshold.${first}`));
			expect(message).toContain(t(`usage.threshold.${second}`));
		}
		expect(error({ cacheHitMediumPercent: '92' })).toBeNull();
	});
	it('refuses values outside the server ranges', () => {
		const error = (thresholds: Record<string, string>) => {
			const d = settingsDraft({ prices: [], thresholds: {} });
			const r = buildSettingsUpdate({ prices: [], thresholds: { ...d.thresholds, ...thresholds } });
			return r.ok ? null : r.error;
		};
		expect(error({ contextBadTokens: '2000000000' })).toContain(t('usage.threshold.contextBadTokens'));
		expect(error({ costTrendBadPercent: '1001' })).toContain(t('usage.threshold.costTrendBadPercent'));
		expect(error({ costTrendGoodPercent: '-101' })).toContain(t('usage.threshold.costTrendGoodPercent'));
		expect(error({ cardTrendPercent: '1001' })).toContain(t('usage.threshold.cardTrendPercent'));
	});
	it('explains the server refusals instead of a generic error', () => {
		for (const reason of ['invalid_thresholds', 'invalid_prices']) {
			expect(describeError(new ApiError(400, reason))).not.toBe(t('error.generic'));
		}
	});
});

describe('usage api client', () => {
	function recorder() {
		const calls: { url: string; init?: RequestInit }[] = [];
		const api = createApi(async (url, init) => (calls.push({ url, init }), Response.json({})));
		return { calls, api };
	}
	it('asks for the range with the local date', async () => {
		const { calls, api } = recorder();
		await api.usageSummary(30, '2026-11-27');
		await api.usageSettings();
		await api.putUsageSettings({ prices: [], thresholds: {} });
		expect(calls.map((c) => `${c.init?.method} ${c.url}`)).toEqual(['GET /v1/usage/summary?days=30&until=2026-11-27', 'GET /v1/usage/settings', 'PUT /v1/usage/settings']);
		expect(JSON.parse(calls[2].init?.body as string)).toEqual({ prices: [], thresholds: {} });
	});
});
