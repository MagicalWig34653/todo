/**
 * Outgoing webhook (ADR 0035, card 06EB19A3): types of `/v1/settings/webhook` (contracts/webhook.yaml) and the pure rules of the
 * settings page. No DOM.
 *
 * The address is a secret. Nothing in here ever turns a server value into UI text unchecked: error messages come from fixed
 * German strings chosen by status and reason, protocol rows only use known codes and kinds, and the mask is reduced to scheme
 * and host again before it is shown.
 */

import { ApiError, type Project } from './api.js';
import type { MessageKey } from './i18n/index.js';
import { t } from './i18n/index.js';
import { projectLabels } from './brainMandate.js';

/** The kinds of person actions that wake the receiver (fixed list of the contract; sorted set in a delivery). */
export const WEBHOOK_KINDS = ['question.answered', 'review.accepted', 'review.changes_requested', 'comment.created', 'task.created', 'task.moved', 'task.status_changed'] as const;
export type WebhookKind = (typeof WEBHOOK_KINDS)[number];

/** `WebhookDelivery` of the contract: never carries an address, a host or a response body. */
export interface WebhookDelivery {
	id: string;
	event: 'person_action' | 'test';
	state: 'pending' | 'sent' | 'failed';
	attempts: number;
	httpStatus?: number | null;
	errorCode?: string | null;
	anzahl: number;
	kinds: WebhookKind[];
	createdAt: string;
	finishedAt?: string | null;
	nextAttemptAt?: string | null;
}

/** `WebhookSettings` of the contract. `maskedURL` is the only thing the API says about the address. */
export interface WebhookSettings {
	configured: boolean;
	maskedURL?: string;
	enabled: boolean;
	signingConfigured: boolean;
	excludedProjectIDs: string[];
	consecutiveFailures: number;
	lastDelivery?: WebhookDelivery;
}

/** Body of `PUT /v1/settings/webhook`: fields that are missing stay as they are, `null` deletes. */
export interface UpdateWebhook {
	url?: string | null;
	signingSecret?: string | null;
	enabled?: boolean;
	excludedProjectIDs?: string[];
}

/** Server ceiling of excluded projects (`webhook_exclusions_invalid` above). */
export const MAX_EXCLUSIONS = 500;
/** After this many failed bundles in a row the server switches the webhook off (ADR 0035, 9). */
export const AUTO_DISABLE_FAILURES = 10;

/** Message key for the documented answers of the webhook endpoints. Never uses the text of the error: it could carry an address. */
export function webhookErrorKey(e: unknown): MessageKey {
	if (!(e instanceof ApiError)) return 'error.generic';
	if (e.status === 0) return 'error.network';
	if (e.status === 401) return 'webhook.error.session';
	if (e.status === 400) {
		switch (e.reason) {
			case 'webhook_url_not_https':
				return 'webhook.error.not_https';
			case 'webhook_url_invalid':
				return 'webhook.error.invalid';
			case 'webhook_url_blocked':
			case 'target_blocked':
				return 'webhook.error.blocked';
			case 'webhook_signing_secret_invalid':
				return 'webhook.error.signingInvalid';
			case 'webhook_exclusions_invalid':
				return 'webhook.error.exclusionsInvalid';
		}
		return 'error.generic';
	}
	if (e.status === 404) return 'webhook.error.projectGone';
	if (e.status === 409) {
		if (e.reason === 'encryption_key_missing') return 'webhook.error.noKey';
		if (e.reason === 'webhook_not_configured') return 'webhook.error.notConfigured';
		return 'error.generic';
	}
	if (e.status === 429) return 'webhook.error.rateLimited';
	return 'error.generic';
}

const CODE_KEYS: Record<string, MessageKey> = {
	timeout: 'webhook.code.timeout',
	network_error: 'webhook.code.network_error',
	tls_error: 'webhook.code.tls_error',
	dns_error: 'webhook.code.dns_error',
	redirect_not_followed: 'webhook.code.redirect_not_followed',
	target_blocked: 'webhook.code.target_blocked',
	webhook_url_invalid: 'webhook.code.webhook_url_invalid',
	webhook_url_not_https: 'webhook.code.webhook_url_not_https',
	webhook_disabled: 'webhook.code.webhook_disabled',
	encryption_key_missing: 'webhook.code.encryption_key_missing',
	encryption_key_unreadable: 'webhook.code.encryption_key_unreadable',
	http_unexpected: 'webhook.code.http_unexpected'
};
const HTTP_CODE = /^http_([1-5]\d\d)$/;

/** Whether `code` is one of the short codes of the contract (own property, so `constructor` and friends are not). */
function knownCode(code: string | null | undefined): code is string {
	return !!code && (Object.hasOwn(CODE_KEYS, code) || HTTP_CODE.test(code));
}

