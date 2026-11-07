import { defineConfig, devices } from '@playwright/test';

// Override with E2E_PORT (and BACKEND_URL for the dev proxy) to run beside another stack; RP_ORIGIN of the backend must match.
const port = process.env.E2E_PORT ?? '25173';

// E2E runs against the real backend (docker compose up -d --wait backend, fresh database,
// BOOTSTRAP_TOKEN=dev-bootstrap-only). RP_ORIGIN defaults to http://localhost:25173, so the PWA must use that port.
export default defineConfig({
	testDir: 'e2e',
	workers: 1,
	use: { baseURL: process.env.E2E_BASE_URL ?? `http://localhost:${port}` },
	// Chromium is the default and the only browser CI runs today. Select others with `npx playwright test --project=webkit`
	// after `npx playwright install firefox webkit`. Specs that use e2e/support/session.ts (for-you, freetext-review,
	// task-graph, oauth-consent, attachment-upload) also run in Firefox/WebKit: the account is created in a helper Chromium
	// (CDP virtual authenticator) and its session cookie is handed over. Other specs still need Chromium and skip elsewhere.
	// The specs share one stateful backend, so run one project at a time (fresh database per project).
	projects: [
		{ name: 'chromium', use: { browserName: 'chromium' } },
		{ name: 'firefox', use: { browserName: 'firefox' } },
		{ name: 'webkit', use: { browserName: 'webkit' } },
		// Mobile emulation (viewport, touch, user agent; not real devices). mobile-safari is WebKit, mobile-chrome is Chromium.
		{ name: 'mobile-safari', use: { ...devices['iPhone 14'] } },
		{ name: 'mobile-chrome', use: { ...devices['Pixel 7'] } }
	],
	// E2E_BASE_URL: test an already running backend image that serves the PWA itself (no Vite).
	webServer: process.env.E2E_BASE_URL ? undefined : {
		command: `npm run dev -- --port ${port} --strictPort --host localhost`,
		url: `http://localhost:${port}`,
		reuseExistingServer: true
	}
});
