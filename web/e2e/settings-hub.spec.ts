import { expect, test, type Page } from '@playwright/test';

// Needs a fresh backend database (bootstrap happens here). Run on its own:
//   E2E_BASE_URL=... npx playwright test e2e/settings-hub.spec.ts --project=chromium
// The backend's OAUTH_ISSUER must equal the origin so the Claude Code check reports "ok".
// Optional: SETTINGS_SHOTS=<dir> writes the documentation screenshots.
const BOOTSTRAP_TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
const SHOTS = process.env.SETTINGS_SHOTS;

test.describe.configure({ mode: 'serial' });
let admin: Page;
let member: Page;
let origin = '';

async function authenticator(page: Page) {
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('WebAuthn.enable');
	await cdp.send('WebAuthn.addVirtualAuthenticator', {
		options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
	});
}
const shot = async (page: Page, name: string) => {
	if (!SHOTS) return;
	await page.evaluate(() => {
		if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
		window.scrollTo(0, 0);
	});
	await page.waitForTimeout(300);
	await page.screenshot({ path: `${SHOTS}/${name}.png` });
};
async function noOverflow(page: Page, label: string) {
	const w = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, inner: window.innerWidth }));
	expect(w.doc, `${label}: page overflows horizontally`).toBeLessThanOrEqual(w.inner);
}
/** The popover panel lies completely inside the viewport. */
async function panelInViewport(page: Page, name: string) {
	const box = await page.getByRole('dialog', { name }).boundingBox();
	const vp = page.viewportSize()!;
	expect(box, name).not.toBeNull();
	expect(box!.x).toBeGreaterThanOrEqual(0);
	expect(box!.y).toBeGreaterThanOrEqual(0);
	expect(box!.x + box!.width).toBeLessThanOrEqual(vp.width);
	expect(box!.y + box!.height).toBeLessThanOrEqual(vp.height);
}

test.beforeAll(async ({ browser }) => {
	test.skip(browser.browserType().name() !== 'chromium', 'passkey needs the Chromium CDP virtual authenticator');
	admin = await (await browser.newContext({ viewport: { width: 1280, height: 800 }, locale: 'de-DE' })).newPage();
	await authenticator(admin);
	await admin.goto('/setup');
	await admin.getByLabel('Einrichtungs- oder Einladungscode').fill(BOOTSTRAP_TOKEN);
	await admin.getByLabel('Anzeigename').fill('Anna Admin');
	await admin.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(admin.getByTestId('account-menu')).toBeVisible();
	origin = new URL(admin.url()).origin;
});
test.afterAll(async () => {
	await admin?.context().close();
	await member?.context().close();
});

test('hub: reachable from the user menu, groups and one description per entry', async () => {
	await admin.getByTestId('account-menu').click();
	await panelInViewport(admin, 'Kontomenü');
	await shot(admin, 'benutzermenue');
	await admin.getByTestId('menu-settings').click();
	await expect(admin).toHaveURL(/\/einstellungen$/);
	await expect(admin.getByTestId('view-heading')).toHaveText('Einstellungen');
	const nav = admin.getByRole('navigation', { name: 'Einstellungsbereiche' });
	for (const group of ['Profil', 'Sicherheit', 'Darstellung', 'Benachrichtigungen & E-Mail', 'Berechtigungen & Zugriff', 'Verbundene Apps & Agenten', 'Daten & Datenschutz', 'Verwaltung']) {
		await expect(nav.getByRole('heading', { name: group, exact: true })).toBeVisible();
	}
	// Landing: every visible entry has a card with its description line.
	const cards = admin.getByTestId('settings-landing').getByRole('link');
	await expect(cards).toHaveCount(25);
	await expect(admin.getByTestId('settings-card-passkeys')).toContainText('Mit welchen Geräten und Schlüsseln du dich anmeldest.');
	await shot(admin, 'einstellungen');
	await nav.getByRole('link', { name: 'Passkeys' }).click();
	await expect(admin).toHaveURL(/\/einstellungen\/passkeys$/);
	await expect(admin.getByTestId('passkey-item')).toHaveCount(1);
	await expect(nav.getByRole('link', { name: 'Passkeys' })).toHaveAttribute('aria-current', 'page');
	// Own pages still work: appearance, notifications, email, permissions, connected apps.
	for (const [id, testid] of [['darstellung', 'appearance'], ['benachrichtigungen', 'notify-settings'], ['email', 'email-settings'], ['verbindungen', 'oauth-grants']] as const) {
		await admin.getByTestId(`settings-link-${id}`).click();
		await expect(admin.getByTestId(testid)).toBeVisible();
	}
	await admin.getByTestId('settings-link-berechtigungen').click();
	await expect(admin.getByTestId('view-heading')).toHaveText('Berechtigungen & Zugriff');
	await admin.getByTestId('settings-link-runner').click();
	await expect(admin.getByTestId('runner-count')).toBeVisible();
});

