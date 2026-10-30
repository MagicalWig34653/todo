import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const file = (name: string) => readFileSync(new URL(`../static/${name}`, import.meta.url));

/** Reads width/height/colour type from a PNG IHDR. */
function png(buf: Buffer) {
	expect(buf.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
	return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), colorType: buf[25] };
}

describe('PWA icons', () => {
	const manifest = JSON.parse(file('manifest.webmanifest').toString());

	it('declares identity and de language', () => {
		expect(manifest).toMatchObject({ id: '/', name: 'Todo', lang: 'de', scope: '/', start_url: '/' });
	});

	it('lists any and maskable icons whose files exist with the declared size', () => {
		const purposes = new Set(manifest.icons.map((i: { purpose: string }) => i.purpose));
		expect(purposes).toEqual(new Set(['any', 'maskable']));
		for (const icon of manifest.icons as { src: string; sizes: string; type: string }[]) {
			const buf = file(icon.src.replace(/^\//, ''));
			if (icon.type === 'image/png') {
				const [w, h] = icon.sizes.split('x').map(Number);
				expect(png(buf)).toMatchObject({ w, h });
			} else {
				expect(buf.toString()).toContain('<svg');
			}
		}
	});

	it('ships opaque apple-touch-icon (180) and a 32/48 favicon.ico', () => {
		const apple = png(file('apple-touch-icon.png'));
		expect(apple).toMatchObject({ w: 180, h: 180 });
		expect(file('apple-touch-icon.png')[25]).not.toBe(6); // not RGBA
		const ico = file('favicon.ico');
		expect(ico.readUInt16LE(2)).toBe(1);
		const count = ico.readUInt16LE(4);
		const sizes = Array.from({ length: count }, (_, i) => ico[6 + i * 16]);
		expect(sizes).toEqual([32, 48]);
	});

	it('links icons and theme colours in app.html', () => {
		const html = readFileSync(new URL('../src/app.html', import.meta.url), 'utf8');
		for (const needle of ['favicon.svg', 'favicon.ico', 'apple-touch-icon.png', 'prefers-color-scheme: light', 'prefers-color-scheme: dark']) {
			expect(html).toContain(needle);
		}
	});
});
