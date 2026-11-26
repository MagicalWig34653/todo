import { expect, request, test, type APIRequestContext, type Locator, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signedInPage } from './support/session';
import { NOW_SEED, defaultRewrite, rewriteOverview, seedNow, type NowIds, type Rewrite } from './support/nowSeed';

// Redesign of the page "Jetzt" (card B0CF5F73, "Leitstand"). Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/now-redesign.spec.ts --project=chromium   (also --project=firefox / webkit)
// Pictures of the same data, before and after: NOW_REDESIGN_SHOTS=docs/screenshots/now-redesign NOW_REDESIGN_PREFIX=vorher|nachher
// (path relative to the repository root); without NOW_REDESIGN_SHOTS nothing is written.
const SHOTS = process.env.NOW_REDESIGN_SHOTS ? resolve(dirname(fileURLToPath(import.meta.url)), '../..', process.env.NOW_REDESIGN_SHOTS) : null;
const PREFIX = process.env.NOW_REDESIGN_PREFIX ?? 'nachher';
const LIVE = { timeout: 20_000 };
const RUNNING = NOW_SEED.runningTasks + NOW_SEED.sessions;
const DESKTOP = { width: 1280, height: 900 };

test.describe.configure({ mode: 'serial' });
// The overview answer is rewritten with `page.route`; WebKit does not route requests of a page under a service worker.
test.use({ serviceWorkers: 'block' });
let page: Page;
let helper: APIRequestContext;
let ids: NowIds;
let rewrite: Rewrite;
const problems: string[] = [];

const block = () => page.getByTestId('now-block');
const tiles = () => page.getByTestId('now-tiles');
const tile = (id: string) => tiles().locator(`[data-tile="${id}"]`);
const row = (projectID: string) => page.locator(`[data-testid="now-project"][data-project="${projectID}"]`);
const boxOf = async (l: Locator) => (await l.boundingBox())!;

/** Fresh page load with the given rewrite of the answer; the stored open/closed choice is cleared unless kept. */
async function open(over: Partial<Rewrite> = {}, keepChoice = false) {
	Object.assign(rewrite, defaultRewrite(), over);
	if (!keepChoice) await page.evaluate(() => localStorage.removeItem('todo.nowExpanded'));
	await page.goto('/now');
	await expect(page.getByTestId('now-view')).toBeVisible(LIVE);
	await expect(page.getByTestId('now-asof')).toBeVisible(LIVE);
}
async function openProject(id: string) {
	const details = row(id);
	if (!(await details.evaluate((e) => (e as HTMLDetailsElement).open))) await details.locator('summary').click();
	await expect(details).toHaveJSProperty('open', true);
}

test.beforeAll(async ({ browser }) => {
	test.setTimeout(180_000);
	page = await signedInPage(browser, 'Leitstand Tester');
	await page.setViewportSize(DESKTOP);
	helper = await request.newContext({ baseURL: test.info().project.use.baseURL, ignoreHTTPSErrors: test.info().project.use.ignoreHTTPSErrors });
	ids = await seedNow(page, helper);
	rewrite = await rewriteOverview(page, ids);
	page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
});
test.afterAll(async () => {
	await helper?.dispose();
});

test('pictures of the seeded page: light and dark, desktop, phone and 320 px', async () => {
	test.skip(!SHOTS, 'only with NOW_REDESIGN_SHOTS');
	mkdirSync(SHOTS!, { recursive: true });
	for (const [width, name] of [[1280, 'desktop'], [390, 'mobil'], [320, '320']] as const) {
		if (width === 320 && PREFIX === 'vorher') continue;
		await page.setViewportSize({ width, height: 900 });
		for (const [scheme, suffix] of [['light', 'hell'], ['dark', 'dunkel']] as const) {
			await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
			await open();
			await expect(block().getByTestId('now-running-item')).toHaveCount(RUNNING, LIVE);
			await expect(page.getByTestId('now-project').first()).toBeVisible();
			await page.waitForTimeout(500);
			await page.screenshot({ path: `${SHOTS}/${PREFIX}-${name}-${suffix}.png`, fullPage: true });
			if (PREFIX === 'vorher' || width === 320) continue;
			// Everything the redesign folds away, unfolded: all waiting entries, no life sign, one project.
			await block().getByTestId('now-waiting-toggle').click();
			await block().getByTestId('now-silent').locator('summary').click();
			await openProject(ids.projects.todolino);
			await page.evaluate(() => {
				(document.activeElement as HTMLElement | null)?.blur();
				window.scrollTo(0, 0);
			});
			await page.waitForTimeout(500);
			await page.screenshot({ path: `${SHOTS}/${PREFIX}-offen-${name}-${suffix}.png`, fullPage: true });
		}
	}
	await page.emulateMedia({ colorScheme: null, reducedMotion: null });
	await page.setViewportSize(DESKTOP);
});

