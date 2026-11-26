import { createHash, randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { mcp } from './support/oauth';
import { signedInPage } from './support/session';

// Card BEF08998 part 3 (ADR 0037), needs a fresh backend database:
//   npx playwright test e2e/project-groups.spec.ts --project=chromium   (also --project=firefox, --project=webkit)
// The person creates a group, grants it on the real consent page and in a brain mandate, switches the mandate to "all my
// projects except", creates a project into the group and takes it out again; the MCP connection always sees exactly that.
// Screenshots (docs/screenshots/projektgruppen/) are written by the Chromium run only.
const SHOTS = resolve(dirname(fileURLToPath(import.meta.url)), '../../docs/screenshots/projektgruppen');
const CALLBACK = 'http://127.0.0.1:59999/callback';
const CLIENT = 'Claude Code (Brain)';
test.describe.configure({ mode: 'serial', timeout: 120_000 });

let page: Page;
let mcpApi: APIRequestContext;
let heizung = '', lager = '', privat = '';
let token = '';

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Gruppen Tester');
	mcpApi = await request.newContext({ baseURL: test.info().project.use.baseURL });
	await page.route(`${CALLBACK}**`, (route) => route.fulfill({ status: 200, contentType: 'text/html', body: 'ok' }));
	const make = async (name: string) => {
		const r = await page.request.post('/v1/projects', { data: { name } });
		expect(r.ok(), await r.text()).toBeTruthy();
		return ((await r.json()) as { id: string }).id;
	};
	heizung = await make('Heizung');
	lager = await make('Lager');
	privat = await make('Privat');
});
test.afterAll(async () => {
	await mcpApi?.dispose();
	await page?.context().close();
});

const sorted = (ids: string[] = []) => ids.map((i) => i.toLowerCase()).sort();
const connectionProjects = async () => sorted(((await (await page.request.get('/oauth/grants')).json()) as { project_ids: string[] }[])[0].project_ids);
const mandateProjects = async () => sorted(((await mcp(mcpApi, token, 'get_connection', {})).brainMandate as { projectIDs?: string[] }).projectIDs);
const projectID = async (name: string) => ((await (await page.request.get('/v1/projects')).json()) as { id: string; name: string }[]).find((p) => p.name === name)!.id;

