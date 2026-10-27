import { ApiError } from './api.js';
import { PasskeyError } from './auth.svelte.js';
import { de } from './i18n/de.js';
import { errorMessage, t } from './i18n/index.js';

/** Converts any thrown value into a localized, user-facing message. */
export function describeError(e: unknown): string {
	if (e instanceof PasskeyError) return errorMessage(e.reason);
	if (e instanceof ApiError) {
		if (e.status === 0) return t('error.network');
		if (e.isConflict) return t('conflict.body');
		if (e.status === 404) return t('error.not_found');
		if (e.status === 403) return t('error.forbidden');
		if (e.status === 429) return t('error.too_many_requests');
		if (e.status === 503) return t('error.storage_unavailable');
		if (e.reason?.startsWith('upload_')) {
			const key = `error.${e.reason}`;
			return key in de ? errorMessage(e.reason) : t('error.upload_failed');
		}
		if (e.status === 422 && !(`error.${e.reason}` in de)) return t('error.unprocessable');
		return errorMessage(e.reason);
	}
	return t('error.generic');
}