test('four tiles show the counted numbers: four in a row on wide screens, two by two on the phone', async () => {
	await open();
	await expect(tiles().getByTestId('now-tile')).toHaveCount(4);
	const expected = [
		['waiting', 'Wartet auf dich', NOW_SEED.waiting], ['running', 'Läuft gerade', RUNNING], ['done', 'Zuletzt fertig', NOW_SEED.done], ['silent', 'Ohne Lebenszeichen', 1]
	] as const;
	for (const [id, label, count] of expected) {
		await expect(tile(id)).toContainText(label);
		await expect(tile(id).getByTestId('now-tile-count')).toHaveText(String(count));
		await expect(tiles().getByRole('button', { name: `${label}: ${count}` })).toBeVisible();
	}
	const tops = async () => Promise.all(expected.map(async ([id]) => Math.round((await boxOf(tile(id))).y)));
	expect(new Set(await tops()).size, 'one row at 1280 px').toBe(1);
	await page.setViewportSize({ width: 390, height: 844 });
	const phone = await tops();
	expect(new Set(phone).size, 'two rows at 390 px').toBe(2);
	expect(phone[0]).toBe(phone[1]);
	expect(phone[2]).toBe(phone[3]);
	await page.setViewportSize(DESKTOP);
	// The list under "Zuletzt fertig" shows five of the six counted cards and says so.
	await expect(block().getByTestId('now-done-item')).toHaveCount(5);
	await expect(block().getByTestId('now-done')).toContainText('in den letzten 6 Stunden · 5 von 6 gezeigt');
});

test('a tile leads to its section by mouse and keyboard; "Ohne Lebenszeichen" opens', async () => {
	await page.setViewportSize({ width: 390, height: 700 });
	await open();
	for (const [id, section] of [['done', 'now-done'], ['waiting', 'now-waiting'], ['running', 'now-running']] as const) {
		await tile(id).click();
		const heading = block().getByTestId(section).getByRole('heading', { level: 3 });
		await expect(heading).toBeFocused();
		await expect(heading).toBeInViewport();
	}
	const silent = block().getByTestId('now-silent');
	await expect(silent).toHaveJSProperty('open', false);
	await tile('silent').getByRole('button').focus();
	await page.keyboard.press('Enter');
	await expect(silent).toHaveJSProperty('open', true);
	await expect(silent.locator('summary')).toBeFocused();
	await expect(silent.getByTestId('now-silent-item')).toBeInViewport();
	await page.setViewportSize(DESKTOP);
});

test('tiles with zero are calm and not clickable, nothing pulses', async () => {
	await open({ emptyBlock: true, silent: false });
	await expect(tiles().getByTestId('now-tile')).toHaveCount(4);
	await expect(tiles().getByRole('button')).toHaveCount(0);
	for (const id of ['waiting', 'running', 'done', 'silent']) await expect(tile(id).getByTestId('now-tile-count')).toHaveText('0');
	await expect(page.getByTestId('now-tile-pulse')).toHaveCount(0);
	await expect(block().getByTestId('now-running-empty')).toHaveText('Gerade läuft nichts mit Lebenszeichen.');
});