/** German explanation of a delivery error code; empty without a code, a neutral text for anything unknown (never the code itself). */
export function deliveryErrorText(code: string | null | undefined): string {
	if (!code) return '';
	if (Object.hasOwn(CODE_KEYS, code)) return t(CODE_KEYS[code]);
	const http = HTTP_CODE.exec(code);
	if (http) return t('webhook.code.http', { status: http[1] });
	return t('webhook.error.unknownCode');
}

export type DeliveryTone = 'success' | 'warning' | 'destructive';

export interface DeliveryRow {
	id: string;
	state: WebhookDelivery['state'];
	tone: DeliveryTone;
	stateLabel: string;
	eventLabel: string;
	/** "3 Aktionen"; empty for the test call. */
	countLabel: string;
	/** German names of the known kinds; unknown values are dropped. */
	kindLabels: string[];
	attemptsLabel: string;
	/** "HTTP 200" / explanation of the error; empty while pending. */
	resultLabel: string;
	/** The short code as the server sent it, only when it is one of the documented ones. */
	code: string | null;
}

const kindKey = (kind: WebhookKind): MessageKey => `webhook.kind.${kind}`;
const isKind = (k: unknown): k is WebhookKind => typeof k === 'string' && (WEBHOOK_KINDS as readonly string[]).includes(k);

function resultOf(d: WebhookDelivery): string {
	const reason = deliveryErrorText(d.errorCode);
	const http = typeof d.httpStatus === 'number' ? d.httpStatus : null;
	// "http_503" already says the number; any other code gets the status in front when there was an answer.
	if (reason && http !== null && !HTTP_CODE.test(d.errorCode ?? '')) return t('webhook.result.httpAnd', { status: http, reason });
	if (reason) return reason;
	return http !== null ? t('webhook.result.http', { status: http }) : '';
}

/** One protocol entry as the page shows it. Only fixed German texts come out; nothing of the server data is passed through as text. */
export function deliveryRow(d: WebhookDelivery): DeliveryRow {
	const tone: DeliveryTone = d.state === 'sent' ? 'success' : d.state === 'failed' ? 'destructive' : 'warning';
	const stateLabel = d.state === 'sent' ? t('webhook.state.sent') : d.state === 'failed' ? t('webhook.state.failed') : t('webhook.state.pending');
	const isTest = d.event === 'test';
	return {
		id: d.id,
		state: d.state,
		tone,
		stateLabel,
		eventLabel: isTest ? t('webhook.event.test') : t('webhook.event.person_action'),
		countLabel: isTest || !(d.anzahl > 0) ? '' : d.anzahl === 1 ? t('webhook.deliveries.actionsOne') : t('webhook.deliveries.actions', { count: d.anzahl }),
		kindLabels: (d.kinds ?? []).filter(isKind).map((k) => t(kindKey(k))),
		attemptsLabel: d.attempts === 1 ? t('webhook.deliveries.attemptsOne') : t('webhook.deliveries.attempts', { count: d.attempts }),
		resultLabel: resultOf(d),
		code: knownCode(d.errorCode) ? d.errorCode : null
	};
}

/** Outcome of "Test senden" as one sentence: delivered, failed with reason and short code, or still on its way. */
export function testOutcome(d: WebhookDelivery): { ok: boolean; text: string } {
	if (d.state === 'sent') {
		const http = typeof d.httpStatus === 'number' ? d.httpStatus : null;
		return { ok: true, text: http !== null ? t('webhook.test.sentHttp', { status: http }) : t('webhook.test.sent') };
	}
	if (d.state === 'pending') return { ok: false, text: t('webhook.test.pending') };
	if (!d.errorCode) return { ok: false, text: t('webhook.test.failed') };
	const code = knownCode(d.errorCode) ? ` ${t('webhook.test.failedCode', { code: d.errorCode })}` : '';
	return { ok: false, text: t('webhook.test.failedWith', { reason: `${deliveryErrorText(d.errorCode)}${code}` }) };
}

/**
 * What may be shown of the stored address: `https://<host>/…`. The API already sends exactly that; the reduction is a second
 * line of defence, so a path or credentials could not reach the page even if a server (or a proxy) made a mistake.
 */
export function safeMask(masked: string | null | undefined): string | null {
	if (!masked) return null;
	let url: URL;
	try {
		url = new URL(masked);
	} catch {
		return null;
	}
	if (url.protocol !== 'https:' || !url.hostname) return null;
	return `https://${url.hostname}/…`;
}

export type WebhookStatus = 'none' | 'active' | 'paused' | 'auto_disabled';

