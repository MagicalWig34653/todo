import { expect, test, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Card A7865053: the repository line of an open project must follow bindings changed elsewhere (another tab, an agent, MCP)
// without a reload and without flashing the loading state (that flicker was card A9796ED2). Needs a fresh backend database. Run on its own:
//   npx playwright test e2e/repo-line-refresh.spec.ts --project=chromium   (also firefox, webkit)
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
let page: Page;
let projectID = '';

test('setup: management project with one binding, overview open', async ({ browser }) => {
	test.setTimeout(90_000);
	page = await signedInPage(browser, 'Repo Refresh');
	const project = (await (await page.request.post('/v1/projects', { ...json, data: { name: 'Nachladen' } })).json()) as { id: string };
	projectID = project.id;
	const prefs = (await (await page.request.get(`/v1/me/project-prefs/${projectID}`)).json()) as { revision: number };
	expect((await page.request.patch(`/v1/me/project-prefs/${projectID}`, { ...json, data: { revision: prefs.revision, mode: 'management' } })).ok()).toBeTruthy();
	expect((await page.request.put(`/v1/projects/${projectID}/sync`, { ...json, data: { repository: 'github.com/example/eins' } })).ok()).toBeTruthy();
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await page.getByTestId('project-item').getByRole('button', { name: 'Nachladen', exact: true }).first().click();
	await page.getByTestId('project-tab-overview').click();
	const head = page.getByTestId('cc-sync-head');
	await expect(head.getByTestId('repo-row')).toHaveCount(1);
	await expect(head.getByTestId('repo-name')).toHaveText('github.com/example/eins');
});

test('a binding added elsewhere appears without reload and without the loading state', async () => {
	const head = page.getByTestId('cc-sync-head');
	// Count every time the loading line of the repository row is shown from now on (it must not be).
	await page.evaluate(() => {
		(window as unknown as { __loading: number }).__loading = 0;
		const watch = () => {
			const el = document.querySelector('[data-testid="repo-line"]');
			if (el && /wird geladen|laden/i.test(el.textContent ?? '') && !el.querySelector('[data-testid="repo-row"]')) (window as unknown as { __loading: number }).__loading++;
		};
		new MutationObserver(watch).observe(document.body, { childList: true, subtree: true, characterData: true });
	});
	// Another actor (same account, REST) binds a second repository.
	expect((await page.request.put(`/v1/projects/${projectID}/sync`, { ...json, data: { repository: 'github.com/example/zwei' } })).ok()).toBeTruthy();
	await expect(head.getByTestId('repo-row'), 'new binding shown without reload').toHaveCount(2, { timeout: 20_000 });
	await expect(head.getByTestId('repo-name').nth(1)).toHaveText('github.com/example/zwei');
	expect(await page.evaluate(() => (window as unknown as { __loading: number }).__loading), 'loading state flashed').toBe(0);
});

test('a binding removed elsewhere disappears without reload', async () => {
	const head = page.getByTestId('cc-sync-head');
	const removed = await page.request.delete(`/v1/projects/${projectID}/bindings?repository=${encodeURIComponent('github.com/example/eins')}`, json);
	expect(removed.ok(), `unbind: ${removed.status()} ${await removed.text()}`).toBeTruthy();
	await expect(head.getByTestId('repo-row'), 'removed binding gone without reload').toHaveCount(1, { timeout: 20_000 });
	await expect(head.getByTestId('repo-name')).toHaveText('github.com/example/zwei');
});

test('an open "add repository" form and its text survive a quiet refresh', async () => {
	const head = page.getByTestId('cc-sync-head');
	await head.getByTestId('repo-add').click();
	const field = head.getByTestId('repo-add-input');
	await field.fill('github.com/example/entwurf');
	expect((await page.request.put(`/v1/projects/${projectID}/sync`, { ...json, data: { repository: 'github.com/example/drei' } })).ok()).toBeTruthy();
	await expect(head.getByTestId('repo-row')).toHaveCount(2, { timeout: 20_000 });
	await expect(field, 'draft kept while the list refreshed').toHaveValue('github.com/example/entwurf');
});
