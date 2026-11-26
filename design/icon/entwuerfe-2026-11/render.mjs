// Generates all draft files from designs.mjs. Repeatable; writes only inside this folder.
//   node design/icon/entwuerfe-2026-11/render.mjs
// SHARP_MODULE and ICTOOL may point to other installations. Without ictool the Apple previews are
// flat sharp composites and are labelled as such on the boards (see render-info.json).
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { designs } from './designs.mjs';
import { board, overview } from './boards.mjs';

const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || '/opt/homebrew/lib/node_modules/sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const ictool = process.env.ICTOOL || '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool';
const ictoolVersion = existsSync(ictool)
  ? JSON.parse(execFileSync(ictool, ['--version'], { encoding: 'utf8' }))['short-bundle-version']
  : null;

const SVG_OPEN = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">';

/** Markup of one layer in a given paint; `paint` is a colour or a class attribute. */
function markup(layer, paint) {
  const isClass = paint.startsWith('class=');
  if (layer.stroke) {
    const stroke = isClass ? paint : `stroke="${paint}"`;
    return `<path d="${layer.stroke.d}" fill="none" stroke-width="${layer.stroke.width}" stroke-linecap="round" stroke-linejoin="round" ${stroke}/>`;
  }
  return layer.draw(isClass ? paint : `fill="${paint}"`);
}

const gradient = (stops, id = 'bg') =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${stops[0]}"/><stop offset="1" stop-color="${stops[1]}"/></linearGradient>`;
const backgroundSvg = (stops) => `${SVG_OPEN}<defs>${gradient(stops)}</defs><rect width="1024" height="1024" fill="url(#bg)"/></svg>\n`;
const layerSvg = (layer, appearance = 0) => `${SVG_OPEN}${markup(layer, layer.colors[appearance])}</svg>\n`;

/** Simplified motif for tab sizes. With `scheme` undefined it follows prefers-color-scheme. */
function faviconSvg(design, scheme) {
  const { background, darkBackground = design.background[1], shapes } = design.favicon;
  const stops = scheme === 'dark' ? darkBackground : background;
  const body = shapes.map((s, i) => markup(s, scheme === undefined ? `class="s${i}"` : s.colors[scheme === 'dark' ? 1 : 0])).join('');
  let style = '';
  if (scheme === undefined) {
    const rules = (mode) => shapes.map((s, i) => `.s${i}{${s.stroke ? 'stroke' : 'fill'}:${s.colors[mode]}}`).join('');
    style = `<style>${rules(0)}@media (prefers-color-scheme:dark){${rules(1)}.a{stop-color:${darkBackground[0]}}.b{stop-color:${darkBackground[1]}}}</style>`;
  }
  const grad = gradient(stops).replace('offset="0"', 'class="a" offset="0"').replace('offset="1"', 'class="b" offset="1"');
  return `${SVG_OPEN.replace(' width="1024" height="1024"', '')}<title>Todolino</title>${style}<defs>${grad}</defs><rect width="1024" height="1024" rx="208" fill="url(#bg)"/>${body}</svg>\n`;
}

// --- Icon Composer bundle -------------------------------------------------------------------------
const srgb = (hex) => `srgb:${[1, 3, 5].map((i) => (parseInt(hex.slice(i, i + 2), 16) / 255).toFixed(5)).join(',')},1.00000`;
const specializations = (values) => [
  { value: values[0] },
  { appearance: 'dark', value: values[1] },
  { appearance: 'tinted', value: values[2] }
];

function iconJson(design) {
  return {
    'fill-specializations': specializations(design.background.map((stops) => ({
      'linear-gradient': stops.map(srgb),
      orientation: { start: { x: 0.5, y: 0 }, stop: { x: 0.5, y: 1 } }
    }))),
    // Icon Composer lists groups front to back: the first group is drawn on top.
    groups: [...design.layers].reverse().map((layer) => ({
      name: layer.name,
      layers: [{
        name: layer.name,
        'image-name': `${layer.id}.svg`,
        'fill-specializations': specializations(layer.colors.map((c) => ({ solid: srgb(c) }))),
        glass: true
      }],
      shadow: { kind: 'neutral', opacity: 0.35 },
      specular: true,
      translucency: { enabled: false, value: 0.5 }
    })),
    'supported-platforms': { circles: ['watchOS'], squares: 'shared' }
  };
}

// --- Rasterising ----------------------------------------------------------------------------------
const raster = (svg, size = 1024) => sharp(Buffer.from(svg), { density: 72 }).resize(size, size).png().toBuffer();

/** Flat composite of the source layers (no Apple material). */
async function composite(design, appearance = 0) {
  const overlays = [];
  for (const layer of design.layers) overlays.push({ input: await raster(layerSvg(layer, appearance)) });
  return sharp(await raster(backgroundSvg(design.background[appearance]))).composite(overlays).png().toBuffer();
}

