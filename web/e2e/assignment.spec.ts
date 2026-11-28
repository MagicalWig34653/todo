import { expect, test, type Browser, type Locator, type Page } from '@playwright/test';
import { signedInPage } from './support/session';

// Needs a fresh backend database (bootstrap happens here) with the server additions of card E9300901
// (assigneeName, feed concernsMe, summary concerning*). Run on its own:
//   npx playwright test e2e/assignment.spec.ts --project=chromium
// Three accounts: Anna (owner), Ben (role edit, not manage) and Rita (role read) share one project.
test.describe.configure({ mode: 'serial' });

const ANNA = 'Anna Eigentum';
const BEN = 'Ben Bearbeiter';
const json = { headers: { 'Content-Type': 'application/json' } };

let anna: Page;
let ben: Page;
let rita: Page;
let annaID = '';
let benID = '';
let projectID = '';
const task: Record<'card' | 'question' | 'annaReview' | 'benReview' | 'benReview2' | 'loose', string> = {
	card: '', question: '', annaReview: '', benReview: '', benReview2: '', loose: ''
};

async function call<T>(page: Page, method: 'post' | 'put' | 'get', url: string, data?: unknown): Promise<T> {
	const r = await page.request[method](url, method === 'get' ? undefined : { ...json, data: data ?? {} });
	expect(r.ok(), `${method} ${url}: ${r.status()} ${await r.text()}`).toBeTruthy();
	return (r.status() === 204 ? null : await r.json()) as T;
}
const assigneeOf = async (id: string) => (await call<{ task: { assigneeID?: string } }>(anna, 'get', `/v1/tasks/${id}/context`)).task.assigneeID ?? null;
const dialog = (p: Page) => p.getByTestId('card-dialog');
const requestReview = (id: string, reviewerID: string, name: string) => call(anna, 'post', `/v1/tasks/${id}/review`, { summary: `Ergebnis ${name} fertig.`, reviewerID });
const side = (p: Page) => dialog(p).getByTestId('side-assignee');
const openCard = (p: Page, id: string) => p.goto(`/project/${projectID}?card=task:${id}`);
const row = (p: Page, title: string) => p.getByTestId('task-item').filter({ hasText: title });
const boardCard = (p: Page, title: string) => p.getByTestId('board-card').filter({ hasText: title });
const forMe = (p: Page) => p.getByTestId('for-me');
const forMeCard = (p: Page, title: string) => forMe(p).getByTestId('for-me-card').filter({ hasText: title });

async function account(browser: Browser, name: string, token: string): Promise<{ page: Page; id: string }> {
	const page = await signedInPage(browser, name, token);
	await page.setViewportSize({ width: 1280, height: 860 });
	return { page, id: (await call<{ id: string }>(page, 'get', '/v1/me')).id };
}
async function view(p: Page, name: 'Liste' | 'Board') {
	await p.getByTestId('display-menu').click();
	await p.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name, exact: true }).click();
	await p.keyboard.press('Escape');
}
async function toggleMine(p: Page) {
	await p.getByTestId('display-menu').click();
	await p.getByRole('dialog', { name: 'Anzeige' }).getByRole('checkbox', { name: 'Meine' }).click();
	await p.keyboard.press('Escape');
}
async function handOver(scope: Locator, name: string) {
	await scope.getByRole('button', { name: 'Weitergeben', exact: true }).click();
	await scope.getByRole('combobox', { name: 'Weitergeben an' }).selectOption({ label: name });
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	anna = await signedInPage(browser, ANNA);
	await anna.setViewportSize({ width: 1280, height: 860 });
	annaID = (await call<{ id: string }>(anna, 'get', '/v1/me')).id;
	const invite = async () => (await call<{ token: string }>(anna, 'post', '/v1/invitations')).token;
	({ page: ben, id: benID } = await account(browser, BEN, await invite()));
	let ritaID = '';
	({ page: rita, id: ritaID } = await account(browser, 'Rita Leserin', await invite()));
	projectID = (await call<{ id: string }>(anna, 'post', '/v1/projects', { name: 'Gemeinsam' })).id;
	for (const [principalID, role] of [[benID, 'edit'], [ritaID, 'read']] as const) {
		await call(anna, 'put', `/v1/projects/${projectID}/grants`, { principalType: 'person', principalID, role });
	}
	const create = async (title: string) => (await call<{ id: string }>(anna, 'post', '/v1/tasks', { projectID, title })).id;
	task.card = await create('Karte zuweisen');
	task.question = await create('Frage weitergeben');
	task.annaReview = await create('Review von Anna');
	task.benReview = await create('Review von Ben');
	task.benReview2 = await create('Zweites Review von Ben');
	task.loose = await create('Ohne Zustaendigkeit');
	await call(anna, 'post', `/v1/tasks/${task.question}/questions`, { prompt: 'Blau oder Gruen?', options: ['Blau', 'Gruen'] });
	await requestReview(task.annaReview, annaID, 'Anna');
});
test.afterAll(async () => {
	for (const p of [anna, ben, rita]) await p?.context().close();
});

