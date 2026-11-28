import { expect, test, type Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

// Deploy targets in the PWA, phase 1b (card 354ADE12, contracts/deploy.yaml): persons create, edit and delete targets, confirm the
// SFTP host key and look at the read-only sync view (file tree with status). Nothing is uploaded, nothing on a server changes.
// Needs a fresh backend database with SETTINGS_ENCRYPTION_KEY. Run on its own:
//   npx playwright test e2e/deploy-targets.spec.ts --project=chromium
// The last test needs the real SFTP test server of scripts/test-deploy-servers.sh and a backend with DEPLOY_ALLOW_PRIVATE_HOSTS=1;
// scripts/deploy-pwa-e2e.sh starts all of it. Without E2E_DEPLOY_SFTP_PORT that test is skipped (GitHub CI has no containers).
// Screenshots (light and dark) go to E2E_SHOTS when set.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SFTP_PORT = process.env.E2E_DEPLOY_SFTP_PORT;
const SHOTS = process.env.E2E_SHOTS;
test.describe.configure({ mode: 'serial' });
let page: Page;
const temps: string[] = [];
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 860 } })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Deploy Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

async function createProject(name: string) {
	const r = await page.request.post('/v1/projects', { ...json, data: { name } });
	expect(r.ok()).toBeTruthy();
	return (await r.json()) as { id: string; name: string };
}

async function openTargets(name: string) {
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name, exact: true }).first().click();
	await page.getByTestId('project-more').click();
	await page.getByTestId('deploy-targets-open').click();
	await expect(page.getByTestId('deploy-targets-dialog')).toBeVisible();
}

const dialog = () => page.getByTestId('deploy-targets-dialog');
const form = () => dialog().getByTestId('deploy-form');
const rows = () => dialog().getByTestId('deploy-target');

async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}

async function theme(mode: 'dark' | 'light') {
	const current = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
	const put = await page.request.put('/v1/me/preferences', { ...json, data: { version: 1, appearance: { ...current.appearance, colorScheme: mode } } });
	expect(put.status(), await put.text()).toBeLessThan(300);
	await page.emulateMedia({ colorScheme: mode });
	await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
}

/** A local folder like a repository checkout: same, changed (CRLF on the server only), new, and files the default rules exclude. */
function repoFolder(vendorFiles = 0): string {
	const root = mkdtempSync(join(tmpdir(), 'deploy-pwa-'));
	temps.push(root);
	const dir = join(root, 'kubus');
	const files: Record<string, string> = {
		'index.php': 'hi\n',
		'css/app.css': 'a{}\nb{}\n',
		'about.php': 'neu\n',
		'kontakt.php': '<?php echo 1;\n',
		'.env': 'SECRET=1\n',
		'node_modules/x/index.js': 'x\n'
	};
	// Many small files like a vendor/ folder: the manifest is then far above the server's default 256 kB body limit.
	for (let i = 0; i < vendorFiles; i++) files[`vendor/pkg-${Math.floor(i / 100)}/src/File${i}.php`] = `<?php // ${i}\n`;
	for (const [path, text] of Object.entries(files)) {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	}
	return dir;
}

