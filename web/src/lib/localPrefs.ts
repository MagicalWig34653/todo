/**
 * Device-local UI state only (collapsed tree nodes, sidebar). Favourites, descriptions, colours, order and display
 * options live on the server (ADR 0012); `projectState.ts` imports the old `todo.*` values once.
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
	collapsed: 'todo.collapsedProjects',
	sidebar: 'todo.sidebarCollapsed'
} as const;
