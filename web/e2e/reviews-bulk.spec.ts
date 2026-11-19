import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database (first account via the bootstrap token):
//   npx playwright test e2e/reviews-bulk.spec.ts --project=chromium   (also --project=webkit)
// Card 9791E2C3: Sammelfreigabe. Reviews in the overview are selectable, a bar accepts or requests changes for all selected
// ones after a confirmation step with the count, partial failures are listed, "Vom Brain empfohlen" filters the list.
//
// "Vom Brain empfohlen" follows the brain mandate (backend 1.29.0, ADR 0032), not a label: the spec does what a person and
// an agent do. Two real OAuth connections are authorized (dynamic client registration, code + PKCE, consent through the
// signed-in session). The person gives the first one ("brain") the mandate for the project (PUT /v1/settings/brain-mandate,
// session only). Only then does the brain connection write its recommendations as real MCP calls (add_comment into the
// review chat). The second connection ("other") has no mandate: its comment labelled "brain" must not count. A review that the
// mandated connection requested itself is never recommended by it. No database access, everything goes through REST/OAuth/MCP.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/reviews-bulk');
const CALLBACK = 'http://127.0.0.1:59999/callback';
const SCOPES = 'projects:read tasks:read tasks:write comments:write';
test.describe.configure({ mode: 'serial' });
let page: Page;
let mcpApi: APIRequestContext;
const json = { headers: { 'Content-Type': 'application/json' } };
const N = 14;
const BRAIN = [1, 2, 3];
/** Not recommended although a comment labelled "brain" hangs in their chat: 12 from a connection without mandate, 13 on a review the mandated connection requested itself. */
const FAKE_LABEL = 12;
const OWN_REVIEW = 13;
let tasks: { id: string; title: string; reviewID: string }[] = [];
let brain = { grantID: '', token: '' };
let other = { grantID: '', token: '' };
const title = (n: number) => `Review-Aufgabe ${String(n).padStart(2, '0')}`;

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
/** An agent connection like Claude Code gets it: register a client, authorize with PKCE, the person approves for one project. */
async function connect(name: string, projectID: string): Promise<{ grantID: string; token: string }> {
	const reg = await page.request.post('/oauth/register', { data: { client_name: name, redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' } });
	expect(reg.ok(), `register: ${await reg.text()}`).toBeTruthy();
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	const verifier = randomBytes(32).toString('base64url');
	const query = new URLSearchParams({
		response_type: 'code', client_id: clientID, redirect_uri: CALLBACK, scope: SCOPES, state: 'bulk',
		code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256'
	});
	const auth = await page.request.get(`/oauth/authorize?${query}`, { headers: { Accept: 'application/json' } });
	expect(auth.ok(), `authorize: ${await auth.text()}`).toBeTruthy();
	const consent = await post<{ redirect_uri: string }>('/oauth/consent', {
		consent_token: ((await auth.json()) as { consent_token: string }).consent_token, approve: true, project_ids: [projectID], connection_name: name
	});
	const code = new URL(consent.redirect_uri).searchParams.get('code');
	expect(code, consent.redirect_uri).toBeTruthy();
	const token = await page.request.post('/oauth/token', {
		form: { grant_type: 'authorization_code', client_id: clientID, code: code!, redirect_uri: CALLBACK, code_verifier: verifier }
	});
	expect(token.ok(), `token: ${await token.text()}`).toBeTruthy();
	const grants = (await (await page.request.get('/oauth/grants')).json()) as { id: string; client_id: string }[];
	const grant = grants.find((g) => g.client_id.toLowerCase() === clientID.toLowerCase());
	expect(grant, 'grant of the new connection').toBeTruthy();
	return { grantID: grant!.id, token: ((await token.json()) as { access_token: string }).access_token };
}
/** One MCP tool call with the OAuth token of a connection (no session cookie involved). */
async function mcp(token: string, tool: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
	const r = await mcpApi.post('/mcp', {
		headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
		data: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: args } }
	});
	expect(r.status(), `${tool}: ${await r.text()}`).toBe(200);
	const result = ((await r.json()) as { result: { isError?: boolean; content: { text: string }[] } }).result;
	expect(result.isError ?? false, `${tool}: ${result.content[0].text}`).toBe(false);
	return JSON.parse(result.content[0].text) as Record<string, unknown>;
}
const recommend = (token: string, t: { id: string; reviewID: string }) =>
	mcp(token, 'add_comment', { taskID: t.id, reviewID: t.reviewID, agentName: 'brain', body: 'Lino: das ist ok, annehmen.' });
const reviewFlags = async () =>
	new Map(((await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as { id: string; brainRecommended?: boolean }[]).map((r) => [r.id, r.brainRecommended === true]));
const status = async (id: string) => ((await (await page.request.get(`/v1/tasks/${id}/context`)).json()) as { task: { status: string } }).task.status;
const reviewState = async (id: string) =>
	((await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as { id: string; state: string; decisionNote?: string }[]).find((r) => r.id === id);
const rows = () => page.getByTestId('cc-reviews').getByTestId('review-row');
const row = (n: number) => rows().filter({ hasText: title(n) });
const box = (n: number) => row(n).getByTestId('review-select');
const bar = () => page.getByTestId('review-bulk-bar');
const count = () => page.getByTestId('review-bulk-count');
async function openReviews() {
	await page.goto('/overview');
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}
async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
const shot = async (name: string) => { await page.waitForTimeout(350); await page.screenshot({ path: `${SHOTS}/${name}.png` }); };
async function theme(mode: 'dark' | 'light') {
	await page.evaluate((m) => (m === 'dark' ? localStorage.setItem('todo.theme', 'dark') : localStorage.removeItem('todo.theme')), mode);
	await page.reload();
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Sammel Tester');
	mcpApi = await request.newContext({ baseURL: test.info().project.use.baseURL });
	const project = await post<{ id: string }>('/v1/projects', { name: 'Sammelprojekt' });
	brain = await connect('Brain-Verbindung', project.id);
	other = await connect('Andere Verbindung', project.id);
	for (let n = 1; n <= N; n++) {
		const t = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: title(n) });
		if (n === OWN_REVIEW) {
			await mcp(brain.token, 'request_review', { taskID: t.id, summary: `Ergebnis ${n} ist fertig.` });
			tasks.push({ id: t.id, title: title(n), reviewID: '' });
			continue;
		}
		const r = await post<{ id: string }>(`/v1/tasks/${t.id}/review`, { summary: `Ergebnis ${n} ist fertig.\n- Neu: Sammelfreigabe\n- Geprüft: Tests`, agentName: 'Claude Code' });
		tasks.push({ id: t.id, title: title(n), reviewID: r.id });
	}
	const listed = (await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as { id: string; taskID: string }[];
	tasks[OWN_REVIEW - 1].reviewID = listed.find((r) => r.taskID.toLowerCase() === tasks[OWN_REVIEW - 1].id.toLowerCase())!.id;
	// The management view lists the project in the account overview.
	await page.goto(`/project/${project.id}`);
	if (!(await page.getByTestId('project-tabs').isVisible())) {
		await page.getByTestId('display-menu').click();
		await page.getByTestId('mode-management').click();
		await page.keyboard.press('Escape');
	}
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	// The person gives the first connection the brain mandate for this project. Only comments written afterwards count.
	const mandate = await page.request.put('/v1/settings/brain-mandate', { ...json, data: { grantID: brain.grantID, projectIDs: [project.id] } });
	expect(mandate.status(), await mandate.text()).toBe(200);
	expect(((await mcp(brain.token, 'get_connection', {})).brainMandate as { active: boolean }).active).toBe(true);
	expect(((await mcp(other.token, 'get_connection', {})).brainMandate as { active: boolean }).active).toBe(false);
	// "Vom Brain empfohlen": real MCP comments in the chat of the review.
	for (const n of BRAIN) await recommend(brain.token, tasks[n - 1]);
	// Look-alikes that must not count: label "brain" from a connection without mandate, and a comment on the mandated connection's own review.
	await recommend(other.token, tasks[FAKE_LABEL - 1]);
	await recommend(brain.token, tasks[OWN_REVIEW - 1]);
});
test.afterAll(async () => {
	await mcpApi?.dispose();
	await page?.context().close();
});

test('every row has a labelled checkbox; selecting shows the bar with the count; select-all takes the visible rows; clear', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await openReviews();
	await expect(rows()).toHaveCount(N);
	await expect(bar()).toHaveCount(0);
	await expect(box(5)).toHaveAccessibleName('Review auswählen: Review-Aufgabe 05');
	await box(5).check();
	await box(6).check();
	await expect(bar()).toBeVisible();
	await expect(bar()).toHaveAccessibleName('Sammelaktion für Reviews');
	await expect(count()).toHaveText('2 ausgewählt');
	await expect(page.getByTestId('review-select-all')).toHaveAttribute('aria-checked', 'mixed');
	await page.getByTestId('review-select-all').check();
	await expect(count()).toHaveText(`${N} ausgewählt`);
	await expect(page.getByTestId('review-select-all')).toHaveAttribute('aria-checked', 'true');
	await shot('desktop-hell-auswahl');
	await page.getByTestId('review-select-all').uncheck();
	await expect(bar()).toHaveCount(0);
	await box(5).check();
	await page.getByTestId('review-bulk-clear').click();
	await expect(bar()).toHaveCount(0);
	await expect(box(5)).not.toBeChecked();
	// The existing single decision stays in every row.
	await expect(row(5).getByTestId('review-accept')).toBeVisible();
	await expect(row(5).getByTestId('review-note')).toBeVisible();
});

