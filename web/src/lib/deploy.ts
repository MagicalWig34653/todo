/**
 * Deploy targets, phase 1b (card 354ADE12, contracts/deploy.yaml, ADR 0039): types of `/v1/.../deploy-targets` and the pure rules
 * of the PWA pages (form <-> request body, error texts, local folder -> manifest, compare result -> file tree). No DOM.
 *
 * The PWA creates and edits targets, confirms the SFTP host key, runs the connection test and the compare, and (phase 3, ADR 0044)
 * shows upload plans: only a person's approval here writes to a server. Passwords and keys are write-only: never returned.
 */

import { ApiError } from './api.js';
import { t, type MessageKey } from './i18n/index.js';
import { de } from './i18n/de.js';

export const DEPLOY_PROTOCOLS = ['sftp', 'ftps', 'ftps-implicit', 'ftp'] as const;
export type DeployProtocol = (typeof DEPLOY_PROTOCOLS)[number];
export const DEPLOY_STAGES = ['test', 'prod'] as const;
export type DeployStage = (typeof DEPLOY_STAGES)[number];
export const SYNC_STATUSES = ['changed', 'new', 'serverOnly', 'unverified', 'same'] as const;
export type SyncStatus = (typeof SYNC_STATUSES)[number];

export interface DeployRules {
	includes?: string[];
	excludes?: string[];
	mappings?: { local: string; remote: string }[];
	defaultExcludes?: boolean;
}

export interface DeployTarget {
	id: string;
	projectID: string;
	name: string;
	stage: string;
	protocol: string;
	host: string;
	port: number;
	basePath: string;
	username: string;
	authMethod: 'password' | 'key';
	hostKey: { confirmed: boolean; type?: string; fingerprint?: string };
	tlsCertificatePinned: boolean;
	rules: DeployRules;
	effectiveExcludes: string[];
	createdAt: string;
	updatedAt: string;
}

/** Body of POST and PATCH. Missing fields stay; `null` removes a secret or the certificate. */
export interface DeployTargetWrite {
	name?: string;
	stage?: string;
	protocol?: string;
	host?: string;
	port?: number;
	basePath?: string;
	username?: string;
	password?: string | null;
	privateKey?: string | null;
	privateKeyPassphrase?: string | null;
	tlsCertificate?: string | null;
	rules?: DeployRules;
}

export interface DeployTestResult {
	ok: boolean;
	code?: string;
	files?: number;
	offeredHostKey?: { type?: string; fingerprint?: string };
}

export interface ManifestEntry {
	path: string;
	size: number;
	sha256: string;
}

export interface CompareFile {
	path: string;
	serverPath: string;
	status: SyncStatus;
	repoSize?: number;
	serverSize?: number;
}

export interface DeployCompareResult {
	ok: boolean;
	code?: string;
	summary?: Partial<Record<SyncStatus, number>>;
	files?: CompareFile[];
}

export const defaultPort = (protocol: string): number => (protocol === 'sftp' ? 22 : protocol === 'ftps-implicit' ? 990 : 21);
export const protocolLabel = (protocol: string): string =>
	protocol === 'ftps-implicit' ? 'FTPS (implizit)' : protocol === 'ftps' ? 'FTPS' : protocol === 'ftp' ? 'FTP' : protocol === 'sftp' ? 'SFTP' : protocol;
export const stageLabel = (stage: string): string => (stage === 'prod' ? 'Prod' : stage === 'test' ? 'Test' : stage);

/** `user@host:port/path` for the list (the base path is shown as stored; "" = login directory). */
export function endpointLabel(target: Pick<DeployTarget, 'username' | 'host' | 'port' | 'basePath'>): string {
	const host = target.host.includes(':') ? `[${target.host}]` : target.host;
	const path = target.basePath === '' ? '' : target.basePath.startsWith('/') ? target.basePath : `/${target.basePath}`;
	return `${target.username}@${host}:${target.port}${path}`;
}

// ---- form -----------------------------------------------------------------------------------------------------------

export interface DeployForm {
	name: string;
	stage: DeployStage;
	protocol: DeployProtocol;
	host: string;
	/** Text field; empty = default port of the protocol. */
	port: string;
	basePath: string;
	username: string;
	auth: 'password' | 'key';
	password: string;
	privateKey: string;
	passphrase: string;
	tlsCertificate: string;
	/** One glob per line. */
	includes: string;
	excludes: string;
	/** One `repo -> server` pair per line. */
	mappings: string;
	defaultExcludes: boolean;
	/** Existing FTPS target with a pinned certificate: remove it (system trust again). */
	removeCertificate: boolean;
}

