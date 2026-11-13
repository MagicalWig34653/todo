import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/repo-line-stability.spec.ts --project=chromium   (also --project=firefox / webkit)
// The account is created through e2e/support/session.ts (Chromium CDP passkey, cookie handed to Firefox/WebKit).
// Layout Instability API ('layout-shift') exists in Chromium only. Everywhere the spec additionally counts, independent of
// the browser: loading-state appearances and remounts of the repository line, and geometric jumps (requestAnimationFrame
// sampling of the repository line height and of the top of the board below it).
// Card A9796ED2: the repository line in the project overview must not flip to "Abgleich wird geladen" (and push the page
// content around) while the board refreshes in the background (live refresh, poll, own writes).
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const PHASE = process.env.SHOT_PHASE ?? 'run';
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/repo-anzeige');
const BASE = [
	'github.com/example/kueche',
	'github.com/a-very-long-organisation-name-for-wrapping/an-extremely-long-repository-name-that-needs-to-wrap-on-phones',
	'gitlab.example.org/team/sub/group/another-fairly-long-repository-name'
];
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Repo Stabil');
	await page.context().addInitScript(() => {
		type Probe = { cls: number; lsSupported: boolean; shifts: { value: number; at: number; nodes: string[] }[]; loadingSeen: number; mounts: number; jumps: { what: string; from: number; to: number }[]; armed: boolean; armedAt: number };
		const w = window as unknown as { __probe: Probe };
		w.__probe = { cls: 0, lsSupported: false, shifts: [], loadingSeen: 0, mounts: 0, jumps: [], armed: false, armedAt: 0 };
		try {
			new PerformanceObserver((list) => {
				for (const e of list.getEntries() as unknown as { value: number; hadRecentInput: boolean; startTime: number; sources?: { node?: Node }[] }[]) {
					if (e.hadRecentInput || !w.__probe.armed || e.startTime < w.__probe.armedAt) continue;
					w.__probe.cls += e.value;
					w.__probe.shifts.push({ value: e.value, at: Math.round(e.startTime), nodes: (e.sources ?? []).map((s) => (s.node as Element | undefined)?.nodeName ?? '?') });
				}
			}).observe({ type: 'layout-shift', buffered: true });
			w.__probe.lsSupported = (PerformanceObserver.supportedEntryTypes ?? []).includes('layout-shift');
		} catch {
			w.__probe.lsSupported = false;
		}
		let wasLoading = false;
		new MutationObserver((records) => {
			if (!w.__probe.armed) return;
			for (const r of records) for (const n of r.addedNodes) if (n instanceof Element && (n.getAttribute('data-testid') === 'repo-line' || n.querySelector('[data-testid="repo-line"]'))) w.__probe.mounts++;
			const line = document.querySelector('[data-testid="repo-line"]');
			const loading = !!line && !line.querySelector('[data-testid="repo-list"],[data-testid="repo-none"],[data-testid="repo-error"]');
			if (loading && !wasLoading) w.__probe.loadingSeen++;
			wasLoading = loading;
		}).observe(document, { childList: true, subtree: true, characterData: true });
		// Geometric fallback for browsers without the Layout Instability API: sample line height and board top every frame.
		let last: { line: number; board: number } | null = null;
		const sample = () => {
			if (w.__probe.armed) {
				const line = document.querySelector('[data-testid="repo-line"]');
				const board = document.querySelector('[data-testid="cc-board"]');
				if (line && board) {
					const cur = { line: Math.round(line.getBoundingClientRect().height), board: Math.round(board.getBoundingClientRect().top + window.scrollY) };
					if (last && cur.line !== last.line) w.__probe.jumps.push({ what: 'repo-line height', from: last.line, to: cur.line });
					if (last && cur.board !== last.board) w.__probe.jumps.push({ what: 'board top', from: last.board, to: cur.board });
					last = cur;
				}
			}
			requestAnimationFrame(sample);
		};
		requestAnimationFrame(sample);
	});
	await page.goto('/');
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