test('keyboard: Space selects, the bar is reachable with Tab, Escape cancels the confirmation and then clears', async () => {
	await openReviews();
	await box(7).focus();
	await page.keyboard.press('Space');
	await expect(box(7)).toBeChecked();
	await expect(count()).toHaveText('1 ausgewählt');
	await page.getByTestId('review-bulk-accept').focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('review-bulk-confirm')).toBeVisible();
	await expect(page.getByTestId('review-bulk-confirm')).toHaveAttribute('role', 'alertdialog');
	// Focus moves to the confirming button, so Enter would confirm: it must be the deliberate action.
	await expect(page.getByTestId('review-bulk-confirm-go')).toBeFocused();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('review-bulk-confirm')).toHaveCount(0);
	await expect(box(7)).toBeChecked();
	await page.getByTestId('review-bulk-note').focus();
	await page.keyboard.press('Escape');
	await expect(bar()).toHaveCount(0);
	await expect(await status(tasks[6].id)).toBe('in_review');
});

test('filter "Vom Brain empfohlen": badge on the rows, only they are listed, select-all takes only them', async () => {
	await openReviews();
	await expect(page.getByTestId('review-filter-all')).toHaveText(`Alle (${N})`);
	await expect(page.getByTestId('review-filter-brain')).toHaveText(`Vom Brain empfohlen (${BRAIN.length})`);
	await expect(page.getByTestId('review-brain-badge')).toHaveCount(BRAIN.length);
	await expect(row(1).getByTestId('review-brain-badge')).toHaveText('Vom Brain empfohlen');
	await expect(row(4).getByTestId('review-brain-badge')).toHaveCount(0);
	await page.getByTestId('review-filter-brain').click();
	await expect(page.getByTestId('review-filter-brain')).toHaveAttribute('aria-pressed', 'true');
	await expect(rows()).toHaveCount(BRAIN.length);
	await page.getByTestId('review-select-all').check();
	await expect(count()).toHaveText(`${BRAIN.length} ausgewählt`);
	// Leaving the filter drops hidden rows from the selection, never selects them.
	await page.getByTestId('review-filter-all').click();
	await expect(rows()).toHaveCount(N);
	await expect(count()).toHaveText(`${BRAIN.length} ausgewählt`);
	await expect(box(4)).not.toBeChecked();
	await page.getByTestId('review-filter-brain').click();
	await shot('desktop-hell-brain-filter');
});

