import { devices, expect, test, type Locator, type Page } from '@playwright/test';
import { readFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signedInPage } from './support/session';

// Card 1D9C8B0C: example pictures of the real app for the owner's review (NOT part of the mandatory suite, it only produces images).
// A realistic choice situation: project "ShowerNow", a map choice with three pictures and a text-only choice between two weather
// data providers, in light and dark, on desktop and on a phone. Needs a fresh backend database; run on its own:
//   DEMO_SHOTS=1 npx playwright test e2e/review-variants-demo.spec.ts --project=chromium
// The pictures are the invented example graphics of the design draft (docs/screenshots/review-variants/entwurf/bilder); they go
// through the real attachment upload. Output: docs/screenshots/review-variants/beispiele/.
const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(HERE, '../../docs/screenshots/review-variants/beispiele');
const IMAGES = resolve(HERE, '../../docs/screenshots/review-variants/entwurf/bilder');
test.describe.configure({ mode: 'serial' });
test.skip(!process.env.DEMO_SHOTS, 'only produces example images: DEMO_SHOTS=1');

let desktop: Page;
let phone: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const MAPS = 'Kartenwahl für die Regenvorhersage';
const PROVIDERS = 'Wetterdaten-Anbieter wählen';

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await desktop.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
async function upload(taskID: string, filename: string, bytes: Buffer): Promise<string> {
	const cap = await post<{ attachmentID: string; uploadURL: string; token: string }>('/v1/attachments/begin', {
		taskID, filename, role: 'result', mediaType: 'image/png', size: bytes.length, checksum: createHash('sha256').update(bytes).digest('hex')
	});
	const put = await desktop.request.put(cap.uploadURL, { headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, data: bytes });
	expect(put.status(), 'upload').toBe(204);
	await post(`/v1/attachments/${cap.attachmentID}/complete`, {});
	return cap.attachmentID;
}
const image = (name: string) => readFileSync(resolve(IMAGES, `${name}.png`));

/** Light and dark picture of the current state (the PWA follows the system scheme in its default mode). */
async function snap(page: Page, name: string, target?: Locator) {
	for (const [scheme, suffix] of [['light', 'hell'], ['dark', 'dunkel']] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.waitForTimeout(500);
		await (target ?? page).screenshot({ path: `${OUT}/${name}-${suffix}.png` });
	}
	await page.emulateMedia({ colorScheme: 'light' });
}
const rowOf = (page: Page, title: string) => page.getByTestId('cc-reviews').getByTestId('review-row').filter({ hasText: title });
async function openReviews(page: Page) {
	await page.goto('/overview');
	await page.getByTestId('cc-section-reviews').click();
	await expect(page.getByTestId('review-toolbar')).toBeVisible();
}
async function picturesLoaded(scope: Locator, count: number) {
	const imgs = scope.getByTestId('review-variant-image');
	await expect(imgs).toHaveCount(count);
	await expect.poll(() => imgs.evaluateAll((els) => els.filter((e) => (e as HTMLImageElement).complete && (e as HTMLImageElement).naturalWidth > 0).length)).toBe(count);
}
/** Row right under the header; lazy pictures above grow the page, so scroll twice. */
async function rowToTop(page: Page, row: Locator, offset = 70) {
	for (let i = 0; i < 2; i++) {
		await row.evaluate((el) => el.scrollIntoView({ block: 'start' }));
		await page.evaluate((o) => window.scrollBy(0, -o), offset);
		await page.waitForFunction(() => [...document.images].every((img) => img.complete));
	}
}

test.beforeAll(async ({ browser }) => {
	mkdirSync(OUT, { recursive: true });
	desktop = await signedInPage(browser, 'Lino');
	await desktop.setViewportSize({ width: 1280, height: 1000 });
	const projectID = (await post<{ id: string }>('/v1/projects', { name: 'ShowerNow' })).id;
	await desktop.goto(`/project/${projectID}`);
	if (!(await desktop.getByTestId('project-tabs').isVisible())) {
		await desktop.getByTestId('display-menu').click();
		await desktop.getByTestId('mode-management').click();
		await desktop.keyboard.press('Escape');
	}
	await expect(desktop.getByTestId('project-tabs')).toBeVisible();

	// Review 1 (created first, so it lists below): two text-only variants (no pictures at all).
	const providers = await post<{ id: string }>('/v1/tasks', { projectID, title: PROVIDERS });
	await post(`/v1/tasks/${providers.id}/review`, {
		agentName: 'Claude Code',
		summary: 'Zwei Anbieter liefern die Regendaten und sind beide angebunden.\n- Neu: beide Anbieter hinter einer Schnittstelle\n- Geprüft: 200 Abrufe je Anbieter ohne Fehler\n- Offen: Kosten ab 10 000 Abrufen am Tag',
		variants: [
			{ id: 'a', label: 'Anbieter A', description: 'Stündliche Werte, kostenlos bis 10 000 Abrufe am Tag. Genügt für den Start.' },
			{ id: 'b', label: 'Anbieter B', description: 'Minutengenaue Regenwerte für die nächsten zwei Stunden, dafür kostenpflichtig ab dem ersten Abruf.' }
		]
	});

	// Review 2 (newest, listed first): three map variants with pictures, summary as an agent writes it (one sentence, up to four points).
	const maps = await post<{ id: string }>('/v1/tasks', { projectID, title: MAPS });
	const wind = await upload(maps.id, 'windkarte.png', image('windkarte'));
	const radar = await upload(maps.id, 'radarkarte.png', image('radarkarte'));
	const temp = await upload(maps.id, 'temperaturkarte.png', image('temperaturkarte'));
	await post(`/v1/tasks/${maps.id}/review`, {
		agentName: 'Claude Code',
		summary: 'Drei Kartenarten sind als Prototyp fertig, jede mit denselben Beispieldaten.\n- Neu: Wind-, Radar- und Temperaturkarte als Vorschau\n- Geprüft: alle drei erscheinen in unter einer Sekunde\n- Ansehen: die drei Bilder unten\n- Offen: Farbskala für Farbfehlsichtigkeit',
		variants: [
			{ id: 'a', label: 'Windkarte', description: 'Pfeile zeigen Richtung und Stärke des Winds.', attachmentID: wind },
			{ id: 'b', label: 'Radarkarte', description: 'Regen der nächsten Stunde im Fünf-Minuten-Raster.', attachmentID: radar },
			{ id: 'c', label: 'Temperaturkarte', description: 'Farbfläche der gefühlten Temperatur, ohne Niederschlag.', attachmentID: temp }
		]
	});

	// A phone of the same account (Chromium emulation of a Pixel 7: touch, 2.6x pixels).
	const state = await desktop.context().storageState();
	const baseURL = test.info().project.use.baseURL;
	phone = await (await browser.newContext({ ...devices['Pixel 7'], baseURL, storageState: state })).newPage();
});
test.afterAll(async () => {
	await desktop?.context().close();
	await phone?.context().close();
});

