import { describe, expect, it } from 'vitest';
import { ApiError } from '../src/lib/api.js';
import { buildManifest, buildTree, deployErrorText, emptyForm, endpointLabel, formOf, manifestPath, summaryOf, writeBody, type DeployTarget } from '../src/lib/deploy.js';

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
		expect(buildTree(files, true).children.map((c) => c.name)).toEqual(['css', 'htdocs']);
		expect(summaryOf({ ok: true, files })).toEqual({ changed: 1, new: 1, serverOnly: 1, unverified: 0, same: 1 });
	});
});
