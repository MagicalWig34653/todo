/** Accent colour handling: presets (ids shared with the backend contract), validation and derived tokens. */

export const DEFAULT_ACCENT = '#2563eb';

export const ACCENT_PRESETS = [
	{ id: 'blue', hex: '#2563eb' },
	{ id: 'teal', hex: '#0d9488' },
	{ id: 'violet', hex: '#7c3aed' },
	{ id: 'green', hex: '#16a34a' },
	{ id: 'orange', hex: '#d97706' },
	{ id: 'pink', hex: '#db2777' },
	{ id: 'graphite', hex: '#52525b' },
	{ id: 'indigo', hex: '#4338ca' },
	{ id: 'navy', hex: '#1e3a8a' },
	{ id: 'purple', hex: '#7e22ce' },
	{ id: 'magenta', hex: '#a21caf' },
	{ id: 'crimson', hex: '#b91c1c' },
	{ id: 'forest', hex: '#166534' },
	{ id: 'petrol', hex: '#0f766e' },
	{ id: 'bronze', hex: '#92400e' },
	{ id: 'wine', hex: '#7f1d3f' },
	{ id: 'slate', hex: '#475a8c' },
	{ id: 'cocoa', hex: '#5c4033' },
	{ id: 'olive', hex: '#4d6b1f' },
	{ id: 'ocean', hex: '#0e7490' },
	{ id: 'ink', hex: '#334155' }
] as const;

export type PresetId = (typeof ACCENT_PRESETS)[number]['id'];
export type AccentId = PresetId | 'custom';

export function isPresetId(value: unknown): value is PresetId {
	return ACCENT_PRESETS.some((p) => p.id === value);
}
export function presetHex(id: PresetId): string {
	return ACCENT_PRESETS.find((p) => p.id === id)!.hex;
}

/** Lower-case `#rrggbb` for `#rgb`/`#rrggbb` input, otherwise null. */
export function normalizeHex(input: string): string | null {
	const v = input.trim();
	if (/^#[0-9a-f]{6}$/i.test(v)) return v.toLowerCase();
	const m = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(v);
	return m ? `#${m[1]}${m[1]}${m[2]}${m[2]}${m[3]}${m[3]}`.toLowerCase() : null;
}

type Rgb = [number, number, number];
const toRgb = (hex: string): Rgb => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)) as Rgb;
const toHex = (rgb: number[]) => '#' + rgb.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');

function luminance(hex: string): number {
	const [r, g, b] = toRgb(hex).map((v) => {
		const x = v / 255;
		return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
	});
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function contrast(a: string, b: string): number {
	const [x, y] = [luminance(a), luminance(b)];
	return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
function mix(hex: string, share: number, base: string): string {
	const a = toRgb(hex);
	const b = toRgb(base);
	return toHex(a.map((v, i) => v * share + b[i] * (1 - share)));
}

const BACKGROUND = { light: '#ffffff', dark: '#09090b' } as const;

export interface AccentTokens {
	primary: string;
	foreground: string;
	/** accent as text colour, nudged towards black/white until it reaches 4.5:1 on the page background */
	ink: string;
}

export function accentTokens(hex: string, dark: boolean): AccentTokens {
	const background = BACKGROUND[dark ? 'dark' : 'light'];
	const target = dark ? '#ffffff' : '#000000';
	let ink = hex;
	for (let i = 1; i <= 10 && contrast(ink, background) < 4.5; i++) ink = mix(target, i / 10, hex);
	return { primary: hex, foreground: contrast(hex, '#ffffff') >= contrast(hex, '#000000') ? '#ffffff' : '#000000', ink };
}

export const GLOW_LEVELS = ['off', 'subtle', 'medium', 'strong'] as const;
export type GlowLevel = (typeof GLOW_LEVELS)[number];
export const DEFAULT_GLOW: GlowLevel = 'subtle';
export function isGlow(value: unknown): value is GlowLevel {
	return GLOW_LEVELS.some((g) => g === value);
}
