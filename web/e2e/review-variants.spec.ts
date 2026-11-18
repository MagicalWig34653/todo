import { expect, test, type Locator, type Page } from '@playwright/test';
import { readFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signedInPage } from './support/session';

// Card 1D9C8B0C, stage 2 (PWA): review with variants, against the real backend. Needs a fresh backend database
// (bootstrap happens here). Run on its own, one project at a time:
//   npx playwright test e2e/review-variants.spec.ts --project=chromium   (also webkit, mobile-safari)
// The images are the invented example graphics of the design draft; they go through the real attachment upload.
const HERE = dirname(fileURLToPath(import.meta.url));
const SHOTS = resolve(HERE, '../../docs/screenshots/review-variants/ergebnis');
const IMAGES = resolve(HERE, '../../docs/screenshots/review-variants/entwurf/bilder');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

interface Variant { id: string; label: string; description?: string; attachmentID?: string }
interface Made { taskID: string; reviewID: string; title: string }
interface ReviewState { id: string; state: string; chosenVariantID?: string; variants?: Variant[]; decisionNote?: string }
const made: Record<string, Made> = {};

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
/** begin, PUT with the capability token, complete: the same three REST calls the app makes. */
async function upload(taskID: string, filename: string, mediaType: string, bytes: Buffer): Promise<string> {
	const cap = await post<{ attachmentID: string; uploadURL: string; token: string }>('/v1/attachments/begin', {
		taskID, filename, role: 'result', mediaType, size: bytes.length, checksum: createHash('sha256').update(bytes).digest('hex')
	});
	const put = await page.request.put(cap.uploadURL, { headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, data: bytes });
	expect(put.status(), 'upload').toBe(204);
	await post(`/v1/attachments/${cap.attachmentID}/complete`, {});
	return cap.attachmentID;
}
const image = (name: string) => readFileSync(resolve(IMAGES, `${name}.png`));
const PDF = Buffer.from('%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 10 10]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');

let projectID = '';
async function makeReview(key: string, title: string, variants: Variant[] | null, summary = `Ergebnis zu ${title}.\n- Neu: Prototyp\n- Offen: Entscheidung`): Promise<Made> {
	const t = await post<{ id: string }>('/v1/tasks', { projectID, title });
	const r = await post<{ id: string }>(`/v1/tasks/${t.id}/review`, { summary, agentName: 'Claude Code', ...(variants ? { variants } : {}) });
	return (made[key] = { taskID: t.id, reviewID: r.id, title });
}
const status = async (taskID: string) => ((await (await page.request.get(`/v1/tasks/${taskID}/context`)).json()) as { task: { status: string } }).task.status;
const review = async (m: Made) => ((await (await page.request.get('/v1/reviews?state=all&limit=200')).json()) as ReviewState[]).find((r) => r.id === m.reviewID)!;
const contextReview = async (m: Made) => ((await (await page.request.get(`/v1/tasks/${m.taskID}/context`)).json()) as { review: ReviewState }).review;

const rows = () => page.getByTestId('cc-reviews').getByTestId('review-row');
const row = (m: Made) => rows().filter({ hasText: m.title });
const dialog = () => page.getByTestId('card-dialog');
const choose = (scope: Locator, name: string) => scope.getByRole('button', { name });
async function openReviews() {
	await page.goto('/overview');
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}
async function noOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
async function imagesLoaded(scope: Locator, count: number) {
	const imgs = scope.getByTestId('review-variant-image');
	await expect(imgs).toHaveCount(count);
	await expect.poll(() => imgs.evaluateAll((els) => els.filter((e) => (e as HTMLImageElement).complete && (e as HTMLImageElement).naturalWidth > 0).length)).toBe(count);
}
/** Result images: Chromium gets the full set (light and dark), the other projects the two that show engine differences most. */
const WANTED: Record<string, string[]> = {
	chromium: ['01-ueberblick', '02-kartendetail', '03-nach-wahl-leiste', '04-sammelfreigabe', '05-mobil', '06-fokus-tastatur'],
	webkit: ['01-ueberblick', '02-kartendetail'],
	'mobile-safari': ['05-mobil']
};
const DARK = new Set(['chromium']);
async function shot(name: string) {
	const project = test.info().project.name;
	if (!(WANTED[project] ?? []).includes(name)) return;
	const prefix = project === 'chromium' ? '' : `${project}-`;
	await page.waitForTimeout(400);
	await page.screenshot({ path: `${SHOTS}/${prefix}${name}-hell.png` });
	// The real app in the dark colour scheme (system setting emulated; the PWA follows it in the default "System" mode).
	if (DARK.has(project)) {
		await page.emulateMedia({ colorScheme: 'dark' });
		await page.waitForTimeout(400);
		await page.screenshot({ path: `${SHOTS}/dunkel/${prefix}${name}-dunkel.png` });
		await page.emulateMedia({ colorScheme: 'light' });
	}
}
/** "noch 4:32" -> seconds. */
async function undoSeconds(scope: Locator): Promise<number> {
	const text = (await scope.getByTestId('review-undo-time').textContent()) ?? '';
	const m = text.match(/(\d+):(\d{2})/);
	expect(m, `undo time in "${text}"`).not.toBeNull();
	return Number(m![1]) * 60 + Number(m![2]);
}

