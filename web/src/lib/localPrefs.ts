/**
 * PROVISIONAL device-local preferences (favorites, project descriptions, collapsed tree nodes).
 * `/v1/me/preferences` is strictly validated and only knows `appearance`, and projects have no description field,
 * so these live in localStorage under the `todo.` prefix until the backend schema is extended. They are not synced.
 */
export function readJSON<T>(key: string, fallback: T): T {
	try {
		const raw = localStorage.getItem(key);
		return raw ? (JSON.parse(raw) as T) : fallback;
	} catch {
		return fallback;
	}
}

export function writeJSON(key: string, value: unknown): void {
	try {
		localStorage.setItem(key, JSON.stringify(value));
	} catch {
		/* storage unavailable: the choice only lasts for this page view */
	}
}

export const KEYS = {
	favorites: 'todo.favorites',
	descriptions: 'todo.projectDescriptions',
	collapsed: 'todo.collapsedProjects',
	sidebar: 'todo.sidebarCollapsed',
	display: 'todo.projectDisplay'
} as const;
