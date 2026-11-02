import { describe, expect, it } from 'vitest';
import { buildInviteLink, parseInviteCode } from '../src/lib/inviteLink';

describe('invite link', () => {
	it('puts the code in the fragment, not the query', () => {
		const link = buildInviteLink('https://todo.example', 'abc/+=123');
		expect(link).toBe('https://todo.example/setup#code=abc%2F%2B%3D123');
		expect(new URL(link).search).toBe('');
	});
	it('round-trips the code', () => {
		const url = new URL(buildInviteLink('https://x.test', 'a b&c#d'));
		expect(parseInviteCode(url.search, url.hash)).toBe('a b&c#d');
	});
	it('accepts the legacy query form and prefers the fragment', () => {
		expect(parseInviteCode('?token=old', '')).toBe('old');
		expect(parseInviteCode('?token=old', '#code=new')).toBe('new');
	});
	it('ignores missing, blank or oversized codes', () => {
		expect(parseInviteCode('', '')).toBe('');
		expect(parseInviteCode('?token=%20', '#code=')).toBe('');
		expect(parseInviteCode('', `#code=${'x'.repeat(201)}`)).toBe('');
	});
});