/** Set up or not, running, switched off by the person, or switched off by the server after repeated failures. */
export function webhookStatus(s: WebhookSettings | null | undefined): WebhookStatus {
	if (!s || !s.configured) return 'none';
	if (s.enabled) return 'active';
	return s.consecutiveFailures >= AUTO_DISABLE_FAILURES ? 'auto_disabled' : 'paused';
}

/** The address as typed (trimmed), or `null` for empty input. Whether it is acceptable is for the server to say. */
export function urlInput(raw: string): string | null {
	const v = raw.trim();
	return v ? v : null;
}

/** The signing secret exactly as typed (spaces are part of a secret), or `null` for empty input. */
export function secretInput(raw: string): string | null {
	return raw === '' ? null : raw;
}

const key = (id: string) => id.toLowerCase();

export interface ProjectRow {
	project: Project;
	depth: number;
	/** Name with the parent path, so equal names stay distinguishable. */
	label: string;
}

const bySiblingOrder = (a: Project, b: Project) =>
	(a.position ?? Number.POSITIVE_INFINITY) - (b.position ?? Number.POSITIVE_INFINITY) || a.name.localeCompare(b.name, 'de') || a.id.localeCompare(b.id);

function childMap(projects: readonly Project[]): { roots: Project[]; children: Map<string, Project[]> } {
	const byID = new Map(projects.map((p) => [key(p.id), p]));
	const children = new Map<string, Project[]>();
	const roots: Project[] = [];
	for (const p of projects) {
		const parent = p.parentID ? byID.get(key(p.parentID)) : undefined;
		// A parent the person cannot see (or a project that is its own parent) makes the project a root of this list.
		if (!parent || key(parent.id) === key(p.id)) roots.push(p);
		else children.set(key(parent.id), [...(children.get(key(parent.id)) ?? []), p]);
	}
	return { roots, children };
}

/** All projects as a tree in display order (children right below their parent) with their depth. Safe against cycles. */
export function orderedProjects(projects: readonly Project[]): ProjectRow[] {
	const labels = projectLabels(projects);
	const { roots, children } = childMap(projects);
	const rows: ProjectRow[] = [];
	const seen = new Set<string>();
	const walk = (p: Project, depth: number) => {
		if (seen.has(key(p.id))) return;
		seen.add(key(p.id));
		rows.push({ project: p, depth, label: labels.get(key(p.id)) ?? p.name });
		for (const c of [...(children.get(key(p.id)) ?? [])].sort(bySiblingOrder)) walk(c, depth + 1);
	};
	for (const r of [...roots].sort(bySiblingOrder)) walk(r, 0);
	// Members of a cycle have no root: they are still listed, once.
	for (const p of [...projects].sort(bySiblingOrder)) walk(p, 0);
	return rows;
}

/** Ids of all projects below `id` (not `id` itself). */
export function descendantIDs(projects: readonly Project[], id: string): string[] {
	const { children } = childMap(projects);
	const out: string[] = [];
	const seen = new Set([key(id)]);
	const queue = [key(id)];
	while (queue.length) {
		for (const c of children.get(queue.shift()!) ?? []) {
			if (seen.has(key(c.id))) continue;
			seen.add(key(c.id));
			out.push(c.id);
			queue.push(key(c.id));
		}
	}
	return out;
}

/**
 * Ticks or unticks one project. With `withChildren` (selection aid) its sub-projects follow; what is stored are always single
 * projects. Adding stops at the server limit, removing always works. The input set is not changed.
 */
export function toggleExclusion(sel: ReadonlySet<string>, projects: readonly Project[], id: string, withChildren: boolean): Set<string> {
	const next = new Set(sel);
	const ids = withChildren ? [id, ...descendantIDs(projects, id)] : [id];
	if (next.has(id)) {
		for (const i of ids) next.delete(i);
		return next;
	}
	for (const i of ids) {
		if (next.size >= MAX_EXCLUSIONS) break;
		next.add(i);
	}
	return next;
}

/** Starting selection: the saved ids that still are projects of the list, as the list's own ids (so picker and PUT agree). */
export function prefillExclusions(saved: readonly string[], projects: readonly Project[]): string[] {
	const wanted = new Set(saved.map(key));
	return projects.filter((p) => wanted.has(key(p.id))).map((p) => p.id);
}

/** Whether the selection differs from what the server stores (ids compared case-insensitively, order ignored). */
export function exclusionsChanged(saved: readonly string[], selected: ReadonlySet<string>): boolean {
	const was = new Set(saved.map(key));
	const will = new Set([...selected].map(key));
	return was.size !== will.size || [...was].some((id) => !will.has(id));
}
