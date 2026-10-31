// Erzeugt die Screenshots für README.md und docs-site/ gegen einen frischen, isolierten Stack.
// Aufruf siehe docs/STATUS.md (Abschnitt "Screenshots"): BASE_URL, OUT_DIR, BOOTSTRAP_TOKEN per Umgebung.
// Alle Daten sind erfundene Demo-Daten; der Passkey liegt nur im virtuellen Authenticator.
import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';

const BASE = process.env.BASE_URL ?? 'http://localhost:25373';
const OUT = process.env.OUT_DIR ?? '../docs-site/screenshots';
const TOKEN = process.env.BOOTSTRAP_TOKEN ?? 'dev-bootstrap-only';
mkdirSync(OUT, { recursive: true });

const DESKTOP = { width: 1360, height: 860 };
const MOBILE = { width: 390, height: 844 };

const browser = await chromium.launch();
const ctx = await browser.newContext({ baseURL: BASE, viewport: DESKTOP, locale: 'de-DE', timezoneId: 'Europe/Berlin' });
const page = await ctx.newPage();
page.setDefaultTimeout(15000);

// Neue Projekte sind im Modus "Klassisch"; Kriterien, Abhängigkeiten und Überblick gibt es nur im Projektmanagement-Modus.
// Bis zur Gegenüberstellung unten meldet der Mock jedes Projekt als `management` (wie e2e/passkey-flow.spec.ts).
let forceManagement = true;
await page.route('**/v1/me/project-prefs*', async (route) => {
	if (!forceManagement || route.request().method() !== 'GET') return route.continue();
	const res = await route.fetch();
	const body = await res.json();
	const fix = (p) => Object.assign(p, { mode: 'management' });
	if (Array.isArray(body.items)) body.items.forEach(fix);
	else fix(body);
	await route.fulfill({ response: res, json: body });
});

const cdp = await ctx.newCDPSession(page);
await cdp.send('WebAuthn.enable');
await cdp.send('WebAuthn.addVirtualAuthenticator', {
	options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true }
});