test.beforeAll(async ({ browser }) => {
	mkdirSync(`${SHOTS}/dunkel`, { recursive: true });
	page = await signedInPage(browser, 'Varianten Tester');
	await page.setViewportSize({ width: 1280, height: 900 });
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'ShowerNow' })).id;
	// The management view lists the project in the account overview (same preparation as reviews-bulk).
	await page.goto(`/project/${projectID}`);
	if (!(await page.getByTestId('project-tabs').isVisible())) {
		await page.getByTestId('display-menu').click();
		await page.getByTestId('mode-management').click();
		await page.keyboard.press('Escape');
	}
	await expect(page.getByTestId('project-tabs')).toBeVisible();

	// V1: two variants with images (the main flow).
	const v1 = await post<{ id: string }>('/v1/tasks', { projectID, title: 'Kartenwahl Regenvorhersage' });
	const wind = await upload(v1.id, 'windkarte.png', 'image/png', image('windkarte'));
	const radar = await upload(v1.id, 'radarkarte.png', 'image/png', image('radarkarte'));
	const r1 = await post<{ id: string }>(`/v1/tasks/${v1.id}/review`, {
		summary: 'Zwei Kartenarten sind als Prototyp fertig. Welche kommt in die Regenvorhersage?',
		agentName: 'Claude Code',
		variants: [
			{ id: 'a', label: 'Windkarte', description: 'Pfeile zeigen Richtung und Stärke des Winds.', attachmentID: wind },
			{ id: 'b', label: 'Radarkarte', description: 'Regen der nächsten Stunde im Fünf-Minuten-Raster.', attachmentID: radar }
		]
	});
	made.v1 = { taskID: v1.id, reviewID: r1.id, title: 'Kartenwahl Regenvorhersage' };

	// V2: three variants, mixed: A with image, B without any attachment (compact card, no picture area), C whose attachment is a PDF (no inline preview, compact fallback).
	const v2 = await post<{ id: string }>('/v1/tasks', { projectID, title: 'Farbschema Warnstufen' });
	const temp = await upload(v2.id, 'temperaturkarte.png', 'image/png', image('temperaturkarte'));
	const pdf = await upload(v2.id, 'skizze.pdf', 'application/pdf', PDF);
	const r2 = await post<{ id: string }>(`/v1/tasks/${v2.id}/review`, {
		summary: 'Drei Farbschemata zur Auswahl.',
		agentName: 'Claude Code',
		variants: [
			{ id: 'a', label: 'Ampel', description: 'Grün, Gelb, Rot.', attachmentID: temp },
			{ id: 'b', label: 'Blau-Orange', description: 'Auch bei Farbfehlsichtigkeit gut lesbar.' },
			{ id: 'c', label: 'Monochrom', description: 'Nur Helligkeitsstufen.', attachmentID: pdf }
		]
	});
	made.v2 = { taskID: v2.id, reviewID: r2.id, title: 'Farbschema Warnstufen' };

	const two = (a: string, b: string): Variant[] => [{ id: 'a', label: a }, { id: 'b', label: b }];
	await makeReview('v5', 'Wahl per Leertaste', two('Links', 'Rechts'));
	await makeReview('v6', 'Änderung statt Wahl', two('Kurz', 'Lang'));
	// V3 has images too (its rows show in the bulk and mobile screenshots).
	const v3 = await post<{ id: string }>('/v1/tasks', { projectID, title: 'Bulk Variante Eins' });
	const w3 = await upload(v3.id, 'windkarte.png', 'image/png', image('windkarte'));
	const r3 = await upload(v3.id, 'radarkarte.png', 'image/png', image('radarkarte'));
	const rv3 = await post<{ id: string }>(`/v1/tasks/${v3.id}/review`, {
		summary: 'Zwei Kartenarten, noch ohne Entscheidung.',
		agentName: 'Claude Code',
		variants: [
			{ id: 'a', label: 'Eins A', description: 'Pfeile zeigen Richtung und Stärke des Winds.', attachmentID: w3 },
			{ id: 'b', label: 'Eins B', description: 'Regen der nächsten Stunde im Fünf-Minuten-Raster.', attachmentID: r3 }
		]
	});
	made.v3 = { taskID: v3.id, reviewID: rv3.id, title: 'Bulk Variante Eins' };
	await makeReview('v4', 'Bulk Variante Zwei', two('Zwei A', 'Zwei B'));
	await makeReview('n1', 'Bulk Normal Eins', null, 'Messung ist fertig: Startseite lädt in 0,8 s.');
	await makeReview('n2', 'Bulk Normal Zwei', null, 'Alle deutschen Texte sind geprüft.');
	await makeReview('plain', 'Ladezeit messen', null, 'Messung ist fertig: Startseite lädt in 0,8 s.');
});
test.afterAll(async () => {
	await page?.context().close();
});

