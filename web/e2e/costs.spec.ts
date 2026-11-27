import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { signedInPage } from './support/session';

// Page "Kosteneffizienz" (contracts/usage.yaml, card 71FD73CF). Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/costs.spec.ts --project=chromium
// Screenshots (design/kosteneffizienz/) only with E2E_SCREENSHOTS=1. Everything runs against the real API, nothing is stubbed.
test.describe.configure({ mode: 'serial' });

const SHOTS = process.env.E2E_SCREENSHOTS === '1';
const SHOT_DIR = '../design/kosteneffizienz';
const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const json = { headers: { 'Content-Type': 'application/json' } };
const CODEX = 'gpt-6.1-codex';

let page: Page;
let rows: Row[] = [];
const projects = { todolino: '', form: '' };

interface Row {
	day: string; sessionKey: string; model: string; provider: 'claude' | 'codex';
	inputTokens: number; outputTokens: number; cacheWriteTokens: number; cacheWrite1hTokens?: number; cacheReadTokens: number;
	turns?: number; maxContextTokens?: number; subagent?: boolean; projectID?: string; commits?: number; cardUpdates?: number;
}

async function send<T>(method: 'post' | 'put' | 'patch' | 'get', path: string, data?: unknown): Promise<T> {
	const r = await page.request[method](path, method === 'get' ? undefined : { ...json, data });
	expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json().catch(() => ({}))) as T;
}

/** The browser's calendar date `back` days ago (the page sends this date as `until`). */
const dayBack = (back: number) =>
	page.evaluate((n) => {
		const d = new Date();
		d.setDate(d.getDate() - n);
		return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
	}, back);

/** Three weeks of agent work: an expensive Opus main session, workers, a watchdog without result and an unpriced Codex model. */
async function seedRows(): Promise<Row[]> {
	const out: Row[] = [];
	for (let back = 0; back < 21; back++) {
		const day = await dayBack(back);
		// Deterministic variation; the older two weeks were a bit cheaper so the trend is visible.
		const f = (1 + (((back * 7) % 11) - 5) / 18) * (back < 7 ? 1 : 0.85);
		const n = (v: number) => Math.round(v * f);
		const row = (sessionKey: string, model: string, tokens: [number, number, number, number], extra: Partial<Row> = {}): Row => ({
			day, sessionKey, model, provider: model === CODEX ? 'codex' : 'claude',
			inputTokens: n(tokens[0]), cacheWriteTokens: n(tokens[1]), cacheReadTokens: n(tokens[2]), outputTokens: n(tokens[3]), ...extra
		});
		out.push(
			row('thread-orchestrator', 'claude-opus-5-5', [42_000, 1_850_000, 22_400_000, 138_000], { cacheWrite1hTokens: n(320_000), turns: 212, maxContextTokens: 176_400, projectID: projects.todolino, commits: 4, cardUpdates: 9 }),
			row('thread-web-costs', 'claude-sonnet-5-5', [31_000, 940_000, 11_800_000, 86_000], { turns: 164, maxContextTokens: 98_200, projectID: projects.todolino, commits: 6, cardUpdates: 3 }),
			row('thread-web-costs/agent-tests', 'claude-haiku-5-5', [220_000, 410_000, 3_100_000, 42_000], { turns: 88, maxContextTokens: 41_000, subagent: true, projectID: projects.todolino, commits: 1, cardUpdates: 1 }),
			row('thread-watchdog', 'claude-opus-5-5', [9_000, 310_000, 1_700_000, 6_000], { turns: 18, maxContextTokens: 132_500, projectID: projects.form, commits: 0, cardUpdates: 0 })
		);
		if (back % 2 === 0) out.push(row('codex-review', CODEX, [520_000, 0, 3_400_000, 61_000], { turns: 47, maxContextTokens: 121_000, projectID: projects.form, commits: 1, cardUpdates: 2 }));
	}
	return out;
}

