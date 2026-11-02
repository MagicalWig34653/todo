import type { MessageKey } from './i18n/index.js';

/** Help pages (`/help/<slug>`) and the external links of the help menu. */
export interface HelpPage {
	id: string;
	label: MessageKey;
	description: MessageKey;
}
export const HELP_PAGES: HelpPage[] = [
	{ id: 'erste-schritte', label: 'help.start', description: 'help.start.description' },
	{ id: 'tastaturkuerzel', label: 'help.keys', description: 'help.keys.description' },
	{ id: 'claude-code', label: 'help.claude', description: 'help.claude.description' },
	{ id: 'agentenhandbuch', label: 'help.manual', description: 'help.manual.description' },
	{ id: 'ueber', label: 'help.about', description: 'help.about.description' }
];
export const DOCS_URL = 'https://magicalwig34653.github.io/todo/';
export const ISSUES_URL = 'https://github.com/MagicalWig34653/todo/issues';
export const CHANGELOG_URL = 'https://github.com/MagicalWig34653/todo/commits/main';

/** Page id -> English URL slug (`/help/<slug>`); other ids are their own slug. */
export const HELP_SLUGS: Record<string, string> = { 'erste-schritte': 'getting-started', tastaturkuerzel: 'shortcuts', agentenhandbuch: 'agent-manual', ueber: 'about' };
const HELP_ID_OF_SLUG: Record<string, string> = Object.fromEntries(Object.entries(HELP_SLUGS).map(([id, slug]) => [slug, id]));
/** Slug (or old German id) from a URL -> page id; unknown values are kept. */
export const normalizeHelpArea = (area: string | undefined) => (area ? (HELP_ID_OF_SLUG[area] ?? area) : undefined);

export const findHelpPage = (id: string | undefined) => HELP_PAGES.find((p) => p.id === id);
export const helpPath = (id?: string) => (id ? `/help/${encodeURIComponent(HELP_SLUGS[id] ?? id)}` : '/help');
