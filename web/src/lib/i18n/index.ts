import { de, type MessageKey } from './de.js';

export type { MessageKey };

/** Looks up a UI string and substitutes `{name}` placeholders. */
export function t(key: MessageKey, params?: Record<string, string | number>): string {
	let text: string = de[key];
	if (params) {
		for (const [name, value] of Object.entries(params)) {
			text = text.replaceAll(`{${name}}`, String(value));
		}
	}
	return text;
}

/** Maps a backend `reason` code to a localized message, falling back to a generic one. */
export function errorMessage(reason: string | undefined): string {
	const key = `error.${reason}` as MessageKey;
	return reason && key in de ? de[key] : de['error.generic'];
}
