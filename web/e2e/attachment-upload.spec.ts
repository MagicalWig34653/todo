import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Attachment upload in the task card, written for touch/mobile and Safari (board card 8C9D4BB6). Needs a fresh backend
// database (bootstrap happens here). Run on its own, in any project:
//   npx playwright test e2e/attachment-upload.spec.ts --project=mobile-safari
// Emulation only: no real iOS Safari picker, camera or photo library (see docs/STATUS.md).
test.describe.configure({ mode: 'serial' });
let page: Page;
let projectID = '';
const json = { headers: { 'Content-Type': 'application/json' } };
const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
/** A valid PNG signature followed by padding: the server checks magic bytes, size and checksum, not full decoding. */
const png = (bytes: number) => Buffer.concat([PNG_1X1, Buffer.alloc(bytes - PNG_1X1.length)]);

const dialog = () => page.getByTestId('card-dialog');
async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
/** Fresh task per test so the tests do not depend on each other's attachments. */
async function openFreshTask(title: string) {
	const task = await post<{ id: string }>('/v1/tasks', { projectID, title });
	await page.goto(`/for-you?card=task:${task.id}`);
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByTestId('attachment-upload')).toBeVisible();
	return task.id;
}
const attachmentsOf = async (taskID: string) => (await (await page.request.get(`/v1/tasks/${taskID}/attachments`)).json()) as { filename: string; size: number; status?: string }[];
/** Counts upload attempts that reach the network layer. */
function countBegins() {
	const seen: string[] = [];
	page.on('request', (r) => {
		if (r.method() === 'POST' && r.url().endsWith('/v1/attachments/begin')) seen.push(r.url());
	});
	return seen;
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Upload Tester');
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'Uploadprojekt' })).id;
});
test.afterAll(async () => {
	await page?.context().close();
});

test('emulation: the project really applies its device (touch and narrow viewport on mobile projects)', async ({}, testInfo) => {
	const use = testInfo.project.use;
	await page.goto('/');
	await expect(page).toHaveURL(/\/for-you$/);
	const viewport = page.viewportSize();
	if (use.isMobile) {
		expect(viewport?.width).toBeLessThan(500);
		expect(await page.evaluate(() => 'ontouchstart' in window || navigator.maxTouchPoints > 0)).toBe(true);
	} else {
		expect(viewport?.width).toBeGreaterThanOrEqual(500);
	}
});

test('tap (touch) or click on Hochladen without a file opens the picker; the chosen file is uploaded and listed with its size', async ({}, testInfo) => {
	const taskID = await openFreshTask('Tippen');
	const button = dialog().getByTestId('attachment-upload');
	const chooser = page.waitForEvent('filechooser');
	if (testInfo.project.use.hasTouch) await button.tap();
	else await button.click();
	await (await chooser).setFiles({ name: 'tap.png', mimeType: 'image/png', buffer: PNG_1X1 });
	const card = dialog().getByTestId('attachment').first();
	await expect(card).toContainText('tap.png');
	await expect(card).toContainText(`${PNG_1X1.length} B`);
	await expect(button).toBeEnabled();
	expect(await attachmentsOf(taskID)).toHaveLength(1);
});

test('file given straight to the file input (setInputFiles) is uploaded without pressing the button', async () => {
	const taskID = await openFreshTask('Direkt');
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'direct.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await expect(dialog().getByTestId('attachment').first()).toContainText('direct.png');
	expect((await attachmentsOf(taskID)).map((a) => a.filename)).toEqual(['direct.png']);
});

test('picker closed without a file (cancel) uploads nothing and shows no error', async () => {
	const taskID = await openFreshTask('Abbruch Dateiauswahl');
	const begins = countBegins();
	const chooser = page.waitForEvent('filechooser');
	await dialog().getByTestId('attachment-upload').click();
	await (await chooser).setFiles([]);
	// The next user action proves the UI is idle: the button works and nothing was sent so far.
	await expect(dialog().getByTestId('attachment-upload')).toBeEnabled();
	await expect(dialog().getByRole('alert')).toHaveCount(0);
	await expect(dialog().getByTestId('notice')).toHaveCount(0);
	expect(begins).toHaveLength(0);
	expect(await attachmentsOf(taskID)).toHaveLength(0);
});

