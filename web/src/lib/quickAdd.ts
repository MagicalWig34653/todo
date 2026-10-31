/**
 * Natural-language quick add (German). Standalone TypeScript port of the Apple parser
 * (Xcode/todo TodoCore/QuickAddParser.swift, same rules and examples) with a few compatible extensions:
 * umlaut spellings ("übermorgen", "täglich", "nächste Woche"), "!1".."!4", "14.30 Uhr" and a `/Abschnitt` token.
 * Pure: `now` is injected; dates use the runtime's local time zone.
 */
export type QuickAddRecurrence = 'daily' | 'weekly' | 'monthly';

export interface QuickAddParse {
	title: string;
	due: Date | null;
	hasTime: boolean;
	/** Stored priority 0..3 (3 = p1 highest); null when the text did not mention one. */
	priority: number | null;
	recurrence: QuickAddRecurrence | null;
	projectToken: string | null;
	labelTokens: string[];
	/** `/Abschnitt` (board column / section) of the target project. */
	sectionToken: string | null;
	/** Phrases removed from the title, in order of recognition (for chips). */
	recognized: string[];
}

// JS getDay(): 0 = Sunday.
const WEEKDAYS: { names: string[]; day: number }[] = [
	{ names: ['sonntag', 'so'], day: 0 },
	{ names: ['montag', 'mo'], day: 1 },
	{ names: ['dienstag', 'di'], day: 2 },
	{ names: ['mittwoch', 'mi'], day: 3 },
	{ names: ['donnerstag', 'do'], day: 4 },
	{ names: ['freitag', 'fr'], day: 5 },
	{ names: ['samstag', 'sa'], day: 6 }
];

/** Lowercase, German umlauts to ae/oe/ue/ss, other diacritics stripped, edge punctuation trimmed. */
function norm(s: string): string {
	return s
		.toLowerCase()
		.replaceAll('ä', 'ae')
		.replaceAll('ö', 'oe')
		.replaceAll('ü', 'ue')
		.replaceAll('ß', 'ss')
		.normalize('NFD')
		.replace(/[̀-ͯ]/g, '')
		.replace(/^[,.;!?]+|[,.;!?]+$/g, '');
}

const isInt = (s: string) => /^\d+$/.test(s);

function startOfDay(d: Date): Date {
	return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}
function addDays(d: Date, n: number): Date {
	const r = new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes(), d.getSeconds());
	return r;
}
/** First matching weekday strictly after `day` (like Calendar.nextDate(after:)). `weekday` uses JS numbering. */
function nextWeekday(weekday: number, day: Date): Date {
	const delta = ((weekday - day.getDay() + 7) % 7) || 7;
	return addDays(day, delta);
}

function parseClock(w: string): [number, number] | null {
	const m = /^(\d{1,2}):(\d{2})$/.exec(w);
	if (!m) return null;
	const h = Number(m[1]);
	const mi = Number(m[2]);
	return h < 24 && mi < 60 ? [h, mi] : null;
}

