import { ApiError } from './api.js';
import { auth } from './auth.svelte.js';
import { describeError } from './errors.js';

class Notice {
	text = $state<string | null>(null);
	conflict = $state(false);

	clear() {
		this.text = null;
		this.conflict = false;
	}
}

export const notice = new Notice();

/**
 * Runs a user action and turns failures into a visible notice.
 * On a version conflict `refresh` reloads the current server state so the user sees what changed.
 * Returns true when the action succeeded.
 */
export async function attempt(action: () => Promise<unknown>, refresh?: () => Promise<unknown>): Promise<boolean> {
	notice.clear();
	try {
		await action();
		return true;
	} catch (e) {
		if (e instanceof ApiError && e.isUnauthorized) {
			auth.user = null;
			return false;
		}
		notice.text = describeError(e);
		if (e instanceof ApiError && e.isConflict) {
			notice.conflict = true;
			try {
				await refresh?.();
			} catch {
				/* the notice already tells the user to reload */
			}
		}
		return false;
	}
}