test('settings search finds entries by keyword', async () => {
	await admin.goto('/einstellungen');
	await admin.getByTestId('settings-search').fill('smtp');
	await expect(admin.getByTestId('settings-search-results').getByRole('link', { name: 'E-Mail-Server' })).toBeVisible();
	await admin.getByTestId('settings-search').fill('zzzz');
	await expect(admin.getByTestId('settings-search-results')).toContainText('Keine passende Einstellung');
});

test('old /konto paths redirect to the hub', async () => {
	await admin.goto('/konto');
	await expect(admin).toHaveURL(/\/einstellungen$/);
	await admin.goto('/konto/berechtigungen');
	await expect(admin).toHaveURL(/\/einstellungen\/berechtigungen$/);
	await admin.goto('/konto/verwaltung');
	await expect(admin).toHaveURL(/\/einstellungen\/verwaltung-konten$/);
	await expect(admin.getByTestId('recovery-issue')).toBeVisible();
	await admin.goto('/einstellungen/gibt-es-nicht');
	await expect(admin.getByTestId('settings-notfound')).toBeVisible();
});

test('theme switch in the user menu', async () => {
	await admin.getByTestId('account-menu').click();
	await admin.getByTestId('theme-dark').click();
	await expect(admin.locator('html')).toHaveClass(/dark/);
	await expect(admin.getByTestId('theme-dark')).toHaveAttribute('aria-pressed', 'true');
	await shot(admin, 'benutzermenue-dunkel');
	await admin.keyboard.press('Escape');
	await admin.goto('/hilfe/claude-code');
	await expect(admin.getByTestId('claude-origin')).toBeVisible();
	await shot(admin, 'claude-code-verbinden-dunkel');
	await admin.getByTestId('account-menu').click();
	await admin.getByTestId('theme-light').click();
	await expect(admin.locator('html')).not.toHaveClass(/dark/);
	await admin.keyboard.press('Escape');
});

test('help menu lists the help pages and external links', async () => {
	await admin.goto('/heute');
	await admin.getByTestId('help-menu').click();
	await panelInViewport(admin, 'Hilfemenü');
	for (const name of ['Erste Schritte', 'Tastaturkürzel', 'Claude Code verbinden', 'Agentenhandbuch', 'Über Todolino']) {
		await expect(admin.getByRole('dialog', { name: 'Hilfemenü' }).getByRole('button', { name })).toBeVisible();
	}
	const dialog = admin.getByRole('dialog', { name: 'Hilfemenü' });
	await expect(dialog.getByRole('link', { name: 'Problem melden' })).toHaveAttribute('href', 'https://github.com/MagicalWig34653/todo/issues');
	await expect(dialog.getByRole('link', { name: 'Dokumentation' })).toHaveAttribute('href', 'https://magicalwig34653.github.io/todo/');
	await shot(admin, 'hilfemenue');
	await dialog.getByRole('button', { name: 'Erste Schritte' }).click();
	await expect(admin).toHaveURL(/\/hilfe\/erste-schritte$/);
	await expect(admin.getByTestId('help-start')).toBeVisible();
});

