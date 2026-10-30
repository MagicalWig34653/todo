import { ApiError, type Api, type Project, type ProjectPrefs, type ProjectPrefsChange } from './api.js';
import { DEFAULT_DISPLAY, type Display } from './listLogic.js';

/** Server prefs use `showCompleted`, the UI model `showDone`. */
export function prefsToDisplay(p: ProjectPrefs | undefined): Display {
	if (!p) return { ...DEFAULT_DISPLAY };
	return { view: p.view, sort: p.sort, grouping: p.grouping, showDone: p.showCompleted };
}

export function displayChangeToPrefs(changes: Partial<Display>): ProjectPrefsChange {
	const out: ProjectPrefsChange = {};
	if (changes.view !== undefined) out.view = changes.view;
	if (changes.sort !== undefined) out.sort = changes.sort;
	if (changes.grouping !== undefined) out.grouping = changes.grouping;
	if (changes.showDone !== undefined) out.showCompleted = changes.showDone;
	return out;
}

/** Applies a change on top of (possibly default) prefs without touching the revision. */
export function applyPrefsChange(base: ProjectPrefs, changes: ProjectPrefsChange): ProjectPrefs {
	return { ...base, ...changes };
}

export function defaultPrefs(projectID: string): ProjectPrefs {
	return { projectID, view: 'list', sort: 'manual', grouping: 'column', showCompleted: true, revision: 0 };
}

/** Favourites in the viewer's order, taken from the project list. */
export function favoriteProjects(projects: Project[]): Project[] {
	return projects
		.filter((p) => p.isFavorite)
		.sort((a, b) => (a.favoritePosition ?? 1e9) - (b.favoritePosition ?? 1e9) || a.id.localeCompare(b.id));
}

/**
 * Writes prefs with optimistic revision handling: on `revision_conflict` the current server state is fetched,
 * the change is re-applied on top of it (the user's latest choice wins per field) and sent once more.
 */
export async function savePrefs(api: Pick<Api, 'patchProjectPrefs' | 'getProjectPrefs'>, current: ProjectPrefs, changes: ProjectPrefsChange): Promise<ProjectPrefs> {
	try {
		return await api.patchProjectPrefs(current.projectID, current.revision, changes);
	} catch (e) {
		if (!(e instanceof ApiError && e.isRevisionConflict)) throw e;
		const fresh = await api.getProjectPrefs(current.projectID);
		return await api.patchProjectPrefs(current.projectID, fresh.revision, changes);
	}
}

// ---- one-time import of the former device-local values ------------------------------------------------------------

export const LEGACY_KEYS = {
	favorites: 'todo.favorites',
	descriptions: 'todo.projectDescriptions',
	display: 'todo.projectDisplay'
} as const;

export interface LegacyStorage {
	getItem(key: string): string | null;
	removeItem(key: string): void;
}

function readLegacy<T>(storage: LegacyStorage, key: string): T | null {
	try {
		const raw = storage.getItem(key);
		return raw ? (JSON.parse(raw) as T) : null;
	} catch {
		return null;
	}
}

export function hasLegacyState(storage: LegacyStorage): boolean {
	try {
		return Object.values(LEGACY_KEYS).some((k) => storage.getItem(k) !== null);
	} catch {
		return false;
	}
}

const isPlainObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** Per-item failures that mean "this value can never be imported" (no rights, project gone, invalid): skip, do not retry. */
const permanent = (e: unknown) => e instanceof ApiError && [400, 403, 404, 422].includes(e.status);

export interface ImportResult {
	favorites: number;
	descriptions: number;
	display: number;
	/** True when everything was handled and the local keys were removed. */
	cleared: boolean;
}

/**
 * Uploads favourites, project descriptions and display options that earlier PWA versions kept in localStorage,
 * then removes the keys. Server state wins: favourites are only imported while the account has none, a description
 * only for projects without one, display options only for projects whose prefs were never written (revision 0).
 * A transient failure (network, 5xx) keeps the keys so the next start retries; permanent per-item failures are skipped.
 */
export async function importLegacyState(
	api: Pick<Api, 'putFavorite' | 'updateProject' | 'patchProjectPrefs'>,
	storage: LegacyStorage,
	projects: Project[],
	storedPrefs: ProjectPrefs[]
): Promise<ImportResult> {
	const result: ImportResult = { favorites: 0, descriptions: 0, display: 0, cleared: false };
	const byID = new Map(projects.map((p) => [p.id, p]));
	const favorites = readLegacy<unknown>(storage, LEGACY_KEYS.favorites);
	const descriptions = readLegacy<unknown>(storage, LEGACY_KEYS.descriptions);
	const display = readLegacy<unknown>(storage, LEGACY_KEYS.display);

	try {
		if (Array.isArray(favorites) && !projects.some((p) => p.isFavorite)) {
			for (const id of favorites) {
				if (typeof id !== 'string' || !byID.has(id)) continue;
				try {
					await api.putFavorite(id);
					result.favorites++;
				} catch (e) {
					if (!permanent(e)) throw e;
				}
			}
		}
		if (isPlainObject(descriptions)) {
			for (const [id, text] of Object.entries(descriptions)) {
				const project = byID.get(id);
				if (!project || typeof text !== 'string' || !text.trim() || project.description) continue;
				try {
					await api.updateProject(project, { description: text.trim().slice(0, 10000) });
					result.descriptions++;
				} catch (e) {
					if (!permanent(e)) throw e;
				}
			}
		}
		if (isPlainObject(display)) {
			const written = new Set(storedPrefs.filter((p) => p.revision > 0).map((p) => p.projectID));
			for (const [id, raw] of Object.entries(display)) {
				if (!byID.has(id) || written.has(id) || !isPlainObject(raw)) continue;
				const change: ProjectPrefsChange = {};
				if (raw.view === 'list' || raw.view === 'board') change.view = raw.view;
				if (['manual', 'title', 'due', 'priority'].includes(raw.sort as string)) change.sort = raw.sort as ProjectPrefs['sort'];
				if (['none', 'column', 'priority', 'due'].includes(raw.grouping as string)) change.grouping = raw.grouping as ProjectPrefs['grouping'];
				if (typeof raw.showDone === 'boolean') change.showCompleted = raw.showDone;
				if (Object.keys(change).length === 0) continue;
				try {
					await api.patchProjectPrefs(id, 0, change);
					result.display++;
				} catch (e) {
					if (!permanent(e) && !(e instanceof ApiError && e.isRevisionConflict)) throw e;
				}
			}
		}
	} catch {
		return result;
	}
	try {
		for (const k of Object.values(LEGACY_KEYS)) storage.removeItem(k);
		result.cleared = true;
	} catch {
		/* storage unavailable */
	}
	return result;
}