test('the running dot pulses only when motion is allowed', async () => {
	await open();
	const animation = () => page.getByTestId('now-tile-pulse').evaluate((e) => getComputedStyle(e).animationName);
	await page.emulateMedia({ reducedMotion: 'no-preference' });
	expect(await animation()).not.toBe('none');
	await page.emulateMedia({ reducedMotion: 'reduce' });
	expect(await animation()).toBe('none');
	await page.emulateMedia({ reducedMotion: null });
});

test('running work is a grid of cards with project mark, percent, due chip and session mark', async () => {
	await open();
	const cards = block().getByTestId('now-running').getByTestId('now-running-item');
	await expect(cards).toHaveCount(RUNNING);
	const [a, b] = [await boxOf(cards.nth(0)), await boxOf(cards.nth(1))];
	expect(Math.round(a.y)).toBe(Math.round(b.y));
	expect(b.x).toBeGreaterThan(a.x);

	const passkey = cards.filter({ hasText: 'Passkey-Anmeldung absichern' });
	await expect(passkey.getByTestId('now-project-mark')).toHaveText('#');
	await expect(passkey.getByTestId('now-project-mark')).toHaveCSS('color', 'rgb(36, 112, 224)');
	await expect(passkey).toContainText('Todolino');
	await expect(passkey).toContainText('Claude Opus');
	await expect(passkey).toContainText('60 %');
	await expect(passkey.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '60');
	await expect(passkey).toContainText(/Lebenszeichen/);
	await expect(passkey.getByTestId('now-running-item-due')).toHaveAttribute('data-overdue', 'false');
	await expect(passkey.getByTestId('now-running-item-due')).toContainText('Frist');
	const text = passkey.getByTestId('now-card-text');
	const lines = await text.evaluate((e) => e.getBoundingClientRect().height / parseFloat(getComputedStyle(e).lineHeight));
	expect(lines).toBeLessThanOrEqual(3.1);

	const late = cards.filter({ hasText: 'Konflikte in der Wochenansicht' }).getByTestId('now-running-item-due');
	await expect(late).toHaveAttribute('data-overdue', 'true');
	await expect(late).toContainText('Überfällig seit 2 Tg.');
	await expect(late.locator('svg')).toHaveCount(1); // not only colour

	const session = cards.filter({ hasText: 'web-redesign' });
	await expect(session).toHaveAttribute('data-kind', 'session');
	await expect(session).toContainText('Sitzung');
	await expect(session.getByTestId('now-project-mark')).toHaveCount(1);

	await passkey.getByRole('button', { name: 'Passkey-Anmeldung absichern' }).click();
	await expect(page.getByRole('dialog', { name: 'Passkey-Anmeldung absichern' })).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);

	await page.setViewportSize({ width: 390, height: 844 });
	const [c, d] = [await boxOf(cards.nth(0)), await boxOf(cards.nth(1))];
	expect(Math.round(c.x)).toBe(Math.round(d.x));
	expect(d.y).toBeGreaterThan(c.y);
	await page.setViewportSize(DESKTOP);
});

