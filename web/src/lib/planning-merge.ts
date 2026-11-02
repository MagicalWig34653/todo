import type { PlanningTask } from './api.js';
import { toLocalInput } from './planning.js';

/** The editable planning fields as the form holds them (strings for inputs, so values compare exactly). */
export interface PlanningForm {
	due: string;
	planned: string;
	priority: number;
	frequency: string;
	interval: number;
	until: string;
	reminders: string[];
}
export type PlanningField = keyof PlanningForm;
export const PLANNING_FIELDS: PlanningField[] = ['due', 'planned', 'priority', 'frequency', 'interval', 'until', 'reminders'];

/** Form values for a stored planning. */
export function planningForm(pt: PlanningTask): PlanningForm {
	return {
		due: toLocalInput(pt.dueAt),
		planned: toLocalInput(pt.plannedAt),
		priority: pt.priority,
		frequency: pt.recurrence?.frequency ?? 'none',
		interval: pt.recurrence?.interval ?? 1,
		until: toLocalInput(pt.recurrence?.until),
		reminders: [...pt.reminders]
	};
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/**
 * Three-way merge of the planning form. `base` is what the form was last synchronised with, `mine` what it holds
 * now, `server` the freshly fetched state. Untouched fields follow the server. A field changed on both sides to
 * different values is a conflict: the local value stays and the base moves to the server value, so saving again
 * overwrites knowingly.
 */
export function mergePlanning(
	base: PlanningForm,
	mine: PlanningForm,
	server: PlanningForm
): { form: PlanningForm; base: PlanningForm; conflicts: PlanningField[] } {
	const form = { ...mine } as Record<PlanningField, unknown>;
	const nextBase = { ...base } as Record<PlanningField, unknown>;
	const conflicts: PlanningField[] = [];
	for (const f of PLANNING_FIELDS) {
		if (same(mine[f], base[f])) {
			form[f] = server[f];
			nextBase[f] = server[f];
		} else if (same(server[f], mine[f])) {
			nextBase[f] = server[f];
		} else if (!same(server[f], base[f])) {
			conflicts.push(f);
			nextBase[f] = server[f];
		}
	}
	return { form: form as unknown as PlanningForm, base: nextBase as unknown as PlanningForm, conflicts };
}
