import { expect, test, type Locator, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/pipeline-settings.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card B926E7D8 (pipeline stage 2, docs/PLAN-PIPELINE-STUFE-2.md section 1 and 7): the project settings "Pipeline". A person with the
// manage right switches steps on and off, sets model and effort per role, the number of fix rounds and the waiting-approval
// notification; saving sends the revision, a conflict explains itself and reloads. Everyone else only sees the values.
// Everything runs against the real backend; the effect is checked through GET/PATCH /v1/projects/{id}/pipeline-settings.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/pipeline-stufe-2');
test.describe.configure({ mode: 'serial' });
let owner: Page;
let guest: Page;
let projectID = '';
let readOnlyID = '';
const json = { headers: { 'Content-Type': 'application/json' } };

interface Settings {
	revision: number;
	steps: Record<string, boolean>;
	roles: Record<string, { model?: string | null; effort?: string | null }>;
	maxFixRounds: number;
	notifyOnWaitingApproval: boolean;
	history: { summary: string; actorLabel?: string }[];
}
const read = async (id = projectID) => (await (await owner.request.get(`/v1/projects/${id}/pipeline-settings`)).json()) as Settings;
const patch = (page: Page, id: string, data: unknown) => page.request.patch(`/v1/projects/${id}/pipeline-settings`, { ...json, data });

const dialog = (page: Page) => page.getByTestId('pipeline-settings-dialog');
const feedback = (page: Page) => dialog(page).getByTestId('pipeline-settings-feedback');
const stepBox = (page: Page, name: string) => dialog(page).getByRole('checkbox', { name, exact: true });
const model = (page: Page, role: string) => dialog(page).getByLabel(`Modell ${role}`, { exact: true });
const effort = (page: Page, role: string) => dialog(page).getByLabel(`Effort ${role}`, { exact: true });
const rounds = (page: Page) => dialog(page).getByLabel('Höchstzahl der Fix-Runden');
const notify = (page: Page) => dialog(page).getByRole('checkbox', { name: 'Benachrichtigen, wenn eine Freigabe wartet', exact: true });
const save = (page: Page) => dialog(page).getByRole('button', { name: 'Speichern', exact: true });
const history = (page: Page) => dialog(page).getByTestId('pipeline-settings-history');
const open = async (page: Page, id: string) => {
	await page.goto(`/project/${id}/pipeline`);
	await expect(dialog(page)).toBeVisible();
	await expect(dialog(page).getByTestId('pipeline-settings')).toBeVisible();
	await expect(dialog(page).getByTestId('pipeline-settings-loading')).toHaveCount(0);
};
/** Counts the PATCH requests the browser sends while `action` runs. */
async function patchesSent(page: Page, action: () => Promise<unknown>): Promise<number> {
	let count = 0;
	const listener = (r: { url(): string; method(): string }) => {
		if (r.method() === 'PATCH' && r.url().endsWith('/pipeline-settings')) count++;
	};
	page.on('request', listener);
	await action();
	await page.waitForTimeout(500);
	page.off('request', listener);
	return count;
}
const noOverflow = async (page: Page, label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog(page).getByTestId('pipeline-settings').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: dialog content overflows`).toBeLessThanOrEqual(0);
};
const shoots = () => test.info().project.name === 'chromium';

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	owner = await signedInPage(browser, 'Pipeline Eigentümer');
	const invite = (await (await owner.request.post('/v1/invitations', { ...json, data: {} })).json()) as { token: string };
	guest = await signedInPage(browser, 'Pipeline Gast', invite.token);
	const guestID = ((await (await guest.request.get('/v1/me')).json()) as { id: string }).id;
	const make = async (name: string) => ((await (await owner.request.post('/v1/projects', { ...json, data: { name } })).json()) as { id: string }).id;
	projectID = await make('Pipelineprojekt');
	readOnlyID = await make('Gemeinsames Projekt');
	const grant = await owner.request.put(`/v1/projects/${readOnlyID}/grants`, { ...json, data: { principalType: 'person', principalID: guestID, role: 'edit' } });
	expect(grant.ok(), await grant.text()).toBeTruthy();
	await guest.reload();
});
test.afterAll(async () => {
	await owner?.context().close();
	await guest?.context().close();
});

test('the project menu opens the settings; the defaults are all steps on, no model, effort Standard, three rounds, notification on', async () => {
	await owner.setViewportSize({ width: 1280, height: 900 });
	await owner.goto(`/project/${projectID}`);
	await owner.getByTestId('project-more').click();
	await owner.getByTestId('pipeline-settings-open').click();
	await expect(dialog(owner)).toBeVisible();
	await expect(owner).toHaveURL(new RegExp(`/project/${projectID}/pipeline$`, 'i'));
	await expect(dialog(owner).getByRole('heading', { name: /Pipeline/ }).first()).toBeVisible();
	for (const name of ['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Tester', 'Review']) await expect(stepBox(owner, name)).toBeChecked();
	for (const role of ['Planer', 'Entwickler', 'Tester', 'Reviewer']) {
		await expect(model(owner, role)).toHaveValue('');
		await expect(effort(owner, role)).toHaveValue('');
		await expect(effort(owner, role).locator('option:checked')).toHaveText('Standard');
	}
	await expect(rounds(owner)).toHaveValue('3');
	await expect(notify(owner)).toBeChecked();
	await expect(history(owner)).toContainText('Noch keine Änderungen');
	await expect(save(owner)).toBeEnabled();
	const server = await read();
	expect(server.revision).toBe(0);
	// Escape closes the dialog and the URL goes back to the project.
	await owner.keyboard.press('Escape');
	await expect(dialog(owner)).toHaveCount(0);
	await expect(owner).toHaveURL(new RegExp(`/project/${projectID}$`, 'i'));
});

test('saving without a change sends nothing', async () => {
	await open(owner, projectID);
	expect(await patchesSent(owner, () => save(owner).click())).toBe(0);
	await expect(feedback(owner)).toContainText('Nichts geändert');
	expect((await read()).revision).toBe(0);
});

test('switching a step off, choosing model and effort, rounds and notification are saved with one request', async () => {
	await open(owner, projectID);
	await stepBox(owner, 'Tester').uncheck();
	await model(owner, 'Entwickler').fill('sonnet');
	await effort(owner, 'Entwickler').selectOption('xhigh');
	await model(owner, 'Planer').fill(' gpt-6.1-sol ');
	await rounds(owner).fill('5');
	await notify(owner).uncheck();
	expect(await patchesSent(owner, () => save(owner).click())).toBe(1);
	await expect(feedback(owner)).toContainText('Gespeichert');
	await expect(feedback(owner)).toHaveAttribute('aria-live', 'polite');
	const server = await read();
	expect(server.revision).toBe(1);
	expect(server.steps).toMatchObject({ tester: false, planner: true, developer: true, approval: true, validation: true, review: true });
	expect(server.roles.developer).toMatchObject({ model: 'sonnet', effort: 'xhigh' });
	expect(server.roles.planner?.model).toBe('gpt-6.1-sol');
	expect(server.roles.tester?.model ?? null).toBeNull();
	expect(server.maxFixRounds).toBe(5);
	expect(server.notifyOnWaitingApproval).toBe(false);
	// The history shows who changed what, in German.
	await expect(history(owner)).not.toContainText('Noch keine Änderungen');
	await expect(history(owner).getByTestId('pipeline-settings-event').first()).toContainText('Pipeline Eigentümer');
	await expect(history(owner).getByTestId('pipeline-settings-event').first()).toContainText('Tester');
});

test('a reload shows the saved values and no raw keys in the history', async () => {
	await open(owner, projectID);
	await expect(stepBox(owner, 'Tester')).not.toBeChecked();
	await expect(stepBox(owner, 'Entwickler')).toBeChecked();
	await expect(model(owner, 'Entwickler')).toHaveValue('sonnet');
	await expect(effort(owner, 'Entwickler').locator('option:checked')).toHaveText('Sehr hoch');
	await expect(model(owner, 'Planer')).toHaveValue('gpt-6.1-sol');
	await expect(rounds(owner)).toHaveValue('5');
	await expect(notify(owner)).not.toBeChecked();
	const text = (await history(owner).textContent()) ?? '';
	expect(text).not.toMatch(/steps\.|roles\.|maxFixRounds|notifyOnWaitingApproval/);
});

test('an invalid model or round count is explained and nothing is sent', async () => {
	await open(owner, projectID);
	await model(owner, 'Tester').fill('zwei Wörter');
	await rounds(owner).fill('11');
	expect(await patchesSent(owner, () => save(owner).click())).toBe(0);
	await expect(model(owner, 'Tester')).toHaveAttribute('aria-invalid', 'true');
	await expect(rounds(owner)).toHaveAttribute('aria-invalid', 'true');
	await expect(dialog(owner).getByRole('alert').first()).toBeVisible();
	await expect(dialog(owner)).toContainText('Buchstaben, Ziffern');
	await expect(dialog(owner)).toContainText('0 und 10');
	await model(owner, 'Tester').fill('haiku');
	await rounds(owner).fill('0');
	await expect(model(owner, 'Tester')).not.toHaveAttribute('aria-invalid', 'true');
	expect(await patchesSent(owner, () => save(owner).click())).toBe(1);
	await expect(feedback(owner)).toContainText('Gespeichert');
	const server = await read();
	expect(server.maxFixRounds).toBe(0);
	expect(server.roles.tester?.model).toBe('haiku');
});

test('the server refuses an invalid model with a German message and keeps the typed values', async () => {
	await open(owner, projectID);
	await owner.route('**/pipeline-settings', (r) => (r.request().method() === 'PATCH' ? r.fulfill({ status: 400, json: { error: true, reason: 'invalid_model' } }) : r.continue()));
	await model(owner, 'Planer').fill('opus');
	await save(owner).click();
	await expect(feedback(owner)).toContainText('Modell');
	await expect(feedback(owner)).not.toContainText('invalid_model');
	await expect(model(owner, 'Planer')).toHaveValue('opus');
	await owner.unroute('**/pipeline-settings');
});

test('clearing a model or an effort goes back to the default', async () => {
	await open(owner, projectID);
	await model(owner, 'Entwickler').fill('');
	await effort(owner, 'Entwickler').selectOption('');
	await save(owner).click();
	await expect(feedback(owner)).toContainText('Gespeichert');
	const server = await read();
	expect(server.roles.developer?.model ?? null).toBeNull();
	expect(server.roles.developer?.effort ?? null).toBeNull();
	expect(server.roles.tester?.model).toBe('haiku');
});

test('a change made elsewhere in the meantime: message, current values loaded, the next save works', async () => {
	await open(owner, projectID);
	const before = await read();
	await rounds(owner).fill('7');
	// Someone else saves first (same revision the dialog still holds).
	const other = await patch(owner, projectID, { revision: before.revision, maxFixRounds: 2, steps: { review: false } });
	expect(other.status(), await other.text()).toBeLessThan(300);
	await save(owner).click();
	await expect(feedback(owner)).toContainText('inzwischen');
	await expect(feedback(owner)).not.toContainText('revision_conflict');
	await expect(rounds(owner)).toHaveValue('2');
	await expect(stepBox(owner, 'Review')).not.toBeChecked();
	expect((await read()).revision).toBe(before.revision + 1);
	await rounds(owner).fill('7');
	await save(owner).click();
	await expect(feedback(owner)).toContainText('Gespeichert');
	expect((await read()).maxFixRounds).toBe(7);
});

test('the keyboard saves: Enter in the field sends the form, focus stays visible and the result is announced', async () => {
	await open(owner, projectID);
	await rounds(owner).focus();
	await owner.keyboard.press('Control+a');
	await owner.keyboard.type('4');
	expect(await patchesSent(owner, () => owner.keyboard.press('Enter'))).toBe(1);
	await expect(feedback(owner)).toContainText('Gespeichert');
	await expect(rounds(owner)).toBeFocused();
	expect((await read()).maxFixRounds).toBe(4);
});

test('a person without the manage right only sees the values; the server refuses a change anyway', async () => {
	// The owner prepares values the guest can read.
	const current = await read(readOnlyID);
	expect((await patch(owner, readOnlyID, { revision: current.revision, steps: { validation: false }, roles: { reviewer: { model: 'haiku', effort: 'low' } }, maxFixRounds: 2 })).status()).toBeLessThan(300);
	await guest.setViewportSize({ width: 1280, height: 900 });
	await open(guest, readOnlyID);
	await expect(dialog(guest).getByTestId('pipeline-settings-readonly')).toContainText('Verwaltungsrecht');
	await expect(save(guest)).toHaveCount(0);
	await expect(stepBox(guest, 'Validierung')).not.toBeChecked();
	await expect(stepBox(guest, 'Validierung')).toBeDisabled();
	await expect(stepBox(guest, 'Tester')).toBeChecked();
	await expect(model(guest, 'Reviewer')).toHaveValue('haiku');
	await expect(model(guest, 'Reviewer')).toBeDisabled();
	await expect(effort(guest, 'Reviewer').locator('option:checked')).toHaveText('Niedrig');
	await expect(effort(guest, 'Reviewer')).toBeDisabled();
	await expect(rounds(guest)).toHaveValue('2');
	await expect(rounds(guest)).toBeDisabled();
	await expect(notify(guest)).toBeDisabled();
	// Hiding is not the protection: the backend refuses (edit is not enough).
	const refused = await patch(guest, readOnlyID, { revision: (await read(readOnlyID)).revision, maxFixRounds: 9 });
	expect(refused.status()).toBe(403);
	expect((await read(readOnlyID)).maxFixRounds).toBe(2);
});

test('a server refusal for a missing right is explained (the right was withdrawn while the dialog was open)', async () => {
	await open(owner, projectID);
	await owner.route('**/pipeline-settings', (r) => (r.request().method() === 'PATCH' ? r.fulfill({ status: 403, json: { error: true, reason: 'forbidden' } }) : r.continue()));
	await rounds(owner).fill('6');
	await save(owner).click();
	await expect(feedback(owner)).toContainText('Berechtigung');
	await expect(rounds(owner)).toHaveValue('6');
	await owner.unroute('**/pipeline-settings');
});

test('a server without the endpoint (404) says so instead of showing an empty form', async () => {
	const url = `**/v1/projects/${projectID}/pipeline-settings`;
	await owner.route(url, (r) => r.fulfill({ status: 404, json: { error: true, reason: 'Not Found' } }));
	await owner.goto(`/project/${projectID}/pipeline`);
	await expect(dialog(owner)).toContainText('noch nicht');
	await expect(save(owner)).toHaveCount(0);
	await owner.unroute(url);
});

for (const [label, size] of [['desktop', { width: 1280, height: 900 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: light and dark screenshots without horizontal scrolling`, async () => {
		test.skip(!shoots(), 'the pictures come from the Chromium run');
		await owner.setViewportSize(size);
		const server = await read();
		// A believable state: tester off, models set, two history entries.
		await patch(owner, projectID, { revision: server.revision, steps: { tester: false, review: true }, roles: { developer: { model: 'sonnet', effort: 'high' }, reviewer: { model: 'haiku', effort: 'low' }, planner: { model: 'gpt-6.1-sol', effort: 'medium' } }, maxFixRounds: 3, notifyOnWaitingApproval: true });
		for (const scheme of ['light', 'dark'] as const) {
			await owner.emulateMedia({ colorScheme: scheme });
			await open(owner, projectID);
			await expect(history(owner)).toBeVisible();
			await noOverflow(owner, `${label} ${scheme}`);
			await owner.waitForTimeout(300);
			await owner.screenshot({ path: `${SHOTS}/einstellungen-${label}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });
			await save(owner).scrollIntoViewIfNeeded();
			await expect(save(owner)).toBeInViewport();
			await owner.screenshot({ path: `${SHOTS}/einstellungen-${label}-${scheme === 'light' ? 'hell' : 'dunkel'}-ende.png` });
			await open(guest, readOnlyID);
			await noOverflow(guest, `${label} ${scheme} read-only`);
			await guest.emulateMedia({ colorScheme: scheme });
			await guest.setViewportSize(size);
			await guest.waitForTimeout(300);
			await guest.screenshot({ path: `${SHOTS}/einstellungen-nur-lesen-${label}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });
		}
		await owner.emulateMedia({ colorScheme: 'light' });
		await guest.emulateMedia({ colorScheme: 'light' });
	});
}

test('the dialog is a dialog: labelled, focus moves in and returns to the menu on close', async () => {
	await owner.setViewportSize({ width: 1280, height: 900 });
	await owner.goto(`/project/${projectID}`);
	await owner.getByTestId('project-more').click();
	await owner.getByTestId('pipeline-settings-open').click();
	const box: Locator = owner.getByRole('dialog', { name: /Pipeline/ });
	await expect(box).toBeVisible();
	const focusInside = await owner.evaluate(() => !!document.activeElement?.closest('[role="dialog"]'));
	expect(focusInside).toBe(true);
	await owner.keyboard.press('Escape');
	await expect(box).toHaveCount(0);
});
