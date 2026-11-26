// Preview boards (German labels), composed as one SVG per board and rasterised with sharp.
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const WIDTH = 1600;
const FONT = "font-family='Helvetica Neue, Helvetica, Arial, sans-serif'";

const uri = (buffer) => `data:image/png;base64,${buffer.toString('base64')}`;
const image = (href, x, y, size) => `<image href="${href}" x="${x}" y="${y}" width="${size}" height="${size}"/>`;
const box = (x, y, w, h, fill, rx = 24, extra = '') => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}" fill="${fill}" ${extra}/>`;
const label = (x, y, value, { size = 18, fill = '#3C3C43', anchor = 'middle', weight = 400 } = {}) =>
  `<text x="${x}" y="${y}" ${FONT} font-size="${size}" font-weight="${weight}" text-anchor="${anchor}" fill="${fill}">${value}</text>`;
const heading = (y, value) => label(60, y, value, { size: 26, fill: '#111114', anchor: 'start', weight: 700 });

/** PNG file resized to the exact display size, so nothing is resampled twice. */
async function sized(sharp, file, size) {
  return uri(await sharp(file).resize(size, size).png().toBuffer());
}
/** Nearest-neighbour enlargement to show the real pixels. */
async function zoomed(sharp, input, factor) {
  const { width } = await sharp(input).metadata();
  return uri(await sharp(input).resize(width * factor, width * factor, { kernel: 'nearest' }).png().toBuffer());
}

async function toPng(sharp, height, body) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${height}" viewBox="0 0 ${WIDTH} ${height}">${box(0, 0, WIDTH, height, '#F2F2F5', 0)}${body}</svg>`;
  const render = (options) => sharp(Buffer.from(svg), { unlimited: true }).removeAlpha().png({ compressionLevel: 9, ...options }).toBuffer();
  const lossless = await render({});
  return lossless.length < 1_900_000 ? lossless : render({ palette: true, quality: 95, effort: 8 });
}

const placeholderGlyphs = [
  '<circle cx="50" cy="50" r="22" fill="#FFFFFF"/>',
  '<path d="M50 26 L76 72 H24 Z" fill="#FFFFFF"/>',
  '<path d="M26 34 H74 M26 50 H74 M26 66 H56" stroke="#FFFFFF" stroke-width="8" stroke-linecap="round"/>',
  '<circle cx="50" cy="50" r="22" fill="none" stroke="#FFFFFF" stroke-width="9"/>',
  '<rect x="30" y="30" width="40" height="40" rx="6" fill="#FFFFFF"/>',
  '<path d="M32 68 V48 M50 68 V30 M68 68 V56" stroke="#FFFFFF" stroke-width="10" stroke-linecap="round"/>',
  '<path d="M50 24 L76 50 L50 76 L24 50 Z" fill="#FFFFFF"/>'
];
const placeholderColors = ['#8E8E93', '#7A8794', '#99918A', '#848C86', '#8D8598', '#6F767D', '#9A9A9A'];
const placeholderNames = ['Karten', 'Berg', 'Notizen', 'Ring', 'Ablage', 'Zahlen', 'Raute'];

function homescreen(x, y, icon, dark) {
  const wallpaper = dark ? ['#1B2233', '#07080C'] : ['#DCE7F5', '#F3DFD4'];
  const text = dark ? '#FFFFFF' : '#111114';
  const id = `wall-${dark ? 'd' : 'l'}`;
  let body = `<defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${wallpaper[0]}"/><stop offset="1" stop-color="${wallpaper[1]}"/></linearGradient></defs>`;
  body += box(x, y, 730, 380, `url(#${id})`, 40);
  let placeholder = 0;
  for (let index = 0; index < 8; index += 1) {
    const ix = x + 50 + (index % 4) * 175;
    const iy = y + 40 + Math.floor(index / 4) * 170;
    if (index === 1) {
      body += image(icon, ix, iy, 105);
      body += label(ix + 52, iy + 132, 'Todolino', { fill: text, size: 17 });
    } else {
      body += box(ix + 4, iy + 4, 97, 97, placeholderColors[placeholder], 23, dark ? 'opacity="0.75"' : '');
      body += `<g transform="translate(${ix + 4} ${iy + 4}) scale(0.97)">${placeholderGlyphs[placeholder]}</g>`;
      body += label(ix + 52, iy + 132, placeholderNames[placeholder], { fill: text, size: 17 });
      placeholder += 1;
    }
  }
  return body;
}

