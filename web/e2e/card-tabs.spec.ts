import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/card-tabs.spec.ts --project=chromium   (also --project=webkit)
// Card 378554C5: the card detail window has tabs (Übersicht, Aktivität, Bericht, Pipeline, Änderungen, Tests). The tab is
// part of the URL (?card=task:<id>&tab=<name>), the tab bar follows the ARIA tabs pattern, Aktivität and Bericht show real
// data of the card, Pipeline/Änderungen/Tests show an honest empty state (no data source yet).
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/karten-tabs');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const DESC_END = 'ENDE-DER-BESCHREIBUNG';
const LONG_DESC = `${'Ausführliche Beschreibung der Aufgabe mit viel Text, damit die Übersicht länger als das Fenster wird. '.repeat(30)}${DESC_END}`;
const TABS = ['Übersicht', 'Aktivität', 'Bericht', 'Pipeline', 'Änderungen', 'Tests'];
const SLUGS = ['overview', 'activity', 'report', 'pipeline', 'changes', 'tests'];

let ids = { full: '', empty: '', questionID: '' };

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const dialog = () => page.getByTestId('card-dialog');
const tab = (name: string) => dialog().getByRole('tab', { name, exact: true });
const tablist = () => dialog().getByRole('tablist', { name: 'Bereiche der Karte' });
const panel = () => dialog().getByRole('tabpanel');
const open = async (id: string, slug?: string) => {
	await page.goto(`/for-you?card=task:${id}${slug ? `&tab=${slug}` : ''}`);
	await expect(dialog()).toBeVisible();
	await expect(tablist()).toBeVisible();
};
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: card scroll area overflows`).toBeLessThanOrEqual(0);
};

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Tabs Tester');
	const project = await post<{ id: string }>('/v1/projects', { name: 'Tabprojekt' });
	const mk = (title: string, description?: string) => post<{ id: string }>('/v1/tasks', { projectID: project.id, title, description });
	const full = await mk('Aufgabe mit Verlauf', LONG_DESC);
	const empty = await mk('Leere Aufgabe');
	await post(`/v1/tasks/${full.id}/claim`, { agentName: 'Claude Code' });
	await post(`/v1/tasks/${full.id}/progress-notes`, { note: 'Erster Schritt erledigt', percent: 30 });
	await post(`/v1/tasks/${full.id}/progress-notes`, { note: 'Zweiter Schritt läuft', percent: 60 });
	const q = await post<{ id: string }>(`/v1/tasks/${full.id}/questions`, { prompt: 'Soll die Spalte rechts stehen?', options: ['Ja, rechts', 'Nein, links'], agentName: 'Claude Code' });
	await post(`/v1/questions/${q.id}/answer`, { answer: 'Ja, rechts' });
	await post(`/v1/tasks/${full.id}/review`, { summary: 'Ergebnis ist fertig.\n- Neu: Tabs\n- Geprüft: 3 Tests', agentName: 'Claude Code' });
	await post(`/v1/tasks/${full.id}/review/decision`, { decision: 'accept', note: 'Sieht gut aus' });
	ids = { full: full.id, empty: empty.id, questionID: q.id };
});
test.afterAll(async () => {
	await page?.context().close();
});

test('tabs are visible, follow the ARIA tabs pattern and the overview keeps the previous content', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await open(ids.full);
	await expect(tablist()).toHaveAttribute('aria-orientation', 'horizontal');
	await expect(dialog().getByRole('tab')).toHaveText(TABS);
	await expect(tab('Übersicht')).toHaveAttribute('aria-selected', 'true');
	await expect(tab('Aktivität')).toHaveAttribute('aria-selected', 'false');
	// Roving tabindex: only the selected tab is in the Tab order.
	await expect(tab('Übersicht')).toHaveAttribute('tabindex', '0');
	await expect(tab('Bericht')).toHaveAttribute('tabindex', '-1');
	// Exactly one panel, labelled by the selected tab, and each tab points at it.
	await expect(dialog().getByRole('tabpanel')).toHaveCount(1);
	const panelID = await panel().getAttribute('id');
	await expect(tab('Übersicht')).toHaveAttribute('aria-controls', panelID!);
	await expect(panel()).toHaveAccessibleName('Übersicht');
	// The title stays above the tabs (visible in every tab); the overview panel holds the previous content: description, subtasks, attachments, notes, chat.
	await expect(dialog().getByTestId('card-title')).toHaveValue('Aufgabe mit Verlauf');
	await expect(panel().getByTestId('card-description')).toContainText(DESC_END);
	await expect(panel().getByTestId('card-attachments')).toBeVisible();
	await expect(panel().getByTestId('detail-notes')).toContainText('Zweiter Schritt läuft');
	// The sidebar stays in every tab.
	await tab('Tests').click();
	await expect(dialog().getByTestId('card-side')).toBeVisible();
});

test('keyboard: arrows, Home and End move and activate tabs; focus stays on the tab bar; Tab enters the panel', async () => {
	await open(ids.full);
	await tab('Übersicht').focus();
	await page.keyboard.press('ArrowRight');
	await expect(tab('Aktivität')).toBeFocused();
	await expect(tab('Aktivität')).toHaveAttribute('aria-selected', 'true');
	await expect(tab('Aktivität')).toHaveAttribute('tabindex', '0');
	await expect(tab('Übersicht')).toHaveAttribute('tabindex', '-1');
	await expect(page).toHaveURL(new RegExp(`card=task:${ids.full}&tab=activity$`));
	await page.keyboard.press('End');
	await expect(tab('Tests')).toBeFocused();
	await expect(panel()).toHaveAccessibleName('Tests');
	await page.keyboard.press('ArrowRight');
	await expect(tab('Übersicht')).toBeFocused();
	await expect(page).toHaveURL(new RegExp(`card=task:${ids.full}$`));
	await page.keyboard.press('ArrowLeft');
	await expect(tab('Tests')).toBeFocused();
	await page.keyboard.press('Home');
	await expect(tab('Übersicht')).toBeFocused();
	await expect(tab('Übersicht')).toHaveAttribute('aria-selected', 'true');
	// A focus ring is visible on the focused tab.
	const ring = await tab('Übersicht').evaluate((el) => { const s = getComputedStyle(el); return `${s.outlineStyle} ${s.outlineWidth} ${s.boxShadow}`; });
	expect(ring).not.toBe('none 0px none');
	// Tab leaves the tab bar (does not cycle through the other tabs).
	await tab('Aktivität').click();
	await tab('Aktivität').focus();
	await page.keyboard.press('Tab');
	await expect(tab('Bericht')).not.toBeFocused();
	expect(await dialog().locator(':focus').evaluate((el) => el.getAttribute('role'))).not.toBe('tab');
	// Escape still closes the window from the tab bar.
	await tab('Aktivität').focus();
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
});

test('deep link: ?tab= opens the right tab, reload keeps it, tab changes do not add history entries, unknown tab falls back', async () => {
	await open(ids.full, 'report');
	await expect(tab('Bericht')).toHaveAttribute('aria-selected', 'true');
	await expect(panel()).toHaveAccessibleName('Bericht');
	await page.reload();
	await expect(tab('Bericht')).toHaveAttribute('aria-selected', 'true');
	await tab('Aktivität').click();
	await expect(page).toHaveURL(/tab=activity$/);
	await tab('Pipeline').click();
	await expect(page).toHaveURL(/tab=pipeline$/);
	await open(ids.full, 'nonsense');
	await expect(tab('Übersicht')).toHaveAttribute('aria-selected', 'true');
	// Opening a card from a list starts on the overview even after a tab was used before.
	await page.goto('/activity');
	await page.getByTestId('feed-task').filter({ hasText: 'Aufgabe mit Verlauf' }).first().click();
	await expect(dialog()).toBeVisible();
	await expect(tab('Übersicht')).toHaveAttribute('aria-selected', 'true');
	await tab('Bericht').click();
	await expect(page).toHaveURL(/card=task:[A-Za-z0-9-]+&tab=report$/);
	await tab('Tests').click();
	// One history entry for the whole card: Back (here: the close button) returns to the list, not to the previous tab.
	await dialog().getByRole('button', { name: 'Schließen' }).click();
	await expect(dialog()).toHaveCount(0);
	await expect(page).toHaveURL(/\/activity$/);
	await page.goForward();
	await expect(dialog()).toBeVisible();
	await expect(tab('Tests')).toHaveAttribute('aria-selected', 'true');
	await page.goBack();
	await expect(dialog()).toHaveCount(0);
});

test('Aktivität shows the real events of the card, newest first, with German labels', async () => {
	await open(ids.full, 'activity');
	const items = panel().getByTestId('activity');
	await expect(items.first()).toBeVisible();
	expect(await items.count()).toBeGreaterThanOrEqual(5);
	const text = (await items.allInnerTexts()).join('\n');
	expect(text).toContain('Fortschritt gemeldet');
	expect(text).toContain('Frage gestellt');
	expect(text).toContain('Frage beantwortet');
	expect(text).toContain('Review angefragt');
	expect(text).toContain('Review angenommen');
	expect(text).not.toMatch(/progress\.posted|question\.asked|review\.requested|task\.claimed/);
	// Empty card: friendly empty state or only its creation event, never raw kinds.
	await open(ids.empty, 'activity');
	await expect(panel()).not.toContainText('progress.posted');
});

test('Bericht shows progress notes, question and answer, review and the completion summary from real data', async () => {
	await open(ids.full, 'report');
	const p = panel();
	await expect(p.getByTestId('report-notes')).toContainText('Erster Schritt erledigt');
	await expect(p.getByTestId('report-notes')).toContainText('Zweiter Schritt läuft');
	const notes = await p.getByTestId('report-notes').innerText();
	expect(notes.indexOf('Erster Schritt')).toBeLessThan(notes.indexOf('Zweiter Schritt')); // chronological
	await expect(p.getByTestId('report-questions')).toContainText('Soll die Spalte rechts stehen?');
	await expect(p.getByTestId('report-questions')).toContainText('Ja, rechts');
	await expect(p.getByTestId('report-review')).toContainText('Review angenommen');
	await expect(p.getByTestId('report-review')).toContainText('Sieht gut aus');
	await expect(p.getByTestId('report-completion')).toContainText('Neu: Tabs');
	await expect(p.getByTestId('report-completion')).toContainText('Geprüft: 3 Tests');
	await expect(p.getByTestId('tab-empty')).toHaveCount(0);
	// A card without any of this: honest empty state.
	await open(ids.empty, 'report');
	await expect(panel().getByTestId('tab-empty')).toContainText('Noch kein Bericht');
	await expect(panel().getByTestId('report-notes')).toHaveCount(0);
});

test('Pipeline, Änderungen and Tests show an honest empty state and no invented content', async () => {
	for (const [name, slug, title] of [
		['Pipeline', 'pipeline', 'Noch keine Pipeline'],
		['Änderungen', 'changes', 'Noch keine Änderungen'],
		['Tests', 'tests', 'Noch keine Testergebnisse']
	] as const) {
		for (const id of [ids.empty, ids.full]) {
			await open(id, slug);
			const empty = panel().getByTestId('tab-empty');
			await expect(empty, `${name} on ${id}`).toBeVisible();
			await expect(empty).toContainText(title);
			await expect(empty).toContainText('Agent');
			await expect(panel().getByRole('heading', { name: title })).toBeVisible();
			// Nothing but the empty state: no list, table or fake rows.
			await expect(panel().locator('table, ol, ul')).toHaveCount(0);
			await expect(panel()).toHaveAccessibleName(name);
		}
	}
});

test('confirmation cards (no task) have no tab bar', async () => {
	await page.goto('/for-you?card=confirmation:00000000-0000-0000-0000-000000000000');
	await expect(dialog()).toBeVisible();
	await expect(dialog().getByRole('tablist')).toHaveCount(0);
});

for (const [label, size] of [['desktop', { width: 1280, height: 800 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: no overlap, no layout jump between tabs, tab bar scrolls on phones, light and dark screenshots`, async () => {
		await page.setViewportSize(size);
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			await open(ids.full);
			await noOverflow(`${label} ${scheme} overview`);
			const list0 = (await tablist().boundingBox())!;
			const box0 = (await dialog().boundingBox())!;
			// The tab bar sits below the title row and above the panel; nothing overlaps.
			const titleBox = (await dialog().getByTestId('card-title-row').boundingBox())!;
			expect(list0.y).toBeGreaterThanOrEqual(titleBox.y + titleBox.height - 1);
			const panel0 = (await panel().boundingBox())!;
			expect(panel0.y).toBeGreaterThanOrEqual(list0.y + list0.height - 1);
			await page.waitForTimeout(300);
			await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-overview.png` });
			for (const [i, name] of TABS.entries()) {
				await tab(name).click();
				await expect(tab(name)).toHaveAttribute('aria-selected', 'true');
				await expect(page).toHaveURL(i === 0 ? /card=task:[A-Za-z0-9-]+$/ : new RegExp(`tab=${SLUGS[i]}$`));
				const list = (await tablist().boundingBox())!;
				const box = (await dialog().boundingBox())!;
				// Same dialog frame and tab bar position (the bar does not move when the content changes).
				expect(Math.abs(box.height - box0.height), `${name}: dialog height`).toBeLessThanOrEqual(1);
				expect(Math.abs(box.width - box0.width), `${name}: dialog width`).toBeLessThanOrEqual(1);
				expect(Math.abs(list.y - list0.y), `${name}: tab bar y`).toBeLessThanOrEqual(1);
				expect(Math.abs(list.height - list0.height), `${name}: tab bar height`).toBeLessThanOrEqual(1);
				const pb = (await panel().boundingBox())!;
				expect(pb.y).toBeGreaterThanOrEqual(list.y + list.height - 1);
				await noOverflow(`${label} ${scheme} ${name}`);
				// The selected tab is fully visible inside the tab bar (scrolled into view on phones).
				const tb = (await tab(name).boundingBox())!;
				expect(tb.x).toBeGreaterThanOrEqual(list.x - 1);
				expect(tb.x + tb.width).toBeLessThanOrEqual(list.x + list.width + 1);
				if (name === 'Aktivität') await expect(panel().getByTestId('activity').first()).toBeVisible();
				if (['Aktivität', 'Bericht', 'Tests'].includes(name)) await page.waitForTimeout(300); // colour transition of the tab
				if (['Aktivität', 'Bericht', 'Tests'].includes(name)) await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-${SLUGS[i]}.png` });
			}
		}
		await page.emulateMedia({ colorScheme: 'light' });
		if (label === 'mobile') {
			// 390 px: six tabs do not fit, the bar scrolls sideways inside itself; the page does not.
			await open(ids.full, 'tests');
			const scroll = await tablist().evaluate((el) => ({ sw: el.scrollWidth, cw: el.clientWidth, left: el.scrollLeft }));
			expect(scroll.sw).toBeGreaterThan(scroll.cw);
			expect(scroll.left).toBeGreaterThan(0); // the deep-linked tab was scrolled into view
			await noOverflow('mobile tests deep link');
		}
	});
}

