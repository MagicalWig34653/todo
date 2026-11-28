import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/card-draft.spec.ts --project=chromium
// Card A42C423B: the main "Aufgabe erstellen" button opens the large card window as a draft (not the quick-add dialog);
// "Anlegen" stores the card and keeps the window open on it, "Abbrechen" leaves nothing behind. Quick add stays on `q` and
// on Enter in the list. SHOTS_DIR keeps the picture sequence (light and dark).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = join(process.env.SHOTS_DIR ?? tmpdir(), 'card-draft');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
let projectID = '';
let columnID = '';

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const dialog = () => page.getByTestId('card-dialog');
const draft = () => page.getByTestId('card-draft');
const select = (name: string) => draft().getByRole('combobox', { name, exact: true });
const description = () => draft().getByRole('textbox', { name: 'Beschreibung', exact: true });
const due = () => draft().locator('input[type="date"][aria-label="Fälligkeit"]');
type ListedTask = { id: string; title: string; description: string; columnID?: string | null; labels?: string[] };
const tasks = async () => (await (await page.request.get(`/v1/tasks?projectID=${projectID}&includeLabels=true`)).json()) as ListedTask[];
const shot = (name: string) => page.screenshot({ path: join(SHOTS, `${name}.png`) });

async function openProject() {
	await page.getByTestId('project-item').getByRole('button', { name: 'Entwurfsprojekt', exact: true }).first().click();
	await expect(page.getByTestId('task-heading')).toHaveText('Entwurfsprojekt');
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	mkdirSync(SHOTS, { recursive: true });
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Entwurf Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'Entwurfsprojekt' })).id;
	await post('/v1/projects', { name: 'Anderes Projekt' });
	await post(`/v1/projects/${projectID}/columns`, { name: 'Offen' });
	columnID = (await post<{ id: string }>(`/v1/projects/${projectID}/columns`, { name: 'In Arbeit' })).id;
	await post('/v1/labels', { name: 'Design' });
});
test.afterAll(async () => {
	await page?.context().close();
});

