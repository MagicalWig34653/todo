import { can, roleOf } from './access.js';
import { api, type Assignee } from './api.js';
import { auth } from './auth.svelte.js';
import { lacksResponsibility, responsibleName } from './assignment.js';
import { t } from './i18n/index.js';
import { workspace } from './workspace.svelte.js';

/** A list older than this is fetched again when somebody asks for it (rights and members change rarely). */
const MAX_AGE_MS = 60_000;

/**
 * Assignable people per project (`GET /v1/projects/{id}/assignees`, needs edit). Readers never ask: they only know the
 * names the server sends along, else a neutral label.
 */
class Directory {
	private lists = $state<Record<string, Assignee[]>>({});
	private asked = new Map<string, number>();
	private gen = 0;
	/** False once the server proved to know nothing about responsibility: then there is nothing to choose or hand over. */
	supported = $state(true);

	reset(): void {
		this.gen++;
		this.lists = {};
		this.asked.clear();
		this.supported = true;
	}

	people(projectID: string | null | undefined): Assignee[] {
		return (projectID && this.lists[projectID]) || [];
	}

	/** May this account read the list (and therefore assign) in the project? */
	mayAssign(projectID: string | null | undefined): boolean {
		const project = workspace.projects.find((p) => p.id === projectID);
		return this.supported && !!project && can(roleOf(project), 'editTask');
	}

	/** Fetches the list when allowed and not fresh. Failures (older server) leave the names unknown. */
	async load(projectID: string | null | undefined, force = false): Promise<void> {
		if (!projectID || !this.mayAssign(projectID)) return;
		if (!force && Date.now() - (this.asked.get(projectID) ?? 0) < MAX_AGE_MS) return;
		this.asked.set(projectID, Date.now());
		const gen = this.gen;
		try {
			const list = await api.listAssignees(projectID);
			if (gen === this.gen) this.lists[projectID] = list;
		} catch (e) {
			const old = await lacksResponsibility(e, () => api.forMe());
			if (gen !== this.gen) return;
			if (old) this.supported = false;
			else this.asked.delete(projectID);
		}
	}

	/** Name of a responsible person, `null` when this account cannot name them. */
	nameOf(projectID: string | null | undefined, id: string | null | undefined, serverName?: string | null): string | null {
		return responsibleName(id, serverName, this.people(projectID), auth.user);
	}

	/** The name, or "eine andere Person" for a person this account cannot name. */
	label(projectID: string | null | undefined, id: string, serverName?: string | null): string {
		return this.nameOf(projectID, id, serverName) ?? t('assign.otherPerson');
	}
}

export const directory = new Directory();
