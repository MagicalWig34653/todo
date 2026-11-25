import { expect, type APIRequestContext, type Page, type Route } from '@playwright/test';
import { createHash } from 'node:crypto';

/**
 * Realistic data for the page "Jetzt", shaped like a busy account: coloured projects, more than five waiting questions and
 * reviews (multi-line Markdown, long titles), running cards with percent and due dates (one overdue), sessions, done cards
 * and several files per build. Everything is created through the real API. The API cannot age a sign of life, so the entry
 * without one and the quiet projects are produced by rewriting the overview answer in the browser (`rewriteOverview`).
 */
export const NOW_SEED = {
	longTitle: 'Mehrstufige Freigaben für verschachtelte Projekte mit Teamrollen, Vererbung und Ausnahmen je Unterprojekt prüfen',
	longQuestion:
		'**Wie soll die Anmeldung weiterlaufen?**\n\n- Variante A: Passkey zuerst, `E-Mail` nur als Rückfall\n- Variante B: beide gleichberechtigt nebeneinander\n- Variante C: nur Passkey, Rückfall über Wiederherstellungscodes\n\nBitte eine Variante wählen, davon hängt der nächste Schritt ab.',
	/** Waiting entries created by the seed (questions + reviews). */
	waiting: 9,
	/** Cards with a claim and a fresh note, plus reported sessions. */
	runningTasks: 4,
	sessions: 3,
	done: 6
} as const;

const PNG_1X1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const json = { headers: { 'Content-Type': 'application/json' } };
const DAY = 24 * 3600 * 1000;

export interface NowIds {
	projects: Record<'todolino' | 'apple' | 'form' | 'orchestrator' | 'thermo' | 'portal' | 'recipes' | 'weather' | 'ideas' | 'archive', string>;
	tasks: Record<'passkey' | 'calendar' | 'limit' | 'runner' | 'question' | 'long', string>;
}