test('creates, edits and deletes targets; FTP is marked unencrypted; credentials never come back', async () => {
	const p = await createProject('Kubus');
	await openTargets('Kubus');
	await expect(dialog().getByTestId('deploy-empty')).toHaveText('Noch keine Deploy-Ziele.');

	// Empty form: readable error, nothing saved.
	await dialog().getByTestId('deploy-add').click();
	await form().getByTestId('deploy-save').click();
	await expect(form().getByTestId('deploy-form-error')).toHaveText('Bitte einen Namen eingeben.');

	await form().getByLabel('Name', { exact: true }).fill('Kubus Test');
	await expect(form().getByLabel('Stufe')).toHaveValue('test');
	await expect(form().getByLabel('Protokoll')).toHaveValue('sftp');
	await expect(form().getByLabel('Port')).toHaveAttribute('placeholder', '22');
	await form().getByLabel('Host').fill('203.0.113.10');
	await form().getByLabel('Basispfad').fill('site');
	await form().getByLabel('Benutzer').fill('deploy');
	await form().getByLabel('Passwort', { exact: true }).fill('geheim-Pass-771');

	// Plain FTP: red warning, default port 21; back to SFTP removes it.
	await form().getByLabel('Protokoll').selectOption('ftp');
	await expect(form().getByTestId('deploy-ftp-warning')).toContainText('unverschlüsselt');
	await expect(form().getByLabel('Port')).toHaveAttribute('placeholder', '21');
	await form().getByLabel('Protokoll').selectOption('sftp');
	await expect(form().getByTestId('deploy-ftp-warning')).toHaveCount(0);

	await form().getByTestId('deploy-save').click();
	await expect(dialog().getByTestId('deploy-status')).toHaveText('Ziel gespeichert.');
	await expect(rows()).toHaveCount(1);
	const row = rows().first();
	await expect(row.getByTestId('deploy-name')).toHaveText('Kubus Test');
	await expect(row.getByTestId('deploy-stage')).toHaveText('Test');
	await expect(row.getByTestId('deploy-protocol')).toHaveText('SFTP');
	await expect(row.getByTestId('deploy-endpoint')).toHaveText('deploy@203.0.113.10:22/site');
	await expect(row.getByTestId('deploy-hostkey')).toHaveText('Host-Schlüssel nicht bestätigt');

	// The password is stored, but neither the API nor the page shows it.
	const listed = await (await page.request.get(`/v1/projects/${p.id}/deploy-targets`)).text();
	expect(listed).not.toContain('geheim-Pass-771');
	expect(await page.content()).not.toContain('geheim-Pass-771');

	// Edit: the password field stays empty (stored), rules are lines.
	await row.getByTestId('deploy-edit').click();
	await expect(form().getByLabel('Passwort', { exact: true })).toHaveValue('');
	await expect(form().getByTestId('deploy-secret-stored')).toBeVisible();
	await form().getByLabel('Name', { exact: true }).fill('Kubus Testserver');
	await form().getByLabel('Ausschlüsse', { exact: true }).fill('cache/**\n*.log');
	await expect(form().getByLabel('Vorgabe-Ausschlüsse anwenden')).toBeChecked();
	const patch = page.waitForRequest((r) => r.method() === 'PATCH' && r.url().includes('/v1/deploy-targets/'));
	await form().getByTestId('deploy-save').click();
	// Only what changed goes out; an unchanged endpoint never sends (or asks for) the secret again.
	expect(Object.keys((await patch).postDataJSON()).sort()).toEqual(['name', 'rules']);
	await expect(dialog().getByTestId('deploy-status')).toHaveText('Ziel gespeichert.');
	await expect(rows().first().getByTestId('deploy-name')).toHaveText('Kubus Testserver');
	const target = ((await (await page.request.get(`/v1/projects/${p.id}/deploy-targets`)).json()) as { items: { rules: { excludes: string[] } }[] }).items[0];
	expect(target.rules.excludes).toEqual(['cache/**', '*.log']);

	// Changing the host without a new password: the server refuses, the form says why.
	await rows().first().getByTestId('deploy-edit').click();
	await form().getByLabel('Host').fill('203.0.113.11');
	await form().getByTestId('deploy-save').click();
	await expect(form().getByTestId('deploy-form-error')).toHaveText('Host, Port, Protokoll oder Benutzer geändert: Bitte das Passwort oder den Schlüssel neu eingeben.');
	await form().getByRole('button', { name: 'Abbrechen' }).click();

	// A second target over FTP keeps the warning in the list; delete asks first.
	await dialog().getByTestId('deploy-add').click();
	await form().getByLabel('Name', { exact: true }).fill('Altserver');
	await form().getByLabel('Stufe').selectOption('prod');
	await form().getByLabel('Protokoll').selectOption('ftp');
	await form().getByLabel('Host').fill('203.0.113.12');
	await form().getByLabel('Benutzer').fill('alt');
	await form().getByLabel('Passwort', { exact: true }).fill('alt-Pass-552');
	await form().getByTestId('deploy-save').click();
	await expect(rows()).toHaveCount(2);
	const ftp = rows().filter({ hasText: 'Altserver' });
	await expect(ftp.getByTestId('deploy-stage')).toHaveText('Prod');
	await expect(ftp.getByTestId('deploy-ftp-badge')).toHaveText('unverschlüsselt');
	await ftp.getByTestId('deploy-delete').click();
	await expect(dialog().getByTestId('deploy-delete-confirm')).toContainText('Altserver');
	await dialog().getByTestId('deploy-delete-yes').click();
	await expect(dialog().getByTestId('deploy-status')).toHaveText('Ziel gelöscht.');
	await expect(rows()).toHaveCount(1);

	await page.setViewportSize({ width: 320, height: 700 });
	await noOverflow('targets at 320 px');
	await page.setViewportSize({ width: 1280, height: 860 });
});

