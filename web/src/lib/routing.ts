/** Pure URL <-> view mapping for the PWA (stable, shareable paths). */
import { normalizeHelpArea, helpPath } from './helpNav.js';
import { normalizeArea, settingsPath } from './settingsNav.js';
import { buildCardParam, parseCardParam, type CardRef } from './cardRef.js';

export type RouteView =
	| 'project' | 'forYou' | 'inbox' | 'overview' | 'today' | 'upcoming' | 'upNext' | 'search' | 'filters' | 'teams' | 'agents' | 'activity' | 'account' | 'help';

export type ProjectSub = 'list' | 'board' | 'overview' | 'comments' | 'graph';

export interface Route {
	view: RouteView | 'notfound';
	projectID?: string;
	sub?: ProjectSub;
	taskID?: string;
	/** `?card=<type>:<id>`: the large detail window opened over the view. */
	card?: CardRef;
	/** `?card=` was present but is not a valid reference. */
	cardInvalid?: boolean;
	labelID?: string;
	filterID?: string;
	/** `/settings/<slug>` (account) or `/help/<slug>` (help); holds the internal id. */
	area?: string;
}

const SIMPLE: Record<string, RouteView> = {
	'for-you': 'forYou', today: 'today', inbox: 'inbox', upcoming: 'upcoming', 'up-next': 'upNext', search: 'search',
	overview: 'overview', activity: 'activity', agents: 'agents', teams: 'teams'
};
/** Old German paths: still understood, the app replaces the URL with the English one (bookmarks, mail links, app deep links). */
const LEGACY_SIMPLE: Record<string, RouteView> = {
	'fuer-dich': 'forYou', heute: 'today', eingang: 'inbox', anstehend: 'upcoming', 'als-naechstes': 'upNext', suche: 'search',
	ueberblick: 'overview', aktivitaet: 'activity', agenten: 'agents'
};
const PATH_OF: Partial<Record<RouteView, string>> = {
	forYou: '/for-you', today: '/today', inbox: '/inbox', upcoming: '/upcoming', upNext: '/up-next', search: '/search',
	overview: '/overview', activity: '/activity', agents: '/agents', teams: '/teams', filters: '/filter', account: '/settings', help: '/help'
};
const SUBS: ProjectSub[] = ['list', 'board', 'overview', 'comments', 'graph'];
const LEGACY_SUBS: Record<string, ProjectSub> = { liste: 'list', ueberblick: 'overview', kommentare: 'comments' };
const ID = /^[A-Za-z0-9-]{8,64}$/;

export function parseRoute(pathname: string, search = ''): Route {
	const seg = pathname.split('/').filter(Boolean).map((s) => { try { return decodeURIComponent(s); } catch { return '\0'; } });
	const q = new URLSearchParams(search);
	const taskParam = q.get('task');
	const taskID = taskParam && ID.test(taskParam) ? taskParam : undefined;
	if (seg.includes('\0')) return { view: 'notfound' };
	const cardParam = q.get('card');
	const card = parseCardParam(cardParam);
	const withCard = (r: Route): Route => (cardParam === null ? r : card ? { ...r, card } : { ...r, cardInvalid: true });
	return withCard(parseSegments(seg, taskID));
}

function parseSegments(seg: string[], taskID: string | undefined): Route {
	if (seg.length === 0) return { view: 'forYou' };
	const [a, b, c] = seg;
	if (seg.length === 1 && (SIMPLE[a] || LEGACY_SIMPLE[a])) return { view: SIMPLE[a] ?? LEGACY_SIMPLE[a] };
	if ((a === 'project' || a === 'projekt') && b && ID.test(b) && seg.length <= 3) {
		const sub = c ? (LEGACY_SUBS[c] ?? (SUBS.includes(c as ProjectSub) ? (c as ProjectSub) : undefined)) : undefined;
		if (c && !sub) return { view: 'notfound' };
		return { view: 'project', projectID: b, sub, taskID };
	}
	if ((a === 'task' || a === 'aufgabe') && b && ID.test(b) && seg.length === 2) return { view: 'today', taskID: b };
	// `/konto/...` is the old path of the settings hub; the normalised area makes the app replace the URL (redirect).
	if ((a === 'settings' || a === 'einstellungen' || a === 'konto') && seg.length <= 2) return { view: 'account', area: normalizeArea(b) };
	if ((a === 'help' || a === 'hilfe') && seg.length <= 2) return { view: 'help', area: normalizeHelpArea(b) };
	if (a === 'filter' && seg.length === 1) return { view: 'filters' };
	if (a === 'filter' && b && ID.test(b) && seg.length === 2) return { view: 'search', filterID: b };
	if (a === 'labels' && b && ID.test(b) && seg.length === 2) return { view: 'search', labelID: b };
	return { view: 'notfound' };
}

export function buildPath(r: Route): string {
	let path: string;
	if (r.view === 'project' && r.projectID) path = `/project/${encodeURIComponent(r.projectID)}${r.sub ? `/${r.sub}` : ''}`;
	else if (r.view === 'search' && r.filterID) path = `/filter/${encodeURIComponent(r.filterID)}`;
	else if (r.view === 'search' && r.labelID) path = `/labels/${encodeURIComponent(r.labelID)}`;
	else if (r.view === 'account') path = settingsPath(r.area);
	else if (r.view === 'help') path = helpPath(r.area);
	else path = PATH_OF[r.view as RouteView] ?? '/today';
	const params = [r.taskID ? `task=${encodeURIComponent(r.taskID)}` : '', r.card ? `card=${buildCardParam(r.card)}` : ''].filter(Boolean);
	return params.length ? `${path}?${params.join('&')}` : path;
}

export const ROUTE_TITLES: Record<RouteView | 'notfound', string> = {
	project: 'Projekt', forYou: 'Für dich', inbox: 'Eingang', overview: 'Überblick', today: 'Heute', upcoming: 'Anstehend', upNext: 'Als Nächstes',
	search: 'Suche', filters: 'Filter und Labels', teams: 'Teams', agents: 'Agenten', activity: 'Aktivität', account: 'Einstellungen', help: 'Hilfe', notfound: 'Nicht gefunden'
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

/** Target from `?redirect=<path>` on the login page; only same-origin paths survive `safeRedirect`, otherwise null (stay on the URL). */
export function loginRedirectTarget(search: string): string | null {
	const raw = new URLSearchParams(search).get('redirect');
	if (!raw) return null;
	const target = safeRedirect(raw, '');
	return target === '' || target === '/' ? null : target;
}

/**
 * Return target from `?next=` after login: only the OAuth authorization endpoint of this origin
 * (`/oauth/authorize` with its query, exactly as given); anything else yields null.
 */
export function oauthNextTarget(search: string): string | null {
	const raw = new URLSearchParams(search).get('next');
	if (!raw || raw.length > 4000 || raw.includes('\\') || /[^\x21-\x7e]/.test(raw)) return null;
	if (raw !== '/oauth/authorize' && !raw.startsWith('/oauth/authorize?')) return null;
	return raw;
}