export async function seedNow(page: Page, helper: APIRequestContext): Promise<NowIds> {
	async function call<T>(method: 'post' | 'put' | 'patch', path: string, data: unknown): Promise<T> {
		const r = await page.request[method](path, { ...json, data });
		expect(r.status(), `${method} ${path}: ${await r.text()}`).toBeLessThan(300);
		return (await r.json().catch(() => ({}))) as T;
	}
	const project = async (name: string, color?: string, parentID?: string) =>
		(await call<{ id: string }>('post', '/v1/projects', { name, color, parentID })).id;
	const task = async (projectID: string, title: string) => (await call<{ id: string }>('post', '/v1/tasks', { projectID, title })).id;
	const claim = (id: string, agentName: string) => call('post', `/v1/tasks/${id}/claim`, { agentName });
	const note = (id: string, text: string, percent?: number) => call('post', `/v1/tasks/${id}/progress-notes`, { note: text, percent });
	const ask = async (projectID: string, title: string, prompt: string) => {
		const id = await task(projectID, title);
		await call('post', `/v1/tasks/${id}/questions`, { prompt, options: ['Ja', 'Nein'], blocking: false });
		return id;
	};
	const review = async (projectID: string, title: string, summary: string) => {
		const id = await task(projectID, title);
		await call('post', `/v1/tasks/${id}/review`, { summary });
		return id;
	};
	const session = (projectID: string, sessionName: string, activity: string) =>
		call('put', `/v1/projects/${projectID}/session-status`, { sessionName, activity });
	const due = (id: string, offset: number) =>
		call('put', `/v1/planning/tasks/${id}`, { priority: 0, reminders: [], plannedAt: null, dueAt: new Date(Date.now() + offset).toISOString() });
	const file = async (taskID: string, filename: string, build: { buildID: string; label?: string; platform?: string; status?: string; commit?: string }) => {
		const checksum = createHash('sha256').update(PNG_1X1).digest('hex');
		const cap = await call<{ attachmentID: string; uploadURL: string; token: string }>('post', '/v1/attachments/begin', {
			taskID, filename, role: 'result', mediaType: 'image/png', size: PNG_1X1.length, checksum
		});
		const put = await helper.put(cap.uploadURL, { headers: { 'Content-Type': 'application/octet-stream', Authorization: `Bearer ${cap.token}` }, data: PNG_1X1 });
		expect(put.status(), await put.text()).toBeLessThan(300);
		await call('post', `/v1/attachments/${cap.attachmentID}/complete`, {});
		await call('post', '/v1/builds', { attachmentID: cap.attachmentID, ...build });
	};

	const todolino = await project('Todolino', '#2470E0');
	const apple = await project('Apple-App', '#6B59D9', todolino);
	const form = await project('Formular-Backend', '#45AE5C');
	const orchestrator = await project('Orchestrator', '#EB8A0A');
	const thermo = await project('Thermoctl', '#29ABAB');
	const portal = await project('Kundenportal', '#E05290');
	const recipes = await project('Rezeptbuch', '#B852C7');
	const weather = await project('Wetterstation', '#C2A61A');
	const ideas = await project('Ideen', '#737378');
	const archive = await project('Altes Archiv');
	await task(ideas, 'Irgendwann: Widgets');
	await task(archive, 'Aufgeräumt');

	// Done cards first, so that the running work below is the newest activity.
	for (const [p, title] of [
		[todolino, 'Kurz-IDs in der Aufgabenliste anzeigen'], [form, 'Spam-Filter für das Kontaktformular'], [apple, 'Widget-Zeitleiste aktualisieren'],
		[orchestrator, 'Protokolle nach 14 Tagen aufräumen'], [thermo, 'Frostschutz-Schwelle konfigurierbar machen'], [todolino, 'Wiederholungsregeln mit Wochentagen']
	] as const) {
		const id = await task(p, title);
		await call('patch', `/v1/tasks/${id}`, { version: 1, status: 'done' });
	}

	// Waiting for the user: four questions, five reviews.
	const question = await ask(todolino, 'Anmeldung und Rückfall festlegen', NOW_SEED.longQuestion);
	await ask(orchestrator, 'Runner-Bindings', 'Soll der Runner bei erschöpftem Kontingent pausieren?');
	await ask(apple, 'Push-Berechtigung erklären', 'Welcher Text soll vor der Systemabfrage stehen?\n1. kurz\n2. mit Beispiel');
	await ask(thermo, 'Zeitplan Wochenende', 'Gilt der **Wochenendplan** auch an Feiertagen?');
	const long = await review(todolino, NOW_SEED.longTitle,
		'**Neu:** Freigaben je Unterprojekt\n- Rollen erben nach unten, Ausnahmen je Knoten\n- Übersicht unter `/v1/projects/{id}/visibility`\n- Doku: https://example.invalid/sehr/langer/pfad/ohne/jede/umbruchstelle/freigaben-und-vererbung-teil-zwei\n- 214 Tests grün');
	await review(form, 'Rate-Limit je Mandant', '## Rate-Limit fertig\n* 60 Anfragen je Minute\n* Antwort 429 mit `Retry-After`');
	await review(portal, 'Rechnungsansicht', 'Rechnungen lassen sich als PDF herunterladen.');
	await review(recipes, 'Einkaufsliste teilen', '**Geprüft:** Teilen per Link, Ablauf nach 7 Tagen. [Beschreibung](https://example.invalid/liste) ansehen.');
	await review(apple, 'Kalender Wochenansicht', 'Wochenansicht auf dem iPad fertig, bitte Bilder ansehen.');

	// Builds: several files per build.
	const shots = await task(todolino, 'Bildschirmfotos zur Wochenansicht');
	const web = { buildID: '564a6b4', label: 'Web 564a6b4', platform: 'web', commit: '564a6b4' };
	await file(shots, 'woche-hell.png', { ...web, status: 'building' });
	await file(shots, 'woche-dunkel.png', { ...web, status: 'succeeded' });
	await file(shots, 'woche-schmal.png', web);
	await file(shots, 'ios-start.png', { buildID: 'ios-42', label: 'iOS 42', platform: 'ios', status: 'failed' });
	await file(shots, 'ios-liste.png', { buildID: 'ios-42', label: 'iOS 42', platform: 'ios' });
	const formShots = await task(form, 'Fehlerseite prüfen');
	await file(formShots, 'fehler.png', { buildID: 'form-18', label: 'Formular 18', platform: 'web', status: 'succeeded' });
	await file(formShots, 'erfolg.png', { buildID: 'form-18', label: 'Formular 18', platform: 'web' });

	// Running work with percent and due dates (one overdue).
	const passkey = await task(todolino, 'Passkey-Anmeldung absichern');
	await claim(passkey, 'Claude Opus');
	for (const [text, percent] of [['Fehlerfälle gesammelt', 10], ['Tests für den Rückfall geschrieben', 25], ['Server prüft die Herkunft', 35], ['Wiederholungsschutz ergänzt', 45], ['Oberfläche zeigt klare Meldungen', 50]] as const) await note(passkey, text, percent);
	await note(passkey, 'Rückfall geschrieben, Tests laufen gerade in allen drei Browsern. Als Nächstes die Meldungen für abgelaufene Anfragen und die Dokumentation der neuen Grenzen.', 60);
	await due(passkey, 2 * DAY);
	const calendar = await task(apple, 'Konflikte in der Wochenansicht anzeigen');
	await claim(calendar, 'Claude Sonnet');
	await note(calendar, 'Überschneidungen werden erkannt, Darstellung folgt.', 35);
	await due(calendar, -2 * DAY - 3600_000);
	const limit = await task(form, 'Anhänge im Kontaktformular auf Schadsoftware prüfen und große Dateien verständlich ablehnen');
	await claim(limit, 'Codex');
	await note(limit, 'Prüfdienst angebunden.\nGrößenlimit greift.\nMeldungen fehlen noch.', 80);
	const runner = await task(orchestrator, 'Wiederaufnahme nach Neustart');
	await claim(runner, 'Claude Sonnet');
	await note(runner, 'Offene Läufe werden beim Start wiedergefunden.');

	await session(todolino, 'web-redesign', 'Überarbeitet die Seite „Jetzt“ und nimmt Bilder auf');
	await session(thermo, 'backend-regelung', 'Prüft die Hysterese mit aufgezeichneten Messwerten');
	await session(orchestrator, 'nachtlauf', 'Sammelt Testergebnisse der letzten Nacht');

	return {
		projects: { todolino, apple, form, orchestrator, thermo, portal, recipes, weather, ideas, archive },
		tasks: { passkey, calendar, limit, runner, question, long }
	};
}