test('the server delivers the variants and the app shows A and B in the overview and in the card detail', async () => {
	const server = await review(made.v1);
	expect(server.variants?.map((v) => v.id)).toEqual(['a', 'b']);
	expect(server.chosenVariantID ?? null).toBeNull();

	await openReviews();
	const r = row(made.v1);
	await expect(r.getByTestId('review-variant')).toHaveCount(2);
	await expect(r.getByTestId('review-choice-badge')).toHaveText('Wahl nötig');
	await expect(r.getByTestId('review-accept')).toHaveCount(0);
	await expect(choose(r, 'Wählen: Variante A, Windkarte')).toBeVisible();
	await expect(choose(r, 'Wählen: Variante B, Radarkarte')).toBeVisible();
	await expect(choose(r, 'Wählen: Variante B, Radarkarte')).toHaveText('Wählen');
	await expect(r.getByRole('heading', { name: /Variante B: Radarkarte/ })).toBeVisible();
	await imagesLoaded(r, 2);
	// The note field and "Änderungen anfordern" stay.
	await expect(r.getByTestId('review-note')).toBeVisible();
	await expect(r.getByRole('button', { name: 'Änderungen anfordern' })).toBeVisible();
	// The hint names the real undo window (one source: REVIEW_UNDO_MINUTES = server window of 5 minutes).
	await expect(r.getByTestId('review-variants-hint')).toContainText('Danach bleiben 5 Minuten zum Rückgängigmachen.');
	await r.evaluate((el) => el.scrollIntoView({ block: 'start' }));
	await page.evaluate(() => window.scrollBy(0, -70));
	await shot('01-ueberblick');

	await r.getByTestId('card-open').click();
	await expect(dialog()).toBeVisible();
	const detail = dialog().getByTestId('card-decide');
	await expect(detail.getByTestId('review-variant')).toHaveCount(2);
	await expect(detail.getByTestId('review-accept')).toHaveCount(0);
	await imagesLoaded(detail, 2);
	await shot('02-kartendetail');
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
});

