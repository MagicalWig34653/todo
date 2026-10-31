import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { backoffDelay, createLiveRefresh, type LiveEnv } from '../src/lib/liveRefresh';

type Handler = () => void;
function fakeDoc(visible = true) {
	const handlers = new Map<string, Handler[]>();
	const doc = {
		visibilityState: visible ? 'visible' : 'hidden',
		activeElement: null as unknown,
		menu: false,
		addEventListener(n: string, h: Handler) { handlers.set(n, [...(handlers.get(n) ?? []), h]); },
		removeEventListener(n: string, h: Handler) { handlers.set(n, (handlers.get(n) ?? []).filter((x) => x !== h)); },
		querySelector() { return doc.menu ? {} : null; },
		fire(n: string) { for (const h of handlers.get(n) ?? []) h(); },
		count() { return [...handlers.values()].reduce((a, b) => a + b.length, 0); },
		show(v: boolean) { doc.visibilityState = v ? 'visible' : 'hidden'; doc.fire('visibilitychange'); }
	};
	return doc;
}

const json = (status: number, body?: unknown, headers: Record<string, string> = {}) =>
	new Response(body === undefined ? null : JSON.stringify(body), { status, headers });

interface Call { url: string; headers: Record<string, string>; signal?: AbortSignal | null }
/** Scripted backend: `routes` maps a path prefix to a queue of handlers; the last handler repeats. */
function fakeServer(routes: Record<string, Array<(c: Call) => Promise<Response> | Response>>) {
	const calls: Call[] = [];
	const idx: Record<string, number> = {};
	const fetchFn: LiveEnv['fetch'] = async (url, init) => {
		const call: Call = { url, headers: (init?.headers ?? {}) as Record<string, string>, signal: init?.signal };
		calls.push(call);
		const key = Object.keys(routes).find((k) => url.startsWith(k))!;
		const list = routes[key];
		const i = Math.min(idx[key] ?? 0, list.length - 1);
		idx[key] = (idx[key] ?? 0) + 1;
		return list[i](call);
	};
	return { calls, fetchFn, count: (p: string) => calls.filter((c) => c.url.startsWith(p)).length };
}
/** A long poll that stays open until aborted (like an idle server). */
const hang = (c: Call) => new Promise<Response>((_, rej) => c.signal?.addEventListener('abort', () => rej(new Error('aborted'))));
const caps = (live = true) => () => json(200, live ? { liveRefresh: { head: true, wait: true, stream: false, pollSeconds: 5, waitMaxSeconds: 25 } } : { passkey: true });

let doc: ReturnType<typeof fakeDoc>;
beforeEach(() => { vi.useFakeTimers(); doc = fakeDoc(); });
afterEach(() => { vi.useRealTimers(); });

function make(server: ReturnType<typeof fakeServer>, extra: Partial<LiveEnv> = {}) {
	return createLiveRefresh({ fetch: server.fetchFn, doc: doc as never, locks: null, channel: null, random: () => 1, onUnauthorized: vi.fn(), ...extra });
}
const tick = (ms = 0) => vi.advanceTimersByTimeAsync(ms);

describe('backoff', () => {
	it('doubles to a 30 s cap with jitter between half and full', () => {
		expect([1, 2, 3, 4, 5, 6, 9].map((n) => backoffDelay(n, () => 1))).toEqual([1000, 2000, 4000, 8000, 16000, 30000, 30000]);
		expect(backoffDelay(3, () => 0)).toBe(2000);
	});
});

