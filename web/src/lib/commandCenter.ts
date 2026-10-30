import type { CommandCard, CommandCenter, CommandLane, CommandSummary, LaneKey, Progress, UpdateItem } from './api.js';
import { readJSON, writeJSON } from './localPrefs.js';

/** Fixed lane order of ADR 0014; the server always returns the lanes in this order. */
export const LANE_ORDER: LaneKey[] = ['running', 'question', 'review', 'ready', 'blocked', 'done'];

export type OverviewView = 'kanban' | 'list';
export type OverviewSection = 'board' | 'questions' | 'reviews' | 'updates';

export const VIEW_KEY = 'todo.commandCenterView';
/** Refetch interval while the page is visible (no sync feed for these objects). */
export const REFRESH_MS = 30_000;

export function loadView(): OverviewView {
	return readJSON<string>(VIEW_KEY, 'kanban') === 'list' ? 'list' : 'kanban';
}
export function saveView(v: OverviewView): void {
	writeJSON(VIEW_KEY, v);
}

/** Display percent, clamped to 0..100 and rounded; unknown input counts as 0. */
export function percentOf(p: Pick<Progress, 'percent'> | null | undefined): number {
	const n = Math.round(p?.percent ?? 0);
	return Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : 0;
}

/** Counter shown next to the bar, depending on where the percentage comes from; empty when there is nothing to count. */
export function progressCounter(p: Progress): { kind: 'subtasks' | 'criteria'; done: number; total: number } | null {
	if (p.source === 'subtasks' && p.subtasksTotal > 0) return { kind: 'subtasks', done: p.subtasksDone, total: p.subtasksTotal };
	if (p.source === 'criteria' && p.criteriaTotal > 0) return { kind: 'criteria', done: p.criteriaDone, total: p.criteriaTotal };
	return null;
}

/** Cards of a response regardless of the view (kanban lanes are flattened in lane order). */
export function cardsOf(cc: CommandCenter | null): CommandCard[] {
	if (!cc) return [];
	if (cc.items) return cc.items;
	return (cc.lanes ?? []).flatMap((l) => l.cards);
}

/** Lanes in fixed order; missing lanes (older servers) become empty ones so the board layout is stable. */
export function orderedLanes(lanes: CommandLane[] | null | undefined, titles: (k: LaneKey) => string): CommandLane[] {
	const byKey = new Map((lanes ?? []).map((l) => [l.key, l]));
	return LANE_ORDER.map((key) => byKey.get(key) ?? { key, title: titles(key), count: 0, truncated: false, cards: [] });
}

/** Number that deserves attention in the sidebar: open questions plus reviews waiting for a decision. */
export function attentionCount(s: Pick<CommandSummary, 'openQuestions' | 'pendingReviews'> | null | undefined): number {
	return (s?.openQuestions ?? 0) + (s?.pendingReviews ?? 0);
}

/** Open questions of all cards, newest first, de-duplicated by id (feature cards repeat subtask questions). */
export function questionsOf(cards: CommandCard[]): { card: CommandCard; question: CommandCard['questions'][number] }[] {
	const seen = new Set<string>();
	const out: { card: CommandCard; question: CommandCard['questions'][number] }[] = [];
	for (const card of cards) {
		for (const question of card.questions) {
			if (seen.has(question.id)) continue;
			seen.add(question.id);
			out.push({ card, question });
		}
	}
	return out.sort((a, b) => (b.question.createdAt ?? '').localeCompare(a.question.createdAt ?? ''));
}

/** A free-text answer is allowed only for questions without options; with options exactly one of them must be sent. */
export function validateAnswer(options: string[], answer: string): string | null {
	const a = answer.trim();
	if (!a) return null;
	if (options.length > 0) return options.includes(a) ? a : null;
	return a.length <= 10000 ? a : null;
}

export type ReviewDecision = 'accept' | 'request_changes';
/** Requesting changes without saying what to change is rarely useful; the UI asks for a note then. */
export function decisionNeedsNote(decision: ReviewDecision, note: string): boolean {
	return decision === 'request_changes' && !note.trim();
}

export type UpdateGroup = 'progress' | 'asked' | 'answered' | 'withdrawn' | 'review' | 'accepted' | 'changes' | 'build' | 'claimed' | 'released' | 'blocked' | 'agent';

/** Maps the activity kind of an update (`updateKinds` in the backend) to a stable i18n suffix. */
export function updateKind(kind: string): UpdateGroup {
	switch (kind) {
		case 'progress.posted':
			return 'progress';
		case 'question.asked':
		case 'agent.question':
			return 'asked';
		case 'question.answered':
		case 'agent.answered':
			return 'answered';
		case 'question.withdrawn':
			return 'withdrawn';
		case 'review.requested':
		case 'agent.submit':
			return 'review';
		case 'review.accepted':
		case 'agent.accept':
			return 'accepted';
		case 'review.changes_requested':
		case 'agent.request_changes':
			return 'changes';
		case 'build.added':
			return 'build';
		case 'task.claimed':
		case 'agent.claimed':
			return 'claimed';
		case 'task.released':
		case 'agent.released':
			return 'released';
		case 'task.blocked':
			return 'blocked';
		default:
			return 'agent';
	}
}

export function sortUpdates(items: UpdateItem[]): UpdateItem[] {
	return [...items].sort((a, b) => (b.createdAt ?? '').localeCompare(a.createdAt ?? ''));
}

/** Backlog and other columns never appear as lanes; the overview is empty when nothing is active. */
export function isEmptyOverview(cc: CommandCenter | null): boolean {
	if (!cc) return false;
	return cardsOf(cc).length === 0 && cc.updates.length === 0;
}

/** Heading shown above the agent brief when a project has none yet. */
export const BRIEF_TEMPLATE = '## Goals\n\n## Constraints\n\n## Definition of done\n\n## Agent rules\n';
export const BRIEF_MAX = 20000;