test('no empty picture area: a variant without attachment is a compact card; a broken attachment gets a small fallback with the label', async () => {
	await openReviews();
	const r = row(made.v2);
	const cards = r.getByTestId('review-variant');
	await expect(cards).toHaveCount(3);
	// C has a PDF, whose preview answers 415, so its broken image turns into the fallback (after the failed load; the images load
	// lazily, so bring the last variant into view first).
	await cards.nth(2).scrollIntoViewIfNeeded();
	await expect(cards.nth(2).getByTestId('review-variant-placeholder')).toBeVisible();
	// A (image) shows the picture, B (no attachment) has neither picture nor placeholder, C only the fallback.
	await expect(cards.nth(0).getByTestId('review-variant-image')).toBeVisible();
	await expect(cards.nth(0).getByTestId('review-variant-placeholder')).toHaveCount(0);
	await expect(cards.nth(1).getByTestId('review-variant-image')).toHaveCount(0);
	await expect(cards.nth(1).getByTestId('review-variant-placeholder')).toHaveCount(0);
	await expect(cards.nth(1).locator('img, svg')).toHaveCount(0);
	await expect(cards.nth(2).getByTestId('review-variant-image')).toHaveCount(0);
	await expect(cards.nth(2).getByTestId('review-variant-placeholder')).toContainText('Monochrom');
	await expect.poll(() => cards.nth(0).getByTestId('review-variant-image').evaluate((e) => (e as HTMLImageElement).naturalWidth > 0)).toBe(true);
	// Compact: the card of B is clearly smaller than the picture, the fallback is a small line, not a picture-sized area.
	const [compact, fallback, imgBox] = await Promise.all([
		cards.nth(1).boundingBox(),
		cards.nth(2).getByTestId('review-variant-placeholder').boundingBox(),
		cards.nth(0).getByTestId('review-variant-image').boundingBox()
	]);
	expect(fallback!.height, 'fallback').toBeLessThan(imgBox!.height / 2);
	expect(compact!.height, 'card without picture').toBeGreaterThan(0);
	// Text and choice stay complete and usable.
	await expect(cards.nth(1)).toContainText('Variante B');
	await expect(cards.nth(1)).toContainText('Blau-Orange');
	await expect(cards.nth(1)).toContainText('Auch bei Farbfehlsichtigkeit gut lesbar.');
	await expect(choose(r, 'Wählen: Variante B, Blau-Orange')).toBeEnabled();
	await expect(choose(r, 'Wählen: Variante C, Monochrom')).toBeEnabled();
});

test('card detail: text-only variants show no picture area; choosing one shows the chosen variant without a picture', async () => {
	await makeReview('t1', 'Wetterdaten-Anbieter', [
		{ id: 'a', label: 'Anbieter A', description: 'Stündliche Werte, kostenlos bis 10 000 Abrufe am Tag.' },
		{ id: 'b', label: 'Anbieter B', description: 'Minutengenaue Regenwerte, dafür kostenpflichtig.' }
	]);
	await openReviews();
	const r = row(made.t1);
	await expect(r.getByTestId('review-variant')).toHaveCount(2);
	await expect(r.locator('[data-testid=review-variant] img, [data-testid=review-variant] svg')).toHaveCount(0);
	await expect(r.getByTestId('review-variant-placeholder')).toHaveCount(0);
	await r.getByTestId('card-open').click();
	const detail = dialog().getByTestId('card-decide');
	await expect(detail.getByTestId('review-variant')).toHaveCount(2);
	await expect(detail.getByTestId('review-variant-image')).toHaveCount(0);
	await expect(detail.getByTestId('review-variant-placeholder')).toHaveCount(0);
	await choose(detail, 'Wählen: Variante B, Anbieter B').click();
	const chosen = dialog().getByTestId('card-review-result').getByTestId('review-chosen');
	await expect(chosen).toContainText('Anbieter B');
	await expect(chosen).toContainText('Minutengenaue Regenwerte, dafür kostenpflichtig.');
	await expect(chosen.locator('img, svg')).toHaveCount(0);
	await expect(chosen.getByTestId('review-chosen-fallback')).toHaveCount(0);
	expect((await review(made.t1)).chosenVariantID).toBe('b');
	await page.keyboard.press('Escape');
});

test('card detail: a chosen variant whose attachment cannot be previewed shows the compact fallback with its label', async () => {
	const t = await post<{ id: string }>('/v1/tasks', { projectID, title: 'Skizze als PDF' });
	const pdf = await upload(t.id, 'skizze.pdf', 'application/pdf', PDF);
	const rv = await post<{ id: string }>(`/v1/tasks/${t.id}/review`, {
		summary: 'Zwei Entwürfe.', agentName: 'Claude Code',
		variants: [{ id: 'a', label: 'Nur Text', description: 'Ohne Anhang.' }, { id: 'b', label: 'Als PDF', description: 'Anhang ohne Vorschau.', attachmentID: pdf }]
	});
	made.tc = { taskID: t.id, reviewID: rv.id, title: 'Skizze als PDF' };
	await openReviews();
	await row(made.tc).getByTestId('card-open').click();
	await choose(dialog().getByTestId('card-decide'), 'Wählen: Variante B, Als PDF').click();
	const chosen = dialog().getByTestId('card-review-result').getByTestId('review-chosen');
	await expect(chosen.getByTestId('review-chosen-fallback')).toBeVisible();
	await expect(chosen.getByTestId('review-chosen-fallback')).toContainText('Als PDF');
	const box = (await chosen.getByTestId('review-chosen-fallback').boundingBox())!;
	expect(box.height).toBeLessThan(60);
	await page.keyboard.press('Escape');
});

