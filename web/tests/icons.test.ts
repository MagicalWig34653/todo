import { existsSync, readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';

const file = (name: string) => readFileSync(new URL(`../static/${name}`, import.meta.url));
const design = (name: string) => readFileSync(new URL(`../../design/icon/${name}`, import.meta.url), 'utf8');

type Rgba = [number, number, number, number];
const rgb = (hex: string): Rgba => [...[1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)), 255] as Rgba;
const NAVY = rgb('#1C2646');
const RED = rgb('#E9412B');

/** Decodes the 8 bit RGB/RGBA, non interlaced PNGs this project ships. */
function png(buf: Buffer) {
	expect(buf.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
	const w = buf.readUInt32BE(16);
	const h = buf.readUInt32BE(20);
	const colorType = buf[25];
	const chunks: string[] = [];
	const data: Buffer[] = [];
	for (let at = 8; at < buf.length; at += buf.readUInt32BE(at) + 12) {
		const type = buf.toString('ascii', at + 4, at + 8);
		chunks.push(type);
		if (type === 'IDAT') data.push(buf.subarray(at + 8, at + 8 + buf.readUInt32BE(at)));
	}
	const opaque = colorType === 2 && !chunks.includes('tRNS');
	const pixels = () => {
		expect([buf[24], buf[28]]).toEqual([8, 0]);
		const bpp = colorType === 6 ? 4 : 3;
		expect([2, 6]).toContain(colorType);
		const raw = inflateSync(Buffer.concat(data));
		const stride = w * bpp;
		const out = Buffer.alloc(stride * h);
		for (let y = 0; y < h; y++) {
			const filter = raw[y * (stride + 1)];
			for (let x = 0; x < stride; x++) {
				const a = x >= bpp ? out[y * stride + x - bpp] : 0;
				const b = y ? out[(y - 1) * stride + x] : 0;
				const c = y && x >= bpp ? out[(y - 1) * stride + x - bpp] : 0;
				const p = a + b - c;
				const paeth = Math.abs(p - a) <= Math.abs(p - b) && Math.abs(p - a) <= Math.abs(p - c) ? a : Math.abs(p - b) <= Math.abs(p - c) ? b : c;
				out[y * stride + x] = (raw[y * (stride + 1) + 1 + x] + [0, a, b, (a + b) >> 1, paeth][filter]) & 255;
			}
		}
		return (x: number, y: number): Rgba => {
			const i = y * stride + x * bpp;
			return [out[i], out[i + 1], out[i + 2], bpp === 4 ? out[i + 3] : 255];
		};
	};
	return { w, h, opaque, pixels };
}

const distance = (a: Rgba, b: Rgba) => Math.max(...a.map((v, i) => Math.abs(v - b[i])));

function icoEntries() {
	const ico = file('favicon.ico');
	expect(ico.readUInt16LE(2)).toBe(1);
	return Array.from({ length: ico.readUInt16LE(4) }, (_, i) => {
		const at = 6 + i * 16;
		const offset = ico.readUInt32LE(at + 12);
		return { size: ico[at], image: png(ico.subarray(offset, offset + ico.readUInt32LE(at + 8))) };
	});
}

describe('PWA icons', () => {
	const manifest = JSON.parse(file('manifest.webmanifest').toString());

	it('declares identity and de language', () => {
		expect(manifest).toMatchObject({ id: '/', name: 'Todolino', lang: 'de', scope: '/', start_url: '/' });
	});

	it('lists any and maskable icons whose files exist with the declared size', () => {
		const purposes = new Set(manifest.icons.map((i: { purpose: string }) => i.purpose));
		expect(purposes).toEqual(new Set(['any', 'maskable']));
		for (const icon of manifest.icons as { src: string; sizes: string; type: string }[]) {
			// Chrome treats icon URLs as immutable: installed apps only notice new artwork under a new URL.
			expect(icon.src).toMatch(/^\/[\w-]+\.png\?v=2$/);
			const buf = file(icon.src.slice(1).split('?')[0]);
			expect(icon.type).toBe('image/png');
			const [w, h] = icon.sizes.split('x').map(Number);
			expect(png(buf), icon.src).toMatchObject({ w, h });
		}
	});

	it('ships opaque square PNGs showing the block check (apple-touch 180, 192, 512, maskable)', () => {
		for (const [name, size] of [['apple-touch-icon.png', 180], ['icon-192.png', 192], ['icon-512.png', 512], ['maskable-512.png', 512]] as const) {
			const image = png(file(name));
			expect(image, name).toMatchObject({ w: size, h: size, opaque: true });
			const at = image.pixels();
			let navy = 0;
			let red = 0;
			for (let y = 0; y < size; y++)
				for (let x = 0; x < size; x++) {
					if (distance(at(x, y), NAVY) <= 4) navy++;
					if (distance(at(x, y), RED) <= 4) red++;
				}
			// Three dark blocks and one red block, each well above a tenth of the canvas width.
			expect(red / (size * size), name).toBeGreaterThan(0.025);
			expect(navy / red, name).toBeGreaterThan(2.5);
		}
	});

	it('keeps the maskable motif inside the safe circle with reserve', () => {
		const image = png(file('maskable-512.png'));
		const at = image.pixels();
		let farthest = 0;
		for (let y = 0; y < 512; y++) {
			const background = at(0, y); // full-bleed vertical gradient
			for (let x = 0; x < 512; x++) if (distance(at(x, y), background) > 24) farthest = Math.max(farthest, Math.hypot(x + 0.5 - 256, y + 0.5 - 256));
		}
		expect(farthest).toBeGreaterThan(150);
		expect(farthest / 512).toBeLessThanOrEqual(0.39); // safe zone is 0.40
	});

	it('ships a 16/32/48 favicon.ico drawn on the pixel grid', () => {
		const entries = icoEntries();
		expect(entries.map((e) => e.size)).toEqual([16, 32, 48]);
		for (const { size, image } of entries) {
			expect(image).toMatchObject({ w: size, h: size });
			const at = image.pixels();
			const k = size / 16;
			// 16 px grid: four 4 × 4 blocks, 3 px apart, with the shared pixel left open as a gap.
			const blocks = [[1, 6], [4, 9], [7, 6], [10, 3]];
			const gaps = [[4, 9], [7, 9], [10, 6]];
			for (let y = 3 * k; y < 13 * k; y++)
				for (let x = k; x < 15 * k; x++) {
					const gx = Math.floor(x / k);
					const gy = Math.floor(y / k);
					const gap = gaps.some(([px, py]) => px === gx && py === gy);
					const block = gap ? -1 : blocks.findIndex(([bx, by]) => gx >= bx && gx < bx + 4 && gy >= by && gy < by + 4);
					const pixel = at(x, y);
					if (block >= 0) expect(pixel, `${size}px ${x},${y}`).toEqual(block === 3 ? RED : NAVY);
					else expect(pixel[2] < 120 && pixel[0] > 240 && pixel[1] > 180, `${size}px yellow at ${x},${y}: ${pixel}`).toBe(true);
				}
		}
	});

	it('draws favicon.svg in the colours of both schemes and keeps it equal to the design source', () => {
		const svg = file('favicon.svg').toString();
		expect(svg).toBe(design('favicon.svg'));
		const [light, dark] = svg.split('@media (prefers-color-scheme:dark)');
		for (const colour of ['#FFD94F', '#FFBC1C', '#1C2646', '#E9412B']) expect(light).toContain(colour);
		for (const colour of ['#1E1C17', '#0D0C09', '#FFCB33', '#FF6549']) expect(dark).toContain(colour);
	});

	it('links exactly these icons in app.html and nowhere else', () => {
		const html = readFileSync(new URL('../src/app.html', import.meta.url), 'utf8');
		for (const needle of ['favicon.svg?v=2', 'favicon.ico?v=2', 'sizes="16x16 32x32 48x48"', 'apple-touch-icon.png?v=2', 'prefers-color-scheme: light', 'prefers-color-scheme: dark']) {
			expect(html).toContain(needle);
		}
		// The layout used to add the Svelte logo as a further tab icon.
		expect(readFileSync(new URL('../src/routes/+layout.svelte', import.meta.url), 'utf8')).not.toContain('rel="icon"');
		expect(existsSync(new URL('../src/lib/assets/favicon.svg', import.meta.url))).toBe(false);
	});
});

describe('Apple icon source design/icon/Todo.icon', () => {
	type Node = { name?: string; fill?: unknown; 'fill-specializations'?: { appearance?: string; value: unknown }[]; 'image-name'?: string; layers?: Node[]; groups?: Node[] };
	const icon: Node = JSON.parse(design('Todo.icon/icon.json'));

	it('lists the red block first, because the first group is drawn in front', () => {
		expect(icon.groups?.map((g) => g.layers?.map((l) => l['image-name']))).toEqual([['block-next.svg'], ['blocks-done.svg']]);
	});

	it('never puts a plain fill beside the appearance variants, which would override them', () => {
		const nodes = [icon, ...(icon.groups ?? []).flatMap((g) => [g, ...(g.layers ?? [])])];
		for (const node of nodes) expect(node.fill, node.name ?? 'root').toBeUndefined();
		for (const node of [icon, ...(icon.groups ?? []).flatMap((g) => g.layers ?? [])]) {
			expect(node['fill-specializations']?.map((s) => s.appearance), node.name ?? 'root').toEqual([undefined, 'dark', 'tinted']);
		}
	});

	it('references assets that exist and match the layer sources', () => {
		for (const layer of icon.groups?.flatMap((g) => g.layers ?? []) ?? []) {
			expect(design(`Todo.icon/Assets/${layer['image-name']}`)).toBe(design(layer['image-name']!));
		}
	});
});
