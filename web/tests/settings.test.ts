import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de.js';
import { buildPath, parseRoute } from '../src/lib/routing.js';
import { findEntry, LEGACY_AREAS, normalizeArea, searchSettings, SETTINGS_GROUPS, settingsPath, visibleGroups } from '../src/lib/settingsNav.js';
import { findHelpPage, HELP_PAGES, helpPath } from '../src/lib/helpNav.js';
import { checkConnection, connectCommands, mcpUrl } from '../src/lib/claudeConnect.js';
import { parseMarkdown } from '../src/lib/miniMarkdown.js';

describe('settings navigation', () => {
	const entries = SETTINGS_GROUPS.flatMap((g) => g.entries);
	it('has unique ids, a label and a description (existing message keys) per entry', () => {
		expect(new Set(entries.map((e) => e.id)).size).toBe(entries.length);
		for (const g of SETTINGS_GROUPS) expect(de[g.label], g.id).toBeTruthy();
		for (const e of entries) {
			expect(de[e.label], e.id).toBeTruthy();
			expect(de[e.description], e.id).toMatch(/\S/);
		}
	});
	it('covers the planned groups', () => {
		expect(SETTINGS_GROUPS.map((g) => g.id)).toEqual(['profile', 'security', 'appearance', 'notify', 'access', 'connected', 'data', 'admin']);
		expect(SETTINGS_GROUPS.find((g) => g.id === 'security')!.entries.map((e) => e.id)).toEqual(['passkeys', 'wiederherstellung', 'sitzungen']);
	});
	it('hides the admin group from non-admins', () => {
		expect(visibleGroups(false).some((g) => g.id === 'admin')).toBe(false);
		expect(visibleGroups(false).flatMap((g) => g.entries).every((e) => !e.adminOnly)).toBe(true);
		expect(visibleGroups(true).some((g) => g.id === 'admin')).toBe(true);
		for (const e of SETTINGS_GROUPS.find((g) => g.id === 'admin')!.entries) expect(e.adminOnly).toBe(true);
	});
	it('finds entries and builds paths', () => {
		expect(findEntry('passkeys')?.label).toBe('settings.passkeys');
		expect(findEntry('nix')).toBeUndefined();
		expect(settingsPath()).toBe('/einstellungen');
		expect(settingsPath('email')).toBe('/einstellungen/email');
	});
	it('searches titles and keywords', () => {
		const t = (k: keyof typeof de) => de[k];
		expect(searchSettings(visibleGroups(false), 'apns', t).map((e) => e.id)).toEqual(['benachrichtigungen']);
		expect(searchSettings(visibleGroups(false), 'smtp', t)).toEqual([]);
		expect(searchSettings(visibleGroups(true), 'smtp', t).map((e) => e.id)).toEqual(['verwaltung-mail']);
		expect(searchSettings(visibleGroups(true), '  ', t)).toEqual([]);
	});
});

describe('redirect mapping of old paths', () => {
	it('/konto and /konto/<x> become /einstellungen[/<x>]', () => {
		const redirect = (p: string) => buildPath(parseRoute(p));
		expect(redirect('/konto')).toBe('/einstellungen');
		expect(redirect('/konto/berechtigungen')).toBe('/einstellungen/berechtigungen');
		expect(redirect('/konto/verwaltung')).toBe('/einstellungen/verwaltung-konten');
		expect(redirect('/konto/passkeys')).toBe('/einstellungen/passkeys');
		expect(redirect('/einstellungen/email')).toBe('/einstellungen/email');
	});
	it('every legacy alias points at a real entry', () => {
		for (const target of Object.values(LEGACY_AREAS)) expect(findEntry(target), target).toBeDefined();
		expect(normalizeArea(undefined)).toBeUndefined();
	});
	it('help routes round-trip', () => {
		expect(parseRoute('/hilfe')).toEqual({ view: 'help', area: undefined });
		expect(parseRoute('/hilfe/claude-code').area).toBe('claude-code');
		expect(buildPath({ view: 'help', area: 'ueber' })).toBe('/hilfe/ueber');
		expect(parseRoute('/hilfe/a/b').view).toBe('notfound');
	});
});

