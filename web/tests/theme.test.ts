import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ACCENT_PRESETS, accentTokens, contrast, normalizeHex } from '../src/lib/theme/accent';

describe('accent helpers', () => {
	it('normalises hex input', () => {
		expect(normalizeHex('#ABC')).toBe('#aabbcc');
		expect(normalizeHex(' #2563EB ')).toBe('#2563eb');
		expect(normalizeHex('2563eb')).toBeNull();
		expect(normalizeHex('#12345')).toBeNull();
	});
	it('keeps ink readable and foreground legible for every preset in both schemes', () => {
		for (const p of ACCENT_PRESETS) {
			for (const dark of [false, true]) {
				const t = accentTokens(p.hex, dark);
				expect(contrast(t.ink, dark ? '#09090b' : '#ffffff')).toBeGreaterThanOrEqual(4.5);
				expect(contrast(t.primary, t.foreground)).toBeGreaterThanOrEqual(4.5);
			}
		}
	});
});

function fakeDom() {
	const store = new Map<string, string>();
	vi.stubGlobal('localStorage', {
		getItem: (k: string) => store.get(k) ?? null,
		setItem: (k: string, v: string) => void store.set(k, v),
		removeItem: (k: string) => void store.delete(k)
	});
	vi.stubGlobal('window', { addEventListener: () => {} });
	vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener: () => {} }));
	const classes = new Set<string>();
	const props = new Map<string, string>();
	vi.stubGlobal('document', {
		documentElement: {
			dataset: {} as Record<string, string>,
			classList: { toggle: (c: string, on: boolean) => (on ? classes.add(c) : classes.delete(c)) },
			style: { setProperty: (k: string, v: string) => props.set(k, v) }
		}
	});
	return { store, classes, props };
}

describe('theme store', () => {
	let calls: { method: string; body?: unknown }[];
	beforeEach(() => {
		vi.resetModules();
		calls = [];
	});

	async function load(remote: unknown, putFails = false) {
		const dom = fakeDom();
		vi.doMock('../src/lib/api', async () => {
			const real = await vi.importActual<typeof import('../src/lib/api')>('../src/lib/api');
			return {
				...real,
				api: {
					getPreferences: async () => (calls.push({ method: 'GET' }), remote),
					putPreferences: async (body: unknown) => {
						calls.push({ method: 'PUT', body });
						if (putFails) throw new real.ApiError(503, 'x');
						return body;
					}
				}
			};
		});
		const { theme } = await import('../src/lib/theme.svelte');
		return { theme, dom };
	}
	const server = (colorScheme: string, accent: string, glow: string, revision = 3) => ({
		version: 1,
		appearance: { colorScheme, accent, glow },
		revision
	});

	it('persists locally under todo. keys and applies data attributes', async () => {
		const { theme, dom } = await load(server('system', 'blue', 'subtle', 0));
		theme.init();
		theme.setMode('dark');
		theme.setGlow('strong');
		theme.setTransparency('reduced');
		expect(dom.store.get('todo.theme')).toBe('dark');
		expect(dom.store.get('todo.glow')).toBe('strong');
		expect(dom.store.get('todo.transparency')).toBe('reduced');
		expect(dom.classes.has('dark')).toBe(true);
		expect(document.documentElement.dataset.glow).toBe('strong');
		expect(document.documentElement.dataset.transparency).toBe('reduced');
		expect(theme.setCustomAccent('nope')).toBe(false);
		expect(theme.setCustomAccent('#AA0000')).toBe(true);
		expect(dom.store.get('todo.accent')).toBe('#aa0000');
		expect(dom.props.get('--ui-accent')).toBe('#aa0000');
	});

	it('adopts the account values when nothing is pending', async () => {
		const { theme, dom } = await load(server('dark', 'teal', 'off'));
		await theme.reconcile('u1');
		expect(theme.mode).toBe('dark');
		expect(theme.accentId).toBe('teal');
		expect(theme.glow).toBe('off');
		expect(dom.store.get('todo.accent')).toBe('#0d9488');
		expect(theme.sync).toBe('saved');
		expect(calls.some((c) => c.method === 'PUT')).toBe(false);
	});

	it('pushes a customised local cache to an account that never stored anything', async () => {
		const { theme } = await load(server('system', 'blue', 'subtle', 0));
		theme.init();
		theme.setMode('light');
		await theme.reconcile('u1');
		await vi.waitFor(() => expect(calls.some((c) => c.method === 'PUT')).toBe(true));
		expect((calls.find((c) => c.method === 'PUT')!.body as { appearance: { colorScheme: string } }).appearance.colorScheme).toBe('light');
	});

	it('does not leak another account\'s cache into a fresh account', async () => {
		const { theme, dom } = await load(server('system', 'blue', 'subtle', 0));
		theme.init();
		dom.store.set('todo.prefsOwner', 'someone-else');
		theme.setMode('dark'); // signed out: no account, so owner stays
		await theme.reconcile('u2');
		expect(calls.some((c) => c.method === 'PUT')).toBe(false);
		expect(theme.mode).toBe('system');
	});

	it('keeps an unsent change pending when the write fails and wins over the server', async () => {
		const { theme, dom } = await load(server('light', 'blue', 'subtle'), true);
		await theme.reconcile('u1');
		theme.setMode('dark');
		await vi.waitFor(() => expect(theme.sync).toBe('pending'));
		expect(dom.store.get('todo.prefsPending')).toBe('u1');
		await theme.reconcile('u1');
		expect(theme.mode).toBe('dark');
	});

	it('survives unavailable storage', async () => {
		const { theme } = await load(server('system', 'blue', 'subtle', 0));
		vi.stubGlobal('localStorage', {
			getItem: () => { throw new Error('blocked'); },
			setItem: () => { throw new Error('blocked'); },
			removeItem: () => { throw new Error('blocked'); }
		});
		expect(() => { theme.init(); theme.setGlow('medium'); }).not.toThrow();
		expect(theme.glow).toBe('medium');
	});
});
