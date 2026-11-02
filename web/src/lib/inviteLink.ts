/**
 * Invitation links: `<origin>/setup#code=<code>`. The code sits in the URL fragment, which browsers never send to the
 * server or in a Referer header, so it cannot leak into access logs. Old links (`/setup?token=`) still work.
 */
const MAX_CODE = 200;

export function buildInviteLink(origin: string, code: string): string {
	return `${origin}/setup#code=${encodeURIComponent(code)}`;
}

function clean(value: string | null): string {
	const v = (value ?? '').trim();
	return v.length > 0 && v.length <= MAX_CODE ? v : '';
}

/** Reads the code from the fragment (preferred) or the legacy `?token=` query. Empty string when absent. */
export function parseInviteCode(search: string, hash: string): string {
	const fromHash = clean(new URLSearchParams(hash.replace(/^#/, '')).get('code'));
	return fromHash || clean(new URLSearchParams(search).get('token'));
}
