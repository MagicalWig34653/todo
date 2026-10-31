import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { readFileSync } from 'node:fs';
import { defineConfig } from 'vitest/config';

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as { version: string };

export default defineConfig({
	define: { __APP_VERSION__: JSON.stringify(pkg.version) },
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			adapter: adapter({ fallback: 'index.html' })
		})
	],
	server: {
		proxy: {
			'/health': process.env.BACKEND_URL ?? 'http://127.0.0.1:28080',
			'/oauth/': process.env.BACKEND_URL ?? 'http://127.0.0.1:28080',
			'/v1': process.env.BACKEND_URL ?? 'http://127.0.0.1:28080'
		}
	},
	test: { include: ['tests/**/*.test.ts'] }
});
