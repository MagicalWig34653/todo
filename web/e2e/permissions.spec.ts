import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/permissions.spec.ts --project=chromium
// Two accounts: A (admin, owner) shares projects with B and the permission UI is checked from both sides.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test.describe.configure({ mode: 'serial' });
let a: Page;
let b: Page;
let bID = '';

async function virtualAuthenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}
async function api(page: Page, method: 'post' | 'put' | 'get', url: string, data?: unknown) {
	const res = await page.request[method](url, method === 'get' ? undefined : { data: data ?? {}, headers: { 'Content-Type': 'application/json' } });
	expect(res.ok(), `${method} ${url}: ${await res.text()}`).toBeTruthy();
	return res.status() === 204 ? null : res.json();
}
const sidebar = (p: Page) => p.getByRole('navigation', { name: 'Seitenleiste' });

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	a = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	await virtualAuthenticator(a);
	await a.goto('/setup');
	await a.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await a.getByLabel('Anzeigename').fill('Anna Eigentum');
	await a.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(a.getByTestId('account-menu')).toBeVisible();

	const { token } = (await api(a, 'post', '/v1/invitations')) as { token: string };
	b = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	await virtualAuthenticator(b);
	await b.goto(`/setup?token=${token}`);
	await b.getByLabel('Anzeigename').fill('Ben Gast');
	await b.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(b.getByTestId('account-menu')).toBeVisible();
	bID = ((await (await b.request.get('/v1/me')).json()) as { id: string }).id;
});
test.afterAll(async () => {
	await a?.context().close();
	await b?.context().close();
});

test('setup: A owns a project with a subproject', async () => {
	const parent = (await api(a, 'post', '/v1/projects', { name: 'Hausbau' })) as { id: string };
	await api(a, 'post', '/v1/projects', { name: 'Keller', parentID: parent.id });
	await a.reload();
	await sidebar(a).getByRole('button', { name: 'Hausbau', exact: true }).click();
	await expect(a.getByTestId('task-heading')).toHaveText('Hausbau');
});

test('the share button is visible in both modes and explains the own role', async () => {
	// Classic mode (default for new projects).
	await expect(a.getByTestId('share-open')).toBeVisible();
	await expect(a.getByTestId('share-count')).toHaveText('1');
	await expect(a.getByTestId('role-chip').first()).toHaveText(/Du: Eigentümer/);
	await a.getByTestId('display-menu').click();
	await a.getByTestId('mode-management').click();
	await a.keyboard.press('Escape');
	await expect(a.getByTestId('project-tabs')).toBeVisible();
	await expect(a.getByTestId('share-open')).toBeVisible();
	await a.getByTestId('display-menu').click();
	await a.getByTestId('mode-classic').click();
	await a.keyboard.press('Escape');
	await expect(a.getByTestId('share-open')).toBeVisible();
});

test('A shares read-only with B: shared section, disabled actions with explanation', async () => {
	await a.getByTestId('share-open').click();
	const dialog = a.getByTestId('share-dialog');
	await expect(dialog.getByTestId('owner-row')).toContainText('Anna Eigentum');
	await expect(dialog.getByTestId('role-explanations')).toBeAttached();
	await dialog.getByLabel('Konto-ID der Person').fill(bID);
	await dialog.getByLabel('Rolle', { exact: true }).selectOption('read');
	await expect(dialog.getByTestId('role-help-selected')).toContainText('Darf das Projekt und seine Aufgaben ansehen');
	await dialog.getByRole('button', { name: 'Hinzufügen', exact: true }).click();
	await expect(dialog.getByTestId('grant')).toContainText('Ben Gast');
	await expect(dialog.getByTestId('who-row').filter({ hasText: 'Ben Gast' })).toContainText('Lesen');
	await expect(dialog.getByTestId('grant-role')).toHaveValue('read');
	await a.keyboard.press('Escape');
	await expect(a.getByTestId('share-count')).toHaveText('2');

	await b.reload();
	const shared = sidebar(b).getByTestId('sidebar-shared');
	await expect(shared).toBeVisible();
	await expect(shared).toContainText('Mit mir geteilt');
	await expect(shared.getByTestId('shared-marker').first()).toContainText('Anna Eigentum');
	// Not listed under "Meine Projekte".
	await expect(sidebar(b).getByRole('region', { name: 'Meine Projekte' })).not.toContainText('Hausbau');
	await shared.getByRole('button', { name: /^Hausbau/ }).click();
	await expect(b.getByTestId('task-heading')).toHaveText('Hausbau');
	await expect(b.getByTestId('project-access').getByTestId('role-chip')).toHaveText(/Du: Lesen/);
	await expect(b.getByTestId('access-banner')).toContainText('Lesen');
	const add = b.getByLabel('Neue Aufgabe, Enter zum Anlegen');
	await expect(add).toBeDisabled();
	await expect(add).toHaveAttribute('title', 'Dafür brauchst du die Rolle Bearbeiten.');
	// The share dialog opens for readers too, without management controls.
	await b.getByTestId('share-open').click();
	await expect(b.getByTestId('no-manage')).toBeVisible();
	await expect(b.getByTestId('share-dialog').getByRole('button', { name: 'Hinzufügen', exact: true })).toHaveCount(0);
	await b.keyboard.press('Escape');
});

