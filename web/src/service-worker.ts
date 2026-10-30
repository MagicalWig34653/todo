/// <reference types="@sveltejs/kit" />
/// <reference lib="webworker" />
import { immutable, assets } from '$app/manifest';
import { version } from '$app/env';

// App-shell caching only. API responses (/v1) and health checks are never cached or intercepted.
const sw = self as unknown as ServiceWorkerGlobalScope;
const CACHE = `shell-${version}`;
const SHELL = [...immutable.map((f) => f.path), ...assets.map((f) => f.path), '/'];

sw.addEventListener('install', (event) => {
	event.waitUntil(
		caches
			.open(CACHE)
			.then((cache) => cache.addAll(SHELL))
			.then(() => sw.skipWaiting())
	);
});

sw.addEventListener('activate', (event) => {
	event.waitUntil(
		caches
			.keys()
			.then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
			.then(() => sw.clients.claim())
	);
});

sw.addEventListener('fetch', (event) => {
	const request = event.request;
	if (request.method !== 'GET') return;
	const url = new URL(request.url);
	if (url.origin !== location.origin) return;
	// Backend-owned paths (API, OAuth, MCP, well-known, health) are served by the backend, never by the shell cache.
	if (['/v1', '/health', '/oauth', '/mcp', '/.well-known', '/apple-app-site-association'].some((p) => url.pathname.startsWith(p))) return;

	if (request.mode === 'navigate') {
		// SPA: network first, fall back to the cached shell when offline.
		event.respondWith(fetch(request).catch(() => caches.match('/').then((r) => r ?? Response.error())));
		return;
	}
	if (SHELL.includes(url.pathname)) {
		event.respondWith(caches.match(request).then((cached) => cached ?? fetch(request)));
	}
});
