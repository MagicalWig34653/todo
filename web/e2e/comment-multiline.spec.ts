import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Bug DA09D11A: a multi-line comment with "- " list lines (about 150 characters) could not be written in the card chat
// ("Ein Fehler ist aufgetreten", Firefox on the Mac). Needs a fresh backend database. Run on its own, per browser:
//   npx playwright test e2e/comment-multiline.spec.ts --project=firefox   (also chromium, webkit)
// The test records console errors and the comment request/response so a failure shows the exact cause.
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const TEXT = 'Regen\n- Deutschland\n- Österreich und die Schweiz (Alpenraum)\n- Skandinavien\n\nBitte prüfen: Kartenwahl für „ShowerNow“ – 100 % sicher?';

test('multi-line list text can be written in the card chat', async ({ browser }) => {
	page = await signedInPage(browser, 'Kommentar Tester');
	const consoleErrors: string[] = [];
	const failed: string[] = [];
	page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
	page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${e.message}`));
	const comments: { method: string; status: number; req: string; res: string }[] = [];
	page.on('response', async (r) => {
		if (r.url().includes('/comments') && r.request().method() === 'POST') {
			comments.push({ method: 'POST', status: r.status(), req: r.request().postData() ?? '', res: await r.text().catch(() => '') });
		}
		if (r.status() >= 400) failed.push(`${r.status()} ${r.request().method()} ${r.url()}`);
	});

	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Kommentarprojekt' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'ShowerNow Kartenwahl' } })).json();
	await page.goto(`/for-you?card=task:${task.id}`);
	const dialog = page.getByTestId('card-dialog');
	await expect(dialog).toBeVisible();

	const field = dialog.getByPlaceholder('Nachricht schreiben');
	await field.fill(TEXT);
	await expect(field).toHaveValue(TEXT);
	await dialog.getByTestId('comment-send').click();

	await expect.poll(() => comments.length, { message: `no comment POST seen; console: ${consoleErrors.join(' | ')}; failed: ${failed.join(' | ')}` }).toBeGreaterThan(0);
	const c = comments[0]!;
	expect(c.status, `status ${c.status}, request ${c.req}, response ${c.res}, console ${consoleErrors.join(' | ')}`).toBeLessThan(300);
	await expect(dialog.getByText('Deutschland')).toBeVisible();
	expect(consoleErrors, 'console errors').toEqual([]);
	expect(failed, 'failed requests').toEqual([]);
	// The server stored the text unchanged apart from trimming.
	const stored = await (await page.request.get(`/v1/tasks/${task.id}/comments`)).json();
	expect(stored.map((x: { body: string }) => x.body)).toContain(TEXT);
});
