import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, request, test, type APIRequestContext, type Locator, type Page } from '@playwright/test';
import { connect as connectGrant, mcp as mcpTool, mcpCall, type Connection } from './support/oauth';
import { signedInPage } from './support/session';

// Needs a fresh backend database (first account via the bootstrap token):
//   npx playwright test e2e/brain-mandate.spec.ts --project=chromium   (also --project=webkit)
// Cards 11DA4A38 and 2280A2F1 (ADR 0032 and addendum): the settings page "Brain-Vollmacht", one mandate per connection. Everything
// runs against the real backend: real OAuth connections (dynamic client registration, code + PKCE, consent), the person manages
// the mandates in the real UI, and the effect is checked through REST (GET /v1/settings/brain-mandate) and MCP (get_connection,
// decide_review with the connections' tokens): two connections hold a mandate at the same time, each decides only in its projects,
// revoking one leaves the other.
// Screenshots (docs/screenshots/brain-mandat/) are written by the Chromium run only; they are real screenshots of the real app.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/brain-mandat');
// The look matrices reload the page eight times; allow for a loaded machine.
test.describe.configure({ mode: 'serial', timeout: 120_000 });

let page: Page;
let mcpApi: APIRequestContext;
const json = { headers: { 'Content-Type': 'application/json' } };
let alpha = { id: '', name: 'Vollmacht Alpha' };
let beta = { id: '', name: 'Vollmacht Beta' };
let gamma = { id: '', name: 'Vollmacht Gamma' };
let codex: Connection;
let brain: Connection;
let reviews: { id: string; taskID: string }[] = [];

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const sortedIDs = (ids: string[]) => ids.map((i) => i.toLowerCase()).sort();

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const connect = (name: string, projectIDs: string[] = [alpha.id, beta.id, gamma.id]) => connectGrant(page, name, projectIDs);
const mcp = (token: string, tool: string, args: Record<string, unknown>) => mcpTool(mcpApi, token, tool, args);
interface Mandate { grantID: string; grantName: string | null; projectIDs: string[]; active: boolean; revokedAt: string | null }
const apiMandates = async () => ((await (await page.request.get('/v1/settings/brain-mandate')).json()) as { mandates: Mandate[] }).mandates;
const apiMandate = async (c: Connection) => (await apiMandates()).find((m) => same(m.grantID, c.grantID));
/** The list entry of one connection. */
const entry = (c: Connection) => page.locator(`[data-testid="bm-mandate"][data-grant-id="${c.grantID.toLowerCase()}"]`);
const mandateOf = async (c: Connection) => (await mcp(c.token, 'get_connection', {})).brainMandate as { active: boolean; projectIDs?: string[] };
/** A pending review of a person (not of any connection), so a mandated connection may decide it. */
async function newReview(project: { id: string }, title: string) {
	const t = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title });
	const r = await post<{ id: string }>(`/v1/tasks/${t.id}/review`, { summary: `Ergebnis von ${title}.`, agentName: 'Claude Code' });
	return { id: r.id, taskID: t.id };
}

