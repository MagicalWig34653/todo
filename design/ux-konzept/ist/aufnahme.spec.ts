// Screenshot run of the current PWA (UX concept, card 607DB96E). Not part of the test suite.
// Run: copy to web/e2e/zz-ux-aufnahme.spec.ts, start a throwaway backend (fresh SQLite, BOOTSTRAP_TOKEN=dev-bootstrap-only,
// RP_ORIGIN=http://localhost:$E2E_PORT) and the dev server, then
//   E2E_PORT=25977 npx playwright test zz-ux-aufnahme   (from web/)
import { test } from '@playwright/test';
import { signedInPage } from './support/session';
import { seedNow } from './support/nowSeed';

const OUT = '../design/ux-konzept/ist';
const DAY = 24 * 3600 * 1000;
const SIZES = { desktop: { width: 1280, height: 800 }, handy: { width: 390, height: 844 } } as const;

test('Ist-Aufnahme', async ({ browser, playwright }) => {
	test.setTimeout(600_000);
	const page = await signedInPage(browser, 'Demo Person');
	const helper = await playwright.request.newContext();
	const ids = await seedNow(page, helper);
	const api = async (method: 'post' | 'put', path: string, data: unknown) => {
		const r = await page.request[method](path, { headers: { 'Content-Type': 'application/json' }, data });
		if (r.status() >= 300) console.log('seed', path, r.status(), await r.text());
		return r.json().catch(() => ({}));
	};
	const p = ids.projects.todolino;
	for (const name of ['Offen', 'In Arbeit', 'Review', 'Erledigt']) await api('post', `/v1/projects/${p}/columns`, { name });
	const mk = async (title: string, from: number, days: number) => {
		const t = await api('post', '/v1/tasks', { projectID: p, title });
		await api('put', `/v1/planning/tasks/${t.id}`, { priority: 0, reminders: [], plannedAt: new Date(Date.now() + from * DAY).toISOString(), dueAt: new Date(Date.now() + (from + days) * DAY).toISOString() });
		return t.id as string;
	};
	const a = await mk('Konzept Zeitleiste', -3, 4);
	const b = await mk('Datenmodell erweitern', 2, 3);
	const c = await mk('Oberfläche bauen', 4, 6);
	await api('put', `/v1/planning/tasks/${b}/dependencies`, { prerequisiteID: a });
	await api('put', `/v1/planning/tasks/${c}/dependencies`, { prerequisiteID: b });
	const m = await api('post', '/v1/planning/milestones', { projectID: p, title: 'Version 2.0', dueAt: new Date(Date.now() + 12 * DAY).toISOString() });
	for (const t of [a, b, c]) await api('put', `/v1/planning/milestones/${m.id}/tasks/${t}`, {});
	await api('post', '/v1/project-groups', { name: 'Eigene Produkte', projectIDs: [p, ids.projects.form] });

	const views: [string, string][] = [
		['fuer-dich', '/for-you'], ['ueberblick', '/overview'], ['jetzt', '/now'], ['heute', '/today'], ['anstehend', '/upcoming'],
		['kalender', '/calendar'], ['projekt-liste', `/project/${p}/list`], ['projekt-board', `/project/${p}/board`], ['projekt-graph', `/project/${p}/graph`],
		['projekt-uebersicht', `/project/${p}/overview`], ['aufgabe', `/project/${p}/list?task=${c}`], ['karte-frage', `/for-you?card=task:${ids.tasks.question}`],
		['einstellungen', '/settings'], ['vollmacht', '/settings/brain-mandate'], ['projektgruppen', '/settings/project-groups']
	];
	const extra: [string, string][] = [
		['eingang', '/inbox'], ['als-naechstes', '/up-next'], ['suche', '/search'], ['filter', '/filter'], ['teams', '/teams'], ['agenten', '/agents'],
		['brain', '/brain'], ['aktivitaet', '/activity'], ['hilfe', '/help']
	];
	const shot = async (name: string, size: string, scheme: string) => {
		await page.waitForTimeout(900);
		await page.screenshot({ path: `${OUT}/${name}-${size}-${scheme}.jpg`, type: 'jpeg', quality: 72 });
	};
	for (const [size, viewport] of Object.entries(SIZES)) {
		await page.setViewportSize(viewport);
		for (const [scheme, colorScheme] of [['hell', 'light'], ['dunkel', 'dark']] as const) {
			await page.emulateMedia({ colorScheme });
			for (const [name, url] of [...views, ...(scheme === 'hell' ? extra : [])]) {
				await page.goto(url);
				await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
				await shot(name, size, scheme);
			}
		}
		// Menus and popovers (light only).
		await page.emulateMedia({ colorScheme: 'light' });
		const open = async (name: string, url: string, ...steps: (() => Promise<unknown>)[]) => {
			await page.goto(url);
			await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {});
			try {
				for (const s of steps) await s();
				await shot(name, size, 'hell');
			} catch (e) {
				console.log('menu', name, size, String(e).slice(0, 200));
			}
		};
		const tap = (testid: string) => () => page.getByTestId(testid).first().click({ timeout: 5000 });
		await open('menu-ansicht', `/project/${p}/list`, tap('display-menu'));
		await open('menu-projekt', `/project/${p}/list`, tap('project-more'));
		await open('menu-konto', '/for-you', tap('account-menu'));
		await open('schnell-anlegen', '/for-you', tap(size === 'handy' ? 'fab' : 'quick-add-open'));
		if (size === 'handy') await open('menu-schublade', '/for-you', () => page.getByRole('navigation', { name: /Haupt/ }).getByRole('button').last().click());
		else await open('menu-seitenleiste-mehr', '/for-you', () => page.getByRole('button', { name: 'Mehr', exact: true }).click());
	}
});
