import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Bug DA09D11A, limits: a long comment (many bullet lines) must either be saved or the person must be told why not, and the
// typed text must stay in the field. The server accepts at most 10 000 characters (CommentService.text) and, without a route
// body limit, Vapor's default of 16 kB request body. comment-compare.spec.ts only goes up to 9 500 characters, so these
// boundaries were never exercised. Needs a fresh backend database. Run on its own, per browser:
//   npx playwright test e2e/comment-limits.spec.ts --project=firefox   (also chromium and webkit)
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };

// Lines of "- Eintrag N: ..." joined with line breaks, cut to exactly n characters.
const bullets = (n: number, unit = '- Eintrag') =>
	Array.from({ length: Math.ceil(n / 10) }, (_, i) => `${unit} ${i + 1} text`).join('\n').slice(0, n);
// Multi-byte text: every "ä" is two UTF-8 bytes, every emoji four, so the JSON body is larger than the character count.
const multibyte = (n: number) => Array.from({ length: Math.ceil(n / 8) }, () => '- äöü 🍎\n').join('').slice(0, n).trim();

const CASES: { name: string; text: string; accepted: boolean }[] = [
	{ name: 'bullets-9999', text: bullets(9999), accepted: true },
	{ name: 'bullets-10000', text: bullets(10000), accepted: true },
	{ name: 'bullets-10001', text: bullets(10001), accepted: false },
	{ name: 'bullets-12000', text: bullets(12000), accepted: false },
	{ name: 'bullets-20000', text: bullets(20000), accepted: false },
	{ name: 'multibyte-5000', text: multibyte(5000), accepted: true },
	{ name: 'multibyte-9000', text: multibyte(9000), accepted: true },
	{ name: 'multibyte-10000', text: multibyte(10000), accepted: true }
];

let page: Page;

test('card chat: boundaries of the comment length (characters and request body)', async ({ browser }) => {
	test.setTimeout(240_000);
	page = await signedInPage(browser, 'Kommentar Grenzen');
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Kommentar Grenzen' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Kommentar-Grenzen' } })).json();
	await page.goto(`/for-you?card=task:${task.id}`);
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	const scope = page.getByTestId('card-dialog').locator('[data-testid="card-conversation"][data-thread="task"]');
	await expect(scope).toBeVisible();
	const field = scope.getByPlaceholder('Nachricht schreiben');

	const failures: string[] = [];
	const table: string[] = [];
	for (const c of CASES) {
		const responded = page.waitForResponse((r) => r.url().includes(`/tasks/${task.id}/comments`) && r.request().method() === 'POST', { timeout: 15_000 }).catch(() => null);
		await field.fill(c.text);
		const bytes = Buffer.byteLength(JSON.stringify({ body: c.text }));
		await scope.getByTestId('comment-send').click();
		const res = await responded;
		const status = res?.status() ?? 0;
		const reason = res && status >= 300 ? (await res.text().catch(() => '')).slice(0, 120) : '';
		// What the person sees: the notice (banner or inside the dialog) and whether the typed text is still in the field.
		await page.waitForTimeout(300);
		const notice = (await page.getByRole('alert').allInnerTexts()).join(' | ').slice(0, 160);
		const kept = (await field.inputValue()) === c.text;
		table.push(`${c.name}: ${c.text.length} chars, ${bytes} body bytes -> POST ${status}${reason ? ` ${reason}` : ''}; notice "${notice}"; text kept in field: ${kept}`);
		if (c.accepted && status !== 201) failures.push(`${c.name}: expected 201, got ${status}`);
		if (!c.accepted && status === 201) failures.push(`${c.name}: expected rejection, got 201`);
		if (!c.accepted) {
			if (!/zu lang|höchstens|10\s?000|Zeichen/i.test(notice)) failures.push(`${c.name}: no hint about the length limit shown (notice "${notice}")`);
			if (!kept) failures.push(`${c.name}: the typed text was lost`);
			await field.fill('');
		}
	}
	console.log(`\nComment length boundaries:\n${table.join('\n')}`);
	expect(failures, `failures:\n${failures.join('\n')}`).toEqual([]);
});
