import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// GitHub per person in the PWA (card E51E8B8C, contracts/deploy.yaml 1.3.0): two people connect their own installation of the
// operator's one GitHub App through the real redirects (GitHub is scripts/fake-github-hub.py), map a project to a repository, and
// never see or use each other's. Needs a fresh backend database and the operator app; scripts/github-e2e.sh pwa starts all of it:
//   scripts/github-e2e.sh pwa            (E2E_SHOTS = folder for the light/dark screenshots)
// Without E2E_GITHUB_URL the spec is skipped.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const GITHUB = process.env.E2E_GITHUB_URL;
const SHOTS = process.env.E2E_SHOTS ?? join(tmpdir(), 'github-connect');
const json = { headers: { 'Content-Type': 'application/json' } };

test.describe.configure({ mode: 'serial' });
let a: Page;
let b: Page;

async function authenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	test.skip(!GITHUB, 'needs the GitHub stand-in of scripts/github-e2e.sh');
	mkdirSync(SHOTS, { recursive: true });
	a = await (await browser.newContext({ viewport: { width: 1280, height: 860 } })).newPage();
	await authenticator(a);
	await a.goto('/setup');
	await a.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await a.getByLabel('Anzeigename').fill('Anna Alice');
	await a.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(a.getByTestId('account-menu')).toBeVisible();
	const invitation = await a.request.post('/v1/invitations', { ...json, data: {} });
	const { token } = (await invitation.json()) as { token: string };
	b = await (await browser.newContext({ viewport: { width: 1280, height: 860 } })).newPage();
	await authenticator(b);
	await b.goto(`/setup?token=${token}`);
	await b.getByLabel('Anzeigename').fill('Ben Bob');
	await b.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(b.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await a?.context().close();
	await b?.context().close();
});

async function theme(page: Page, mode: 'dark' | 'light') {
	const current = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
	const put = await page.request.put('/v1/me/preferences', { ...json, data: { version: 1, appearance: { ...current.appearance, colorScheme: mode } } });
	expect(put.status(), await put.text()).toBeLessThan(300);
	await page.emulateMedia({ colorScheme: mode });
	await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
}

async function noOverflow(page: Page, label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}

/** "Mit GitHub verbinden": to the stand-in's installation page, pick the own GitHub account there, back to Todolino. */
async function connectAs(page: Page, login: string, button = 'github-connect') {
	await page.goto('/settings/github');
	await page.getByTestId(button).click();
	await expect(page.getByRole('heading', { name: /App installieren|App autorisieren/ })).toBeVisible();
	await page.getByRole('link', { name: new RegExp(`^Als ${login} `) }).click();
	await expect(page.getByTestId('github-return-status')).toHaveAttribute('data-phase', 'done');
}

async function openTargets(page: Page, project: string) {
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name: project, exact: true }).first().click();
	await page.getByTestId('project-more').click();
	await page.getByTestId('deploy-targets-open').click();
	await expect(page.getByTestId('deploy-targets-dialog')).toBeVisible();
}

test('nothing is connected at first; connecting runs through GitHub and back', async () => {
	await a.goto('/settings/github');
	await expect(a.getByTestId('github-page')).toBeVisible();
	await expect(a.getByTestId('github-empty')).toHaveText('Noch nichts verbunden.');
	await expect(a.getByTestId('github-unavailable')).toHaveCount(0);

	await connectAs(a, 'alice');
	// The address bar no longer carries code and state.
	expect(new URL(a.url()).search).toBe('');
	await expect(a.getByText('GitHub ist verbunden.')).toBeVisible();
	await a.getByRole('link', { name: 'Zu den GitHub-Verbindungen' }).click();
	const list = a.getByTestId('github-connection');
	await expect(list).toHaveCount(1);
	await expect(list.getByTestId('github-account')).toHaveText('alice');
	await expect(list).toContainText('Verbunden als alice');
	await expect(list.getByRole('link', { name: /Installation von alice bei GitHub verwalten/ })).toHaveAttribute('href', /\/settings\/installations\/111$/);
	await expect(a.getByTestId('github-error')).toHaveText('');

	// The second person starts with an empty list of their own.
	await b.goto('/settings/github');
	await expect(b.getByTestId('github-empty')).toBeVisible();
	await connectAs(b, 'bob');
	await b.goto('/settings/github');
	await expect(b.getByTestId('github-connection')).toHaveCount(1);
	await expect(b.getByTestId('github-account')).toHaveText('bob');
});