/** Browser tab strip at 2x (retina): the 32 px favicon is shown pixel for pixel. */
function browserTabs(x, y, favicon, dark) {
  const c = dark
    ? { bar: '#1F2023', tab: '#35363A', text: '#E8EAED', dim: '#9AA0A6', field: '#202124' }
    : { bar: '#DEE1E6', tab: '#FFFFFF', text: '#202124', dim: '#5F6368', field: '#F1F3F4' };
  let body = box(x, y, 730, 170, c.bar, 20);
  body += ['#9A9A9E', '#9A9A9E', '#9A9A9E'].map((fill, i) => `<circle cx="${x + 30 + i * 28}" cy="${y + 52}" r="8" fill="${fill}"/>`).join('');
  body += `<path d="M ${x + 120} ${y + 90} V ${y + 36} a 18 18 0 0 1 18 -18 H ${x + 422} a 18 18 0 0 1 18 18 V ${y + 90} Z" fill="${c.tab}"/>`;
  body += image(favicon, x + 140, y + 38, 32);
  body += label(x + 188, y + 63, 'Todolino', { size: 26, fill: c.text, anchor: 'start' });
  body += label(x + 410, y + 63, '×', { size: 28, fill: c.dim });
  body += `<circle cx="${x + 480}" cy="${y + 54}" r="14" fill="${c.dim}" opacity="0.6"/>`;
  body += label(x + 510, y + 63, 'Neuer Tab', { size: 26, fill: c.dim, anchor: 'start' });
  body += box(x, y + 90, 730, 80, c.tab, 0);
  body += box(x + 24, y + 104, 682, 50, c.field, 25);
  body += label(x + 52, y + 137, 'todolino.example', { size: 22, fill: c.dim, anchor: 'start' });
  return body;
}

export async function board(sharp, { design, dir, darkFavicons }, renderer) {
  const file = (name) => path.join(dir, 'png', `${name}.png`);
  let body = label(60, 70, design.title, { size: 46, fill: '#111114', anchor: 'start', weight: 700 });
  body += label(60, 108, design.idea, { size: 22, anchor: 'start' });
  body += label(1540, 108, `Apple-Ansichten: ${renderer}`, { size: 18, anchor: 'end' });

  body += heading(172, 'Erscheinungen (iOS und iPadOS)');
  const looks = [
    ['ios-default', 'Hell (Standard)', '#FFFFFF'],
    ['ios-dark', 'Dunkel', '#1C1C1E'],
    ['ios-tinted-gray', 'Monochrom (Clear Dark)', '#1C1C1E'],
    ['ios-tinted-color', 'Getönt: Beispiel eingefärbt', '#1C1C1E']
  ];
  for (const [i, [name, text, bg]] of looks.entries()) {
    const x = 60 + i * 375;
    body += box(x, 195, 355, 355, bg) + image(await sized(sharp, file(name), 290), x + 32, 227, 290);
    body += label(x + 177, 582, text);
  }

  body += heading(645, 'macOS, watchOS, maskable (PWA)');
  const mac = await sized(sharp, file('macos-default'), 220);
  body += box(60, 668, 480, 340, '#C9D6E8') + image(mac, 190, 695, 220);
  body += box(130, 925, 340, 62, '#FFFFFF', 20, 'opacity="0.55"');
  for (let i = 0; i < 5; i += 1) {
    const x = 148 + i * 66;
    body += i === 2 ? image(await sized(sharp, file('macos-default'), 48), x, 932, 48) : box(x + 4, 936, 40, 40, placeholderColors[i], 10);
  }
  body += label(300, 1040, 'macOS: Fenstergröße und Dock');
  body += box(560, 668, 480, 340, '#000000') + image(await sized(sharp, file('watchos-default'), 270), 665, 703, 270);
  body += label(800, 1040, 'watchOS: Kreismaske');
  body += box(1060, 668, 480, 340, '#FFFFFF') + image(await sized(sharp, file('maskable-512'), 300), 1150, 688, 300);
  body += '<circle cx="1300" cy="838" r="120" fill="none" stroke="#000000" stroke-width="3" stroke-dasharray="10 8"/>';
  body += '<circle cx="1300" cy="838" r="120" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-dasharray="10 8" stroke-dashoffset="9"/>';
  body += label(1300, 1040, 'maskable-512 mit Sicherheitskreis (80 %)');

  body += heading(1100, 'Kleingrößen in echter Pixelgröße');
  body += box(60, 1122, 730, 250, '#FFFFFF') + box(810, 1122, 730, 250, '#FFFFFF');
  let x = 90;
  for (const size of [180, 64, 32, 16]) {
    const source = size === 180 ? file('apple-touch-icon') : file('ios-default');
    const href = await sized(sharp, source, size);
    if (size === 180) {
      body += `<clipPath id="touch"><rect x="${x}" y="1147" width="180" height="180" rx="40"/></clipPath><g clip-path="url(#touch)">${image(href, x, 1147, 180)}</g>`;
    } else {
      body += image(href, x, 1327 - size, size);
    }
    body += label(x + size / 2, 1355, `${size} px`, { size: 16 });
    x += size + 100;
  }
  const f16 = await readFile(file('favicon-16'));
  const f32 = await readFile(file('favicon-32'));
  body += image(uri(f32), 840, 1250, 32) + label(856, 1355, '32 px', { size: 16 });
  body += image(uri(f16), 910, 1266, 16) + label(918, 1355, '16 px', { size: 16 });
  body += image(await zoomed(sharp, f32, 4), 1000, 1180, 128) + label(1064, 1355, '32 px × 4', { size: 16 });
  body += image(await zoomed(sharp, f16, 8), 1170, 1180, 128) + label(1234, 1355, '16 px × 8', { size: 16 });
  body += box(1350, 1160, 170, 170, '#1C1C1E', 16) + image(await zoomed(sharp, darkFavicons[16], 8), 1371, 1181, 128);
  body += label(1435, 1355, '16 px × 8 dunkel', { size: 16 });
  body += label(60, 1400, 'Links: 180 px = apple-touch-icon (flach), 64/32/16 px = iOS-Ansicht verkleinert. Rechts: Favicon (vereinfachte Form), vergrößert ohne Glättung.', { size: 16, anchor: 'start' });

  body += heading(1462, 'Homescreen (Platzhalter ohne Marken)');
  body += homescreen(60, 1485, await sized(sharp, file('ios-default'), 105), false);
  body += homescreen(810, 1485, await sized(sharp, file('ios-dark'), 105), true);

  body += heading(1925, 'Browser-Tab (doppelte Auflösung)');
  body += browserTabs(60, 1948, uri(f32), false);
  body += browserTabs(810, 1948, uri(darkFavicons[32]), true);

  return toPng(sharp, 2160, body);
}

