import { describe, expect, it } from 'vitest';
import { base64urlToBuffer, bufferToBase64url, toCreationOptions, toRequestOptions } from '../src/lib/webauthn';

describe('base64url', () => {
	it('round-trips bytes including url-unsafe characters and no padding', () => {
		const bytes = new Uint8Array([251, 255, 190, 0, 1, 2, 3]);
		const encoded = bufferToBase64url(bytes);
		expect(encoded).not.toMatch(/[+/=]/);
		expect(new Uint8Array(base64urlToBuffer(encoded))).toEqual(bytes);
	});

	it('decodes known vector', () => {
		expect(new TextDecoder().decode(base64urlToBuffer('aGVsbG8'))).toBe('hello');
		expect(bufferToBase64url(new TextEncoder().encode('hello'))).toBe('aGVsbG8');
	});
});

describe('option conversion', () => {
	it('converts creation options fields to buffers', () => {
		const o = toCreationOptions({
			challenge: 'aGVsbG8',
			user: { id: 'aGVsbG8', name: 'a', displayName: 'a' },
			excludeCredentials: [{ id: 'aGVsbG8', type: 'public-key' }],
			rp: { id: 'localhost', name: 'Todolino' }
		});
		expect(o.challenge).toBeInstanceOf(ArrayBuffer);
		expect(o.user.id).toBeInstanceOf(ArrayBuffer);
		expect(o.excludeCredentials?.[0].id).toBeInstanceOf(ArrayBuffer);
		expect((o as unknown as { rp: unknown }).rp).toEqual({ id: 'localhost', name: 'Todolino' });
	});

	it('handles request options without allowCredentials', () => {
		const o = toRequestOptions({ challenge: 'aGVsbG8' });
		expect(o.challenge).toBeInstanceOf(ArrayBuffer);
		expect(o.allowCredentials).toBeUndefined();
	});
});
