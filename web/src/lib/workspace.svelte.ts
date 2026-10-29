import { api, type Label, type Project, type SavedFilter, type Task, type Team, type TeamMembership } from './api.js';
import { inboxTasks, openCounts, todayTasks } from './counts.js';
import { KEYS, readJSON, writeJSON } from './localPrefs.js';
import { collectAll } from './planning.js';

/** Shared client state of the signed-in workspace: projects, all own tasks (for counts), teams, labels, filters. */
class Workspace {
	projects = $state<Project[]>([]);
	tasks = $state<Task[]>([]);
	teams = $state<Team[]>([]);
	invitations = $state<TeamMembership[]>([]);
	labels = $state<Label[]>([]);
	filters = $state<SavedFilter[]>([]);
	/** PROVISIONAL (localStorage): see localPrefs.ts. */
	favorites = $state<string[]>(readJSON<string[]>(KEYS.favorites, []));
	descriptions = $state<Record<string, string>>(readJSON<Record<string, string>>(KEYS.descriptions, {}));
	collapsed = $state<Record<string, boolean>>(readJSON<Record<string, boolean>>(KEYS.collapsed, {}));

	counts = $derived(openCounts(this.tasks));
	inboxCount = $derived(inboxTasks(this.tasks).length);
	todayCount = $derived(todayTasks(this.tasks).length);

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
	/** Everything the sidebar shows; failures of the optional parts must not break the app. */
	async reloadAll() {
		await Promise.all([this.reloadProjects(), this.reloadTasks()]);
		await Promise.allSettled([this.reloadTeams(), this.reloadMeta()]);
	}

	isFavorite = (id: string) => this.favorites.includes(id);
	toggleFavorite(id: string) {
		this.favorites = this.isFavorite(id) ? this.favorites.filter((x) => x !== id) : [...this.favorites, id];
		writeJSON(KEYS.favorites, this.favorites);
	}
	setDescription(id: string, text: string) {
		const next = { ...this.descriptions };
		if (text.trim()) next[id] = text;
		else delete next[id];
		this.descriptions = next;
		writeJSON(KEYS.descriptions, next);
	}
	toggleCollapsed(id: string) {
		this.collapsed = { ...this.collapsed, [id]: !this.collapsed[id] };
		writeJSON(KEYS.collapsed, this.collapsed);
	}
}

export const workspace = new Workspace();