const shoots = () => test.info().project.name === 'chromium';
async function noOverflow(label: string) {
	const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
	expect(over, `${label}: page overflows horizontally`).toBeLessThanOrEqual(0);
}
const WIDTHS = [['desktop', 1280], ['mobil', 375], ['schmal', 320]] as const;
/** The consent page follows the system colour scheme; checked light and dark at three widths, photographed at two. */
async function consentShots(name: string) {
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		for (const [label, width] of WIDTHS) {
			await page.setViewportSize({ width, height: 900 });
			await noOverflow(`${name} ${label} ${scheme}`);
			await page.addStyleTag({ content: '.bar{position:static}' }).catch(() => {});
			if (shoots() && label !== 'schmal') await page.screenshot({ path: `${SHOTS}/${label}-${scheme === 'light' ? 'hell' : 'dunkel'}-${name}.png`, fullPage: true });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize({ width: 1280, height: 900 });
}
/** The PWA keeps its colour scheme in the account. `open` brings the part on screen again after each reload. */
async function appShots(testid: string, name: string, open: () => Promise<void>) {
	for (const mode of ['light', 'dark'] as const) {
		const prefs = (await (await page.request.get('/v1/me/preferences')).json()) as { appearance: Record<string, unknown> };
		const put = await page.request.put('/v1/me/preferences', { data: { version: 1, appearance: { ...prefs.appearance, colorScheme: mode } } });
		expect(put.ok(), await put.text()).toBeTruthy();
		await page.emulateMedia({ colorScheme: mode });
		await page.evaluate((m) => localStorage.setItem('todo.theme', m), mode);
		for (const [label, width] of WIDTHS) {
			// A tall viewport shows the whole part in one real frame (the app shell has fixed bars).
			await page.setViewportSize({ width, height: 2600 });
			await open();
			await expect(page.getByTestId(testid).first()).toBeVisible({ timeout: 20_000 });
			expect(await page.evaluate(() => document.documentElement.classList.contains('dark'))).toBe(mode === 'dark');
			await noOverflow(`${name} ${label} ${mode}`);
			if (shoots() && label !== 'schmal') await page.getByTestId(testid).first().screenshot({ path: `${SHOTS}/${label}-${mode === 'light' ? 'hell' : 'dunkel'}-${name}.png` });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.evaluate(() => localStorage.setItem('todo.theme', 'light'));
	await page.setViewportSize({ width: 1280, height: 900 });
	await open();
}

const group = () => page.locator('[data-testid="pg-group"][data-name="Haus"]');

test('the person creates a group with the keyboard', async () => {
	await page.goto('/settings/project-groups');
	await page.getByTestId('pg-new-name').fill('Haus');
	await page.getByTestId('pg-new-name').press('Enter');
	await expect(group()).toBeVisible({ timeout: 20_000 });
	await group().getByRole('checkbox', { name: 'Heizung' }).press('Space');
	await group().getByTestId('pg-save').press('Enter');
	await expect(page.getByTestId('pg-message')).toContainText('gespeichert');
	await expect(group().getByTestId('pg-members')).toHaveText('Heizung');
});

test('the consent page grants the group and shows what it reaches', async () => {
	const reg = await page.request.post('/oauth/register', { data: { client_name: CLIENT, redirect_uris: [CALLBACK], token_endpoint_auth_method: 'none' } });
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	const verifier = randomBytes(32).toString('base64url');
	const query = new URLSearchParams({
		response_type: 'code', client_id: clientID, redirect_uri: CALLBACK, scope: 'projects:read projects:write tasks:read', state: 's',
		code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256'
	});
	await page.goto(`/oauth/authorize?${query}`);
	await expect(page.getByRole('button', { name: 'Erlauben' })).toBeVisible({ timeout: 20_000 });

	// "All except": the exclusions appear, the page says that new projects join and which are in effect.
	await page.getByRole('radio', { name: 'Alle meine Projekte außer …' }).check();
	await expect(page.locator('#selhint')).toContainText('auch für neue');
	await expect(page.locator('#effective')).toContainText('3 Projekte: Heizung, Lager, Privat');
	await page.locator('.exprojectlist').getByRole('checkbox', { name: 'Privat' }).check();
	await expect(page.locator('#effective')).toContainText('2 Projekte: Heizung, Lager.');
	await consentShots('zustimmung-alle-ausser');

	await page.getByRole('radio', { name: 'Gewählte Projekte und Gruppen' }).check();
	await expect(page.locator('.exprojectlist')).toBeHidden();
	await page.locator('.grouplist').getByRole('checkbox', { name: 'Haus' }).check();
	await expect(page.locator('#selhint')).toContainText('Neue Projekte dieser Gruppen');
	await expect(page.locator('#effective')).toContainText('1 Projekt: Heizung.');
	await consentShots('zustimmung-gruppe');

	const arrived = page.waitForRequest((r) => r.url().startsWith(CALLBACK));
	await page.getByRole('button', { name: 'Erlauben' }).click();
	const code = new URL((await arrived).url()).searchParams.get('code');
	const t = await page.request.post('/oauth/token', { form: { grant_type: 'authorization_code', client_id: clientID, code: code!, redirect_uri: CALLBACK, code_verifier: verifier } });
	expect(t.ok(), await t.text()).toBeTruthy();
	token = ((await t.json()) as { access_token: string }).access_token;
	expect(await connectionProjects()).toEqual(sorted([heizung]));
	const groups = (await mcp(mcpApi, token, 'list_project_groups', {})) as unknown as { name: string }[];
	expect(groups.map((g) => g.name)).toEqual(['Haus']);
});

test('a group change shows its effect before it is saved', async () => {
	await page.goto('/settings/project-groups');
	await group().getByTestId('pg-edit').click();
	await group().getByRole('checkbox', { name: 'Lager' }).check();
	await group().getByTestId('pg-save').click();
	const change = page.getByTestId('pg-change');
	await expect(change).toHaveCount(1);
	await expect(change).toContainText(CLIENT);
	await expect(change).toContainText('Lager');
	// Nothing is saved before the confirmation.
	expect(await connectionProjects()).toEqual(sorted([heizung]));
	await appShots('pg-impact', 'gruppe-aenderung', async () => {
		await page.goto('/settings/project-groups');
		await group().getByTestId('pg-edit').click();
		await group().getByRole('checkbox', { name: 'Lager' }).check();
		await group().getByTestId('pg-save').click();
	});
	await page.getByTestId('pg-confirm').click();
	await expect(page.getByTestId('pg-message')).toContainText('gespeichert');
	expect(await connectionProjects()).toEqual(sorted([heizung, lager]));
});

test('a brain mandate by group, then "all my projects except"', async () => {
	await page.goto('/settings/brain-mandate');
	await page.getByTestId('bm-grant-option').click();
	await page.getByTestId('bm-group').check();
	await expect(page.getByTestId('bm-effective-count')).toContainText('2 Projekte');
	await page.getByTestId('bm-save').click();
	await expect(page.getByTestId('bm-status')).toHaveText('Aktiv');
	await expect(page.getByTestId('bm-rule')).toContainText('Haus');
	expect(await mandateProjects()).toEqual(sorted([heizung, lager]));

	await page.getByTestId('bm-edit').click();
	await page.getByTestId('bm-mode-all').check();
	await expect(page.getByTestId('bm-hint')).toContainText('neue');
	await page.getByTestId('bm-selection').getByRole('checkbox', { name: 'Privat' }).first().check();
	await expect(page.getByTestId('bm-effective-list')).toHaveText('Heizung, Lager');
	await appShots('bm-form-card', 'vollmacht-alle-ausser', async () => {
		await page.goto('/settings/brain-mandate');
		await page.getByTestId('bm-edit').click();
		await page.getByTestId('bm-mode-all').check();
		await page.getByTestId('bm-selection').getByRole('checkbox', { name: 'Privat' }).first().check();
		await expect(page.getByTestId('bm-effective-list')).toHaveText('Heizung, Lager');
	});
	await page.getByTestId('bm-save').click();
	await page.getByTestId('bm-confirm-go').click();
	await expect(page.getByTestId('bm-rule')).toContainText('Privat');
	expect(await mandateProjects()).toEqual(sorted([heizung, lager]));
});

test('a new project of the group is in effect at once', async () => {
	await page.goto('/');
	await page.getByTestId('add-project').click();
	const dialog = page.getByTestId('add-project-dialog');
	await dialog.getByRole('textbox').fill('Garten');
	await dialog.getByRole('checkbox', { name: 'Haus' }).check();
	await dialog.getByRole('textbox').press('Enter');
	await expect.poll(async () => (await connectionProjects()).length).toBe(3);
	const garten = await projectID('Garten');
	expect(await connectionProjects()).toEqual(sorted([heizung, lager, garten]));
	// "All except Privat" takes the new project as well.
	expect(await mandateProjects()).toEqual(sorted([heizung, lager, garten]));
	expect(await mandateProjects()).not.toContain(privat.toLowerCase());
});

test('taking a project out of the group in its settings works at once', async () => {
	const garten = await projectID('Garten');
	const open = async () => {
		await page.goto(`/project/${garten}`);
		await page.getByTestId('project-more').click();
		await page.getByTestId('project-groups-open').click();
		await page.getByTestId('project-groups-dialog').getByRole('checkbox', { name: 'Haus' }).uncheck();
		await expect(page.getByTestId('project-groups-impact')).toContainText(CLIENT);
	};
	await open();
	await appShots('project-groups-dialog', 'projekt-gruppen', open);
	await page.getByTestId('project-groups-save').click();
	await expect(page.getByTestId('project-groups-dialog')).toBeHidden();
	expect(await connectionProjects()).toEqual(sorted([heizung, lager]));
});

test('the connected app shows its rule; deleting the group withdraws it', async () => {
	await appShots('oauth-grants', 'verbindung-gruppe', async () => {
		await page.goto('/settings/connections');
		await expect(page.getByTestId('oauth-rule')).toContainText('Haus');
	});
	await appShots('project-groups', 'gruppen-seite', async () => {
		await page.goto('/settings/project-groups');
		await expect(group()).toBeVisible({ timeout: 20_000 });
	});
	await group().getByTestId('pg-delete').click();
	await expect(page.getByTestId('pg-impact')).toContainText(CLIENT);
	await page.getByTestId('pg-confirm').click();
	await expect(page.getByTestId('pg-empty')).toBeVisible();
	expect(await connectionProjects()).toEqual([]);
});
