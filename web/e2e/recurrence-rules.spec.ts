import { expect, test, type Page, type Request } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signedInPage } from './support/session';

// Card 21CF716D: recurrence rules with several weekdays, "from completion" and a day of the month, set in the card detail
// sidebar. Needs a fresh backend database (bootstrap happens here) and, for the persistence and successor tests, a backend
// that knows the new rule fields (`weekdays`, `basis`, `monthDay`). Run on its own:
//   npx playwright test e2e/recurrence-rules.spec.ts --project=chromium   (also firefox and webkit)
// Part 1 (requests the form sends, unchanged legacy rules) also runs against a backend without the new fields.
// Dates are computed from today in the browser's time zone (this process and the browser share it).
// Pictures (light and dark) go to E2E_SHOTS (default: wiederholung in the system temp dir).
const SHOTS = process.env.E2E_SHOTS ?? join(tmpdir(), 'wiederholung');
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
let page: Page;
let projectID = '';

type Rule = { frequency: string; interval: number; timeZone: string; until?: string | null; weekdays?: number[]; basis?: string; monthDay?: number };
type Planning = { dueAt: string | null; recurrence: Rule | null; priority: number };

// --- dates in the browser's local time zone -------------------------------------------------------------------------
const pad = (n: number) => String(n).padStart(2, '0');
const ymd = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const day = (offset = 0) => {
	const t = new Date();
	return new Date(t.getFullYear(), t.getMonth(), t.getDate() + offset);
};
const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const at9 = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), 9, 0).toISOString();
const isoWeekday = (d: Date) => (d.getDay() === 0 ? 7 : d.getDay());
const daysInMonth = (y: number, m: number) => new Date(y, m + 1, 0).getDate();
/** The first date strictly after today that falls on the ISO weekday (1 = Monday). */
function nextWeekday(iso: number): Date {
	for (let i = 1; i <= 7; i++) if (isoWeekday(day(i)) === iso) return day(i);
	throw new Error('unreachable');
}
/** The 31st of the next month that has 31 days and is followed by a shorter one: its successor day is clamped. */
function nextClampedThirtyFirst(): { due: Date; expected: Date } {
	const today = day();
	for (let k = 1; k <= 12; k++) {
		const first = new Date(today.getFullYear(), today.getMonth() + k, 1);
		const next = new Date(first.getFullYear(), first.getMonth() + 1, 1);
		if (daysInMonth(first.getFullYear(), first.getMonth()) === 31 && daysInMonth(next.getFullYear(), next.getMonth()) < 31) {
			return { due: new Date(first.getFullYear(), first.getMonth(), 31), expected: new Date(next.getFullYear(), next.getMonth(), daysInMonth(next.getFullYear(), next.getMonth())) };
		}
	}
	throw new Error('unreachable');
}
const localDate = (iso: string | null) => ymd(new Date(iso ?? ''));

// --- API helpers ----------------------------------------------------------------------------------------------------
async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
async function card(title: string, dueAt: string, recurrence: Rule | null = null): Promise<string> {
	const task = await post<{ id: string }>('/v1/tasks', { projectID, title });
	const r = await page.request.put(`/v1/planning/tasks/${task.id}`, { ...json, data: { dueAt, plannedAt: null, priority: 0, recurrence, reminders: [] } });
	expect(r.status(), await r.text()).toBe(200);
	return task.id;
}
async function planning(id: string): Promise<Planning> {
	const r = await page.request.get(`/v1/planning/tasks/${id}`);
	expect(r.status(), await r.text()).toBe(200);
	return (await r.json()) as Planning;
}
async function tasksTitled(title: string): Promise<{ id: string }[]> {
	const r = await page.request.get(`/v1/tasks?projectID=${projectID}`);
	expect(r.status(), await r.text()).toBe(200);
	return ((await r.json()) as { id: string; title: string }[]).filter((x) => x.title === title);
}