export interface Rewrite {
	/** Add one session without a sign of life for 47 minutes (default true). */
	silent: boolean;
	/** Count this many more waiting entries than are delivered. */
	extraWaiting: number;
	/** Answer like a server without the field `now`. */
	oldServer: boolean;
	/** Nothing running, waiting, done or silent (the projects stay). */
	emptyBlock: boolean;
}
export const defaultRewrite = (): Rewrite => ({ silent: true, extraWaiting: 0, oldServer: false, emptyBlock: false });

/** Installs the rewrite of `GET /v1/overview/now`; the returned object is read on every request. */
export async function rewriteOverview(page: Page, ids: NowIds): Promise<Rewrite> {
	const state = defaultRewrite();
	await page.route('**/v1/overview/now', async (route: Route) => {
		const res = await route.fetch();
		if (res.status() !== 200) return route.fulfill({ response: res });
		const body = await res.json();
		const quiet = [ids.projects.ideas, ids.projects.archive, ids.projects.weather];
		for (const p of body.projects ?? []) if (quiet.includes(p.projectID)) p.lastActivityAt = new Date(Date.now() - 3 * DAY).toISOString();
		if (body.now) {
			if (state.silent) {
				body.now.silent.push({
					kind: 'session', projectID: ids.projects.apple, projectName: 'Apple-App', title: 'ios-build', text: 'Wartet auf die Signierung', worker: null,
					lastSignAt: new Date(Date.now() - 47 * 60_000).toISOString(), ageSeconds: 47 * 60
				});
				body.now.counts.silent = body.now.silent.length;
			}
			body.now.counts.waiting += state.extraWaiting;
			if (state.emptyBlock) body.now = { counts: { running: 0, waiting: 0, recentlyDone: 0, silent: 0 }, running: [], waiting: [], recentlyDone: [], silent: [] };
		}
		if (state.oldServer) delete body.now;
		await route.fulfill({ response: res, json: body });
	});
	return state;
}
