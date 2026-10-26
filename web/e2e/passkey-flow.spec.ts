import { expect, test } from '@playwright/test';

const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';

test('bootstrap registration, logout, passkey login, project tree and task', async ({ page }) => {
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
