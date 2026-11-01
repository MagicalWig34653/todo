import { describe, expect, it } from 'vitest';
import { createKeyedGate, createLatest } from '../src/lib/serial';

describe('createKeyedGate', () => {
	it('sends no second request for a key until the first one finished', async () => {
		const seen: string[][] = [];
		const gate = createKeyedGate((b) => seen.push(b));
		let calls = 0;
		let release!: () => void;
		const first = gate.run('g1', () => new Promise<void>((r) => { calls++; release = r; }));
		const second = await gate.run('g1', async () => { calls++; });
		expect(second).toBeUndefined();
		expect(calls).toBe(1);
		expect(gate.has('g1')).toBe(true);
		// another key is independent and does not free g1
		await gate.run('g2', async () => { calls++; });
		expect(gate.has('g1')).toBe(true);
		release();
		await first;
		expect(gate.has('g1')).toBe(false);
		expect(seen.at(-1)).toEqual([]);
		expect(calls).toBe(2);
		expect(await gate.run('g1', async () => 7)).toEqual({ value: 7 });
	});
	it('frees the key when the operation throws', async () => {
		const gate = createKeyedGate();
		await expect(gate.run('k', async () => { throw new Error('x'); })).rejects.toThrow('x');
		expect(gate.has('k')).toBe(false);
	});
});

describe('createLatest', () => {
	it('only the newest token is current', () => {
		const latest = createLatest();
		const a = latest.begin();
		const b = latest.begin();
		expect(a()).toBe(false);
		expect(b()).toBe(true);
	});
});