test('"Für mich" is empty with a plain sentence when nothing concerns the account', async () => {
	await ben.goto('/for-you');
	// Nothing is assigned to Ben yet: "Alle" is preselected, "Für mich" says so.
	await expect(ben.getByTestId('for-you-all')).toHaveAttribute('aria-pressed', 'true');
	await expect(ben.getByTestId('needs-card').filter({ hasText: 'Blau oder Gruen?' })).toBeVisible();
	await ben.getByTestId('for-you-mine').click();
	await expect(forMe(ben)).toContainText('Nichts wartet auf dich');
});

test('card window: Anna makes Ben responsible; the draft assigns after creating', async () => {
	await openCard(anna, task.card);
	const field = side(anna).getByRole('combobox', { name: 'Zuständig' });
	await expect(field).toHaveValue('');
	await expect(field.locator('option:checked')).toHaveText('Niemand');
	await field.selectOption({ label: BEN });
	await expect.poll(() => assigneeOf(task.card)).toBe(benID);
	// Removing and setting again keeps working (the card version moved on).
	await field.selectOption({ label: 'Niemand' });
	await expect.poll(() => assigneeOf(task.card)).toBe(null);
	await field.selectOption({ label: BEN });
	await expect.poll(() => assigneeOf(task.card)).toBe(benID);

	await anna.goto(`/project/${projectID}`);
	await anna.getByTestId('create-task-open').click();
	const draft = anna.getByTestId('card-draft');
	await draft.getByLabel('Titel', { exact: true }).fill('Entwurf mit Zuständigkeit');
	await draft.getByRole('combobox', { name: 'Zuständig' }).selectOption({ label: BEN });
	await draft.getByRole('button', { name: 'Anlegen' }).click();
	await expect(anna).toHaveURL(/card=task:/);
	const id = new URL(anna.url()).searchParams.get('card')!.split(':')[1]!;
	await expect.poll(() => assigneeOf(id)).toBe(benID);
	await expect(side(anna).getByRole('combobox', { name: 'Zuständig' }).locator('option:checked')).toHaveText(BEN);
});

test('"Für mich" shows the assigned cards to Ben only', async () => {
	await ben.goto('/for-you');
	await expect(ben.getByTestId('for-you-mine')).toHaveAttribute('aria-pressed', 'true');
	await expect(forMeCard(ben, 'Karte zuweisen')).toBeVisible();
	await expect(forMeCard(ben, 'Entwurf mit Zuständigkeit')).toBeVisible();
	await expect(forMe(ben)).not.toContainText('Ohne Zustaendigkeit');
	// "Alle" stays as before: the open question, not the plain cards.
	await ben.getByTestId('for-you-all').click();
	await expect(ben.getByTestId('needs-card').filter({ hasText: 'Blau oder Gruen?' })).toBeVisible();
	await expect(forMe(ben)).toHaveCount(0);

	await anna.goto('/for-you');
	await expect(anna.getByTestId('for-you-mine')).toBeVisible();
	await expect(forMeCard(anna, 'Review von Anna')).toBeVisible();
	await expect(forMe(anna)).not.toContainText('Karte zuweisen');
	await expect(forMe(anna)).not.toContainText('Entwurf mit Zuständigkeit');
});