for (const scheme of ['light', 'dark'] as const) {
	test(`main button opens the card as a draft, "Anlegen" stores it and keeps the card open (${scheme})`, async () => {
		await page.emulateMedia({ colorScheme: scheme });
		await page.setViewportSize({ width: 1280, height: 860 });
		await page.goto('/');
		await openProject();
		await shot(`1-vor-klick-${scheme}`);

		await page.getByTestId('create-task-open').click();
		await expect(dialog()).toBeVisible();
		await expect(draft()).toBeVisible();
		// Not the quick-add dialog behind the main button any more.
		await expect(page.getByTestId('quick-add')).toHaveCount(0);
		const title = draft().getByLabel('Titel', { exact: true });
		await expect(title).toBeFocused();
		// The current project is preselected; every field of the full card is there.
		await expect(select('Projekt')).toHaveValue(projectID);
		for (const field of ['Spalte', 'Priorität']) await expect(select(field)).toBeVisible();
		await expect(description()).toBeVisible();
		await expect(due()).toBeVisible();
		await expect(draft().getByRole('checkbox', { name: 'Design' })).toBeVisible();
		await expect(draft().getByTestId('draft-files')).toBeAttached();

		const name = `Logo entwerfen ${scheme}`;
		await title.fill(name);
		await description().fill('**Varianten** für das Logo\n\n- hell\n- dunkel');
		await select('Spalte').selectOption({ label: 'In Arbeit' });
		await select('Priorität').selectOption({ label: 'Hoch' });
		await due().fill('2027-03-15');
		await draft().getByRole('checkbox', { name: 'Design' }).check();
		await draft().getByTestId('draft-files').setInputFiles({ name: 'skizze.png', mimeType: 'image/png', buffer: PNG_1X1 });
		await expect(draft().getByTestId('draft-file')).toHaveText(/skizze\.png/);
		await shot(`2-entwurf-offen-${scheme}`);

		await draft().getByRole('button', { name: 'Anlegen' }).click();
		// The window stays open and now shows the stored card (its own URL, no draft form any more).
		await expect(page).toHaveURL(/[?&]card=task:[A-Za-z0-9-]+/);
		await expect(draft()).toHaveCount(0);
		await expect(dialog()).toBeVisible();
		await expect(dialog().getByRole('textbox', { name: 'Titel der Aufgabe' })).toHaveValue(name);
		await expect(dialog().getByTestId('attachment').first()).toBeVisible();
		await shot(`3-nach-anlegen-${scheme}`);

		const id = new URL(page.url()).searchParams.get('card')!.split(':')[1]!;
		const stored = (await tasks()).find((t) => t.id === id)!;
		expect(stored).toMatchObject({ title: name, description: '**Varianten** für das Logo\n\n- hell\n- dunkel', columnID, labels: ['Design'] });
		const planning = await (await page.request.get(`/v1/planning/tasks/${id}`)).json();
		expect(planning.priority).toBe(3);
		expect(planning.dueAt).toMatch(/^2027-03-1[45]T/);
		const attachments = (await (await page.request.get(`/v1/tasks/${id}/attachments`)).json()) as { filename: string }[];
		expect(attachments.map((a) => a.filename)).toEqual(['skizze.png']);

		await page.keyboard.press('Escape');
		await expect(dialog()).toHaveCount(0);
	});

	test(`"Abbrechen" closes the draft and creates nothing (${scheme})`, async () => {
		await page.emulateMedia({ colorScheme: scheme });
		const before = (await tasks()).length;
		await page.getByTestId('create-task-open').click();
		await expect(draft()).toBeVisible();
		await draft().getByLabel('Titel', { exact: true }).fill('Verworfener Entwurf');
		await description().fill('soll nirgends auftauchen');
		await draft().getByTestId('draft-files').setInputFiles({ name: 'weg.png', mimeType: 'image/png', buffer: PNG_1X1 });
		await draft().getByRole('button', { name: 'Abbrechen' }).click();
		await expect(dialog()).toHaveCount(0);
		await expect(page).not.toHaveURL(/card=/);
		await expect(page.getByText('Verworfener Entwurf')).toHaveCount(0);
		await shot(`4-nach-abbrechen-${scheme}`);
		expect((await tasks()).length).toBe(before);
		expect((await tasks()).some((t) => t.title === 'Verworfener Entwurf')).toBe(false);
		// Reopening starts empty: nothing of the discarded draft is left.
		await page.getByTestId('create-task-open').click();
		await expect(draft().getByLabel('Titel', { exact: true })).toHaveValue('');
		await expect(description()).toHaveValue('');
		await expect(draft().getByTestId('draft-file')).toHaveCount(0);
		await page.keyboard.press('Escape');
		await expect(dialog()).toHaveCount(0);
		expect((await tasks()).length).toBe(before);
	});
}

test('phone: the "+" in the header opens the same draft', async () => {
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.getByTestId('fab').click();
	await expect(draft()).toBeVisible();
	await expect(page.getByTestId('quick-add')).toHaveCount(0);
	await draft().getByRole('button', { name: 'Abbrechen' }).click();
	await expect(dialog()).toHaveCount(0);
	await page.setViewportSize({ width: 1280, height: 860 });
});

test('quick add stays: Enter in the list creates a task, `q` still opens the quick-add dialog', async () => {
	await page.goto('/');
	await openProject();
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: 'Liste' }).click();
	await page.keyboard.press('Escape');
	const row = page.getByRole('textbox', { name: 'Aufgabe hinzufügen in In Arbeit' });
	await row.fill('Schnell per Enter');
	await row.press('Enter');
	await expect(page.getByTestId('task-item').filter({ hasText: 'Schnell per Enter' })).toBeVisible();
	await expect(row).toHaveValue('');
	expect((await tasks()).find((t) => t.title === 'Schnell per Enter')?.columnID).toBe(columnID);
	await expect(dialog()).toHaveCount(0);

	await page.locator('body').click({ position: { x: 5, y: 400 } });
	await page.keyboard.press('q');
	const input = page.getByTestId('quick-add').getByLabel('Titel', { exact: true });
	await expect(input).toBeFocused();
	await input.fill('Schnell per Kürzel');
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('quick-add-added')).toContainText('Schnell per Kürzel');
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('quick-add')).toHaveCount(0);
	expect((await tasks()).some((t) => t.title === 'Schnell per Kürzel')).toBe(true);
});