test('one tap on "Wählen" accepts with that variant; the toast names the choice and the real undo window', async () => {
	await openReviews();
	const r = row(made.v1);
	await choose(r, 'Wählen: Variante B, Radarkarte').click();
	// One click, no extra dialog: the row is gone, the review is accepted with the variant, the task is done.
	await expect(row(made.v1)).toHaveCount(0);
	const server = await review(made.v1);
	expect(server.state).toBe('accepted');
	expect(server.chosenVariantID).toBe('b');
	expect(await status(made.v1.taskID)).toBe('done');
	const toast = page.getByTestId('review-undo-toast');
	await expect(toast).toBeVisible();
	await expect(toast.getByTestId('review-undo-message')).toHaveText('Variante B gewählt: Radarkarte');
	const left = await undoSeconds(toast);
	expect(left).toBeGreaterThan(4 * 60 + 40);
	expect(left).toBeLessThanOrEqual(5 * 60);
	await expect(toast.getByTestId('review-undo')).toBeVisible();
});

test('undo puts the review back to pending with all variants; the choice is open again', async () => {
	await page.getByTestId('review-undo-toast').getByTestId('review-undo').click();
	await expect(page.getByTestId('review-undo-toast')).toHaveCount(0);
	await expect.poll(async () => (await review(made.v1)).state).toBe('pending');
	const server = await review(made.v1);
	expect(server.chosenVariantID ?? null).toBeNull();
	expect(server.variants?.map((v) => v.id)).toEqual(['a', 'b']);
	expect(await status(made.v1.taskID)).toBe('in_review');
	await openReviews();
	await expect(row(made.v1).getByTestId('review-variant')).toHaveCount(2);
	await expect(choose(row(made.v1), 'Wählen: Variante B, Radarkarte')).toBeEnabled();
});

test('card detail: the choice shows bar, chosen variant and history (chat line and activity)', async () => {
	await openReviews();
	await row(made.v1).getByTestId('card-open').click();
	await expect(dialog()).toBeVisible();
	await choose(dialog().getByTestId('card-decide'), 'Wählen: Variante B, Radarkarte').click();
	const result = dialog().getByTestId('card-review-result');
	await expect(result).toBeVisible();
	await expect(result.getByTestId('review-chosen-badge')).toHaveText('Variante B gewählt');
	const bar = result.getByTestId('review-undo-bar');
	await expect(bar.getByTestId('review-undo-message')).toHaveText('Variante B gewählt: Radarkarte');
	const left = await undoSeconds(bar);
	expect(left).toBeGreaterThan(4 * 60 + 40);
	expect(left).toBeLessThanOrEqual(5 * 60);
	await expect(bar.getByTestId('review-undo-time')).toContainText('noch 4:');
	await expect(result.getByTestId('review-chosen')).toContainText('Radarkarte');
	await expect(result.getByTestId('review-chosen')).toContainText('Nicht gewählt:');
	await expect(result.getByTestId('review-chosen')).toContainText('A Windkarte');
	// History: the server writes the choice as a chat line on the review; it is shown with the conversation.
	await expect(result).toContainText('Variante B gewählt: Radarkarte');
	// The chat of the review is the real history: choice, undo, choice again (the first choice was taken back in the test before).
	const chat = result.getByRole('region', { name: 'Unterhaltung zum Review' });
	await expect(chat.getByText('Variante B gewählt: Radarkarte', { exact: true })).toHaveCount(2);
	await expect(chat.getByText('Freigabe zurückgenommen.', { exact: true })).toHaveCount(1);
	await shot('03-nach-wahl-leiste');
	// Activity tab: the accepting decision names the variant.
	await dialog().getByRole('tab', { name: /Aktivität/ }).click();
	// Two accepting entries exist (the first one was taken back); only the newest names the current choice.
	await expect(dialog().getByTestId('activity').filter({ hasText: 'Review angenommen' })).toHaveCount(2);
	await expect(dialog().getByTestId('activity-choice')).toHaveCount(1);
	await expect(dialog().getByTestId('activity-choice')).toHaveText('Variante B gewählt: Radarkarte');
	// The server's own feed text carries the choice, too.
	const server = await contextReview(made.v1);
	expect(server.chosenVariantID).toBe('b');
	await page.keyboard.press('Escape');
});