describe('long-poll loop', () => {
	it('reads the baseline token, waits with since/timeout, refreshes on change and waits again with the new token', async () => {
		let n = 0;
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { cursor: 'c1', token: 'l1.1.1' })],
			'/v1/sync/wait': [
				() => json(200, { token: 'l1.2.1', changed: true, cursor: 'c2' }),
				(c) => { n++; return hang(c); }
			]
		});
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick();
		expect(live.mode).toBe('live');
		expect(server.calls.filter((c) => c.url.startsWith('/v1/sync/wait'))[0].url).toBe('/v1/sync/wait?since=l1.1.1&timeout=25');
		expect(fn).toHaveBeenCalledTimes(1);
		expect(server.calls.filter((c) => c.url.startsWith('/v1/sync/wait'))[1].url).toBe('/v1/sync/wait?since=l1.2.1&timeout=25');
		expect(n).toBe(1);
		live.stop();
	});
	it('re-waits at once on changed:false without notifying', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 't', cursor: 'c' })],
			'/v1/sync/wait': [
				async () => { await new Promise((r) => setTimeout(r, 25_000)); return json(200, { token: 't', changed: false, cursor: 'c' }); },
				hang
			]
		});
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick(25_001);
		expect(server.count('/v1/sync/wait')).toBe(2);
		expect(fn).not.toHaveBeenCalled();
		live.stop();
	});
	it('honours retryAfter from a shutting-down server', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 't', cursor: 'c' })],
			'/v1/sync/wait': [() => json(200, { token: 't', changed: false, cursor: 'c', retryAfter: 2 }), hang]
		});
		const live = make(server);
		live.start();
		await tick(1_000);
		expect(server.count('/v1/sync/wait')).toBe(1);
		await tick(1_100);
		expect(server.count('/v1/sync/wait')).toBe(2);
		live.stop();
	});
	it('backs off after errors, checks head with If-None-Match every 5 s meanwhile and notices changes there', async () => {
		let waits = 0;
		let heads = 0;
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [
				() => json(200, { token: 'a', cursor: 'c' }),
				() => json(304),
				() => json(200, { token: 'b', cursor: 'c' })
			],
			'/v1/sync/wait': [() => { waits++; return json(503); }, () => { waits++; return json(503); }, hang]
		});
		void heads;
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick(0);
		expect(waits).toBe(1); // first failure -> 1 s backoff
		await tick(1_000);
		expect(waits).toBe(2); // second failure -> 2 s backoff
		await tick(2_000);
		expect(server.count('/v1/sync/wait')).toBe(3);
		expect(server.calls.filter((c) => c.url.startsWith('/v1/sync/head'))[1]?.headers['If-None-Match']).toBeUndefined();
		live.stop();
	});
	it('sends If-None-Match during a long backoff and notifies when head shows a new token', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a', cursor: 'c' }), () => json(304), () => json(200, { token: 'b', cursor: 'c' })],
			'/v1/sync/wait': [() => json(429, undefined, { 'Retry-After': '20' }), hang]
		});
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick(0);
		await tick(5_000);
		const heads = server.calls.filter((c) => c.url.startsWith('/v1/sync/head'));
		expect(heads[1].headers['If-None-Match']).toBe('"a"');
		expect(fn).not.toHaveBeenCalled();
		await tick(5_000);
		expect(fn).toHaveBeenCalledTimes(1);
		await tick(10_100);
		expect(server.count('/v1/sync/wait')).toBe(2);
		live.stop();
	});
	it('treats a 35 s client timeout as an error and retries', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a', cursor: 'c' })],
			'/v1/sync/wait': [hang]
		});
		const live = make(server);
		live.start();
		await tick(35_001);
		expect(server.count('/v1/sync/wait')).toBe(1);
		await tick(1_000);
		expect(server.count('/v1/sync/wait')).toBe(2);
		live.stop();
	});
	it('401 ends the loop and reports the lost session', async () => {
		const onUnauthorized = vi.fn();
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a', cursor: 'c' })],
			'/v1/sync/wait': [() => json(401)]
		});
		const live = make(server, { onUnauthorized });
		live.start();
		await tick(60_000);
		expect(onUnauthorized).toHaveBeenCalledTimes(1);
		expect(server.count('/v1/sync/wait')).toBe(1);
		expect(live.mode).toBe('unauthorized');
	});
	it('404 on wait falls back to 5 s polling of the subscribers', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a', cursor: 'c' })],
			'/v1/sync/wait': [() => json(404)]
		});
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick(0);
		expect(live.mode).toBe('poll');
		await tick(5_000);
		expect(fn).toHaveBeenCalledTimes(1);
		await tick(10_000);
		expect(fn).toHaveBeenCalledTimes(3);
		live.stop();
	});
});