test('host key confirmation and the read-only sync view (server answers simulated)', async () => {
	await openTargets('Kubus');
	const target = rows().first();
	const id = await target.getAttribute('data-target-id');
	expect(id).toBeTruthy();
	const fingerprint = 'SHA256:2wT8Lq0mQ1rP3hN9vXkZ7cY4bA6sD5fG8jK1lM0nO2p';
	let confirmed = '';
	await page.route(`**/v1/deploy-targets/${id}/test`, (r) =>
		r.fulfill({ json: confirmed ? { ok: true, files: 4 } : { ok: false, code: 'deploy_host_key_unconfirmed', offeredHostKey: { type: 'ssh-ed25519', fingerprint } } })
	);
	await page.route(`**/v1/deploy-targets/${id}/host-key`, async (r) => {
		confirmed = (JSON.parse(r.request().postData() ?? '{}') as { fingerprint?: string }).fingerprint ?? '';
		const current = (await (await page.request.get(`/v1/deploy-targets/${id}`)).json()) as Record<string, unknown>;
		await r.fulfill({ json: { ...current, hostKey: { confirmed: true, type: 'ssh-ed25519', fingerprint } } });
	});
	await page.route(`**/v1/deploy-targets/${id}/compare`, (r) =>
		r.fulfill({
			json: {
				ok: true,
				summary: { same: 2, new: 1, changed: 1, serverOnly: 1, unverified: 0 },
				files: [
					{ path: 'index.php', serverPath: 'index.php', status: 'same', repoSize: 3, serverSize: 3 },
					{ path: 'css/app.css', serverPath: 'css/app.css', status: 'same', repoSize: 8, serverSize: 10 },
					{ path: 'about.php', serverPath: 'about.php', status: 'changed', repoSize: 4, serverSize: 4 },
					{ path: 'kontakt.php', serverPath: 'kontakt.php', status: 'new', repoSize: 14 },
					{ path: '', serverPath: 'designer.html', status: 'serverOnly', serverSize: 20 }
				]
			}
		})
	);

	await target.getByTestId('deploy-test').click();
	const offer = dialog().getByTestId('deploy-hostkey-offer');
	await expect(offer).toContainText('ssh-ed25519');
	await expect(offer.getByTestId('deploy-fingerprint')).toHaveText(fingerprint);
	await offer.getByTestId('deploy-hostkey-confirm').click();
	await expect(rows().first().getByTestId('deploy-hostkey')).toHaveText('Host-Schlüssel bestätigt');
	expect(confirmed).toBe(fingerprint);
	await rows().first().getByTestId('deploy-test').click();
	await expect(dialog().getByTestId('deploy-test-result')).toHaveText('Verbindung ok: 4 Dateien im Basispfad.');

	await rows().first().getByTestId('deploy-sync').click();
	const sync = dialog().getByTestId('deploy-sync-view');
	await expect(sync.getByTestId('deploy-sync-readonly')).toContainText('lädt nichts hoch');
	const compare = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith('/compare'));
	await sync.getByTestId('deploy-sync-folder').setInputFiles(repoFolder());
	// The browser sends paths relative to the folder with size and SHA-256, never contents; node_modules is skipped.
	const sent = ((await compare).postDataJSON() as { files: { path: string; size: number; sha256: string }[] }).files;
	expect(sent.map((f) => f.path)).toEqual(['.env', 'about.php', 'css/app.css', 'index.php', 'kontakt.php']);
	expect(sent.find((f) => f.path === 'index.php')).toEqual({ path: 'index.php', size: 3, sha256: '98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4' });
	await expect(sync.getByTestId('deploy-sync-count-same')).toHaveText('2 gleich');
	await expect(sync.getByTestId('deploy-sync-count-changed')).toHaveText('1 geändert');
	await expect(sync.getByTestId('deploy-sync-count-new')).toHaveText('1 neu');
	await expect(sync.getByTestId('deploy-sync-count-serverOnly')).toHaveText('1 nur Server');
	const designer = sync.getByTestId('deploy-sync-file').filter({ hasText: 'designer.html' });
	await expect(designer).toHaveAttribute('data-status', 'serverOnly');
	await expect(sync.getByTestId('deploy-sync-file').filter({ hasText: 'app.css' })).toHaveAttribute('data-status', 'same');
	// Filter: only differences.
	await sync.getByTestId('deploy-sync-only-diff').check();
	await expect(sync.getByTestId('deploy-sync-file')).toHaveCount(3);
	// Read only: no upload, download or delete actions anywhere.
	await expect(sync.getByRole('button', { name: /hochladen|herunterladen|löschen/i })).toHaveCount(0);

	await page.setViewportSize({ width: 320, height: 700 });
	await noOverflow('sync view at 320 px');
	await page.setViewportSize({ width: 1280, height: 860 });
	await page.unrouteAll();
});

