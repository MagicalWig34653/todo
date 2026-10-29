import type { Snippet } from 'svelte';
import { KEYS, readJSON, writeJSON } from './localPrefs.js';

/** Cross-component UI state: quick-add dialog, header toolbar slot, sidebar collapse, data change tick. */
class Ui {
	quickAdd = $state(false);
	/** Header toolbar (breadcrumb and actions) contributed by the current page. */
	toolbar = $state.raw<Snippet | null>(null);
	/** Desktop sidebar collapsed (device-local, `todo.sidebarCollapsed`). */
	sidebarCollapsed = $state(readJSON<boolean>(KEYS.sidebar, false));
	/** Bumped when something outside the open page created or changed tasks (quick add), so the page reloads. */
	changeTick = $state(0);

	toggleSidebar() {
		this.sidebarCollapsed = !this.sidebarCollapsed;
		writeJSON(KEYS.sidebar, this.sidebarCollapsed);
	}
}
export const ui = new Ui();