describe('429 and fallback', () => {
	it('waits Retry-After on 429 before trying again', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a' })],
			'/v1/sync/wait': [() => json(429, undefined, { 'Retry-After': '7' }), hang]
		});
		const live = make(server);
		live.start();
		await tick(6_000);
		expect(server.count('/v1/sync/wait')).toBe(1);
		await tick(1_500);
		expect(server.count('/v1/sync/wait')).toBe(2);
		live.stop();
	});
	it('without liveRefresh in the capabilities: plain 5 s polling, only while visible', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps(false)] });
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick(0);
		expect(live.mode).toBe('poll');
		await tick(5_000);
		expect(fn).toHaveBeenCalledTimes(1);
		doc.show(false);
		await tick(20_000);
		expect(fn).toHaveBeenCalledTimes(1);
		doc.show(true);
		await tick(0);
		expect(fn).toHaveBeenCalledTimes(2);
		expect(server.count('/v1/sync')).toBe(0);
		live.stop();
	});
	it('a failing capabilities request also falls back to polling', async () => {
		const server = fakeServer({ '/v1/capabilities': [() => json(500)] });
		const live = make(server);
		live.start();
		await tick(0);
		expect(live.mode).toBe('poll');
		live.stop();
	});
});

describe('bundling', () => {
	it('runs subscribers at most once per second and coalesces hints', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick();
		live.poke();
		live.poke();
		live.poke();
		expect(fn).toHaveBeenCalledTimes(1);
		await tick(1_000);
		expect(fn).toHaveBeenCalledTimes(2);
		await tick(5_000);
		expect(fn).toHaveBeenCalledTimes(2);
		live.stop();
	});
	it('runs a subscriber again after it finished when a hint arrived meanwhile, and swallows errors', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		let release!: () => void;
		let calls = 0;
		live.subscribe(() => { calls++; return new Promise<void>((_, rej) => { release = () => rej(new Error('boom')); }); });
		live.start();
		await tick();
		live.poke();
		await tick(1_100);
		live.poke();
		await tick(1_100);
		expect(calls).toBe(1);
		release();
		await tick(10);
		expect(calls).toBe(2);
		live.stop();
	});
	it('defers while a drag or an open menu is active', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick();
		doc.fire('dragstart');
		live.poke();
		await tick(3_000);
		expect(fn).not.toHaveBeenCalled();
		doc.fire('dragend');
		await tick(1_100);
		expect(fn).toHaveBeenCalledTimes(1);
		doc.menu = true;
		await tick(1_100);
		live.poke();
		await tick(2_000);
		expect(fn).toHaveBeenCalledTimes(1);
		doc.menu = false;
		await tick(1_100);
		expect(fn).toHaveBeenCalledTimes(2);
		live.stop();
	});
	it('guardEditing subscribers wait while a text field holds input', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		const guarded = vi.fn();
		const free = vi.fn();
		live.subscribe(guarded, { guardEditing: true });
		live.subscribe(free);
		live.start();
		await tick();
		doc.activeElement = { tagName: 'INPUT', type: 'text', value: 'half typed' };
		live.poke();
		await tick(2_000);
		expect(free).toHaveBeenCalledTimes(1);
		expect(guarded).not.toHaveBeenCalled();
		doc.activeElement = null;
		await tick(1_100);
		expect(guarded).toHaveBeenCalledTimes(1);
		live.stop();
	});
});

