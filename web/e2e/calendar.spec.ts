import { expect, test, type Locator, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';

// Calendar (ADR 0033, stage B). Needs a fresh backend database (bootstrap happens here). Run on its own:
//   npx playwright test e2e/calendar.spec.ts --project=chromium
// Screenshots go to $CALENDAR_SHOTS (default docs/screenshots/kalender).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.CALENDAR_SHOTS ?? '../docs/screenshots/kalender';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const ids = { project: '', free: '', planned: '', readonly: '', conflict: '' };

/** Berlin calendar day (YYYY-MM-DD) of "today". */
const berlinToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin' }).format(new Date());
const berlinHM = (iso: string) => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
const berlinDay = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin' }).format(new Date(iso));
/** Today at hh:00 in Berlin as ISO instant (tries both offsets and keeps the one that round-trips). */
function todayAt(hour: number): string {
	for (const off of ['+02:00', '+01:00']) {
		const iso = new Date(`${berlinToday()}T${String(hour).padStart(2, '0')}:00:00${off}`).toISOString();
		if (berlinHM(iso) === `${String(hour).padStart(2, '0')}:00` && berlinDay(iso) === berlinToday()) return iso;
	}
	throw new Error('no offset');
}

async function api<T>(method: 'post' | 'patch' | 'put' | 'get', path: string, data?: unknown): Promise<T> {
	const r = await page.request[method](path, method === 'get' ? undefined : { ...json, data });
	expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
interface Planned { plannedAt?: string | null; plannedMinutes?: number | null; plannedAllDay?: boolean; task: { version: number } }
const planning = (id: string) => api<Planned>('get', `/v1/planning/tasks/${id}`);
const card = (title: string) => page.getByTestId('calendar-card').filter({ hasText: title });
/** The week grid scrolls itself to 07:00 after loading; on Linux that scroll is animated (about half a second), on macOS it jumps.
 *  A drop target measured while it still moves lands a slot too late (observed: 09:15 instead of 09:00, 1 in 8 Linux runs). */
async function gridSettled() {
	let last = -1;
	await expect
		.poll(async () => {
			const now = await page.evaluate(() => (document.querySelector('[data-testid="calendar-week"]') as HTMLElement | null)?.scrollTop ?? 0);
			const stable = now === last && now > 0;
			last = now;
			return stable;
		}, { intervals: [120], timeout: 10_000 })
		.toBe(true);
}
/** Real mouse drag with intermediate moves (the browser only starts a native drag after a few pixels). */
async function drag(source: Locator, target: Locator, position?: { x: number; y: number }) {
	await gridSettled();
	await source.scrollIntoViewIfNeeded();
	const from = (await source.boundingBox())!;
	await page.mouse.move(from.x + 10, from.y + from.height / 2);
	await page.mouse.down();
	await page.mouse.move(from.x + 20, from.y + from.height / 2 + 10, { steps: 4 });
	if (!position) await target.scrollIntoViewIfNeeded();
	const to = (await target.boundingBox())!;
	const x = to.x + (position?.x ?? to.width / 2);
	const y = to.y + (position?.y ?? to.height / 2);
	await page.mouse.move(x, y, { steps: 8 });
	await page.mouse.move(x, y + 1, { steps: 2 });
	await page.mouse.up();
}
const column = () => page.locator(`[data-testid="calendar-day"][data-day="${berlinToday()}"]`);

test.afterAll(async () => {
	// A live refresh may still be inside the route handler when the last test ends ("route.fetch: Test ended" outside any test).
	await page?.unrouteAll({ behavior: 'ignoreErrors' });
});

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'de-DE', timezoneId: 'Europe/Berlin' })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Kalender Tester');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
	const project = await api<{ id: string }>('post', '/v1/projects', { name: 'Kalenderprojekt' });
	const mk = async (title: string) => (await api<{ id: string }>('post', '/v1/tasks', { projectID: project.id, title })).id;
	ids.project = project.id;
	ids.free = await mk('Ohne Termin Karte');
	ids.planned = await mk('Geplante Karte');
	ids.readonly = await mk('Lesekarte');
	ids.conflict = await mk('Karte nach Frist');
	// Planned card at 11:00 today (60 minutes), read-only candidate at 16:00, conflict card at 14:00 with a due time of 13:00.
	const put = async (id: string, hour: number, minutes: number, due?: string) => {
		const t = await planning(id);
		await api('put', `/v1/planning/tasks/${id}`, { priority: 0, reminders: [], dueAt: due ?? null, plannedAt: null });
		const fresh = await planning(id);
		void t;
		await api('patch', `/v1/tasks/${id}/schedule`, { version: fresh.task.version, plannedAt: todayAt(hour), plannedMinutes: minutes });
	};
	await put(ids.planned, 11, 60);
	await put(ids.readonly, 16, 30);
	await put(ids.conflict, 14, 30, todayAt(13));
	// The account owns everything, so one card is reported as read-only to the UI to prove that it is not draggable.
	await page.route('**/v1/planning/schedule*', async (route) => {
		const res = await route.fetch();
		const body = await res.json();
		for (const e of body.items) if (e.taskID === ids.readonly) e.canEdit = false;
		await route.fulfill({ response: res, json: body });
	});
	await page.goto('/calendar');
	await expect(page.getByTestId('calendar-week')).toBeVisible();
	await expect(card('Geplante Karte')).toBeVisible();
});