const shot = async (name, opts = {}) => {
	await page.evaluate(() => document.activeElement instanceof HTMLElement && document.activeElement.blur());
	await page.waitForTimeout(400);
	await page.screenshot({ path: `${OUT}/${name}.png`, ...opts });
	console.log('shot', name);
};
const closeDialogs = async () => {
	while (await page.locator('[aria-modal="true"]').first().isVisible()) await page.keyboard.press('Escape');
};
const nav = async (name) => {
	await closeDialogs();
	const btn = page.getByRole('button', { name: new RegExp(`^${name}( \\d+)?$`) }).first();
	if (!(await btn.isVisible())) await page.getByRole('button', { name: 'Mehr', exact: true }).click();
	await btn.click();
};
const setView = async (view) => {
	await closeDialogs();
	await page.getByTestId('display-menu').click();
	await page.getByRole('dialog', { name: 'Anzeige' }).getByRole('button', { name: view }).click();
	await page.keyboard.press('Escape');
};
const desktop = () => page.setViewportSize(DESKTOP);
const mobile = () => page.setViewportSize(MOBILE);
const localDate = (days, hour) => {
	const d = new Date(Date.now() + days * 86400000);
	const p = (n) => String(n).padStart(2, '0');
	return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(hour)}:00`;
};

// Registrierung mit Ersteinrichtungscode (der Code wird nicht ins Bild genommen).
await page.goto('/setup');
await page.getByLabel('Einrichtungs- oder Einladungscode').fill(TOKEN);
await page.getByLabel('Anzeigename').fill('Mara Beispiel');
await page.getByRole('button', { name: 'Passkey erstellen' }).click();
await page.getByTestId('account-menu').waitFor();
await page.getByTestId('account-menu').click();
await page.getByRole('button', { name: 'Abmelden' }).click();
await page.getByRole('button', { name: 'Mit Passkey anmelden' }).waitFor();
await shot('login');
await mobile();
await shot('login-mobil');
await desktop();
await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
await page.getByTestId('account-menu').waitFor();

// Projekte
const addRoot = async (name) => {
	await page.getByTestId('add-project').click();
	await page.getByLabel('Neues Projekt').fill(name);
	await page.getByRole('button', { name: 'Projekt anlegen' }).click();
	await page.getByTestId('project-item').filter({ hasText: name }).first().waitFor();
};
const addSub = async (parent, name) => {
	const root = page.getByTestId('project-item').filter({ hasText: parent }).first();
	await root.getByRole('button', { name: parent, exact: true }).first().hover();
	await root.getByRole('button', { name: `Projektmenü: ${parent}` }).click();
	await page.getByRole('button', { name: 'Unterprojekt' }).click();
	await root.getByLabel('Name des Unterprojekts').fill(name);
	await root.getByRole('button', { name: 'Speichern' }).click();
	await page.getByTestId('project-item').filter({ hasText: name }).last().waitFor();
};
await addRoot('Urlaub Portugal');
await addRoot('Website-Relaunch');
await addRoot('Haushalt');
await addSub('Haushalt', 'Küche');
await addSub('Haushalt', 'Garten');
await addSub('Website-Relaunch', 'Design');
await addSub('Website-Relaunch', 'Entwicklung');

const open = async (name) => {
	await closeDialogs();
	await page.getByTestId('project-item').getByRole('button', { name, exact: true }).first().click();
	await page.getByTestId('task-heading').filter({ hasText: name }).waitFor();
};
const addTasks = async (titles) => {
	for (const title of titles) {
		await page.getByLabel('Neue Aufgabe, Enter zum Anlegen').fill(title);
		await page.keyboard.press('Enter');
		await page.getByTestId('task-item').filter({ hasText: title }).first().waitFor();
	}
};

await open('Küche');
await addTasks(['Wocheneinkauf erledigen', 'Backofen reinigen', 'Spülmaschine ausräumen', 'Gewürzregal sortieren', 'Neue Kaffeemaschine vergleichen']);
await open('Garten');
await addTasks(['Hecke schneiden', 'Tomaten gießen']);
await open('Design');
await addTasks(['Farbkonzept abstimmen', 'Startseite entwerfen']);
await open('Entwicklung');
await addTasks(['Kontaktformular bauen', 'Seitenladezeit messen', 'Cookie-Hinweis prüfen']);
await open('Urlaub Portugal');
await addTasks(['Flüge buchen', 'Unterkunft in Lissabon reservieren']);

// Labels über die Suche anlegen
await nav('Suche');
for (const l of ['dringend', 'einkaufen', 'Idee']) {
	await page.getByLabel('Neues Label').fill(l);
	await page.getByRole('button', { name: 'Label anlegen' }).click();
	await page.getByTestId('label-item').filter({ hasText: l }).waitFor();
}

// Details zu einer Aufgabe
await open('Küche');
const task = page.getByTestId('task-item').filter({ hasText: 'Wocheneinkauf erledigen' });
await task.getByRole('button', { name: 'Details' }).click();
const detail = task.getByTestId('task-detail');
await detail.getByLabel('Fällig').fill(localDate(0, 18));
await detail.getByLabel('Priorität').selectOption('3');
await detail.getByRole('button', { name: 'Planung speichern' }).click();
await detail.getByLabel('Label hinzufügen').selectOption({ label: 'dringend' });
await detail.getByLabel('Label hinzufügen').selectOption({ label: 'einkaufen' }).catch(() => {});
for (const c of ['Milch und Eier', 'Gemüse für das Wochenende', 'Kaffeebohnen']) {
	await detail.getByLabel('Neues Kriterium').fill(c);
	await detail.getByRole('button', { name: 'Kriterium hinzufügen' }).click();
	await detail.getByRole('checkbox', { name: c }).waitFor();
}
await detail.getByRole('checkbox', { name: 'Milch und Eier' }).check();
await detail.getByRole('checkbox', { name: 'Kaffeebohnen' }).check();
await detail.getByLabel('Kommentar schreiben').fill('Bitte Bio-Milch nehmen, die andere war letzte Woche zu schnell sauer.');
await detail.getByRole('button', { name: 'Kommentieren' }).click();
await detail.getByTestId('comment').first().waitFor();
await detail.getByLabel('Kommentar schreiben').fill('Erledigt ich morgen früh vor der Arbeit.');
await detail.getByRole('button', { name: 'Kommentieren' }).click();
await page.waitForTimeout(500);
// close the detail again: its dependency picker lists the other tasks and would match later task filters
await task.getByRole('button', { name: 'Details' }).click();

// Planung für Heute / Anstehend
const plan = async (project, title, days, prio) => {
	await open(project);
	const t = page.getByTestId('task-item').filter({ hasText: title });
	await t.getByRole('button', { name: 'Details' }).click();
	const d = t.getByTestId('task-detail');
	await d.getByLabel('Fällig').fill(localDate(days, 12));
	await d.getByLabel('Priorität').selectOption(String(prio));
	await d.getByRole('button', { name: 'Planung speichern' }).click();
	await page.waitForTimeout(300);
	await t.getByRole('button', { name: 'Schließen' }).click().catch(() => {});
};
await plan('Küche', 'Backofen reinigen', 0, 2);
await plan('Entwicklung', 'Kontaktformular bauen', 0, 3);
await plan('Design', 'Farbkonzept abstimmen', 2, 2);
await plan('Garten', 'Hecke schneiden', 3, 1);

// Board: eigene Spalten per API anlegen (Küche) und Aufgaben einsortieren
await open('Küche');
const apiJSON = (method, url, body) =>
	page.evaluate(
		async ([m, u, b]) => {
			const r = await fetch(`/v1${u}`, { method: m, headers: { 'Content-Type': 'application/json' }, body: b ? JSON.stringify(b) : undefined });
			return r.status === 204 ? null : r.json();
		},
		[method, url, body ?? null]
	);
const kitchen = (await apiJSON('GET', '/projects')).find((p) => p.name === 'Küche');
const cols = {};
for (const [name, color, isDone] of [['Ideen', '#EB8A0A'], ['Geplant', '#2470E0'], ['In Arbeit', '#6B59D9'], ['Erledigt', '#45AE5C', true]]) {
	cols[name] = await apiJSON('POST', `/projects/${kitchen.id}/columns`, { name, color, ...(isDone ? { isDone } : {}) });
}
const kTasks = await apiJSON('GET', `/tasks?projectID=${kitchen.id}`);
const put = (title, col) => {
	const task = kTasks.find((x) => x.title === title);
	return apiJSON('PUT', `/tasks/${task.id}/column`, { version: task.version, columnID: cols[col].id });
};
await put('Neue Kaffeemaschine vergleichen', 'Ideen');
await put('Gewürzregal sortieren', 'Ideen');
await put('Wocheneinkauf erledigen', 'Geplant');
await put('Backofen reinigen', 'In Arbeit');
await put('Spülmaschine ausräumen', 'Erledigt');
// Für-dich-Feed: Rückfragen und Fortschritt an Aufgaben (Demo-Daten, über die Nutzer-API angelegt)
const byTitle = (title) => kTasks.find((x) => x.title === title);
await apiJSON('POST', `/tasks/${byTitle('Backofen reinigen').id}/questions`, {
	prompt: 'Soll ich den Backofen mit Backofenreiniger oder per Dampfreiniger säubern?',
	options: ['Backofenreiniger', 'Dampfreiniger'],
	blocking: true
});
await apiJSON('POST', `/tasks/${byTitle('Neue Kaffeemaschine vergleichen').id}/questions`, {
	prompt: 'Welches Budget gilt für die neue Kaffeemaschine?',
	options: ['bis 150 Euro', 'bis 300 Euro', 'egal'],
	blocking: false
});
await apiJSON('POST', `/tasks/${byTitle('Backofen reinigen').id}/progress-notes`, { note: 'Bleche eingeweicht, Innenraum ist als Nächstes dran.', percent: 40 });
await apiJSON('POST', `/tasks/${byTitle('Gewürzregal sortieren').id}/progress-notes`, { note: 'Erste zwei Regalböden sind sortiert und beschriftet.', percent: 60 });
await page.reload();
await open('Küche');
await page.getByTestId('project-description').fill('Alles rund um die Küche: Einkauf, Reinigung und Anschaffungen.');

// Aufnahmen Desktop
await page.setViewportSize({ width: 1600, height: 900 });
await setView('Board');
await page.getByTestId('board-lane').first().waitFor();
await shot('board');
await page.getByTestId('project-more').click();
await page.getByRole('button', { name: 'Zu Favoriten hinzufügen' }).click();
await shot('seitenleiste', { clip: { x: 0, y: 0, width: 300, height: 900 } });
await desktop();
await setView('Liste');
await page.getByTestId('task-item').filter({ hasText: 'Wocheneinkauf erledigen' }).waitFor();
await shot('projekte-aufgaben', { fullPage: false });
const det = page.getByTestId('task-item').filter({ hasText: 'Wocheneinkauf erledigen' });
if (!(await det.getByTestId('task-detail').isVisible().catch(() => false))) await det.getByRole('button', { name: 'Details' }).click();
await det.getByTestId('task-detail').scrollIntoViewIfNeeded();
await shot('aufgabendetail');

await nav('Heute');
await page.getByTestId('view-heading').waitFor();
await shot('heute');

await nav('Suche');
await page.getByLabel('Suchen in Titeln, Beschreibungen und Projekten').fill('Kontakt');
await page.getByRole('button', { name: 'Suchen', exact: true }).click();
await page.getByTestId('search-hit').first().waitFor();
await page.getByLabel('Name des Filters').fill('Kontaktformular').catch(() => {});
await page.getByRole('button', { name: 'Als Filter speichern' }).click().catch(() => {});
await shot('suche');

// Team und Freigaben
await nav('Teams');
await page.getByLabel('Neues Team').fill('Familie');
await page.getByRole('button', { name: 'Team anlegen' }).click();
await page.getByTestId('team-item').filter({ hasText: 'Familie' }).waitFor();
await shot('teams');
await open('Haushalt');
await page.getByTestId('share-open').click();
await page.getByTestId('share-dialog').waitFor();
await page.getByLabel('Empfänger').selectOption('team');
await page.getByLabel('Team', { exact: true }).selectOption({ label: 'Familie' });
await page.getByRole('button', { name: 'Freigabe hinzufügen' }).click();
await page.getByTestId('grant').first().waitFor();
await shot('freigaben');

// Projektzustand: Kommentare, Aktivität, Agenten
await open('Küche');
await page.getByTestId('project-comments-open').click();
const pc = page.getByTestId('project-comments-dialog');
await pc.getByLabel('Kommentar zum Projekt schreiben').fill('Bitte vor dem Wochenende die Küchenplanung abschließen.');
await pc.getByRole('button', { name: 'Kommentieren' }).click();
await pc.getByTestId('project-comment').first().waitFor();
await shot('projektkommentare');
await closeDialogs();
await nav('Aktivität');
await page.getByTestId('feed-item').first().waitFor();
await shot('aktivitaet');
await nav('Agenten');
await page.getByLabel('Bezeichnung des Geräts').fill('Mac Studio');
await page.getByRole('button', { name: 'Code erzeugen' }).click();
await page.getByTestId('pairing-code').waitFor();
await shot('agenten');

// OAuth-Zustimmung
const reg = await page.request.post('/oauth/register', {
	data: { client_name: 'Claude Code (Demo)', redirect_uris: ['https://client.example/cb'], token_endpoint_auth_method: 'none' },
	headers: { 'Content-Type': 'application/json' }
});
const clientID = (await reg.json()).client_id;
await page.goto(
	`/consent?response_type=code&client_id=${clientID}&redirect_uri=${encodeURIComponent('https://client.example/cb')}` +
		`&scope=${encodeURIComponent('projects:read tasks:read tasks:write comments:write')}&state=demo&code_challenge=${'A'.repeat(43)}&code_challenge_method=S256`
);
await page.getByText('Zugriff erlauben?').first().waitFor();
await page.getByLabel('Website-Relaunch').check().catch(() => {});
await shot('zustimmung');

// Für dich (Startansicht), hell und dunkel
await page.goto('/');
await page.getByTestId('needs-card').first().waitFor();
await page.getByTestId('post-card').first().waitFor();
await page.setViewportSize({ width: 1360, height: 1400 });
await shot('fuer-dich');
await page.emulateMedia({ colorScheme: 'dark' });
await page.waitForTimeout(500);
await shot('fuer-dich-dunkel');
await page.emulateMedia({ colorScheme: 'light' });
await page.waitForTimeout(300);
await desktop();

// Projektansicht: Klassisch (nur Aufgaben) gegenüber Projektmanagement (Reiter, Meilensteine, Überblick)
forceManagement = false;
await page.reload();
await open('Küche');
await setView('Liste');
await page.getByTestId('task-item').filter({ hasText: 'Wocheneinkauf erledigen' }).waitFor();
await shot('projekt-klassisch');
await page.getByTestId('display-menu').click();
await page.getByTestId('mode-management').click();
await page.keyboard.press('Escape');
await page.getByTestId('project-tabs').waitFor();
await shot('projekt-management');
await page.getByTestId('display-menu').click();
await page.getByTestId('mode-classic').click();
await page.keyboard.press('Escape');
await page.getByTestId('project-tabs').waitFor({ state: 'detached' });
forceManagement = true;
await page.reload();

// Konto
await page.goto('/');
await nav('Konto');
await page.getByText('Konto und Sicherheit').first().waitFor();
await shot('konto', { fullPage: true });

// Mobil
await mobile();
await page.goto('/');
const menu = page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name: 'Menü' });
const drawer = page.getByRole('navigation', { name: 'Seitenleiste' });
await menu.click();
await drawer.getByTestId('project-item').getByRole('button', { name: 'Küche', exact: true }).first().waitFor();
await shot('projekte-mobil');
await drawer.getByTestId('project-item').getByRole('button', { name: 'Küche', exact: true }).first().click();
await page.getByTestId('task-heading').filter({ hasText: 'Küche' }).waitFor();
await shot('aufgaben-mobil');
await setView('Board');
await page.getByTestId('board-lane').first().waitFor();
await shot('board-mobil');
await setView('Liste');
const mt = page.getByTestId('task-item').filter({ hasText: 'Wocheneinkauf erledigen' });
if (!(await mt.getByTestId('task-detail').isVisible().catch(() => false))) await mt.getByRole('button', { name: 'Details' }).click();
await mt.getByTestId('task-detail').scrollIntoViewIfNeeded();
await shot('aufgabendetail-mobil');
for (const [name, file] of [['Heute', 'heute-mobil'], ['Suche', 'suche-mobil'], ['Teams', 'teams-mobil'], ['Konto', 'konto-mobil']]) {
	if (['Teams', 'Konto'].includes(name)) {
		await menu.click();
		await drawer.getByRole('button', { name: 'Mehr', exact: true }).click();
		await drawer.getByRole('button', { name, exact: true }).click();
	} else {
		await page.getByRole('navigation', { name: 'Hauptnavigation' }).getByRole('button', { name, exact: true }).click();
	}
	await shot(file);
}

// Mobil: Für dich als erster Tab und geöffnetes Menü innerhalb des Viewports
await page.goto('/');
await page.getByTestId('needs-card').first().waitFor();
await shot('fuer-dich-mobil');
await menu.click();
await drawer.getByTestId('project-item').getByRole('button', { name: 'Küche', exact: true }).first().click();
await page.getByTestId('task-heading').filter({ hasText: 'Küche' }).waitFor();
await page.getByTestId('display-menu').click();
await page.getByRole('dialog', { name: 'Anzeige' }).waitFor();
await shot('menue-mobil');
await page.keyboard.press('Escape');

await browser.close();