export function parseQuickAdd(input: string, now: Date = new Date()): QuickAddParse {
	const words = input.split(' ').filter((w) => w !== '');
	const result: QuickAddParse = {
		title: '', due: null, hasTime: false, priority: null, recurrence: null,
		projectToken: null, labelTokens: [], sectionToken: null, recognized: []
	};
	const today = startOfDay(now);
	let dayOffset: number | null = null;
	let dayDate: Date | null = null;
	let time: [number, number] | null = null;

	const take = (i: number, n: number) => {
		result.recognized.push(words.slice(i, i + n).join(' '));
		words.splice(i, n);
	};

	let i = 0;
	while (i < words.length) {
		const raw = words[i];
		const w = norm(raw);
		const next = i + 1 < words.length ? norm(words[i + 1]) : '';
		const next2 = i + 2 < words.length ? norm(words[i + 2]) : '';

		if (raw.startsWith('#') && raw.length > 1) { result.projectToken = raw.slice(1); result.recognized.push(raw); words.splice(i, 1); continue; }
		if (raw.startsWith('@') && raw.length > 1) { result.labelTokens.push(raw.slice(1)); result.recognized.push(raw); words.splice(i, 1); continue; }
		if (raw.startsWith('/') && raw.length > 1) { result.sectionToken = raw.slice(1); result.recognized.push(raw); words.splice(i, 1); continue; }
		const prio = /^(?:p|!)([1-4])$/i.exec(raw.replace(/[,.;?]+$/, ''));
		if (prio) { result.priority = 4 - Number(prio[1]); take(i, 1); continue; }

		switch (w) {
			case 'heute': dayOffset = 0; take(i, 1); continue;
			case 'morgen': dayOffset = 1; take(i, 1); continue;
			case 'uebermorgen': dayOffset = 2; take(i, 1); continue;
			case 'taeglich': result.recurrence = 'daily'; take(i, 1); continue;
			case 'woechentlich': result.recurrence = 'weekly'; take(i, 1); continue;
			case 'monatlich': result.recurrence = 'monthly'; take(i, 1); continue;
		}
		if (w === 'jeden' || w === 'jede' || w === 'jedes') {
			if (next === 'tag') { result.recurrence = 'daily'; take(i, 2); continue; }
			if (next === 'woche') { result.recurrence = 'weekly'; take(i, 2); continue; }
			if (next === 'monat') { result.recurrence = 'monthly'; take(i, 2); continue; }
		}
		if ((w === 'naechste' || w === 'naechsten' || w === 'kommenden') && next === 'woche') {
			dayDate = nextWeekday(1, today); take(i, 2); continue;
		}
		if ((w === 'am' || w === 'naechsten' || w === 'kommenden') && next === 'wochenende') {
			dayDate = nextWeekday(6, today); take(i, 2); continue;
		}
		if (w === 'wochenende') { dayDate = nextWeekday(6, today); take(i, 1); continue; }
		if (w === 'in' && isInt(next)) {
			const n = Number(next);
			if (n > 0 && n < 400) {
				if (next2 === 'tag' || next2 === 'tagen') { dayOffset = n; take(i, 3); continue; }
				if (next2 === 'woche' || next2 === 'wochen') { dayOffset = n * 7; take(i, 3); continue; }
			}
		}
		const entry = WEEKDAYS.find((e) => e.names.includes(w) && (w.length > 2 || (i > 0 && norm(words[i - 1]) === 'am')));
		if (entry) {
			let consumed = 1;
			let start = i;
			if (i > 0 && ['am', 'naechsten', 'naechster'].includes(norm(words[i - 1]))) { start = i - 1; consumed = 2; }
			dayDate = nextWeekday(entry.day, today);
			take(start, consumed);
			i = start;
			continue;
		}
		// Times: "um 14 Uhr", "14:30", "14.30 Uhr", "um 9".
		let clock = parseClock(w);
		if (!clock && next === 'uhr') {
			const m = /^(\d{1,2})\.(\d{2})$/.exec(w);
			if (m && Number(m[1]) < 24 && Number(m[2]) < 60) clock = [Number(m[1]), Number(m[2])];
		}
		if (clock) {
			time = clock;
			if (i > 0 && norm(words[i - 1]) === 'um') { take(i - 1, next === 'uhr' ? 3 : 2); i -= 1; }
			else if (next === 'uhr') take(i, 2);
			else take(i, 1);
			continue;
		}
		if (w === 'um' && isInt(next) && Number(next) < 24) {
			time = [Number(next), 0]; take(i, next2 === 'uhr' ? 3 : 2); continue;
		}
		if (isInt(w) && Number(w) < 24 && next === 'uhr') { time = [Number(w), 0]; take(i, 2); continue; }
		i += 1;
	}

	if (dayDate) result.due = dayDate;
	else if (dayOffset !== null) result.due = addDays(today, dayOffset);
	else if (time || result.recurrence) result.due = today;
	if (time && result.due) {
		const d = result.due;
		result.due = new Date(d.getFullYear(), d.getMonth(), d.getDate(), time[0], time[1], 0);
		result.hasTime = true;
		if (!dayDate && dayOffset === null && result.due < now) result.due = addDays(result.due, 1);
	}
	result.title = words.join(' ').trim();
	return result;
}

// ---- resolving tokens against the account's data ---------------------------------------------------------------

/** Exact name (case-insensitive), then prefix, then a unique substring; null when ambiguous or unknown. */
export function matchByName<T>(items: T[], name: (x: T) => string, token: string): T | null {
	const q = norm(token);
	if (!q) return null;
	const names = items.map((x) => norm(name(x)));
	const exact = items.filter((_, i) => names[i] === q);
	if (exact.length >= 1) return exact[0];
	const prefix = items.filter((_, i) => names[i].startsWith(q));
	if (prefix.length === 1) return prefix[0];
	const part = items.filter((_, i) => names[i].includes(q));
	return part.length === 1 ? part[0] : null;
}

export interface QuickAddChip {
	kind: 'due' | 'priority' | 'recurrence' | 'project' | 'label' | 'section';
	text: string;
}
