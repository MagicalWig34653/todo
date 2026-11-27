/** Logic of the page "Kosteneffizienz" (contracts/usage.yaml): types, formatting, judgement texts, chart geometry, settings form. */
import { t, type MessageKey } from './i18n/index.js';
import { de } from './i18n/de.js';

export type Rating = 'good' | 'medium' | 'bad' | 'info' | 'unknown';
export const METRIC_ORDER = [
	'costPerDay', 'cacheHitRate', 'cacheWriteCostShare', 'outputShare', 'contextPerTurn', 'opusCostShare', 'costPerDoneCard', 'idleCostShare'
] as const;
export type MetricID = (typeof METRIC_ORDER)[number];
export interface Metric {
	id: MetricID;
	rating: Rating;
	value?: number;
	previous?: number;
	change?: number;
}
export const PART_KEYS = ['input', 'cacheWrite', 'cacheRead', 'output'] as const;
export type PartKey = (typeof PART_KEYS)[number];
export type CostParts = Record<PartKey, number>;
export type UsageDays = 1 | 7 | 30;
export interface UsageDay {
	day: string;
	costUSD: number;
	parts: CostParts;
}
export interface UsageModel {
	family: 'opus' | 'sonnet' | 'haiku' | 'fable' | 'codex' | 'other';
	costUSD: number;
	share: number;
	tokens: number;
}
export interface UsageSession {
	sessionKey: string;
	costUSD: number;
	share: number;
	models: string[];
	projectID?: string;
	projectName?: string;
	turns: number;
	maxContextTokens: number;
	subagent: boolean;
	commits?: number;
	cardUpdates?: number;
	idle: boolean;
}
export interface UsageProject {
	projectID?: string;
	projectName?: string;
	costUSD: number;
	share: number;
	doneCards: number;
	costPerDoneCard?: number;
}
export interface UsageSummary {
	days: number;
	from: string;
	until: string;
	partial: boolean;
	hasData: boolean;
	hasAnyData?: boolean;
	totalCostUSD: number;
	previousCostUSD?: number;
	verdict: { rating: Rating; best?: string; worst?: string; lever?: string };
	metrics: Metric[];
	series: UsageDay[];
	models: UsageModel[];
	sessions: UsageSession[];
	projects: UsageProject[];
	unpricedModels: string[];
}
export const PRICE_FIELDS = ['input', 'cacheWrite', 'cacheWrite1h', 'cacheRead', 'output'] as const;
export type PriceField = (typeof PRICE_FIELDS)[number];
export type Price = { model: string; custom?: boolean } & Record<PriceField, number>;
export const DEFAULT_THRESHOLDS = {
	costTrendGoodPercent: -5,
	costTrendBadPercent: 15,
	cacheHitGoodPercent: 92,
	cacheHitMediumPercent: 85,
	cacheWriteGoodPercent: 45,
	cacheWriteBadPercent: 65,
	contextGoodTokens: 60000,
	contextBadTokens: 120000,
	cardTrendPercent: 5,
	idleGoodPercent: 5,
	idleBadPercent: 15
};
export type Thresholds = Partial<typeof DEFAULT_THRESHOLDS> & { opusTargetPercent?: number };
export const THRESHOLD_KEYS = [
	'costTrendGoodPercent', 'costTrendBadPercent', 'cacheHitGoodPercent', 'cacheHitMediumPercent', 'cacheWriteGoodPercent', 'cacheWriteBadPercent',
	'contextGoodTokens', 'contextBadTokens', 'opusTargetPercent', 'cardTrendPercent', 'idleGoodPercent', 'idleBadPercent'
] as const;
export type ThresholdKey = (typeof THRESHOLD_KEYS)[number];
export interface UsageSettings {
	prices: Price[];
	thresholds: Thresholds;
}

// --- formatting -----------------------------------------------------------------------------------------------------

const money = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'USD' });
const percent = new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 });
const decimal = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 });
const whole = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 0 });

