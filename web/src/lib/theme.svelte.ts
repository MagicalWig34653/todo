import { api, ApiError, type Preferences } from './api.js';
import {
	DEFAULT_ACCENT,
	DEFAULT_GLOW,
	accentTokens,
	isGlow,
	isPresetId,
	normalizeHex,
	presetHex,
	type AccentId,
	type GlowLevel,
	type PresetId
} from './theme/accent.js';

export type ThemeMode = 'system' | 'light' | 'dark';
export type TransparencyMode = 'system' | 'reduced';
/** idle: nothing to sync (signed out), pending: unsent local change, saving, saved: the account holds the value. */
export type SyncState = 'idle' | 'pending' | 'saving' | 'saved';

const K = {
	mode: 'todo.theme',
	accent: 'todo.accent',
	accentId: 'todo.accentId',
	glow: 'todo.glow',
	transparency: 'todo.transparency',
	owner: 'todo.prefsOwner',
	pending: 'todo.prefsPending'
} as const;

function read(key: string): string | null {
	try {
		return localStorage.getItem(key);
	} catch {
		return null;
	}
}
function write(key: string, value: string | null) {
	try {
		if (value === null) localStorage.removeItem(key);
		else localStorage.setItem(key, value);
	} catch {
		/* storage unavailable: the choice then lasts for this tab only */
	}
}

/**
 * Appearance. Colour scheme, accent and glow belong to the account (`/v1/me/preferences`) and are cached in localStorage
 * for instant, flash-free start and offline use; reduced transparency stays device-local.
 * Reconcile rule (on every session load): an unsent local change of the same account wins and is pushed; an account
 * that never stored anything adopts a customised local cache once (unless it was written for another account);
 * otherwise the account's values replace the cache.
 */
class Theme {
	mode = $state<ThemeMode>('system');
	accentId = $state<AccentId>('blue');
	accent = $state(DEFAULT_ACCENT);
	glow = $state<GlowLevel>(DEFAULT_GLOW);
	transparency = $state<TransparencyMode>('system');
	systemDark = $state(false);
	sync = $state<SyncState>('idle');
	private started = false;
	private account: string | null = null;
	private flushing = false;

	get dark() {
		return this.mode === 'dark' || (this.mode === 'system' && this.systemDark);
	}

	init() {
		if (this.started || typeof window === 'undefined') return;
		this.started = true;
		const mode = read(K.mode);
		if (mode === 'light' || mode === 'dark') this.mode = mode;
		const hex = normalizeHex(read(K.accent) ?? '');
		if (hex) {
			this.accent = hex;
			const id = read(K.accentId);
			this.accentId = isPresetId(id) && presetHex(id) === hex ? id : 'custom';
		}
		const glow = read(K.glow);
		if (isGlow(glow)) this.glow = glow;
		if (read(K.transparency) === 'reduced') this.transparency = 'reduced';
		const query = matchMedia('(prefers-color-scheme: dark)');
		this.systemDark = query.matches;
		query.addEventListener('change', (e) => {
			this.systemDark = e.matches;
			this.apply();
		});
		window.addEventListener('online', () => void this.flush());
		this.apply();
	}

	setMode(mode: ThemeMode) {
		this.mode = mode;
		if (mode === 'system') write(K.mode, null);
		else write(K.mode, mode);
		this.apply();
		this.changed();
	}
	cycle() {
		this.setMode(this.mode === 'system' ? 'light' : this.mode === 'light' ? 'dark' : 'system');
	}
	setPreset(id: PresetId) {
		this.accentId = id;
		this.accent = presetHex(id);
		this.storeAccent();
		this.apply();
		this.changed();
	}
	/** Returns false (keeping the current accent) for an invalid colour. */
	setCustomAccent(input: string): boolean {
		const hex = normalizeHex(input);
		if (!hex) return false;
		this.accentId = 'custom';
		this.accent = hex;
		this.storeAccent();
		this.apply();
		this.changed();
		return true;
	}
	setGlow(level: GlowLevel) {
		this.glow = level;
		write(K.glow, level);
		this.apply();
		this.changed();
	}
	setTransparency(mode: TransparencyMode) {
		this.transparency = mode;
		write(K.transparency, mode === 'reduced' ? 'reduced' : null);
		this.apply();
	}
	resetAll() {
		this.mode = 'system';
		write(K.mode, null);
		this.glow = DEFAULT_GLOW;
		write(K.glow, DEFAULT_GLOW);
		this.setPreset('blue');
	}
	private storeAccent() {
		write(K.accent, this.accent);
		write(K.accentId, this.accentId);
	}