test('desktop: list with three picture variants, card detail, text variants', async () => {
	await openReviews(desktop);
	const maps = rowOf(desktop, MAPS);
	await expect(maps.getByTestId('review-variant')).toHaveCount(3);
	await picturesLoaded(maps, 3);
	await rowToTop(desktop, maps, 130);
	await snap(desktop, '01-liste-drei-varianten');

	const text = rowOf(desktop, PROVIDERS);
	await expect(text.getByTestId('review-variant')).toHaveCount(2);
	await expect(text.locator('[data-testid=review-variant] img, [data-testid=review-variant] svg')).toHaveCount(0);
	await expect(text.getByTestId('review-variant-placeholder')).toHaveCount(0);
	await snap(desktop, '02-textvarianten-ohne-bildplatz', text);

	// Tall window so that the whole choice of the card window is in one picture.
	await desktop.setViewportSize({ width: 1280, height: 1250 });
	await maps.getByTestId('card-open').click();
	const detail = desktop.getByTestId('card-dialog').getByTestId('card-decide');
	await expect(detail.getByTestId('review-variant')).toHaveCount(3);
	await picturesLoaded(detail, 3);
	await snap(desktop, '03-karten-detail');
	await desktop.keyboard.press('Escape');
	await desktop.setViewportSize({ width: 1280, height: 1000 });
});

test('phone: list and text variants', async () => {
	await phone.goto('/overview');
	await phone.getByTestId('cc-section-reviews').click();
	await expect(phone.getByTestId('review-toolbar')).toBeVisible();
	const maps = rowOf(phone, MAPS);
	await expect(maps.getByTestId('review-variant')).toHaveCount(3);
	await picturesLoaded(maps, 3);
	await rowToTop(phone, maps, 60);
	await snap(phone, '04-mobil-liste-drei-varianten');
	const text = rowOf(phone, PROVIDERS);
	await text.scrollIntoViewIfNeeded();
	await snap(phone, '05-mobil-textvarianten-ohne-bildplatz', text);
});

test('desktop: after the choice (picture variant), with the undo bar', async () => {
	await openReviews(desktop);
	await rowOf(desktop, MAPS).getByTestId('card-open').click();
	const dialog = desktop.getByTestId('card-dialog');
	await dialog.getByTestId('card-decide').getByRole('button', { name: 'Wählen: Variante B, Radarkarte' }).click();
	const result = dialog.getByTestId('card-review-result');
	await expect(result.getByTestId('review-undo-message')).toHaveText('Variante B gewählt: Radarkarte');
	await expect(result.getByTestId('review-chosen').getByTestId('review-chosen-image')).toBeVisible();
	await expect.poll(() => result.getByTestId('review-chosen-image').evaluate((e) => (e as HTMLImageElement).naturalWidth > 0)).toBe(true);
	await desktop.setViewportSize({ width: 1280, height: 1250 });
	await snap(desktop, '06-nach-wahl-rueckgaengig');
	await desktop.keyboard.press('Escape');
});

test('phone: after the choice (text variant), with the undo bar', async () => {
	await phone.goto('/overview');
	await phone.getByTestId('cc-section-reviews').click();
	await expect(phone.getByTestId('review-toolbar')).toBeVisible();
	const text = rowOf(phone, PROVIDERS);
	await text.getByRole('button', { name: 'Wählen: Variante A, Anbieter A' }).click();
	await expect(phone.getByTestId('review-undo-toast').getByTestId('review-undo-message')).toHaveText('Variante A gewählt: Anbieter A');
	await snap(phone, '07-mobil-nach-wahl-textvariante');
});