test('keyboard shortcuts page and the ? overlay', async () => {
	await admin.goto('/hilfe/tastaturkuerzel');
	await expect(admin.getByTestId('shortcut-list')).toContainText('Aufgabe schnell hinzufügen');
	await admin.goto('/heute');
	await expect(admin.getByTestId('view-heading')).toBeVisible();
	await admin.keyboard.press('?');
	await expect(admin.getByTestId('shortcuts-overlay')).toBeVisible();
	await expect(admin.getByTestId('shortcuts-overlay')).toContainText('Esc');
	await admin.keyboard.press('Escape');
	await expect(admin.getByTestId('shortcuts-overlay')).toBeHidden();
});

test('Claude Code page shows the real origin, /mcp and checks the connection', async () => {
	await admin.goto('/hilfe/claude-code');
	await expect(admin.getByTestId('claude-origin')).toHaveText(origin);
	await expect(admin.getByTestId('claude-cmd-marketplace')).toHaveText('/plugin marketplace add MagicalWig34653/todo');
	await expect(admin.getByTestId('claude-cmd-install')).toHaveText('/plugin install todolino@todolino');
	await expect(admin.getByTestId('claude-cmd-mcp')).toHaveText(`claude mcp add --transport http --scope user todolino ${origin}/mcp`);
	await expect(admin.getByTestId('claude-cmd-mcp')).toContainText('/mcp');
	await admin.getByTestId('claude-check').click();
	await expect(admin.getByTestId('claude-check-resource')).toHaveAttribute('data-state', 'ok');
	await expect(admin.getByTestId('claude-check-capabilities')).toHaveAttribute('data-state', 'ok');
	await expect(admin.getByTestId('claude-check-results')).toContainText(`${origin}/mcp`);
	await shot(admin, 'claude-code-verbinden');
	// The same page is part of the settings hub.
	await admin.goto('/einstellungen/mcp');
	await expect(admin.getByTestId('claude-origin')).toHaveText(origin);
});

test('agent manual and about page', async () => {
	await admin.goto('/hilfe/agentenhandbuch');
	await expect(admin.getByTestId('manual-content')).toBeVisible();
	await expect(admin.getByTestId('manual-version')).toContainText('Version');
	await admin.goto('/hilfe/ueber');
	await expect(admin.getByTestId('about-status')).toHaveText('bereit');
	await expect(admin.getByTestId('about-origin')).toHaveText(origin);
	await expect(admin.getByRole('link', { name: 'Problem melden (GitHub)' })).toHaveAttribute('href', /github\.com\/MagicalWig34653\/todo\/issues/);
	await admin.goto('/hilfe');
	await expect(admin.getByTestId('help-landing').getByRole('link')).toHaveCount(5);
	await shot(admin, 'hilfe');
	await admin.goto('/hilfe/gibt-es-nicht');
	await expect(admin.getByTestId('help-notfound')).toBeVisible();
});