test('waiting: five first, all on demand, plain previews of at most two lines', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await open();
	const waiting = block().getByTestId('now-waiting');
	const items = waiting.getByTestId('now-waiting-item');
	await expect(items).toHaveCount(5);
	const toggle = waiting.getByTestId('now-waiting-toggle');
	await expect(toggle).toHaveText(`Alle ${NOW_SEED.waiting} anzeigen`);
	await expect(toggle).toHaveAttribute('aria-expanded', 'false');
	await toggle.focus();
	await page.keyboard.press('Enter');
	await expect(items).toHaveCount(NOW_SEED.waiting);
	await expect(toggle).toHaveText('Weniger anzeigen');
	await expect(toggle).toHaveAttribute('aria-expanded', 'true');
	await expect(waiting.getByTestId('now-waiting-more')).toHaveCount(0);

	const previews = waiting.getByTestId('now-waiting-text');
	for (const text of await previews.allTextContents()) expect(text).not.toMatch(/\*\*|`|##|\]\(/);
	for (let i = 0; i < NOW_SEED.waiting; i++) {
		const lines = await previews.nth(i).evaluate((e) => e.getBoundingClientRect().height / parseFloat(getComputedStyle(e).lineHeight));
		expect(lines, `entry ${i}`).toBeLessThanOrEqual(2.1);
		await expect(items.nth(i).locator('svg').first()).toBeVisible();
	}
	const question = items.filter({ hasText: 'Wie soll die Anmeldung weiterlaufen?' });
	await expect(question).toHaveAttribute('data-kind', 'question');
	await expect(question).toContainText('Frage');
	await expect(question).toContainText('Variante A: Passkey zuerst, E-Mail nur als Rückfall');
	await expect(question).toContainText('Todolino');
	await expect(question).toContainText('Anmeldung und Rückfall festlegen');
	const review = items.filter({ hasText: NOW_SEED.longTitle });
	await expect(review).toHaveAttribute('data-kind', 'review');
	await expect(review).toContainText('Review');

	await question.getByRole('button', { name: 'Antworten' }).click();
	await expect(page.getByRole('dialog')).toContainText('Wie soll die Anmeldung weiterlaufen?');
	await page.keyboard.press('Escape');
	await expect(page.getByRole('dialog')).toHaveCount(0);
	await toggle.click();
	await expect(items).toHaveCount(5);
	await page.setViewportSize(DESKTOP);
});

test('says so when more entries are counted than delivered', async () => {
	await open({ extraWaiting: 3 });
	await expect(tile('waiting').getByTestId('now-tile-count')).toHaveText(String(NOW_SEED.waiting + 3));
	const waiting = block().getByTestId('now-waiting');
	await expect(waiting.getByTestId('now-waiting-toggle')).toHaveText(`Alle ${NOW_SEED.waiting} geladenen anzeigen`);
	await expect(waiting.getByTestId('now-waiting-more')).toHaveText(`3 weitere sind mitgezählt, werden hier aber nicht aufgeführt.`);
});

test('project rows are compact, closed by default, and the stored choice holds', async () => {
	await open();
	const rows = page.getByTestId('now-project');
	await expect(row(ids.projects.todolino)).toBeVisible();
	for (const details of await rows.all()) await expect(details).toHaveJSProperty('open', false);
	const todolino = row(ids.projects.todolino);
	await expect(todolino.locator('summary').getByTestId('now-project-mark')).toHaveCSS('color', 'rgb(36, 112, 224)');
	await expect(todolino.locator('summary').getByTestId('now-stat-builds')).toHaveText('2 Builds');
	await expect(page.getByTestId('now-quiet').locator('[data-testid="now-project"]').first()).toBeVisible();
	await todolino.locator('summary').focus();
	await page.keyboard.press('Enter');
	await expect(todolino).toHaveJSProperty('open', true);
	await open({}, true);
	await expect(row(ids.projects.todolino)).toHaveJSProperty('open', true);
	await expect(row(ids.projects.form)).toHaveJSProperty('open', false);
	expect(JSON.parse((await page.evaluate(() => localStorage.getItem('todo.nowExpanded'))) ?? '{}')).toEqual({ [ids.projects.todolino]: true });
});

test('inside a project: builds per build, five events first, waiting entries as on top', async () => {
	await open();
	await openProject(ids.projects.todolino);
	const todolino = row(ids.projects.todolino);
	const builds = todolino.getByTestId('now-build');
	await expect(builds).toHaveCount(2);
	await expect(builds.nth(0)).toContainText('iOS 42');
	await expect(builds.nth(0)).toContainText('2 Dateien');
	await expect(builds.nth(0).getByTestId('build-status')).toHaveText('Fehlgeschlagen');
	await expect(builds.nth(1)).toContainText('Web 564a6b4');
	await expect(builds.nth(1)).toContainText('3 Dateien');
	await expect(builds.nth(1).getByTestId('build-status')).toHaveText('Erfolgreich');
	await expect(builds.nth(1).getByTestId('now-build-commit')).toHaveText('564a6b4');
	// The server delivers at most five files per project; the page says so instead of claiming a total.
	await expect(todolino.getByTestId('now-builds')).toContainText('neuesten 5 Dateien');

	await expect(todolino.getByTestId('now-running-item')).toContainText(/60 % · .+ · „Rückfall geschrieben/);
	const events = todolino.getByTestId('now-event');
	await expect(events).toHaveCount(5);
	const more = todolino.getByTestId('now-events-toggle');
	await expect(more).toHaveText('Mehr anzeigen');
	await expect(more).toHaveAttribute('aria-expanded', 'false');
	await more.click();
	await expect(events).toHaveCount(10);
	await expect(more).toHaveText('Weniger anzeigen');
	await expect(more).toHaveAttribute('aria-expanded', 'true');

	const waiting = todolino.getByTestId('now-waiting-item');
	await expect(waiting).toHaveCount(2);
	for (const text of await todolino.getByTestId('now-waiting-text').allTextContents()) expect(text).not.toMatch(/\*\*|`/);
});