// --- page helpers ---------------------------------------------------------------------------------------------------
const dialog = () => page.getByTestId('card-dialog');
const side = () => dialog().getByTestId('side-recurrence');
const summary = () => dialog().getByTestId('side-recurrence-value');
const frequency = () => dialog().getByLabel('Häufigkeit der Wiederholung');
const weekdays = () => dialog().getByRole('group', { name: 'Wochentage' });
async function openCard(id: string) {
	await page.goto(`/project/${projectID}/list?card=task:${id}`);
	await expect(dialog()).toBeVisible();
	// The sidebar form is disabled until the stored planning has arrived.
	await expect(dialog().getByTestId('side-priority-select')).toBeEnabled();
}
async function openEditor() {
	await dialog().getByTestId('side-recurrence-add').click();
	await expect(dialog().getByTestId('recurrence-form')).toBeVisible();
	await expect(frequency()).toBeEnabled();
}
/** Records the bodies of the planning PUTs the page sends. */
function recordPuts() {
	const bodies: { recurrence: Rule | null }[] = [];
	const on = (r: Request) => {
		if (r.method() === 'PUT' && /\/v1\/planning\/tasks\//.test(r.url())) bodies.push(r.postDataJSON());
	};
	page.on('request', on);
	return { bodies, stop: () => page.off('request', on) };
}
async function markDone() {
	await dialog().getByRole('checkbox', { name: 'Als erledigt markieren', exact: true }).click();
	await expect(dialog().getByTestId('card-status')).toHaveText('Erledigt');
}
async function pictures(name: string) {
	mkdirSync(SHOTS, { recursive: true });
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await page.waitForTimeout(300);
		await page.screenshot({ path: join(SHOTS, `${name}-${scheme === 'light' ? 'hell' : 'dunkel'}.png`) });
	}
	await page.emulateMedia({ colorScheme: null });
}

/**
 * A backend without the new rule fields drops them from the stored rule and returns the plain rule, which the form adopts
 * after each save. Part 1 therefore waits for each save to finish before the next input, and only asserts that all the
 * inputs together end in one stored rule when the backend knows the fields. Part 2 needs those fields.
 */
let backendKnowsFields = true;
async function probeBackend(taskID: string) {
	const rule = { frequency: 'weekly', interval: 1, timeZone: 'Europe/Berlin', until: null, weekdays: [1, 4] };
	const put = (recurrence: Rule | null) => page.request.put(`/v1/planning/tasks/${taskID}`, { ...json, data: { dueAt: at9(day(3)), plannedAt: null, priority: 0, recurrence, reminders: [] } });
	const r = await put(rule);
	backendKnowsFields = r.status() === 200 && ((await r.json()) as Planning).recurrence?.weekdays?.length === 2;
	await put(null);
}
/** Runs the action and waits for the planning save it triggers. */
async function saving(action: () => Promise<unknown>) {
	const [response] = await Promise.all([
		page.waitForResponse((r) => r.request().method() === 'PUT' && /\/v1\/planning\/tasks\//.test(r.url())),
		action()
	]);
	expect(response.status(), await response.text()).toBe(200);
}

const ids = { payload: '', legacy: '', weekly: '', completion: '', monthly: '' };
const monthly = nextClampedThirtyFirst();
const WEEKLY = 'Wöchentlich Montag und Donnerstag';
const COMPLETION = 'Täglich ab Erledigung';
const MONTHLY = 'Monatlich am 31.';

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Wiederholung Tester');
	await page.setViewportSize({ width: 1280, height: 900 });
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'Wiederholungen' })).id;
	ids.payload = await card('Nutzlast', at9(day(3)));
	ids.legacy = await card('Alte Regel', at9(day(3)), { frequency: 'weekly', interval: 2, timeZone: 'Europe/Berlin', until: null });
	ids.weekly = await card(WEEKLY, at9(nextWeekday(1)));
	ids.completion = await card(COMPLETION, at9(day(-5)));
	ids.monthly = await card(MONTHLY, at9(monthly.due));
	await probeBackend(ids.payload);
});
test.afterAll(async () => {
	await page?.context().close();
});

