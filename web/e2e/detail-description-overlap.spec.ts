import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/detail-description-overlap.spec.ts --project=chromium
// A long multi-line (bullet list) description must not run into the sections below it in the card detail.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.SHOTS_DIR ?? '/private/tmp/claude-501/detail-overlap';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

const LONG_WORD = 'Superlangeswortohneleerzeichen'.repeat(8);
const DESCRIPTION = [
	'Auftrag Brain/Orchestrator, Vibecoding-Karten A9C45B0F und F3BABE3F.',
	'',
	'- get_daily_brief (MCP) und REST, Umfang Projekt oder Konto: seit gestern erledigt, läuft, wartet auf Lino (Fragen, Reviews, Bestätigungen), verwaiste Ansprüche, veraltete Projekte; kurz, nach Vorrang sortiert.',
	'- Variante „eine Zeile“ (≤ 200 Zeichen).',
	'- Optional täglicher Push dieser Zeile (Einstellung in Benachrichtigungen, Standard aus).',
	'- Ablauf: Plan an die Karte, Tests, request_review, nach Fertigstellung pushen (Dauerregel).',
	...Array.from({ length: 12 }, (_, i) => `- Punkt ${i + 1}: ${'viel Text in einer Aufzählung, '.repeat(4)}`),
	`- ${LONG_WORD}`,
	'',
	'Abschlussabsatz nach der Liste.'
].join('\n');

let ids = { project: '', task: '' };

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
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
	await page.getByLabel('Anzeigename').fill('Overlap Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
	const project = await post<{ id: string }>('/v1/projects', { name: 'Überlappung' });
	const task = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: 'Tagesbericht mit langer Beschreibung', description: DESCRIPTION });
	await post(`/v1/tasks/${task.id}/progress-notes`, { note: 'Plan: erst Test, dann Fix.', percent: 5 });
	ids = { project: project.id, task: task.id };
});

type Box = { top: number; bottom: number; left: number; right: number };
async function box(selector: string): Promise<Box | null> {
	return page.evaluate((sel) => {
		const el = document.querySelector(sel);
		if (!el) return null;
		const r = el.getBoundingClientRect();
		return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
	}, selector);
}

const cases = [
	{ name: 'desktop-1280', width: 1280, height: 800 },
	{ name: 'mobile-390', width: 390, height: 844 }
];
for (const c of cases) {
	for (const scheme of ['dark', 'light'] as const) {
		test(`long description does not overlap following sections (${c.name}, ${scheme})`, async () => {
			await page.setViewportSize({ width: c.width, height: c.height });
			await page.emulateMedia({ colorScheme: scheme });
			await page.goto(`/for-you?card=task:${ids.task}`);
			await expect(page.getByTestId('card-dialog')).toBeVisible();
			await expect(page.getByTestId('card-description')).toContainText('Abschlussabsatz');
			await expect(page.getByTestId('card-subtask-add')).toBeVisible();
			await page.screenshot({ path: `${SHOTS}/${process.env.SHOT_TAG ?? 'run'}-${c.name}-${scheme}.png` });

			const view = await box('[data-testid="card-description-view"]');
			const text = await box('[data-testid="card-description"]');
			const add = await box('[data-testid="card-subtask-add"]');
			const criteria = await box('[data-testid="card-criteria"]');
			const attachments = await box('[data-testid="card-attachments"]');
			expect(view && text && add, 'description, view and add-subtask row exist').toBeTruthy();
			// The description text must lie inside its own box and end above the next section.
			expect(text!.bottom, 'description text inside its container').toBeLessThanOrEqual(view!.bottom + 1);
			expect(view!.bottom, 'description above subtask row').toBeLessThanOrEqual(add!.top + 1);
			expect(text!.bottom, 'description text above subtask row').toBeLessThanOrEqual(add!.top + 1);
			if (criteria) expect(add!.bottom, 'subtask row above criteria').toBeLessThanOrEqual(criteria.top + 1);
			if (criteria && attachments) expect(criteria.bottom, 'criteria above attachments').toBeLessThanOrEqual(attachments.top + 1);
			// No sideways overflow of the long word.
			const main = await box('[data-testid="card-main"]');
			expect(text!.right, 'description inside main column').toBeLessThanOrEqual(main!.right + 1);
			const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
			expect(w.doc, 'page overflows horizontally').toBeLessThanOrEqual(w.inner);
		});
	}
}