export const emptyForm = (): DeployForm => ({
	name: '',
	stage: 'test',
	protocol: 'sftp',
	host: '',
	port: '',
	basePath: '',
	username: '',
	auth: 'password',
	password: '',
	privateKey: '',
	passphrase: '',
	tlsCertificate: '',
	includes: '',
	excludes: '',
	mappings: '',
	defaultExcludes: true,
	removeCertificate: false
});

const asProtocol = (p: string): DeployProtocol => ((DEPLOY_PROTOCOLS as readonly string[]).includes(p) ? (p as DeployProtocol) : 'sftp');

export function formOf(target: DeployTarget): DeployForm {
	const protocol = asProtocol(target.protocol);
	return {
		...emptyForm(),
		name: target.name,
		stage: target.stage === 'prod' ? 'prod' : 'test',
		protocol,
		host: target.host,
		port: target.port === defaultPort(protocol) ? '' : String(target.port),
		basePath: target.basePath,
		username: target.username,
		auth: target.authMethod === 'key' ? 'key' : 'password',
		includes: (target.rules.includes ?? []).join('\n'),
		excludes: (target.rules.excludes ?? []).join('\n'),
		mappings: (target.rules.mappings ?? []).map((m) => `${m.local} -> ${m.remote}`).join('\n'),
		defaultExcludes: target.rules.defaultExcludes ?? true
	};
}

const lines = (text: string) =>
	text
		.split('\n')
		.map((l) => l.trim())
		.filter(Boolean);

export type FormProblem = 'name' | 'host' | 'port' | 'username' | 'secret' | 'authChange' | 'passphrase' | 'mappings';

export function parseMappings(text: string): { local: string; remote: string }[] | null {
	const out: { local: string; remote: string }[] = [];
	for (const line of lines(text)) {
		const parts = line.split('->');
		if (parts.length !== 2) return null;
		out.push({ local: parts[0].trim(), remote: parts[1].trim() });
	}
	return out;
}

/**
 * Turns the form into a request body. New target: everything. Existing target: only what changed, so an unchanged endpoint never
 * asks for the secret again; the server refuses an endpoint change without a new secret (deploy_credentials_required).
 */
export function writeBody(form: DeployForm, existing?: DeployTarget): { body: DeployTargetWrite } | { problem: FormProblem } {
	const name = form.name.trim();
	if (!name) return { problem: 'name' };
	const host = form.host.trim();
	if (!host) return { problem: 'host' };
	const portText = form.port.trim();
	if (portText !== '' && !/^\d{1,5}$/.test(portText)) return { problem: 'port' };
	const port = portText === '' ? defaultPort(form.protocol) : Number(portText);
	if (port < 1 || port > 65535) return { problem: 'port' };
	const username = form.username.trim();
	if (!username) return { problem: 'username' };
	const mappings = parseMappings(form.mappings);
	if (!mappings) return { problem: 'mappings' };
	const auth = form.protocol === 'sftp' ? form.auth : 'password';
	const secret = auth === 'key' ? form.privateKey.trim() : form.password;
	if (!existing && !secret) return { problem: 'secret' };
	// The server binds a passphrase to its key and the login method to the secret: neither changes without the secret.
	if (auth === 'key' && form.passphrase && !secret) return { problem: 'passphrase' };
	if (existing && !secret && (existing.authMethod === 'key') !== (auth === 'key')) return { problem: 'authChange' };

	const rules: DeployRules = { includes: lines(form.includes), excludes: lines(form.excludes), mappings, defaultExcludes: form.defaultExcludes };
	const full: DeployTargetWrite = { name, stage: form.stage, protocol: form.protocol, host, port, basePath: form.basePath.trim(), username, rules };
	if (form.protocol === 'ftps' || form.protocol === 'ftps-implicit') {
		if (form.tlsCertificate.trim()) full.tlsCertificate = form.tlsCertificate.trim();
	}
	if (!existing) {
		if (auth === 'key') {
			full.privateKey = secret;
			if (form.passphrase) full.privateKeyPassphrase = form.passphrase;
		} else full.password = secret;
		return { body: full };
	}

	const body: DeployTargetWrite = {};
	if (name !== existing.name) body.name = name;
	if (form.stage !== existing.stage) body.stage = form.stage;
	if (form.protocol !== existing.protocol) body.protocol = form.protocol;
	if (host !== existing.host) body.host = host;
	if (port !== existing.port) body.port = port;
	if (full.basePath !== existing.basePath) body.basePath = full.basePath;
	if (username !== existing.username) body.username = username;
	if (JSON.stringify(normalRules(rules)) !== JSON.stringify(normalRules(existing.rules))) body.rules = rules;
	if (full.tlsCertificate) body.tlsCertificate = full.tlsCertificate;
	else if (form.removeCertificate && existing.tlsCertificatePinned) body.tlsCertificate = null;
	if (secret) {
		if (auth === 'key') {
			body.privateKey = secret;
			body.password = null;
			if (form.passphrase) body.privateKeyPassphrase = form.passphrase;
		} else {
			body.password = secret;
			if (existing.authMethod === 'key') body.privateKey = null;
		}
	}
	return { body };
}