// ===== Part 1: what the form sends (does not need the new backend fields) =====
test.describe('part 1', () => {
	test('weekday toggles are real toggle buttons, usable by keyboard, and every change is sent as one rule', async () => {
		await openCard(ids.payload);
		const puts = recordPuts();
		await openEditor();
		await saving(() => frequency().selectOption('weekly'));
		await expect(weekdays()).toBeVisible();
		await expect(weekdays().getByRole('button')).toHaveCount(7);
		const monday = weekdays().getByRole('button', { name: 'Montag' });
		const thursday = weekdays().getByRole('button', { name: 'Donnerstag' });
		await expect(monday).toHaveAttribute('aria-pressed', 'false');
		// Keyboard: focus, then Space (a button toggles with Space and Enter).
		await monday.focus();
		await saving(() => page.keyboard.press('Space'));
		expect(puts.bodies.at(-1)?.recurrence?.weekdays).toEqual([1]);
		if (backendKnowsFields) {
			await expect(monday).toHaveAttribute('aria-pressed', 'true');
			// The next tap adds to the stored day: one rule with both days, no conflict message.
			await saving(() => thursday.click());
			expect(puts.bodies.at(-1)?.recurrence?.weekdays).toEqual([1, 4]);
			await expect(thursday).toHaveAttribute('aria-pressed', 'true');
			await expect(dialog().getByTestId('planning-conflict')).toHaveCount(0);
		}
		for (const body of puts.bodies) {
			expect(Object.keys(body.recurrence ?? {})).not.toContain('basis');
			expect(Object.keys(body.recurrence ?? {})).not.toContain('monthDay');
		}
		puts.stop();
	});

	test('a day of the month goes out only for monthly, and the basis only when it is the completion', async () => {
		await openCard(ids.payload);
		await openEditor();
		const puts = recordPuts();
		await saving(() => frequency().selectOption('monthly'));
		await expect(weekdays()).toHaveCount(0);
		expect(Object.keys(puts.bodies.at(-1)?.recurrence ?? {})).not.toContain('weekdays');
		const monthDay = dialog().getByLabel('Am n-ten Tag des Monats');
		await expect(monthDay).toBeVisible();
		await expect(dialog().getByText('Monatsende gekürzt')).toBeVisible();
		await monthDay.fill('31');
		await saving(() => monthDay.press('Tab'));
		expect(puts.bodies.at(-1)?.recurrence?.monthDay).toBe(31);
		expect(Object.keys(puts.bodies.at(-1)?.recurrence ?? {})).not.toContain('weekdays');
		await saving(() => dialog().getByLabel('Nächster Termin').selectOption('completion'));
		expect(puts.bodies.at(-1)?.recurrence?.basis).toBe('completion');
		puts.stop();
	});

	test('a rule without the new fields is shown as before and saved without them', async () => {
		await openCard(ids.legacy);
		await expect(summary()).toHaveText('Wöchentlich · Alle … Wochen 2');
		const puts = recordPuts();
		// Any other sidebar change saves the whole planning, including the untouched rule.
		await dialog().getByTestId('side-priority-select').selectOption('2');
		await expect.poll(() => puts.bodies.length).toBeGreaterThan(0);
		expect(puts.bodies.at(-1)?.recurrence).toEqual({ frequency: 'weekly', interval: 2, timeZone: 'Europe/Berlin', until: null });
		puts.stop();
		const stored = await planning(ids.legacy);
		expect(stored.priority).toBe(2);
		expect(stored.recurrence).toMatchObject({ frequency: 'weekly', interval: 2, timeZone: 'Europe/Berlin' });
		for (const key of ['weekdays', 'monthDay']) expect(Object.keys(stored.recurrence ?? {})).not.toContain(key);
	});
});

// ===== Part 2: needs a backend with the new rule fields =====

test('a changed frequency drops the fields that no longer fit and keeps the basis', async () => {
	await openCard(ids.payload);
	await openEditor();
	await frequency().selectOption('weekly');
	await weekdays().getByRole('button', { name: 'Montag' }).click();
	await dialog().getByLabel('Nächster Termin').selectOption('completion');
	await expect.poll(async () => (await planning(ids.payload)).recurrence).toMatchObject({ weekdays: [1], basis: 'completion' });
	const puts = recordPuts();
	await frequency().selectOption('monthly');
	await expect(weekdays()).toHaveCount(0);
	await expect.poll(() => puts.bodies.at(-1)?.recurrence?.frequency).toBe('monthly');
	expect(Object.keys(puts.bodies.at(-1)?.recurrence ?? {})).not.toContain('weekdays');
	await dialog().getByLabel('Am n-ten Tag des Monats').fill('15');
	await dialog().getByLabel('Am n-ten Tag des Monats').press('Tab');
	await expect.poll(async () => (await planning(ids.payload)).recurrence).toMatchObject({ monthDay: 15, basis: 'completion' });
	await frequency().selectOption('daily');
	await expect(dialog().getByLabel('Am n-ten Tag des Monats')).toHaveCount(0);
	await expect.poll(async () => (await planning(ids.payload)).recurrence?.frequency).toBe('daily');
	const stored = (await planning(ids.payload)).recurrence ?? ({} as Rule);
	expect(Object.keys(stored)).not.toContain('monthDay');
	expect(Object.keys(stored)).not.toContain('weekdays');
	expect(stored.basis).toBe('completion');
	// Back to "from due date": the basis is not sent at all, so the stored rule is the plain default again.
	await dialog().getByLabel('Nächster Termin').selectOption('due');
	await expect.poll(async () => Object.keys((await planning(ids.payload)).recurrence ?? {})).not.toContain('basis');
	puts.stop();
});

