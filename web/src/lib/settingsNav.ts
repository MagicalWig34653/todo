import type { MessageKey } from './i18n/index.js';

/**
 * Structure of the settings hub (`/einstellungen/<bereich>`), modelled on the grouped settings navigation of a
 * mature PWA: left list in groups on wide screens, grouped list -> detail on phones, one description line per entry.
 * Pure data and helpers only; the components map entry ids to pages (SettingsView.svelte).
 */
export interface SettingsEntry {
	/** URL segment: `/einstellungen/<id>`. */
	id: string;
	label: MessageKey;
	/** One explanatory line, shown on the landing page and on phones. */
	description: MessageKey;
	/** Extra German search terms. */
	keywords: string;
	adminOnly?: boolean;
}
export interface SettingsGroup {
	id: string;
	label: MessageKey;
	entries: SettingsEntry[];
	adminOnly?: boolean;
}

export const SETTINGS_GROUPS: SettingsGroup[] = [
	{
		id: 'profile',
		label: 'settings.group.profile',
		entries: [{ id: 'profil', label: 'settings.profil', description: 'settings.profil.description', keywords: 'name konto id benutzername anzeigename' }]
	},
	{
		id: 'security',
		label: 'settings.group.security',
		entries: [
			{ id: 'passkeys', label: 'settings.passkeys', description: 'settings.passkeys.description', keywords: 'passkey anmeldung sicherheit schlüssel' },
			{ id: 'wiederherstellung', label: 'settings.wiederherstellung', description: 'settings.wiederherstellung.description', keywords: 'recovery code verloren zugang' },
			{ id: 'sitzungen', label: 'settings.sitzungen', description: 'settings.sitzungen.description', keywords: 'sitzung abmelden geräte login' }
		]
	},
	{
		id: 'appearance',
		label: 'settings.group.appearance',
		entries: [{ id: 'darstellung', label: 'settings.darstellung', description: 'settings.darstellung.description', keywords: 'hell dunkel akzent farbe theme glow transparenz design' }]
	},
	{
		id: 'notify',
		label: 'settings.group.notify',
		entries: [
			{ id: 'benachrichtigungen', label: 'settings.benachrichtigungen', description: 'settings.benachrichtigungen.description', keywords: 'push apns mitteilungen geräte erinnerung' },
			{ id: 'email', label: 'settings.email', description: 'settings.email.description', keywords: 'mail adresse bestätigung testmail' }
		]
	},
	{
		id: 'access',
		label: 'settings.group.access',
		entries: [{ id: 'berechtigungen', label: 'settings.berechtigungen', description: 'settings.berechtigungen.description', keywords: 'rollen freigaben teilen zugriff team rechte' }]
	},
	{
		id: 'connected',
		label: 'settings.group.connected',
		entries: [
			{ id: 'verbindungen', label: 'settings.verbindungen', description: 'settings.verbindungen.description', keywords: 'oauth claude chatgpt mcp apps zugriff widerrufen' },
			{ id: 'runner', label: 'settings.runner', description: 'settings.runner.description', keywords: 'runner mac agent gerät koppeln claude code' },
			{ id: 'mcp', label: 'settings.mcp', description: 'settings.mcp.description', keywords: 'mcp claude code verbinden plugin befehl' }
		]
	},
	{
		id: 'data',
		label: 'settings.group.data',
		entries: [{ id: 'daten', label: 'settings.daten', description: 'settings.daten.description', keywords: 'export löschen datenschutz dsgvo auskunft download' }]
	},
	{
		id: 'admin',
		label: 'settings.group.admin',
		adminOnly: true,
		entries: [
			{ id: 'verwaltung-konten', label: 'settings.verwaltung-konten', description: 'settings.verwaltung-konten.description', keywords: 'konten benutzer recovery sperren admin', adminOnly: true },
			{ id: 'verwaltung-einladungen', label: 'settings.verwaltung-einladungen', description: 'settings.verwaltung-einladungen.description', keywords: 'einladung einladen registrierung token', adminOnly: true },
			{ id: 'verwaltung-mail', label: 'settings.verwaltung-mail', description: 'settings.verwaltung-mail.description', keywords: 'mail smtp server versand', adminOnly: true },
			{ id: 'verwaltung-push', label: 'settings.verwaltung-push', description: 'settings.verwaltung-push.description', keywords: 'apns push apple schlüssel', adminOnly: true },
			{ id: 'verwaltung-speicher', label: 'settings.verwaltung-speicher', description: 'settings.verwaltung-speicher.description', keywords: 'speicher anhänge dateien limit', adminOnly: true },
			{ id: 'verwaltung-system', label: 'settings.verwaltung-system', description: 'settings.verwaltung-system.description', keywords: 'system health status bereit datenbank wartung', adminOnly: true }
		]
	}
];

/** Old `/konto/<bereich>` values and the one-segment admin page of the first permission build. */
export const LEGACY_AREAS: Record<string, string> = { verwaltung: 'verwaltung-konten', allgemein: 'profil', general: 'profil' };

/** Area segment from an old or new URL -> current entry id (unknown values are kept so the hub can show "not found"). */
export function normalizeArea(area: string | undefined): string | undefined {
	if (!area) return undefined;
	return LEGACY_AREAS[area] ?? area;
}

/** Groups the viewer may see; admin-only groups and entries disappear for everybody else. */
export function visibleGroups(isAdmin: boolean): SettingsGroup[] {
	return SETTINGS_GROUPS.filter((g) => isAdmin || !g.adminOnly)
		.map((g) => ({ ...g, entries: g.entries.filter((e) => isAdmin || !e.adminOnly) }))
		.filter((g) => g.entries.length > 0);
}

export function findEntry(id: string | undefined): SettingsEntry | undefined {
	if (!id) return undefined;
	for (const g of SETTINGS_GROUPS) for (const e of g.entries) if (e.id === id) return e;
	return undefined;
}

export const settingsPath = (id?: string) => (id ? `/einstellungen/${encodeURIComponent(id)}` : '/einstellungen');

/** Entries matching all words of a query by title or keywords. */
export function searchSettings(groups: SettingsGroup[], query: string, title: (key: MessageKey) => string): SettingsEntry[] {
	const words = query.toLowerCase().split(/\s+/).filter(Boolean);
	if (words.length === 0) return [];
	return groups.flatMap((g) => g.entries).filter((e) => {
		const hay = `${title(e.label)} ${e.keywords}`.toLowerCase();
		return words.every((w) => hay.includes(w));
	});
}