test('headings are in order', async () => {
	await open();
	await openProject(ids.projects.todolino);
	const levels = await page.getByTestId('now-view').locator('h1, h2, h3, h4, h5, h6').evaluateAll((all) => all.map((h) => Number(h.tagName[1])));
	expect(levels[0]).toBe(2);
	levels.forEach((level, i) => expect(level, `heading ${i} of ${levels.join(',')}`).toBeLessThanOrEqual((levels[i - 1] ?? 1) + 1));
});

test('old server without `now`: no tiles, the project sections are the view and active ones are open', async () => {
	await open({ oldServer: true });
	await expect(page.getByTestId('now-active').getByTestId('now-project').first()).toBeVisible();
	await expect(tiles()).toHaveCount(0);
	await expect(block()).toHaveCount(0);
	await expect(row(ids.projects.todolino)).toHaveJSProperty('open', true);
	await expect(row(ids.projects.ideas)).toHaveJSProperty('open', false);
	await expect(row(ids.projects.todolino).getByTestId('now-build')).toHaveCount(2);
});

for (const width of [320, 375]) {
	test(`${width} px with everything unfolded: no horizontal scrolling, targets are easy to hit, the plus button covers nothing`, async () => {
		await page.setViewportSize({ width, height: 720 });
		await open();
		await block().getByTestId('now-waiting-toggle').click();
		await block().getByTestId('now-silent').locator('summary').click();
		for (const details of await page.getByTestId('now-project').all()) {
			await details.locator('summary').first().click();
			await expect(details).toHaveJSProperty('open', true);
		}
		const size = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
		expect(size.doc).toBeLessThanOrEqual(size.inner);
		const outside = await page.getByTestId('now-view').locator('*:visible').evaluateAll((all) =>
			all.filter((e) => !e.closest('.sr-only') && e.getBoundingClientRect().right > window.innerWidth + 1).map((e) => `${e.tagName}.${e.getAttribute('class')}`).slice(0, 5));
		expect(outside).toEqual([]);
		const small = await page.getByTestId('now-view').locator('button:visible:not([data-testid="id-chip"]), summary:visible').evaluateAll((all) =>
			all.map((e) => ({ name: e.textContent!.trim().slice(0, 40), height: Math.round(e.getBoundingClientRect().height) })).filter((x) => x.height < 40));
		expect(small).toEqual([]);
		await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
		const last = await boxOf(page.getByTestId('now-project').last());
		// The last block ends above the bottom tab bar; the plus button sits in the header and covers nothing (UX step 1).
		const bar = await boxOf(page.getByRole('navigation', { name: 'Hauptnavigation' }));
		expect(last.y + last.height).toBeLessThanOrEqual(bar.y);
		const fab = await boxOf(page.getByTestId('fab'));
		const header = await boxOf(page.getByTestId('app-header'));
		expect(fab.y + fab.height).toBeLessThanOrEqual(header.y + header.height + 1);
		await page.setViewportSize(DESKTOP);
	});
}

test('no page error during all of this', async () => {
	expect(problems).toEqual([]);
});
