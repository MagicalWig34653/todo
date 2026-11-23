import { describe, expect, it } from 'vitest';
import { ApiError, createApi, type FetchLike, type Project } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import {
	AUTO_DISABLE_FAILURES,
	MAX_EXCLUSIONS,
	WEBHOOK_KINDS,
	deliveryErrorText,
	deliveryRow,
	descendantIDs,
	exclusionsChanged,
	orderedProjects,
	prefillExclusions,
	safeMask,
	secretInput,
	testOutcome,
	toggleExclusion,
	urlInput,
	webhookErrorKey,
	webhookStatus,
	type WebhookDelivery,
	type WebhookSettings
} from '../src/lib/webhook';
import { findEntry, normalizeArea, searchSettings, settingsPath, visibleGroups } from '../src/lib/settingsNav';
import { t } from '../src/lib/i18n/index';

const project = (id: string, name: string, parentID: string | null = null, extra: Partial<Project> = {}): Project => ({ id, name, parentID, version: 1, ...extra });
const delivery = (over: Partial<WebhookDelivery> = {}): WebhookDelivery => ({
	id: 'D1', event: 'person_action', state: 'sent', attempts: 1, httpStatus: 200, errorCode: null, anzahl: 3,
	kinds: ['question.answered', 'task.created'], createdAt: '2026-11-23T10:00:00Z', finishedAt: '2026-11-23T10:01:00Z', nextAttemptAt: null, ...over
});
const settings = (over: Partial<WebhookSettings> = {}): WebhookSettings => ({
	configured: true, maskedURL: 'https://example.com/…', enabled: true, signingConfigured: false, excludedProjectIDs: [], consecutiveFailures: 0, ...over
});

describe('API errors become clear German texts', () => {
	const text = (status: number, reason?: string) => t(webhookErrorKey(new ApiError(status, reason)));

	it('translates every code of contracts/webhook.yaml', () => {
		expect(text(400, 'webhook_url_not_https')).toBe('Nur https-Adressen sind erlaubt.');
		expect(text(400, 'webhook_url_invalid')).toContain('keine gültige Adresse');
		expect(text(400, 'webhook_url_blocked')).toBe('Diese Adresse ist nicht erlaubt oder der Name lässt sich nicht auflösen (private oder lokale Ziele werden nicht aufgerufen).');
		expect(text(400, 'webhook_signing_secret_invalid')).toContain('16 bis 256');
		expect(text(400, 'webhook_exclusions_invalid')).toContain('500');
		expect(text(404)).toContain('Projekt');
		expect(text(409, 'encryption_key_missing')).toBe('Der Server hat keinen Verschlüsselungsschlüssel (Administrator).');
		expect(text(409, 'webhook_not_configured')).toContain('Zuerst eine Adresse');
		expect(text(429, 'rate_limited')).toContain('10 Sekunden');
		expect(text(401)).toContain('Sitzung');
		expect(text(0, 'network')).toBe(de['error.network']);
	});
	it('falls back to the generic text for anything else and never uses the raw message', () => {
		expect(text(500)).toBe(de['error.generic']);
		expect(text(400, 'something_new')).toBe(de['error.generic']);
		expect(t(webhookErrorKey(new Error('boom')))).toBe(de['error.generic']);
		expect(t(webhookErrorKey('https://hooks.example.com/SECRET-PATH'))).toBe(de['error.generic']);
	});
	it('never repeats a URL that a faulty server put into the reason', () => {
		const leaky = new ApiError(400, 'bad https://hooks.example.com/SECRET-PATH');
		expect(t(webhookErrorKey(leaky))).not.toContain('SECRET');
		expect(leaky.message).toContain('SECRET'); // the raw message exists but is never what the page shows
	});
});