const normalRules = (r: DeployRules) => ({
	includes: r.includes ?? [],
	excludes: r.excludes ?? [],
	mappings: r.mappings ?? [],
	defaultExcludes: r.defaultExcludes ?? true
});

export const problemKey = (p: FormProblem): MessageKey => `deploy.problem.${p}` as MessageKey;

/** Fixed German text for a reason code; never the server's own text. */
export function deployErrorText(e: unknown): string {
	const reason = e instanceof ApiError ? e.reason : typeof e === 'string' ? e : undefined;
	const key = `deploy.error.${reason}` as MessageKey;
	if (reason && key in de) return t(key);
	if (e instanceof ApiError && e.status === 404) return t('deploy.error.notFound');
	return t('deploy.error.generic');
}

// ---- upload plans (phase 3, ADR 0044) --------------------------------------------------------------------------------

export interface DeployPlanFile {
	path: string;
	serverPath: string;
	/** `upload` | `delete` */
	action: string;
	/** `new` | `changed` | `drift` | `restore` | `remove` */
	reason: string;
	oldSize?: number;
	newSize?: number;
}

export interface DeployPlanBlocker {
	path: string;
	serverPath: string;
	/** `unknown_server_state` | `server_changed` | `server_deleted` | `symlink` | `unverified` */
	reason: string;
	overridable: boolean;
}

export interface DeployPlan {
	id: string;
	targetID: string;
	targetName: string;
	/** `upload` | `rollback` */
	kind: string;
	/** For a way back: the run it undoes. */
	sourcePlanID?: string;
	/** `planned` | `requested` | `rejected` | `expired` | `running` | `succeeded` | `failed` */
	state: string;
	ref?: string;
	note?: string;
	createdAt: string;
	createdBy?: string;
	requestedAt?: string;
	requestedBy?: string;
	decidedAt?: string;
	decidedBy?: string;
	finishedAt?: string;
	expiresAt: string;
	overrideDrift: boolean;
	summary: { upload: number; delete: number; unchanged: number; serverOnly: number; blocked: number; skipped: number };
	files: DeployPlanFile[];
	blockers: DeployPlanBlocker[];
	findings: { path: string; serverPath: string; reason: string }[];
	blocked: boolean;
	overridable: boolean;
	written: string[];
	code?: string;
	canRollback: boolean;
}

export interface DeployPlanResult {
	ok: boolean;
	code?: string;
	plan?: DeployPlan;
}

export const isOpenPlan = (p: DeployPlan): boolean => p.state === 'planned' || p.state === 'requested';

/** Asked for, or a way back the person plans and decides right here. */
export const isDecidable = (p: DeployPlan): boolean => p.state === 'requested' || (p.state === 'planned' && p.kind === 'rollback');

/** A person may approve: decidable, and every lock (if any) can be overridden. */
export const canApprove = (p: DeployPlan): boolean => isDecidable(p) && (!p.blocked || p.overridable);

/** The way back of this run is already waiting for a decision. */
export const hasOpenRollback = (plans: DeployPlan[], run: DeployPlan): boolean => plans.some((p) => p.kind === 'rollback' && p.sourcePlanID === run.id && isOpenPlan(p));

/** Requests first (they wait for a person), then everything else newest first as the server sends it. */
export function sortPlans(plans: DeployPlan[]): DeployPlan[] {
	return [...plans.filter((p) => p.state === 'requested'), ...plans.filter((p) => p.state !== 'requested')];
}

// ---- manifest from a local folder ------------------------------------------------------------------------------------

/** Folders no target ever wants; skipped before hashing so a checkout with dependencies stays fast. The server applies the rules. */
const SKIP_DIRS = new Set(['.git', 'node_modules']);
export const MAX_MANIFEST = 50_000;

export interface PickedFile {
	/** `webkitRelativePath`: the picked folder's name, then the path inside it. */
	relativePath: string;
	size: number;
	bytes: () => Promise<ArrayBuffer>;
}