let REPOS = BASE;
async function createProject(name: string) {
	const r = await page.request.post('/v1/projects', { ...json, data: { name } });
	const project = (await r.json()) as { id: string; name: string };
	const prefs = (await (await page.request.get(`/v1/me/project-prefs/${project.id}`)).json()) as { revision: number };
	const mode = await page.request.patch(`/v1/me/project-prefs/${project.id}`, { ...json, data: { revision: prefs.revision, mode: 'management' } });
	expect(mode.ok(), `mode ${mode.status()}`).toBeTruthy();
	for (const repository of REPOS) {
		const bound = await page.request.put(`/v1/projects/${project.id}/sync`, { ...json, data: { repository } });
		expect(bound.ok(), `bind ${bound.status()}`).toBeTruthy();
	}
	return project;
}

type Probe = { cls: number; lsSupported: boolean; shifts: { value: number; at: number; nodes: string[] }[]; loadingSeen: number; mounts: number; jumps: { what: string; from: number; to: number }[] };
const probe = () => page.evaluate(() => (window as unknown as { __probe: Probe }).__probe);

for (const vp of [
	{ name: 'desktop', width: 1280, height: 800 },
	{ name: 'mobile', width: 390, height: 844 }
]) {
	test(`repository line stays put during background refreshes (${vp.name})`, async () => {
		test.setTimeout(120_000);
		await page.setViewportSize({ width: vp.width, height: vp.height });
		REPOS = BASE.map((r) => r.replace(/^([^/]+\/)/, `$1${vp.name}-`));
		const project = await createProject(`Stabil ${vp.name}`);
		await page.goto(`/project/${project.id}`);
		await page.getByTestId('project-tab-overview').click();
		await expect(page.getByTestId('repo-row')).toHaveCount(REPOS.length);
		await expect(page.getByTestId('cc-lane').first()).toBeVisible();
		mkdirSync(SHOTS, { recursive: true });
		await page.screenshot({ path: `${SHOTS}/${PHASE}-${vp.name}-start.png`, fullPage: true });

		// The first paint and the first card (empty lane -> filled lane is a real content change) may settle;
		// only shifts caused by later background refreshes count.
		await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: 'Erste Karte' } });
		await expect(page.getByTestId('cc-board').getByText('Erste Karte')).toBeVisible({ timeout: 15_000 });
		await page.waitForTimeout(1_500);
		await page.evaluate(() => {
			const armedProbe = (window as unknown as { __probe: { armed: boolean; armedAt: number } }).__probe;
			armedProbe.armedAt = performance.now();
			armedProbe.armed = true;
		});
		// Background changes: new cards and a re-bound repository, one every ~2 s for ~24 s (live refresh answers each).
		const start = Date.now();
		let i = 0;
		while (Date.now() - start < 24_000) {
			i++;
			await page.request.post('/v1/tasks', { ...json, data: { projectID: project.id, title: `Hintergrund ${i}` } });
			if (i % 3 === 0) await page.request.put(`/v1/projects/${project.id}/sync`, { ...json, data: { repository: REPOS[i % REPOS.length] } });
			await page.waitForTimeout(2_000);
		}
		// Let the last refresh settle.
		await page.waitForTimeout(2_500);
		const p = await probe();
		console.log(`PROBE ${PHASE} ${test.info().project.name} ${vp.name}: ${JSON.stringify({ lsSupported: p.lsSupported, cls: Number(p.cls.toFixed(4)), shifts: p.shifts.length, loadingSeen: p.loadingSeen, mounts: p.mounts, jumps: p.jumps.length })}`);
		console.log(`JUMPS ${vp.name}: ${JSON.stringify(p.jumps.slice(0, 10))}`);
		console.log(`SHIFTS ${vp.name}: ${JSON.stringify(p.shifts.slice(0, 10))}`);
		await page.screenshot({ path: `${SHOTS}/${PHASE}-${vp.name}-end.png`, fullPage: true });
		await expect(page.getByTestId('repo-row')).toHaveCount(REPOS.length);
		expect(p.loadingSeen, 'loading state shown again after the first load').toBe(0);
		expect(p.mounts, 'repo line was remounted').toBe(0);
		expect(p.jumps, 'repository line height or board position changed while refreshing').toEqual([]);
		// Layout Instability API: Chromium only. Elsewhere loadingSeen, mounts and jumps above are the measurement.
		if (p.lsSupported) expect(p.cls, 'layout shift while refreshing').toBeLessThan(0.01);
	});
}
