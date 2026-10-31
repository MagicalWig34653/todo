import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database with BOOTSTRAP_TOKEN (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/live-refresh.spec.ts --project=chromium
// Two browser contexts share one account (cookie copied): a change made in A must show up in B within 6 s without reload.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test('a change in browser A appears in browser B without reload', async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	const ctxA = await browser.newContext();
	const a = await ctxA.newPage();
	const cdp = await ctxA.newCDPSession(a);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await a.goto('/setup');
	await a.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await a.getByLabel('Anzeigename').fill('Live Tester');
	await a.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(a.getByTestId('account-menu')).toBeVisible();

	const ctxB = await browser.newContext({ storageState: await ctxA.storageState() });
	const b = await ctxB.newPage();
	const waits: string[] = [];
	b.on('request', (r) => {
		if (r.url().includes('/v1/sync/wait')) waits.push(r.url());
	});
	await b.goto('/');
	await expect(b.getByTestId('account-menu')).toBeVisible();
	await b.evaluate(() => ((window as unknown as { __noReload: boolean }).__noReload = true));

	await openProject(a, 'Livezone', true);
	await a.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill('Erste Aufgabe');
	await a.keyboard.press('Enter');
	await expect(a.getByTestId('task-item').filter({ hasText: 'Erste Aufgabe' })).toBeVisible();

	// B sees the new project in the sidebar and opens it.
	await openProject(b, 'Livezone', false);
	await expect(b.getByTestId('task-item').filter({ hasText: 'Erste Aufgabe' })).toBeVisible({ timeout: 6_000 });

	// New task in A -> list in B.
	await a.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill('Zweite Aufgabe');
	await a.keyboard.press('Enter');
	await expect(a.getByTestId('task-item').filter({ hasText: 'Zweite Aufgabe' })).toBeVisible();
	const t0 = Date.now();
	await expect(b.getByTestId('task-item').filter({ hasText: 'Zweite Aufgabe' })).toBeVisible({ timeout: 6_000 });
	console.log(`task propagated in ${Date.now() - t0} ms`);

	// Comment in A on an open task -> visible in B's open detail (comments have no sync feed, only the live hint).
	const taskB = b.getByTestId('task-item').filter({ hasText: 'Erste Aufgabe' });
	await taskB.getByRole('button', { name: 'Details' }).click();
	const taskA = a.getByTestId('task-item').filter({ hasText: 'Erste Aufgabe' });
	await taskA.getByRole('button', { name: 'Details' }).click();
	const detailA = taskA.getByTestId('task-detail');
	await detailA.getByLabel('Kommentar schreiben').fill('Hallo aus A');
	await detailA.getByRole('button', { name: 'Kommentieren' }).click();
	await expect(detailA.getByTestId('comment')).toContainText('Hallo aus A');
	await expect(taskB.getByTestId('task-detail').getByTestId('comment')).toContainText('Hallo aus A', { timeout: 6_000 });

	// Never reloaded, and B used the long poll instead of timers.
	expect(await b.evaluate(() => (window as unknown as { __noReload?: boolean }).__noReload)).toBe(true);
	expect(waits.length).toBeGreaterThan(0);
	await ctxA.close();
	await ctxB.close();
});

async function openProject(page: Page, name: string, create: boolean) {
	if (create) {
		await page.getByTestId('add-project').click();
		await page.getByLabel('Neues Projekt').fill(name);
		await page.getByRole('button', { name: 'Projekt anlegen' }).click();
	}
	await page.getByTestId('project-item').filter({ hasText: name }).getByRole('button', { name, exact: true }).click({ timeout: create ? 5_000 : 6_000 });
	await expect(page.getByTestId('task-heading')).toHaveText(name);
}
