import { expect, test, type Locator, type Page } from '@playwright/test';

const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

// Serial tests share one page, so the passkey created in the first test is available to the later ones.
test.describe.configure({ mode: 'serial' });
let page: Page;

/** Sidebar entry by name; entries under "Mehr" open that group first. Counts are part of the accessible name. */
async function closeDialogs() {
	while (await page.locator('[aria-modal="true"]').first().isVisible()) await page.keyboard.press('Escape');
}
async function nav(name: string) {
	await closeDialogs();
	const rx = new RegExp(`^${name}( \\d+)?$`);
	const btn = page.getByRole('button', { name: rx });
	if (!(await btn.first().isVisible())) await page.getByRole('button', { name: 'Mehr', exact: true }).click();
	await btn.first().click();
}
const accountMenu = () => page.getByTestId('account-menu');
async function logout(p: Page = page) {
	await p.getByTestId('account-menu').click();
	await p.getByRole('button', { name: 'Abmelden' }).click();
}
async function setView(view: 'Liste' | 'Board') {
	await closeDialogs();
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: view }).click();
	await page.keyboard.press('Escape');
}
/** HTML5 drag and drop with real mouse events: press on the card, move in steps, release on the target. */
async function dragCard(source: Locator, target: Locator) {
	await source.scrollIntoViewIfNeeded();
	const a = (await source.boundingBox())!;
	const b = (await target.boundingBox())!;
	await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
	await page.mouse.down();
	await page.mouse.move(a.x + a.width / 2 + 10, a.y + a.height / 2 + 10, { steps: 3 });
	await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 12 });
	await page.mouse.up();
}
async function openShare() {
	await page.getByTestId('share-open').click();
	await expect(page.getByTestId('share-dialog')).toBeVisible();
}

test.beforeAll(async ({ browser }) => {
	page = await (await browser.newContext()).newPage();
});
test.afterAll(async () => {
	await page.context().close();
});

test('bootstrap registration, logout, passkey login, project tree and task', async () => {
	// Virtual authenticator with resident key + user verification so login needs no user gesture.
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: {
			protocol: 'ctap2',
			transport: 'internal',
			hasResidentKey: true,
			hasUserVerification: true,
			isUserVerified: true,
			automaticPresenceSimulation: true
		}
	});

	// First setup with the bootstrap token.
	await page.goto('/setup');
	await page.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await page.getByLabel('Anzeigename').fill('Test Admin');
	await page.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(accountMenu()).toBeVisible();

	// Logout returns to the login view.
	await logout();
	await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();

	// Password login must not be offered when the server does not allow it.
	await expect(page.getByRole('button', { name: 'Andere Anmeldemethode' })).toHaveCount(0);

	// Passkey login, also after a reload (cookie session survives).
	await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
	await expect(accountMenu()).toBeVisible();
	await page.reload();
	await expect(accountMenu()).toBeVisible();

	// Project, sub-project, task.
	await page.getByTestId('add-project').click();
	await page.getByLabel('Neues Projekt').fill('Haushalt');
	await page.getByRole('button', { name: 'Projekt anlegen' }).click();
	const root = page.getByTestId('project-item').filter({ hasText: 'Haushalt' }).first();
	await expect(root).toBeVisible();

	await root.hover();
	await root.getByRole('button', { name: 'Projektmenü: Haushalt' }).click();
	await page.getByRole('button', { name: 'Unterprojekt' }).click();
	await root.getByLabel('Name des Unterprojekts').fill('Küche');
	await root.getByRole('button', { name: 'Speichern' }).click();
	const sub = page.getByTestId('project-item').filter({ hasText: 'Küche' }).last();
	await expect(sub).toBeVisible();

	await sub.getByRole('button', { name: 'Küche', exact: true }).click();
	await expect(page.getByTestId('task-heading')).toHaveText('Küche');
	await page.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill('Spülmaschine ausräumen');
	await page.keyboard.press('Enter');
	const task = page.getByTestId('task-item').filter({ hasText: 'Spülmaschine ausräumen' });
	await expect(task).toBeVisible();

	// Tick off and reload: state is persisted by the backend.
	await task.getByRole('checkbox').check();
	await page.reload();
	await page.getByRole('button', { name: 'Küche', exact: true }).click();
	await expect(page.getByTestId('task-item').getByRole('checkbox')).toBeChecked();
});

const PNG_1X1 = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
	'base64'
);

