// Walks the five most frequent tasks through the current PWA and counts clicks/taps (typing and scrolling not counted;
// scrolling is reported as "screens"). Same setup as aufnahme.spec.ts, fresh database. Output: klickwege.json.
import { test, expect, type Locator } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { signedInPage } from './support/session';
import { seedNow } from './support/nowSeed';

test('Klickwege', async ({ browser, playwright }) => {
	test.setTimeout(300_000);
	const page = await signedInPage(browser, 'Demo Person');
	const ids = await seedNow(page, await playwright.request.newContext());
	const out: Record<string, unknown>[] = [];
	for (const [device, viewport] of [['desktop', { width: 1280, height: 800 }], ['handy', { width: 390, height: 844 }]] as const) {
		await page.setViewportSize(viewport);
		const phone = device === 'handy';
		const walk = async (task: string, start: string, steps: [string, () => Locator][]) => {
			await page.goto(start);
			await page.waitForTimeout(1500);
			const log: string[] = [];
			try {
				for (const [name, loc] of steps) {
					const l = loc();
					await l.waitFor({ timeout: 6000 });
					const box = await l.boundingBox();
					const screens = box ? Math.max(0, Math.floor(box.y / viewport.height)) : 0;
					await l.click({ timeout: 6000 });
					log.push(screens ? `${name} (nach ${screens} Bildschirm(en) Scrollen)` : name);
					await page.waitForTimeout(600);
				}
				out.push({ device, task, clicks: log.length, steps: log });
			} catch (e) {
				out.push({ device, task, failedAfter: log, error: String(e).slice(0, 300) });
			}
		};
		const btn = (name: string | RegExp) => () => page.getByRole('button', { name, exact: typeof name === 'string' }).first();
		const menu: [string, () => Locator][] = phone ? [['Tableiste „Menü“', () => page.getByRole('navigation', { name: /Haupt/ }).getByRole('button').last()]] : [];
		const nav = (label: string): [string, () => Locator] => [`Seitenleiste „${label}“`, () => page.locator('#main-nav').getByRole('button', { name: new RegExp(`^${label}`) }).first()];
		const open: [string, () => Locator] = phone ? ['Plus-Knopf', () => page.getByTestId('fab')] : ['„Aufgabe hinzufügen“', () => page.getByTestId('quick-add-open')];
		await walk('1 Karte anlegen (im offenen Projekt)', `/project/${ids.projects.todolino}/list`, [
			open,
			['Titel tippen, „Aufgabe hinzufügen“', () => { void page.keyboard.type(`Neue Karte ${device}`); return page.getByRole('dialog').getByRole('button', { name: 'Aufgabe hinzufügen' }); }],
			['„Fertig“ (Dialog bleibt sonst offen)', () => page.getByRole('dialog').getByRole('button', { name: 'Fertig' })]
		]);
		await walk('2 Frage beantworten (Start, Option)', '/for-you', [['Option „Ja“ auf „Für dich“', () => page.getByTestId('for-you').getByRole('button', { name: 'Ja', exact: true }).first()]]);
		await walk('2b Frage beantworten (über Überblick)', '/for-you', [...menu, nav('Überblick'), ['Reiter „Offene Fragen“', () => page.getByRole('tab', { name: /Offene Fragen/ })], ['Option „Ja“', () => page.getByRole('tabpanel').getByRole('button', { name: 'Ja', exact: true }).first()]]);
		await walk('3 Review entscheiden (über Überblick)', '/for-you', [...menu, nav('Überblick'), ['Reiter „Reviews“', () => page.getByRole('tab', { name: /Reviews/ })], ['„Freigeben“', () => page.getByTestId('review-accept').first()]]);
		await walk('4 Projekt wechseln', '/for-you', [...menu, ['Projekt „Wetterstation“ bzw. „Rezeptbuch“', () => page.locator('#main-nav').getByRole('button', { name: /^Rezeptbuch/ }).first()]]);
		await walk('5 Einstellung: Brain-Vollmacht', '/for-you', [['Konto-Menü', () => page.getByTestId('account-menu').first()], ['„Einstellungen“', () => page.getByTestId('menu-settings')], ['Eintrag „Brain-Vollmacht“', () => page.getByRole('main').getByRole('link', { name: /^Brain-Vollmacht/ }).or(page.getByRole('main').getByRole('button', { name: /^Brain-Vollmacht/ })).first()]]);
		await walk('5b Einstellung: Projektgruppen eines Projekts', `/project/${ids.projects.todolino}/list`, [['Projektmenü „…“', () => page.getByTestId('project-more').first()], ['„Projektgruppen“', () => page.getByTestId('project-groups-open')]]);
		// Evidence: how far down the first review and the projects are.
		await page.goto('/for-you');
		await page.waitForTimeout(2000);
		const cards = await page.locator('[data-testid=needs-card]').evaluateAll((els) => els.map((e) => ({ kind: e.getAttribute('data-kind'), y: Math.round(e.getBoundingClientRect().y), buttons: [...e.querySelectorAll('button')].slice(1).map((b) => b.textContent?.trim()).filter(Boolean) })));
		out.push({ device, task: 'Für dich: Karten', cards });
		await page.screenshot({ path: `../design/ux-konzept/ist/fuer-dich-ganz-${device}-hell.jpg`, type: 'jpeg', quality: 60, fullPage: true });
	}
	writeFileSync('../design/ux-konzept/ist/klickwege.json', JSON.stringify(out, null, 1));
	expect(out.length).toBeGreaterThan(10);
});
