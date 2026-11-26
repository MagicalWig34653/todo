import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/readability.spec.ts --project=chromium
// Card 8B820AA8, UX step 1 "Lesbarkeit" (design/ux-konzept/konzept.md §7): Markdown on "Für dich" is shown as a short plain
// preview (no raw `**`, `##`, list dashes), explanations show one sentence with the rest behind "Mehr erfahren", the card
// window hides tabs without data, and the phone's plus button covers nothing.
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const PHONE = { width: 390, height: 844 };
const DESKTOP = { width: 1280, height: 800 };
const PROMPT =
	'**Wie soll die Anmeldung weiterlaufen?** - Variante A: Passkey zuerst, `E-Mail` nur als Rückfall - Variante B: beide gleichberechtigt nebeneinander - Variante C: nur Passkey, Rückfall über Wiederherstellungscodes Bitte eine Variante wählen, davon hängt der nächste Schritt ab. Dazu noch ein langer Absatz mit Begründung, warum das wichtig ist, und was danach alles passiert, damit der Text auf dem Handy sicher länger als drei Zeilen wird.';
const NOTE = '## Zwischenstand\n\n- **Tests** grün\n- `npm run build` ok\n- Bilder hell und dunkel';
let ids = { project: '', full: '', empty: '' };

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Lese Tester');
	const project = await post<{ id: string }>('/v1/projects', { name: 'Leseprojekt' });
	const full = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: 'Aufgabe mit Bericht' });
	const empty = await post<{ id: string }>('/v1/tasks', { projectID: project.id, title: 'Leere Aufgabe' });
	await post(`/v1/tasks/${full.id}/progress-notes`, { note: NOTE, percent: 40 });
	await post(`/v1/tasks/${full.id}/questions`, { prompt: PROMPT, options: ['Ja', 'Nein'], agentName: 'Claude Code' });
	ids = { project: project.id, full: full.id, empty: empty.id };
});
test.afterAll(async () => {
	await page?.context().close();
});