test('real SFTP server: confirm the host key, test, and compare a local folder (read only)', async () => {
	test.skip(!SFTP_PORT, 'needs scripts/deploy-pwa-e2e.sh (real SFTP container, DEPLOY_ALLOW_PRIVATE_HOSTS=1)');
	await createProject('Kubus Echt');
	await openTargets('Kubus Echt');
	await dialog().getByTestId('deploy-add').click();
	await form().getByLabel('Name', { exact: true }).fill('Kubus Test');
	await form().getByLabel('Host').fill('127.0.0.1');
	await form().getByLabel('Port').fill(String(SFTP_PORT));
	await form().getByLabel('Basispfad').fill('site');
	await form().getByLabel('Benutzer').fill('deploy');
	await form().getByLabel('Passwort', { exact: true }).fill('sftp-Geheim-41d9');
	await form().getByTestId('deploy-save').click();
	await expect(rows()).toHaveCount(1);

	// Unconfirmed: the server offers the key, nobody logged in yet.
	await rows().first().getByTestId('deploy-test').click();
	const offer = dialog().getByTestId('deploy-hostkey-offer');
	await expect(offer.getByTestId('deploy-fingerprint')).toHaveText(/^SHA256:[A-Za-z0-9+/]{43}$/, { timeout: 30_000 });
	await offer.getByTestId('deploy-hostkey-confirm').click();
	await expect(rows().first().getByTestId('deploy-hostkey')).toHaveText('Host-Schlüssel bestätigt', { timeout: 30_000 });
	await rows().first().getByTestId('deploy-test').click();
	await expect(dialog().getByTestId('deploy-test-result')).toHaveText(/^Verbindung ok: \d+ Dateien im Basispfad\.$/, { timeout: 30_000 });

	await rows().first().getByTestId('deploy-sync').click();
	const sync = dialog().getByTestId('deploy-sync-view');
	await sync.getByTestId('deploy-sync-folder').setInputFiles(repoFolder(3000));
	await expect(sync.getByTestId('deploy-sync-summary')).toBeVisible({ timeout: 60_000 });
	await expect(sync.getByTestId('deploy-sync-count-new')).toHaveText('3001 neu');
	// A big folder starts collapsed with its counts; small ones are open.
	const vendor = sync.locator('[data-testid="deploy-sync-dir"][data-path="vendor"]');
	await expect(vendor.locator('details').first()).not.toHaveAttribute('open');
	await expect(sync.locator('[data-testid="deploy-sync-dir"][data-path="css"] details').first()).toHaveAttribute('open');
	const status = async (name: string) => sync.getByTestId('deploy-sync-file').filter({ has: page.getByText(name, { exact: true }) }).getAttribute('data-status');
	expect(await status('index.php')).toBe('same');
	expect(await status('app.css')).toBe('same'); // CRLF on the server, LF in the folder
	expect(await status('about.php')).toBe('changed');
	expect(await status('kontakt.php')).toBe('new');
	expect(await status('designer.html')).toBe('serverOnly');
	// Default excludes: neither .env nor node_modules show up; symlinks on the server are not listed.
	const fileAt = (path: string) => sync.locator(`[data-testid="deploy-sync-file"][data-path*="${path}"]`);
	await expect(fileAt('.env')).toHaveCount(0);
	await expect(fileAt('node_modules')).toHaveCount(0);
	await expect(fileAt('link.txt')).toHaveCount(0);
	await expect(fileAt('etclink')).toHaveCount(0);

	if (SHOTS) {
		mkdirSync(SHOTS, { recursive: true });
		for (const mode of ['light', 'dark'] as const) {
			const suffix = mode === 'light' ? 'hell' : 'dunkel';
			await theme(mode);
			await page.setViewportSize({ width: 1280, height: 900 });
			await openTargets('Kubus Echt');
			await expect(rows()).toHaveCount(1);
			await expect(rows().first().getByTestId('deploy-hostkey')).toHaveText('Host-Schlüssel bestätigt');
			await page.screenshot({ path: `${SHOTS}/ziele-${suffix}.png` });
			await dialog().getByTestId('deploy-add').click();
			await form().getByLabel('Name', { exact: true }).fill('Kubus Altserver');
			await form().getByLabel('Protokoll').selectOption('ftp');
			await page.screenshot({ path: `${SHOTS}/formular-ftp-${suffix}.png` });
			await form().getByRole('button', { name: 'Abbrechen' }).click();
			await rows().first().getByTestId('deploy-sync').click();
			await dialog().getByTestId('deploy-sync-view').getByTestId('deploy-sync-folder').setInputFiles(repoFolder());
			await expect(dialog().getByTestId('deploy-sync-summary')).toBeVisible({ timeout: 30_000 });
			await page.screenshot({ path: `${SHOTS}/sync-${suffix}.png` });
			await page.setViewportSize({ width: 390, height: 844 });
			await page.screenshot({ path: `${SHOTS}/sync-mobil-${suffix}.png` });
		}
		await theme('light');
	}
});