test('administration: invitation, system status, honest gaps', async () => {
	await admin.goto('/einstellungen/verwaltung-einladungen');
	await admin.getByTestId('invite-create').click();
	const code = (await admin.getByTestId('invite-code').innerText()).trim();
	expect(code.length).toBeGreaterThan(20);
	await expect(admin.getByTestId('invite-link')).toHaveText(`${origin}/setup?token=${encodeURIComponent(code)}`);
	await expect(admin.getByTestId('invite-gap')).toBeVisible();
	await admin.getByTestId('settings-link-verwaltung-system').click();
	await expect(admin.getByTestId('admin-system-status')).toHaveText('bereit');
	await admin.getByTestId('settings-link-verwaltung-mail').click();
	await expect(admin.getByTestId('server-settings-mail')).toBeVisible();
	await admin.getByTestId('settings-link-verwaltung-push').click();
	await expect(admin.getByTestId('server-settings-push')).toBeVisible();
	await admin.getByTestId('settings-link-verwaltung-speicher').click();
	await expect(admin.getByTestId('server-settings-attachments')).toBeVisible();
	await shot(admin, 'verwaltung');
	await admin.getByTestId('settings-link-verwaltung-konten').click();
	await expect(admin.getByTestId('admin-gaps')).toBeVisible();

	// A second account registers with the invitation and gets no administration.
	member = await (await admin.context().browser()!.newContext({ viewport: { width: 1280, height: 800 }, locale: 'de-DE' })).newPage();
	await authenticator(member);
	await member.goto(`/setup?token=${code}`);
	await member.getByLabel('Anzeigename').fill('Max Mitglied');
	await member.getByRole('button', { name: 'Passkey erstellen' }).click();
	await expect(member.getByTestId('account-menu')).toBeVisible();
});

test('non-admins see no administration, neither in menu, hub nor by URL', async () => {
	await member.getByTestId('account-menu').click();
	await expect(member.getByTestId('menu-settings')).toBeVisible();
	await expect(member.getByTestId('menu-admin')).toHaveCount(0);
	await member.keyboard.press('Escape');
	await member.goto('/einstellungen');
	await expect(member.getByRole('navigation', { name: 'Einstellungsbereiche' }).getByRole('heading', { name: 'Verwaltung' })).toHaveCount(0);
	await expect(member.getByTestId('settings-landing').getByRole('link')).toHaveCount(12);
	await member.goto('/einstellungen/verwaltung-einladungen');
	await expect(member.getByTestId('admin-denied')).toBeVisible();
	await expect(member.getByTestId('invite-create')).toHaveCount(0);
	await member.goto('/konto/verwaltung');
	await expect(member.getByTestId('admin-denied')).toBeVisible();
	await expect(member.getByTestId('recovery-issue')).toHaveCount(0);
});

test('mobile 390px: list then detail, menus inside the viewport, no horizontal scroll', async () => {
	await member.setViewportSize({ width: 390, height: 844 });
	await member.goto('/einstellungen');
	// List screen: entries with descriptions, no content column yet.
	await expect(member.getByTestId('settings-nav')).toBeVisible();
	await expect(member.getByTestId('settings-content')).toBeHidden();
	await expect(member.getByTestId('settings-link-passkeys')).toContainText('Mit welchen Geräten');
	await noOverflow(member, 'settings list');
	await shot(member, 'einstellungen-mobil');
	await member.getByTestId('settings-link-passkeys').click();
	await expect(member).toHaveURL(/\/einstellungen\/passkeys$/);
	await expect(member.getByTestId('settings-nav')).toBeHidden();
	await expect(member.getByTestId('passkey-item')).toHaveCount(1);
	await noOverflow(member, 'passkeys');
	await member.getByTestId('settings-back').click();
	await expect(member).toHaveURL(/\/einstellungen$/);
	await member.getByTestId('settings-link-mcp').click();
	await expect(member.getByTestId('claude-cmd-mcp')).toBeVisible();
	await noOverflow(member, 'claude code');
	await shot(member, 'claude-code-mobil');
	await member.getByTestId('account-menu').click();
	await panelInViewport(member, 'Kontomenü');
	await member.keyboard.press('Escape');
	await member.getByTestId('help-menu').click();
	await panelInViewport(member, 'Hilfemenü');
	await shot(member, 'hilfemenue-mobil');
	await member.keyboard.press('Escape');
	await member.goto('/hilfe');
	await expect(member.getByTestId('help-nav')).toBeVisible();
	await expect(member.getByTestId('help-content')).toBeHidden();
	await noOverflow(member, 'help list');
	await member.getByTestId('help-link-ueber').click();
	await expect(member.getByTestId('about')).toBeVisible();
	await noOverflow(member, 'about');
});
