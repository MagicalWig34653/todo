// node --test design/ux-konzept/check.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const VIEWS = ['fuer-dich', 'aufgaben', 'projekte', 'projekt', 'karte', 'zeitleiste', 'zeitleiste-detail', 'einstellungen'];
const EXPECTED = VIEWS.flatMap((v) => ['desktop', 'handy'].flatMap((d) => ['hell', 'dunkel'].map((s) => `wireframes/png/${v}-${d}-${s}.png`)));
const files = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(dir, e.name)) : [join(dir, e.name)]));

test('every view exists in light and dark, desktop and phone', () => {
	const missing = EXPECTED.filter((f) => !existsSync(join(root, f)) || statSync(join(root, f)).size < 5000);
	assert.deepEqual(missing, []);
});

test('board for the review exists', () => assert.ok(existsSync(join(root, 'tafel.png'))));

test('wireframes load nothing from outside', () => {
	const html = existsSync(join(root, 'wireframes')) ? files(join(root, 'wireframes')).filter((f) => /\.(html|css|js|mjs)$/.test(f)) : [];
	assert.ok(html.some((f) => f.endsWith('index.html')), 'wireframes/index.html missing');
	for (const f of html.filter((f) => /\.(html|css)$/.test(f))) assert.doesNotMatch(readFileSync(f, 'utf8'), /https?:\/\/|@import|url\(\s*['"]?\/\//, f);
});

test('linked files and images in the documents exist', () => {
	const broken = [];
	for (const f of files(root).filter((f) => /\.(md|html)$/.test(f))) {
		const text = readFileSync(f, 'utf8');
		const links = [...text.matchAll(/\]\(([^)\s#]+)\)/g), ...(f.endsWith('.html') ? text.matchAll(/(?:src|href)="([^"#?$]+)"/g) : [])].map((m) => m[1]);
		for (const l of links) if (!/^[a-z]+:/i.test(l) && !existsSync(resolve(dirname(f), l))) broken.push(`${f.slice(root.length + 1)} -> ${l}`);
	}
	assert.deepEqual(broken, []);
});

test('every image name pattern in the survey has a file', () => {
	const doc = readFileSync(join(root, 'ist-aufnahme.md'), 'utf8');
	const have = readdirSync(join(root, 'ist'));
	const names = [...doc.matchAll(/`([a-z-]+-(?:desktop|handy|\*)[a-z*-]*)`/g)].map((m) => m[1]);
	assert.ok(names.length > 10);
	const missing = names.filter((n) => !have.some((h) => new RegExp(`^${n.replace(/\*/g, '.*')}\\.jpg$`).test(h)));
	assert.deepEqual(missing, []);
});