test('the subproject inherits the access and is shown as inherited', async () => {
	await b.getByTestId('project-item').filter({ hasText: 'Keller' }).getByRole('button', { name: /^Keller/ }).click();
	await expect(b.getByTestId('task-heading')).toHaveText('Keller');
	await expect(b.getByTestId('project-access').getByTestId('role-chip')).toHaveText(/Du: Lesen/);

	await sidebar(a).getByTestId('project-item').filter({ hasText: 'Keller' }).getByRole('button', { name: /^Keller/ }).click();
	await a.getByTestId('share-open').click();
	const dialog = a.getByTestId('share-dialog');
	const inherited = dialog.getByTestId('grant-inherited').filter({ hasText: 'Ben Gast' });
	await expect(inherited).toContainText('geerbt von');
	await expect(inherited.getByTestId('grant-parent-link')).toHaveText(/Hausbau/);
	await expect(inherited.getByTestId('grant-remove')).toHaveCount(0);
	await expect(inherited.getByTestId('grant-role')).toHaveCount(0);
	await expect(dialog.getByTestId('who-row').filter({ hasText: 'Ben Gast' })).toContainText('geerbt von Hausbau');
	// The link leads to the parent project.
	await inherited.getByTestId('grant-parent-link').click();
	await expect(a.getByTestId('task-heading')).toHaveText('Hausbau');
});

test('raising the role to "Bearbeiten" lets B create tasks', async () => {
	await a.getByTestId('share-open').click();
	const dialog = a.getByTestId('share-dialog');
	await dialog.getByTestId('grant-role').selectOption('edit');
	await expect(dialog.getByTestId('who-row').filter({ hasText: 'Ben Gast' })).toContainText('Bearbeiten');
	await a.keyboard.press('Escape');

	await b.getByTestId('project-item').filter({ hasText: 'Hausbau' }).getByRole('button', { name: /^Hausbau/ }).click();
	await b.reload();
	await expect(b.getByTestId('project-access').getByTestId('role-chip')).toHaveText(/Du: Bearbeiten/);
	await expect(b.getByTestId('access-banner')).toHaveCount(0);
	const add = b.getByLabel('Neue Aufgabe, Enter zum Anlegen');
	await expect(add).toBeEnabled();
	await add.fill('Baugenehmigung holen');
	await b.keyboard.press('Enter');
	await expect(b.getByTestId('task-item').filter({ hasText: 'Baugenehmigung holen' })).toBeVisible();
	// Renaming needs Verwalten: disabled with the reason.
	await expect(b.getByRole('heading', { level: 2 }).getByRole('button')).toBeDisabled();
});

test('overview and teams show the sharing from both sides', async () => {
	await b.goto('/konto/berechtigungen');
	await expect(b).toHaveURL(/\/settings\/permissions$/);
	await expect(b.getByTestId('settings-link-berechtigungen')).toHaveAttribute('aria-current', 'page');
	const incoming = b.getByTestId('access-incoming').filter({ hasText: 'Hausbau' });
	await expect(incoming).toContainText('von Anna Eigentum');
	await expect(incoming).toContainText('Bearbeiten');
	await expect(b.getByTestId('access-apps')).toBeVisible();

	await a.goto('/settings/permissions');
	await expect(a.getByTestId('access-outgoing').filter({ hasText: 'Hausbau' })).toContainText('Ben Gast');
	// Admin area: recovery code and account ID live here.
	await a.getByTestId('settings-link-verwaltung-konten').click();
	await expect(a.getByTestId('recovery-issue')).toBeVisible();
	await expect(a.getByTestId('admin-accounts')).toBeVisible();
	await b.goto('/settings/admin-accounts');
	await expect(b.getByTestId('admin-denied')).toBeVisible();
	await expect(b.getByTestId('recovery-issue')).toHaveCount(0);
});

