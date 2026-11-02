import { buildPath, type Route } from './routing.js';

/**
 * In-app navigation for components that have no callback into the workspace shell: pushes a history entry and
 * lets the shell's popstate handler apply the route (project pages and `?task=<id>` opens included).
 */
export function navigate(route: Route): void {
	const path = buildPath(route);
	if (path === location.pathname + location.search) return;
	history.pushState(null, '', path);
	window.dispatchEvent(new PopStateEvent('popstate'));
}

export const openProjectRoute = (projectID: string) => navigate({ view: 'project', projectID });
export const openTaskRoute = (projectID: string, taskID: string) => navigate({ view: 'project', projectID, taskID });
