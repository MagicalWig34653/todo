import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/plan-approval.spec.ts --project=chromium   (also --project=firefox / webkit)
// Card 74EC341D (plan approval, stage 1): the Pipeline tab shows the plan of a card and the state of the six steps. A person
// approves the plan or asks for changes; agents (here: the REST API) write plans and step states, which appear live.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/plan-freigabe');
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };
const STEPS = ['Planer', 'Freigabe', 'Entwickler', 'Validierung', 'Tester', 'Review'];
const LIVE = { timeout: 15_000 };
const PLAN_1 = [
	'## Ziel',
	'Die **Pipeline** je Karte sichtbar machen.',
	'',
	'1. Datenmodell ergänzen',
	'2. Oberfläche bauen',
	'',
	'- Geprüft mit `npm test`',
	'<img src="x" onerror="window.__injected = true">',
	`Pfad: ${'sehr-langer-dateiname-ohne-leerzeichen-'.repeat(5)}ende.ts`
].join('\n');

/** A realistic plan for the pictures (with a long path that has to wrap on phones). */
const SHOT_PLAN = [
	'## Ziel',
	'Wiederkehrende Aufgaben sollen auch **an Wochentagen** funktionieren.',
	'',
	'1. Regel im Datenmodell ergänzen',
	'2. Eingabe in der Oberfläche bauen',
	'3. Tests für Monatsende und Zeitumstellung',
	'',
	'## Betroffen',
	'- `web/src/lib/components/planning/RecurrenceWeekdayEditorWithAVeryLongFileName.svelte`',
	'- Prüfung mit `npm test` und Playwright'
].join('\n');

interface Pipeline {
	plan?: { version: number; state: string; decisionComment?: string | null } | null;
	steps: { step: string; state: string; note?: string | null }[];
}
let ids = { main: '', empty: '', shots: '', run: '', long: '' };