function localToday(hour: number) {
	const d = new Date();
	const p = (n: number) => String(n).padStart(2, '0');
	return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(hour)}:00`;
}

async function openProject(name: string) {
	await closeDialogs();
	await page.getByTestId('project-item').getByRole('button', { name, exact: true }).first().click();
	await expect(page.getByTestId('task-heading')).toHaveText(name);
}

test('labels, planning, detail sections and views', async () => {
	await openProject('Küche');
	for (const title of ['Einkaufen', 'Putzen']) {
		await page.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill(title);
		await page.keyboard.press('Enter');
		await expect(page.getByTestId('task-item').filter({ hasText: title })).toBeVisible();
	}

	// Create a label in the search view.
	await nav('Suche');
	await page.getByLabel('Neues Label').fill('dringend');
	await page.getByRole('button', { name: 'Label anlegen' }).click();
	await expect(page.getByTestId('label-item').filter({ hasText: 'dringend' })).toBeVisible();

	// Task details: planning, label, criterion, comment, activity.
	await openProject('Küche');
	const task = page.getByTestId('task-item').filter({ hasText: 'Einkaufen' });
	await task.getByRole('button', { name: 'Details' }).click();
	const detail = task.getByTestId('task-detail');
	await detail.getByLabel('Fällig').fill(localToday(23));
	await detail.getByLabel('Priorität').selectOption('3');
	const [saved] = await Promise.all([
		page.waitForResponse((r) => r.url().includes('/v1/planning/tasks/') && r.request().method() === 'PUT'),
		detail.getByRole('button', { name: 'Planung speichern' }).click()
	]);
	expect(saved.status(), await saved.text()).toBe(200);
	await detail.getByLabel('Label hinzufügen').selectOption({ label: 'dringend' });
	await expect(detail.getByTestId('task-label')).toContainText('dringend');

	await detail.getByLabel('Neues Kriterium').fill('Milch im Kühlschrank');
	await detail.getByRole('button', { name: 'Kriterium hinzufügen' }).click();
	await detail.getByRole('checkbox', { name: 'Milch im Kühlschrank' }).check();
	await expect(detail.getByTestId('criteria-progress')).toHaveText('1 von 1 erfüllt');

	await detail.getByLabel('Kommentar schreiben').fill('Bitte Bio-Milch');
	await detail.getByRole('button', { name: 'Kommentieren' }).click();
	await expect(detail.getByTestId('comment')).toContainText('Bio-Milch');
	await expect(detail.getByTestId('activity').filter({ hasText: 'Kommentar hinzugefügt' })).toHaveCount(1);

	// Persisted: reload and see criterion + planning again.
	await page.reload();
	await openProject('Küche');
	const again = page.getByTestId('task-item').filter({ hasText: 'Einkaufen' });
	await again.getByRole('button', { name: 'Details' }).click();
	await expect(again.getByLabel('Priorität')).toHaveValue('3');
	await expect(again.getByTestId('criteria-progress')).toHaveText('1 von 1 erfüllt');

	// Today view lists the task due today with priority chip.
	await nav('Heute');
	const todayItem = page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' });
	await expect(todayItem).toBeVisible();
	await expect(todayItem.getByTestId('chip-priority')).toHaveText('Hoch');
	await nav('Als Nächstes');
	await expect(page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' })).toBeVisible();
	await nav('Anstehend');
	await expect(page.getByTestId('view-heading')).toHaveText('Anstehend');
	await expect(page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' })).toHaveCount(0);
});

test('board: status mode, columns, tasks, drag and menu moves, delete column', async () => {
	await page.setViewportSize({ width: 1700, height: 900 });
	await openProject('Küche');
	await setView('Board');
	// Without own columns the board shows read-only status columns and a hint.
	await expect(page.getByTestId('board')).toHaveAttribute('data-mode', 'status');
	await expect(page.getByTestId('board-status-hint')).toBeVisible();
	await expect(page.getByTestId('board-lane').filter({ hasText: 'Offen' }).getByTestId('board-card')).toHaveCount(2);
	await expect(page.getByTestId('board-card').first().locator('xpath=ancestor::*[@draggable="true"]')).toHaveCount(0);

	// Create real columns.
	await page.getByTestId('template-status').click();
	await expect(page.getByTestId('board')).toHaveAttribute('data-mode', 'columns');
	const lane = (name: string) => page.getByTestId('board-lane').filter({ has: page.getByRole('heading', { name, exact: true }) });
	await expect(lane('Offen').getByTestId('board-card')).toHaveCount(2);
	await page.getByTestId('add-column').click();
	await page.getByLabel('Name der Spalte').fill('Ideen');
	await page.getByRole('button', { name: 'Spalte anlegen' }).click();
	await expect(lane('Ideen')).toBeVisible();

	// Add a task directly into a column.
	await lane('Ideen').getByLabel('Aufgabe hinzufügen in Ideen').fill('Hochbeet planen');
	await page.keyboard.press('Enter');
	await expect(lane('Ideen').getByTestId('board-card')).toContainText('Hochbeet planen');

	// Move by menu ("Verschieben nach") and persist across reload.
	const putCol = () => page.waitForResponse((r) => r.url().includes('/column') && r.request().method() === 'PUT');
	await lane('Offen').getByTestId('board-card').filter({ hasText: 'Putzen' }).getByRole('button', { name: /Aufgabenmenü/ }).click();
	let moved = putCol();
	await page.getByRole('button', { name: 'In Arbeit', exact: true }).click();
	expect((await moved).status()).toBe(200);
	await expect(lane('In Arbeit').getByTestId('board-card')).toContainText('Putzen');

	await page.getByTestId('board').evaluate((e) => (e.scrollLeft = 0));
	// Drag and drop a card to another column (HTML5 DnD).
	moved = putCol();
	await dragCard(lane('Offen').getByTestId('board-card').filter({ hasText: 'Einkaufen' }), lane('Ideen').getByTestId('board-card').first());
	expect((await moved).status()).toBe(200);
	await expect(lane('Ideen').getByTestId('board-card').filter({ hasText: 'Einkaufen' })).toBeVisible();

	// Move into the done column marks the task done.
	await lane('In Arbeit').getByTestId('board-card').filter({ hasText: 'Putzen' }).getByRole('button', { name: /Aufgabenmenü/ }).click();
	moved = putCol();
	await page.getByRole('button', { name: 'Erledigt', exact: true }).click();
	await moved;
	await expect(lane('Erledigt').getByTestId('board-card-check').first()).toHaveAttribute('aria-pressed', 'true');

	// Reopen it again by moving it out of the done column.
	await lane('Erledigt').getByTestId('board-card').filter({ hasText: 'Putzen' }).getByRole('button', { name: /Aufgabenmenü/ }).click();
	moved = putCol();
	await page.getByRole('button', { name: 'Offen', exact: true }).click();
	await moved;
	await expect(lane('Offen').getByTestId('board-card').filter({ hasText: 'Putzen' }).getByTestId('board-card-check')).toHaveAttribute('aria-pressed', 'false');

	// Reorder a column via its menu.
	await lane('Ideen').getByRole('button', { name: 'Spaltenmenü: Ideen' }).click();
	await page.getByRole('button', { name: 'Nach links' }).click();
	await expect(page.getByTestId('lane-title')).toHaveText(['Offen', 'In Arbeit', 'Ideen', 'Erledigt']);

	// Persisted.
	await page.reload();
	await openProject('Küche');
	await expect(page.getByTestId('board')).toHaveAttribute('data-mode', 'columns');
	await expect(page.getByTestId('lane-title')).toHaveText(['Offen', 'In Arbeit', 'Ideen', 'Erledigt']);
	await expect(lane('Ideen').getByTestId('board-card')).toHaveCount(2);

	// Rename and colour.
	await lane('Ideen').getByRole('button', { name: 'Spaltenmenü: Ideen' }).click();
	await page.getByRole('button', { name: 'Umbenennen' }).click();
	await page.getByLabel('Spaltenname').fill('Ideenspeicher');
	await page.keyboard.press('Enter');
	await expect(lane('Ideenspeicher')).toBeVisible();
	await lane('Ideenspeicher').getByRole('button', { name: 'Spaltenmenü: Ideenspeicher' }).click();
	await page.getByRole('button', { name: 'Farbe #2470E0' }).click();
	await expect(lane('Ideenspeicher').locator('span[style*="background"]').first()).toBeVisible();

	// Delete a column: its tasks move to the chosen column.
	await lane('Ideenspeicher').getByRole('button', { name: 'Spaltenmenü: Ideenspeicher' }).click();
	await page.getByRole('button', { name: 'Spalte löschen' }).click();
	await page.getByLabel('Aufgaben verschieben nach').selectOption({ label: 'Offen' });
	await page.getByTestId('delete-column-dialog').getByRole('button', { name: 'Löschen' }).click();
	await expect(page.getByTestId('lane-title').filter({ hasText: 'Ideenspeicher' })).toHaveCount(0);
	await expect(lane('Offen').getByTestId('board-card').filter({ hasText: 'Hochbeet planen' })).toBeVisible();
	await setView('Liste');
	await page.setViewportSize({ width: 1280, height: 720 });
});

test('sidebar: favorites, counts, quick add shortcut, notifications', async () => {
	await nav('Heute');
	await page.keyboard.press('q');
	await expect(page.getByTestId('quick-add')).toBeVisible();
	await page.getByLabel('Titel', { exact: true }).fill('Per Kürzel angelegt');
	await page.getByRole('button', { name: 'Aufgabe hinzufügen', exact: true }).last().click();
	await expect(page.getByTestId('quick-add')).toHaveCount(0);
	await nav('Eingang');
	await expect(page.getByTestId('inbox-item').filter({ hasText: 'Per Kürzel angelegt' })).toBeVisible();

	// Favorite (stored on the server per account) shows up in the Favoriten section.
	const item = page.getByTestId('project-item').filter({ hasText: 'Küche' }).first();
	await item.hover();
	await item.getByRole('button', { name: 'Projektmenü: Küche' }).click();
	await page.getByRole('button', { name: 'Zu Favoriten hinzufügen' }).click();
	await expect(page.getByTestId('favorites')).toContainText('Küche');
	await expect(page.getByTestId('project-count').first()).toBeVisible();

	await page.getByTestId('notifications').click();
	await expect(page.getByRole('dialog', { name: 'Benachrichtigungen' })).toContainText('Keine offenen Einladungen');
	await page.keyboard.press('Escape');
});

test('search and saved filter', async () => {
	// Search + saved filter.
	await nav('Suche');
	await page.getByLabel('Suchen in Titeln, Beschreibungen und Projekten').fill('putz');
	await page.getByRole('button', { name: 'Suchen', exact: true }).click();
	await expect(page.getByTestId('search-hit').filter({ hasText: 'Putzen' })).toBeVisible();
	await page.getByLabel('Name des Filters').fill('Putzliste');
	await page.getByRole('button', { name: 'Als Filter speichern' }).click();
	await expect(page.getByTestId('saved-filter')).toContainText('Putzliste');
	await page.getByLabel('Suchen in Titeln, Beschreibungen und Projekten').fill('');
	await page.getByRole('button', { name: 'Filter Putzliste anwenden' }).click();
	await expect(page.getByTestId('search-hit').filter({ hasText: 'Putzen' })).toBeVisible();
	await expect(page.getByTestId('search-hit').filter({ hasText: 'Einkaufen' })).toHaveCount(0);
});

test('teams, sharing and visibility', async () => {
	await nav('Teams');
	await page.getByLabel('Neues Team').fill('Familie');
	await page.getByRole('button', { name: 'Team anlegen' }).click();
	await expect(page.getByTestId('team-item')).toContainText('Familie');
	await expect(page.getByTestId('team-member')).toHaveCount(1);
	await expect(page.getByTestId('team-member')).toContainText('Teamadministration');

	await openProject('Haushalt');
	await openShare();
	await expect(page.getByTestId('my-role')).toHaveText('Verwalten');
	await page.getByLabel('Empfänger').selectOption('team');
	await page.getByLabel('Team', { exact: true }).selectOption({ label: 'Familie' });
	await page.getByRole('button', { name: 'Freigabe hinzufügen' }).click();
	await expect(page.getByTestId('grant')).toContainText('Familie');
	await page.getByTestId('grant').getByRole('button', { name: 'Entziehen' }).click();
	await expect(page.getByTestId('grant')).toHaveCount(0);
});

test('recurrence, reminders, dependencies, milestones and filter changes', async () => {
	await openProject('Küche');
	await setView('Liste');
	const task = page.getByTestId('task-item').filter({ hasText: 'Putzen' });
	// The form adopts the stored planning when it arrives; selecting before that would be overwritten.
	const planningLoaded = page.waitForResponse((r) => r.url().includes('/v1/planning/tasks/') && r.request().method() === 'GET');
	await task.getByRole('button', { name: 'Details' }).click();
	await planningLoaded;
	const detail = task.getByTestId('task-detail');

	// A recurrence needs a date: refused before any request.
	await detail.getByLabel('Häufigkeit der Wiederholung').selectOption('weekly');
	await detail.getByRole('button', { name: 'Planung speichern' }).click();
	await expect(detail.getByTestId('recurrence-error')).toBeVisible();

	await detail.getByLabel('Fällig').fill(localToday(22));
	await detail.getByLabel('Alle … Wochen').fill('2');
	await detail.getByLabel('Neue Erinnerung').fill(localToday(21));
	await detail.getByRole('button', { name: 'Erinnerung hinzufügen' }).click();
	await expect(detail.getByTestId('reminder')).toHaveCount(1);
	const [saved] = await Promise.all([
		page.waitForResponse((r) => r.url().includes('/v1/planning/tasks/') && r.request().method() === 'PUT'),
		detail.getByRole('button', { name: 'Planung speichern' }).click()
	]);
	expect(saved.status(), await saved.text()).toBe(200);
	// The list shows the compact planning summary delivered with the task list.
	await expect(task.getByTestId('task-chips')).toContainText('Wiederholt sich');
	await expect(task.getByTestId('task-chips')).toContainText('Erinnerungen: 1');

	await page.reload();
	await openProject('Küche');
	const again = page.getByTestId('task-item').filter({ hasText: 'Putzen' });
	await again.getByRole('button', { name: 'Details' }).click();
	await expect(again.getByLabel('Häufigkeit der Wiederholung')).toHaveValue('weekly');
	await expect(again.getByLabel('Alle … Wochen')).toHaveValue('2');
	await expect(again.getByTestId('reminder')).toHaveCount(1);

	// Dependencies: Putzen needs Einkaufen; the reverse direction would be a cycle.
	await again.getByLabel('Voraussetzung wählen').selectOption({ label: 'Einkaufen' });
	await again.getByRole('button', { name: 'Voraussetzung hinzufügen' }).click();
	await expect(again.getByTestId('dependency')).toContainText('Einkaufen');
	await again.getByRole('button', { name: 'Details' }).click();
	const shop = page.getByTestId('task-item').filter({ hasText: 'Einkaufen' });
	await shop.getByRole('button', { name: 'Details' }).click();
	await shop.getByLabel('Voraussetzung wählen').selectOption({ label: 'Putzen' });
	await shop.getByRole('button', { name: 'Voraussetzung hinzufügen' }).click();
	await expect(page.getByTestId('notice')).toContainText('Kreis');
	await expect(shop.getByTestId('dependency')).toHaveCount(0);

	// Milestone with a task and progress.
	await page.getByTestId('project-more').click();
	await page.getByTestId('milestones-open').click();
	await page.getByLabel('Neuer Meilenstein').fill('Frühjahrsputz');
	await page.getByRole('button', { name: 'Meilenstein anlegen' }).click();
	const ms = page.getByTestId('milestone').filter({ hasText: 'Frühjahrsputz' });
	await expect(ms).toBeVisible();
	await ms.getByLabel('Aufgabe zuordnen').selectOption({ label: 'Putzen' });
	await ms.getByRole('button', { name: 'Zuordnen' }).click();
	await expect(ms.getByTestId('milestone-task')).toContainText('Putzen');
	await expect(ms.getByTestId('milestone-progress')).toHaveText('0 von 1 erledigt');

	// Saved filter: rename, then overwrite with the current search.
	await nav('Suche');
	await page.getByRole('button', { name: 'Filter Putzliste umbenennen' }).click();
	await page.getByLabel('Filter Putzliste umbenennen').fill('Putzplan');
	await page.getByTestId('saved-filter').getByRole('button', { name: 'Speichern' }).click();
	await expect(page.getByTestId('saved-filter')).toContainText('Putzplan');
	await page.getByLabel('Suchen in Titeln, Beschreibungen und Projekten').fill('Einkauf');
	await page.getByRole('button', { name: 'Filter Putzplan mit der aktuellen Suche überschreiben' }).click();
	await page.getByLabel('Suchen in Titeln, Beschreibungen und Projekten').fill('');
	await page.getByRole('button', { name: 'Filter Putzplan anwenden' }).click();
	await expect(page.getByTestId('search-hit').filter({ hasText: 'Einkaufen' })).toBeVisible();
	await expect(page.getByTestId('search-hit').filter({ hasText: 'Putzen' })).toHaveCount(0);
});

test('invited person: directory search, team invitation name, author and actor names', async () => {
	const invitation = await page.request.post('/v1/invitations', {
		data: {},
		headers: { 'Content-Type': 'application/json' }
	});
	expect(invitation.ok(), await invitation.text()).toBeTruthy();
	const { token } = (await invitation.json()) as { token: string };

	const guestCtx = await page.context().browser()!.newContext();
	try {
		const guest = await guestCtx.newPage();
		const cdp = await guestCtx.newCDPSession(guest);
		await cdp.send('WebAuthn.enable');
		await cdp.send('WebAuthn.addVirtualAuthenticator', {
			options: {
				protocol: 'ctap2',
				transport: 'internal',
				hasResidentKey: true,
				hasUserVerification: true,
				isUserVerified: true,
				automaticPresenceSimulation: true
			}
		});
		await guest.goto(`/setup?token=${token}`);
		await guest.getByLabel('Anzeigename').fill('Berta Beispiel');
		await guest.getByRole('button', { name: 'Passkey erstellen' }).click();
		await expect(guest.getByTestId('account-menu')).toBeVisible();

		const guestID = ((await (await guest.request.get('/v1/me')).json()) as { id: string }).id;

		// First contact: there is no global directory, so the search finds nobody and the account ID is used.
		await nav('Teams');
		await page.getByTestId('team-item').filter({ hasText: 'Familie' }).click();
		await page.getByLabel('Person suchen (Name)').fill('Bert');
		await expect(page.getByText('Niemand gefunden.')).toBeVisible();
		await page.getByLabel('Konto-ID der Person').fill(guestID);
		await page.getByRole('button', { name: 'Einladen' }).click();
		const row = page.getByTestId('team-member').filter({ hasText: 'Berta Beispiel' });
		await expect(row).toContainText('Einladung offen');

		// The invitee sees the team name, not just an ID.
		await guest.getByRole('button', { name: 'Mehr', exact: true }).click().then(() => guest.getByRole('button', { name: 'Teams', exact: true }).click());
		await expect(guest.getByTestId('team-invitation')).toContainText('Einladung zum Team Familie');

		// Now a relation exists: she is found by name and can be shared a project with.
		await openProject('Haushalt');
		await setView('Liste');
		await page.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill('Wochenplan');
		await page.keyboard.press('Enter');
		await expect(page.getByTestId('task-item').filter({ hasText: 'Wochenplan' })).toBeVisible();
		await openShare();
		await page.getByLabel('Person suchen (Name)').fill('Berta');
		await page.getByTestId('person-results').getByRole('button', { name: 'Berta Beispiel' }).click();
		await page.getByLabel('Deine Rolle').selectOption('comment');
		await page.getByRole('button', { name: 'Freigabe hinzufügen' }).click();
		await expect(page.getByTestId('grant')).toHaveCount(1);

		await guest.reload();
		await guest.getByTestId('project-item').getByRole('button', { name: 'Haushalt', exact: true }).first().click();
		const guestTask = guest.getByTestId('task-item').filter({ hasText: 'Wochenplan' });
		await guestTask.getByRole('button', { name: 'Details' }).click();
		await guestTask.getByLabel('Kommentar schreiben').fill('Hallo vom Gast');
		await guestTask.getByRole('button', { name: 'Kommentieren' }).click();
		await expect(guestTask.getByTestId('comment')).toContainText('Hallo vom Gast');

		// The admin sees the author's name on the comment and the actor's name in the activity.
		await setView('Liste');
		const mine = page.getByTestId('task-item').filter({ hasText: 'Wochenplan' });
		await mine.getByRole('button', { name: 'Details' }).click();
		await expect(mine.getByTestId('comment-author')).toHaveText('Berta Beispiel');
		await expect(mine.getByTestId('activity-actor').filter({ hasText: 'Berta Beispiel' }).first()).toBeVisible();
		await expect(mine.getByTestId('activity-actor').filter({ hasText: 'Test Admin' }).first()).toBeVisible();
	} finally {
		await guestCtx.close();
	}
});

/** Drag a sidebar project row; `at` is the vertical position inside the target row (0 top, 1 bottom). */
async function dragProject(source: Locator, target: Locator, at: number) {
	const from = source.locator('> div').first();
	const to = target.locator('> div').first();
	await from.scrollIntoViewIfNeeded();
	const a = (await from.boundingBox())!;
	const b = (await to.boundingBox())!;
	await page.mouse.move(a.x + a.width / 2, a.y + a.height / 2);
	await page.mouse.down();
	await page.mouse.move(a.x + a.width / 2 + 8, a.y + a.height / 2 + 8, { steps: 3 });
	await page.mouse.move(b.x + b.width / 2, b.y + b.height * at, { steps: 12 });
	await page.mouse.up();
}
const sidebarItem = (name: string) => page.getByTestId('project-item').filter({ has: page.getByRole('button', { name, exact: true }) }).last();
const rootOrder = async () =>
	page.evaluate(async () => {
		const all = (await (await fetch('/v1/projects')).json()) as { name: string; parentID?: string; position?: number; createdAt: string; id: string }[];
		return all
			.filter((p) => !p.parentID)
			.sort((x, y) => (x.position ?? 1e9) - (y.position ?? 1e9) || x.createdAt.localeCompare(y.createdAt))
			.map((p) => p.name);
	});
const apiProjects = () =>
	page.evaluate(async () => (await (await fetch('/v1/projects')).json()) as { id: string; name: string; parentID?: string; description?: string; color?: string; version: number; isFavorite?: boolean }[]);
const projectID = async (name: string) => (await apiProjects()).find((p) => p.name === name)!.id;

test('project state on the server: legacy import, favorites, description, colour, display options', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	// Favourite set in an earlier test lives on the server and survives a reload without any local state.
	await page.evaluate(() => localStorage.removeItem('todo.favorites'));
	await page.reload();
	await expect(page.getByTestId('favorites')).toContainText('Küche');
	const favs = await page.evaluate(async () => (await (await fetch('/v1/me/favorites')).json()) as { items: { projectID: string }[] });
	expect(favs.items).toHaveLength(1);

	// One-time import of the former device-local values (the account has no favourites and no description yet).
	await page.evaluate(async () => {
		for (const f of (await (await fetch('/v1/me/favorites')).json()).items) await fetch(`/v1/me/favorites/${f.projectID}`, { method: 'DELETE', headers: { 'Content-Type': 'application/json' } });
	});
	const haushalt = await projectID('Haushalt');
	const garten = await page.evaluate(async (parentID) => {
		const r = await fetch('/v1/projects', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'Garten', parentID }) });
		return ((await r.json()) as { id: string }).id;
	}, haushalt);
	await page.evaluate(
		([h, g]) => {
			localStorage.setItem('todo.favorites', JSON.stringify([h, 'not-a-project']));
			localStorage.setItem('todo.projectDescriptions', JSON.stringify({ [g]: 'Beete, Hecke und Rasen' }));
			localStorage.setItem('todo.projectDisplay', JSON.stringify({ [g]: { view: 'board', sort: 'title', grouping: 'none', showDone: false } }));
		},
		[haushalt, garten]
	);
	await page.reload();
	await expect(page.getByTestId('favorites')).toContainText('Haushalt');
	await expect.poll(() => page.evaluate(() => ['todo.favorites', 'todo.projectDescriptions', 'todo.projectDisplay'].map((k) => localStorage.getItem(k)))).toEqual([null, null, null]);
	expect((await apiProjects()).find((p) => p.name === 'Garten')!.description).toBe('Beete, Hecke und Rasen');
	const gp = await page.evaluate(async (id) => (await fetch(`/v1/me/project-prefs/${id}`)).json(), garten);
	expect(gp).toMatchObject({ view: 'board', sort: 'title', grouping: 'none', showCompleted: false });
	await openProject('Garten');
	await expect(page.getByTestId('project-description')).toHaveValue('Beete, Hecke und Rasen');
	await expect(page.getByTestId('board')).toBeVisible();

	// Description: inline edit saves on blur through PATCH and survives a reload.
	await openProject('Küche');
	const desc = page.getByTestId('project-description');
	await desc.fill('Alles rund um die Küche');
	await desc.evaluate((e) => (e as HTMLTextAreaElement).blur());
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Küche')!.description).toBe('Alles rund um die Küche');
	await page.reload();
	await openProject('Küche');
	await expect(page.getByTestId('project-description')).toHaveValue('Alles rund um die Küche');
	await desc.fill('');
	await desc.evaluate((e) => (e as HTMLTextAreaElement).blur());
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Küche')!.description ?? '').toBe('');
	await desc.fill('Alles rund um die Küche');
	await desc.evaluate((e) => (e as HTMLTextAreaElement).blur());
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Küche')!.description).toBe('Alles rund um die Küche');

	// Colour picker replaces the ID-derived colour.
	await page.getByTestId('project-more').click();
	await page.getByTestId('project-color-open').click();
	await page.getByRole('button', { name: 'Farbe Blau' }).click();
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Küche')!.color).toBe('#2470E0');
	await expect(page.getByTestId('project-item').getByRole('button', { name: 'Küche', exact: true }).first().locator('span').first()).toHaveCSS('color', 'rgb(36, 112, 224)');
	await page.getByTestId('project-more').click();
	await page.getByTestId('project-color-open').click();
	await page.getByTestId('color-auto').click();
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Küche')!.color ?? '').toBe('');

	// Display options per project and account; a concurrent write from another device does not lose the change.
	const kitchen = await projectID('Küche');
	await setView('Board');
	await expect(page.getByTestId('board')).toBeVisible();
	await expect.poll(async () => (await page.evaluate(async (id) => (await fetch(`/v1/me/project-prefs/${id}`)).json(), kitchen)).view).toBe('board');
	await page.reload();
	await openProject('Küche');
	await expect(page.getByTestId('board')).toBeVisible();
	const before = await page.evaluate(async (id) => (await fetch(`/v1/me/project-prefs/${id}`)).json(), kitchen);
	await page.evaluate(async ([id, rev]) => {
		await fetch(`/v1/me/project-prefs/${id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ revision: rev, sort: 'priority' }) });
	}, [kitchen, before.revision] as const);
	await setView('Liste'); // the page still holds the old revision -> conflict -> retry with the fresh one
	await expect(page.getByTestId('notice')).toHaveCount(0);
	await expect.poll(async () => page.evaluate(async (id) => (await fetch(`/v1/me/project-prefs/${id}`)).json(), kitchen)).toMatchObject({ view: 'list', sort: 'priority', revision: before.revision + 2 });
	await page.getByTestId('display-menu').click();
	await page.getByTestId('show-done').uncheck();
	await page.keyboard.press('Escape');
	await expect.poll(async () => (await page.evaluate(async (id) => (await fetch(`/v1/me/project-prefs/${id}`)).json(), kitchen)).showCompleted).toBe(false);
	expect(await page.evaluate(() => localStorage.getItem('todo.projectDisplay'))).toBeNull();
	await page.getByTestId('display-menu').click();
	await page.getByTestId('show-done').check();
	await page.keyboard.press('Escape');
});

