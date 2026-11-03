import type { OAuthGrant, Project, ProjectConnection, Role } from './api.js';
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

/** Whether a grant may be saved with an empty project list (only connections that may create projects). */
export function mayBeEmpty(grant: OAuthGrant): boolean {
	return grant.scopes.includes('projects:write');
}

/** Ids to send: the checked ones; ids the user cannot see any more are dropped (least privilege). */
export function nextGrantProjects(selected: Set<string>, projects: Project[]): string[] {
	return projects.filter((p) => selected.has(p.id)).map((p) => p.id);
}

export interface ConnectionAccess {
	grant: OAuthGrant;
	/** The connection may reach this project. */
	allowed: boolean;
}

/** Name shown for a connection: the name the person gave, else the registered client name, else a short id. */
export function connectionName(grant: OAuthGrant): string {
	return grant.name?.trim() || grant.client_name?.trim() || grant.client_id.slice(0, 8);
}

/** The caller's active connections with whether each reaches `projectID`; allowed ones first, then by name. */
export function connectionsForProject(grants: OAuthGrant[], projectID: string): ConnectionAccess[] {
	return grants
		.filter((g) => !g.revoked)
		.map((grant) => ({ grant, allowed: grant.project_ids.includes(projectID) }))
		.sort((a, b) => Number(b.allowed) - Number(a.allowed) || connectionName(a.grant).localeCompare(connectionName(b.grant), 'de'));
}

/** New project list of a connection after switching one project on or off (order kept, no duplicates). */
export function projectsWith(grant: OAuthGrant, projectID: string, allowed: boolean): string[] {
	const rest = grant.project_ids.filter((id) => id !== projectID);
	return allowed ? [...rest, projectID] : rest;
}

/** Switching `projectID` off would leave a connection without projects, which only projects:write connections may have. */
export function wouldLeaveEmpty(grant: OAuthGrant, projectID: string): boolean {
	return !mayBeEmpty(grant) && grant.project_ids.every((id) => id === projectID);
}

/** The viewer's own connections that reach `projectID`, shaped like the participants list (used when the viewer cannot list others'). */
export function connectionRows(grants: OAuthGrant[], projectID: string, role?: Role | null): ProjectConnection[] {
	return connectionsForProject(grants, projectID)
		.filter((c) => c.allowed)
		.map((c) => ({ grantID: c.grant.id, name: connectionName(c.grant), clientName: c.grant.client_name ?? null, ownerID: '', ownerName: null, isOwn: true, role: role ?? null, scopes: c.grant.scopes, lastUsedAt: c.grant.last_used_at ?? null }));
}
