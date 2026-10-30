import { defineConfig } from '@playwright/test';

// Override with E2E_PORT (and BACKEND_URL for the dev proxy) to run beside another stack; RP_ORIGIN of the backend must match.
const port = process.env.E2E_PORT ?? '25173';

// E2E runs against the real backend (docker compose up -d --wait backend, fresh database,
// BOOTSTRAP_TOKEN=dev-bootstrap-only). RP_ORIGIN defaults to http://localhost:25173, so the PWA must use that port.
export default defineConfig({
	testDir: 'e2e',
	workers: 1,
	use: { baseURL: process.env.E2E_BASE_URL ?? `http://localhost:${port}`, browserName: 'chromium' },
	// E2E_BASE_URL: test an already running backend image that serves the PWA itself (no Vite).
	webServer: process.env.E2E_BASE_URL ? undefined : {
		command: `npm run dev -- --port ${port} --strictPort --host localhost`,
		url: `http://localhost:${port}`,
		reuseExistingServer: true
	}
});