describe('delivery error codes', () => {
	it('translates the short codes of the protocol', () => {
		expect(deliveryErrorText('timeout')).toContain('Zeitüberschreitung');
		expect(deliveryErrorText('network_error')).toContain('Netzwerk');
		expect(deliveryErrorText('tls_error')).toContain('Zertifikat');
		expect(deliveryErrorText('dns_error')).toContain('Namensauflösung');
		expect(deliveryErrorText('redirect_not_followed')).toContain('Weiterleitung');
		expect(deliveryErrorText('target_blocked')).toContain('nicht erlaubt');
		expect(deliveryErrorText('webhook_url_invalid')).toContain('Adresse');
		expect(deliveryErrorText('webhook_url_not_https')).toContain('https');
		expect(deliveryErrorText('webhook_disabled')).toContain('ausgeschaltet');
		expect(deliveryErrorText('encryption_key_missing')).toContain('Verschlüsselungsschlüssel');
		expect(deliveryErrorText('encryption_key_unreadable')).toContain('Verschlüsselungsschlüssel');
		expect(deliveryErrorText('http_unexpected')).toContain('Antwort');
	});
	it('explains http_<status> with the number', () => {
		expect(deliveryErrorText('http_404')).toBe('Der Empfänger antwortete mit HTTP 404.');
		expect(deliveryErrorText('http_503')).toContain('503');
	});
	it('does not echo unknown or hostile codes', () => {
		for (const code of ['<img src=x onerror=alert(1)>', 'https://hooks.example.com/abc', 'http_<script>', 'x'.repeat(200), 'HTTP_404']) {
			const out = deliveryErrorText(code);
			expect(out).toBe(de['webhook.error.unknownCode']);
			expect(out).not.toContain('<');
			expect(out).not.toContain('hooks.example');
		}
		expect(deliveryErrorText(null)).toBe('');
		expect(deliveryErrorText(undefined)).toBe('');
	});
});

describe('protocol rows', () => {
	it('shows a delivered bundle with count, kinds in German, attempts and HTTP status', () => {
		const r = deliveryRow(delivery());
		expect(r.tone).toBe('success');
		expect(r.stateLabel).toBe('Zugestellt');
		expect(r.eventLabel).toBe('Aktionen von dir');
		expect(r.countLabel).toBe('3 Aktionen');
		expect(r.kindLabels).toEqual(['Frage beantwortet', 'Aufgabe angelegt']);
		expect(r.attemptsLabel).toBe('1 Versuch');
		expect(r.resultLabel).toBe('HTTP 200');
	});
	it('shows a failed delivery with status and the translated code', () => {
		const r = deliveryRow(delivery({ state: 'failed', attempts: 6, httpStatus: 503, errorCode: 'http_503' }));
		expect(r.tone).toBe('destructive');
		expect(r.stateLabel).toBe('Fehlgeschlagen');
		expect(r.attemptsLabel).toBe('6 Versuche');
		expect(r.resultLabel).toContain('HTTP 503');
		expect(r.resultLabel).toContain('Der Empfänger antwortete mit HTTP 503.');
		const net = deliveryRow(delivery({ state: 'failed', httpStatus: null, errorCode: 'timeout' }));
		expect(net.resultLabel).toContain('Zeitüberschreitung');
		expect(net.resultLabel).not.toContain('HTTP');
	});
	it('shows pending deliveries as waiting and the test as test', () => {
		const p = deliveryRow(delivery({ state: 'pending', attempts: 0, httpStatus: null, nextAttemptAt: '2026-11-23T10:05:00Z' }));
		expect(p.tone).toBe('warning');
		expect(p.stateLabel).toBe('Wartet');
		expect(p.attemptsLabel).toBe('0 Versuche');
		expect(p.resultLabel).toBe('');
		const test = deliveryRow(delivery({ event: 'test', anzahl: 0, kinds: [] }));
		expect(test.eventLabel).toBe('Testaufruf');
		expect(test.countLabel).toBe('');
		expect(test.kindLabels).toEqual([]);
	});
	it('uses the singular for one action', () => {
		expect(deliveryRow(delivery({ anzahl: 1 })).countLabel).toBe('1 Aktion');
	});
	it('renders only known German labels: no server text can reach the page', () => {
		const r = deliveryRow(delivery({ kinds: ['question.answered', '<b>x</b>' as never, 'https://hooks.example.com/abc' as never], errorCode: '<img onerror=x>', state: 'failed' }));
		expect(r.kindLabels).toEqual(['Frage beantwortet']);
		expect(JSON.stringify(r)).not.toContain('<');
		expect(JSON.stringify(r)).not.toContain('hooks.example');
	});
	it('has a German name for every kind of the contract', () => {
		expect(WEBHOOK_KINDS).toEqual(['question.answered', 'review.accepted', 'review.changes_requested', 'comment.created', 'task.created', 'task.moved', 'task.status_changed']);
		const names = WEBHOOK_KINDS.map((k) => deliveryRow(delivery({ kinds: [k] })).kindLabels[0]);
		expect(names.every(Boolean)).toBe(true);
		expect(new Set(names).size).toBe(WEBHOOK_KINDS.length);
	});
});

