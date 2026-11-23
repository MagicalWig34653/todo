import { expect, type Locator, type Page } from '@playwright/test';

/**
 * State of the page around a sidebar step, as one line for an error message. Only counts, flags and the URL path (no query, no
 * texts, names or ids from the page), so it is safe in CI logs. Card 188D611F: the step "Mehr" -> "Teams" of the invitee hung for
 * 90 s in about 2 of 55 Linux runs and the error said nothing about the page.
 */
export async function sidebarState(page: Page, more: Locator, target: Locator): Promise<string> {
	if (page.isClosed()) return 'page closed';
	const probe = async <T>(f: () => Promise<T>): Promise<T | string> => f().catch((e: Error) => `n/a (${e.message.split('\n')[0].slice(0, 60)})`);
	const state = {
		path: await probe(async () => new URL(page.url()).pathname.replace(/[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}/g, ':id')),
		viewport: await probe(async () => `${page.viewportSize()?.width ?? '?'}x${page.viewportSize()?.height ?? '?'}`),
		moreCount: await probe(() => more.count()),
		moreExpanded: await probe(async () => (await more.count()) ? await more.first().getAttribute('aria-expanded') : 'absent'),
		moreEnabled: await probe(async () => (await more.count()) ? await more.first().isEnabled() : 'absent'),
		targetCount: await probe(() => target.count()),
		targetVisible: await probe(() => target.first().isVisible()),
		navs: await probe(() => page.getByRole('navigation').count()),
		openDialogs: await probe(() => page.getByRole('dialog').count()),
		busy: await probe(() => page.locator('[aria-busy="true"]').count()),
		readyState: await probe(() => page.evaluate(() => document.readyState))
	};
	return Object.entries(state).map(([k, v]) => `${k}=${v}`).join(' ');
}

/**
 * Opens a sidebar entry that sits behind the "Mehr" toggle: opens the toggle only while the entry is hidden, retries as a unit and
 * clicks the entry. A failure names every attempt with the state of the page (see `sidebarState`).
 */
export async function openViaMore(page: Page, more: Locator, target: Locator, opts: { timeout?: number; attemptTimeout?: number } = {}): Promise<void> {
	const timeout = opts.timeout ?? 20_000;
	const started = Date.now();
	const attempts: string[] = [];
	try {
		await expect(async () => {
			const before = await sidebarState(page, more, target);
			attempts.push(`#${attempts.length + 1} +${Date.now() - started}ms before: ${before}`);
			if (!(await target.isVisible())) await more.click({ timeout: opts.attemptTimeout ?? 3000 });
			await expect(target).toBeVisible({ timeout: opts.attemptTimeout ?? 1500 });
		}).toPass({ timeout });
	} catch (e) {
		const after = await sidebarState(page, more, target);
		throw new Error(`sidebar step failed after ${Date.now() - started}ms\n${attempts.slice(-5).join('\n')}\nafter: ${after}\ncause: ${(e as Error).message.split('\n')[0]}`);
	}
	await target.click();
}