test('switching tabs while scrolled down brings the tab bar back to the top of the content instead of leaving an arbitrary offset', async () => {
	await page.setViewportSize({ width: 1280, height: 600 });
	await open(ids.full);
	const scroller = dialog().getByTestId('card-main');
	await scroller.evaluate((el) => { el.scrollTop = el.scrollHeight; });
	expect(await scroller.evaluate((el) => el.scrollTop)).toBeGreaterThan(100);
	await tab('Tests').click();
	await expect(panel().getByTestId('tab-empty')).toBeInViewport();
	await expect(tablist()).toBeInViewport();
	// And back: the overview starts at its own top, not in the middle of the description.
	await tab('Übersicht').click();
	await expect(tablist()).toBeInViewport();
	await expect(panel().getByTestId('card-description')).toBeVisible();
});

test('overview behaviour is unchanged: inline title edit saves, tab state survives it', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await open(ids.empty);
	const title = dialog().getByTestId('card-title');
	await title.fill('Leere Aufgabe umbenannt');
	await title.press('Enter');
	await tab('Bericht').click();
	await tab('Übersicht').click();
	await expect(dialog().getByTestId('card-title')).toHaveValue('Leere Aufgabe umbenannt');
	const saved = (await (await page.request.get(`/v1/tasks/${ids.empty}/context`)).json()) as { task: { title: string } };
	expect(saved.task.title).toBe('Leere Aufgabe umbenannt');
});