const view = () => page.getByTestId('costs-view');
const range = (name: '24 h' | '7 T' | '30 T') => view().getByTestId('costs-range').getByRole('button', { name, exact: true });
const total = async () => ((await view().getByTestId('costs-total').textContent()) ?? '').trim();
const dollars = (text: string) => Number(text.replace(/[^\d,]/g, '').replace(',', '.'));
const money = (v: number) => new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'USD' }).format(v).replace(/\s/g, ' ');

async function openPage() {
	await page.goto('/costs');
	await expect(page.getByTestId('view-heading')).toHaveText('Kosteneffizienz');
	await expect(view().getByTestId('costs-loading')).toHaveCount(0);
}

async function expectNoOverflow(label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: document.documentElement.clientWidth }));
	expect(w.doc, `horizontal overflow: ${label}`).toBeLessThanOrEqual(w.inner);
}

/** Overflow check for both sizes and schemes; writes full page pictures only with E2E_SCREENSHOTS=1. */
async function pictures(name: 'filled' | 'empty') {
	if (SHOTS) mkdirSync(SHOT_DIR, { recursive: true });
	for (const [device, size] of [['desktop', DESKTOP], ['phone', PHONE]] as const) {
		await page.setViewportSize(size);
		for (const [scheme, suffix] of [['light', 'light'], ['dark', 'dark']] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			await openPage();
			await expectNoOverflow(`${name} ${device} ${scheme}`);
			// The phone's fixed tab bar would sit in the middle of a full page picture: it is placed at the end for the picture only.
			const style = 'nav[aria-label="Hauptnavigation"] { position: static !important; }';
			if (SHOTS) await page.screenshot({ path: `${SHOT_DIR}/${name}-${device}-${suffix}.png`, fullPage: true, animations: 'disabled', style });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize(DESKTOP);
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Kosten Tester');
	await page.setViewportSize(DESKTOP);
});
test.afterAll(async () => {
	await page?.context().close();
});

test('empty state: no rows yet, the page explains how to set up the collector', async () => {
	await openPage();
	const setup = view().getByTestId('costs-setup');
	await expect(setup).toContainText('Noch keine Daten, Sammler einrichten');
	await expect(setup).toContainText('report_usage');
	await expect(setup).toContainText('keine Prompt-Inhalte');
	await expect(view().getByTestId('costs-verdict')).toHaveCount(0);
	await expect(view().getByTestId('costs-tile')).toHaveCount(0);
	await pictures('empty');
});

test('main navigation leads to the page on desktop and phone', async () => {
	await page.goto('/for-you');
	await page.getByRole('navigation', { name: 'Seitenleiste' }).getByRole('button', { name: 'Kosteneffizienz', exact: true }).click();
	await expect(page).toHaveURL(/\/costs$/);
	await expect(page).toHaveTitle(/Kosteneffizienz/);
	await page.setViewportSize(PHONE);
	await page.goto('/for-you');
	await page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' }).click();
	await page.locator('#main-nav').getByRole('button', { name: 'Kosteneffizienz', exact: true }).click();
	await expect(page).toHaveURL(/\/costs$/);
	await expect(page.getByTestId('view-heading')).toHaveText('Kosteneffizienz');
	await page.setViewportSize(DESKTOP);
});

test('data outside every range: a quiet state, not the setup hint', async () => {
	await send('post', '/v1/usage', {
		rows: [{ day: await dayBack(75), sessionKey: 'thread-old', model: 'claude-sonnet-5-5', provider: 'claude', inputTokens: 1000, outputTokens: 100, cacheWriteTokens: 0, cacheReadTokens: 0 }]
	});
	await openPage();
	await expect(view().getByTestId('costs-quiet')).toContainText('Keine Nutzung in diesem Zeitraum');
	await expect(view().getByTestId('costs-setup')).toHaveCount(0);
	await expect(view().getByTestId('costs-verdict')).toHaveCount(0);
});

test('filled page: verdict first, eight tiles, charts, sessions with idle marker, projects, unpriced hint', async () => {
	projects.todolino = (await send<{ id: string }>('post', '/v1/projects', { name: 'Todolino' })).id;
	projects.form = (await send<{ id: string }>('post', '/v1/projects', { name: 'Formular-Backend' })).id;
	for (const title of ['Seite Kosteneffizienz', 'Sammler melden lassen', 'Preistabelle prüfen']) {
		const t = await send<{ id: string }>('post', '/v1/tasks', { projectID: projects.todolino, title });
		await send('patch', `/v1/tasks/${t.id}`, { version: 1, status: 'done' });
	}
	rows = await seedRows();
	const stored = await send<{ stored: number; unpricedModels: string[] }>('post', '/v1/usage', { rows });
	expect(stored.stored).toBe(rows.length);
	expect(stored.unpricedModels).toContain(CODEX);

	await openPage();
	const until = await dayBack(0);
	const summary = await send<{ totalCostUSD: number; verdict: { rating: string }; partial: boolean }>('get', `/v1/usage/summary?days=7&until=${until}`);
	await expect(range('7 T')).toHaveAttribute('aria-pressed', 'true');
	await expect.poll(async () => (await total()).replace(/\s/g, ' ')).toBe(money(summary.totalCostUSD));

	// The judgement comes first, in words (readable without colour).
	const verdict = view().getByTestId('costs-verdict');
	await expect(verdict).toHaveAttribute('data-rating', summary.verdict.rating);
	await expect(verdict.getByTestId('costs-verdict-sentence')).toHaveText(/^(Gut|Ordentlich|Handlungsbedarf): .+\.$/);
	await expect(verdict.getByTestId('costs-trend')).toContainText('gegenüber den 7 Tagen davor');
	const verdictBox = (await verdict.boundingBox())!;
	expect(verdictBox.y + verdictBox.height, 'verdict is visible without scrolling').toBeLessThanOrEqual(DESKTOP.height);
	if (summary.partial) await expect(view().getByTestId('costs-partial')).toContainText('läuft noch');

	const tiles = view().getByTestId('costs-tile');
	await expect(tiles).toHaveCount(8);
	for (const tile of await tiles.all()) await expect(tile.getByTestId('costs-rating')).toHaveText(/^(Gut|Mittel|Schlecht|Info|Unbekannt)$/);
	await expect(tiles.and(view().locator('[data-metric="outputShare"]'))).toContainText('jeder Schritt den ganzen Kontext neu liest');

	await expect(view().getByTestId('costs-day-bar')).toHaveCount(7);
	for (const name of ['Input', 'Cache-Write', 'Cache-Read', 'Output']) await expect(view().getByTestId('costs-legend')).toContainText(name);
	await view().getByTestId('costs-day-table').locator('summary').click();
	await expect(view().getByTestId('costs-day-table').locator('tbody tr')).toHaveCount(7);
	await view().getByTestId('costs-day-bar').first().hover();
	await expect(view().getByTestId('costs-day-readout')).toContainText('Cache-Write');

	await expect(view().locator('[data-testid="costs-model"][data-family="opus"]')).toContainText('%');
	for (const family of ['sonnet', 'haiku', 'codex']) await expect(view().locator(`[data-testid="costs-model"][data-family="${family}"]`)).toHaveCount(1);

	const sessions = view().getByTestId('costs-session');
	await expect(sessions).toHaveCount(5);
	await expect(sessions.first()).toContainText('thread-orchestrator');
	await expect(sessions.first()).toContainText('Todolino');
	await expect(sessions.first()).toContainText('claude-opus-5-5');
	const idle = view().locator('[data-testid="costs-session"][data-idle="true"]');
	await expect(idle).toHaveCount(1);
	await expect(idle).toContainText('thread-watchdog');
	await expect(idle).toContainText('teuer und ohne Ergebnis');
	await expect(view().getByText('teuer und ohne Ergebnis')).toHaveCount(1);

	const todolino = view().getByTestId('costs-project').filter({ hasText: 'Todolino' });
	await expect(todolino).toContainText('3 erledigte Karten');
	await expect(todolino).toContainText('je Karte');
	await expect(view().getByTestId('costs-project').filter({ hasText: 'Formular-Backend' })).toContainText('keine erledigte Karte');

	await expect(view().getByTestId('costs-unpriced')).toContainText(CODEX);
	await expect(view().getByTestId('costs-unpriced')).toContainText('0 $');
	await expect(view().getByTestId('costs-settings')).toHaveJSProperty('open', false);
});

test('range switch: 24 h, 7 T and 30 T ask for the browser date and redraw', async () => {
	await openPage();
	const until = await dayBack(0);
	const week = dollars(await total());
	for (const [name, days, bars] of [['24 h', 1, 1], ['30 T', 30, 30]] as const) {
		const request = page.waitForRequest((r) => r.url().includes(`/v1/usage/summary?days=${days}&until=${until}`));
		await range(name).click();
		await request;
		await expect(range(name)).toHaveAttribute('aria-pressed', 'true');
		await expect(view().getByTestId('costs-day-bar')).toHaveCount(bars);
		await expect.poll(async () => dollars(await total()))[days === 1 ? 'toBeLessThan' : 'toBeGreaterThan'](week);
	}
	await page.setViewportSize(PHONE);
	await expect(view().getByTestId('costs-day-bar')).toHaveCount(30);
	await expectNoOverflow('30 days on the phone');
	await page.setViewportSize(DESKTOP);
	await range('7 T').click();
	await expect(view().getByTestId('costs-day-bar')).toHaveCount(7);
});

test('reporting the same rows again replaces them: totals stay the same', async () => {
	await openPage();
	const before = await total();
	const again = await send<{ stored: number; created: number; updated: number }>('post', '/v1/usage', { rows });
	expect(again).toMatchObject({ stored: rows.length, created: 0, updated: rows.length });
	await openPage();
	await expect.poll(total).toBe(before);
});

test('screenshots of the filled page, without horizontal scroll on the phone', async () => {
	await pictures('filled');
});

test('a price for the unpriced model recalculates the costs; removing it restores them', async () => {
	await openPage();
	const before = dollars(await total());
	await view().getByRole('button', { name: `Preis für ${CODEX} ergänzen` }).click();
	await expect(view().getByTestId('costs-settings')).toHaveJSProperty('open', true);
	const row = view().locator(`[data-testid="costs-price-row"][data-model="${CODEX}"]`);
	// Incomplete input is refused with a sentence, nothing is saved.
	await view().getByTestId('costs-save').click();
	await expect(view().getByTestId('costs-settings-error')).toContainText('alle fünf Preise');
	for (const [label, value] of [['Input', '2'], ['Cache-Write 5 min', '0'], ['Cache-Write 1 h', '0'], ['Cache-Read', '0,5'], ['Output', '16']]) {
		await row.getByLabel(label, { exact: true }).fill(value);
	}
	await view().getByTestId('costs-save').click();
	await expect(view().getByTestId('costs-saved')).toContainText('Gespeichert');
	await expect(view().getByTestId('costs-unpriced')).toHaveCount(0);
	await expect.poll(async () => dollars(await total())).toBeGreaterThan(before);
	const saved = await send<{ prices: { model: string; custom?: boolean; cacheRead: number }[] }>('get', '/v1/usage/settings');
	expect(saved.prices.filter((p) => p.custom)).toEqual([expect.objectContaining({ model: CODEX, cacheRead: 0.5 })]);

	// A threshold changes the judgement text.
	await view().getByLabel('Cache-Trefferquote gut ab (%)').fill('99');
	await view().getByTestId('costs-save').click();
	await expect(view().locator('[data-metric="cacheHitRate"]')).not.toHaveAttribute('data-rating', 'good');

	await row.getByRole('button', { name: `Eigenen Preis für ${CODEX} entfernen` }).click();
	await view().getByLabel('Cache-Trefferquote gut ab (%)').fill('');
	await view().getByTestId('costs-save').click();
	await expect(view().getByTestId('costs-unpriced')).toContainText(CODEX);
	await expect.poll(async () => dollars(await total())).toBe(before);
	await expectNoOverflow('settings open on desktop');
	await page.setViewportSize(PHONE);
	await expectNoOverflow('settings open on the phone');
	await page.setViewportSize(DESKTOP);
});
