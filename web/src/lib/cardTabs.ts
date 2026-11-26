/** Tabs of the large card detail window (`?card=<type>:<id>&tab=<name>`) and the pure logic behind them. */
import type { ProgressNote, Question, Review } from './api.js';

export const CARD_TABS = ['overview', 'activity', 'report', 'pipeline', 'changes', 'tests'] as const;
export type CardTab = (typeof CARD_TABS)[number];
export const DEFAULT_TAB: CardTab = 'overview';
/** Tabs prepared for data that has no source yet; they show an honest empty state. */
export const DATA_TABS = ['pipeline', 'changes', 'tests'] as const satisfies readonly CardTab[];

/** Null for anything that is not exactly a known tab name. */
export function parseCardTab(raw: string | null | undefined): CardTab | null {
	return raw && (CARD_TABS as readonly string[]).includes(raw) ? (raw as CardTab) : null;
}

/**
 * Tabs the card window shows (UX step 1: a tab appears only when it has something to show). Übersicht and Aktivität always;
 * Bericht and Pipeline with data; Änderungen and Tests have no source yet. The current tab always stays, so an old link
 * with `&tab=` still opens it (with its honest empty state).
 */
export function visibleTabs(has: { report: boolean; pipeline: boolean }, current: CardTab): CardTab[] {
	return CARD_TABS.filter((tab) => tab === 'overview' || tab === 'activity' || tab === current || (tab === 'report' && has.report) || (tab === 'pipeline' && has.pipeline));
}

/** The tab a key press moves to among `tabs` (arrows wrap around, Home/End jump); null for every other key. */
export function tabAfterKey(current: CardTab, key: string, tabs: readonly CardTab[] = CARD_TABS): CardTab | null {
	const i = Math.max(0, tabs.indexOf(current));
	const last = tabs.length - 1;
	switch (key) {
		case 'ArrowRight':
			return tabs[i === last ? 0 : i + 1]!;
		case 'ArrowLeft':
			return tabs[i === 0 ? last : i - 1]!;
		case 'Home':
			return tabs[0]!;
		case 'End':
			return tabs[last]!;
		default:
			return null;
	}
}

export interface Report {
	/** Progress notes, oldest first. */
	notes: ProgressNote[];
	/** Questions (open, answered, withdrawn), oldest first. */
	questions: Question[];
	review: Review | null;
	/** Only after an accepted review: its summary is the completion summary. */
	completion: { summary: string; decidedAt?: string | null; decisionNote?: string | null; lastPercent: number | null } | null;
	isEmpty: boolean;
}

const time = (iso?: string | null) => (iso ? new Date(iso).getTime() || 0 : 0);

/** Report of a card from data the task context already carries (no extra request). */
export function buildReport(ctx: { progressNotes: ProgressNote[]; questions: Question[]; review?: Review | null }): Report {
	// The API lists notes newest first and stamps whole seconds: reversing first keeps notes of one second in posting order.
	const notes = [...ctx.progressNotes].reverse().sort((a, b) => time(a.createdAt) - time(b.createdAt));
	const questions = [...ctx.questions].sort((a, b) => time(a.createdAt) - time(b.createdAt));
	const review = ctx.review ?? null;
	const lastPercent = [...notes].reverse().find((n) => n.percent != null)?.percent ?? null;
	const completion =
		review?.state === 'accepted' ? { summary: review.summary, decidedAt: review.decidedAt, decisionNote: review.decisionNote, lastPercent } : null;
	return { notes, questions, review, completion, isEmpty: notes.length === 0 && questions.length === 0 && !review };
}
