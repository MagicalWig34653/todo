import { describe, expect, it } from 'vitest';
import { placePanel } from '../src/lib/floating.js';

const anchor = (left: number, top: number, w = 32, h = 32) => ({ left, top, right: left + w, bottom: top + h });
const inside = (p: ReturnType<typeof placePanel>, w: number, h: number, vw: number, vh: number) => {
	const shownH = Math.min(h, p.maxHeight);
	const shownW = Math.min(w, p.maxWidth);
	expect(p.left).toBeGreaterThanOrEqual(8);
	expect(p.top).toBeGreaterThanOrEqual(8);
	expect(p.left + shownW).toBeLessThanOrEqual(vw - 8);
	expect(p.top + shownH).toBeLessThanOrEqual(vh - 8);
};

describe('placePanel', () => {
	it('opens below, aligned to the end for a top-right trigger', () => {
		const p = placePanel(anchor(330, 8), { width: 288, height: 300 }, { width: 390, height: 800 }, { align: 'end' });
		expect(p.side).toBe('bottom');
		inside(p, 288, 300, 390, 800);
	});
	it('shifts into the viewport at 320px', () => {
		const p = placePanel(anchor(280, 8), { width: 288, height: 200 }, { width: 320, height: 640 }, { align: 'start' });
		expect(p.left).toBe(320 - 288 - 8);
		inside(p, 288, 200, 320, 640);
	});
	it('caps the width below the viewport', () => {
		const p = placePanel(anchor(10, 8), { width: 500, height: 100 }, { width: 320, height: 640 });
		expect(p.maxWidth).toBe(304);
		inside(p, 500, 100, 320, 640);
	});
	it('flips above when below is too small', () => {
		const p = placePanel(anchor(10, 700), { width: 200, height: 300 }, { width: 390, height: 800 });
		expect(p.side).toBe('top');
		inside(p, 200, 300, 390, 800);
	});
	it('caps the height and scrolls when the panel fits neither side (landscape)', () => {
		const p = placePanel(anchor(700, 8), { width: 288, height: 600 }, { width: 844, height: 390 }, { align: 'end' });
		expect(p.maxHeight).toBeLessThan(600);
		inside(p, 288, 600, 844, 390);
	});
	it('overlays the anchor when neither side is usable', () => {
		const p = placePanel(anchor(10, 150, 32, 32), { width: 200, height: 600 }, { width: 390, height: 340 }, { minUsable: 200 });
		expect(p.side).toBe('overlay');
		expect(p.maxHeight).toBe(324);
		inside(p, 200, 600, 390, 340);
	});
	it('stays inside for a sweep of geometries', () => {
		for (const vw of [320, 360, 390, 844]) {
			for (const vh of [320, 390, 640, 800]) {
				for (const ax of [0, vw / 2, vw - 40]) {
					for (const ay of [0, vh / 2, vh - 40]) {
						for (const align of ['start', 'end'] as const) {
							const p = placePanel(anchor(ax, ay, 40, 32), { width: 288, height: 700 }, { width: vw, height: vh }, { align });
							inside(p, 288, 700, vw, vh);
						}
					}
				}
			}
		}
	});
});