/** The repo state as an agent sends it: manifest with content. */
const manifestOf = (files: Record<string, string>) =>
	Object.entries(files).map(([path, text]) => ({ path, size: Buffer.byteLength(text), sha256: createHash('sha256').update(text).digest('hex'), content: Buffer.from(text).toString('base64') }));

async function planUpload(targetID: string, files: Record<string, string>, note: string, request = true) {
	const made = await page.request.post(`/v1/deploy-targets/${targetID}/plans`, { ...json, data: { files: manifestOf(files), note, ref: 'main@abc1234' } });
	const body = (await made.json()) as { ok: boolean; plan: { id: string } };
	expect(body.ok, JSON.stringify(body)).toBe(true);
	if (request) expect((await page.request.post(`/v1/deploy-plans/${body.plan.id}/request`, { ...json, data: {} })).ok()).toBe(true);
	return body.plan.id;
}

const onServer = (path: string) => execFileSync('docker', ['exec', 'todo-deploy-test-sftp', 'sh', '-c', `cat "/home/deploy/site/${path}" 2>/dev/null || echo FEHLT`]).toString();
const plans = () => dialog().getByTestId('deploy-plans');
const planCard = (id: string) => plans().locator(`[data-testid="deploy-plan"][data-plan-id="${id}"]`);