export const formatUSD = (v: number): string => (v > 0 && v < 0.01 ? `< ${money.format(0.01)}` : money.format(v));
export const formatShare = (v: number): string => (v > 0 && v < 0.001 ? `< ${percent.format(0.001)}` : percent.format(v));
export const formatCount = (v: number): string => whole.format(v);
export function formatTokens(v: number): string {
	if (v < 1000) return whole.format(v);
	if (v < 999_950) return `${decimal.format(v / 1000)}k`;
	return `${decimal.format(v / 1_000_000)} Mio.`;
}
export function formatChange(change: number): string {
	const abs = percent.format(Math.abs(change));
	if (abs === percent.format(0)) return `±${abs}`;
	return `${change > 0 ? '+' : '−'}${abs}`;
}
/** `2026-11-27` -> `27.11.` (the string is a calendar day, no time zone involved). */
export const formatDay = (day: string): string => `${day.slice(8, 10)}.${day.slice(5, 7)}.`;
/** The browser's local calendar date, sent as `until`. */
export const localDate = (d: Date): string =>
	`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

// --- page state, trend ----------------------------------------------------------------------------------------------

export type PageState = 'setup' | 'quiet' | 'filled';
export const pageState = (s: UsageSummary): PageState => (s.hasAnyData === false ? 'setup' : s.hasData ? 'filled' : 'quiet');

const rangeOf = (days: number): UsageDays => (days === 1 || days === 30 ? days : 7);

export function costTrend(s: UsageSummary): string {
	if (s.previousCostUSD === undefined) return t('usage.trend.none');
	const amount = formatUSD(s.previousCostUSD);
	if (s.previousCostUSD <= 0) return t('usage.trend.zero', { amount });
	const change = formatChange((s.totalCostUSD - s.previousCostUSD) / s.previousCostUSD);
	return t(`usage.trend.${rangeOf(s.days)}`, { change, amount });
}
export const partialHint = (s: UsageSummary): string | null => (s.partial ? t('usage.partial', { day: formatDay(s.until) }) : null);

// --- metric tiles ---------------------------------------------------------------------------------------------------

const MONEY_METRICS = new Set<MetricID>(['costPerDay', 'costPerDoneCard']);

export function metricValue(m: Metric): string {
	if (m.value === undefined) return '–';
	if (MONEY_METRICS.has(m.id)) return formatUSD(m.value);
	if (m.id === 'contextPerTurn') return t('usage.value.tokens', { value: formatTokens(m.value) });
	return formatShare(m.value);
}

function why(m: Metric, th: Thresholds): string {
	const all = { ...DEFAULT_THRESHOLDS, ...th };
	const share = (p: number) => formatShare(p / 100);
	if (m.id === 'outputShare') return t('usage.why.outputShare');
	if (m.id === 'costPerDay' || m.id === 'costPerDoneCard') {
		if (m.rating === 'unknown') return t(`usage.why.${m.id}.unknown`);
		if (m.change === undefined) return t(`usage.why.${m.id}.noChange`);
		const change = formatChange(m.change);
		return m.id === 'costPerDay'
			? t('usage.why.costPerDay.rated', { change, good: formatChange(all.costTrendGoodPercent / 100), bad: formatChange(all.costTrendBadPercent / 100) })
			: t('usage.why.costPerDoneCard.rated', { change, span: share(all.cardTrendPercent) });
	}
	const key = `usage.why.${m.id}.${m.rating}`;
	if (!(key in de)) return t('usage.why.generic');
	const params: Record<string, string> =
		m.id === 'cacheHitRate'
			? { good: share(all.cacheHitGoodPercent), medium: share(all.cacheHitMediumPercent) }
			: m.id === 'cacheWriteCostShare'
				? { good: share(all.cacheWriteGoodPercent), bad: share(all.cacheWriteBadPercent) }
				: m.id === 'contextPerTurn'
					? { good: formatTokens(all.contextGoodTokens), bad: formatTokens(all.contextBadTokens) }
					: m.id === 'idleCostShare'
						? { good: share(all.idleGoodPercent), bad: share(all.idleBadPercent) }
						: { target: all.opusTargetPercent === undefined ? '–' : share(all.opusTargetPercent) };
	return t(key as MessageKey, params);
}

export interface Tile {
	id: MetricID;
	rating: Rating;
	label: string;
	value: string;
	ratingLabel: string;
	why: string;
}
export const metricTile = (m: Metric, thresholds: Thresholds): Tile => ({
	id: m.id,
	rating: m.rating,
	label: t(`usage.metric.${m.id}`),
	value: metricValue(m),
	ratingLabel: t(`usage.rating.${m.rating}`),
	why: why(m, thresholds)
});

// --- verdict --------------------------------------------------------------------------------------------------------

/** The clause of one rated metric ("Cache trifft zu 95 %"), or null without a value. */
function clause(m: Metric | undefined): string | null {
	if (!m || m.value === undefined || m.id === 'outputShare' || m.id === 'costPerDoneCard') return null;
	if (m.id === 'costPerDay') {
		if (!m.change) return t('usage.clause.costPerDay.flat', { value: formatUSD(m.value) });
		return t(m.change > 0 ? 'usage.clause.costPerDay.up' : 'usage.clause.costPerDay.down', { value: formatShare(Math.abs(m.change)) });
	}
	const value = m.id === 'contextPerTurn' ? metricValue(m) : formatShare(m.value);
	return t(`usage.clause.${m.id}.${m.rating === 'good' ? 'good' : 'problem'}`, { value });
}

export function verdictText(s: UsageSummary): { rating: Rating; label: string; sentence: string } {
	const { rating } = s.verdict;
	const label = t(`usage.verdict.${rating}`);
	const find = (id?: string) => s.metrics.find((m) => m.id === id);
	const done = (text: string) => ({ rating, label, sentence: `${label}: ${text}` });
	if (rating === 'unknown' || rating === 'info') return done(t('usage.verdict.none'));
	const bestMetric = find(s.verdict.best);
	// "best" is only praise when it really is good.
	const best = bestMetric?.rating === 'good' ? clause(bestMetric) : null;
	if (!s.verdict.worst) return done([best && `${best}.`, t('usage.verdict.fine')].filter(Boolean).join(' '));
	const worst = clause(find(s.verdict.worst));
	const first = best && worst ? t('usage.verdict.but', { best, worst }) : (worst ?? best) && `${worst ?? best}.`;
	const leverKey = `usage.lever.${s.verdict.lever ?? s.verdict.worst}`;
	const lever = leverKey in de ? t('usage.verdict.lever', { lever: t(leverKey as MessageKey) }) : null;
	return done([first, lever].filter(Boolean).join(' '));
}

// --- chart geometry -------------------------------------------------------------------------------------------------

/** Next readable axis maximum: 1, 2, 4, 5 or 10 times a power of ten. */
export function niceMax(v: number): number {
	if (!(v > 0)) return 1;
	const base = 10 ** Math.floor(Math.log10(v));
	return [1, 2, 4, 5, 10].map((f) => f * base).find((c) => c >= v * (1 - 1e-9))!;
}

export interface Bar {
	day: string;
	label: string;
	total: number;
	/** Percent of the axis maximum. */
	height: number;
	/** Non-zero cost parts, bottom to top; `share` in percent of the bar. */
	parts: { key: PartKey; value: number; share: number }[];
}
export function stackedBars(series: UsageDay[]): { max: number; bars: Bar[] } {
	const sum = (p: CostParts) => PART_KEYS.reduce((a, k) => a + p[k], 0);
	const max = niceMax(Math.max(0, ...series.map((d) => sum(d.parts))));
	const bars = series.map((d) => {
		const total = sum(d.parts);
		return {
			day: d.day,
			label: formatDay(d.day),
			total,
			height: (total / max) * 100,
			parts: PART_KEYS.filter((k) => d.parts[k] > 0).map((key) => ({ key, value: d.parts[key], share: (d.parts[key] / total) * 100 }))
		};
	});
	return { max, bars };
}

/** Which of `n` bars get a date label (all up to a week, otherwise five evenly spread). */
export const labelIndices = (n: number): number[] =>
	n <= 7 ? Array.from({ length: n }, (_, i) => i) : Array.from({ length: 5 }, (_, i) => Math.round((i * (n - 1)) / 4));

// --- settings form --------------------------------------------------------------------------------------------------

export type PriceDraft = { model: string } & Record<PriceField, string>;
export interface SettingsDraft {
	prices: PriceDraft[];
	thresholds: Record<ThresholdKey, string>;
}
export interface SettingsUpdate {
	prices: Omit<Price, 'custom'>[];
	thresholds: Thresholds;
}

const asInput = (v: number): string => String(v).replace('.', ',');
const priceDraft = (model: string, from?: Price): PriceDraft => ({
	model,
	...(Object.fromEntries(PRICE_FIELDS.map((f) => [f, from ? asInput(from[f]) : ''])) as Record<PriceField, string>)
});

/** Own prices stay editable; a threshold that equals its default is shown as empty (it keeps following the default). */
export function settingsDraft(s: UsageSettings): SettingsDraft {
	const defaults: Thresholds = DEFAULT_THRESHOLDS;
	return {
		prices: s.prices.filter((p) => p.custom).map((p) => priceDraft(p.model, p)),
		thresholds: Object.fromEntries(
			THRESHOLD_KEYS.map((k) => {
				const v = s.thresholds[k];
				return [k, v === undefined || v === defaults[k] ? '' : asInput(v)];
			})
		) as Record<ThresholdKey, string>
	};
}

export function addPriceRow(draft: SettingsDraft, model: string, from?: Price): SettingsDraft {
	if (model && draft.prices.some((p) => p.model.toLowerCase() === model.toLowerCase())) return draft;
	return { ...draft, prices: [...draft.prices, priceDraft(model, from)] };
}

/** German or English decimal notation without thousands separators; null for anything else. */
function parseNumber(text: string): number | null {
	const s = text.trim();
	return /^-?\d+([.,]\d+)?$/.test(s) ? Number(s.replace(',', '.')) : null;
}

const MODEL = /^[A-Za-z0-9._:/[\]-]{1,80}$/;

export function buildSettingsUpdate(draft: SettingsDraft): { ok: true; body: SettingsUpdate } | { ok: false; error: string } {
	const fail = (key: MessageKey, params?: Record<string, string>) => ({ ok: false as const, error: t(key, params) });
	if (draft.prices.length > 100) return fail('usage.invalid.tooMany');
	const prices: SettingsUpdate['prices'] = [];
	const seen = new Set<string>();
	for (const row of draft.prices) {
		const model = row.model.trim();
		if (!MODEL.test(model)) return fail('usage.invalid.model');
		if (seen.has(model.toLowerCase())) return fail('usage.invalid.duplicate', { model });
		seen.add(model.toLowerCase());
		const price = { model } as Omit<Price, 'custom'>;
		for (const f of PRICE_FIELDS) {
			const v = parseNumber(row[f]);
			if (v === null || v < 0 || v > 10000) return fail('usage.invalid.price', { model });
			price[f] = v;
		}
		prices.push(price);
	}
	const thresholds: Thresholds = {};
	for (const k of THRESHOLD_KEYS) {
		const text = draft.thresholds[k].trim();
		if (!text) continue;
		// Token counts may be typed the German way ("60.000").
		const v = parseNumber(k.startsWith('context') && /^\d{1,3}(\.\d{3})+$/.test(text) ? text.replaceAll('.', '') : text);
		const field = t(`usage.threshold.${k}`);
		// Trend thresholds may be negative; token counts are open ended; everything else is a share in percent.
		const isShare = !k.startsWith('costTrend') && !k.startsWith('context') && k !== 'cardTrendPercent';
		if (isShare && (v === null || v < 0 || v > 100)) return fail('usage.invalid.percent', { field });
		if (v === null || (!k.startsWith('costTrend') && v < 0)) return fail('usage.invalid.number', { field });
		thresholds[k] = v;
	}
	return { ok: true, body: { prices, thresholds } };
}