	// account sync

	private body(): Preferences {
		const custom = this.accentId === 'custom';
		return {
			version: 1,
			appearance: {
				colorScheme: this.mode,
				accent: this.accentId,
				...(custom ? { accentCustomHex: this.accent.toUpperCase() } : {}),
				glow: this.glow
			}
		};
	}
	private changed() {
		if (!this.account) return;
		write(K.pending, this.account);
		write(K.owner, this.account);
		this.sync = 'pending';
		void this.flush();
	}
	async flush() {
		const account = this.account;
		if (!account || this.flushing || read(K.pending) !== account) return;
		this.flushing = true;
		try {
			while (read(K.pending) === account && this.account === account) {
				const body = this.body();
				const sent = JSON.stringify(body);
				this.sync = 'saving';
				try {
					await api.putPreferences(body);
				} catch (e) {
					if (e instanceof ApiError && e.status >= 400 && e.status < 500 && e.status !== 401 && e.status !== 429) {
						// a refused document would fail forever: drop it, the next session load shows the account's values
						write(K.pending, null);
						this.sync = 'idle';
					} else this.sync = 'pending';
					return;
				}
				if (JSON.stringify(this.body()) === sent) {
					write(K.pending, null);
					this.sync = 'saved';
				}
			}
		} finally {
			this.flushing = false;
		}
	}
	private isDefault() {
		return this.mode === 'system' && this.accentId === 'blue' && this.glow === DEFAULT_GLOW;
	}
	/** Called when a session is known. Never throws; offline keeps the cache. */
	async reconcile(accountID: string) {
		this.init();
		this.account = accountID;
		let remote: Preferences;
		try {
			remote = await api.getPreferences();
		} catch {
			this.sync = read(K.pending) === accountID ? 'pending' : 'idle';
			return;
		}
		if (this.account !== accountID) return;
		const owner = read(K.owner);
		const pending = read(K.pending) === accountID;
		const neverSet = !remote.revision;
		if (pending || (neverSet && !this.isDefault() && (owner === null || owner === accountID))) {
			this.changed();
			return;
		}
		this.adopt(remote);
		write(K.owner, accountID);
		write(K.pending, null);
		this.sync = 'saved';
	}
	/** Re-reads the account's values (another device may have changed them). */
	async refresh() {
		const account = this.account;
		if (!account) return;
		await this.flush();
		if (read(K.pending) === account) return;
		try {
			const remote = await api.getPreferences();
			if (this.account === account && read(K.pending) !== account) {
				this.adopt(remote);
				this.sync = 'saved';
			}
		} catch {
			/* offline */
		}
	}
	detach() {
		this.account = null;
		this.sync = 'idle';
	}
	private adopt(remote: Preferences) {
		const a = remote.appearance;
		this.mode = a.colorScheme;
		write(K.mode, a.colorScheme === 'system' ? null : a.colorScheme);
		const custom = a.accent === 'custom' ? normalizeHex(a.accentCustomHex ?? '') : null;
		if (custom) {
			this.accentId = 'custom';
			this.accent = custom;
		} else {
			const id = isPresetId(a.accent) ? a.accent : 'blue';
			this.accentId = id;
			this.accent = presetHex(id);
		}
		this.storeAccent();
		if (isGlow(a.glow)) this.glow = a.glow;
		write(K.glow, this.glow);
		this.apply();
	}

	apply() {
		if (typeof document === 'undefined') return;
		const root = document.documentElement;
		root.classList.toggle('dark', this.dark);
		root.dataset.glow = this.glow;
		if (this.transparency === 'reduced') root.dataset.transparency = 'reduced';
		else delete root.dataset.transparency;
		const t = accentTokens(this.accent, this.dark);
		root.style.setProperty('--ui-accent', t.primary);
		root.style.setProperty('--ui-accent-foreground', t.foreground);
		root.style.setProperty('--ui-accent-ink', t.ink);
		root.style.setProperty('--ui-accent-soft', `color-mix(in srgb, ${t.primary} ${this.dark ? 18 : 9}%, var(--background))`);
		root.style.setProperty('--glow-color', t.ink === t.primary ? t.primary : t.ink);
	}
}

export const theme = new Theme();