describe('help navigation', () => {
	it('lists the five pages with texts', () => {
		expect(HELP_PAGES.map((p) => p.id)).toEqual(['erste-schritte', 'tastaturkuerzel', 'claude-code', 'agentenhandbuch', 'ueber']);
		for (const p of HELP_PAGES) expect(de[p.description]).toMatch(/\S/);
		expect(findHelpPage('claude-code')?.label).toBe('help.claude');
		expect(helpPath('ueber')).toBe('/hilfe/ueber');
	});
});

describe('Claude Code connection', () => {
	it('builds the commands from the origin', () => {
		const c = connectCommands('https://todo.example.org/');
		expect(c.marketplace).toBe('/plugin marketplace add MagicalWig34653/todo');
		expect(c.install).toBe('/plugin install todolino@todolino');
		expect(c.mcpAdd).toBe('claude mcp add --transport http --scope user todolino https://todo.example.org/mcp');
		expect(mcpUrl('http://localhost:25173')).toBe('http://localhost:25173/mcp');
	});
	const reply = (map: Record<string, { status: number; body?: unknown } | 'throw'>) => async (url: string) => {
		const r = map[url];
		if (!r || r === 'throw') throw new Error('network');
		return new Response(r.body === undefined ? null : JSON.stringify(r.body), { status: r.status });
	};
	const O = 'https://todo.example.org';
	it('reports a healthy server', async () => {
		const res = await checkConnection(reply({ '/.well-known/oauth-protected-resource/mcp': { status: 200, body: { resource: `${O}/mcp` } }, '/v1/capabilities': { status: 200, body: { passkey: true } } }), O);
		expect(res.map((r) => r.state)).toEqual(['ok', 'ok']);
	});
	it('explains a missing /mcp suffix, a mismatch and failures', async () => {
		const caps = { status: 200, body: { passkey: true } };
		const r1 = await checkConnection(reply({ '/.well-known/oauth-protected-resource/mcp': { status: 200, body: { resource: O } }, '/v1/capabilities': caps }), O);
		expect(r1[0]).toMatchObject({ state: 'fail', message: 'claude.check.resource.noMcp' });
		const r2 = await checkConnection(reply({ '/.well-known/oauth-protected-resource/mcp': { status: 200, body: { resource: 'https://other.example/mcp' } }, '/v1/capabilities': caps }), O);
		expect(r2[0]).toMatchObject({ state: 'warn', message: 'claude.check.resource.mismatch' });
		const r3 = await checkConnection(reply({ '/.well-known/oauth-protected-resource/mcp': { status: 404 }, '/v1/capabilities': 'throw' }), O);
		expect(r3.map((r) => r.state)).toEqual(['fail', 'fail']);
		expect(r3[0]!.params).toEqual({ status: 404 });
	});
});

describe('mini markdown', () => {
	it('parses headings, lists, code and inline code without HTML', () => {
		const b = parseMarkdown('# Titel\n\nText mit `code` und **fett**.\nzweite Zeile\n\n- eins\n- zwei\n\n```\n<b>x</b>\n```\n');
		expect(b.map((x) => x.kind)).toEqual(['heading', 'paragraph', 'list', 'code']);
		expect(b[1]).toMatchObject({ inline: [{ kind: 'text', text: 'Text mit ' }, { kind: 'code', text: 'code' }, { kind: 'text', text: ' und ' }, { kind: 'strong', text: 'fett' }, { kind: 'text', text: '.  zweite Zeile'.replace('  ', ' ') }] });
		expect(b[3]).toEqual({ kind: 'code', text: '<b>x</b>' });
	});
});
