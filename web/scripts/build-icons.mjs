// Writes the PWA icons in web/static from the sources in design/icon (no design decisions here beyond the framing).
// Usage (repo root): SHARP_MODULE=/opt/homebrew/lib/node_modules/sharp node web/scripts/build-icons.mjs
// Outputs are committed; sharp is deliberately not a project dependency. When the artwork changes, raise the `?v=` number in
// web/static/manifest.webmanifest and web/src/app.html: installed apps treat icon URLs as immutable.
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, '../../design/icon');
const out = path.join(here, '../static');
const read = (name) => readFile(path.join(src, name), 'utf8');

const inner = (svg) => svg.slice(svg.indexOf('>') + 1, svg.lastIndexOf('</svg>'));
const [background, done, next, favicon] = await Promise.all(['background.svg', 'blocks-done.svg', 'block-next.svg', 'favicon.svg'].map(read));

const raster = (svg) => sharp(Buffer.from(svg), { density: 72 });

/** Opaque square icon: full-bleed background, motif scaled by `scale` around the centre of the 1024 canvas. */
function square(size, scale) {
	const motif = `<g transform="translate(512 512) scale(${scale}) translate(-512 -512)">${inner(done)}${inner(next)}</g>`;
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024">${inner(background)}${motif}</svg>`;
	return raster(svg).removeAlpha().png({ compressionLevel: 9 }).toBuffer();
}

/** Light-scheme favicon at exactly `size` pixels, so the 16 px grid of favicon.svg lands on whole pixels. */
function tab(size) {
	const light = favicon.replace(/@media \(prefers-color-scheme:dark\)\{(?:[^{}]*\{[^{}]*\})*\}/, '');
	return raster(light.replace('width="32" height="32"', `width="${size}" height="${size}"`)).ensureAlpha().png({ compressionLevel: 9 }).toBuffer();
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

const files = {
	// Shown unmasked or with rounded corners: a little larger than the Apple canvas.
	'icon-192.png': await square(192, 1.06),
	'icon-512.png': await square(512, 1.06),
	// Maskable: the whole motif stays within r = 38 % of the side (safe zone 40 %).
	'maskable-512.png': await square(512, 0.9),
	'apple-touch-icon.png': await square(180, 1.04),
	'favicon.svg': favicon,
	'favicon.ico': ico(await Promise.all([16, 32, 48].map(async (size) => ({ size, png: await tab(size) }))))
};
for (const [name, data] of Object.entries(files)) {
	await writeFile(path.join(out, name), data);
	console.log(`${name}: ${data.length} bytes`);
}