async function openPlans(project: string) {
	await openTargets(project);
	await rows().first().getByTestId('deploy-plans-open').click();
	await expect(plans()).toBeVisible();
}

test('real SFTP server: a person sees the request, overrides the lock, uploads, rejects and takes it back', async () => {
	test.skip(!SFTP_PORT, 'needs scripts/deploy-pwa-e2e.sh (real SFTP container, DEPLOY_ALLOW_PRIVATE_HOSTS=1)');
	test.setTimeout(240_000);
	await page.setViewportSize({ width: 1280, height: 860 });
	await openTargets('Kubus Echt');
	const target = (await rows().first().getAttribute('data-target-id'))!;
	await rows().first().getByTestId('deploy-plans-open').click();
	await expect(plans().getByTestId('deploy-plans-empty')).toBeVisible();

	const before = { about: onServer('about.php'), kontakt: onServer('kontakt.php') };
	expect(before).toEqual({ about: 'alt\n', kontakt: 'FEHLT\n' });
	const files = { 'index.php': 'hi\n', 'about.php': 'neu aus dem Repo\n', 'kontakt.php': '<?php echo 1;\n', '.env': 'SECRET=1\n' };
	const id = await planUpload(target, files, 'Kontaktseite ist fertig');
	await plans().getByTestId('deploy-plans-reload').click();
	const card = planCard(id);
	await expect(card.getByTestId('deploy-plan-state')).toHaveText('wartet auf Freigabe');
	await expect(card.getByTestId('deploy-plan-note')).toHaveText('Kontaktseite ist fertig');
	await expect(card.getByTestId('deploy-plan-counts')).toHaveText('2 hochladen, 0 löschen, 1 unverändert');
	await expect(card.getByTestId('deploy-plan-file')).toHaveCount(2);
	await expect(card.getByTestId('deploy-plan-file').filter({ hasText: 'about.php' })).toContainText('überschreibt Server-Änderung');
	// The server file is not Todolino's: locked until the person says so.
	await expect(card.getByTestId('deploy-plan-blocker')).toContainText('about.php');
	await expect(card.getByTestId('deploy-plan-approve')).toBeDisabled();
	expect(onServer('kontakt.php')).toBe('FEHLT\n');

	if (SHOTS) await shotPlans('gesperrt', 'Kubus Echt', id);
	await openPlans('Kubus Echt');
	await planCard(id).getByTestId('deploy-plan-override').check();
	await planCard(id).getByTestId('deploy-plan-approve').click();
	await expect(planCard(id).getByTestId('deploy-plan-state')).toHaveText('ausgeführt', { timeout: 60_000 });
	await expect(planCard(id).getByTestId('deploy-plan-result')).toHaveText('2 Dateien geschrieben.');
	expect(onServer('about.php')).toBe('neu aus dem Repo\n');
	expect(onServer('kontakt.php')).toBe('<?php echo 1;\n');

	// A plan nobody asked for cannot be approved here.
	const unasked = await planUpload(target, { ...files, 'about.php': 'noch nicht beantragt\n' }, 'Nur geplant', false);
	await plans().getByTestId('deploy-plans-reload').click();
	await expect(planCard(unasked).getByTestId('deploy-plan-state')).toHaveText('geplant');
	await expect(planCard(unasked).getByTestId('deploy-plan-approve')).toHaveCount(0);
	await expect(planCard(unasked).getByTestId('deploy-plan-unasked')).toBeVisible();
	await planCard(unasked).getByTestId('deploy-plan-reject').click();
	await expect(planCard(unasked).getByTestId('deploy-plan-state')).toHaveText('abgelehnt');

	// A second request is rejected: nothing changes.
	const second = await planUpload(target, { ...files, 'about.php': 'unerwünscht\n' }, 'Bitte nicht');
	await plans().getByTestId('deploy-plans-reload').click();
	await planCard(second).getByTestId('deploy-plan-reject').click();
	await expect(planCard(second).getByTestId('deploy-plan-state')).toHaveText('abgelehnt');
	await expect(planCard(second).getByTestId('deploy-plan-approve')).toHaveCount(0);
	expect(onServer('about.php')).toBe('neu aus dem Repo\n');

	// A change on the server after the request stops the run with a readable reason.
	const third = await planUpload(target, { ...files, 'index.php': 'HI\n' }, 'Startseite');
	execFileSync('docker', ['exec', 'todo-deploy-test-sftp', 'sh', '-c', 'echo dazwischen >> /home/deploy/site/index.php']);
	await plans().getByTestId('deploy-plans-reload').click();
	await planCard(third).getByTestId('deploy-plan-approve').click();
	await expect(planCard(third).getByTestId('deploy-plan-result')).toContainText('veraltet', { timeout: 60_000 });
	execFileSync('docker', ['exec', 'todo-deploy-test-sftp', 'sh', '-c', "printf 'hi\\n' > /home/deploy/site/index.php"]);

	// The way back: planned first, written only after the approval.
	await planCard(id).getByTestId('deploy-plan-rollback').click();
	await expect(plans().getByTestId('deploy-plans-status')).toHaveText('Rückweg geplant. Prüfe ihn und gib ihn frei.', { timeout: 60_000 });
	const back = plans().locator('[data-testid="deploy-plan"][data-kind="rollback"]');
	await expect(back.getByTestId('deploy-plan-file')).toHaveCount(2);
	await expect(planCard(id).getByTestId('deploy-plan-rollback')).toHaveCount(0);
	expect(onServer('about.php')).toBe('neu aus dem Repo\n');
	const backID = (await back.getAttribute('data-plan-id'))!;
	if (SHOTS) await shotPlans('rueckweg', 'Kubus Echt', backID);
	await openPlans('Kubus Echt');
	await planCard(backID).getByTestId('deploy-plan-approve').click();
	await expect(planCard(backID).getByTestId('deploy-plan-state')).toHaveText('ausgeführt', { timeout: 60_000 });
	expect(onServer('about.php')).toBe('alt\n');
	expect(onServer('kontakt.php')).toBe('FEHLT\n');
});