// Safari/WebKit on macOS skips buttons with plain Tab (system setting "Tab highlights each item"); Option+Tab is its way.
// The arrow keys are independent of that setting.
const tabKey = () => (test.info().project.use.browserName === 'webkit' || test.info().project.name.includes('safari') ? 'Alt+Tab' : 'Tab');
const focusedName = () => page.evaluate(() => document.activeElement?.getAttribute('aria-label') ?? '');
/** Tab from the filter bar until the first "Wählen" button of the group is focused. */
async function tabInto(firstName: string) {
	await page.getByTestId('review-filter-all').focus();
	let seen = '';
	for (let i = 0; i < 200 && seen !== firstName; i++) {
		await page.keyboard.press(tabKey());
		seen = await focusedName();
	}
	expect(seen).toBe(firstName);
}

test('keyboard: the variants of a review are one group with one tab stop; ArrowRight moves to the second, Enter chooses it', async () => {
	await makeReview('k2', 'Tastatur zwei Varianten', [{ id: 'a', label: 'Links' }, { id: 'b', label: 'Rechts' }]);
	await openReviews();
	const r = row(made.k2);
	const group = r.getByRole('group', { name: 'Wähle eine Variante' });
	await expect(group).toBeVisible();
	// Roving tab index: exactly one "Wählen" button of the group is a tab stop.
	await expect(group.locator('[data-testid=review-variant-choose][tabindex="0"]')).toHaveCount(1);
	await expect(group.locator('[data-testid=review-variant-choose][tabindex="-1"]')).toHaveCount(1);
	await tabInto('Wählen: Variante A, Links');
	await page.keyboard.press('ArrowRight');
	await expect(choose(r, 'Wählen: Variante B, Rechts')).toBeFocused();
	await page.keyboard.press('Enter');
	await expect.poll(async () => (await review(made.k2)).state).toBe('accepted');
	expect((await review(made.k2)).chosenVariantID).toBe('b');
	await expect(page.getByTestId('review-undo-toast').getByTestId('review-undo-message')).toHaveText('Variante B gewählt: Rechts');
});

test('keyboard: three variants, ArrowRight twice and ArrowLeft once choose the middle one; Tab leaves the group; Shift+Tab returns to the last one', async () => {
	await makeReview('k3', 'Tastatur drei Varianten', [{ id: 'a', label: 'Eins' }, { id: 'b', label: 'Zwei' }, { id: 'c', label: 'Drei' }]);
	await openReviews();
	const r = row(made.k3);
	await tabInto('Wählen: Variante A, Eins');
	await page.keyboard.press('ArrowRight');
	await page.keyboard.press('ArrowRight');
	await expect(choose(r, 'Wählen: Variante C, Drei')).toBeFocused();
	// The ends stop (no wrapping), ArrowDown/Up work like Right/Left, Home/End jump.
	await page.keyboard.press('ArrowDown');
	await expect(choose(r, 'Wählen: Variante C, Drei')).toBeFocused();
	await page.keyboard.press('Home');
	await expect(choose(r, 'Wählen: Variante A, Eins')).toBeFocused();
	await page.keyboard.press('ArrowLeft');
	await expect(choose(r, 'Wählen: Variante A, Eins')).toBeFocused();
	await page.keyboard.press('End');
	await expect(choose(r, 'Wählen: Variante C, Drei')).toBeFocused();
	await page.keyboard.press('ArrowLeft');
	await expect(choose(r, 'Wählen: Variante B, Zwei')).toBeFocused();
	// The focus ring on the arrow-selected button is visible.
	const ring = await choose(r, 'Wählen: Variante B, Zwei').evaluate((el) => { const s = getComputedStyle(el); return `${s.outlineStyle}|${s.boxShadow}`; });
	expect(ring).not.toBe('none|none');
	await shot('06-fokus-tastatur');
	// Only one tab stop per group: Tab leaves it (the note field is next), Shift+Tab returns to the last focused variant, not to A.
	await page.keyboard.press(tabKey());
	expect(await focusedName()).not.toMatch(/^Wählen: Variante/);
	await expect(r.getByTestId('review-note')).toBeFocused();
	await page.keyboard.press(`Shift+${tabKey()}`);
	await expect(choose(r, 'Wählen: Variante B, Zwei')).toBeFocused();
	// No focus loss after a re-render: a new review arrives through the live refresh while the focus sits on the variant.
	await makeReview('k4', 'Neu während der Wahl', null, 'Neues Review ohne Varianten.');
	await expect(row(made.k4)).toBeVisible({ timeout: 15_000 });
	await expect(choose(r, 'Wählen: Variante B, Zwei')).toBeFocused();
	await page.keyboard.press('Enter');
	await expect.poll(async () => (await review(made.k3)).state).toBe('accepted');
	expect((await review(made.k3)).chosenVariantID).toBe('b');
	// k4 was only there to trigger the re-render.
	await post(`/v1/tasks/${made.k4.taskID}/review/decision`, { decision: 'accept' });
});