describe('test result', () => {
	it('says delivered or failed with the short code', () => {
		expect(testOutcome(delivery({ event: 'test', state: 'sent', httpStatus: 204 }))).toEqual({ ok: true, text: 'Testaufruf zugestellt (HTTP 204).' });
		const failed = testOutcome(delivery({ event: 'test', state: 'failed', httpStatus: 404, errorCode: 'http_404' }));
		expect(failed.ok).toBe(false);
		expect(failed.text).toContain('Testaufruf fehlgeschlagen');
		expect(failed.text).toContain('http_404');
		const dns = testOutcome(delivery({ event: 'test', state: 'failed', httpStatus: null, errorCode: 'dns_error' }));
		expect(dns.text).toContain('dns_error');
		expect(dns.text).toContain('Namensauflösung');
	});
	it('never prints hostile codes', () => {
		const out = testOutcome(delivery({ event: 'test', state: 'failed', httpStatus: null, errorCode: 'https://hooks.example.com/abc' }));
		expect(out.text).not.toContain('hooks.example');
	});
});

describe('masked address', () => {
	it('shows the mask of the API', () => {
		expect(safeMask('https://example.com/…')).toBe('https://example.com/…');
	});
	it('reduces anything with a path, query or credentials to scheme and host', () => {
		expect(safeMask('https://example.com/abc/SECRET?token=1')).toBe('https://example.com/…');
		expect(safeMask('https://user:pw@example.com:8443/abc')).toBe('https://example.com/…');
	});
	it('shows nothing for non-https values, garbage and absence', () => {
		for (const bad of ['http://example.com/…', 'not a url', '', undefined, null, 'javascript:alert(1)']) expect(safeMask(bad)).toBeNull();
	});
});

describe('status of the webhook', () => {
	it('distinguishes none, active, switched off by the person and switched off by the server', () => {
		expect(webhookStatus(null)).toBe('none');
		expect(webhookStatus(settings({ configured: false, maskedURL: undefined }))).toBe('none');
		expect(webhookStatus(settings())).toBe('active');
		expect(webhookStatus(settings({ enabled: false, consecutiveFailures: 2 }))).toBe('paused');
		expect(webhookStatus(settings({ enabled: false, consecutiveFailures: AUTO_DISABLE_FAILURES }))).toBe('auto_disabled');
		expect(webhookStatus(settings({ enabled: true, consecutiveFailures: AUTO_DISABLE_FAILURES }))).toBe('active');
	});
});

describe('input fields', () => {
	it('trims the address and refuses empty input; the server does the real validation', () => {
		expect(urlInput('  https://example.com/x  ')).toBe('https://example.com/x');
		expect(urlInput('   ')).toBeNull();
		expect(urlInput('')).toBeNull();
		expect(urlInput('http://not-https.example')).toBe('http://not-https.example'); // refused by the server (webhook_url_not_https), not here
	});
	it('keeps the signing secret as typed (spaces count) and refuses empty', () => {
		expect(secretInput('  a b  ')).toBe('  a b  ');
		expect(secretInput('')).toBeNull();
	});
});