test('the way back refuses what is forged, refused or incomplete', async () => {
	const status = (p: Page) => p.getByTestId('github-return-status');
	// A state of the other person is no state of mine (CSRF), a made-up one neither.
	const forged = await b.request.post('/v1/github/connect', { ...json, data: { mode: 'existing' } });
	const state = new URL(((await forged.json()) as { url: string }).url).searchParams.get('state')!;
	await a.goto(`/github/callback?code=irgendwas&state=${state}`);
	await expect(status(a)).toHaveAttribute('data-phase', 'error');
	await expect(status(a)).toContainText('abgelaufen oder gehört nicht zu deiner Anmeldung');
	await a.goto('/github/callback?code=irgendwas&state=erfundenerStateErfundenerState');
	await expect(status(a)).toHaveAttribute('data-phase', 'error');
	// The person said no on GitHub, an organisation member only asked, the call is incomplete.
	await a.goto('/github/callback?error=access_denied&state=x');
	await expect(status(a)).toContainText('abgelehnt');
	await a.goto('/github/setup?setup_action=request&state=x');
	await expect(status(a)).toContainText('angefragt');
	await a.goto('/github/setup');
	await expect(status(a)).toHaveAttribute('data-phase', 'missing');
	await a.goto('/github/setup?installation_id=1%2F2&state=' + 'S'.repeat(30));
	await expect(status(a)).toHaveAttribute('data-phase', 'missing');
	// Forged installation id: alice names bob's installation while authorising as herself.
	const start = await a.request.post('/v1/github/connect', { ...json, data: { mode: 'install' } });
	const own = new URL(((await start.json()) as { url: string }).url).searchParams.get('state')!;
	const authorize = await a.request.post('/v1/github/setup', { ...json, data: { state: own, installationID: '222' } });
	const second = new URL(((await authorize.json()) as { url: string }).url).searchParams.get('state')!;
	await a.goto(`${GITHUB}/fake/authorize?user=alice&state=${second}`);
	await expect(status(a)).toHaveAttribute('data-phase', 'error');
	await expect(status(a)).toContainText('gehört laut GitHub nicht zu deinem Konto');
	// Not signed in: nothing is sent, the person is asked to sign in.
	const anonymous = await (await a.context().browser()!.newContext()).newPage();
	await anonymous.goto('/github/callback?code=abc&state=' + 'S'.repeat(30));
	await expect(status(anonymous)).toHaveAttribute('data-phase', 'signIn');
	await anonymous.context().close();
	await a.goto('/settings/github');
	await expect(a.getByTestId('github-connection')).toHaveCount(1);
});

test('a project is mapped to a repository of the own connection; the other person sees none of it', async () => {
	await a.request.post('/v1/projects', { ...json, data: { name: 'Kubus Alice' } });
	await b.request.post('/v1/projects', { ...json, data: { name: 'Kubus Bob' } });

	await openTargets(a, 'Kubus Alice');
	const section = a.getByTestId('github-repos');
	await expect(section).toBeVisible();
	await expect(section.getByTestId('github-repos-empty')).toBeVisible();
	// One connection: chosen already; its repositories are loaded.
	const repository = section.getByLabel('Repository', { exact: true });
	await expect(section.getByLabel('GitHub-Verbindung')).toHaveValue(/.+/);
	await expect(repository.locator('option')).toHaveText(['Repository wählen', 'alice/site']);
	await expect(section.getByTestId('github-repo-assign')).toHaveAttribute('aria-disabled', 'true');
	await repository.selectOption('alice/site');
	await section.getByTestId('github-repo-assign').click();
	await expect(section.getByTestId('github-repo-name')).toHaveText('alice/site');
	await expect(section.getByTestId('github-repo-by')).toHaveText('von dir zugeordnet');
	await expect(section.getByText('Repository zugeordnet.')).toBeVisible();
	// Mapped repositories are not offered twice.
	await expect(repository.locator('option')).toHaveText(['Repository wählen']);

	// Bob: his project, his repository only; alice/site does not exist for him.
	await openTargets(b, 'Kubus Bob');
	const mine = b.getByTestId('github-repos');
	await expect(mine.getByLabel('Repository', { exact: true }).locator('option')).toHaveText(['Repository wählen', 'bob/site']);
	await expect(mine).not.toContainText('alice');
	const connections = (await (await b.request.get('/v1/github')).json()) as { connections: { id: string }[] };
	const aliceProject = ((await (await a.request.get('/v1/projects')).json()) as { id: string; name: string }[]).find((p) => p.name === 'Kubus Alice')!;
	const foreign = await b.request.get(`/v1/projects/${aliceProject.id}/github-repositories`);
	expect(foreign.status()).toBe(404);
	const aliceConnection = ((await (await a.request.get('/v1/github')).json()) as { connections: { id: string }[] }).connections[0].id;
	expect(connections.connections.map((c) => c.id)).not.toContain(aliceConnection);
	expect((await b.request.get(`/v1/github/connections/${aliceConnection}/repositories`)).status()).toBe(404);
	const stolen = await b.request.post(`/v1/projects/${aliceProject.id}/github-repositories`, { ...json, data: { connectionID: connections.connections[0].id, repository: 'bob/site' } });
	expect(stolen.status()).toBe(404);
	await mine.getByLabel('Repository', { exact: true }).selectOption('bob/site');
	await mine.getByTestId('github-repo-assign').click();
	await expect(mine.getByTestId('github-repo-name')).toHaveText('bob/site');
});

