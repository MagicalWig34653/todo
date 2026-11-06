import { describe, expect, it } from 'vitest';
import { de } from '../src/lib/i18n/de';
import { repositoryLink } from '../src/lib/syncState';

describe('repositoryLink', () => {
	it('links normalized git remotes (host/owner/repo) over https', () => {
		expect(repositoryLink('github.com/example/kueche')).toBe('https://github.com/example/kueche');
		expect(repositoryLink('gitlab.example.org/group/sub/repo')).toBe('https://gitlab.example.org/group/sub/repo');
	});
	it('does not link free keys, empty values or anything with a scheme/whitespace', () => {
		for (const v of ['my-key', 'todolino', '', '  ', null, undefined, 'javascript:alert(1)', 'https://x.io/a/b', 'github.com/a b/c', 'github.com/a/b?x=1'])
			expect(repositoryLink(v as string)).toBeNull();
	});
	it('has German texts for the repository line', () => {
		for (const k of ['sync.repoOpen', 'sync.repoError', 'sync.repoNone'] as const) expect(de[k]).toBeTruthy();
	});
});