describe('project list for exclusions', () => {
	const all = [
		project('B', 'Beta'), project('A', 'Alpha'), project('A2', 'Zwei', 'A'), project('A1', 'Eins', 'A'),
		project('A1a', 'Tief', 'A1'), project('X', 'Waise', 'NOT-VISIBLE'), project('P', 'Mit Position', null, { position: 0 })
	];
	it('orders the tree with children below their parent and shows the depth', () => {
		const rows = orderedProjects(all);
		expect(rows.map((r) => [r.project.id, r.depth])).toEqual([['P', 0], ['A', 0], ['A1', 1], ['A1a', 2], ['A2', 1], ['B', 0], ['X', 0]]);
	});
	it('labels each row with the path so equal names stay distinguishable', () => {
		const rows = orderedProjects([project('A', 'Alpha'), project('A1', 'Eins', 'A')]);
		expect(rows.map((r) => r.label)).toEqual(['Alpha', 'Alpha › Eins']);
	});
	it('survives cycles and missing parents', () => {
		const rows = orderedProjects([project('C1', 'Eins', 'C2'), project('C2', 'Zwei', 'C1'), project('S', 'Selbst', 'S')]);
		expect(rows.map((r) => r.project.id).sort()).toEqual(['C1', 'C2', 'S']);
	});
	it('lists the descendants of a project, not the project itself', () => {
		expect(descendantIDs(all, 'A').sort()).toEqual(['A1', 'A1a', 'A2']);
		expect(descendantIDs(all, 'A1a')).toEqual([]);
		expect(descendantIDs(all, 'nope')).toEqual([]);
		expect(descendantIDs([project('C1', 'Eins', 'C2'), project('C2', 'Zwei', 'C1')], 'C1')).toEqual(['C2']);
	});
	it('toggles single projects, and with sub-projects as a selection aid (single projects are what gets stored)', () => {
		const one = toggleExclusion(new Set(), all, 'A', false);
		expect([...one]).toEqual(['A']);
		const withKids = toggleExclusion(new Set(), all, 'A', true);
		expect([...withKids].sort()).toEqual(['A', 'A1', 'A1a', 'A2']);
		expect([...toggleExclusion(withKids, all, 'A', true)]).toEqual([]);
		// Unticking the parent with the aid on also unticks the children; with the aid off only the parent.
		expect([...toggleExclusion(withKids, all, 'A', false)].sort()).toEqual(['A1', 'A1a', 'A2']);
		// A child alone never drags its parent along.
		expect([...toggleExclusion(new Set(), all, 'A1', true)].sort()).toEqual(['A1', 'A1a']);
	});
	it('does not change the input set', () => {
		const sel = new Set(['A']);
		toggleExclusion(sel, all, 'B', false);
		expect([...sel]).toEqual(['A']);
	});
	it('caps the selection at the server limit but always allows removing', () => {
		const many = Array.from({ length: MAX_EXCLUSIONS + 5 }, (_, i) => project(`P${i}`, `Projekt ${i}`));
		let sel = new Set<string>();
		for (const p of many) sel = toggleExclusion(sel, many, p.id, false);
		expect(sel.size).toBe(MAX_EXCLUSIONS);
		expect(toggleExclusion(sel, many, 'P0', false).size).toBe(MAX_EXCLUSIONS - 1);
		// With sub-projects the aid never overshoots the limit either.
		const tree = [project('R', 'Wurzel'), ...Array.from({ length: MAX_EXCLUSIONS + 2 }, (_, i) => project(`K${i}`, `Kind ${i}`, 'R'))];
		expect(toggleExclusion(new Set(), tree, 'R', true).size).toBe(MAX_EXCLUSIONS);
	});
	it('starts from the saved ids that still exist, using the ids of the project list (case-insensitive)', () => {
		const list = [project('aaaa-1', 'Eins'), project('BBBB-2', 'Zwei')];
		expect(prefillExclusions(['AAAA-1', 'bbbb-2', 'gone'], list).sort()).toEqual(['BBBB-2', 'aaaa-1']);
		expect(prefillExclusions([], list)).toEqual([]);
	});
	it('detects changes against the saved list, independent of order and case', () => {
		const list = [project('aaaa-1', 'Eins'), project('BBBB-2', 'Zwei')];
		expect(exclusionsChanged(['AAAA-1'], new Set(['aaaa-1']))).toBe(false);
		expect(exclusionsChanged(['AAAA-1'], new Set(['aaaa-1', 'BBBB-2']))).toBe(true);
		expect(exclusionsChanged([], new Set())).toBe(false);
		// A stored id the person cannot read any more is dropped on the next save: that is a change.
		expect(exclusionsChanged(['gone'], new Set())).toBe(true);
	});
});

