// Structural checks for the four icon drafts. No new dependency:
//   node --test design/icon/entwuerfe-2026-11/check.test.mjs
// The maskable safe-zone test needs sharp (SHARP_MODULE, else the global install) and is skipped without it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = path.dirname(fileURLToPath(import.meta.url));
const designs = readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && /^[a-z]-[a-z0-9-]+$/.test(entry.name))
  .map((entry) => entry.name)
  .sort();

const PNGS = {
  'favicon-16.png': 16,
  'favicon-32.png': 32,
  'favicon-48.png': 48,
  'icon-192.png': 192,
  'icon-512.png': 512,
  'maskable-512.png': 512,
  'apple-touch-icon.png': 180,
  'ios-default.png': 512,
  'ios-dark.png': 512,
  'ios-tinted-gray.png': 512,
  'ios-tinted-color.png': 512,
  'macos-default.png': 512,
  'watchos-default.png': 512
};

function loadSharp() {
  for (const id of [process.env.SHARP_MODULE, 'sharp', '/opt/homebrew/lib/node_modules/sharp']) {
    if (!id) continue;
    try {
      return require(id);
    } catch {
      // try the next candidate
    }
  }
  return null;
}

/** Reads IHDR and the chunk names of a PNG file. */
function pngInfo(file) {
  const data = readFileSync(file);
  assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', `${file} is not a PNG`);
  assert.equal(data.subarray(12, 16).toString('latin1'), 'IHDR');
  const chunks = [];
  for (let offset = 8; offset < data.length; offset += 12 + data.readUInt32BE(offset)) {
    chunks.push(data.subarray(offset + 4, offset + 8).toString('latin1'));
  }
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20), colorType: data[25], chunks };
}

const iconBundles = (dir) => readdirSync(path.join(root, dir)).filter((name) => name.endsWith('.icon'));
const sourceSvgs = (dir) => readdirSync(path.join(root, dir, 'src')).filter((name) => name.endsWith('.svg')).sort();

test('there are exactly four drafts A to D, with README, overview and render script', () => {
  assert.deepEqual(designs.map((name) => name[0]), ['a', 'b', 'c', 'd']);
  for (const file of ['README.md', 'render.mjs', 'uebersicht.png']) {
    assert.ok(existsSync(path.join(root, file)), `missing ${file}`);
  }
  assert.ok(statSync(path.join(root, 'uebersicht.png')).size < 2_000_000, 'uebersicht.png must stay below 2 MB');
});