const shoots = () => test.info().project.name === 'chromium';
/** Luminance (0..1) of the first opaque background colour (body, then html) as the browser really paints it. */
const backdrop = () =>
	page.evaluate(() => {
		const ctx = document.createElement('canvas').getContext('2d')!;
		for (const el of [document.body, document.documentElement]) {
			const color = getComputedStyle(el).backgroundColor;
			ctx.clearRect(0, 0, 1, 1);
			ctx.fillStyle = '#000';
			ctx.fillStyle = color;
			ctx.fillRect(0, 0, 1, 1);
			const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
			if (a > 250) return { dark: document.documentElement.classList.contains('dark'), luminance: (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255, color };
		}
		return { dark: document.documentElement.classList.contains('dark'), luminance: -1, color: 'transparent' };
	});
/** The page really is in the claimed mode: the PWA's dark class and the painted background agree (light > 0.8, dark < 0.2). */
async function assertMode(mode: 'light' | 'dark') {
	const look = await backdrop();
	expect(look.dark, `html.dark in ${mode} mode (${look.color})`).toBe(mode === 'dark');
	expect(look.luminance, `background ${look.color}`).toBeGreaterThanOrEqual(0);
	if (mode === 'light') expect(look.luminance, `background ${look.color}`).toBeGreaterThan(0.8);
	else expect(look.luminance, `background ${look.color}`).toBeLessThan(0.2);
}
/** File name and look cannot disagree: "-hell-" must be painted light, "-dunkel-" dark, checked right before the screenshot. */
const shot = async (name: string) => {
	if (!shoots()) return;
	await assertMode(name.includes('-dunkel-') ? 'dark' : 'light');
	await page.evaluate(() => {
		if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
	});
	// No fullPage: the app shell has fixed parts (sidebar, header, bottom bar) that a stitched full-page capture would paste into
	// the middle of the page. Instead the viewport is made as tall as the content, so one real frame shows everything in place.
	const { width, height } = page.viewportSize()!;
	await page.setViewportSize({ width, height: 4000 });
	await page.waitForTimeout(300);
	const bottom = await page.evaluate(() =>
		Math.max(...['bm-intro', 'bm-list', 'bm-form-card', 'bm-audit'].map((id) => document.querySelector(`[data-testid="${id}"]`)?.getBoundingClientRect().bottom ?? 0))
	);
	// Room below the last card; on a phone the fixed bottom bar needs its own space.
	await page.setViewportSize({ width, height: Math.ceil(bottom) + (width < 600 ? 110 : 40) });
	await page.waitForTimeout(400);
	await page.evaluate(() => window.scrollTo(0, 0));
	await page.screenshot({ path: `${SHOTS}/${name}.png` });
	await page.setViewportSize({ width, height });
};
async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
/**
 * Sets the PWA's own colour scheme like the appearance page does: it belongs to the account (`PUT /v1/me/preferences`, which
 * wins over localStorage on every load) and is cached in localStorage `todo.theme`. Never left on "system". The browser's
 * colour scheme follows, then the page is reloaded and the effect is asserted.
 */
async function theme(mode: 'dark' | 'light') {
	const current = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
	const put = await page.request.put('/v1/me/preferences', { ...json, data: { version: 1, appearance: { ...current.appearance, colorScheme: mode } } });
	expect(put.status(), await put.text()).toBeLessThan(300);
	await page.emulateMedia({ colorScheme: mode });
	await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
	await page.reload();
	await expect(page.getByTestId('brain-mandate')).toBeVisible({ timeout: 20_000 });
	await expect(page.getByTestId('bm-list')).toBeVisible({ timeout: 20_000 });
	await assertMode(mode);
}
const desktop = () => page.setViewportSize({ width: 1280, height: 900 });
const mobile = () => page.setViewportSize({ width: 390, height: 844 });
async function openPage() {
	await page.goto('/settings/brain-mandate');
	await expect(page.getByTestId('bm-list')).toBeVisible({ timeout: 20_000 });
}
/**
 * One state in all four looks (desktop 1280 / mobile 390, light / dark): the theme is set and asserted, the reload resets the
 * page, so `setup` rebuilds the state (e.g. reopens the confirmation) before the overflow check and the screenshot.
 */
async function lookMatrix(name: string, setup: () => Promise<void> = async () => {}) {
	for (const mode of ['light', 'dark'] as const) {
		for (const size of ['desktop', 'mobil'] as const) {
			await (size === 'desktop' ? desktop() : mobile());
			await theme(mode);
			await setup();
			await noOverflow(`${name} ${size} ${mode}`);
			await shot(`${size}-${mode === 'light' ? 'hell' : 'dunkel'}-${name}`);
		}
	}
	await theme('light');
	await desktop();
}
/**
 * Tab moves focus to the next control. WebKit (like Safari by default) does not put checkboxes and buttons in the Tab order,
 * so there the same target is focused directly; the assertion that it really has focus stays.
 */
async function tabTo(target: Locator) {
	await page.keyboard.press('Tab');
	if (page.context().browser()?.browserType().name() === 'webkit') await target.focus();
	await expect(target).toBeFocused();
}
const grantOption = (name: string) => page.getByRole('radio', { name: new RegExp(name) });
const projectBox = (name: string) => page.getByTestId('bm-project-list').getByRole('checkbox', { name });
const save = () => page.getByTestId('bm-save');
const message = () => page.getByTestId('bm-message');
async function pickProjects(...names: string[]) {
	for (const n of names) await projectBox(n).check();
}

test.beforeAll(async ({ browser }) => {
	test.setTimeout(120_000);
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Vollmacht Tester');
	mcpApi = await request.newContext({ baseURL: test.info().project.use.baseURL });
	alpha.id = (await post<{ id: string }>('/v1/projects', { name: alpha.name })).id;
	beta.id = (await post<{ id: string }>('/v1/projects', { name: beta.name })).id;
	gamma.id = (await post<{ id: string }>('/v1/projects', { name: gamma.name })).id;
	await page.setViewportSize({ width: 1280, height: 900 });
});
test.afterAll(async () => {
	await mcpApi?.dispose();
	await page?.context().close();
});

test('(a) empty state: no connection and no mandate, then the connections show up unselected; reachable from the settings hub', async () => {
	await page.goto('/settings');
	await page.getByTestId('settings-link-brain-vollmacht').click();
	await expect(page).toHaveURL(/\/settings\/brain-mandate$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Brain-Vollmacht');
	await expect(page.getByTestId('bm-intro')).toContainText('Pflichtzitat');
	await expect(page.getByTestId('bm-intro')).toContainText('Brain im Auftrag von Vollmacht Tester');
	await expect(page.getByTestId('bm-intro')).toContainText('Jede Verbindung bekommt ihre eigene Vollmacht');
	await expect(page.getByTestId('bm-intro')).toContainText('nicht für deren Unterprojekte');
	await expect(page.getByTestId('bm-intro')).toContainText('nie für Reviews oder Fragen, die die Verbindung selbst gestellt hat');
	await expect(page.getByTestId('bm-empty')).toContainText('Keine Vollmacht erteilt');
	await expect(page.getByTestId('bm-no-grants')).toContainText('keine aktive Verbindung');
	expect(await apiMandates()).toEqual([]);
	await expect(save()).toBeDisabled();

	// Two real connections (the person approves them like in the consent screen).
	codex = await connect('Codex-Verbindung');
	brain = await connect('Brain-Verbindung');
	await openPage();
	await expect(page.getByTestId('bm-empty')).toBeVisible();
	await expect(page.getByTestId('bm-grant-option')).toHaveCount(2);
	// Nothing is preselected: no connection, no project.
	await expect(page.getByRole('radio', { checked: true })).toHaveCount(0);
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox', { checked: true })).toHaveCount(0);
	await expect(page.getByTestId('bm-problem')).toHaveText('Wähle eine Verbindung.');
	await expect(save()).toBeDisabled();
	await expect(page.getByTestId('bm-selected-count')).toHaveText('0 von 200 Projekten gewählt');
	await lookMatrix('leerzustand');
});

test('(b) grant the first connection: pick one of two connections and two of three projects; the API and get_connection confirm exactly that', async () => {
	await openPage();
	await grantOption('Codex-Verbindung').check();
	await expect(save()).toBeDisabled();
	await expect(page.getByTestId('bm-problem')).toHaveText('Wähle mindestens ein Projekt.');
	// Search narrows the list, selection survives the filter.
	await page.getByTestId('bm-project-search').fill('Gamma');
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox')).toHaveCount(1);
	await page.getByTestId('bm-project-search').fill('');
	await pickProjects(alpha.name, beta.name);
	await expect(page.getByTestId('bm-selected-count')).toHaveText('2 von 200 Projekten gewählt');
	await expect(page.getByTestId('bm-summary')).toContainText('„Codex-Verbindung“ darf in 2 Projekten');
	await expect(save()).toHaveText('Vollmacht erteilen');
	const choose = async () => {
		await grantOption('Codex-Verbindung').check();
		await pickProjects(alpha.name, beta.name);
		await expect(save()).toBeEnabled();
	};
	await lookMatrix('auswahl', choose);
	await choose();

	await save().click();
	await expect(message()).toContainText('Vollmacht erteilt');
	await expect(message()).toHaveAttribute('role', 'status');
	const mine = entry(codex);
	await expect(mine.getByTestId('bm-status')).toHaveText('Aktiv');
	await expect(mine.getByTestId('bm-grant-name')).toHaveText('Codex-Verbindung');
	await expect(mine.getByTestId('bm-scope-project')).toHaveText([alpha.name, beta.name]);
	await expect(mine.getByTestId('bm-used')).toHaveText('Noch nie benutzt');
	await expect(page.getByTestId('bm-mandate')).toHaveCount(1);
	// Focus moves to the result, not into the void.
	await expect(page.getByTestId('bm-list')).toBeFocused();

	const m = await apiMandate(codex);
	expect(m?.active).toBe(true);
	expect(sortedIDs(m!.projectIDs)).toEqual(sortedIDs([alpha.id, beta.id]));
	const viaMcp = await mandateOf(codex);
	expect(viaMcp.active).toBe(true);
	expect(sortedIDs(viaMcp.projectIDs ?? [])).toEqual(sortedIDs([alpha.id, beta.id]));
	expect((await mandateOf(brain)).active).toBe(false);
});

test('(b2) add a second connection: both hold a mandate with their own projects; the form of the new one does not take over the first one\'s projects', async () => {
	await openPage();
	// The connection that already has a mandate is marked; the other one starts empty.
	await expect(page.locator('[data-testid="bm-grant-option"]', { hasText: 'Codex-Verbindung' })).toContainText('hat die Vollmacht');
	await expect(page.locator('[data-testid="bm-grant-option"]', { hasText: 'Brain-Verbindung' })).not.toContainText('hat die Vollmacht');
	await expect(page.getByTestId('bm-form-title')).toHaveText('Vollmacht hinzufügen');
	await grantOption('Brain-Verbindung').check();
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox', { checked: true })).toHaveCount(0);
	await expect(page.getByTestId('bm-form-title')).toHaveText('Vollmacht hinzufügen');
	await pickProjects(beta.name, gamma.name);
	await expect(save()).toHaveText('Vollmacht erteilen');
	await save().click();
	await expect(message()).toContainText('Vollmacht erteilt');
	await expect(page.getByTestId('bm-mandate')).toHaveCount(2);
	await expect(entry(brain).getByTestId('bm-scope-project')).toHaveText([beta.name, gamma.name]);
	// The first mandate is untouched.
	await expect(entry(codex).getByTestId('bm-status')).toHaveText('Aktiv');
	await expect(entry(codex).getByTestId('bm-scope-project')).toHaveText([alpha.name, beta.name]);

	const list = await apiMandates();
	expect(list.filter((m) => m.active)).toHaveLength(2);
	expect(sortedIDs((await apiMandate(codex))!.projectIDs)).toEqual(sortedIDs([alpha.id, beta.id]));
	expect(sortedIDs((await apiMandate(brain))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect(sortedIDs((await mandateOf(codex)).projectIDs ?? [])).toEqual(sortedIDs([alpha.id, beta.id]));
	expect(sortedIDs((await mandateOf(brain)).projectIDs ?? [])).toEqual(sortedIDs([beta.id, gamma.id]));
	await lookMatrix('zwei-vollmachten');
});

test('(c) change the project scope of one connection: add one, remove one; the diff names both before anything is saved and the other mandate stays', async () => {
	await openPage();
	await entry(codex).getByTestId('bm-edit').click();
	// The mandate of that connection is the starting point of the change; nothing of the other one leaks in.
	await expect(page.getByTestId('bm-form-title')).toHaveText('Vollmacht von „Codex-Verbindung“ ändern');
	await expect(page.getByTestId('bm-form-title')).toBeFocused();
	await expect(page.getByRole('radio', { name: /Codex-Verbindung/ })).toBeChecked();
	await expect(projectBox(alpha.name)).toBeChecked();
	await expect(projectBox(beta.name)).toBeChecked();
	await expect(projectBox(gamma.name)).not.toBeChecked();
	await expect(save()).toBeDisabled();
	await expect(page.getByTestId('bm-unchanged')).toBeVisible();
	await projectBox(gamma.name).check();
	await projectBox(alpha.name).uncheck();
	await expect(save()).toHaveText('Änderung prüfen');
	await save().click();
	const confirm = page.getByTestId('bm-confirm');
	await expect(confirm).toBeVisible();
	await expect(confirm).toHaveAttribute('role', 'alertdialog');
	await expect(confirm).toBeFocused();
	await expect(page.getByTestId('bm-diff-before')).toContainText('„Codex-Verbindung“ für 2 Projekte');
	await expect(page.getByTestId('bm-diff-after')).toContainText('„Codex-Verbindung“ für 2 Projekte');
	await expect(page.getByTestId('bm-diff-added')).toContainText(gamma.name);
	await expect(page.getByTestId('bm-diff-removed')).toContainText(alpha.name);
	await expect(page.getByTestId('bm-diff-kept')).toContainText(beta.name);
	await expect(page.getByTestId('bm-diff-warning')).toContainText('Für die entfallenen Projekte verliert „Codex-Verbindung“ die Vollmacht sofort.');
	await expect(page.getByTestId('bm-diff-others')).toContainText('Die Vollmachten deiner anderen Verbindungen bleiben unverändert.');
	// Nothing happened yet.
	expect(sortedIDs((await apiMandate(codex))!.projectIDs)).toEqual(sortedIDs([alpha.id, beta.id]));
	await page.getByTestId('bm-confirm-go').click();
	await expect(message()).toContainText('Vollmacht geändert');
	await expect(page.getByTestId('bm-confirm')).toHaveCount(0);
	await expect(entry(codex).getByTestId('bm-scope-project')).toHaveText([beta.name, gamma.name]);
	expect(sortedIDs((await apiMandate(codex))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect(sortedIDs((await mandateOf(codex)).projectIDs ?? [])).toEqual(sortedIDs([beta.id, gamma.id]));
	// The other connection kept its mandate.
	expect(sortedIDs((await apiMandate(brain))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect((await mandateOf(brain)).active).toBe(true);
});

test('(d) cancel changes nothing; choosing a connection that has a mandate shows its own projects; the confirmation looks right in all four looks', async () => {
	await openPage();
	await grantOption('Brain-Verbindung').check();
	await expect(page.getByTestId('bm-form-title')).toHaveText('Vollmacht von „Brain-Verbindung“ ändern');
	await expect(projectBox(alpha.name)).not.toBeChecked();
	await expect(projectBox(beta.name)).toBeChecked();
	await expect(projectBox(gamma.name)).toBeChecked();
	await projectBox(gamma.name).uncheck();
	await pickProjects(alpha.name);
	await save().click();
	const confirm = page.getByTestId('bm-confirm');
	await expect(confirm).toBeVisible();
	await expect(page.getByTestId('bm-diff-before')).toContainText('„Brain-Verbindung“');
	await expect(page.getByTestId('bm-diff-added')).toContainText(alpha.name);
	await expect(page.getByTestId('bm-diff-removed')).toContainText(gamma.name);
	await expect(page.getByTestId('bm-diff-warning')).toContainText('Für die entfallenen Projekte verliert „Brain-Verbindung“ die Vollmacht sofort.');
	await expect(page.getByTestId('bm-confirm-go')).toHaveText('Projektumfang jetzt ändern');
	// The same confirmation in all four looks (each reload rebuilds it).
	await lookMatrix('bestaetigung', async () => {
		await grantOption('Brain-Verbindung').check();
		await projectBox(gamma.name).uncheck();
		await pickProjects(alpha.name);
		await save().click();
		await expect(page.getByTestId('bm-confirm')).toBeVisible();
		await expect(page.getByTestId('bm-diff-warning')).toContainText('verliert „Brain-Verbindung“ die Vollmacht sofort');
	});

	// Cancel: nothing changed, neither in the API nor on the connections.
	await openPage();
	await grantOption('Brain-Verbindung').check();
	await projectBox(gamma.name).uncheck();
	await save().click();
	await page.getByTestId('bm-confirm-cancel').click();
	await expect(page.getByTestId('bm-confirm')).toHaveCount(0);
	await expect(save()).toBeFocused();
	expect(sortedIDs((await apiMandate(brain))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect(sortedIDs((await apiMandate(codex))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect((await mandateOf(codex)).active).toBe(true);
	expect((await mandateOf(brain)).active).toBe(true);
});

test('protocol: real decisions of both mandated connections show up with the deciding connection, quote and card link; outside its projects a connection decides nothing', async () => {
	// Codex and brain both hold beta and gamma now; alpha belongs to neither mandate.
	reviews = [
		await newReview(beta, 'Angebot prüfen'), await newReview(gamma, 'Release-Notes prüfen'),
		await newReview(beta, 'Letzte Freigabe'), await newReview(alpha, 'Außerhalb der Vollmacht'), await newReview(beta, 'Zweite Freigabe')
	];
	await mcp(brain.token, 'decide_review', { taskID: reviews[0].taskID, decision: 'accept', quote: 'Lino: ja, das Angebot passt, nimm es an.' });
	await mcp(codex.token, 'decide_review', { taskID: reviews[1].taskID, decision: 'request_changes', note: 'Bitte die Beispiele ergänzen.', quote: 'Lino: die Release-Notes brauchen noch Beispiele.' });
	for (const c of [codex, brain]) {
		const outside = await mcpCall(mcpApi, c.token, 'decide_review', { taskID: reviews[3].taskID, decision: 'accept', quote: 'Lino: ja.' });
		expect(outside.isError, outside.text).toBe(true);
		expect(outside.text).toContain('outside_brain_mandate');
	}
	await openPage();
	await expect(entry(brain).getByTestId('bm-used')).not.toHaveText('Noch nie benutzt');
	await expect(entry(codex).getByTestId('bm-used')).not.toHaveText('Noch nie benutzt');
	const items = page.getByTestId('bm-audit-item');
	await expect(items).toHaveCount(2);
	await expect(items.first()).toContainText('Änderungen angefordert');
	await expect(items.first()).toContainText('Lino: die Release-Notes brauchen noch Beispiele.');
	await expect(items.first()).toContainText(gamma.name);
	await expect(items.first().getByTestId('bm-audit-via')).toHaveText('über „Codex-Verbindung“');
	await expect(items.nth(1)).toContainText('Review angenommen');
	await expect(items.nth(1)).toContainText('Lino: ja, das Angebot passt, nimm es an.');
	await expect(items.nth(1).getByTestId('bm-audit-via')).toHaveText('über „Brain-Verbindung“');
	// The entry leads to the card.
	await items.nth(1).getByTestId('bm-audit-card').click();
	await expect(page).toHaveURL(new RegExp(`card=task:${reviews[0].taskID}`, 'i'));
	await page.keyboard.press('Escape');
	await expect(page).not.toHaveURL(/card=/);
	await expect(page.getByTestId('bm-audit')).toBeVisible();
	await lookMatrix('aktiv-protokoll');
});

test('(e) revoke one connection with confirmation: cancel keeps it, confirming ends only that one; its token can no longer decide, the other still can', async () => {
	await openPage();
	await entry(brain).getByTestId('bm-revoke').click();
	const ask = entry(brain).getByTestId('bm-revoke-confirm');
	await expect(ask).toContainText('Vollmacht von „Brain-Verbindung“ widerrufen?');
	await expect(ask).toContainText('Wirkt sofort für die nächste Entscheidung dieser Verbindung');
	await expect(ask).toBeFocused();
	// Only this entry asks.
	await expect(page.getByTestId('bm-revoke-confirm')).toHaveCount(1);
	await page.keyboard.press('Escape');
	await expect(ask).toHaveCount(0);
	await expect(entry(brain).getByTestId('bm-revoke')).toBeFocused();
	expect((await apiMandate(brain))!.active).toBe(true);

	await entry(brain).getByTestId('bm-revoke').click();
	await entry(brain).getByTestId('bm-revoke-go').click();
	await expect(message()).toContainText('Vollmacht von „Brain-Verbindung“ widerrufen');
	await expect(entry(brain)).toHaveAttribute('data-status', 'revoked');
	await expect(entry(brain).getByTestId('bm-status')).toHaveText('Widerrufen');
	await expect(entry(brain).getByTestId('bm-was-revoked')).toContainText('Brain-Verbindung');
	await expect(entry(codex)).toHaveAttribute('data-status', 'active');
	await expect(page.getByTestId('bm-list')).toBeFocused();
	// The protocol of the earlier decisions stays.
	await expect(page.getByTestId('bm-audit-item')).toHaveCount(2);
	const gone = await apiMandate(brain);
	expect(gone?.active).toBe(false);
	expect(gone?.revokedAt).toBeTruthy();
	expect((await apiMandate(codex))!.active).toBe(true);
	expect((await mandateOf(brain)).active).toBe(false);
	expect((await mandateOf(codex)).active).toBe(true);

	// The real MCP call with the old token against a foreign review (the person's), with the mandatory quote.
	const denied = await mcpCall(mcpApi, brain.token, 'decide_review', { taskID: reviews[2].taskID, decision: 'accept', quote: 'Lino: ja, annehmen.' });
	expect(denied.isError, denied.text).toBe(true);
	expect(denied.text).toContain('brain_mandate_required');
	const statusOf = async (id: string) => ((await (await page.request.get(`/v1/tasks/${id}/context`)).json()) as { task: { status: string } }).task.status;
	expect(await statusOf(reviews[2].taskID)).toBe('in_review');
	// The other connection still decides in its projects.
	const ok = await mcpCall(mcpApi, codex.token, 'decide_review', { taskID: reviews[2].taskID, decision: 'accept', quote: 'Lino: ja, annehmen.' });
	expect(ok.isError, ok.text).toBe(false);
	expect(await statusOf(reviews[2].taskID)).toBe('done');
	await expect(entry(brain).getByTestId('bm-regrant')).toBeVisible();
	await lookMatrix('widerrufen');
});

test('(f) error: a connection revoked meanwhile gives a clear message, the list is refreshed and the choices stay; a revoked connection voids only its own mandate', async () => {
	const third = await connect('Dritte Verbindung');
	await openPage();
	await expect(page.getByTestId('bm-grant-option')).toHaveCount(3);
	await grantOption('Dritte Verbindung').check();
	await pickProjects(alpha.name);
	await expect(save()).toBeEnabled();
	// Another tab / device revokes the connection after the page was loaded.
	const revoked = await page.request.delete(`/oauth/grants/${third.grantID}`, json);
	expect(revoked.status(), await revoked.text()).toBeLessThan(300);
	await save().click();
	const error = page.getByTestId('bm-error');
	await expect(error).toHaveText('Diese Verbindung wurde zwischenzeitlich widerrufen. Wähle eine andere aktive Verbindung.');
	await expect(error).toHaveAttribute('role', 'alert');
	await expect(page.getByTestId('bm-grant-option')).toHaveCount(2);
	await expect(page.getByRole('radio', { checked: true })).toHaveCount(0);
	await expect(projectBox(alpha.name)).toBeChecked();
	await expect(save()).toBeDisabled();
	// Nothing was granted: still exactly the two earlier mandates.
	expect(await apiMandates()).toHaveLength(2);
	// Re-grant the revoked brain connection (a revoked mandate gives nobody power, so this is a plain grant).
	await entry(brain).getByTestId('bm-regrant').click();
	await expect(page.getByTestId('bm-form-title')).toHaveText('Vollmacht hinzufügen');
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox', { checked: true })).toHaveCount(0);
	await pickProjects(alpha.name);
	await save().click();
	await expect(message()).toContainText('Vollmacht erteilt');
	await expect(page.getByTestId('bm-error')).toHaveCount(0);
	await expect(entry(brain)).toHaveAttribute('data-status', 'active');
	expect(sortedIDs((await apiMandate(brain))!.projectIDs)).toEqual(sortedIDs([alpha.id]));
	// A mandate whose connection was revoked itself is shown as void; the other connection is not affected.
	const gone = await page.request.delete(`/oauth/grants/${codex.grantID}`, json);
	expect(gone.status()).toBeLessThan(300);
	await openPage();
	await expect(entry(codex)).toHaveAttribute('data-status', 'grant_revoked');
	await expect(entry(codex).getByTestId('bm-void')).toContainText('wirkt die Vollmacht nicht mehr');
	await expect(entry(codex).getByTestId('bm-status')).toHaveText('Verbindung widerrufen, Vollmacht wirkungslos');
	await expect(entry(brain)).toHaveAttribute('data-status', 'active');
	expect((await apiMandate(codex))!.active).toBe(false);
	expect((await apiMandate(brain))!.active).toBe(true);
	await expect(page.getByTestId('bm-grant-option')).toHaveCount(1);
});

test('(g) keyboard: connection and projects by Space, grant by Enter; "Projekte ändern" by keyboard; the confirmation takes focus, Escape cancels, Enter confirms', async () => {
	const spare = await connect('Ersatz-Verbindung');
	await openPage();
	const radio = grantOption('Ersatz-Verbindung');
	await radio.focus();
	await page.keyboard.press('Space');
	await expect(radio).toBeChecked();
	await page.getByTestId('bm-project-search').focus();
	await page.keyboard.type('Beta');
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox')).toHaveCount(1);
	await tabTo(projectBox(beta.name));
	await page.keyboard.press('Space');
	await expect(projectBox(beta.name)).toBeChecked();
	await save().focus();
	await page.keyboard.press('Enter');
	await expect(message()).toContainText('Vollmacht erteilt');
	const m = await apiMandate(spare);
	expect(m!.active).toBe(true);
	expect(sortedIDs(m!.projectIDs)).toEqual(sortedIDs([beta.id]));
	// The brain connection kept its own mandate next to it.
	expect(sortedIDs((await apiMandate(brain))!.projectIDs)).toEqual(sortedIDs([alpha.id]));

	// A change by keyboard, started from the list entry.
	await entry(spare).getByTestId('bm-edit').focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('bm-form-title')).toBeFocused();
	await expect(grantOption('Ersatz-Verbindung')).toBeChecked();
	await expect(projectBox(beta.name)).toBeChecked();
	await page.getByTestId('bm-project-search').focus();
	await page.keyboard.type('Gamma');
	await expect(page.getByTestId('bm-project-list').getByRole('checkbox')).toHaveCount(1);
	await tabTo(projectBox(gamma.name));
	await page.keyboard.press('Space');
	await save().focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('bm-confirm')).toBeFocused();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('bm-confirm')).toHaveCount(0);
	await expect(save()).toBeFocused();
	expect(sortedIDs((await apiMandate(spare))!.projectIDs)).toEqual(sortedIDs([beta.id]));
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('bm-confirm')).toBeFocused();
	await tabTo(page.getByTestId('bm-confirm-cancel'));
	await tabTo(page.getByTestId('bm-confirm-go'));
	await page.keyboard.press('Enter');
	await expect(message()).toContainText('Vollmacht geändert');
	expect(sortedIDs((await apiMandate(spare))!.projectIDs)).toEqual(sortedIDs([beta.id, gamma.id]));
	expect((await mandateOf(spare)).active).toBe(true);
	expect(sortedIDs((await mandateOf(brain)).projectIDs ?? [])).toEqual(sortedIDs([alpha.id]));
});

test('labels, live regions and layout: every control has a name; mobile and dark mode have no overflow', async () => {
	await openPage();
	for (const box of await page.getByTestId('bm-project-list').getByRole('checkbox').all()) await expect(box).toHaveAccessibleName(/\S/);
	for (const radio of await page.getByRole('radio').all()) await expect(radio).toHaveAccessibleName(/\S/);
	await expect(page.getByTestId('bm-project-search')).toHaveAccessibleName('Projekte suchen');
	await expect(message()).toHaveAttribute('aria-live', 'polite');
	// Every list button says which connection it acts on.
	for (const b of await page.getByTestId('bm-edit').all()) await expect(b).toHaveAccessibleName(/Projekte von „.+“ ändern/);
	for (const b of await page.getByTestId('bm-revoke').all()) await expect(b).toHaveAccessibleName(/Vollmacht von „.+“ widerrufen/);
	const small: Locator[] = [page.getByTestId('bm-save'), page.getByTestId('bm-revoke').first(), page.getByTestId('bm-edit').first()];
	await mobile();
	await noOverflow('final mobile');
	for (const l of small) if (await l.count()) expect((await l.boundingBox())!.height).toBeGreaterThanOrEqual(32);
	await theme('dark');
	await noOverflow('final dark mobile');
	await theme('light');
	await desktop();
});