/** Repo-relative path of a picked file, or null when it is skipped. */
export function manifestPath(relativePath: string): string | null {
	const segs = relativePath.split('/').filter(Boolean).slice(1);
	if (segs.length === 0 || segs.some((s) => SKIP_DIRS.has(s))) return null;
	return segs.join('/');
}

export async function sha256Hex(data: ArrayBuffer): Promise<string> {
	const digest = await crypto.subtle.digest('SHA-256', data);
	return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Body limit of POST .../compare on the server (16 MB); checked before sending so the person gets a clear text, not a 413. */
export const MAX_MANIFEST_BYTES = 16 * 1024 * 1024;

export async function buildManifest(files: PickedFile[], onProgress?: (done: number, total: number) => void): Promise<ManifestEntry[] | 'tooMany' | 'empty'> {
	const picked = files.map((f) => ({ f, path: manifestPath(f.relativePath) })).filter((x): x is { f: PickedFile; path: string } => x.path !== null);
	if (picked.length === 0) return 'empty';
	if (picked.length > MAX_MANIFEST) return 'tooMany';
	const out: ManifestEntry[] = [];
	for (const [i, { f, path }] of picked.entries()) {
		out.push({ path, size: f.size, sha256: await sha256Hex(await f.bytes()) });
		onProgress?.(i + 1, picked.length);
	}
	out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
	return new TextEncoder().encode(JSON.stringify({ files: out })).length > MAX_MANIFEST_BYTES ? 'tooMany' : out;
}

// ---- file tree of a compare result ------------------------------------------------------------------------------------

export interface TreeFile {
	kind: 'file';
	name: string;
	/** Server path (relative to the base path); the stable key. */
	path: string;
	repoPath: string;
	status: SyncStatus;
	repoSize?: number;
	serverSize?: number;
}
export interface TreeDir {
	kind: 'dir';
	name: string;
	path: string;
	children: TreeNode[];
	/** Status counts of all files below. */
	counts: Partial<Record<SyncStatus, number>>;
	/** Number of files below. */
	total: number;
}
export type TreeNode = TreeFile | TreeDir;

/** Builds the folder tree along the server paths; folders first, then files, each alphabetically. */
export function buildTree(files: CompareFile[], onlyDifferences = false): TreeDir {
	const root: TreeDir = { kind: 'dir', name: '', path: '', children: [], counts: {}, total: 0 };
	const seen = new Set<string>();
	for (const f of files) {
		if (onlyDifferences && f.status === 'same') continue;
		const shown = f.serverPath || f.path;
		const segs = shown.split('/').filter(Boolean);
		// One row per server path (several repo files mapped onto the same path would collide).
		if (segs.length === 0 || seen.has(shown)) continue;
		seen.add(shown);
		let dir = root;
		dir.counts[f.status] = (dir.counts[f.status] ?? 0) + 1;
		dir.total += 1;
		for (const [i, seg] of segs.slice(0, -1).entries()) {
			const path = segs.slice(0, i + 1).join('/');
			let next = dir.children.find((c): c is TreeDir => c.kind === 'dir' && c.name === seg);
			if (!next) {
				next = { kind: 'dir', name: seg, path, children: [], counts: {}, total: 0 };
				dir.children.push(next);
			}
			next.counts[f.status] = (next.counts[f.status] ?? 0) + 1;
			next.total += 1;
			dir = next;
		}
		dir.children.push({ kind: 'file', name: segs[segs.length - 1], path: shown, repoPath: f.path, status: f.status, repoSize: f.repoSize, serverSize: f.serverSize });
	}
	sortTree(root);
	return root;
}

function sortTree(dir: TreeDir) {
	dir.children.sort((a, b) => (a.kind !== b.kind ? (a.kind === 'dir' ? -1 : 1) : a.name.localeCompare(b.name, 'de')));
	for (const c of dir.children) if (c.kind === 'dir') sortTree(c);
}

/** Counts per status from the summary, falling back to counting the files. */
export function summaryOf(result: DeployCompareResult): Record<SyncStatus, number> {
	const out = Object.fromEntries(SYNC_STATUSES.map((s) => [s, 0])) as Record<SyncStatus, number>;
	if (result.summary) {
		for (const s of SYNC_STATUSES) out[s] = result.summary[s] ?? 0;
		return out;
	}
	for (const f of result.files ?? []) if (f.status in out) out[f.status] += 1;
	return out;
}

/** Folders with more files than this start collapsed (a vendor/ folder would otherwise fill the view). */
export const OPEN_FOLDER_LIMIT = 50;

export const statusKey = (s: SyncStatus): MessageKey => `deploy.sync.status.${s}` as MessageKey;
export const countKey = (s: SyncStatus): MessageKey => `deploy.sync.count.${s}` as MessageKey;