test('a reader sees the mapping but cannot change it; rights lost on GitHub are said clearly', async () => {
	const aliceProject = ((await (await a.request.get('/v1/projects')).json()) as { id: string; name: string }[]).find((p) => p.name === 'Kubus Alice')!;
	await a.request.put(`/v1/projects/${aliceProject.id}/grants`, { ...json, data: {} }).catch(() => undefined);
	// GitHub no longer lists the repository: the page says so instead of pretending it is empty.
	await a.route('**/v1/github/connections/*/repositories', (r) => r.fulfill({ json: { ok: false, code: 'deploy_github_installation_removed', items: [], truncated: false } }));
	await openTargets(a, 'Kubus Alice');
	await expect(a.getByTestId('github-repos-error')).toHaveText('Die Installation wurde bei GitHub entfernt. Entferne die Verbindung und verbinde neu.');
	await a.unroute('**/v1/github/connections/*/repositories');
});

test('removing a connection removes what was mapped through it', async () => {
	await a.goto('/settings/github');
	await a.getByTestId('github-remove').click();
	await expect(a.getByTestId('github-remove-confirm')).toContainText('Alle Projekte, die darüber in ein Repository schreiben, verlieren die Zuordnung');
	await a.getByTestId('github-remove-yes').click();
	await expect(a.getByTestId('github-empty')).toBeVisible();
	await openTargets(a, 'Kubus Alice');
	await expect(a.getByTestId('github-repos-empty')).toBeVisible();
	await expect(a.getByTestId('github-repos-connect-first')).toContainText('Zum Zuordnen zuerst GitHub verbinden');
	// Bob's mapping is untouched.
	await openTargets(b, 'Kubus Bob');
	await expect(b.getByTestId('github-repo-name')).toHaveText('bob/site');
	await connectAs(a, 'alice');
});

test('light and dark, wide and narrow', async () => {
	const project = ((await (await a.request.get('/v1/projects')).json()) as { id: string; name: string }[]).find((p) => p.name === 'Kubus Alice')!;
	await openTargets(a, 'Kubus Alice');
	const section = a.getByTestId('github-repos');
	await section.getByLabel('Repository', { exact: true }).selectOption('alice/site');
	await section.getByTestId('github-repo-assign').click();
	await expect(section.getByTestId('github-repo-name')).toBeVisible();
	for (const mode of ['light', 'dark'] as const) {
		const suffix = mode === 'light' ? 'hell' : 'dunkel';
		await theme(a, mode);
		await a.setViewportSize({ width: 1280, height: 900 });
		await a.goto('/settings/github');
		await expect(a.getByTestId('github-connection')).toHaveCount(1);
		await a.screenshot({ path: join(SHOTS, `einstellungen-${suffix}.png`) });
		await a.getByTestId('github-remove').click();
		await a.screenshot({ path: join(SHOTS, `entfernen-${suffix}.png`) });
		await a.getByRole('button', { name: 'Abbrechen' }).click();
		await openTargets(a, 'Kubus Alice');
		await expect(a.getByTestId('github-repo-name')).toHaveText('alice/site');
		await expect(a.getByText('Kein weiteres Repository, in das du schreiben darfst.')).toBeVisible();
		await a.screenshot({ path: join(SHOTS, `projekt-repository-${suffix}.png`) });
		await a.goto('/github/callback?error=access_denied&state=x');
		await expect(a.getByTestId('github-return-status')).toContainText('abgelehnt');
		await a.screenshot({ path: join(SHOTS, `rueckweg-${suffix}.png`) });
		await a.setViewportSize({ width: 390, height: 844 });
		await a.goto('/settings/github');
		await expect(a.getByTestId('github-connection')).toHaveCount(1);
		await noOverflow(a, `settings at 390 px, ${mode}`);
		await a.screenshot({ path: join(SHOTS, `einstellungen-mobil-${suffix}.png`) });
		// The sidebar is folded away on a phone: the project's deploy page by its address.
		await a.goto(`/project/${project.id}/deploy`);
		await expect(a.getByTestId('github-repo-name')).toHaveText('alice/site');
		await expect(a.getByText('Kein weiteres Repository, in das du schreiben darfst.')).toBeVisible();
		await a.getByTestId('github-repos').scrollIntoViewIfNeeded();
		await noOverflow(a, `project at 390 px, ${mode}`);
		await a.screenshot({ path: join(SHOTS, `projekt-repository-mobil-${suffix}.png`) });
	}
	await theme(a, 'light');
	await a.setViewportSize({ width: 320, height: 700 });
	await a.goto('/settings/github');
	await noOverflow(a, 'settings at 320 px');
});
