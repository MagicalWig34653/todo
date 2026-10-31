import type { MessageKey } from './i18n/index.js';

/** Commands and the connection check of the "Claude Code verbinden" help page. */
export const MARKETPLACE_REPO = 'MagicalWig34653/todo';

export const normalizeOrigin = (origin: string) => origin.replace(/\/+$/, '');
export const mcpUrl = (origin: string) => `${normalizeOrigin(origin)}/mcp`;

export function connectCommands(origin: string) {
	return {
		marketplace: `/plugin marketplace add ${MARKETPLACE_REPO}`,
		install: '/plugin install todolino@todolino',
		mcpAdd: `claude mcp add --transport http --scope user todolino ${mcpUrl(origin)}`
	};
}

export type CheckState = 'ok' | 'warn' | 'fail';
export interface CheckResult {
	id: 'resource' | 'capabilities';
	state: CheckState;
	message: MessageKey;
	params?: Record<string, string | number>;
}

type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

async function getJSON(fetchFn: Fetch, url: string): Promise<{ status: number; body: unknown } | null> {
	try {
		const r = await fetchFn(url, { headers: { Accept: 'application/json' }, credentials: 'omit' });
		let body: unknown = null;
		try {
			body = await r.json();
		} catch {
			/* not JSON */
		}
		return { status: r.status, body };
	} catch {
		return null;
	}
}

/**
 * Probes the two public endpoints Claude Code needs: the OAuth resource metadata of the MCP endpoint and the
 * capability document (passkey login). Every result carries a message key that explains the outcome.
 */
export async function checkConnection(fetchFn: Fetch, origin: string): Promise<CheckResult[]> {
	const out: CheckResult[] = [];
	const want = mcpUrl(origin);
	const res = await getJSON(fetchFn, '/.well-known/oauth-protected-resource/mcp');
	if (!res) out.push({ id: 'resource', state: 'fail', message: 'claude.check.resource.network' });
	else if (res.status !== 200) out.push({ id: 'resource', state: 'fail', message: 'claude.check.resource.status', params: { status: res.status } });
	else {
		const resource = typeof (res.body as { resource?: unknown } | null)?.resource === 'string' ? ((res.body as { resource: string }).resource) : '';
		if (!resource) out.push({ id: 'resource', state: 'fail', message: 'claude.check.resource.invalid' });
		else if (!resource.endsWith('/mcp')) out.push({ id: 'resource', state: 'fail', message: 'claude.check.resource.noMcp', params: { resource } });
		else if (resource !== want) out.push({ id: 'resource', state: 'warn', message: 'claude.check.resource.mismatch', params: { resource, expected: want } });
		else out.push({ id: 'resource', state: 'ok', message: 'claude.check.resource.ok', params: { resource } });
	}
	const caps = await getJSON(fetchFn, '/v1/capabilities');
	if (!caps) out.push({ id: 'capabilities', state: 'fail', message: 'claude.check.caps.network' });
	else if (caps.status !== 200) out.push({ id: 'capabilities', state: 'fail', message: 'claude.check.caps.status', params: { status: caps.status } });
	else if ((caps.body as { passkey?: unknown } | null)?.passkey === true) out.push({ id: 'capabilities', state: 'ok', message: 'claude.check.caps.ok' });
	else out.push({ id: 'capabilities', state: 'warn', message: 'claude.check.caps.nopasskey' });
	return out;
}