describe('api', () => {
	function recorder(body: unknown, status = 200) {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => {
			calls.push({ url, init });
			return new Response(status === 204 ? null : JSON.stringify(body), { status });
		};
		return { calls, api: createApi(fetchFn) };
	}
	it('reads the settings without any URL', async () => {
		const r = recorder(settings());
		expect(await r.api.getWebhook()).toMatchObject({ configured: true, maskedURL: 'https://example.com/…' });
		expect(r.calls[0].url).toBe('/v1/settings/webhook');
	});
	it('sends only the fields that are set', async () => {
		const r = recorder(settings());
		await r.api.updateWebhook({ url: 'https://example.com/x' });
		await r.api.updateWebhook({ enabled: false });
		await r.api.updateWebhook({ signingSecret: null });
		await r.api.updateWebhook({ excludedProjectIDs: ['P1'] });
		expect(r.calls.map((c) => c.init?.method)).toEqual(['PUT', 'PUT', 'PUT', 'PUT']);
		expect(r.calls.every((c) => c.url === '/v1/settings/webhook')).toBe(true);
		expect(r.calls.map((c) => JSON.parse(c.init?.body as string))).toEqual([
			{ url: 'https://example.com/x' }, { enabled: false }, { signingSecret: null }, { excludedProjectIDs: ['P1'] }
		]);
	});
	it('deletes, sends the test and reads the protocol items', async () => {
		const del = recorder(null, 204);
		await del.api.deleteWebhook();
		expect(del.calls[0]).toMatchObject({ url: '/v1/settings/webhook', init: { method: 'DELETE' } });
		const test = recorder(delivery({ event: 'test' }));
		expect((await test.api.testWebhook()).event).toBe('test');
		expect(test.calls[0]).toMatchObject({ url: '/v1/settings/webhook/test', init: { method: 'POST' } });
		const list = recorder({ items: [delivery(), delivery({ id: 'D2' })] });
		expect((await list.api.listWebhookDeliveries()).map((d) => d.id)).toEqual(['D1', 'D2']);
		expect(list.calls[0].url).toBe('/v1/settings/webhook/deliveries');
	});
	it('turns the documented error answers into ApiErrors with the reason', async () => {
		const r = recorder({ reason: 'webhook_url_blocked' }, 400);
		await expect(r.api.updateWebhook({ url: 'https://10.0.0.5/x' })).rejects.toMatchObject({ status: 400, reason: 'webhook_url_blocked' });
	});
});

describe('settings entry', () => {
	it('is the area "webhook" next to the brain mandate and the connections, with its own slug', () => {
		const e = findEntry('webhook');
		expect(e).toBeDefined();
		expect(t(e!.label)).toBe('Webhook');
		expect(t(e!.description)).toBe('Weckruf bei Aktionen von dir');
		const group = visibleGroups(false).find((g) => g.entries.some((x) => x.id === 'webhook'));
		expect(group?.id).toBe('connected');
		expect(group?.entries.map((x) => x.id)).toContain('brain-vollmacht');
		expect(settingsPath('webhook')).toBe('/settings/webhook');
		expect(normalizeArea('webhook')).toBe('webhook');
	});
	it('is not admin-only and is found by its keywords', () => {
		expect(findEntry('webhook')?.adminOnly).toBeFalsy();
		const groups = visibleGroups(false);
		for (const word of ['webhook', 'weckruf', 'signatur', 'zustellung']) expect(searchSettings(groups, word, t).map((x) => x.id)).toContain('webhook');
	});
});
