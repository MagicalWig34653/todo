import { can, roleOf } from './access.js';
import { api, type Project, type ProjectGrant } from './api.js';

/** Upper bound of per-project grant requests for overviews (grants are only readable with the manage role, one call per project). */
export const MAX_GRANT_LOOKUPS = 40;

/** Direct grants of every project the viewer may manage; unreadable or failing projects are skipped. */
export async function loadManagedGrants(projects: Project[], limit = MAX_GRANT_LOOKUPS): Promise<Map<string, ProjectGrant[]>> {
	const managed = projects.filter((p) => can(roleOf(p), 'share')).slice(0, limit);
	const out = new Map<string, ProjectGrant[]>();
	await Promise.all(
		managed.map(async (p) => {
			try {
				out.set(p.id, await api.listGrants(p.id));
			} catch {
				/* no longer readable: skip */
			}
		})
	);
	return out;
}

/** Projects that were shared with `teamID`, either by a grant or because the team owns them. */
export function projectsOfTeam(projects: Project[], grants: Map<string, ProjectGrant[]>, teamID: string): { project: Project; via: 'owner' | 'grant'; role?: ProjectGrant['role'] }[] {
	const out: { project: Project; via: 'owner' | 'grant'; role?: ProjectGrant['role'] }[] = [];
	for (const p of projects) {
		if (p.ownerType === 'team' && p.ownerID === teamID) {
			out.push({ project: p, via: 'owner' });
			continue;
		}
		const g = grants.get(p.id)?.find((x) => x.principalType === 'team' && x.principalID === teamID);
		if (g) out.push({ project: p, via: 'grant', role: g.role });
	}
	return out;
}

/** Projects I own that are shared with someone: who has direct access. */
export function sharedByMe(projects: Project[], grants: Map<string, ProjectGrant[]>): { project: Project; grants: ProjectGrant[] }[] {
	return projects
		.filter((p) => p.isOwner !== false)
		.map((project) => ({ project, grants: grants.get(project.id) ?? [] }))
		.filter((x) => x.grants.length > 0);
}
