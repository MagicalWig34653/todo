import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Bug DA09D11A, second report (Lino 19.11.): the comment "was not saved", suspected cause: many line breaks and/or "- " dashes.
// Compares the normal card chat form for a short text, plain text, multi-line text and several bullet styles of similar
// length (about 150 characters), plus many line breaks, CRLF, a trailing newline and long texts. Per case: sent through the real
// form, POST status, no error message/console error, field cleared, text shown, and after a reload still shown and stored.
// Needs a fresh backend database. Run on its own, per browser:
//   npx playwright test e2e/comment-compare.spec.ts --project=chromium   (also webkit and firefox; Firefox needs @playwright/test 1.65.0 with its
//   firefox-1572 build, `npx playwright install firefox`)
// The third test types like a person (real key events, Shift+Enter for line breaks, Enter / Ctrl+Enter to send) instead of fill().
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };

const filler = (n: number) => 'Lorem ipsum dolor sit amet consectetur adipiscing elit '.repeat(Math.ceil(n / 54)).slice(0, n).trim();
const CASES: { name: string; text: string }[] = [
	{ name: 'short', text: 'Das passt so.' },
	{ name: 'plain-150', text: filler(150) },
	{ name: 'three-lines-150', text: `Erste Zeile mit etwas Text\nZweite Zeile mit etwas mehr Text\n${filler(70)}` },
	{ name: 'dash-bullets-150', text: 'Regen\n- Deutschland\n- Österreich und die Schweiz (Alpenraum)\n- Skandinavien\n\nBitte prüfen: Kartenwahl für „ShowerNow“ – 100 % sicher?' },
	{ name: 'dash-bullets-5', text: '- eins\n- zwei\n- drei\n- vier\n- fünf\n- sechs\n- sieben\n- acht\n- neun\n- zehn' },
	{ name: 'star-bullets', text: '* Deutschland\n* Österreich und die Schweiz\n* Skandinavien\n* Benelux\n* Frankreich' },
	{ name: 'dot-bullets', text: '• Deutschland\n• Österreich und die Schweiz\n• Skandinavien\n• Benelux\n• Frankreich' },
	{ name: 'numbered', text: '1. Deutschland\n2. Österreich und die Schweiz\n3. Skandinavien\n4. Benelux\n5. Frankreich' },
	{ name: 'nested-dashes', text: '- Europa\n  - Deutschland\n  - Österreich\n    - Tirol\n    - Wien\n- Asien\n  - Japan' },
	{ name: 'many-linebreaks-30', text: Array.from({ length: 30 }, (_, i) => `Z${i + 1}`).join('\n\n') },
	{ name: 'many-linebreaks-60', text: Array.from({ length: 60 }, (_, i) => `- Punkt ${i + 1}`).join('\n') },
	{ name: 'only-linebreaks-between', text: 'Anfang\n\n\n\n\n\n\n\n\n\nEnde' },
	{ name: 'trailing-newlines', text: 'Text mit Zeilenumbruch am Ende\n\n\n' },
	{ name: 'crlf', text: 'Zeile eins\r\nZeile zwei\r\n- Punkt A\r\n- Punkt B' },
	{ name: 'dash-only-lines', text: '-\n-\n-\n--\n---\n- -' },
	{ name: 'markdown-mix', text: '# Titel\n**fett** _kursiv_ `code`\n> Zitat\n- [ ] offen\n- [x] erledigt\n\n```\nblock\n```' },
	{ name: 'emoji-umlaut', text: 'Größe: 3 ½ – „fertig“ ✅\n- Äpfel 🍎\n- Öl\n- Übung' },
	{ name: 'long-2000-bullets', text: Array.from({ length: 80 }, (_, i) => `- Eintrag ${i + 1} mit etwas Text`).join('\n').slice(0, 2000) },
	{ name: 'long-9500', text: Array.from({ length: 400 }, (_, i) => `- Zeile ${i + 1} ${filler(10)}`).join('\n').slice(0, 9500) }
];

let page: Page;