test('large attachment just under the 10 MB limit uploads completely', async () => {
	test.setTimeout(90_000);
	const taskID = await openFreshTask('Gross');
	const bytes = 10 * 1024 * 1024 - 1024;
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'large.png', mimeType: 'image/png', buffer: png(bytes) });
	await expect(dialog().getByTestId('attachment').first()).toContainText('large.png', { timeout: 60_000 });
	await expect(dialog().getByTestId('attachment').first()).toContainText('10,0 MB');
	const list = await attachmentsOf(taskID);
	expect(list).toHaveLength(1);
	expect(list[0].size).toBe(bytes);
});

test('attachment over 10 MB is refused in the browser before anything is sent', async () => {
	const taskID = await openFreshTask('Zu gross');
	const begins = countBegins();
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'huge.png', mimeType: 'image/png', buffer: png(10 * 1024 * 1024 + 1) });
	await expect(dialog().getByRole('alert')).toContainText('größer als 10 MB');
	expect(begins).toHaveLength(0);
	expect(await attachmentsOf(taskID)).toHaveLength(0);
});

test('unsupported type and empty file are refused with a message', async () => {
	const taskID = await openFreshTask('Falscher Typ');
	const begins = countBegins();
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') });
	await expect(dialog().getByRole('alert')).toContainText('Dateityp');
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'empty.png', mimeType: 'image/png', buffer: Buffer.alloc(0) });
	await expect(dialog().getByRole('alert')).toContainText('leer');
	expect(begins).toHaveLength(0);
	expect(await attachmentsOf(taskID)).toHaveLength(0);
});

test('upload aborted mid-transfer (connection lost) shows an error, leaves no attachment and a retry succeeds', async () => {
	const taskID = await openFreshTask('Netzabbruch');
	// In-page fault injection: WebKit's request interception does not see the Blob PUT, so route.abort would be a no-op there.
	// The wrapper fails the upload PUT like a lost connection (fetch rejects with a TypeError) until it is switched off.
	await page.evaluate(() => {
		const w = window as unknown as { __realFetch?: typeof fetch; __dropUploads: boolean };
		w.__dropUploads = true;
		w.__realFetch = window.fetch.bind(window);
		window.fetch = (input, init) =>
			w.__dropUploads && init?.method === 'PUT' && String(input).includes('/upload')
				? Promise.reject(new TypeError('Load failed'))
				: w.__realFetch!(input, init);
	});
	const dropped = page.waitForRequest((r) => r.method() === 'DELETE' && /\/v1\/attachments\/[0-9A-F-]+$/i.test(r.url()));
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'lost.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await expect(dialog().getByTestId('notice')).toBeVisible();
	await expect(dialog().getByTestId('attachment')).toHaveCount(0);
	await expect(dialog().getByTestId('attachment-upload')).toBeEnabled();
	// The client drops the pending upload again (DELETE); pending uploads are not listed, so the request itself is the evidence.
	await dropped;
	await expect.poll(async () => (await attachmentsOf(taskID)).length).toBe(0);

	await page.evaluate(() => ((window as unknown as { __dropUploads: boolean }).__dropUploads = false));
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'retry.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await expect(dialog().getByTestId('attachment').first()).toContainText('retry.png');
	expect((await attachmentsOf(taskID)).map((a) => a.filename)).toEqual(['retry.png']);
});

test('server refuses the upload (checksum/content mismatch): error shown, nothing listed', async () => {
	const taskID = await openFreshTask('Serverfehler');
	// Not a PNG although declared as one: the server verifies magic bytes on complete.
	await dialog().getByTestId('attachment-file').setInputFiles({ name: 'fake.png', mimeType: 'image/png', buffer: Buffer.from('this is not a png at all') });
	await expect(dialog().getByTestId('notice')).toBeVisible();
	await expect(dialog().getByTestId('attachment')).toHaveCount(0);
	await expect(dialog().getByTestId('attachment-upload')).toBeEnabled();
	await expect.poll(async () => (await attachmentsOf(taskID)).length).toBe(0);
});
