import { expect, test, type Page, type Request } from '@playwright/test';

// Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/board-single-fetch.spec.ts --project=chromium
// Card 65857554: when the project list is refreshed in the background (a project field changed elsewhere), the board of the
// open project overview is fetched exactly once. The effects of CommandCenter.svelte used to read the `projectID` getter prop
// directly, so the refreshed project object re-ran them next to the live refresh and the board was requested twice.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
test.describe.configure({ mode: 'serial' });
let page: Page;
const json = { headers: { 'Content-Type': 'application/json' } };

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	page = await (await browser.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Board Zaehler');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(page.getByTestId('account-menu')).toBeVisible();
});
test.afterAll(async () => {
	await page?.context().close();
});

async function createProject(name: string) {
	const r = await page.request.post('/v1/projects', { ...json, data: { name } });
	const project = (await r.json()) as { id: string; name: string };
	const prefs = (await (await page.request.get(`/v1/me/project-prefs/${project.id}`)).json()) as { revision: number };
	const mode = await page.request.patch(`/v1/me/project-prefs/${project.id}`, { ...json, data: { revision: prefs.revision, mode: 'management' } });
	expect(mode.ok(), `mode ${mode.status()}`).toBeTruthy();
	return project;
}

/** Board requests of the open project: the command center without the "updates only" form (`limit=1`). */
function boardRequests(projectID: string) {
	const seen: string[] = [];
	const onRequest = (r: Request) => {
		const url = new URL(r.url());
		if (url.pathname !== '/v1/command-center' || url.searchParams.get('projectID') !== projectID) return;
		if (url.searchParams.get('limit') === '1') return;
		seen.push(`${url.pathname}${url.search}`);
	};
	page.on('request', onRequest);
	return { seen, stop: () => page.off('request', onRequest) };
}

test('a project list refresh fetches the board exactly once', async () => {
	test.setTimeout(90_000);
	const project = await createProject('Board einmal');
	let version = (project as unknown as { version: number }).version;
	await page.goto(`/project/${project.id}`);
	await page.getByTestId('project-tab-overview').click();
	await expect(page.getByTestId('cc-board')).toBeVisible();
	// Let the first load, the prefs and any startup refresh settle before counting.
	await page.waitForTimeout(3_000);
	// The project list answers later than the board (slow list, large account): the refreshed project object then arrives
	// after the live refresh of the board has finished, so a second board request cannot be merged with the first one.
	await page.route('**/v1/projects', async (route) => {
		await new Promise((resolve) => setTimeout(resolve, 1_200));
		await route.continue();
	});

	for (let round = 1; round <= 3; round++) {
		const counter = boardRequests(project.id);
		// A change to the project itself: the next live refresh replaces the project in the workspace list.
		const renamed = `Board einmal ${round}`;
		const patch = await page.request.patch(`/v1/projects/${project.id}`, { ...json, data: { version, name: renamed } });
		expect(patch.ok(), `rename ${patch.status()}`).toBeTruthy();
		version = ((await patch.json()) as { version: number }).version;
		await expect(page.getByTestId('project-item').getByRole('button', { name: renamed, exact: true }).first()).toBeVisible({ timeout: 15_000 });
		await page.waitForTimeout(2_500);
		counter.stop();
		expect(counter.seen, `board requests in round ${round}: ${counter.seen.join(' | ')}`).toHaveLength(1);
	}
});