test('regression: a bare "brain" label from a connection without mandate, and a comment on the mandated connection\'s own review, are not recommendations', async () => {
	// The look-alike comments really exist in the review chats, so the checks below are not vacuous.
	type Comment = { reviewID?: string; authorKind: string; authorLabel: string };
	for (const n of [FAKE_LABEL, OWN_REVIEW]) {
		const body = (await (await page.request.get(`/v1/tasks/${tasks[n - 1].id}/comments`)).json()) as Comment[] | { items: Comment[] };
		const list = Array.isArray(body) ? body : body.items;
		const hit = list.some((c) => c.authorKind === 'agent' && c.authorLabel === 'brain' && c.reviewID?.toLowerCase() === tasks[n - 1].reviewID.toLowerCase());
		expect(hit, `comment labelled brain on ${title(n)}`).toBe(true);
	}
	// API: only the real recommendations are flagged.
	const flags = await reviewFlags();
	for (const n of BRAIN) expect(flags.get(tasks[n - 1].reviewID), title(n)).toBe(true);
	for (const n of [FAKE_LABEL, OWN_REVIEW]) expect(flags.get(tasks[n - 1].reviewID), title(n)).toBe(false);
	const only = (await (await page.request.get('/v1/reviews?brainRecommended=true')).json()) as { id: string }[];
	expect(only.map((r) => r.id.toLowerCase()).sort()).toEqual(BRAIN.map((n) => tasks[n - 1].reviewID.toLowerCase()).sort());
	// UI: no badge on the look-alikes, and the filter does not list them.
	await openReviews();
	for (const n of [FAKE_LABEL, OWN_REVIEW]) {
		await expect(row(n)).toBeVisible();
		await expect(row(n).getByTestId('review-brain-badge')).toHaveCount(0);
	}
	await page.getByTestId('review-filter-brain').click();
	await expect(rows()).toHaveCount(BRAIN.length);
	for (const n of [FAKE_LABEL, OWN_REVIEW]) await expect(row(n)).toHaveCount(0);
	await page.getByTestId('review-filter-all').click();
});