test('Monday and Thursday are stored, shown after a reload and carried by the summary', async () => {
	await openCard(ids.weekly);
	await openEditor();
	await frequency().selectOption('weekly');
	await weekdays().getByRole('button', { name: 'Montag' }).click();
	await weekdays().getByRole('button', { name: 'Donnerstag' }).click();
	await expect.poll(async () => (await planning(ids.weekly)).recurrence?.weekdays).toEqual([1, 4]);
	await expect(summary()).toHaveText('Wöchentlich · Mo, Do');
	await pictures('wochentage-bearbeiten');

	await page.reload();
	await expect(dialog()).toBeVisible();
	await expect(summary()).toHaveText('Wöchentlich · Mo, Do');
	await openEditor();
	await expect(weekdays().getByRole('button', { name: 'Montag' })).toHaveAttribute('aria-pressed', 'true');
	await expect(weekdays().getByRole('button', { name: 'Dienstag' })).toHaveAttribute('aria-pressed', 'false');
	await expect(weekdays().getByRole('button', { name: 'Donnerstag' })).toHaveAttribute('aria-pressed', 'true');
	await pictures('wochentage-nach-neuladen');
});

test('"from completion" is stored and shown after a reload', async () => {
	await openCard(ids.completion);
	await openEditor();
	await frequency().selectOption('daily');
	const interval = dialog().getByLabel('Alle … Tage');
	await interval.fill('3');
	await interval.press('Tab');
	await dialog().getByLabel('Nächster Termin').selectOption('completion');
	await expect.poll(async () => (await planning(ids.completion)).recurrence).toMatchObject({ frequency: 'daily', interval: 3, basis: 'completion' });
	await expect(summary()).toHaveText('Täglich · Alle … Tage 3 · ab Erledigung');
	await pictures('ab-erledigung-bearbeiten');

	await page.reload();
	await expect(summary()).toHaveText('Täglich · Alle … Tage 3 · ab Erledigung');
	await openEditor();
	await expect(dialog().getByLabel('Nächster Termin')).toHaveValue('completion');
});

test('the 31st of the month is stored and shown after a reload, with the hint about the shortened month end', async () => {
	await openCard(ids.monthly);
	await openEditor();
	await frequency().selectOption('monthly');
	const monthDay = dialog().getByLabel('Am n-ten Tag des Monats');
	await monthDay.fill('31');
	await monthDay.press('Tab');
	await expect.poll(async () => (await planning(ids.monthly)).recurrence).toMatchObject({ frequency: 'monthly', monthDay: 31 });
	await expect(summary()).toHaveText('Monatlich · am 31. (Monatsende gekürzt)');
	await pictures('monatstag-bearbeiten');

	await page.reload();
	await expect(summary()).toHaveText('Monatlich · am 31. (Monatsende gekürzt)');
	await openEditor();
	await expect(dialog().getByLabel('Am n-ten Tag des Monats')).toHaveValue('31');
	await expect(side()).toContainText('Monatsende gekürzt');
});

test('completing the cards creates the successors on the expected dates, and they carry the rule', async () => {
	// Monday + Thursday: the due date is a Monday, so the next one is that week's Thursday.
	await openCard(ids.weekly);
	await markDone();
	await expect.poll(async () => (await tasksTitled(WEEKLY)).length).toBe(2);
	const weeklyNext = (await tasksTitled(WEEKLY)).find((x) => x.id.toLowerCase() !== ids.weekly.toLowerCase())!;
	const weekly = await planning(weeklyNext.id);
	expect(localDate(weekly.dueAt)).toBe(ymd(addDays(nextWeekday(1), 3)));
	expect(weekly.recurrence).toMatchObject({ frequency: 'weekly', weekdays: [1, 4] });

	// Every 3 days from completion: due was 5 days ago, the next one is three days from today (not from the due date).
	await openCard(ids.completion);
	await markDone();
	await expect.poll(async () => (await tasksTitled(COMPLETION)).length).toBe(2);
	const completionNext = (await tasksTitled(COMPLETION)).find((x) => x.id.toLowerCase() !== ids.completion.toLowerCase())!;
	const completion = await planning(completionNext.id);
	expect(localDate(completion.dueAt)).toBe(ymd(day(3)));
	expect(completion.recurrence).toMatchObject({ frequency: 'daily', interval: 3, basis: 'completion' });

	// The 31st: the due date is a 31st followed by a shorter month, the next one is that month's last day.
	await openCard(ids.monthly);
	await markDone();
	await expect.poll(async () => (await tasksTitled(MONTHLY)).length).toBe(2);
	const monthlyNext = (await tasksTitled(MONTHLY)).find((x) => x.id.toLowerCase() !== ids.monthly.toLowerCase())!;
	const next = await planning(monthlyNext.id);
	expect(localDate(next.dueAt)).toBe(ymd(monthly.expected));
	expect(next.recurrence).toMatchObject({ frequency: 'monthly', monthDay: 31 });

	// The successor shows its rule in the sidebar.
	await openCard(monthlyNext.id);
	await expect(summary()).toHaveText('Monatlich · am 31. (Monatsende gekürzt)');
	await pictures('nachfolger-monatstag');
});
