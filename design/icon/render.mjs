// Proves design/icon/Todo.icon with Apple's renderer and draws the board tafel-d-final.png.
//   node web/scripts/build-icons.mjs && node design/icon/render.mjs     (see README.md; needs sharp and Icon Composer)
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { board } from './entwuerfe-2026-11/boards.mjs';

const require = createRequire(import.meta.url);
const sharp = require(process.env.SHARP_MODULE || '/opt/homebrew/lib/node_modules/sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const web = path.join(root, '../../web/static');
const draft = path.join(root, 'entwuerfe-2026-11/d-bausteine');
const bundle = path.join(root, 'Todo.icon');
const ictool = process.env.ICTOOL || '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool';
const version = JSON.parse(execFileSync(ictool, ['--version'], { encoding: 'utf8' }))['short-bundle-version'];

for (const name of ['blocks-done.svg', 'block-next.svg']) await copyFile(path.join(root, name), path.join(bundle, 'Assets', name));

const work = await mkdtemp(path.join(tmpdir(), 'todolino-icon-'));
await mkdir(path.join(root, 'png'), { recursive: true });
await mkdir(path.join(work, 'png'));

const APPLE = [
  ['ios-default', 'iOS', 'Default'],
  ['ios-dark', 'iOS', 'Dark'],
  ['ios-tinted-gray', 'iOS', 'ClearDark'], // monochrome
  ['ios-clear-light', 'iOS', 'ClearLight'], // monochrome on light wallpaper
  ['ios-tinted-color', 'iOS', 'TintedDark', ['0.12', '1']],
  ['ios-tinted-light', 'iOS', 'TintedLight', ['0.6', '1']],
  ['macos-default', 'macOS', 'Default'],
  ['watchos-default', 'watchOS', 'Default']
];
for (const [name, platform, rendition, tint] of APPLE) {
  const file = path.join(root, 'png', `${name}.png`);
  execFileSync(ictool, [bundle, '--export-image', '--output-file', file, '--platform', platform, '--rendition', rendition,
    '--width', '512', '--height', '512', '--scale', '1', ...(tint ? ['--tint-color', tint[0], '--tint-strength', tint[1]] : [])], { stdio: 'pipe' });
  // ictool writes 16-bit files; 8-bit sRGB keeps the repository small.
  await writeFile(file, await sharp(await readFile(file)).toColourspace('srgb').png({ compressionLevel: 9 }).toBuffer());
  await copyFile(file, path.join(work, 'png', `${name}.png`));
}

// The board shows the shipped web files, not a second rendering of them.
for (const name of ['apple-touch-icon', 'maskable-512']) await copyFile(path.join(web, `${name}.png`), path.join(work, 'png', `${name}.png`));
const ico = await readFile(path.join(web, 'favicon.ico'));
for (let i = 0; i < ico.readUInt16LE(4); i += 1) {
  const at = 6 + 16 * i;
  const offset = ico.readUInt32LE(at + 12);
  await writeFile(path.join(work, 'png', `favicon-${ico[at]}.png`), ico.subarray(offset, offset + ico.readUInt32LE(at + 8)));
}

const favicon = await readFile(path.join(root, 'favicon.svg'), 'utf8');
/** Dark scheme forced: the media query becomes unconditional. */
const dark = (svg, size) => sharp(Buffer.from(svg
  .replace('@media (prefers-color-scheme:dark)', '@media all')
  .replace(/<svg ([^>]*?)(?: width="\d+" height="\d+")? viewBox/, `<svg $1 width="${size}" height="${size}" viewBox`)), { density: 72 }).png().toBuffer();
// librsvg ignores @media: apply the dark rules by moving them behind the light ones.
const forcedDark = favicon.replace(/@media \(prefers-color-scheme:dark\)\{((?:[^{}]*\{[^{}]*\})*)\}/, '$1');
const darkFavicons = {};
for (const size of [16, 32]) darkFavicons[size] = await dark(forcedDark, size);

const design = { title: 'D – Bausteine (fertig)', idea: 'Ein Haken aus Aufgabenblöcken, der nächste leuchtet' };
const top = await board(sharp, { design, dir: work, darkFavicons }, `Icon Composer ictool ${version}`);

// Before (draft D) and after (final) at 16 and 32 px, pixel for pixel and enlarged without smoothing.
const draftSvg = await readFile(path.join(draft, 'favicon.svg'), 'utf8');
const draftDark = draftSvg.replace(/@media \(prefers-color-scheme:dark\)\{((?:[^{}]*\{[^{}]*\})*)\}/, '$1');
const rows = [
  ['Vorher (Entwurf D)', async (s) => readFile(path.join(draft, `png/favicon-${s}.png`)), (s) => dark(draftDark, s)],
  ['Nachher (fertig)', async (s) => readFile(path.join(work, 'png', `favicon-${s}.png`)), async (s) => darkFavicons[s]]
];
const text = (x, y, value, size = 18, weight = 400) =>
  `<text x="${x}" y="${y}" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="${size}" font-weight="${weight}" fill="#111114">${value}</text>`;
let labels = `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="640"><rect width="1600" height="640" fill="#F2F2F5"/>${text(60, 50, 'Vorher / Nachher: Favicon 16 und 32 px (echte Größe und vergrößert)', 26, 700)}`;
const tiles = [];
for (const [row, [title, light, night]] of rows.entries()) {
  const y = 80 + row * 270;
  labels += text(60, y + 135, title, 20, 700);
  let x = 300;
  for (const [mode, render, bg] of [['hell', light, '#FFFFFF'], ['dunkel', night, '#1C1C1E']]) {
    labels += `<rect x="${x}" y="${y}" width="610" height="250" rx="20" fill="${bg}"/>`;
    let cx = x + 30;
    for (const [size, factor] of [[16, 12], [32, 6]]) {
      const png = await render(size);
      tiles.push({ input: png, left: cx, top: y + 25 + 192 - size });
      cx += size + 22;
      tiles.push({ input: await sharp(png).resize(size * factor, size * factor, { kernel: 'nearest' }).png().toBuffer(), left: cx, top: y + 25 });
      cx += size * factor + 30;
    }
    labels += `<text x="${x + 30}" y="${y + 240}" font-family="Helvetica" font-size="15" fill="${mode === 'hell' ? '#3C3C43' : '#D1D1D6'}">${mode}: 16 px, 16 px × 12, 32 px, 32 px × 6</text>`;
    x += 630;
  }
}
const strip = await sharp(Buffer.from(`${labels}</svg>`)).composite(tiles).png().toBuffer();
const { height } = await sharp(top).metadata();
await writeFile(path.join(root, 'tafel-d-final.png'), await sharp({ create: { width: 1600, height: height + 640, channels: 3, background: '#F2F2F5' } })
  .composite([{ input: top, left: 0, top: 0 }, { input: strip, left: 0, top: height }]).png({ compressionLevel: 9 }).toBuffer());
await rm(work, { recursive: true, force: true });
console.log(`rendered ${APPLE.length} Apple views with ictool ${version} and tafel-d-final.png`);
