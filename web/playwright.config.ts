import { defineConfig } from '@playwright/test';

// E2E runs against the real backend (docker compose up -d --wait backend, fresh database,
// BOOTSTRAP_TOKEN=dev-bootstrap-only). RP_ORIGIN defaults to http://localhost:25173, so the PWA must use that port.
export default defineConfig({
	testDir: 'e2e',
	workers: 1,
	use: { baseURL: 'http://localhost:25173', browserName: 'chromium' },
	webServer: {
		command: 'npm run dev -- --port 25173 --strictPort --host localhost',
		url: 'http://localhost:25173',
		reuseExistingServer: true
	}
});
