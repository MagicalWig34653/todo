import { expect, test, type Locator, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/question-overflow.spec.ts --project=chromium
// SHOT_DIR=<dir> additionally writes screenshots.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.SHOT_DIR;
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

const LONG_WORD = 'Superlangeroptionsbezeichnung'.repeat(6) + '/' + 'x'.repeat(40);
const SENTENCE = 'Wir nehmen die zweite Variante mit dem ausfuehrlichen Migrationsplan und pruefen danach alles erneut. ';
const OPTIONS = ['Kurz', SENTENCE.repeat(2).trim(), LONG_WORD, ('Sehr ausfuehrliche Antwort mit viel Text. ' + 'wort '.repeat(120)).slice(0, 500)];

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext()).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Overflow Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

async function ask(title: string): Promise<{ projectID: string; taskID: string }> {
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: `Projekt ${title}` } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title } })).json();
	const res = await page.request.post(`/v1/tasks/${task.id}/questions`, { ...json, data: { prompt: `Frage ${title}: ${LONG_WORD}`, options: OPTIONS, blocking: true } });
	expect(res.status()).toBe(201);
	return { projectID: project.id, taskID: task.id };
}

/** No descendant may stick out of the card, and neither card nor page may scroll horizontally. */
async function expectContained(card: Locator) {
	const result = await card.evaluate((el) => {
		const box = el.getBoundingClientRect();
		const offenders: string[] = [];
		for (const child of el.querySelectorAll('*')) {
			const r = child.getBoundingClientRect();
			if (r.width === 0 && r.height === 0) continue;
			if (r.right > box.right + 0.5 || r.left < box.left - 0.5) offenders.push(`${child.tagName} ${String((child as HTMLElement).className).slice(0, 40)} ${Math.round(r.right)}>${Math.round(box.right)}`);
		}
		const doc = document.documentElement;
		const wide = [...document.querySelectorAll('body *')]
			.filter((n) => n.getBoundingClientRect().right > doc.clientWidth + 0.5 && n.getBoundingClientRect().width > 0)
			.slice(0, 4)
			.map((n) => `${n.tagName} ${String((n as HTMLElement).className).slice(0, 60)} ${Math.round(n.getBoundingClientRect().right)}`);
		return { wide, offenders: offenders.slice(0, 5), cardScroll: el.scrollWidth - el.clientWidth, pageScroll: doc.scrollWidth - doc.clientWidth, bodyScroll: document.body.scrollWidth - doc.clientWidth };
	});
	expect(result.offenders).toEqual([]);
	expect(result.cardScroll).toBeLessThanOrEqual(0);
	expect(result.pageScroll, result.wide.join(' | ')).toBeLessThanOrEqual(0);
	expect(result.bodyScroll).toBeLessThanOrEqual(0);
}

async function shot(name: string) {
	if (SHOTS) await page.screenshot({ path: `${SHOTS}/${name}.png` });
}

for (const width of [320, 390]) {
	for (const scheme of ['light', 'dark'] as const) {
		test(`For you: long options wrap inside the card (${width}px, ${scheme})`, async () => {
			if (width === 320 && scheme === 'light') await ask('Fuer dich');
			await page.emulateMedia({ colorScheme: scheme });
			await page.setViewportSize({ width, height: 900 });
			await page.goto('/fuer-dich');
			const card = page.getByTestId('needs-card').filter({ hasText: 'Frage Fuer dich' });
			await expect(card).toBeVisible();
			await shot(`for-you-${width}-${scheme}`);
			await expectContained(card);
			const last = card.getByRole('button', { name: /^Sehr ausfuehrliche/ });
			await last.scrollIntoViewIfNeeded();
			await expect(last).toBeVisible();
			await last.focus();
			await expect(last).toBeFocused();
		});
	}
}

test('For you: 200% font size keeps options inside the card', async () => {
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 320, height: 900 });
	await page.goto('/fuer-dich');
	await page.addStyleTag({ content: 'html { font-size: 200% !important; }' });
	const card = page.getByTestId('needs-card').filter({ hasText: 'Frage Fuer dich' });
	await expect(card).toBeVisible();
	await expectContained(card);
	await shot('for-you-320-200pct');
});

test('Overview card and task detail: long options wrap (320px, 200%)', async () => {
	const { projectID } = await ask('Ueberblick');
	// The overview only lists projects in "Projektmanagement" mode.
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto(`/projekt/${projectID}`);
	await page.getByTestId('display-menu').click();
	await page.getByTestId('mode-management').click();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('project-tabs')).toBeVisible();
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 320, height: 900 });
	await page.goto('/ueberblick');
	await page.addStyleTag({ content: 'html { font-size: 200% !important; }' });
	await page.getByRole('tab', { name: /Offene Fragen/ }).click();
	await expect(page.getByTestId('question').first()).toBeVisible();
	for (const question of await page.getByTestId('question').all()) await expectContained(question);
	await shot('overview-320-200pct');

	// Board card (question inline) and its detail dialog.
	await page.getByRole('tab', { name: 'Board' }).click();
	const ocCard = page.getByTestId('oc-card').filter({ hasText: 'Ueberblick' }).first();
	await expect(ocCard).toBeVisible();
	await expectContained(ocCard);
	await ocCard.getByTestId('oc-title').click();
	const detailQ = page.getByTestId('card-detail').getByTestId('question').first();
	await expect(detailQ).toBeVisible();
	await expectContained(detailQ);
	await shot('detail-320');
});

test('answering with a long option sends it', async () => {
	await page.setViewportSize({ width: 390, height: 900 });
	await page.goto('/fuer-dich');
	const card = page.getByTestId('needs-card').filter({ hasText: 'Frage Fuer dich' });
	await card.getByRole('button', { name: /^Sehr ausfuehrliche/ }).click();
	await expect(card).toHaveCount(0);
	await expect(page.getByTestId('post-card').filter({ hasText: 'Frage beantwortet' }).first()).toBeVisible();
});