test('keyboard: Tab (Option+Tab in Safari) reaches "Wählen" with one stop per group; Enter and Space choose without further dialog', async () => {
	await openReviews();
	const r = row(made.v2);
	await tabInto('Wählen: Variante A, Ampel');
	// One tab stop per group: the next Tab does not go to variant B.
	await page.keyboard.press(tabKey());
	expect(await focusedName()).not.toBe('Wählen: Variante B, Blau-Orange');
	await page.keyboard.press(`Shift+${tabKey()}`);
	await expect(choose(r, 'Wählen: Variante A, Ampel')).toBeFocused();
	await page.keyboard.press('ArrowRight');
	await expect(choose(r, 'Wählen: Variante B, Blau-Orange')).toBeFocused();
	await page.keyboard.press('Enter');
	await expect.poll(async () => (await review(made.v2)).state).toBe('accepted');
	expect((await review(made.v2)).chosenVariantID).toBe('b');
	await expect(page.getByTestId('review-undo-toast').getByTestId('review-undo-message')).toHaveText('Variante B gewählt: Blau-Orange');

	await openReviews();
	await choose(row(made.v5), 'Wählen: Variante A, Links').focus();
	await page.keyboard.press('Space');
	await expect.poll(async () => (await review(made.v5)).state).toBe('accepted');
	expect((await review(made.v5)).chosenVariantID).toBe('a');
});

test('"Änderungen anfordern" with a note works without a variant', async () => {
	await openReviews();
	const r = row(made.v6);
	await r.getByRole('button', { name: 'Änderungen anfordern' }).click();
	await expect(r.getByText('Bitte beschreibe, was geändert werden soll.')).toBeVisible();
	await r.getByTestId('review-note').fill('Bitte beide Längen zeigen');
	await r.getByRole('button', { name: 'Änderungen anfordern' }).click();
	await expect.poll(async () => (await review(made.v6)).state).toBe('changes_requested');
	const server = await review(made.v6);
	expect(server.chosenVariantID ?? null).toBeNull();
	expect(server.decisionNote).toBe('Bitte beide Längen zeigen');
	expect(await status(made.v6.taskID)).toBe('in_progress');
});

test('a review without variants is unchanged: "Freigeben", no variant UI, no variant in the request', async () => {
	await openReviews();
	const r = row(made.plain);
	await expect(r.getByTestId('review-variant')).toHaveCount(0);
	await expect(r.getByTestId('review-choice-badge')).toHaveCount(0);
	await expect(r.getByTestId('review-select')).toBeEnabled();
	let body = '';
	page.on('request', (q) => {
		if (q.method() === 'POST' && q.url().includes(`/tasks/${made.plain.taskID}/review/decision`)) body = q.postData() ?? '';
	});
	await r.getByTestId('review-accept').click();
	await expect(row(made.plain)).toHaveCount(0);
	expect(JSON.parse(body)).toEqual({ decision: 'accept' });
	expect(await status(made.plain.taskID)).toBe('done');
	const server = await review(made.plain);
	expect(server.state).toBe('accepted');
	expect(server.chosenVariantID ?? null).toBeNull();
	await expect(page.getByTestId('review-undo-toast').getByTestId('review-undo-message')).toHaveText('Entscheidung gespeichert.');
});