test('list and board mark responsibility and filter "Meine"', async () => {
	await ben.goto(`/project/${projectID}`);
	await view(ben, 'Liste');
	await expect(row(ben, 'Karte zuweisen').getByRole('img', { name: `Zuständig: ${BEN}` })).toBeVisible();
	await expect(row(ben, 'Ohne Zustaendigkeit').getByTestId('assignee-chip')).toHaveCount(0);
	await toggleMine(ben);
	await expect(row(ben, 'Karte zuweisen')).toBeVisible();
	await expect(row(ben, 'Ohne Zustaendigkeit')).toHaveCount(0);
	await view(ben, 'Board');
	await expect(boardCard(ben, 'Karte zuweisen').getByRole('img', { name: `Zuständig: ${BEN}` })).toBeVisible();
	await expect(boardCard(ben, 'Ohne Zustaendigkeit')).toHaveCount(0);
	await toggleMine(ben);
	await expect(boardCard(ben, 'Ohne Zustaendigkeit')).toBeVisible();
	await view(ben, 'Liste');

	// Anna has nothing assigned to herself among the cards.
	await anna.goto(`/project/${projectID}`);
	await view(anna, 'Liste');
	await toggleMine(anna);
	await expect(row(anna, 'Karte zuweisen')).toHaveCount(0);
	await toggleMine(anna);
	await expect(row(anna, 'Karte zuweisen')).toBeVisible();
});

test('a reader sees the name in the card window, but cannot change it', async () => {
	await openCard(rita, task.card);
	await expect(side(rita)).toContainText(BEN);
	await expect(side(rita).getByRole('combobox')).toHaveCount(0);
	await rita.goto(`/project/${projectID}`);
	// Without the list of people a reader sees a neutral mark.
	await expect(row(rita, 'Karte zuweisen').getByRole('img', { name: 'Zugewiesen' })).toBeVisible();
});

test('Anna hands the question to Ben, who finds it under "Für mich" and answers', async () => {
	await openCard(anna, task.question);
	const handover = dialog(anna).getByTestId('handover').first();
	await handOver(handover, BEN);
	await expect(handover).toContainText(`Für ${BEN}`);

	await ben.goto('/for-you');
	const card = forMeCard(ben, 'Blau oder Gruen?');
	await expect(card).toContainText(`Für ${BEN}`);
	await card.getByTestId('question-option').filter({ hasText: 'Blau' }).click();
	await expect(card).toHaveCount(0);
	const ctx = await call<{ questions: { state: string; answer?: string }[] }>(anna, 'get', `/v1/tasks/${task.question}/context`);
	expect(ctx.questions[0]).toMatchObject({ state: 'answered', answer: 'Blau' });
});

