import { ApiError } from './api.js';

/** Phrase the person types to confirm anonymizing their own account (the request itself carries `ANONYMIZE`). */
export const ANONYMIZE_PHRASE = 'ANONYMISIEREN';

export const phraseMatches = (input: string): boolean => input.trim().toUpperCase() === ANONYMIZE_PHRASE;

/** `todolino-export-2026-11-02.json` (local date). */
export function exportFileName(date: Date = new Date()): string {
	const p = (n: number) => String(n).padStart(2, '0');
	return `todolino-export-${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}.json`;
}

async function failure(res: Response): Promise<ApiError> {
	let reason: string | undefined;
	try {
		reason = ((await res.json()) as { reason?: string }).reason;
	} catch {
		/* not JSON */
	}
	return new ApiError(res.status, reason);
}

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;
const browserFetch: FetchFn = (i, init) => fetch(i, init);

/** Locks and anonymizes the signed-in account (POST /v1/me/anonymize, contracts/admin-settings.yaml). */
export async function anonymizeMyAccount(fetchFn: FetchFn = browserFetch): Promise<void> {
	let res: Response;
	try {
		res = await fetchFn('/v1/me/anonymize', {
			method: 'POST',
			credentials: 'same-origin',
			headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
			body: JSON.stringify({ confirm: 'ANONYMIZE' })
		});
	} catch {
		throw new ApiError(0, 'network');
	}
	if (!res.ok) throw await failure(res);
}

/** Fetches the data export (GET /v1/me/export) and returns it as a Blob. */
export async function fetchMyExport(fetchFn: FetchFn = browserFetch): Promise<Blob> {
	let res: Response;
	try {
		res = await fetchFn('/v1/me/export', { credentials: 'same-origin', headers: { Accept: 'application/json' } });
	} catch {
		throw new ApiError(0, 'network');
	}
	if (!res.ok) throw await failure(res);
	return await res.blob();
}

/** Starts a browser download of the export. */
export async function downloadMyExport(): Promise<void> {
	const blob = await fetchMyExport();
	const url = URL.createObjectURL(blob);
	const a = document.createElement('a');
	a.href = url;
	a.download = exportFileName();
	document.body.appendChild(a);
	a.click();
	a.remove();
	setTimeout(() => URL.revokeObjectURL(url), 1000);
}
