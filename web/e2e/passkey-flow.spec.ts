import { expect, test, type Page } from '@playwright/test';

const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

// Serial tests share one page, so the passkey created in the first test is available to the later ones.
test.describe.configure({ mode: 'serial' });
let page: Page;

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
	await expect(page.getByRole('button', { name: 'Abmelden' })).toBeVisible();

	// Logout returns to the login view.
	await page.getByRole('button', { name: 'Abmelden' }).click();
	await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();

	// Password login must not be offered when the server does not allow it.
	await expect(page.getByRole('button', { name: 'Andere Anmeldemethode' })).toHaveCount(0);

	// Passkey login, also after a reload (cookie session survives).
	await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
	await expect(page.getByRole('button', { name: 'Abmelden' })).toBeVisible();
	await page.reload();
	await expect(page.getByRole('button', { name: 'Abmelden' })).toBeVisible();

	// Project, sub-project, task.
	await page.getByLabel('Neues Projekt').fill('Haushalt');
	await page.getByRole('button', { name: 'Projekt anlegen' }).click();
	const root = page.getByTestId('project-item').filter({ hasText: 'Haushalt' }).first();
	await expect(root).toBeVisible();

	await root.getByRole('button', { name: /Projekte: Haushalt/ }).click();
	await root.getByRole('button', { name: 'Unterprojekt' }).click();
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
	await page.getByRole('button', { name: 'Suche', exact: true }).click();
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
	await page.getByRole('button', { name: 'Heute', exact: true }).click();
	const todayItem = page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' });
	await expect(todayItem).toBeVisible();
	await expect(todayItem.getByTestId('chip-priority')).toHaveText('Hoch');
	await page.getByRole('button', { name: 'Als Nächstes', exact: true }).click();
	await expect(page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' })).toBeVisible();
	await page.getByRole('button', { name: 'Anstehend', exact: true }).click();
	await expect(page.getByTestId('view-heading')).toHaveText('Anstehend');
	await expect(page.getByTestId('planning-item').filter({ hasText: 'Einkaufen' })).toHaveCount(0);
});

test('board reorder persists, search and saved filter', async () => {
	await openProject('Küche');
	await page.getByRole('tab', { name: 'Board' }).click();
	const open = page.getByTestId('board-column-open');
	await expect(open.getByTestId('board-card')).toHaveCount(2);
	const before = await open.getByTestId('board-card').allInnerTexts();
	const secondTitle = before[1].split('\n')[0];
	await open.getByTestId('board-card').last().getByRole('button', { name: 'Nach oben' }).click();
	await expect(open.getByTestId('board-card').first()).toContainText(secondTitle);
	await page.reload();
	await openProject('Küche');
	await page.getByRole('tab', { name: 'Board' }).click();
	await expect(page.getByTestId('board-column-open').getByTestId('board-card').first()).toContainText(secondTitle);

	// Move a card to another column.
	await page
		.getByTestId('board-column-open')
		.getByTestId('board-card')
		.filter({ hasText: 'Putzen' })
		.getByLabel('Verschieben nach Spalte')
		.selectOption('in_progress');
	await expect(page.getByTestId('board-column-in_progress').getByTestId('board-card')).toContainText('Putzen');

	// Search + saved filter.
	await page.getByRole('button', { name: 'Suche', exact: true }).click();
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
	await page.getByRole('button', { name: 'Teams', exact: true }).click();
	await page.getByLabel('Neues Team').fill('Familie');
	await page.getByRole('button', { name: 'Team anlegen' }).click();
	await expect(page.getByTestId('team-item')).toContainText('Familie');
	await expect(page.getByTestId('team-member')).toHaveCount(1);
	await expect(page.getByTestId('team-member')).toContainText('Teamadministration');

	await openProject('Haushalt');
	await page.getByRole('tab', { name: 'Freigaben' }).click();
	await expect(page.getByTestId('my-role')).toHaveText('Verwalten');
	await page.getByLabel('Empfänger').selectOption('team');
	await page.getByLabel('Team', { exact: true }).selectOption({ label: 'Familie' });
	await page.getByRole('button', { name: 'Freigabe hinzufügen' }).click();
	await expect(page.getByTestId('grant')).toContainText('Familie');
	await page.getByTestId('grant').getByRole('button', { name: 'Entziehen' }).click();
	await expect(page.getByTestId('grant')).toHaveCount(0);
});

test('attachment upload with preview', async () => {
	await openProject('Küche');
	await page.getByRole('tab', { name: 'Liste' }).click();
	const task = page.getByTestId('task-item').filter({ hasText: 'Einkaufen' });
	await task.getByRole('button', { name: 'Details' }).click();
	await task.getByLabel('Datei auswählen').setInputFiles({ name: 'beleg.png', mimeType: 'image/png', buffer: PNG_1X1 });
	await task.getByRole('button', { name: 'Hochladen' }).click();
	const att = task.getByTestId('attachment');
	await expect(att).toHaveCount(1);
	await expect(att.getByRole('img')).toBeVisible();
	await expect.poll(() => att.getByRole('img').evaluate((i: HTMLImageElement) => i.naturalWidth)).toBe(1);
});

test('account: passkeys, sessions and recovery', async () => {
	await page.getByRole('button', { name: 'Konto', exact: true }).click();
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

	// Admin issues a recovery code via API (no UI for issuing yet); the user redeems it on /recover.
	const id = (await page.getByTestId('account-id').innerText()).trim();
	const issued = await page.request.post(`/v1/identity/accounts/${id}/recovery`, {
		data: {},
		headers: { 'Content-Type': 'application/json' }
	});
	expect(issued.ok()).toBeTruthy();
	const { token } = (await issued.json()) as { token: string };
	await page.goto('/recover');
	await page.getByLabel('Recovery-Code').fill(token);
	await page.getByRole('button', { name: 'Code einlösen' }).click();
	await page.getByLabel('Name des neuen Passkeys (optional)').fill('Wiederhergestellt');
	await page.getByRole('button', { name: 'Neuen Passkey erstellen' }).click();
	await expect(page.getByTestId('recovery-done')).toBeVisible();
});