/** Light and dark, desktop and phone, scrolled to one plan; no horizontal overflow. */
async function shotPlans(name: string, project: string, planID: string) {
	mkdirSync(SHOTS!, { recursive: true });
	for (const mode of ['light', 'dark'] as const) {
		const suffix = mode === 'light' ? 'hell' : 'dunkel';
		await theme(mode);
		// The dialog is opened on the desktop layout (the phone layout has no project list), then resized.
		await page.setViewportSize({ width: 1280, height: 900 });
		await openPlans(project);
		for (const [size, width, height] of [['', 1280, 900], ['-mobil', 390, 844], ['-schmal', 320, 700]] as const) {
			await page.setViewportSize({ width, height });
			await expect(planCard(planID)).toBeVisible();
			await planCard(planID).evaluate((e) => e.scrollIntoView({ block: 'start' }));
			if (width > 320) await page.screenshot({ path: `${SHOTS}/uploads-${name}${size}-${suffix}.png` });
			await noOverflow(`${name} ${width}px`);
			const card = await planCard(planID).evaluate((e) => e.scrollWidth - e.clientWidth);
			expect(card, `${name} ${width}px: plan card overflows`).toBeLessThanOrEqual(0);
		}
		await page.setViewportSize({ width: 1280, height: 860 });
	}
	await theme('light');
}

test.afterAll(() => {
	for (const d of temps) rmSync(d, { recursive: true, force: true });
});
