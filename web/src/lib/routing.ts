/** Pure URL <-> view mapping for the PWA (stable, shareable paths). */
export type RouteView =
	| 'project' | 'inbox' | 'overview' | 'today' | 'upcoming' | 'upNext' | 'search' | 'filters' | 'teams' | 'agents' | 'activity' | 'account';

export type ProjectSub = 'liste' | 'board' | 'ueberblick' | 'kommentare';

export interface Route {
	view: RouteView | 'notfound';
	projectID?: string;
	sub?: ProjectSub;
	taskID?: string;
	labelID?: string;
	filterID?: string;
	/** `/konto/<bereich>` */
	area?: string;
}

const SIMPLE: Record<string, RouteView> = {
	heute: 'today', eingang: 'inbox', anstehend: 'upcoming', 'als-naechstes': 'upNext', suche: 'search',
	ueberblick: 'overview', aktivitaet: 'activity', agenten: 'agents', teams: 'teams'
};
const PATH_OF: Partial<Record<RouteView, string>> = {
	today: '/heute', inbox: '/eingang', upcoming: '/anstehend', upNext: '/als-naechstes', search: '/suche',
	overview: '/ueberblick', activity: '/aktivitaet', agents: '/agenten', teams: '/teams', filters: '/filter', account: '/konto'
};
const SUBS: ProjectSub[] = ['liste', 'board', 'ueberblick', 'kommentare'];
const ID = /^[A-Za-z0-9-]{8,64}$/;

export function parseRoute(pathname: string, search = ''): Route {
	const seg = pathname.split('/').filter(Boolean).map((s) => { try { return decodeURIComponent(s); } catch { return '\0'; } });
	const q = new URLSearchParams(search);
	const taskParam = q.get('task');
	const taskID = taskParam && ID.test(taskParam) ? taskParam : undefined;
	if (seg.includes('\0')) return { view: 'notfound' };
	if (seg.length === 0) return { view: 'today' };
	const [a, b, c] = seg;
	if (seg.length === 1 && SIMPLE[a]) return { view: SIMPLE[a] };
	if (a === 'projekt' && b && ID.test(b) && seg.length <= 3) {
		if (c && !SUBS.includes(c as ProjectSub)) return { view: 'notfound' };
		return { view: 'project', projectID: b, sub: c as ProjectSub | undefined, taskID };
	}
	if (a === 'aufgabe' && b && ID.test(b) && seg.length === 2) return { view: 'today', taskID: b };
	if (a === 'konto' && seg.length <= 2) return { view: 'account', area: b };
	if (a === 'filter' && seg.length === 1) return { view: 'filters' };
	if (a === 'filter' && b && ID.test(b) && seg.length === 2) return { view: 'search', filterID: b };
	if (a === 'labels' && b && ID.test(b) && seg.length === 2) return { view: 'search', labelID: b };
	return { view: 'notfound' };
}

export function buildPath(r: Route): string {
	let path: string;
	if (r.view === 'project' && r.projectID) path = `/projekt/${encodeURIComponent(r.projectID)}${r.sub ? `/${r.sub}` : ''}`;
	else if (r.view === 'search' && r.filterID) path = `/filter/${encodeURIComponent(r.filterID)}`;
	else if (r.view === 'search' && r.labelID) path = `/labels/${encodeURIComponent(r.labelID)}`;
	else if (r.view === 'account') path = `/konto${r.area ? `/${encodeURIComponent(r.area)}` : ''}`;
	else path = PATH_OF[r.view as RouteView] ?? '/heute';
	return r.taskID ? `${path}?task=${encodeURIComponent(r.taskID)}` : path;
}

export const ROUTE_TITLES: Record<RouteView | 'notfound', string> = {
	project: 'Projekt', inbox: 'Eingang', overview: 'Überblick', today: 'Heute', upcoming: 'Anstehend', upNext: 'Als Nächstes',
	search: 'Suche', filters: 'Filter und Labels', teams: 'Teams', agents: 'Agenten', activity: 'Aktivität', account: 'Konto', notfound: 'Nicht gefunden'
};

/** Same-origin, path-only redirect targets; everything else (absolute URLs, `//host`, backslashes, API paths) falls back. */
export function safeRedirect(target: string | null | undefined, fallback = '/'): string {
	if (!target || !target.startsWith('/') || target.startsWith('//') || target.includes('\\') || /[\u0000-\u001f]/.test(target)) return fallback;
	try {
		const u = new URL(target, 'http://x.invalid');
		if (u.origin !== 'http://x.invalid') return fallback;
		if (/^\/(v1|mcp|oauth|\.well-known|health|docs|openapi)(\/|$)/.test(u.pathname)) return fallback;
		return u.pathname + u.search + u.hash;
	} catch {
		return fallback;
	}
}