test('a review named for Anna: Ben sees who decides, no decision and no handover', async () => {
	await requestReview(task.benReview, benID, 'Ben');
	await requestReview(task.benReview2, benID, 'Ben');
	await openCard(ben, task.annaReview);
	const review = dialog(ben).getByTestId('review');
	await expect(review).toContainText(`Entscheidet: ${ANNA}`);
	await expect(review.getByTestId('review-accept')).toHaveCount(0);
	await expect(review.getByTestId('review-changes')).toHaveCount(0);
	await expect(review.getByRole('button', { name: 'Weitergeben' })).toHaveCount(0);

	await ben.goto('/for-you');
	await ben.getByTestId('for-you-all').click();
	const need = ben.getByTestId('needs-card').filter({ hasText: 'Review von Anna' });
	await expect(need).toContainText(`Entscheidet: ${ANNA}`);
	await expect(need.getByRole('button', { name: 'Annehmen', exact: true })).toHaveCount(0);
	await expect(need.getByRole('button', { name: 'Weitergeben' })).toHaveCount(0);

	// Overview, including the bulk selection.
	await ben.goto(`/project/${projectID}`);
	await ben.getByTestId('display-menu').click();
	await ben.getByTestId('mode-management').click();
	await ben.keyboard.press('Escape');
	await ben.getByTestId('project-tab-overview').click();
	await ben.getByTestId('cc-section-reviews').click();
	const item = ben.getByTestId('review-row').filter({ hasText: 'Review von Anna' });
	await expect(item).toContainText(`Entscheidet: ${ANNA}`);
	await expect(item.getByTestId('review-accept')).toHaveCount(0);
	await expect(item.getByTestId('review-select')).toBeDisabled();
	await ben.getByTestId('review-select-all').check();
	await expect(ben.getByTestId('review-bulk-count')).toContainText('2');
	await ben.getByTestId('display-menu').click();
	await ben.getByTestId('mode-classic').click();
	await ben.keyboard.press('Escape');
});

test('the owner (manage) still decides a review named for someone else', async () => {
	await openCard(anna, task.benReview);
	const review = dialog(anna).getByTestId('review');
	await expect(review).toContainText(`Für ${BEN}`);
	await expect(review.getByTestId('review-accept')).toBeVisible();
	await expect(review.getByRole('button', { name: 'Weitergeben' })).toBeVisible();
});

test('Ben decides one of his reviews and hands the other one over', async () => {
	await ben.goto('/for-you');
	const decide = forMeCard(ben, 'Review von Ben').filter({ hasNotText: 'Zweites' });
	await decide.getByTestId('review-accept').click();
	await expect(decide).toHaveCount(0);

	const second = forMeCard(ben, 'Zweites Review von Ben');
	await handOver(second, ANNA);
	await expect(second).toHaveCount(0);
	const ctx = await call<{ review: { reviewerID?: string } }>(anna, 'get', `/v1/tasks/${task.benReview2}/context`);
	expect(ctx.review.reviewerID).toBe(annaID);
	await openCard(ben, task.benReview2);
	await expect(dialog(ben).getByTestId('review')).toContainText(`Entscheidet: ${ANNA}`);
});

test('the navigation counter follows what concerns the account', async () => {
	const summary = (await call<{ summary: Record<string, number> }>(ben, 'get', '/v1/command-center?scope=account&view=list&limit=1&updatesLimit=1')).summary;
	// Both remaining reviews are named for Anna: they do not concern Ben.
	expect(summary.pendingReviews).toBe(2);
	expect(summary.concerningReviews).toBe(0);
	await ben.goto('/for-you');
	await expect(ben.getByTestId('for-you-all')).toBeVisible();
	await expect(ben.getByRole('navigation', { name: 'Seitenleiste' }).getByTestId('nav-count-forYou')).toHaveCount(0);
	await anna.goto('/for-you');
	await expect(anna.getByRole('navigation', { name: 'Seitenleiste' }).getByTestId('nav-count-forYou')).toHaveText('2');
});

test('notification settings: one switch "Zuweisungen" that is stored', async () => {
	await ben.goto('/settings/notifications');
	const box = ben.getByRole('checkbox', { name: 'Zuweisungen' });
	await expect(box).toHaveCount(1);
	const was = await box.isChecked();
	await box.click();
	await expect.poll(async () => (await call<{ categories: { assignments: boolean } }>(ben, 'get', '/v1/me/push-prefs')).categories.assignments).toBe(!was);
});

test('phone: segments and handover fit without horizontal scrolling', async () => {
	await anna.setViewportSize({ width: 390, height: 844 });
	await anna.goto('/for-you');
	await expect(anna.getByTestId('for-you-mine')).toBeVisible();
	expect(await anna.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
	await openCard(anna, task.annaReview);
	await expect(side(anna)).toBeVisible();
	expect(await anna.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
	await anna.setViewportSize({ width: 1280, height: 860 });
});
