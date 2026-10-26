import { ApiError } from './api.js';
import { PasskeyError } from './auth.svelte.js';
import { errorMessage, t } from './i18n/index.js';

/** Converts any thrown value into a localized, user-facing message. */
export function describeError(e: unknown): string {
	if (e instanceof PasskeyError) return errorMessage(e.reason);
	if (e instanceof ApiError) {
		if (e.status === 0) return t('error.network');
		if (e.isConflict) return t('conflict.body');
		if (e.status === 404) return t('error.not_found');
		return errorMessage(e.reason);
	}
	return t('error.generic');
}
