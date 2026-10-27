export type ThemeMode = 'system' | 'light' | 'dark';
const KEY = 'todo.theme';

function read(): ThemeMode {
	try {
		const v = localStorage.getItem(KEY);
		if (v === 'light' || v === 'dark') return v;
	} catch {
		/* storage unavailable: follow the system */
	}
	return 'system';
}

/** Applies the mode to <html> (class `dark`). Mirrors the inline script in app.html that prevents a flash. */
export function applyTheme(mode: ThemeMode) {
	const dark = mode === 'dark' || (mode === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
	document.documentElement.classList.toggle('dark', dark);
}

class Theme {
	mode = $state<ThemeMode>('system');

	init() {
		this.mode = read();
		applyTheme(this.mode);
		matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => applyTheme(this.mode));
	}

	set(mode: ThemeMode) {
		this.mode = mode;
		try {
			if (mode === 'system') localStorage.removeItem(KEY);
			else localStorage.setItem(KEY, mode);
		} catch {
			/* ignore */
		}
		applyTheme(mode);
	}

	cycle() {
		this.set(this.mode === 'system' ? 'light' : this.mode === 'light' ? 'dark' : 'system');
	}
}

export const theme = new Theme();