test('week view shows planned, due and conflict cards with text', async () => {
	await expect(page.getByTestId('view-heading')).toHaveText('Kalender');
	await expect(page.getByTestId('calendar-day-head')).toHaveCount(7);
	await expect(column().getByTestId('calendar-due')).toContainText('Frist: Karte nach Frist');
	await expect(card('Karte nach Frist').getByTestId('calendar-conflict')).toHaveText('Nach der Frist');
	await expect(card('Lesekarte')).toContainText('nur lesbar');
	await expect(card('Ohne Termin Karte')).toBeVisible(); // sidebar
	await expect(page.getByTestId('calendar-sidebar')).toContainText('Ohne Termin');
	mkdirSync(SHOTS, { recursive: true });
	await page.screenshot({ path: `${SHOTS}/woche-1280.png` });
});

test('only editable cards are draggable', async () => {
	await expect(card('Geplante Karte')).toHaveAttribute('data-draggable', 'true');
	await expect(card('Lesekarte')).toHaveAttribute('data-draggable', 'false');
	let patches = 0;
	page.on('request', (r) => { if (r.method() === 'PATCH' && r.url().includes('/schedule')) patches++; });
	await card('Lesekarte').focus();
	await page.keyboard.press('ArrowDown');
	await page.keyboard.press('ArrowRight');
	expect(patches).toBe(0);
});

test('dragging from the sidebar sets the start, undo removes it again', async () => {
	await page.getByTestId('calendar-week').evaluate((el) => (el.scrollTop = 300));
	await drag(card('Ohne Termin Karte'), column(), { x: 30, y: 9 * 48 + 2 });
	await expect(page.getByTestId('calendar-undo-bar')).toBeVisible();
	await expect.poll(async () => (await planning(ids.free)).plannedAt).toBeTruthy();
	const p = await planning(ids.free);
	expect(berlinHM(p.plannedAt!)).toBe('09:00');
	expect(berlinDay(p.plannedAt!)).toBe(berlinToday());
	await expect(column().getByTestId('calendar-card').filter({ hasText: 'Ohne Termin Karte' })).toBeVisible();
	await page.getByTestId('calendar-undo').click();
	await expect.poll(async () => (await planning(ids.free)).plannedAt ?? null).toBeNull();
	await expect(page.getByTestId('calendar-sidebar').getByTestId('calendar-card').filter({ hasText: 'Ohne Termin Karte' })).toBeVisible();
});

