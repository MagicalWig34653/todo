import type { EmailStatus, PushTestResult } from '#lib/api.js';

/** Preference categories in display order (keys match contracts/push.yaml). */
export const PUSH_CATEGORIES = ['reminders', 'agent_questions', 'agent_reviews', 'assignments', 'comments', 'confirmations'] as const;
export type PushCategory = (typeof PUSH_CATEGORIES)[number];

/** Server defaults; used until the stored preferences arrive. */
export const PUSH_DEFAULTS: Record<PushCategory, boolean> = {
	reminders: true,
	agent_questions: true,
	agent_reviews: true,
	assignments: false,
	comments: false,
	confirmations: true
};

export type TestSummary = { total: number; sent: number; none: boolean };

export function summarizeTest(r: PushTestResult): TestSummary {
	return { total: r.devices.length, sent: r.devices.filter((d) => d.result === 'sent').length, none: r.devices.length === 0 };
}

/** The recovery-code link in a mail carries the code in the URL fragment (never sent to the server on load). */
export function fragmentParam(hash: string, name: string): string | null {
	const params = new URLSearchParams(hash.replace(/^#/, ''));
	const v = params.get(name);
	return v && /^[A-Za-z0-9_-]{16,200}$/.test(v) ? v : null;
}

export function mailStateKey(last: NonNullable<EmailStatus['lastMail']>): string {
	return `email.state.${last.state}`;
}
