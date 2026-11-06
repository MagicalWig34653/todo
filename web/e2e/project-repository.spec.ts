import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/project-repository.spec.ts --project=chromium
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Repo Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

async function createProject(name: string, repository?: string) {
	const r = await page.request.post('/v1/projects', { ...json, data: { name } });
	const project = (await r.json()) as { id: string; name: string };
	// Management mode shows the overview tab (the repository line lives there).
	const prefs = (await (await page.request.get(`/v1/me/project-prefs/${project.id}`)).json()) as { revision: number };
	const mode = await page.request.patch(`/v1/me/project-prefs/${project.id}`, { ...json, data: { revision: prefs.revision, mode: 'management' } });
	expect(mode.ok(), `mode ${mode.status()}`).toBeTruthy();
	if (repository) {
		const bound = await page.request.put(`/v1/projects/${project.id}/sync`, { ...json, data: { repository } });
		expect(bound.ok()).toBeTruthy();
	}
	return project;
}

async function openOverview(name: string) {
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name, exact: true }).first().click();
	await page.getByTestId('project-tab-overview').click();
}

test('shows the bound repository as a link and the empty state for an unbound project', async () => {
	await createProject('Mit Repo', 'github.com/example/kueche');
	await createProject('Ohne Repo');
	await openOverview('Mit Repo');
	const name = page.getByTestId('cc-sync-head').getByTestId('repo-name');
	await expect(name).toHaveText('github.com/example/kueche');
	await expect(name).toHaveAttribute('href', 'https://github.com/example/kueche');
	await expect(name).toHaveAttribute('rel', /noopener/);

	await openOverview('Ohne Repo');
	await expect(page.getByTestId('cc-sync-head').getByTestId('repo-none')).toHaveText('Kein Repository verknüpft.');
});

test('free repository keys are plain text; load failure shows an error; fits 320 px', async () => {
	const free = await createProject('Freier Schluessel', 'meinschluessel');
	await openOverview('Freier Schluessel');
	const name = page.getByTestId('cc-sync-head').getByTestId('repo-name');
	await expect(name).toHaveText('meinschluessel');
	await expect(name).not.toHaveAttribute('href', /.+/);

	await page.setViewportSize({ width: 320, height: 700 });
	await page.route(`**/v1/projects/${free.id}/sync`, (route) => route.fulfill({ status: 500, contentType: 'application/json', body: '{"error":true}' }));
	await page.reload();
	await expect(page.getByTestId('repo-error')).toHaveText('Repository konnte nicht geladen werden.');
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
	await page.unroute(`**/v1/projects/${free.id}/sync`);
});

test('lists several bindings, adds one with errors, and unbinds with a confirmation', async () => {
	const p = await createProject('Mehrfach', 'github.com/example/eins');
	await page.setViewportSize({ width: 1280, height: 800 });
	await openOverview('Mehrfach');
	const head = page.getByTestId('cc-sync-head');
	await expect(head.getByTestId('repo-row')).toHaveCount(1);

	// Add: empty input first, then a valid repository.
	await head.getByTestId('repo-add').click();
	await head.getByTestId('repo-add-submit').click();
	await expect(head.getByTestId('repo-form-error')).toHaveText('Bitte ein Repository eingeben.');
	await head.getByTestId('repo-add-input').fill('github.com/example/zwei');
	await head.getByTestId('repo-add-submit').click();
	await expect(head.getByTestId('repo-status')).toHaveText('Repository hinzugefügt.');
	await expect(head.getByTestId('repo-row')).toHaveCount(2);
	await expect(head.getByTestId('repo-row').nth(1).getByTestId('repo-name')).toHaveText('github.com/example/zwei');
	await expect(head.getByTestId('repo-row').nth(1).getByTestId('sync-chip')).toBeVisible();

	// A repository already bound to another project: readable error.
	const fremd = await createProject('Fremd', 'github.com/example/belegt');
	expect(fremd.id).not.toBe(p.id);
	await head.getByTestId('repo-add').click();
	await head.getByTestId('repo-add-input').fill('github.com/example/belegt');
	await head.getByTestId('repo-add-submit').click();
	await expect(head.getByTestId('repo-form-error')).toHaveText('Dieses Repository ist bereits mit einem anderen Projekt verknüpft.');
	await head.getByRole('button', { name: 'Abbrechen' }).click();

	// The detail panel shares the data; the threshold can be changed with two bindings.
	await page.getByTestId('cc-sync-toggle').click();
	await head.getByTestId('sync-threshold').fill('7');
	await head.getByTestId('sync-threshold-save').click();
	await expect(head.getByTestId('sync-saved')).toBeVisible();

	// Unbind with a confirmation; cancel keeps the row.
	await head.getByTestId('repo-row').first().getByTestId('repo-remove').click();
	await expect(head.getByTestId('repo-confirm')).toContainText('github.com/example/eins');
	await head.getByTestId('repo-confirm').getByRole('button', { name: 'Abbrechen' }).click();
	await expect(head.getByTestId('repo-row')).toHaveCount(2);
	await head.getByTestId('repo-row').first().getByTestId('repo-remove').click();
	await head.getByTestId('repo-remove-yes').click();
	await expect(head.getByTestId('repo-status')).toHaveText('Repository gelöst.');
	await expect(head.getByTestId('repo-row')).toHaveCount(1);
	await expect(head.getByTestId('repo-name')).toHaveText('github.com/example/zwei');

	const left = (await (await page.request.get(`/v1/projects/${p.id}/bindings`)).json()) as unknown[];
	expect(left).toHaveLength(1);

	// Last binding removed: empty state.
	await head.getByTestId('repo-remove').click();
	await head.getByTestId('repo-remove-yes').click();
	await expect(head.getByTestId('repo-none')).toBeVisible();
});

test('hides add and unbind without the edit right; fits 320 px with several bindings', async () => {
	const p = await createProject('Schmal', 'github.com/example/sehr-langer-name-fuer-den-schmalen-bildschirm');
	const more = await page.request.put(`/v1/projects/${p.id}/sync`, { ...json, data: { repository: 'zweiterschluessel' } });
	expect(more.ok()).toBeTruthy();
	await page.setViewportSize({ width: 1280, height: 800 });
	await openOverview('Schmal');
	await page.setViewportSize({ width: 320, height: 700 });
	const head = page.getByTestId('cc-sync-head');
	await expect(head.getByTestId('repo-row')).toHaveCount(2);
	await head.getByTestId('repo-remove').first().click();
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);

	await page.route(`**/v1/projects/${p.id}/visibility*`, (route) =>
		route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ role: 'view' }) })
	);
	await page.reload();
	await expect(head.getByTestId('repo-row')).toHaveCount(2);
	await expect(head.getByTestId('repo-remove')).toHaveCount(0);
	await expect(head.getByTestId('repo-add')).toHaveCount(0);
	await page.unroute(`**/v1/projects/${p.id}/visibility*`);
});