test('accept: confirmation names the count and can be cancelled; confirming accepts all selected and reports it', async () => {
	await openReviews();
	await page.getByTestId('review-filter-brain').click();
	await page.getByTestId('review-select-all').check();
	await page.getByTestId('review-bulk-note').fill('Mündlich freigegeben');
	await page.getByTestId('review-bulk-accept').click();
	const confirm = page.getByTestId('review-bulk-confirm');
	await expect(confirm).toContainText('3 Reviews annehmen?');
	await expect(confirm).toContainText('Zurücknehmen geht nur einzeln');
	await shot('desktop-hell-bestaetigung');
	// Cancel: nothing happened.
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await expect(confirm).toHaveCount(0);
	await expect(rows()).toHaveCount(BRAIN.length);
	for (const n of BRAIN) expect(await status(tasks[n - 1].id)).toBe('in_review');
	// Confirm.
	await page.getByTestId('review-bulk-accept').click();
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toHaveText(/3 Reviews angenommen\./);
	await expect(page.getByTestId('review-bulk-result')).toHaveAttribute('role', 'status');
	await expect(bar()).toHaveCount(0);
	for (const n of BRAIN) {
		expect(await status(tasks[n - 1].id)).toBe('done');
		const r = await reviewState(tasks[n - 1].reviewID);
		expect(r?.state).toBe('accepted');
		expect(r?.decisionNote).toBe('Mündlich freigegeben');
	}
	await page.getByTestId('review-filter-all').click();
	await expect(rows()).toHaveCount(N - BRAIN.length);
	await expect(page.getByTestId('cc-count-reviews')).toHaveText(String(N - BRAIN.length));
	await shot('desktop-hell-ergebnis');
});

test('partial failure: a review decided meanwhile is reported, the others are done, nothing is rolled back', async () => {
	await openReviews();
	for (const n of [4, 5, 6, 8]) await box(n).check();
	await expect(count()).toHaveText('4 ausgewählt');
	// Someone decides review 5 after the selection but before the batch arrives (real backend, real single path).
	// In-page fetch wrapper (page.route does not intercept this request in WebKit): decide review 5 through the real single
	// path right before the batch request leaves.
	await page.evaluate((taskID) => {
		const original = window.fetch.bind(window);
		let done = false;
		window.fetch = async (input, init) => {
			const url = typeof input === 'string' ? input : input instanceof Request ? input.url : String(input);
			if (!done && url.endsWith('/v1/reviews/decisions') && init?.method === 'POST') {
				done = true;
				const r = await original(`/v1/tasks/${taskID}/review/decision`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ decision: 'accept' }) });
				if (!r.ok) throw new Error(`interleaved decision failed: ${r.status}`);
			}
			return original(input, init);
		};
	}, tasks[4].id);
	await page.getByTestId('review-bulk-accept').click();
	await expect(page.getByTestId('review-bulk-confirm')).toContainText('4 Reviews annehmen?');
	await page.getByTestId('review-bulk-confirm-go').click();
	const result = page.getByTestId('review-bulk-result');
	await expect(result).toContainText('3 von 4 erledigt, 1 nicht');
	await expect(result).toHaveAttribute('role', 'alert');
	await expect(page.getByTestId('review-bulk-failures').locator('li')).toHaveCount(1);
	await expect(page.getByTestId('review-bulk-failures')).toContainText('Review-Aufgabe 05');
	await expect(page.getByTestId('review-bulk-failures')).toContainText('Schon entschieden');
	for (const n of [4, 5, 6, 8]) expect(await status(tasks[n - 1].id), title(n)).toBe('done');
	await expect(rows()).toHaveCount(N - BRAIN.length - 4);
	await shot('desktop-hell-teilfehler');
	await result.getByRole('button', { name: 'Meldung schließen' }).click();
	await expect(result).toHaveCount(0);
});