async function call<T>(method: 'post' | 'put', path: string, data: unknown): Promise<T> {
	const r = await page.request[method](path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const writePlan = (id: string, body: string) => call<Pipeline>('put', `/v1/tasks/${id}/plan`, { body, agentName: 'claude-code' });
const decide = (id: string, decision: 'approve' | 'request_changes', version: number, comment?: string) =>
	call<Pipeline>('post', `/v1/tasks/${id}/plan/decision`, { decision, version, comment });
const setStep = (id: string, step: string, state: string, note?: string) =>
	call<Pipeline>('put', `/v1/tasks/${id}/pipeline/steps/${step}`, { state, note, agentName: 'claude-code' });
const read = async (id: string) => (await (await page.request.get(`/v1/tasks/${id}/pipeline`)).json()) as Pipeline;

const dialog = () => page.getByTestId('card-dialog');
const tab = () => dialog().getByTestId('card-tab-pipeline');
const panel = () => dialog().getByRole('tabpanel');
const step = (name: string) => panel().getByTestId('pipeline-step').nth(STEPS.indexOf(name));
const stepState = (name: string) => step(name).getByTestId('pipeline-step-state');
const plan = () => panel().getByTestId('pipeline-plan');
const comment = () => panel().getByLabel('Kommentar (optional)');
const approve = () => panel().getByRole('button', { name: 'Plan freigeben', exact: true });
const changes = () => panel().getByRole('button', { name: 'Änderungen', exact: true });
const feedback = () => panel().getByTestId('pipeline-feedback');
/** Offered after the first click on a version that replaced the one the person had before them. */
const confirmApprove = (version: number) => panel().getByRole('button', { name: `Gelesen: Version ${version} freigeben`, exact: true });
const confirmChanges = (version: number) => panel().getByRole('button', { name: `Gelesen: Änderungen zu Version ${version} senden`, exact: true });
const open = async (id: string, slug: string | null = 'pipeline') => {
	await page.goto(`/for-you?card=task:${id}${slug ? `&tab=${slug}` : ''}`);
	await expect(dialog()).toBeVisible();
	await expect(tab()).toBeVisible();
};
/** Counts the decision requests the browser sends while `action` runs. */
async function decisionsSent(action: () => Promise<unknown>): Promise<number> {
	let count = 0;
	const listener = (r: { url(): string; method(): string }) => {
		if (r.method() === 'POST' && r.url().endsWith('/plan/decision')) count++;
	};
	page.on('request', listener);
	await action();
	await page.waitForTimeout(500);
	page.off('request', listener);
	return count;
}
const noOverflow = async (label: string) => {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows`).toBeLessThanOrEqual(w.inner);
	const inner = await dialog().getByTestId('card-scroll').evaluate((el) => el.scrollWidth - el.clientWidth);
	expect(inner, `${label}: card scroll area overflows`).toBeLessThanOrEqual(0);
};

test.beforeAll(async ({ browser }) => {
	mkdirSync(SHOTS, { recursive: true });
	page = await signedInPage(browser, 'Plan Tester');
	const project = await call<{ id: string }>('post', '/v1/projects', { name: 'Planprojekt' });
	const mk = async (title: string) => (await call<{ id: string }>('post', '/v1/tasks', { projectID: project.id, title })).id;
	ids = { main: await mk('Karte mit Plan'), empty: await mk('Karte ohne Plan'), shots: await mk('Plan wartet auf Freigabe'), run: await mk('Pipeline läuft'), long: await mk('Langer Plan') };
});
test.afterAll(async () => {
	await page?.context().close();
});

test('a card without a plan shows the empty state and no approval hint', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await open(ids.empty);
	await expect(panel().getByTestId('tab-empty')).toContainText('Noch keine Pipeline');
	await expect(tab()).toHaveAccessibleName('Pipeline');
	await expect(dialog().getByTestId('card-tab-hint-pipeline')).toHaveCount(0);
	await expect(panel().getByRole('alert')).toHaveCount(0);
});

test('a server without the endpoint (404) shows the empty state without an error', async () => {
	const url = `**/v1/tasks/${ids.empty}/pipeline`;
	await page.route(url, (r) => r.fulfill({ status: 404, json: { error: true, reason: 'Not Found' } }));
	await open(ids.empty);
	await expect(panel().getByTestId('tab-empty')).toContainText('Noch keine Pipeline');
	await expect(dialog().getByRole('alert')).toHaveCount(0);
	await page.unroute(url);
});

test('a written plan appears live, the tab announces the waiting approval and the Markdown stays text', async () => {
	await open(ids.main, null);
	await expect(tab()).toHaveAccessibleName('Pipeline');
	await writePlan(ids.main, PLAN_1);
	// Without a reload: the hint reaches the open card while another tab is selected.
	await expect(tab()).toHaveAccessibleName('Pipeline, Freigabe wartet', LIVE);
	await expect(dialog().getByTestId('card-tab-hint-pipeline')).toBeVisible();
	await tab().click();
	await expect(panel().getByTestId('pipeline-step')).toHaveCount(6);
	for (const [i, name] of STEPS.entries()) await expect(panel().getByTestId('pipeline-step').nth(i)).toContainText(name);
	await expect(stepState('Planer')).toHaveText('Fertig');
	await expect(stepState('Freigabe')).toHaveText('Wartet auf Freigabe');
	for (const name of ['Entwickler', 'Validierung', 'Tester', 'Review']) await expect(stepState(name)).toHaveText('Offen');
	await expect(plan()).toContainText('Version 1');
	await expect(plan()).toContainText('claude-code');
	await expect(plan().getByTestId('pipeline-plan-state')).toHaveText('Wartet auf Freigabe');
	const body = plan().getByTestId('pipeline-plan-body');
	await expect(body.locator('ol > li')).toHaveText(['Datenmodell ergänzen', 'Oberfläche bauen']);
	await expect(body.locator('strong')).toHaveText('Pipeline');
	// No raw HTML: the tag is shown as text and never becomes an element.
	await expect(body).toContainText('<img src="x"');
	await expect(body.locator('img')).toHaveCount(0);
	expect(await page.evaluate(() => (window as unknown as { __injected?: boolean }).__injected)).toBeUndefined();
	const history = panel().getByTestId('pipeline-history');
	await history.locator('summary').click();
	await expect(history.getByTestId('pipeline-event')).toContainText(['Plan Version 1 geschrieben']);
});

test('changes without a comment explain what is missing and send nothing', async () => {
	await open(ids.main);
	const sent = await decisionsSent(() => changes().click());
	expect(sent).toBe(0);
	await expect(panel().getByRole('alert')).toContainText('Beschreibe im Kommentar');
	await expect(comment()).toBeFocused();
	await expect(comment()).toHaveAttribute('aria-invalid', 'true');
	await comment().fill('x');
	await expect(panel().getByRole('alert')).toHaveCount(0);
	expect((await read(ids.main)).plan?.state).toBe('proposed');
});

test('a plan rewritten before the click is not approved: reload, message, comment kept', async () => {
	await open(ids.main);
	await expect(plan()).toContainText('Version 1');
	await comment().fill('Mein halb fertiger Kommentar');
	// Freeze what the browser reads until it sends the decision, so the click really is based on the old version.
	const url = `**/v1/tasks/${ids.main}/pipeline`;
	const stale = await read(ids.main);
	let frozen = true;
	await page.route(url, (r) => (frozen ? r.fulfill({ json: stale }) : r.continue()));
	await page.route('**/plan/decision', (r) => {
		frozen = false;
		return r.continue();
	});
	await writePlan(ids.main, `${PLAN_1}\n- Nachtrag`);
	const sent = await decisionsSent(() => approve().click());
	expect(sent).toBe(1);
	await expect(feedback()).toContainText('Der Plan wurde inzwischen geändert');
	await expect(plan()).toContainText('Version 2');
	await expect(comment()).toHaveValue('Mein halb fertiger Kommentar');
	expect((await read(ids.main)).plan).toMatchObject({ version: 2, state: 'proposed' });
	await page.unroute(url);
	await page.unroute('**/plan/decision');
});

test('a live refresh keeps the typed comment and announces the new version', async () => {
	await open(ids.main);
	await comment().fill('Bleibt beim Aktualisieren stehen');
	await writePlan(ids.main, `${PLAN_1}\n- Zweiter Nachtrag`);
	await expect(plan()).toContainText('Version 3', LIVE);
	await expect(feedback()).toContainText('Neue Planversion 3');
	await expect(comment()).toHaveValue('Bleibt beim Aktualisieren stehen');
	await expect(comment()).toBeFocused();
	// Switching tabs keeps the draft too.
	await dialog().getByTestId('card-tab-overview').click();
	await tab().click();
	await expect(comment()).toHaveValue('Bleibt beim Aktualisieren stehen');
	// The version changed under the person: no click on the usual buttons sends anything, not even a double click.
	expect(await decisionsSent(() => approve().click())).toBe(0);
	await expect(feedback()).toContainText('Neue Fassung – bitte erst lesen');
	await expect(confirmApprove(3)).toBeVisible();
	await expect(confirmApprove(3)).toBeInViewport();
	await expect(approve()).toBeEnabled();
	expect(await decisionsSent(() => approve().dblclick())).toBe(0);
	expect(await decisionsSent(() => changes().dblclick())).toBe(0);
	await expect(confirmChanges(3)).toBeVisible();
	await expect(confirmApprove(3)).toHaveCount(0);
	await expect(comment()).toHaveValue('Bleibt beim Aktualisieren stehen');
	expect((await read(ids.main)).plan).toMatchObject({ version: 3, state: 'proposed' });
});

test('asking for changes sends one request and shows the decision with its comment', async () => {
	await open(ids.main);
	await comment().fill('Bitte die Tests zuerst.');
	const sent = await decisionsSent(() => changes().dblclick());
	expect(sent).toBe(1);
	await expect(plan().getByTestId('pipeline-plan-state')).toHaveText('Änderungen angefragt');
	await expect(plan().getByTestId('pipeline-plan-decided')).toContainText('Bitte die Tests zuerst.');
	await expect(plan().getByTestId('pipeline-plan-decided')).toContainText('Plan Tester');
	await expect(stepState('Freigabe')).toHaveText('Änderungen angefragt');
	await expect(step('Freigabe')).toContainText('Bitte die Tests zuerst.');
	await expect(stepState('Planer')).toHaveText('Offen');
	await expect(feedback()).toContainText('Änderungen angefragt');
	await expect(feedback()).toBeFocused();
	await expect(comment()).toHaveCount(0);
	await expect(approve()).toHaveCount(0);
	await expect(tab()).toHaveAccessibleName('Pipeline');
	const server = await read(ids.main);
	expect(server.plan).toMatchObject({ version: 3, state: 'changes_requested', decisionComment: 'Bitte die Tests zuerst.' });
});

test('a new plan returns live; approval works with the keyboard and step states follow the agent', async () => {
	await open(ids.main);
	// The person must have seen the old version, otherwise the new one is simply the first they read and needs no confirmation.
	await expect(plan()).toContainText('Version 3');
	await writePlan(ids.main, '1. Tests zuerst\n2. Umsetzung');
	await expect(plan()).toContainText('Version 4', LIVE);
	await expect(stepState('Freigabe')).toHaveText('Wartet auf Freigabe');
	await expect(tab()).toHaveAccessibleName('Pipeline, Freigabe wartet');
	await comment().focus();
	// WebKit on macOS tabs to buttons only with Option+Tab (system keyboard setting).
	const macWebKit = process.platform === 'darwin' && page.context().browser()?.browserType().name() === 'webkit';
	await page.keyboard.press(macWebKit ? 'Alt+Tab' : 'Tab');
	await expect(approve()).toBeFocused();
	// The plan changed while the old version was open: the first Enter only asks to read, pressing it again sends nothing.
	expect(await decisionsSent(async () => {
		await page.keyboard.press('Enter');
		await expect(feedback()).toBeFocused();
		await page.keyboard.press('Enter');
	})).toBe(0);
	await expect(feedback()).toContainText('Neue Fassung – bitte erst lesen');
	await page.keyboard.press(macWebKit ? 'Alt+Tab' : 'Tab');
	await expect(confirmApprove(4)).toBeFocused();
	const sent = await decisionsSent(() => page.keyboard.press('Enter'));
	expect(sent).toBe(1);
	await expect(plan().getByTestId('pipeline-plan-state')).toHaveText('Freigegeben');
	await expect(feedback()).toContainText('Plan freigegeben');
	await expect(stepState('Freigabe')).toHaveText('Fertig');
	await expect(approve()).toHaveCount(0);
	await expect(tab()).toHaveAccessibleName('Pipeline');
	// The agent reports the steps after the approval.
	await setStep(ids.main, 'developer', 'running', 'Baut die Oberfläche');
	await expect(stepState('Entwickler')).toHaveText('Läuft', LIVE);
	await expect(step('Entwickler')).toContainText('Baut die Oberfläche');
	await expect(step('Entwickler')).toContainText('claude-code');
	await setStep(ids.main, 'developer', 'done');
	await setStep(ids.main, 'validation', 'skipped');
	await setStep(ids.main, 'tester', 'failed', '2 Tests rot');
	await expect(stepState('Entwickler')).toHaveText('Fertig', LIVE);
	await expect(stepState('Validierung')).toHaveText('Übersprungen', LIVE);
	await expect(stepState('Tester')).toHaveText('Fehlgeschlagen', LIVE);
	await expect(step('Tester')).toContainText('2 Tests rot');
	await expect(stepState('Review')).toHaveText('Offen');
	const history = panel().getByTestId('pipeline-history');
	await history.locator('summary').click();
	await expect(history).toContainText('Tester: Fehlgeschlagen');
	await expect(history).toContainText('Plan Version 4 freigegeben');
	await expect(history).toContainText('Änderungen zu Plan Version 3 angefragt');
	// The card activity names the events in German.
	await dialog().getByTestId('card-tab-activity').click();
	await expect(panel().getByTestId('activity').filter({ hasText: 'Plan freigegeben' }).first()).toBeVisible();
	await expect(panel()).not.toContainText('pipeline.step');
	await page.keyboard.press('Escape');
	await expect(dialog()).toHaveCount(0);
});

for (const [label, size] of [['desktop', { width: 1280, height: 900 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: light and dark screenshots without horizontal scrolling`, async () => {
		await page.setViewportSize(size);
		if ((await read(ids.shots)).plan == null) {
			await writePlan(ids.shots, SHOT_PLAN);
			await writePlan(ids.run, '1. Datenmodell\n2. Oberfläche\n3. Tests');
			await decide(ids.run, 'approve', 1, 'Passt so.');
			await setStep(ids.run, 'developer', 'done', 'Oberfläche gebaut');
			await setStep(ids.run, 'validation', 'done');
			await setStep(ids.run, 'tester', 'running', 'Playwright in drei Browsern');
		}
		for (const scheme of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: scheme });
			for (const [name, id] of [['wartet', ids.shots], ['laeuft', ids.run]] as const) {
				await open(id);
				await expect(plan()).toBeVisible();
				await noOverflow(`${label} ${scheme} ${name}`);
				await page.waitForTimeout(300);
				await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-${name}.png` });
				const end = name === 'wartet' ? approve() : panel().getByTestId('pipeline-history');
				await end.scrollIntoViewIfNeeded();
				await expect(end).toBeInViewport();
				await noOverflow(`${label} ${scheme} ${name} end`);
				await page.screenshot({ path: `${SHOTS}/${label}-${scheme}-${name}-ende.png` });
			}
		}
		await page.emulateMedia({ colorScheme: 'light' });
	});
}

/** Scrolls the open panel under the pinned tab bar and lists what shows through between the top of the scroll area and the bar. */
const leaksAboveTabs = () =>
	dialog().getByTestId('card-tabs').evaluate((bar) => {
		let box = bar.parentElement!;
		while (!(/auto|scroll/.test(getComputedStyle(box).overflowY) && box.scrollHeight > box.clientHeight)) box = box.parentElement!;
		const area = bar.parentElement!;
		box.scrollTop += area.getBoundingClientRect().top - box.getBoundingClientRect().top + 200;
		const top = box.getBoundingClientRect().top;
		const r = bar.getBoundingClientRect();
		const leaks: string[] = [];
		for (const dy of [1, 8, 16, 23])
			for (const x of [r.left + 40, r.left + r.width / 2, r.right - 40]) {
				const hit = document.elementFromPoint(x, top + dy);
				if (!bar.contains(hit)) leaks.push(`${dy}px: ${hit?.textContent?.trim().slice(0, 30)}`);
			}
		return { scrolledPast: area.getBoundingClientRect().top < top - 100, barOffset: Math.round(r.top - top), leaks };
	});

for (const [label, size] of [['desktop', { width: 1280, height: 800 }], ['mobile', { width: 390, height: 844 }]] as const) {
	test(`${label}: nothing shows through above the pinned tab bar while a long panel scrolls`, async () => {
		await page.setViewportSize(size);
		await writePlan(ids.long, Array.from({ length: 60 }, (_, i) => `${i + 1}. Schritt ${i + 1} des langen Plans`).join('\n'));
		await open(ids.long);
		await expect(plan()).toContainText('Schritt 60');
		expect(await leaksAboveTabs()).toEqual({ scrolledPast: true, barOffset: 0, leaks: [] });
		await expect(tab()).toBeInViewport();
	});
}
