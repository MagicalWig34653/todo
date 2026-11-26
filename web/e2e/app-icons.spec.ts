import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';

// The built app served by the real backend: every icon the page and the manifest point to is a real image of the right
// type and size, decoded by the browser itself, and favicon.svg follows the colour scheme. No account needed.
//   E2E_BASE_URL=http://localhost:25173 npx playwright test e2e/app-icons.spec.ts --project=chromium
// Screenshots go to $APP_ICON_SHOTS (default docs/screenshots/app-icons).
const SHOTS = process.env.APP_ICON_SHOTS ?? '../docs/screenshots/app-icons';
const TYPES: Record<string, RegExp> = {
	svg: /^image\/svg\+xml/,
	png: /^image\/png/,
	ico: /^image\/(x-icon|vnd\.microsoft\.icon)/
};
const SIZES: Record<string, number> = {
	'/apple-touch-icon.png': 180,
	'/icon-192.png': 192,
	'/icon-512.png': 512,
	'/maskable-512.png': 512,
	'/favicon.svg': 32
};

async function openApp(page: Page) {
	await page.goto('/', { waitUntil: 'networkidle' });
}

/** Icon paths named by the loaded document (after hydration) and by its manifest. */
async function iconPaths(page: Page) {
	const linked = await page.evaluate(() =>
		[...document.querySelectorAll<HTMLLinkElement>('link[rel~="icon"], link[rel="apple-touch-icon"]')].map((l) => {
			const url = new URL(l.href);
			return url.pathname + url.search;
		})
	);
	const href = await page.locator('link[rel="manifest"]').getAttribute('href');
	const manifest = await (await page.request.get(new URL(href!, page.url()).href)).json();
	return { linked, manifest: (manifest.icons as { src: string }[]).map((i) => i.src) };
}

const decodedSize = (page: Page, src: string) =>
	page.evaluate(async (url) => {
		const image = new Image();
		image.src = url;
		await image.decode();
		return [image.naturalWidth, image.naturalHeight];
	}, src);

test('the page links exactly the three app icons and the manifest names its three, all versioned', async ({ page }) => {
	await openApp(page);
	const { linked, manifest } = await iconPaths(page);
	expect(linked.sort()).toEqual(['/apple-touch-icon.png?v=2', '/favicon.ico?v=2', '/favicon.svg?v=2']);
	expect(manifest.sort()).toEqual(['/icon-192.png?v=2', '/icon-512.png?v=2', '/maskable-512.png?v=2']);
});

test('every icon answers 200 with its content type, revalidates and decodes at its size', async ({ page }) => {
	await openApp(page);
	const { linked, manifest } = await iconPaths(page);
	for (const path of new Set([...linked, ...manifest])) {
		const response = await page.request.get(path);
		expect(response.status(), path).toBe(200);
		const name = path.split('?')[0];
		expect(response.headers()['content-type'], path).toMatch(TYPES[name.split('.').pop()!]);
		// Unhashed names must be revalidated, or an old icon could stick in the HTTP cache.
		expect(response.headers()['cache-control'], path).toBe('no-cache');
		const [w, h] = await decodedSize(page, path);
		expect(w, path).toBe(h);
		if (name in SIZES) expect(w, path).toBe(SIZES[name]);
		else expect([16, 32, 48], path).toContain(w);
	}
});

test('favicon.ico holds 16, 32 and 48 px images the browser can decode', async ({ page }) => {
	await openApp(page);
	const sizes = await page.evaluate(async () => {
		const view = new DataView(await (await fetch('/favicon.ico')).arrayBuffer());
		const out: number[][] = [];
		for (let i = 0; i < view.getUint16(4, true); i++) {
			const at = 6 + i * 16;
			const entry = new Uint8Array(view.buffer, view.getUint32(at + 12, true), view.getUint32(at + 8, true));
			const bitmap = await createImageBitmap(new Blob([entry.slice()], { type: 'image/png' }));
			out.push([bitmap.width, bitmap.height]);
		}
		return out;
	});
	expect(sizes).toEqual([[16, 16], [32, 32], [48, 48]]);
});

for (const scheme of ['light', 'dark'] as const) {
	test(`icons shown on a ${scheme} page; favicon.svg follows the scheme`, async ({ page, browserName }) => {
		await page.emulateMedia({ colorScheme: scheme });
		await openApp(page);
		await page.evaluate(async (dark) => {
			const tiles: [string, number][] = [
				['/favicon.ico', 16], ['/favicon.svg', 16], ['/favicon.svg', 32], ['/favicon.svg', 64],
				['/apple-touch-icon.png', 180], ['/icon-192.png', 192], ['/icon-512.png', 192], ['/maskable-512.png', 192]
			];
			document.body.replaceChildren();
			document.body.style.cssText = `margin:0;padding:24px;display:flex;flex-wrap:wrap;gap:24px;align-items:flex-end;width:560px;font:12px sans-serif;background:${dark ? '#09090b' : '#ffffff'};color:${dark ? '#fafafa' : '#09090b'}`;
			for (const [src, size] of tiles) {
				const figure = document.createElement('figure');
				figure.style.margin = '0';
				const image = new Image(size, size);
				image.src = `${src}?v=2`;
				image.dataset.tile = `${src} ${size}`;
				figure.append(image, Object.assign(document.createElement('figcaption'), { textContent: `${src.slice(1)} ${size}` }));
				document.body.append(figure);
				await image.decode();
			}
		}, scheme === 'dark');
		mkdirSync(SHOTS, { recursive: true });
		await page.locator('body').screenshot({ path: `${SHOTS}/${browserName}-${scheme === 'light' ? 'hell' : 'dunkel'}.png` });

		// Read what is on screen (a detached Image would not know the page's colour scheme in Firefox and WebKit):
		// one pixel inside the left block and one inside the red block of the 16 px grid.
		const shot = await page.locator('[data-tile="/favicon.svg 32"]').screenshot({ scale: 'css' });
		const colours = await page.evaluate(async (data) => {
			const image = new Image();
			image.src = `data:image/png;base64,${data}`;
			await image.decode();
			const canvas = Object.assign(document.createElement('canvas'), { width: 32, height: 32 });
			const context = canvas.getContext('2d')!;
			context.drawImage(image, 0, 0);
			return [[5, 15], [25, 9]].map(([x, y]) => [...context.getImageData(x, y, 1, 1).data.slice(0, 3)]);
		}, shot.toString('base64'));
		const expected = scheme === 'light' ? [[28, 38, 70], [233, 65, 43]] : [[255, 203, 51], [255, 101, 73]];
		for (const [i, colour] of colours.entries())
			for (const [channel, value] of colour.entries()) expect(Math.abs(value - expected[i][channel]), `${scheme} ${colours.join(' | ')}`).toBeLessThanOrEqual(6);
	});
}