export async function overview(sharp, results, renderer) {
  let body = label(60, 66, 'Todolino – vier Icon-Entwürfe', { size: 42, fill: '#111114', anchor: 'start', weight: 700 });
  body += label(1540, 66, `Apple-Ansichten: ${renderer}`, { size: 18, anchor: 'end' });
  const rows = [['ios-default', 'Hell', 150], ['ios-dark', 'Dunkel', 400], ['ios-tinted-gray', 'Monochrom', 650], ['ios-tinted-color', 'Getönt farbig', 900]];
  for (const [i, { design, dir, darkFavicons }] of results.entries()) {
    const x = 60 + i * 375;
    const file = (name) => path.join(dir, 'png', `${name}.png`);
    body += label(x + 177, 122, design.title, { size: 28, fill: '#111114', weight: 700 });
    for (const [name, text, y] of rows) {
      body += box(x, y, 355, 238, name === 'ios-default' ? '#FFFFFF' : '#1C1C1E');
      body += image(await sized(sharp, file(name), 180), x + 87, y + 16, 180);
      body += label(x + 177, y + 222, text, { size: 16, fill: name === 'ios-default' ? '#3C3C43' : '#D1D1D6' });
    }
    const f16 = await readFile(file('favicon-16'));
    const f32 = await readFile(file('favicon-32'));
    for (const [y, bg, text, small, large] of [[1150, '#FFFFFF', '#3C3C43', f16, f32], [1330, '#1C1C1E', '#D1D1D6', darkFavicons[16], darkFavicons[32]]]) {
      body += box(x, y, 355, 168, bg);
      body += image(uri(large), x + 40, y + 50, 32) + label(x + 56, y + 142, '32 px', { size: 15, fill: text });
      body += image(uri(small), x + 112, y + 58, 16) + label(x + 120, y + 142, '16 px', { size: 15, fill: text });
      body += image(await zoomed(sharp, small, 7), x + 195, y + 18, 112) + label(x + 251, y + 152, '16 px × 7', { size: 15, fill: text });
    }
  }
  return toPng(sharp, 1530, body);
}
