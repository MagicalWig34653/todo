import { api, type Label, type Project, type ProjectPrefs, type SavedFilter, type Task, type Team, type TeamMembership } from './api.js';
import { inboxTasks, openCounts, todayTasks } from './counts.js';
import type { Display } from './listLogic.js';
import { KEYS, readJSON, writeJSON } from './localPrefs.js';
import { collectAll } from './planning.js';
import { projectColor } from './boardLogic.js';
import { defaultPrefs, displayChangeToPrefs, favoriteProjects, hasLegacyState, importLegacyState, prefsToDisplay, applyPrefsChange, savePrefs } from './projectState.js';

/** Shared client state of the signed-in workspace: projects, all own tasks (for counts), teams, labels, filters. */
class Workspace {
	projects = $state<Project[]>([]);
	tasks = $state<Task[]>([]);
	teams = $state<Team[]>([]);
	invitations = $state<TeamMembership[]>([]);
	labels = $state<Label[]>([]);
	filters = $state<SavedFilter[]>([]);
	/** Stored display options per project (server, per account). Missing = defaults. */
	prefs = $state<Record<string, ProjectPrefs>>({});
	/** Device-local: collapsed tree nodes. */
	collapsed = $state<Record<string, boolean>>(readJSON<Record<string, boolean>>(KEYS.collapsed, {}));

	counts = $derived(openCounts(this.tasks));
	inboxCount = $derived(inboxTasks(this.tasks).length);
	todayCount = $derived(todayTasks(this.tasks).length);
	favorites = $derived(favoriteProjects(this.projects));

	#saving = new Map<string, Promise<unknown>>();
	#imported = false;

	async reloadProjects() {
		this.projects = await api.listProjects();
	}
	async reloadTasks() {
		this.tasks = await api.listTasks();
	}
	async reloadTeams() {
		[this.teams, this.invitations] = await Promise.all([api.listTeams(), api.teamInvitations()]);
	}
	async reloadMeta() {
		[this.labels, this.filters] = await Promise.all([collectAll((c) => api.listLabels(c)), collectAll((c) => api.listFilters(c))]);
	}
	async reloadPrefs() {
		const { items } = await api.listProjectPrefs();
		this.prefs = Object.fromEntries(items.map((p) => [p.projectID, p]));
	}
	/** Everything the sidebar shows; failures of the optional parts must not break the app. */
	async reloadAll() {
		await Promise.all([this.reloadProjects(), this.reloadTasks()]);
		await Promise.allSettled([this.reloadTeams(), this.reloadMeta(), this.reloadPrefs()]);
		await this.importLegacy();
	}

	/** Moves values that older PWA versions kept in localStorage to the server, once per start while any remain. */
	async importLegacy() {
		if (this.#imported) return;
		this.#imported = true;
		try {
			if (!hasLegacyState(localStorage)) return;
			const result = await importLegacyState(api, localStorage, this.projects, Object.values(this.prefs));
			if (result.favorites + result.descriptions + result.display > 0) {
				await Promise.allSettled([this.reloadProjects(), this.reloadPrefs()]);
			}
		} catch {
			/* storage unavailable: nothing to import */
		}
	}

	isFavorite = (id: string) => !!this.projects.find((p) => p.id === id)?.isFavorite;
	/** Throws on failure; the caller reports it. */
	async toggleFavorite(id: string) {
		const was = this.isFavorite(id);
		try {
			if (was) await api.deleteFavorite(id);
			else await api.putFavorite(id);
		} finally {
			await this.reloadProjects();
		}
	}

	colorOf = (id: string | null | undefined) => projectColor(id, this.projects.find((p) => p.id === id)?.color);

	displayOf(id: string): Display {
		return prefsToDisplay(this.prefs[id]);
	}
	/**
	 * Optimistic: the UI changes immediately, the PATCH follows. Writes per project run one after another so a quick
	 * second click does not conflict with the first one's revision; a foreign revision conflict is resolved in `savePrefs`.
	 */
	async setDisplay(id: string, changes: Partial<Display>) {
		const change = displayChangeToPrefs(changes);
		this.prefs = { ...this.prefs, [id]: applyPrefsChange(this.prefs[id] ?? defaultPrefs(id), change) };
		const run = async () => {
			const base = this.prefs[id] ?? defaultPrefs(id);
			const saved = await savePrefs(api, base, change);
			// Keep any newer optimistic fields the user changed meanwhile; only adopt the revision.
			this.prefs = { ...this.prefs, [id]: { ...this.prefs[id], revision: saved.revision, updatedAt: saved.updatedAt } };
		};
		const previous = this.#saving.get(id) ?? Promise.resolve();
		const next = previous.catch(() => undefined).then(run);
		this.#saving.set(id, next);
		try {
			await next;
		} catch (e) {
			await this.reloadPrefs().catch(() => undefined);
			throw e;
		}
	}

	toggleCollapsed(id: string) {
		this.collapsed = { ...this.collapsed, [id]: !this.collapsed[id] };
		writeJSON(KEYS.collapsed, this.collapsed);
	}
}

export const workspace = new Workspace();
