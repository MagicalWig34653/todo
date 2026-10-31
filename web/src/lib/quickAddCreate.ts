import type { Api, Label, Project, Task } from './api.js';
import { browserTimeZone } from './planning.js';
import { matchByName, type QuickAddParse } from './quickAdd.js';

export interface QuickAddContext {
	projects: Project[];
	labels: Label[];
	/** Used when the text names no (known) `#project`. */
	defaultProjectID: string;
	/** Board column the entry was started in. */
	columnID?: string | null;
	/** Previous task of this session; used when the entry is indented (Tab). Ignored across projects. */
	parent?: Task | null;
	asFeature?: boolean;
}

export interface QuickAddOutcome {
	task: Task;
	/** Secondary steps (planning, labels, structure) that failed after the task itself was stored. */
	failed: ('planning' | 'labels' | 'structure')[];
	projectID: string;
	newLabels: Label[];
}

type CreateApi = Pick<Api, 'createTask' | 'putPlanning' | 'projectBoard' | 'createLabel' | 'addTaskLabel' | 'setTaskStructure'>;

/**
 * Stores one parsed quick-add line: the task first (a failure there throws, so the caller keeps the text), then
 * planning, labels and parent as best effort. Unknown `#project` / `/section` tokens stay in the title.
 */
export async function createQuickTask(api: CreateApi, parsed: QuickAddParse, ctx: QuickAddContext): Promise<QuickAddOutcome> {
	let title = parsed.title;
	const restore: string[] = [];
	let project = parsed.projectToken ? matchByName(ctx.projects, (p) => p.name, parsed.projectToken) : null;
	if (parsed.projectToken && !project) restore.push(`#${parsed.projectToken}`);
	project ??= ctx.projects.find((p) => p.id === ctx.defaultProjectID) ?? null;
	if (!project) throw new Error('no_project');

	let columnID = project.id === ctx.defaultProjectID ? (ctx.columnID ?? null) : null;
	if (parsed.sectionToken) {
		let found: string | null = null;
		try {
			const board = await api.projectBoard(project.id);
			const cols = board.columns.filter((c) => c.id);
			found = matchByName(cols, (c) => c.name, parsed.sectionToken)?.id ?? null;
		} catch {
			/* fall through: token stays in the title */
		}
		if (found) columnID = found;
		else restore.push(`/${parsed.sectionToken}`);
	}
	if (restore.length) title = `${title} ${restore.join(' ')}`.trim();
	if (!title) throw new Error('empty_title');

	const task = await api.createTask(project.id, title, columnID ? { columnID } : {});
	const failed: QuickAddOutcome['failed'] = [];
	const newLabels: Label[] = [];

	if (parsed.due || parsed.priority !== null || parsed.recurrence) {
		try {
			await api.putPlanning(task.id, {
				dueAt: parsed.due ? parsed.due.toISOString() : null,
				plannedAt: null,
				priority: parsed.priority ?? 0,
				recurrence: parsed.recurrence ? { frequency: parsed.recurrence, interval: 1, timeZone: browserTimeZone() } : null,
				reminders: []
			});
		} catch {
			failed.push('planning');
		}
	}
	if (parsed.labelTokens.length) {
		try {
			const known = [...ctx.labels];
			for (const token of parsed.labelTokens) {
				let label = matchByName(known, (l) => l.name, token);
				if (!label) {
					label = await api.createLabel(token);
					known.push(label);
					newLabels.push(label);
				}
				await api.addTaskLabel(task.id, label.id);
			}
		} catch {
			failed.push('labels');
		}
	}
	const structure: { parentTaskID?: string; kind?: string } = {};
	if (ctx.parent && ctx.parent.projectID === project.id) structure.parentTaskID = ctx.parent.id;
	if (ctx.asFeature) structure.kind = 'feature';
	if (Object.keys(structure).length) {
		try {
			await api.setTaskStructure(task.id, structure);
		} catch {
			failed.push('structure');
		}
	}
	return { task, failed, projectID: project.id, newLabels };
}