describe('visibility and lifecycle', () => {
	it('stops waiting when hidden, then checks head at once and refreshes if the token moved', async () => {
		const server = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a' }), () => json(200, { token: 'b' })],
			'/v1/sync/wait': [hang]
		});
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick();
		expect(live.leading).toBe(true);
		const first = server.calls.find((c) => c.url.startsWith('/v1/sync/wait'))!;
		doc.show(false);
		expect(first.signal?.aborted).toBe(true);
		expect(live.leading).toBe(false);
		await tick(60_000);
		expect(server.count('/v1/sync/wait')).toBe(1);
		doc.show(true);
		await tick();
		expect(server.count('/v1/sync/head')).toBe(2);
		expect(fn).toHaveBeenCalledTimes(1);
		expect(server.count('/v1/sync/wait')).toBe(2);
		live.stop();
	});
	it('does not start the loop in a hidden tab until it becomes visible', async () => {
		doc = fakeDoc(false);
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		live.start();
		await tick(10_000);
		expect(server.count('/v1/sync/wait')).toBe(0);
		doc.show(true);
		await tick();
		expect(server.count('/v1/sync/wait')).toBe(1);
		live.stop();
	});
	it('stop() aborts the wait, removes listeners and ignores later events (logout)', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		const fn = vi.fn();
		live.subscribe(fn);
		live.start();
		await tick();
		const wait = server.calls.find((c) => c.url.startsWith('/v1/sync/wait'))!;
		live.stop();
		expect(wait.signal?.aborted).toBe(true);
		expect(doc.count()).toBe(0);
		live.poke();
		await tick(60_000);
		expect(fn).not.toHaveBeenCalled();
		expect(server.count('/v1/sync/wait')).toBe(1);
	});
	it('start() twice runs exactly one loop', async () => {
		const server = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const live = make(server);
		live.start();
		live.start();
		await tick();
		expect(server.count('/v1/capabilities')).toBe(1);
		expect(server.count('/v1/sync/wait')).toBe(1);
		live.stop();
	});
});

describe('tab leader', () => {
	/** Minimal Web Locks + BroadcastChannel shared by several fake tabs. */
	function browser() {
		const queue: Array<{ cb: () => Promise<unknown>; signal?: AbortSignal; resolve: () => void }> = [];
		let held = false;
		const pump = async () => {
			if (held) return;
			const next = queue.shift();
			if (!next) return;
			if (next.signal?.aborted) return pump();
			held = true;
			try { await next.cb(); } finally { held = false; next.resolve(); void pump(); }
		};
		const locks = {
			request(_n: string, o: { signal?: AbortSignal }, cb: () => Promise<unknown>) {
				return new Promise<void>((resolve, reject) => {
					queue.push({ cb, signal: o.signal, resolve });
					o.signal?.addEventListener('abort', () => { const i = queue.findIndex((q) => q.cb === cb); if (i >= 0) { queue.splice(i, 1); reject(new Error('abort')); } });
					void pump();
				});
			}
		};
		const chans: Array<{ onmessage: ((e: { data: unknown }) => void) | null }> = [];
		const channel = () => {
			const ch = { onmessage: null as ((e: { data: unknown }) => void) | null,
				postMessage(d: unknown) { for (const o of chans) if (o !== ch) o.onmessage?.({ data: d }); },
				close() { chans.splice(chans.indexOf(ch), 1); } };
			chans.push(ch);
			return ch;
		};
		return { locks, channel };
	}
	it('only one of two tabs waits; the other is notified over the channel and takes over when the leader hides', async () => {
		const b = browser();
		const docA = fakeDoc();
		const docB = fakeDoc();
		const serverA = fakeServer({
			'/v1/capabilities': [caps()],
			'/v1/sync/head': [() => json(200, { token: 'a' })],
			'/v1/sync/wait': [(c) => { return new Promise<Response>((res, rej) => { c.signal?.addEventListener('abort', () => rej(new Error('x'))); setTimeout(() => res(json(200, { token: 'b', changed: true })), 3_000); }); }, hang]
		});
		const serverB = fakeServer({ '/v1/capabilities': [caps()], '/v1/sync/head': [() => json(200, { token: 'a' })], '/v1/sync/wait': [hang] });
		const A = createLiveRefresh({ fetch: serverA.fetchFn, doc: docA as never, locks: b.locks, channel: b.channel, random: () => 1 });
		const B = createLiveRefresh({ fetch: serverB.fetchFn, doc: docB as never, locks: b.locks, channel: b.channel, random: () => 1 });
		const fa = vi.fn();
		const fb = vi.fn();
		A.subscribe(fa);
		B.subscribe(fb);
		A.start();
		await tick();
		B.start();
		await tick();
		expect(serverA.count('/v1/sync/wait')).toBe(1);
		expect(serverB.count('/v1/sync/wait')).toBe(0);
		await tick(3_100);
		expect(fa).toHaveBeenCalledTimes(1);
		expect(fb).toHaveBeenCalledTimes(1);
		docA.show(false);
		await tick(10);
		expect(serverB.count('/v1/sync/wait')).toBe(1);
		A.stop();
		B.stop();
	});
});
