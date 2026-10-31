import { api, type ProjectMode, type ProjectPrefsChange, type CommandSummary, type Label, type Project, type ProjectPrefs, type SavedFilter, type Task, type Team, type TeamMembership } from './api.js';
import { attentionCount } from './commandCenter.js';
import { inboxTasks, openCounts, todayTasks } from './counts.js';
import type { Display } from './listLogic.js';
import { KEYS, readJSON, writeJSON } from './localPrefs.js';
import { collectAll } from './planning.js';
import { sameList } from './liveRefresh.js';
import { projectColor } from './boardLogic.js';
import { descendantIDs, modeOfPrefs, MAX_APPLY_SUBPROJECTS, defaultPrefs, displayChangeToPrefs, favoriteProjects, hasLegacyState, importLegacyState, prefsToDisplay, applyPrefsChange, savePrefs } from './projectState.js';

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
	/** Account-wide command center counters (open questions, pending reviews) for the sidebar badge. */
	attention = $state<CommandSummary | null>(null);
	/** Device-local: collapsed tree nodes. */
	collapsed = $state<Record<string, boolean>>(readJSON<Record<string, boolean>>(KEYS.collapsed, {}));

	counts = $derived(openCounts(this.tasks));
	inboxCount = $derived(inboxTasks(this.tasks).length);
	todayCount = $derived(todayTasks(this.tasks).length);
	favorites = $derived(favoriteProjects(this.projects));
	attentionCount = $derived(attentionCount(this.attention));

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
	/** Cheap list-view call: only the summary is used. Failures are ignored (the badge just stays stale). */
	async reloadAttention() {
		try {
			this.attention = (await api.commandCenter({ scope: 'account', view: 'list', limit: 1, updatesLimit: 1 })).summary;
		} catch {
			/* optional */
		}
	}
	/**
	 * Silent live refresh of everything the sidebar and the list views show. Each part is only assigned when it changed,
	 * so unchanged data causes no re-render; failures keep the cached values.
	 */
	async refreshLive() {
		const was = { p: this.projects, t: this.tasks, m: this.teams, i: this.invitations };
		const [projects, tasks, teams, summary] = await Promise.allSettled([
			api.listProjects(),
			api.listTasks(),
			Promise.all([api.listTeams(), api.teamInvitations()]),
			api.commandCenter({ scope: 'account', view: 'list', limit: 1, updatesLimit: 1 })
		]);
		if (projects.status === 'fulfilled' && this.projects === was.p && !sameList(this.projects, projects.value)) this.projects = projects.value;
		if (tasks.status === 'fulfilled' && this.tasks === was.t && !sameList(this.tasks, tasks.value)) this.tasks = tasks.value;
		if (teams.status === 'fulfilled' && this.teams === was.m && this.invitations === was.i) {
			if (!sameList(this.teams, teams.value[0])) this.teams = teams.value[0];
			if (!sameList(this.invitations, teams.value[1])) this.invitations = teams.value[1];
		}
		if (summary.status === 'fulfilled' && JSON.stringify(this.attention) !== JSON.stringify(summary.value.summary)) this.attention = summary.value.summary;
		await this.refreshPrefsIfChanged();
	}
	private async refreshPrefsIfChanged() {
		if (this.#inflight > 0) return;
		try {
			const { items } = await api.listProjectPrefs(true);
			if (this.#inflight > 0) return;
			const next = Object.fromEntries(items.map((p) => [p.projectID, p]));
			if (JSON.stringify(next) !== JSON.stringify(this.prefs)) this.prefs = next;
		} catch {
			/* keep the cached prefs */
		}
	}
	/** Re-reads prefs (derived modes change when agents/bindings appear) unless a local write is still in flight. */
	async refreshPrefs() {
		if (this.#inflight > 0) return;
		try {
			await this.reloadPrefs();
		} catch {
			/* keep the cached prefs */
		}
	}
	async reloadPrefs() {
		const { items } = await api.listProjectPrefs(true);
		this.prefs = Object.fromEntries(items.map((p) => [p.projectID, p]));
		this.prefsLoaded = true;
	}
	/** Everything the sidebar shows; failures of the optional parts must not break the app. */
	async reloadAll() {
		await Promise.all([this.reloadProjects(), this.reloadTasks()]);
		await Promise.allSettled([this.reloadTeams(), this.reloadMeta(), this.reloadPrefs(), this.reloadAttention()]);
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
	setDisplay(id: string, changes: Partial<Display>) {
		return this.setPrefs(id, displayChangeToPrefs(changes));
	}
	/** Classic (plain todo list/board) or management (overview, agents, sync) view of a project for this account. */
	/** False until the first prefs load; until then nothing is hidden (a failed load must not hide agent work). */
	prefsLoaded = $state(false);
	modeOf = (id: string | null | undefined): ProjectMode => (id && this.prefsLoaded ? modeOfPrefs(this.prefs[id]) : 'management');
	setMode(id: string, mode: ProjectMode) {
		return this.setPrefs(id, { mode });
	}
	/** Sub-projects the mode switch can be applied to in one go; `null` when the tree is too large. */
	subprojectsForMode(id: string): string[] | null {
		const ids = descendantIDs(this.projects, id);
		return ids.length <= MAX_APPLY_SUBPROJECTS ? ids : null;
	}
	async setModeWithSubprojects(id: string, mode: ProjectMode) {
		const ids = this.subprojectsForMode(id);
		if (!ids) throw new Error('too_many_subprojects');
		for (const pid of [id, ...ids]) await this.setMode(pid, mode);
	}
	#inflight = 0;
	async setPrefs(id: string, change: ProjectPrefsChange) {
		this.prefs = { ...this.prefs, [id]: applyPrefsChange(this.prefs[id] ?? defaultPrefs(id), change) };
		const run = async () => {
			const base = this.prefs[id] ?? defaultPrefs(id);
			const saved = await savePrefs(api, base, change);
			// Keep any newer optimistic fields the user changed meanwhile; only adopt the revision.
			this.prefs = { ...this.prefs, [id]: { ...this.prefs[id], revision: saved.revision, updatedAt: saved.updatedAt } };
		};
		const previous = this.#saving.get(id) ?? Promise.resolve();
		this.#inflight++;
		const next = previous.catch(() => undefined).then(run).finally(() => this.#inflight--);
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