test('changes requested needs a note; with it all selected go back to work with the shared note', async () => {
	await openReviews();
	await box(9).check();
	await box(10).check();
	await page.getByTestId('review-bulk-changes').click();
	await expect(page.getByText('Bitte beschreibe, was geändert werden soll.')).toBeVisible();
	await expect(page.getByTestId('review-bulk-confirm')).toHaveCount(0);
	await page.getByTestId('review-bulk-note').fill('Bitte Tests ergänzen');
	await page.getByTestId('review-bulk-changes').click();
	await expect(page.getByTestId('review-bulk-confirm')).toContainText('Für 2 Reviews Änderungen anfordern?');
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toHaveText(/Für 2 Reviews Änderungen angefordert\./);
	for (const n of [9, 10]) {
		expect(await status(tasks[n - 1].id)).toBe('in_progress');
		const r = await reviewState(tasks[n - 1].reviewID);
		expect(r?.state).toBe('changes_requested');
		expect(r?.decisionNote).toBe('Bitte Tests ergänzen');
	}
});

test('layout: 390 px mobile and dark mode (bar, confirmation, result); no horizontal overflow', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await openReviews();
	await expect(rows().first()).toBeVisible();
	await noOverflow('list');
	await shot('mobil-hell-liste');
	await page.getByTestId('review-select-all').check();
	await expect(bar()).toBeVisible();
	await noOverflow('selection');
	// The bar sits inside the viewport and its buttons are reachable (tap size).
	const b = await bar().boundingBox();
	expect(b!.y + b!.height).toBeLessThanOrEqual(844);
	for (const id of ['review-bulk-accept', 'review-bulk-changes']) {
		const r = await page.getByTestId(id).boundingBox();
		expect(r!.height, id).toBeGreaterThanOrEqual(32);
	}
	await shot('mobil-hell-auswahl');
	await page.getByTestId('review-bulk-accept').click();
	await expect(page.getByTestId('review-bulk-confirm')).toBeVisible();
	await noOverflow('confirm');
	await shot('mobil-hell-bestaetigung');
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await theme('dark');
	await expect(page.locator('html')).toHaveClass(/dark/);
	await page.getByTestId('review-select-all').check();
	await noOverflow('dark selection');
	await shot('mobil-dunkel-auswahl');
	await page.getByTestId('review-bulk-accept').click();
	await shot('mobil-dunkel-bestaetigung');
	await page.getByTestId('review-bulk-confirm-cancel').click();
	await page.setViewportSize({ width: 1280, height: 900 });
	await expect(page.getByTestId('review-bulk-note')).toBeVisible();
	await shot('desktop-dunkel-auswahl');
	await theme('light');
});

test('single decision is unchanged, and the empty state follows the last review', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	await openReviews();
	const left = await rows().count();
	expect(left).toBeGreaterThan(0);
	await row(11).getByTestId('review-accept').click();
	await expect(row(11)).toHaveCount(0);
	expect(await status(tasks[10].id)).toBe('done');
	await expect(rows()).toHaveCount(left - 1);
	// Decide the rest in one batch; the empty state and no toolbar remain.
	await page.getByTestId('review-select-all').check();
	await page.getByTestId('review-bulk-accept').click();
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toContainText(`${left - 1} Reviews angenommen.`);
	await expect(rows()).toHaveCount(0);
	await expect(page.getByText('Keine fälligen Reviews')).toBeVisible();
	await expect(page.getByTestId('review-toolbar')).toHaveCount(0);
});
