import { expect, test, type Page } from '@playwright/test';
import { openViaMore } from './support/sidebarStep';
import { signedInPage } from './support/session';

// Card 188D611F: the failure message of the sidebar step must carry the state of the page, and nothing personal.
// Needs a fresh backend database. Run on its own:  npx playwright test e2e/sidebar-diagnostics.spec.ts --project=chromium   (also firefox, webkit)
test.describe.configure({ mode: 'serial' });
let page: Page;

test('openViaMore opens "Teams" behind "Mehr" and clicks it', async ({ browser }) => {
	test.setTimeout(90_000);
	page = await signedInPage(browser, 'Geheimer Name Diagnose');
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	await openViaMore(page, page.getByRole('button', { name: 'Mehr', exact: true }), page.getByRole('button', { name: 'Teams', exact: true }));
	await expect(page).toHaveURL(/\/teams$/);
});

test('a failing step names attempts and page state, without texts or ids', async () => {
	await page.setViewportSize({ width: 1280, height: 800 });
	await page.goto('/');
	const error = await openViaMore(page, page.getByRole('button', { name: 'Mehr', exact: true }), page.getByRole('button', { name: 'Gibt es nicht', exact: true }), { timeout: 4000, attemptTimeout: 600 }).then(
		() => '',
		(e: Error) => e.message
	);
	expect(error).toContain('sidebar step failed');
	// Every attempt carries all fields (values vary with the load state: the first attempt may see no sidebar yet).
	const fields = ['path', 'viewport', 'moreCount', 'moreExpanded', 'moreEnabled', 'targetCount', 'targetVisible', 'navs', 'openDialogs', 'busy', 'readyState'];
	const attempts = error.split('\n').filter((l) => /^#\d+ \+\d+ms before: /.test(l));
	expect(attempts.length).toBeGreaterThanOrEqual(2);
	for (const line of attempts) for (const f of fields) expect(line, `field ${f}`).toContain(` ${f}=`);
	expect(error).toContain('targetCount=0 targetVisible=false');
	expect(error).toContain('after: ');
	expect(error, 'no display name').not.toContain('Geheimer');
	expect(error, 'no id').not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}/i);
});
