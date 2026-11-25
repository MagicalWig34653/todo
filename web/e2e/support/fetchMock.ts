import type { Page } from '@playwright/test';

/**
 * Answers chosen requests inside the page by wrapping `fetch`, because `page.route` with `fulfill`/`abort` does not reliably see the
 * PWA's requests in WebKit (see recurrence-rules.spec.ts). The rules live in sessionStorage, so they survive a reload and are
 * removed with `clearMocks`. Call `installMocks` once per page (before the navigation that should see them).
 */
export interface MockRule {
	/** Substring of the request URL. */
	url: string;
	method?: string;
	/** Network failure instead of an answer. */
	abort?: boolean;
	status?: number;
	json?: unknown;
	/** The rule ends as soon as a request with this substring in its URL is sent (that request already sees no rule). */
	until?: string;
}
const KEY = 'e2e-fetch-mocks';

export async function installMocks(page: Page): Promise<void> {
	await page.addInitScript((key) => {
		const real = window.fetch.bind(window);
		window.fetch = async (input, init) => {
			const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
			const method = (init?.method ?? (typeof input === 'object' && 'method' in input ? input.method : 'GET')).toUpperCase();
			let rules: { url: string; method?: string; abort?: boolean; status?: number; json?: unknown; until?: string }[] = [];
			try {
				rules = JSON.parse(sessionStorage.getItem(key) ?? '[]');
			} catch {
				/* no rules */
			}
			const left = rules.filter((r) => !(r.until && url.includes(r.until)));
			if (left.length !== rules.length) sessionStorage.setItem(key, JSON.stringify((rules = left)));
			const rule = rules.find((r) => url.includes(r.url) && (!r.method || r.method.toUpperCase() === method));
			if (!rule) return real(input, init);
			if (rule.abort) throw new TypeError('Failed to fetch');
			return new Response(JSON.stringify(rule.json ?? {}), { status: rule.status ?? 200, headers: { 'Content-Type': 'application/json' } });
		};
	}, KEY);
}
/** Replaces the active rules (the page must have been loaded after `installMocks`). */
export const setMocks = (page: Page, rules: MockRule[]) => page.evaluate(([key, value]) => sessionStorage.setItem(key!, value!), [KEY, JSON.stringify(rules)]);
export const clearMocks = (page: Page) => page.evaluate((key) => sessionStorage.removeItem(key), KEY);
