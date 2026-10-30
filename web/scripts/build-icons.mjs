// Derives the PWA icons in web/static from the app icon layers in design/icon (no new design).
// Usage (repo root): SHARP_MODULE=/opt/homebrew/lib/node_modules/sharp node web/scripts/build-icons.mjs
// Outputs are committed; sharp is deliberately not a project dependency.
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, '../../design/icon');
const out = path.join(here, '../static');
const manifest = JSON.parse(await readFile(path.join(src, 'Todo.icon/icon.json'), 'utf8'));

const layerNames = ['background', ...manifest.groups.flatMap((g) => g.layers.map((l) => path.parse(l['image-name']).name))];
const svgs = new Map(await Promise.all(layerNames.map(async (n) => [n, await readFile(path.join(src, `${n}.svg`), 'utf8')])));

// The motif (three cards) spans 224..768 of the 1024 canvas; its centre is (496, 496).
const CX = 496;
const CY = 496;

function fillOf(obj, appearance) {
	return obj['fill-specializations']?.find((s) => s.appearance === appearance)?.value || obj.fill;
}
function hexes(fill) {
	return fill['linear-gradient'].map((s) => '#' + s.split(':')[1].split(',').slice(0, 3).map((v) => Math.round(Number(v) * 255).toString(16).padStart(2, '0')).join('').toUpperCase());
}

/** Full 1024 composite of background + layers, rendered from the SVG sources. */
async function composite() {
	const layers = [];
	for (const n of layerNames.slice(1)) layers.push({ input: await sharp(Buffer.from(svgs.get(n))).resize(1024, 1024).png().toBuffer() });
	return sharp(Buffer.from(svgs.get('background'))).resize(1024, 1024).composite(layers).png().toBuffer();
}

/** Square icon: motif centred, scaled by `scale` relative to the source composition, full-bleed background (opaque). */
async function square(full, size, scale) {
	const side = Math.round(1024 / scale);
	let left = Math.round(CX - side / 2);
	let top = Math.round(CY - side / 2);
	left = Math.max(0, Math.min(1024 - side, left));
	top = Math.max(0, Math.min(1024 - side, top));
	return sharp(full).extract({ left, top, width: side, height: side }).resize(size, size).flatten({ background: '#ffffff' }).png({ compressionLevel: 9 }).toBuffer();
}

// favicon.svg: vector composition with a dark-scheme override taken from icon.json (appearance "dark").
function faviconSvg() {
	const scale = 1.3;
	const side = 1024 / scale;
	const vb = `${(CX - side / 2).toFixed(1)} ${(CY - side / 2).toFixed(1)} ${side.toFixed(1)} ${side.toFixed(1)}`;
	const groupOf = new Map();
	for (const g of manifest.groups) for (const l of g.layers) groupOf.set(path.parse(l['image-name']).name, l);
	let defs = '';
	let body = '';
	let css = '';
	for (const n of layerNames) {
		const s = svgs.get(n);
		const light = [...s.matchAll(/stop-color="(#[0-9A-Fa-f]{6})"/g)].map((m) => m[1]);
		const dark = hexes(fillOf(n === 'background' ? manifest : groupOf.get(n), 'dark'));
		const grad = s.match(/<linearGradient[\s\S]*?<\/linearGradient>/)[0]
			.replace(/id="paint"/, `id="p-${n}"`)
			.replace(/<stop offset="0" stop-color="[^"]+"\/>/, `<stop offset="0" class="${n}-a" stop-color="${light[0]}"/>`)
			.replace(/<stop offset="1" stop-color="[^"]+"\/>/, `<stop offset="1" class="${n}-b" stop-color="${light[1]}"/>`);
		defs += grad;
		const inner = s.match(/<g id="[^"]+">[\s\S]*?<\/g>/)[0].replaceAll('url(#paint)', `url(#p-${n})`);
		body += inner;
		css += `.${n}-a{stop-color:${dark[0]}}.${n}-b{stop-color:${dark[1]}}`;
	}
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" color-interpolation="sRGB">
<title>Todolino</title>
<defs>${defs}<clipPath id="clip"><rect x="${(CX - side / 2).toFixed(1)}" y="${(CY - side / 2).toFixed(1)}" width="${side.toFixed(1)}" height="${side.toFixed(1)}" rx="${(side * 0.22).toFixed(1)}"/></clipPath>
<style>@media (prefers-color-scheme:dark){${css}}</style></defs>
<g clip-path="url(#clip)">${body}</g>
</svg>
`;
}

/** ICO container with PNG-compressed entries. */
function ico(entries) {
	const head = Buffer.alloc(6);
	head.writeUInt16LE(1, 2);
	head.writeUInt16LE(entries.length, 4);
	let offset = 6 + 16 * entries.length;
	const dirs = entries.map(({ size, png }) => {
		const d = Buffer.alloc(16);
		d[0] = size;
		d[1] = size;
		d.writeUInt16LE(1, 4);
		d.writeUInt16LE(32, 6);
		d.writeUInt32LE(png.length, 8);
		d.writeUInt32LE(offset, 12);
		offset += png.length;
		return d;
	});
	return Buffer.concat([head, ...dirs, ...entries.map((e) => e.png)]);
}

const full = await composite();
const files = {
	'icon-192.png': await square(full, 192, 1.3),
	'icon-512.png': await square(full, 512, 1.3),
	// Maskable: full-bleed background, motif inside the central safe zone (circle r = 40 % of the side).
	'maskable-512.png': await square(full, 512, 1.0),
	'apple-touch-icon.png': await square(full, 180, 1.25)
};
const fav = faviconSvg();
files['favicon.svg'] = fav;
files['favicon.ico'] = ico([
	{ size: 32, png: await square(full, 32, 1.3) },
	{ size: 48, png: await square(full, 48, 1.3) }
]);
for (const [name, data] of Object.entries(files)) {
	await writeFile(path.join(out, name), data);
	console.log(`${name}: ${data.length} bytes`);
}
