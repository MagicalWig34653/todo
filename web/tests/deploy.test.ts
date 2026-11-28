import { describe, expect, it, vi } from 'vitest';
import { ApiError, api } from '../src/lib/api.js';
import { buildManifest, buildTree, deployErrorText, emptyForm, endpointLabel, formOf, manifestPath, summaryOf, writeBody, canApprove, hasOpenRollback, isOpenPlan, sortPlans, type DeployPlan, type DeployTarget } from '../src/lib/deploy.js';

const target: DeployTarget = {
	id: 't1',
	projectID: 'p1',
	name: 'Kubus Test',
	stage: 'test',
	protocol: 'sftp',
	host: 'sftp.example.com',
	port: 22,
	basePath: 'site',
	username: 'deploy',
	authMethod: 'password',
	hostKey: { confirmed: false },
	tlsCertificatePinned: false,
	rules: { includes: [], excludes: ['cache/**'], mappings: [], defaultExcludes: true },
	effectiveExcludes: ['cache/**', '**/.git/**'],
	createdAt: '2026-11-27T00:00:00Z',
	updatedAt: '2026-11-27T00:00:00Z'
};

describe('deploy form', () => {
	it('needs name, host, user and a secret for a new target; empty port = protocol default', () => {
		expect(writeBody(emptyForm())).toEqual({ problem: 'name' });
		const f = { ...emptyForm(), name: 'A', host: 'h', username: 'u' };
		expect(writeBody(f)).toEqual({ problem: 'secret' });
		const ok = writeBody({ ...f, password: 'pw', protocol: 'ftps-implicit' });
		expect('body' in ok && ok.body).toMatchObject({ port: 990, password: 'pw', protocol: 'ftps-implicit' });
		expect(writeBody({ ...f, password: 'pw', port: '70000' })).toEqual({ problem: 'port' });
		expect(writeBody({ ...f, password: 'pw', port: '0x16' })).toEqual({ problem: 'port' });
		expect(writeBody({ ...f, password: 'pw', port: '1e3' })).toEqual({ problem: 'port' });
		expect(writeBody({ ...f, password: 'pw', mappings: 'public htdocs' })).toEqual({ problem: 'mappings' });
	});

	it('sends only what changed when editing, never an empty secret', () => {
		const form = formOf(target);
		expect(form.port).toBe('');
		expect(writeBody(form, target)).toEqual({ body: {} });
		const renamed = writeBody({ ...form, name: 'Neu', excludes: 'cache/**\n*.log' }, target);
		expect(renamed).toEqual({ body: { name: 'Neu', rules: { includes: [], excludes: ['cache/**', '*.log'], mappings: [], defaultExcludes: true } } });
		const withKey = writeBody({ ...form, auth: 'key', privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----' }, target);
		expect(withKey).toEqual({ body: { privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----', password: null } });
		// Neither the login method nor a passphrase changes without the secret itself.
		expect(writeBody({ ...form, auth: 'key' }, target)).toEqual({ problem: 'authChange' });
		expect(writeBody({ ...form, auth: 'key', passphrase: 'p' }, { ...target, authMethod: 'key' })).toEqual({ problem: 'passphrase' });
		const ftps = { ...target, protocol: 'ftps', port: 21, tlsCertificatePinned: true };
		expect(writeBody({ ...formOf(ftps), removeCertificate: true }, ftps)).toEqual({ body: { tlsCertificate: null } });
	});

	it('parses mappings and shows the endpoint', () => {
		const r = writeBody({ ...formOf(target), mappings: 'public -> htdocs' }, target);
		expect('body' in r && r.body.rules?.mappings).toEqual([{ local: 'public', remote: 'htdocs' }]);
		expect(endpointLabel(target)).toBe('deploy@sftp.example.com:22/site');
		expect(endpointLabel({ ...target, host: '::1', basePath: '' })).toBe('deploy@[::1]:22');
	});

	it('maps reason codes to fixed texts, unknown ones to a generic text', () => {
		expect(deployErrorText(new ApiError(400, 'deploy_credentials_required'))).toContain('neu eingeben');
		expect(deployErrorText('deploy_host_key_mismatch')).toContain('anderen Host-Schlüssel');
		expect(deployErrorText(new ApiError(400, '<script>'))).toBe('Das hat nicht geklappt. Bitte erneut versuchen.');
	});
});

describe('manifest and tree', () => {
	it('drops the picked folder name and skips .git and node_modules', () => {
		expect(manifestPath('kubus/css/app.css')).toBe('css/app.css');
		expect(manifestPath('kubus/.git/HEAD')).toBeNull();
		expect(manifestPath('kubus/a/node_modules/x.js')).toBeNull();
		expect(manifestPath('kubus')).toBeNull();
	});

	it('reports an empty folder instead of sending an empty manifest', async () => {
		const none = async () => new ArrayBuffer(0);
		expect(await buildManifest([{ relativePath: 'only-name.txt', size: 0, bytes: none }])).toBe('empty');
		expect(await buildManifest([{ relativePath: 'r/.git/HEAD', size: 0, bytes: none }])).toBe('empty');
	});

	it('hashes files with SHA-256, sorted by path', async () => {
		const bytes = (s: string) => async () => new TextEncoder().encode(s).buffer as ArrayBuffer;
		const m = await buildManifest([
			{ relativePath: 'r/b.txt', size: 3, bytes: bytes('hi\n') },
			{ relativePath: 'r/a.txt', size: 0, bytes: bytes('') }
		]);
		expect(m).toEqual([
			{ path: 'a.txt', size: 0, sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' },
			{ path: 'b.txt', size: 3, sha256: '98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4' }
		]);
	});

	it('builds folders first with counts; only differences hides same files', () => {
		const files = [
			{ path: 'index.php', serverPath: 'index.php', status: 'same' as const },
			{ path: 'css/app.css', serverPath: 'css/app.css', status: 'changed' as const },
			{ path: '', serverPath: 'css/designer.css', status: 'serverOnly' as const },
			{ path: 'public/a.php', serverPath: 'htdocs/a.php', status: 'new' as const }
		];
		const tree = buildTree(files);
		expect(tree.children.map((c) => c.name)).toEqual(['css', 'htdocs', 'index.php']);
		const css = tree.children[0];
		expect(css.kind === 'dir' && css.counts).toEqual({ changed: 1, serverOnly: 1 });
		expect(css.kind === 'dir' && css.total).toBe(2);
		expect(buildTree(files, true).children.map((c) => c.name)).toEqual(['css', 'htdocs']);
		// A file and a folder of the same name, and two repo files on one server path: distinct rows, no crash.
		const clash = buildTree([
			{ path: 'a', serverPath: 'a', status: 'new' },
			{ path: 'x/a/b', serverPath: 'a/b', status: 'new' },
			{ path: 'y/a/b', serverPath: 'a/b', status: 'changed' }
		]);
		expect(clash.children.map((c) => `${c.kind}:${c.path}`)).toEqual(['dir:a', 'file:a']);
		expect(clash.total).toBe(2);
		expect(summaryOf({ ok: true, files })).toEqual({ changed: 1, new: 1, serverOnly: 1, unverified: 0, same: 1 });
	});
});

const plan = (over: Partial<DeployPlan> = {}): DeployPlan => ({
	id: 'a',
	targetID: 't1',
	targetName: 'Kubus Test',
	kind: 'upload',
	state: 'requested',
	createdAt: '2026-11-28T10:00:00Z',
	expiresAt: '2026-11-29T10:00:00Z',
	overrideDrift: false,
	summary: { upload: 1, delete: 0, unchanged: 0, serverOnly: 0, blocked: 0, skipped: 0 },
	files: [],
	blockers: [],
	findings: [],
	blocked: false,
	overridable: false,
	written: [],
	canRollback: false,
	...over
});

describe('deploy upload plans', () => {
	it('offers approval only for open plans whose locks can be overridden', () => {
		expect(['planned', 'requested', 'rejected', 'expired', 'running', 'succeeded', 'failed'].filter((state) => isOpenPlan(plan({ state })))).toEqual(['planned', 'requested']);
		expect(canApprove(plan())).toBe(true);
		expect(canApprove(plan({ blocked: true, overridable: true }))).toBe(true);
		expect(canApprove(plan({ blocked: true, overridable: false }))).toBe(false);
		expect(canApprove(plan({ state: 'succeeded' }))).toBe(false);
	});

	it('shows waiting requests first and hides a second way back', () => {
		const run = plan({ id: 'run', state: 'succeeded', canRollback: true });
		const back = plan({ id: 'back', kind: 'rollback', state: 'planned', sourcePlanID: 'run' });
		expect(sortPlans([run, back, plan({ id: 'ask' })]).map((p) => p.id)).toEqual(['ask', 'run', 'back']);
		expect(hasOpenRollback([run, back], run)).toBe(true);
		expect(hasOpenRollback([run, { ...back, state: 'rejected' }], run)).toBe(false);
	});

	it('has a text for every reason a person can meet when deciding', () => {
		const codes = ['blocked', 'stale', 'expired', 'decided', 'not_requested', 'limit', 'too_large'].map((c) => `deploy_plan_${c}`);
		codes.push('deploy_target_busy', 'deploy_stage_not_supported', 'deploy_rollback_not_latest', 'deploy_backup_missing', 'deploy_interrupted', 'deploy_verify_failed', 'deploy_symlink_in_path', 'deploy_content_unreadable', 'deploy_failed');
		for (const code of codes) expect(deployErrorText(code), code).not.toBe(deployErrorText('something_else'));
	});

	it('approves with the explicit override flag and never sends file contents', async () => {
		const calls: { url: string; method: string; body: unknown }[] = [];
		vi.stubGlobal('fetch', async (url: string, init: RequestInit = {}) => {
			calls.push({ url: String(url), method: init.method ?? 'GET', body: init.body ? JSON.parse(String(init.body)) : undefined });
			return new Response(JSON.stringify({ items: [] }), { status: 200, headers: { 'Content-Type': 'application/json' } });
		});
		await api.deployPlans('t 1');
		await api.requestDeployPlan('p1');
		await api.approveDeployPlan('p1', true);
		await api.rejectDeployPlan('p1');
		await api.rollbackDeployPlan('p1');
		vi.unstubAllGlobals();
		expect(calls.map((c) => `${c.method} ${c.url.replace(/^.*\/v1/, '')}`)).toEqual([
			'GET /deploy-targets/t%201/plans',
			'POST /deploy-plans/p1/request',
			'POST /deploy-plans/p1/approve',
			'POST /deploy-plans/p1/reject',
			'POST /deploy-plans/p1/rollback'
		]);
		expect(calls[2].body).toEqual({ overrideDrift: true });
	});
});