test('bulk release: variant reviews are not selectable and say why; the normal ones are accepted, the variant ones stay pending', async () => {
	await openReviews();
	await expect(rows()).toHaveCount(4);
	for (const k of ['v3', 'v4']) {
		const box = row(made[k]).getByTestId('review-select');
		await expect(box).toBeDisabled();
		await expect(box).toHaveAccessibleName(`Review auswählen: ${made[k].title} (nicht sammelbar)`);
	}
	for (const k of ['n1', 'n2']) await expect(row(made[k]).getByTestId('review-select')).toBeEnabled();
	await expect(page.getByTestId('review-bulk-variants-hint')).toContainText('2 Reviews mit Varianten brauchen eine Wahl.');
	await expect(page.getByText('Alle auswählbaren auswählen')).toBeVisible();

	await page.getByTestId('review-select-all').check();
	await expect(page.getByTestId('review-bulk-count')).toHaveText('2 ausgewählt');
	await expect(page.getByTestId('review-bulk-bar').getByTestId('review-bulk-variants-hint')).toContainText('2 Reviews mit Varianten brauchen eine Wahl.');
	// Tall viewport so that the rows with variants and the bar are in one picture.
	await page.setViewportSize({ width: 1280, height: 1900 });
	await page.evaluate(() => window.scrollTo(0, 0));
	await shot('04-sammelfreigabe');
	await page.setViewportSize({ width: 1280, height: 900 });
	await page.getByTestId('review-bulk-accept').click();
	await expect(page.getByTestId('review-bulk-confirm')).toContainText('2 Reviews annehmen?');
	await page.getByTestId('review-bulk-confirm-go').click();
	await expect(page.getByTestId('review-bulk-result')).toHaveText(/2 Reviews angenommen\./);
	for (const k of ['n1', 'n2']) {
		expect((await review(made[k])).state).toBe('accepted');
		expect(await status(made[k].taskID)).toBe('done');
	}
	for (const k of ['v3', 'v4']) {
		expect((await review(made[k])).state).toBe('pending');
		expect(await status(made[k].taskID)).toBe('in_review');
		await expect(row(made[k])).toBeVisible();
	}
	// The server refuses accepting a variant review in a batch on its own: the UI shows that as a single failure reason.
	const direct = await post<{ results: { reviewID: string; result: string; reason?: string }[] }>('/v1/reviews/decisions', { decisions: [{ reviewID: made.v3.reviewID }], decision: 'accept' });
	expect(direct.results[0]).toMatchObject({ result: 'invalid', reason: 'variant_required' });
	expect((await review(made.v3)).state).toBe('pending');
});

test('mobile (iPhone viewport): variants stand one below the other, tap targets >= 44 px, nothing overflows', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await openReviews();
	const r = row(made.v3);
	await expect(r.getByTestId('review-variant')).toHaveCount(2);
	const a = (await r.getByTestId('review-variant').nth(0).boundingBox())!;
	const b = (await r.getByTestId('review-variant').nth(1).boundingBox())!;
	expect(Math.abs(a.x - b.x), 'same column').toBeLessThan(2);
	expect(b.y, 'below').toBeGreaterThan(a.y + a.height - 1);
	for (const btn of await r.getByTestId('review-variant-choose').all()) {
		const box = (await btn.boundingBox())!;
		expect(box.height).toBeGreaterThanOrEqual(44);
		expect(box.width).toBeGreaterThan(150);
	}
	await noOverflow('overview');
	await expect(r.getByTestId('review-variants-hint')).toBeVisible();
	await r.getByTestId('review-variant').nth(0).scrollIntoViewIfNeeded();
	await shot('05-mobil');
	// One click/tap decides (the mobile-safari project emulates touch).
	await choose(row(made.v4), 'Wählen: Variante B, Zwei B').click();
	await expect.poll(async () => (await review(made.v4)).state).toBe('accepted');
	expect((await review(made.v4)).chosenVariantID).toBe('b');
	await noOverflow('after choice');
	await page.setViewportSize({ width: 1280, height: 900 });
});