test('dragging onto the all-day row makes the card all-day, dragging back to the sidebar clears it', async () => {
	await drag(card('Geplante Karte'), page.locator(`[data-testid="calendar-allday"][data-day="${berlinToday()}"]`));
	await expect.poll(async () => (await planning(ids.planned)).plannedAllDay).toBe(true);
	await expect(page.locator(`[data-testid="calendar-allday"][data-day="${berlinToday()}"]`).getByTestId('calendar-card')).toContainText('Geplante Karte');
	await drag(card('Geplante Karte'), page.getByTestId('calendar-sidebar'));
	await expect.poll(async () => (await planning(ids.planned)).plannedAt ?? null).toBeNull();
	await expect(page.getByTestId('calendar-sidebar').getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' })).toBeVisible();
});

test('keyboard: arrows move by 15 minutes, Shift changes the duration, Enter opens the dialog', async () => {
	// Put the card back via the dialog first (Enter on a sidebar card).
	await card('Geplante Karte').focus();
	await page.keyboard.press('Enter');
	const dialog = page.getByTestId('calendar-dialog');
	await expect(dialog).toBeVisible();
	await dialog.getByLabel('Start', { exact: true }).fill(`${berlinToday()}T11:00`);
	await dialog.getByLabel('Dauer in Minuten').fill('60');
	await dialog.getByTestId('calendar-dialog-save').click();
	await expect.poll(async () => berlinHM((await planning(ids.planned)).plannedAt ?? '1970-01-01T00:00:00Z')).toBe('11:00');
	const block = column().getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' });
	await expect(block).toBeVisible();
	await block.focus();
	await page.keyboard.press('ArrowDown');
	await expect.poll(async () => berlinHM((await planning(ids.planned)).plannedAt!)).toBe('11:15');
	await expect(page.getByTestId('calendar-live')).toContainText('Geändert');
	// focus must survive the move (the same element keeps or regains focus)
	await expect(column().getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' })).toBeFocused();
	await page.keyboard.press('Shift+ArrowDown');
	await expect.poll(async () => (await planning(ids.planned)).plannedMinutes).toBe(75);
});

test('keyboard: a key pressed while the reload after the previous move is still running uses the new version', async () => {
	// Regression (flaky "keyboard" test): the version table was emptied before the reload finished, so a quick second key
	// sent the stale version and got a 409. The schedule reload is held back for 2 s to make the window deterministic.
	const block = () => column().getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' });
	await expect(block()).toBeVisible();
	const before = berlinHM((await planning(ids.planned)).plannedAt!);
	let hold = true;
	await page.route('**/planning/schedule*', async (route) => {
		if (hold) await new Promise((r) => setTimeout(r, 2000));
		await route.continue();
	});
	try {
		await block().focus();
		await page.keyboard.press('ArrowDown');
		await expect.poll(async () => berlinHM((await planning(ids.planned)).plannedAt!)).not.toBe(before);
		const first = berlinHM((await planning(ids.planned)).plannedAt!);
		await page.keyboard.press('ArrowDown');
		await expect.poll(async () => berlinHM((await planning(ids.planned)).plannedAt!), { timeout: 8000 }).not.toBe(first);
		await expect(page.getByTestId('calendar-error')).toHaveCount(0);
	} finally {
		hold = false;
		await page.unroute('**/planning/schedule*');
	}
});

test('version conflict (409) shows a German message and reloads', async () => {
	const block = column().getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' });
	await expect(block).toBeVisible();
	// Someone else changes the card; the page still holds the old version.
	const fresh = await planning(ids.planned);
	await api('patch', `/v1/tasks/${ids.planned}`, { version: fresh.task.version, title: 'Geplante Karte' });
	await drag(block, page.locator(`[data-testid="calendar-allday"][data-day="${berlinToday()}"]`));
	await expect(page.getByTestId('calendar-error')).toContainText('zwischenzeitlich geändert');
	await expect(page.getByTestId('calendar-undo-bar')).toHaveCount(0);
	const p = await planning(ids.planned);
	expect(p.plannedAllDay ?? false).toBe(false);
	await expect(column().getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' })).toBeVisible();
});

test('month view lists the cards of the day', async () => {
	await page.getByTestId('calendar-view-month').click();
	await expect(page.getByTestId('calendar-month')).toBeVisible();
	const cell = page.locator(`[data-testid="calendar-month-cell"][data-day="${berlinToday()}"]`);
	await expect(cell.getByTestId('calendar-card').filter({ hasText: 'Geplante Karte' })).toBeVisible();
	await page.screenshot({ path: `${SHOTS}/monat-1280.png` });
	await page.getByTestId('calendar-view-week').click();
});

test('mobile layout stays usable', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await expect(page.getByTestId('calendar-sidebar')).toBeVisible();
	await page.screenshot({ path: `${SHOTS}/woche-390.png`, fullPage: true });
});