/** Opaque square PWA icon, motif scaled by `scale` around the centre. */
async function square(full, size, scale) {
  const side = Math.round(1024 / scale);
  const offset = Math.round((1024 - side) / 2);
  return sharp(full).extract({ left: offset, top: offset, width: side, height: side })
    .resize(size, size).removeAlpha().png({ compressionLevel: 9 }).toBuffer();
}

const APPLE = [
  ['ios-default', 'iOS', 'Default', 0],
  ['ios-dark', 'iOS', 'Dark', 1],
  ['ios-tinted-gray', 'iOS', 'ClearDark', 2],
  ['ios-tinted-color', 'iOS', 'TintedDark', 2, ['0.12', '1']],
  ['macos-default', 'macOS', 'Default', 0],
  ['watchos-default', 'watchOS', 'Default', 0]
];

const results = [];
for (const design of designs) {
  const dir = path.join(root, design.dir);
  const bundle = path.join(dir, `${design.bundle}.icon`);
  await rm(dir, { recursive: true, force: true });
  for (const sub of ['src', 'png', `${design.bundle}.icon/Assets`]) await mkdir(path.join(dir, sub), { recursive: true });

  await writeFile(path.join(dir, 'src/background.svg'), backgroundSvg(design.background[0]));
  for (const layer of design.layers) {
    for (const target of [path.join(dir, 'src'), path.join(bundle, 'Assets')]) {
      await writeFile(path.join(target, `${layer.id}.svg`), layerSvg(layer));
    }
  }
  await writeFile(path.join(bundle, 'icon.json'), JSON.stringify(iconJson(design), null, 2) + '\n');
  await writeFile(path.join(dir, 'favicon.svg'), faviconSvg(design));

  const png = (name) => path.join(dir, 'png', `${name}.png`);
  for (const [name, platform, rendition, appearance, tint] of APPLE) {
    if (ictoolVersion) {
      execFileSync(ictool, [bundle, '--export-image', '--output-file', png(name), '--platform', platform, '--rendition', rendition,
        '--width', '512', '--height', '512', '--scale', '1', ...(tint ? ['--tint-color', tint[0], '--tint-strength', tint[1]] : [])], { stdio: 'pipe' });
      // ictool writes 16-bit files; 8-bit sRGB keeps the repository small.
      await writeFile(png(name), await sharp(await readFile(png(name))).toColourspace('srgb').png({ compressionLevel: 9 }).toBuffer());
    } else {
      const round = platform === 'watchOS' ? 256 : 114;
      const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"><rect width="512" height="512" rx="${round}"/></svg>`);
      await sharp(await sharp(await composite(design, appearance)).resize(512, 512).png().toBuffer())
        .composite([{ input: mask, blend: 'dest-in' }]).png().toFile(png(name));
    }
  }

  const full = await composite(design);
  await writeFile(png('icon-192'), await square(full, 192, 1.12));
  await writeFile(png('icon-512'), await square(full, 512, 1.12));
  await writeFile(png('maskable-512'), await square(full, 512, 1));
  await writeFile(png('apple-touch-icon'), await square(full, 180, 1.08));
  for (const size of [16, 32, 48]) await writeFile(png(`favicon-${size}`), await raster(faviconSvg(design, 'light'), size));

  const darkFavicons = {};
  for (const size of [16, 32]) darkFavicons[size] = await raster(faviconSvg(design, 'dark'), size);
  results.push({ design, dir, darkFavicons });
}

const renderer = ictoolVersion ? `Icon Composer ictool ${ictoolVersion}` : 'flache Sharp-Vorschau (ictool nicht verfügbar)';
for (const result of results) {
  await writeFile(path.join(result.dir, 'tafel.png'), await board(sharp, result, renderer));
}
await writeFile(path.join(root, 'uebersicht.png'), await overview(sharp, results, renderer));

await writeFile(path.join(root, 'render-info.json'), JSON.stringify({
  appleRenderer: renderer,
  appleRenditions: APPLE.map(([file, platform, rendition, , tint]) => ({ file, platform, rendition, ...(tint ? { tintColor: tint[0], tintStrength: tint[1] } : {}) })),
  pwaAndBoards: { node: process.versions.node, sharp: sharp.versions.sharp, vips: sharp.versions.vips, rsvg: sharp.versions.rsvg },
  notVerified: ['Xcode import and actool build', 'real devices', 'browser rendering of favicon.svg in dark mode', 'clear (glass) renditions']
}, null, 2) + '\n');
console.log(`rendered ${results.length} drafts, Apple previews: ${renderer}`);
