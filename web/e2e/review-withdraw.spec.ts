import { expect, request, test, type APIRequestContext, type Page } from '@playwright/test';
import { connect, mcp as mcpTool, type Connection } from './support/oauth';
import { signedInPage } from './support/session';

// Card 6515CAFA: an open review does not stay pending when its card is settled. A real agent connection (OAuth) requests the
// review through MCP; then (i) the person sets the card done in the PWA, (ii) the agent sets it done with update_task, (iii)
// the agent takes its own review back with withdraw_review. The card shows what happened and nothing waits for the person any
// more. Needs a fresh backend database:
//   npx playwright test e2e/review-withdraw.spec.ts --project=chromium   (also firefox and webkit)
// Pictures (light and dark) go to E2E_SHOT_DIR only when set.
test.describe.configure({ mode: 'serial' });
const json = { headers: { 'Content-Type': 'application/json' } };
let page: Page;
let mcpApi: APIRequestContext;
let agent: Connection;
let projectID = '';

async function post<T>(path: string, data: unknown): Promise<T> {
	const r = await page.request.post(path, { ...json, data });
	expect(r.status(), `${path}: ${await r.text()}`).toBeLessThan(300);
	return (await r.json()) as T;
}
const mcp = (tool: string, args: Record<string, unknown>) => mcpTool(mcpApi, agent.token, tool, args);
const dialog = () => page.getByTestId('card-dialog');
const result = () => dialog().getByTestId('card-review-result');

/** A task whose review the agent connection requested through MCP. */
async function reviewCard(title: string) {
	const task = await post<{ id: string }>('/v1/tasks', { projectID, title });
	await mcp('request_review', { taskID: task.id, summary: `${title}: bitte ansehen.`, agentName: 'Claude Code' });
	return task.id;
}
async function pendingReviewsOf(taskID: string) {
	const r = await page.request.get('/v1/reviews?state=pending');
	expect(r.status(), await r.text()).toBe(200);
	return ((await r.json()) as { taskID: string }[]).filter((x) => x.taskID.toLowerCase() === taskID.toLowerCase());
}
/** Opens "Für dich" (what waits for the person) and returns the review entries for `title`. */
async function waitingFor(title: string) {
	await page.goto('/for-you');
	await expect(page.getByTestId('for-you')).toBeVisible();
	// The list is loaded once either an entry or the empty state is there.
	await expect(page.getByTestId('needs-card').or(page.getByTestId('post-card')).first()).toBeVisible();
	return page.locator('[data-testid="needs-card"][data-kind="review"]').filter({ hasText: title });
}
async function expectWithdrawn(taskID: string, title: string, note: string, status: string, picture: string) {
	await page.goto(`/for-you?card=task:${taskID}`);
	await expect(dialog()).toBeVisible();
	await expect(result()).toContainText('Review zurückgezogen');
	await expect(result().getByTestId('review-note-shown')).toHaveText(note, { useInnerText: true });
	await expect(dialog().getByTestId('card-status')).toHaveText(status);
	await expect(dialog().getByTestId('review-accept')).toHaveCount(0);
	await expect(dialog().getByTestId('review-changes')).toHaveCount(0);
	await pictures(picture);
	expect(await pendingReviewsOf(taskID)).toEqual([]);
	await expect(await waitingFor(title)).toHaveCount(0);
}
async function pictures(name: string) {
	const dir = process.env.E2E_SHOT_DIR;
	if (!dir) return;
	for (const scheme of ['light', 'dark'] as const) {
		await page.emulateMedia({ colorScheme: scheme });
		await result().scrollIntoViewIfNeeded();
		await page.waitForTimeout(400);
		await page.screenshot({ path: `${dir}/${name}-${test.info().project.name}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });
	}
	await page.emulateMedia({ colorScheme: null });
}

test.beforeAll(async ({ browser }) => {
	page = await signedInPage(browser, 'Rückzug Tester');
	await page.setViewportSize({ width: 1280, height: 900 });
	mcpApi = await request.newContext({ baseURL: test.info().project.use.baseURL });
	projectID = (await post<{ id: string }>('/v1/projects', { name: 'Rückzugprojekt' })).id;
	await post(`/v1/projects/${projectID}/columns/template`, { source: 'agent_workflow' });
	agent = await connect(page, 'Agentenverbindung', [projectID]);
});
test.afterAll(async () => {
	await mcpApi?.dispose();
	await page?.context().close();
});

test('(i) the person sets a card with an open review done: the review is withdrawn', async () => {
	const title = 'Person erledigt';
	const taskID = await reviewCard(title);
	await expect(await waitingFor(title)).toHaveCount(1);
	await page.goto(`/for-you?card=task:${taskID}`);
	await expect(dialog().getByTestId('review-accept')).toBeVisible();
	await dialog().getByRole('checkbox', { name: 'Als erledigt markieren', exact: true }).click();
	await expect(result()).toContainText('Review zurückgezogen');
	await expectWithdrawn(taskID, title, 'Karte auf erledigt gesetzt', 'Erledigt', 'person-erledigt');
});

test('(ii) the agent sets its card done with update_task: the review is withdrawn', async () => {
	const title = 'Agent erledigt';
	const taskID = await reviewCard(title);
	const current = (await mcp('get_task', { id: taskID })) as { version: number };
	await mcp('update_task', { id: taskID, version: current.version, status: 'done' });
	await expectWithdrawn(taskID, title, 'Karte auf erledigt gesetzt', 'Erledigt', 'agent-erledigt');
});

test('(iii) the agent withdraws its own review with a note: the card is back in work', async () => {
	const title = 'Agent zieht zurück';
	const taskID = await reviewCard(title);
	await expect(await waitingFor(title)).toHaveCount(1);
	const note = 'Zu früh angefragt:\n- ein Test fehlt noch\n- neue Anfrage folgt';
	const review = await mcp('withdraw_review', { taskID, note });
	expect(review.state).toBe('withdrawn');
	await expectWithdrawn(taskID, title, note, 'In Arbeit', 'agent-zurueckgezogen');
});
