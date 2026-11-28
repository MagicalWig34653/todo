import type { Api, Task } from './api.js';

/** Fields of a new card in the large draft window (card A42C423B). */
export interface CardDraft {
	title: string;
	/** Markdown. */
	description: string;
	projectID: string;
	columnID: string | null;
	/** 0 (none) to 3 (high), see `PRIORITIES`. */
	priority: number;
	/** `<input type="date">` value (YYYY-MM-DD, local day) or ''. */
	due: string;
	labelIDs: string[];
	files: File[];
	/** Responsible person (account ID) or '' for nobody. */
	assigneeID?: string;
}

export interface DraftOutcome {
	task: Task;
	/** Secondary steps that failed after the task itself was stored (the card opens anyway, the window says what is missing). */
	failed: ('planning' | 'assignee' | 'labels' | 'attachments')[];
}

type DraftApi = Pick<Api, 'createTask' | 'putPlanning' | 'addTaskLabel' | 'setTaskAssignee'>;

/** Local midnight of a date input value as ISO instant (shown as date only); null for an empty or invalid value. */
export function dueFromDate(value: string): string | null {
	if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
	const d = new Date(`${value}T00:00`);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * Stores a draft: the task first (a failure throws, so the draft stays open with all input), then planning, the
 * responsible person (its own route), labels and attachments as best effort. `attach` uploads one file (begin, upload, complete).
 */
export async function createDraftTask(api: DraftApi, draft: CardDraft, attach: (taskID: string, file: File) => Promise<void>): Promise<DraftOutcome> {
	const title = draft.title.trim();
	if (!title) throw new Error('empty_title');
	const description = draft.description.trim();
	const task = await api.createTask(draft.projectID, title, {
		...(description ? { description: draft.description } : {}),
		...(draft.columnID ? { columnID: draft.columnID } : {})
	});
	const failed: DraftOutcome['failed'] = [];
	const dueAt = dueFromDate(draft.due);
	if (dueAt || draft.priority > 0) {
		try {
			await api.putPlanning(task.id, { dueAt, plannedAt: null, priority: draft.priority, recurrence: null, reminders: [] });
		} catch {
			failed.push('planning');
		}
	}
	if (draft.assigneeID) {
		try {
			await api.setTaskAssignee(task.id, draft.assigneeID);
		} catch {
			failed.push('assignee');
		}
	}
	try {
		for (const id of draft.labelIDs) await api.addTaskLabel(task.id, id);
	} catch {
		failed.push('labels');
	}
	for (const file of draft.files) {
		try {
			await attach(task.id, file);
		} catch {
			if (!failed.includes('attachments')) failed.push('attachments');
		}
	}
	return { task, failed };
}
