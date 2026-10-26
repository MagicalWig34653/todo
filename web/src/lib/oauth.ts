import type { OAuthGrant, Project } from './api.js';
import { de } from './i18n/de.js';

/** Localized label of an OAuth scope; unknown scopes are shown verbatim. */
export function scopeLabel(scope: string): string {
	const key = `scope.${scope}`;
	return key in de ? de[key as keyof typeof de] : scope;
}

/** Schemes a consent redirect must never navigate to, even if a client registered them. */
const FORBIDDEN_SCHEMES = new Set(['javascript:', 'data:', 'vbscript:', 'file:', 'blob:']);

/** Returns the URL when it is safe to navigate to after consent, otherwise null. */
export function safeRedirect(url: string): string | null {
	try {
		const parsed = new URL(url);
		return FORBIDDEN_SCHEMES.has(parsed.protocol) ? null : parsed.toString();
	} catch {
		return null;
	}
}

/** `host` of an http(s) redirect, or the whole scheme for app redirects; shown so users see where they return to. */
export function redirectTarget(url: string): string {
	try {
		const parsed = new URL(url);
		return parsed.host ? `${parsed.protocol}//${parsed.host}` : parsed.protocol;
	} catch {
		return url;
	}
}

/** Project names for the ids of a grant; ids the user can no longer see are reported separately. */
export function resolveGrantProjects(grant: OAuthGrant, projects: Project[]): { names: string[]; unknown: number } {
	const byID = new Map(projects.map((p) => [p.id, p.name]));
	const names: string[] = [];
	let unknown = 0;
	for (const id of grant.project_ids) {
		const name = byID.get(id);
		if (name === undefined) unknown++;
		else names.push(name);
	}
	return { names, unknown };
}

/** Active grants first (stable otherwise). */
export function sortGrants(grants: OAuthGrant[]): OAuthGrant[] {
	return [...grants].sort((a, b) => Number(a.revoked) - Number(b.revoked));
}