test('removing the grant hides the project from B', async () => {
	await sidebar(a).getByRole('button', { name: 'Hausbau', exact: true }).click();
	await a.getByTestId('share-open').click();
	const dialog = a.getByTestId('share-dialog');
	await dialog.getByTestId('grant').filter({ hasText: 'Ben Gast' }).getByTestId('grant-remove').click();
	await expect(dialog.getByTestId('grant-remove-confirm')).toContainText('Ben Gast den Zugriff auf „Hausbau“ entziehen?');
	await dialog.getByRole('button', { name: 'Zugriff entziehen' }).click();
	await expect(dialog.getByTestId('grant')).toHaveCount(0);
	await a.keyboard.press('Escape');

	await b.reload();
	await expect(sidebar(b).getByTestId('sidebar-shared')).toHaveCount(0);
	await expect(sidebar(b).getByText('Hausbau')).toHaveCount(0);
});

test('team invitation: badge, accept, decline, leave', async () => {
	await sidebar(a).getByRole('button', { name: 'Teams', exact: true }).click();
	await a.getByLabel('Neues Team').fill('Bauteam');
	await a.getByRole('button', { name: 'Team anlegen' }).click();
	await expect(a.getByTestId('team-role-help')).toContainText('Administration');
	await a.getByLabel('Konto-ID der Person').fill(bID);
	await a.getByRole('button', { name: 'Einladen', exact: true }).click();
	await expect(a.getByTestId('team-member').filter({ hasText: 'Ben Gast' })).toContainText('Einladung offen');

	await b.reload();
	await expect(sidebar(b).getByTestId('nav-badge-teams')).toHaveText('1');
	await sidebar(b).getByRole('button', { name: /^Teams/ }).click();
	await expect(b.getByTestId('team-invitation')).toContainText('Einladung zum Team Bauteam');
	await b.getByTestId('team-invitation').getByRole('button', { name: 'Einladung annehmen' }).click();
	await expect(b.getByTestId('teams-info')).toHaveText('Du bist jetzt im Team.');
	await expect(sidebar(b).getByTestId('nav-badge-teams')).toHaveCount(0);
	await expect(b.getByTestId('team-item').filter({ hasText: 'Bauteam' })).toBeVisible();

	// A shares a project with the team; B sees it with the team's role and the team lists it.
	const projects = (await (await a.request.get('/v1/projects')).json()) as { id: string; name: string }[];
	const team = ((await (await a.request.get('/v1/teams')).json()) as { id: string; name: string }[]).find((x) => x.name === 'Bauteam')!;
	await api(a, 'put', `/v1/projects/${projects.find((p) => p.name === 'Hausbau')!.id}/grants`, { principalType: 'team', principalID: team.id, role: 'comment' });
	await b.reload();
	await expect(sidebar(b).getByTestId('sidebar-shared')).toContainText('Hausbau');
	// The team page lists the projects the viewer manages that are shared with the team (grants are only readable with Verwalten).
	await a.reload();
	await sidebar(a).getByRole('button', { name: 'Teams', exact: true }).click();
	await a.getByTestId('team-item').filter({ hasText: 'Bauteam' }).click();
	await expect(a.getByTestId('team-projects')).toContainText('Hausbau');
	await expect(a.getByTestId('team-projects')).toContainText('Kommentieren');
	await b.getByTestId('team-item').filter({ hasText: 'Bauteam' }).click();

	// Leaving needs no team administration and removes the shared project again.
	await b.getByTestId('team-leave').click();
	await b.getByTestId('team-leave-confirm').getByRole('button', { name: 'Verlassen' }).click();
	await expect(b.getByTestId('team-item')).toHaveCount(0);
	await b.reload();
	await expect(sidebar(b).getByTestId('sidebar-shared')).toHaveCount(0);

	// Declining a fresh invitation.
	await a.getByRole('button', { name: 'Einladen', exact: true }).waitFor();
	await a.getByLabel('Konto-ID der Person').fill(bID);
	await a.getByRole('button', { name: 'Einladen', exact: true }).click();
	// Wait until the invitation exists before B reloads (the click does not await the request).
	await expect(a.getByTestId('team-member').filter({ hasText: 'Ben Gast' })).toContainText('Einladung offen');
	await b.reload();
	await sidebar(b).getByRole('button', { name: /^Teams/ }).click();
	await b.getByTestId('team-decline').click();
	await expect(b.getByTestId('teams-info')).toHaveText('Einladung abgelehnt.');
	await expect(b.getByTestId('team-invitation')).toHaveCount(0);
});