for (const [label, size] of [['phone', PHONE], ['desktop', DESKTOP]] as const) {
	test(`${label}: Für dich shows Markdown as a short plain preview, the full text stays in the card`, async () => {
		await page.setViewportSize(size);
		await page.goto('/for-you');
		const card = page.getByTestId('needs-card').filter({ hasText: 'Wie soll die Anmeldung weiterlaufen?' });
		await expect(card).toBeVisible();
		// Headline is the first sentence only, without Markdown marks; the rest is a muted, clamped preview.
		await expect(card.getByTestId('need-title')).toHaveText('Wie soll die Anmeldung weiterlaufen?');
		await expect(card.getByTestId('need-preview')).toContainText('Variante A: Passkey zuerst, E-Mail nur als Rückfall · Variante B');
		const text = (await card.textContent()) ?? '';
		expect(text).not.toMatch(/\*\*|`|##/);
		expect(text).not.toMatch(/Rückfall - Variante/);
		// Short: the preview is clamped (it does not grow with the text).
		const preview = card.getByTestId('need-preview');
		const clamp = await preview.evaluate((el) => ({ h: el.getBoundingClientRect().height, sh: el.scrollHeight, lh: parseFloat(getComputedStyle(el).lineHeight) }));
		expect(clamp.h).toBeLessThanOrEqual(clamp.lh * 3 + 1);
		const head = (await card.getByRole('button').first().boundingBox())!;
		expect(head.height, 'the text part of the card').toBeLessThanOrEqual(label === 'phone' ? 190 : 140);
		// The progress note (Markdown heading and list) as a post: plain text, list items joined.
		const postCard = page.getByTestId('post-card').filter({ hasText: 'Zwischenstand' });
		await expect(postCard).toBeVisible();
		await expect(postCard.getByTestId('post-text')).toHaveText('Zwischenstand · Tests grün · npm run build ok · Bilder hell und dunkel');
		// The card window still shows the whole question.
		await card.getByRole('button').first().click();
		await expect(page.getByTestId('card-dialog')).toBeVisible();
		await expect(page.getByTestId('card-dialog')).toContainText('Dazu noch ein langer Absatz');
		await page.keyboard.press('Escape');
		await expect(page.getByTestId('card-dialog')).toHaveCount(0);
	});
}

test('card window: tabs without data are hidden, a deep link keeps its tab', async () => {
	await page.setViewportSize(DESKTOP);
	const tabs = () => page.getByTestId('card-dialog').getByRole('tab');
	await page.goto(`/for-you?card=task:${ids.empty}`);
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(tabs()).toHaveText(['Übersicht', 'Aktivität']);
	await page.goto(`/for-you?card=task:${ids.full}`);
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	await expect(tabs()).toHaveText(['Übersicht', 'Aktivität', 'Bericht']);
	// Old addresses stay valid: the linked tab is shown with its honest empty state.
	await page.goto(`/for-you?card=task:${ids.empty}&tab=tests`);
	await expect(tabs()).toHaveText(['Übersicht', 'Aktivität', 'Tests']);
	await expect(page.getByTestId('card-dialog').getByRole('tab', { name: 'Tests' })).toHaveAttribute('aria-selected', 'true');
	await expect(page.getByTestId('card-dialog').getByTestId('tab-empty')).toBeVisible();
});

test('explanations: one sentence, the rest behind "Mehr erfahren" (Brain-Vollmacht, Graph, Kalender)', async () => {
	await page.setViewportSize(PHONE);
	await page.goto('/settings/brain-mandate');
	const intro = page.getByTestId('bm-intro');
	await expect(intro).toBeVisible();
	await expect(intro).toContainText('Mit einer Vollmacht darf eine deiner Verbindungen');
	await expect(intro).not.toContainText('Nicht erlaubt');
	expect((await intro.boundingBox())!.height, 'intro is short on the phone').toBeLessThanOrEqual(220);
	await intro.getByRole('button', { name: 'Mehr erfahren' }).click();
	await expect(intro).toContainText('Nicht erlaubt');
	await expect(intro.getByRole('button', { name: 'Weniger' })).toHaveAttribute('aria-expanded', 'true');

	await page.goto(`/project/${ids.project}/graph`);
	const graph = page.getByTestId('task-graph').getByTestId('explainer');
	await expect(graph).toHaveText(/Wie die Historie eines Git-Clients: eine Zeile je Aufgabe, Geplantes oben, Erledigtes unter der Linie „Jetzt“\.\s*Mehr erfahren/);
	await expect(page.getByTestId('task-graph')).not.toContainText('Ein Feature verzweigt');

	await page.goto('/calendar');
	await expect(page.getByTestId('view-heading')).toBeVisible();
	const head = page.getByRole('main').getByTestId('explainer').first();
	await expect(head).toContainText('Geplanter Start und Dauer pro Karte.');
	await expect(head).not.toContainText('Ziehen verschiebt');
	await head.getByRole('button', { name: 'Mehr erfahren' }).click();
	await expect(head).toContainText('Ziehen verschiebt den Start');
});

test('phone: the plus button sits in the header and covers no content', async () => {
	await page.setViewportSize(PHONE);
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		for (const path of ['/for-you', `/project/${ids.project}/list`]) {
			await page.goto(path);
			const fab = page.getByTestId('fab');
			await expect(fab).toBeVisible();
			const header = (await page.getByTestId('app-header').boundingBox())!;
			const box = (await fab.boundingBox())!;
			expect(box.y, `${path}: inside the header`).toBeGreaterThanOrEqual(header.y - 1);
			expect(box.y + box.height, `${path}: inside the header`).toBeLessThanOrEqual(header.y + header.height + 1);
			// Scrolled down, nothing of the main content lies under the button (the header covers it, the button adds nothing).
			await page.evaluate(() => window.scrollTo(0, 400));
			const hit = await page.evaluate(({ x, y }) => document.elementFromPoint(x, y)?.closest('[data-testid="fab"]') !== null, { x: box.x + box.width / 2, y: box.y + box.height / 2 });
			expect(hit).toBe(true);
			const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
			if (await nav.count()) expect(await nav.locator('[data-testid="fab"]').count()).toBe(0);
		}
		await fabOpensQuickAdd();
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize(DESKTOP);
	await expect(page.getByTestId('fab')).toBeHidden();
});

async function fabOpensQuickAdd() {
	await page.getByTestId('fab').click();
	await expect(page.getByRole('dialog')).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);
}