for (const letter of ['a', 'b', 'c', 'd']) {
  const dir = designs.find((name) => name.startsWith(`${letter}-`));
  const need = () => assert.ok(dir, `draft ${letter.toUpperCase()} is missing`);

  test(`${letter}: required files exist`, () => {
    need();
    for (const file of ['favicon.svg', 'tafel.png', 'src/background.svg', ...Object.keys(PNGS).map((n) => `png/${n}`)]) {
      assert.ok(existsSync(path.join(root, dir, file)), `missing ${dir}/${file}`);
    }
    assert.equal(iconBundles(dir).length, 1, 'exactly one .icon bundle');
    const foreground = sourceSvgs(dir).filter((name) => name !== 'background.svg');
    assert.ok(foreground.length >= 1 && foreground.length <= 4, `1 to 4 foreground layers, got ${foreground.length}`);
  });

  test(`${letter}: PNG sizes match IHDR`, () => {
    need();
    for (const [name, size] of Object.entries(PNGS)) {
      const info = pngInfo(path.join(root, dir, 'png', name));
      assert.deepEqual([info.width, info.height], [size, size], name);
    }
    const board = pngInfo(path.join(root, dir, 'tafel.png'));
    assert.equal(board.width, 1600, 'tafel.png width');
    assert.ok(statSync(path.join(root, dir, 'tafel.png')).size < 2_000_000, 'tafel.png must stay below 2 MB');
  });

  test(`${letter}: apple-touch-icon and maskable icon are opaque`, () => {
    need();
    for (const name of ['apple-touch-icon.png', 'maskable-512.png']) {
      const info = pngInfo(path.join(root, dir, 'png', name));
      assert.ok(info.colorType === 2 || info.colorType === 0, `${name} has an alpha channel or palette`);
      assert.ok(!info.chunks.includes('tRNS'), `${name} has a transparency chunk`);
    }
  });

  test(`${letter}: maskable motif stays inside the safe zone (circle, 80 % diameter)`, async (t) => {
    need();
    const sharp = loadSharp();
    if (!sharp) return t.skip('sharp not available');
    const { data, info } = await sharp(path.join(root, dir, 'png/maskable-512.png'))
      .removeAlpha().raw().toBuffer({ resolveWithObject: true });
    const radius = info.width * 0.4;
    const centre = (info.width - 1) / 2;
    let outside = 0;
    let inside = 0;
    for (let y = 0; y < info.height; y += 1) {
      for (let x = 0; x < info.width; x += 1) {
        // The background is a vertical gradient, so the left edge of each row is its reference colour.
        const i = (y * info.width + x) * info.channels;
        const ref = y * info.width * info.channels;
        const diff = Math.max(...[0, 1, 2].map((c) => Math.abs(data[i + c] - data[ref + c])));
        if (diff <= 6) continue;
        if (Math.hypot(x - centre, y - centre) > radius) outside += 1;
        else inside += 1;
      }
    }
    assert.equal(outside, 0, `${outside} motif pixels outside the safe zone`);
    assert.ok(inside > info.width * info.height * 0.08, 'motif covers less than 8 % of the canvas');
  });

  test(`${letter}: SVGs use a 1024 canvas and contain no text, script, image or external reference`, () => {
    need();
    const files = ['favicon.svg', ...sourceSvgs(dir).map((n) => `src/${n}`)];
    for (const file of files) {
      const svg = readFileSync(path.join(root, dir, file), 'utf8');
      assert.match(svg, /<svg\b[^>]*viewBox="0 0 1024 1024"/, `${file}: viewBox`);
      assert.doesNotMatch(svg, /<(text|tspan|script|image|foreignObject|filter|font)\b/i, `${file}: forbidden element`);
      assert.doesNotMatch(svg, /(href\s*=\s*["'](?!#))|(url\(\s*["']?(?!#))|@import/i, `${file}: external reference`);
    }
    const background = readFileSync(path.join(root, dir, 'src/background.svg'), 'utf8');
    assert.match(background, /<rect width="1024" height="1024"/, 'background is a full square');
    assert.doesNotMatch(background, /\brx=/, 'no baked-in rounded corners');
  });

  test(`${letter}: icon.json is valid and references existing assets`, () => {
    need();
    const bundle = path.join(root, dir, iconBundles(dir)[0]);
    const icon = JSON.parse(readFileSync(path.join(bundle, 'icon.json'), 'utf8'));
    assert.ok(icon.groups.length >= 1 && icon.groups.length <= 4, '1 to 4 groups');
    assert.equal(icon['supported-platforms'].squares, 'shared');
    assert.deepEqual(icon['supported-platforms'].circles, ['watchOS']);
    const filled = [icon, ...icon.groups.flatMap((group) => group.layers)];
    for (const item of filled) {
      // ictool ignores fill-specializations when a plain "fill" sits next to them.
      assert.equal(item.fill, undefined, 'default fill belongs into fill-specializations');
      assert.deepEqual(item['fill-specializations'].map((s) => s.appearance ?? 'default'), ['default', 'dark', 'tinted']);
    }
    const referenced = filled.slice(1).map((layer) => layer['image-name']).sort();
    assert.deepEqual(readdirSync(path.join(bundle, 'Assets')).sort(), referenced);
    assert.deepEqual(referenced, sourceSvgs(dir).filter((n) => n !== 'background.svg'));
    for (const name of referenced) {
      assert.ok(readFileSync(path.join(bundle, 'Assets', name)).equals(readFileSync(path.join(root, dir, 'src', name))), `${name} differs from src`);
    }
  });
}