// Runs all cases through the chat of one thread ("task" = the card's own chat, "review" = the chat of its review) and checks
// feedback (POST status, no error message, no console error, field cleared) and what the server really stored after a reload.
async function compare(thread: 'task' | 'review') {
	const consoleErrors: string[] = [];
	page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
	page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${e.message}`));

	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: `Kommentarvergleich ${thread}` } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: `Kommentar-Vergleich ${thread}` } })).json();
	let reviewID = '';
	if (thread === 'review') {
		reviewID = (await (await page.request.post(`/v1/tasks/${task.id}/review`, { ...json, data: { summary: 'Review für den Kommentarvergleich', agentName: 'Claude Code' } })).json()).id;
	}
	const open = async () => {
		await page.goto(`/for-you?card=task:${task.id}`);
		await expect(page.getByTestId('card-dialog')).toBeVisible();
	};
	await open();
	const scope = () => page.getByTestId('card-dialog').locator(`[data-testid="card-conversation"][data-thread="${thread}"]`);
	await expect(scope()).toBeVisible();

	const failures: string[] = [];
	const table: string[] = [];
	for (const c of CASES) {
		const field = scope().getByPlaceholder('Nachricht schreiben');
		const errorsBefore = consoleErrors.length;
		let status = 0, responseText = '';
		const responded = page.waitForResponse((r) => r.url().includes(`/tasks/${task.id}/comments`) && r.request().method() === 'POST', { timeout: 15_000 }).catch(() => null);
		await field.fill(c.text);
		await scope().getByTestId('comment-send').click();
		const res = await responded;
		if (res) { status = res.status(); responseText = (await res.text().catch(() => '')).slice(0, 200); }
		const problems: string[] = [];
		if (!res) problems.push('no POST seen');
		else if (status >= 300) problems.push(`POST ${status} ${responseText}`);
		await expect(page.getByText('Etwas ist schiefgelaufen')).toHaveCount(0).catch(() => problems.push('error message shown'));
		if (consoleErrors.length > errorsBefore) problems.push(`console: ${consoleErrors.slice(errorsBefore).join(' | ')}`);
		if (!res || status >= 300) { table.push(`${c.name}: ${problems.join('; ')}`); failures.push(`${c.name}: ${problems.join('; ')}`); continue; }
		if ((await field.inputValue()) !== '') problems.push('field not cleared');
		table.push(`${c.name} (${c.text.length} chars): ${problems.length ? problems.join('; ') : 'ok'}`);
		if (problems.length) failures.push(`${c.name}: ${problems.join('; ')}`);
	}

	// Persistence: everything the server accepted is stored (trimmed, CRLF folded), in the right thread, and shown again after a reload.
	await open();
	const q = thread === 'review' ? `?reviewID=${reviewID}` : '?thread=task';
	const stored = (await (await page.request.get(`/v1/tasks/${task.id}/comments${q}`)).json()) as { body: string }[];
	const bodies = stored.map((x) => x.body);
	for (const c of CASES) {
		const wanted = c.text.trim();
		if (!bodies.includes(wanted) && !bodies.includes(wanted.replace(/\r\n/g, '\n'))) failures.push(`${c.name}: not stored unchanged in the ${thread} thread (trimmed length ${wanted.length})`);
	}
	// The dialog opens before the comments arrive (production bundle: no dev-server delay), so wait for the list instead of counting at once.
	await expect(scope().getByText('Das passt so.').first()).toBeAttached({ timeout: 10_000 }).catch(() => failures.push('short comment not shown after reload'));
	console.log(`\nComment comparison, ${thread} chat (${CASES.length} cases; ${stored.length} stored):\n${table.join('\n')}`);
	expect(failures, `failures:\n${failures.join('\n')}`).toEqual([]);
}

test('card chat: short, plain, multi-line and bullet texts are all saved and survive a reload', async ({ browser }) => {
	test.setTimeout(240_000);
	page = await signedInPage(browser, 'Kommentar Vergleich');
	await compare('task');
});

test('review chat: the same texts are all saved in the review thread and survive a reload', async () => {
	test.setTimeout(240_000);
	await compare('review');
});

// Real keyboard input: key by key typing with Shift+Enter line breaks, sent with Enter, with Ctrl/Cmd+Enter and with the button.
// fill() sets the value in one go; Firefox users type, so the input events, the growing field (many lines, max height) and the
// Enter handling are exercised here as well. Everything must be stored exactly as typed (trimmed).
const typed = (lines: string[]) => lines.join('\n');
const KEY_CASES: { name: string; text: string; send: 'Enter' | 'ControlOrMeta+Enter' | 'button' }[] = [
	{ name: 'typed-short-enter', text: 'Das passt so.', send: 'Enter' },
	{ name: 'typed-bullets-12-enter', text: typed(Array.from({ length: 12 }, (_, i) => `- Punkt ${i + 1}`)), send: 'Enter' },
	{ name: 'typed-bullets-12-ctrl-enter', text: typed(Array.from({ length: 12 }, (_, i) => `- Punkt ${i + 1} mit etwas Text`)), send: 'ControlOrMeta+Enter' },
	{ name: 'typed-many-breaks-40-button', text: typed(Array.from({ length: 40 }, (_, i) => (i % 3 === 2 ? '' : `Zeile ${i + 1}`))), send: 'button' },
	{ name: 'typed-bullets-60-enter', text: typed(Array.from({ length: 60 }, (_, i) => `- Eintrag ${i + 1}`)), send: 'Enter' },
	{ name: 'typed-nested-umlaut', text: typed(['- Größe', '  - Äpfel 🍎', '  - Öl', '- Übung „fertig“ ✅']), send: 'ControlOrMeta+Enter' }
];

test('card chat: texts typed key by key with line breaks and bullets are saved (Enter, Ctrl/Cmd+Enter, button)', async () => {
	test.setTimeout(240_000);
	const consoleErrors: string[] = [];
	page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
	page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${e.message}`));
	const project = await (await page.request.post('/v1/projects', { ...json, data: { name: 'Kommentarvergleich Tastatur' } })).json();
	const task = await (await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Kommentar-Vergleich Tastatur' } })).json();
	await page.goto(`/for-you?card=task:${task.id}`);
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	const scope = page.getByTestId('card-dialog').locator('[data-testid="card-conversation"][data-thread="task"]');
	await expect(scope).toBeVisible();
	const field = scope.getByPlaceholder('Nachricht schreiben');

	const failures: string[] = [];
	for (const c of KEY_CASES) {
		const errorsBefore = consoleErrors.length;
		const responded = page.waitForResponse((r) => r.url().includes(`/tasks/${task.id}/comments`) && r.request().method() === 'POST', { timeout: 15_000 }).catch(() => null);
		await field.click();
		const lines = c.text.split('\n');
		for (let i = 0; i < lines.length; i++) {
			if (lines[i]) await field.pressSequentially(lines[i], { delay: 1 });
			if (i < lines.length - 1) await field.press('Shift+Enter');
		}
		expect(await field.inputValue(), `${c.name}: field content before sending`).toBe(c.text);
		if (c.send === 'button') await scope.getByTestId('comment-send').click();
		else await field.press(c.send);
		const res = await responded;
		const problems: string[] = [];
		if (!res) problems.push('no POST seen');
		else if (res.status() >= 300) problems.push(`POST ${res.status()} ${(await res.text().catch(() => '')).slice(0, 200)}`);
		await expect(page.getByText('Etwas ist schiefgelaufen')).toHaveCount(0).catch(() => problems.push('error message shown'));
		if (consoleErrors.length > errorsBefore) problems.push(`console: ${consoleErrors.slice(errorsBefore).join(' | ')}`);
		if (res && res.status() < 300 && (await field.inputValue()) !== '') problems.push('field not cleared');
		if (problems.length) failures.push(`${c.name}: ${problems.join('; ')}`);
	}

	await page.goto(`/for-you?card=task:${task.id}`);
	await expect(page.getByTestId('card-dialog')).toBeVisible();
	const stored = ((await (await page.request.get(`/v1/tasks/${task.id}/comments?thread=task`)).json()) as { body: string }[]).map((x) => x.body);
	for (const c of KEY_CASES) if (!stored.includes(c.text.trim())) failures.push(`${c.name}: not stored unchanged (trimmed length ${c.text.trim().length})`);
	console.log(`\nTyped comments (${KEY_CASES.length} cases; ${stored.length} stored): ${failures.length ? failures.join(' | ') : 'all ok'}`);
	expect(failures, `failures:\n${failures.join('\n')}`).toEqual([]);
});