test('sidebar order: drag and drop, move under a parent, menu alternatives, cycle error', async () => {
	await page.setViewportSize({ width: 1280, height: 900 });
	for (const name of ['Alpha', 'Beta', 'Gamma']) {
		await page.getByTestId('add-project').click();
		await page.getByLabel('Neues Projekt').fill(name);
		await page.getByRole('button', { name: 'Projekt anlegen' }).click();
		await expect(sidebarItem(name)).toBeVisible();
	}
	// Projects created within one second have no defined mutual order yet: pin it through the position API.
	await page.evaluate(async () => {
		const all = (await (await fetch('/v1/projects')).json()) as { id: string; name: string }[];
		const root = (n: string) => all.find((p) => p.name === n)!.id;
		for (const [i, n] of ['Alpha', 'Beta', 'Gamma'].entries()) {
			await fetch(`/v1/projects/${root(n)}/position`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ index: 100 + i }) });
		}
	});
	await page.reload();
	const roots = async () => (await rootOrder()).filter((n) => ['Alpha', 'Beta', 'Gamma'].includes(n));
	expect(await roots()).toEqual(['Alpha', 'Beta', 'Gamma']);

	// Drop on the upper edge of Alpha: Gamma becomes the first of the three.
	await dragProject(sidebarItem('Gamma'), sidebarItem('Alpha'), 0.12);
	await expect.poll(roots).toEqual(['Gamma', 'Alpha', 'Beta']);
	const names = () => page.getByTestId('project-item').evaluateAll((els) => els.map((e) => e.querySelector('span.truncate')?.textContent ?? ''));
	await expect.poll(async () => (await names()).filter((n) => ['Alpha', 'Beta', 'Gamma'].includes(n))).toEqual(['Gamma', 'Alpha', 'Beta']);

	// The order persists across a reload (server side, per account).
	await page.reload();
	await expect.poll(async () => (await names()).filter((n) => ['Alpha', 'Beta', 'Gamma'].includes(n))).toEqual(['Gamma', 'Alpha', 'Beta']);

	// Menu alternative: move down one place.
	const open = async (n: string) => {
		await sidebarItem(n).hover();
		await sidebarItem(n).getByRole('button', { name: `Projektmenü: ${n}` }).click();
	};
	await open('Gamma');
	await page.getByTestId('project-move-down').click();
	await expect.poll(roots).toEqual(['Alpha', 'Gamma', 'Beta']);

	// Drop in the middle of a row: Beta becomes a sub-project of Alpha (manage right of the owner).
	await dragProject(sidebarItem('Beta'), sidebarItem('Alpha'), 0.5);
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Beta')!.parentID).toBe(await projectID('Alpha'));
	await expect(sidebarItem('Alpha').getByRole('button', { name: 'Beta', exact: true })).toBeVisible();

	// Menu alternative "Verschieben nach …": back to the top level, then under Gamma.
	await open('Beta');
	await page.getByTestId('project-move-to').click();
	await page.getByLabel('Verschieben nach').selectOption({ label: 'Gamma' });
	await expect.poll(async () => (await apiProjects()).find((p) => p.name === 'Beta')!.parentID).toBe(await projectID('Gamma'));

	// A drop the client cannot see as a cycle but the server rejects (tree changed on another device): 422 message.
	const alpha = await apiProjects().then((l) => l.find((p) => p.name === 'Alpha')!);
	await page.evaluate(async ([id, ver, parent]) => {
		await fetch(`/v1/projects/${id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ version: ver, parentID: parent }) });
	}, [alpha.id, alpha.version, await projectID('Beta')] as const);
	// Stale UI: Gamma and Alpha are still roots here. Dropping Gamma into Alpha would make Gamma its own descendant.
	await dragProject(sidebarItem('Gamma'), sidebarItem('Alpha'), 0.5);
	await expect(page.getByTestId('notice')).toContainText('nicht in sich selbst');
	await page.getByTestId('notice').getByRole('button', { name: 'Abbrechen' }).click();
});

test('project comments panel', async () => {
	await openProject('Haushalt');
	await page.getByTestId('project-comments-open').click();
	const dlg = page.getByTestId('project-comments-dialog');
	await expect(dlg).toBeVisible();
	await expect(dlg).toContainText('Noch keine Projektkommentare');
	await dlg.getByLabel('Kommentar zum Projekt schreiben').fill('Wochenplan bitte bis Freitag');
	await dlg.getByRole('button', { name: 'Kommentieren' }).click();
	const c = dlg.getByTestId('project-comment').filter({ hasText: 'Wochenplan bitte bis Freitag' });
	await expect(c).toBeVisible();
	await expect(c.getByTestId('comment-author')).toHaveText('Du');
	await c.getByRole('button', { name: 'Bearbeiten' }).click();
	await dlg.getByLabel('Bearbeiten', { exact: true }).fill('Wochenplan bitte bis Donnerstag');
	await dlg.getByRole('button', { name: 'Speichern' }).click();
	await expect(dlg.getByTestId('project-comment')).toContainText('bis Donnerstag');

	// A second account with comment rights: author name for the owner, no delete of foreign comments.
	const invitation = await page.request.post('/v1/invitations', { data: {}, headers: { 'Content-Type': 'application/json' } });
	const { token } = (await invitation.json()) as { token: string };
	const guestCtx = await page.context().browser()!.newContext();
	try {
		const guest = await guestCtx.newPage();
		const cdp = await guestCtx.newCDPSession(guest);
		await cdp.send('WebAuthn.enable');
		await cdp.send('WebAuthn.addVirtualAuthenticator', {
			options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
		});
		await guest.goto(`/setup?token=${token}`);
		await guest.getByLabel('Anzeigename').fill('Carla Gast');
		await guest.getByRole('button', { name: 'Passkey erstellen' }).click();
		await expect(guest.getByTestId('account-menu')).toBeVisible();
		const guestID = ((await (await guest.request.get('/v1/me')).json()) as { id: string }).id;
		const grant = await page.request.put(`/v1/projects/${await projectID('Haushalt')}/grants`, {
			data: { principalType: 'person', principalID: guestID, role: 'comment' },
			headers: { 'Content-Type': 'application/json' }
		});
		expect(grant.ok(), await grant.text()).toBeTruthy();
		await guest.reload();
		await guest.getByTestId('project-item').getByRole('button', { name: 'Haushalt', exact: true }).first().click();
		await guest.getByTestId('project-comments-open').click();
		const gd = guest.getByTestId('project-comments-dialog');
		await expect(gd.getByTestId('comment-author').first()).toHaveText('Test Admin');
		await expect(gd.getByRole('button', { name: 'Löschen' })).toHaveCount(0);
		await gd.getByLabel('Kommentar zum Projekt schreiben').fill('Passt, mache ich');
		await gd.getByRole('button', { name: 'Kommentieren' }).click();
		await expect(gd.getByTestId('project-comment').filter({ hasText: 'Passt, mache ich' }).getByTestId('comment-author')).toHaveText('Du');

		// The owner sees the guest by name and may delete the foreign comment (manage).
		await page.reload();
		await openProject('Haushalt');
		await page.getByTestId('project-comments-open').click();
		const again = page.getByTestId('project-comments-dialog');
		const foreign = again.getByTestId('project-comment').filter({ hasText: 'Passt, mache ich' });
		await expect(foreign.getByTestId('comment-author')).toHaveText('Carla Gast');
		await foreign.getByRole('button', { name: 'Löschen' }).click();
		await expect(foreign).toHaveCount(0);
		await again.getByTestId('project-comment').getByRole('button', { name: 'Löschen' }).click();
		await expect(again).toContainText('Noch keine Projektkommentare');
	} finally {
		await guestCtx.close();
	}
	await closeDialogs();
});

test('activity page: infinite list, project filter, labels', async () => {
	await openProject('Küche');
	// 35 more events in the kitchen project so that a second page is needed (page size 30).
	await page.evaluate(async (id) => {
		for (let i = 0; i < 35; i++) {
			await fetch('/v1/tasks', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ projectID: id, title: `Feed ${i}` }) });
		}
	}, await projectID('Küche'));
	await nav('Aktivität');
	const feed = page.getByTestId('feed-item');
	await expect(feed.first()).toBeVisible();
	await expect(feed.first().getByTestId('feed-label')).toHaveText('Aufgabe angelegt');
	await expect(feed.first().getByTestId('feed-actor')).toHaveText('Du');
	// Scrolling to the end loads the following pages through the cursor.
	await expect.poll(async () => {
		await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
		return feed.count();
	}, { timeout: 15_000 }).toBeGreaterThan(30);
	await expect(page.getByTestId('feed-end')).toBeVisible({ timeout: 15_000 });
	// Project comment events carry their own German label; unknown kinds fall back, never crash.
	await expect(page.getByTestId('feed-item').filter({ hasText: 'Projektkommentar hinzugefügt' }).first()).toBeVisible();
	// Filter by project.
	await page.getByTestId('activity-filter').selectOption({ label: 'Haushalt' });
	await expect.poll(async () => feed.count()).toBeGreaterThan(0);
	const projects = await feed.evaluateAll((els) => [...new Set(els.map((e) => e.querySelector('[data-testid="feed-project"]')?.textContent?.trim()))]);
	expect(projects).toEqual(['in Haushalt']);
	await page.getByTestId('activity-filter').selectOption({ label: 'Alle Projekte' });
	await expect.poll(async () => {
		await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
		return feed.count();
	}, { timeout: 15_000 }).toBeGreaterThan(30);
});

test('agents page: pairing, device list with binding and active run, job list with state filter', async () => {
	await nav('Agenten');
	await expect(page.getByText('Noch kein Gerät gekoppelt.')).toBeVisible();
	await page.getByLabel('Bezeichnung des Geräts').fill('Mac Studio');
	await page.getByRole('button', { name: 'Code erzeugen' }).click();
	const code = (await page.getByTestId('pairing-code').locator('code').innerText()).trim();
	const device = page.getByTestId('device').filter({ hasText: 'Mac Studio' });
	await expect(device.getByTestId('device-status')).toHaveText('Wartet auf Kopplung');
	await expect(page.getByText('Keine Aufträge.')).toBeVisible();

	// The runner redeems the code (no session), the owner binds a project and releases a job.
	const origin = new URL(page.url()).origin;
	const paired = await page.request.post('/v1/runner/pair', { data: { code }, headers: { 'Content-Type': 'application/json', Origin: origin } });
	expect(paired.ok(), await paired.text()).toBeTruthy();
	const { deviceID } = (await paired.json()) as { deviceID: string };
	const kitchen = (await apiProjects()).find((p) => p.name === 'Küche')!;
	const bound = await page.request.post('/v1/agents/bindings', {
		data: { projectID: kitchen.id, deviceID, repositoryKey: crypto.randomUUID(), label: 'todo-repo' },
		headers: { 'Content-Type': 'application/json', Origin: origin }
	});
	expect(bound.ok(), await bound.text()).toBeTruthy();
	const bindingID = ((await bound.json()) as { id: string }).id;
	const tasks = (await (await page.request.get(`/v1/tasks?projectID=${kitchen.id}`)).json()) as { id: string; title: string; version: number }[];
	const job = await page.request.post('/v1/agents/jobs', {
		data: { id: crypto.randomUUID(), taskID: tasks[0].id, bindingID, taskRevision: tasks[0].version, mode: 'clarify', scope: 'Offene Fragen klären' },
		headers: { 'Content-Type': 'application/json', Origin: origin }
	});
	expect(job.ok(), await job.text()).toBeTruthy();

	await page.getByRole('button', { name: 'Aktualisieren' }).click();
	await expect(device.getByTestId('device-status')).toHaveText('Gekoppelt');
	await expect(device.getByTestId('binding')).toContainText('Küche');
	await expect(device.getByTestId('binding')).toContainText('todo-repo');
	await expect(device.getByTestId('device-active')).toHaveText('Aktive Läufe: 0');
	const row = page.getByTestId('job').first();
	await expect(row.getByTestId('job-state')).toHaveText('Wartet');
	await expect(row).toContainText('Küche');
	await page.getByTestId('job-filter').selectOption({ label: 'Erfolgreich' });
	await expect(page.getByText('Keine Aufträge.')).toBeVisible();
	await page.getByTestId('job-filter').selectOption({ label: 'Wartet' });
	await expect(page.getByTestId('job')).toHaveCount(1);
	// the feed shows the release event with its German label
	await nav('Aktivität');
	await expect(page.getByTestId('feed-item').filter({ hasText: 'Auftrag für den Runner freigegeben' }).first()).toBeVisible();
});

test('attachment upload with preview', async () => {
	await openProject('Küche');
	await setView('Liste');
	const task = page.getByTestId('task-item').filter({ hasText: 'Einkaufen' });
	await task.getByRole('button', { name: 'Details' }).click();
	await task.getByLabel('Datei auswählen').setInputFiles({ name: 'beleg.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await task.getByRole('button', { name: 'Hochladen' }).click();
	const att = task.getByTestId('attachment');
	await expect(att).toHaveCount(1);
	await expect(att.getByRole('img')).toBeVisible();
	await expect.poll(() => att.getByRole('img').evaluate((i: HTMLImageElement) => i.naturalWidth)).toBe(1);
});

test('oauth consent page and grant management', async () => {
	// Public client registration (RFC 7591) via API; the consent UI is what is under test.
	const reg = await page.request.post('/oauth/register', {
		data: { client_name: 'Test-Assistent', redirect_uris: ['https://client.example/cb'], token_endpoint_auth_method: 'none' },
		headers: { 'Content-Type': 'application/json' }
	});
	expect(reg.ok(), await reg.text()).toBeTruthy();
	const clientID = ((await reg.json()) as { client_id: string }).client_id;
	await page.route('https://client.example/**', (route) => route.fulfill({ status: 200, body: 'client' }));

	const authorize = (state: string) =>
		`/consent?response_type=code&client_id=${clientID}&redirect_uri=${encodeURIComponent('https://client.example/cb')}` +
		`&scope=${encodeURIComponent('projects:read tasks:read')}&state=${state}&code_challenge=${'A'.repeat(43)}&code_challenge_method=S256`;

	// Deny: no project needed, redirect carries access_denied.
	await page.goto(authorize('deny1'));
	await expect(page.getByTestId('consent-redirect')).toContainText('https://client.example');
	await expect(page.getByText('Aufgaben lesen')).toBeVisible();
	await page.getByRole('button', { name: 'Ablehnen' }).click();
	await page.waitForURL(/client\.example\/cb\?.*error=access_denied/);
	expect(page.url()).toContain('state=deny1');

	// Approve needs an explicit project selection.
	await page.goto(authorize('ok1'));
	await page.getByRole('button', { name: 'Erlauben' }).click();
	await expect(page.getByTestId('consent-error')).toHaveText('Bitte wähle mindestens ein Projekt.');
	await page.getByLabel('Haushalt').check();
	await page.getByRole('button', { name: 'Erlauben' }).click();
	await page.waitForURL(/client\.example\/cb\?.*code=/);
	expect(page.url()).toContain('state=ok1');

	// Invalid request shows a message instead of a form.
	await page.goto('/consent?client_id=nope');
	await expect(page.getByTestId('consent-invalid')).toBeVisible();

	// Grant list and revoke.
	await page.goto('/');
	await nav('Konto');
	const grant = page.getByTestId('oauth-grant').filter({ hasText: clientID });
	await expect(grant).toContainText('Projekte lesen, Aufgaben lesen');
	await expect(grant).toContainText('Haushalt');
	await grant.getByRole('button', { name: 'Zugriff widerrufen' }).click();
	await grant.getByRole('button', { name: 'Zugriff widerrufen' }).last().click();
	await expect(page.getByTestId('oauth-info')).toHaveText('Der Zugriff wurde widerrufen.');
	await expect(grant).toContainText('Widerrufen');
	await expect(grant.getByRole('button', { name: 'Zugriff widerrufen' })).toHaveCount(0);
});

test('account: passkeys, sessions and recovery', async () => {
	await nav('Konto');
	await expect(page.getByTestId('passkey-item')).toHaveCount(1);
	await page.getByLabel('Name des neuen Passkeys').fill('Zweiter');
	await page.getByRole('button', { name: 'Passkey hinzufügen' }).click();
	await expect(page.getByTestId('passkey-item')).toHaveCount(2);
	await expect(page.getByTestId('account-info')).toHaveText('Der Passkey wurde hinzugefügt.');

	// Revoke the second passkey (first click asks for confirmation).
	const second = page.getByTestId('passkey-item').filter({ hasText: 'Zweiter' });
	await second.getByRole('button', { name: 'Widerrufen' }).click();
	await second.getByRole('button', { name: 'Widerrufen' }).last().click();
	await expect(second).toContainText('Widerrufen');

	await expect(page.getByTestId('session-item').filter({ hasText: 'Diese Sitzung' })).toHaveCount(1);

	// Admin issues a recovery code in the UI (shown once); the user redeems it on /recover.
	await page.getByLabel('Konto-ID').fill((await page.getByTestId('account-id').innerText()).trim());
	await page.getByRole('button', { name: 'Code ausstellen' }).click();
	const token = (await page.getByTestId('recovery-code').innerText()).trim();
	expect(token.length).toBeGreaterThan(20);
	await page.goto('/recover');
	await page.getByLabel('Recovery-Code').fill(token);
	await page.getByRole('button', { name: 'Code einlösen' }).click();
	await page.getByLabel('Name des neuen Passkeys (optional)').fill('Wiederhergestellt');
	await page.getByRole('button', { name: 'Neuen Passkey erstellen' }).click();
	await expect(page.getByTestId('recovery-done')).toBeVisible();
});

test('mobile 390px: navigation drawer, board and no horizontal page scroll', async () => {
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/');
	const login = page.getByRole('button', { name: 'Mit Passkey anmelden' });
	const menu = page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' });
	await expect(login.or(menu)).toBeVisible();
	if (await login.isVisible()) await login.click();
	await expect(menu).toBeVisible();

	const noOverflow = async (label: string) => {
		const w = await page.evaluate(() => ({
			doc: document.documentElement.scrollWidth,
			body: document.body.scrollWidth,
			inner: window.innerWidth
		}));
		expect(w.doc, `${label}: documentElement overflows`).toBeLessThanOrEqual(w.inner);
		expect(w.body, `${label}: body overflows`).toBeLessThanOrEqual(w.inner);
	};
	const nav = page.getByRole('navigation', { name: 'Seitenleiste' });

	// Drawer is closed by default and opens via the menu button.
	await expect(nav).toBeHidden();
	await menu.click();
	await expect(menu).toHaveAttribute('aria-expanded', 'true');
	await expect(nav).toBeVisible();
	await noOverflow('drawer');
	await nav.getByTestId('project-item').getByRole('button', { name: 'Küche', exact: true }).first().click();
	await expect(nav).toBeHidden();
	await expect(page.getByTestId('task-heading')).toHaveText('Küche');
	await expect(page.getByTestId('fab')).toBeVisible();

	// Task rows stay inside the viewport, including the edit button.
	await setView('Liste');
	const row = page.getByTestId('task-item').first();
	await expect(row).toBeVisible();
	const edit = row.getByRole('button', { name: 'Bearbeiten' });
	const box = await edit.boundingBox();
	expect(box!.x + box!.width).toBeLessThanOrEqual(390);
	await noOverflow('task list');
	await row.getByRole('button', { name: 'Details' }).click();
	await expect(row.getByTestId('task-detail')).toBeVisible();
	await noOverflow('task detail');
	await row.getByRole('button', { name: 'Details' }).click();

	// Board scrolls horizontally inside its own container, not the page.
	await setView('Board');
	await expect(page.getByTestId('board')).toBeVisible();
	await expect(page.getByTestId('board-lane').first()).toBeVisible();
	await noOverflow('board');
	await page.getByTestId('project-comments-open').click();
	await expect(page.getByTestId('project-comments-dialog')).toBeVisible();
	await noOverflow('project comments');
	await closeDialogs();
	const scroller = await page.getByTestId('board').evaluate((e) => ({ sw: e.scrollWidth, cw: e.clientWidth, snap: getComputedStyle(e).scrollSnapType }));
	expect(scroller.sw).toBeGreaterThan(scroller.cw);
	expect(scroller.snap).toContain('x');
	if (process.env.BOARD_SHOTS) await page.screenshot({ path: `${process.env.BOARD_SHOTS}/board-mobil.png` });
	await setView('Liste');

	// Bottom navigation reaches the main views directly.
	const bottom = page.getByRole('navigation', { name: 'Hauptnavigation' });
	await expect(bottom).toBeVisible();
	for (const view of ['Heute', 'Anstehend', 'Suche']) {
		await bottom.getByRole('button', { name: view, exact: true }).click();
		await expect(page.getByTestId('view-heading')).toBeVisible();
		await page.waitForTimeout(300);
		await noOverflow(view);
	}
	// Drawer: Teams, Agenten, Aktivität and Konto live under "Mehr".
	for (const view of ['Teams', 'Agenten', 'Aktivität', 'Konto']) {
		await menu.click();
		await nav.getByRole('button', { name: 'Mehr', exact: true }).click();
		await nav.getByRole('button', { name: view, exact: true }).click();
		await expect(nav).toBeHidden();
		await expect(page.getByTestId('view-heading')).toBeVisible();
		await page.waitForTimeout(300);
		await noOverflow(view);
	}
	await page.setViewportSize({ width: 1280, height: 720 });
});

test('appearance settings persist locally and in the account', async () => {
	const SHOTS = process.env.APPEARANCE_SHOTS;
	await page.setViewportSize({ width: 900, height: 1500 });
	await page.emulateMedia({ colorScheme: 'light' });
	await page.evaluate(() => localStorage.clear());
	await page.reload();
	await nav('Konto');
	const html = page.locator('html');
	await expect(page.getByTestId('appearance')).toBeVisible();
	await expect(page.getByTestId('appearance-sync')).toHaveAttribute('data-state', 'saved');

	if (SHOTS) {
		await page.getByTestId('appearance').scrollIntoViewIfNeeded();
		await page.locator('section:has(> [data-testid="appearance"])').screenshot({ path: `${SHOTS}/darstellung-hell.png` });
	}

	await page.getByTestId('mode-dark').click();
	await page.getByTestId('accent-teal').click();
	await page.getByTestId('glow-strong').click();
	await page.getByTestId('transparency-toggle').check();
	await expect(html).toHaveClass(/dark/);
	await expect(html).toHaveAttribute('data-glow', 'strong');
	await expect(html).toHaveAttribute('data-transparency', 'reduced');
	await expect(page.getByTestId('accent-current')).toHaveText('Aktuell: #0D9488');
	await expect(page.getByTestId('appearance-sync')).toHaveAttribute('data-state', 'saved');

	await page.getByTestId('accent-hex').fill('zzz');
	await page.getByTestId('accent-apply').click();
	await expect(page.getByTestId('accent-invalid')).toBeVisible();
	await page.getByTestId('accent-hex').fill('#B45309');
	await page.getByTestId('accent-apply').click();
	await expect(page.getByTestId('accent-current')).toHaveText('Aktuell: #B45309');
	await expect(page.getByTestId('appearance-sync')).toHaveAttribute('data-state', 'saved');

	// the account holds the values
	const stored = await page.evaluate(async () => (await fetch('/v1/me/preferences')).json());
	expect(stored.appearance).toMatchObject({ colorScheme: 'dark', accent: 'custom', accentCustomHex: '#B45309', glow: 'strong' });

	// pre-paint: the cached choice is applied before the app starts
	await page.reload();
	await expect(html).toHaveClass(/dark/);
	await expect(html).toHaveAttribute('data-glow', 'strong');

	if (SHOTS) {
		await nav('Konto');
		await page.locator('section:has(> [data-testid="appearance"])').screenshot({ path: `${SHOTS}/darstellung-dunkel.png` });
	}

	// a fresh device (empty storage) gets the account's values
	await page.evaluate(() => localStorage.clear());
	await page.reload();
	await expect(html).toHaveClass(/dark/, { timeout: 10_000 });
	await expect(html).toHaveAttribute('data-glow', 'strong');
	await nav('Konto');
	await expect(page.getByTestId('accent-current')).toHaveText('Aktuell: #B45309');
	await page.setViewportSize({ width: 1280, height: 720 });
});
