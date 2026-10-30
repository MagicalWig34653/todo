import { expect, test } from '@playwright/test';

// Served assets (Vite dev, Vite build or the backend image): manifest icons resolve with an image content type and
// the declared size, and /favicon.ico is never answered with the SPA fallback HTML.
function pngSize(buf: Buffer) {
	return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
}

test('manifest icons are served with correct type and size', async ({ request }) => {
	const res = await request.get('/manifest.webmanifest');
	expect(res.status()).toBe(200);
	expect(res.headers()['content-type']).toMatch(/manifest\+json|application\/json/);
	const manifest = await res.json();
	expect(manifest.icons.length).toBeGreaterThanOrEqual(3);
	for (const icon of manifest.icons as { src: string; sizes: string; type: string }[]) {
		const r = await request.get(icon.src);
		expect(r.status(), icon.src).toBe(200);
		expect(r.headers()['content-type'], icon.src).toContain(icon.type);
		if (icon.type === 'image/png') {
			const [w, h] = icon.sizes.split('x').map(Number);
			expect(pngSize(await r.body()), icon.src).toEqual({ w, h });
		}
	}
});

test('favicon.ico and apple-touch-icon are real images, not the SPA fallback', async ({ request }) => {
	const ico = await request.get('/favicon.ico', { headers: { accept: 'image/avif,image/webp,*/*' } });
	expect(ico.status()).toBe(200);
	expect(ico.headers()['content-type']).toMatch(/image\/(x-icon|vnd\.microsoft\.icon)/);
	expect((await ico.body()).readUInt16LE(2)).toBe(1);
	const apple = await request.get('/apple-touch-icon.png');
	expect(apple.status()).toBe(200);
	expect(apple.headers()['content-type']).toContain('image/png');
	expect(pngSize(await apple.body())).toEqual({ w: 180, h: 180 });
});

test('pages link the icons', async ({ page }) => {
	await page.goto('/');
	await expect(page.locator('link[rel="icon"][href$="favicon.svg"]')).toHaveCount(1);
	await expect(page.locator('link[rel="apple-touch-icon"]')).toHaveCount(1);
	await expect(page.locator('meta[name="theme-color"]')).toHaveCount(2);
});
