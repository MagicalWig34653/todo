# Beleg Karte 9608B355: Dependabot @sveltejs/kit, adapter-static, yaml

Stand 27.11.2026. Offene Dependabot-Alerts vorher (`gh api repos/.../dependabot/alerts`): #7, #6 (kit, hoch), #5, #4 (kit, mittel), #2 (adapter-static, mittel) in `web/package-lock.json`; #1 (yaml, mittel) in `docs-site/package-lock.json`.

## Vorher (rot): `npm audit`
web: `@sveltejs/kit 3.1.0` (high: GHSA-mw6w-2fmv-pvw3, GHSA-m9j8-jcmv-hp69, GHSA-3r8g-jcqq-3p5j, GHSA-6cf5-gc4q-fm3x, GHSA-rqp5-r3wg-vg35), `@sveltejs/adapter-static 4.0.0` (moderate: GHSA-jf9x-2fg2-hx4w); "2 vulnerabilities (1 moderate, 1 high)".
docs-site: `yaml 2.8.1` (moderate: GHSA-48c2-rrv3-qjmp); "1 moderate severity vulnerability".

## Änderung
- web: `@sveltejs/kit` ^3.0.0 -> ^3.1.1 (installiert 3.4.1), `@sveltejs/adapter-static` ^4.0.0 -> ^4.0.1 (4.0.1).
- docs-site: `yaml` 2.8.1 -> 2.9.1 (exakt gepinnt wie vorher).

## Nachher (grün)
- `npm audit` web: "found 0 vulnerabilities"; docs-site: "found 0 vulnerabilities".
- web: `npm run check` 0 Fehler 0 Warnungen, vitest 860/860, `npm run build` ok.
- docs-site: `npm run build` "Built 96 pages, 28 contracts", `dist/` bytegleich mit dem Stand vor dem Update (`diff -r` ohne Unterschied).
- Playwright gegen natives Backend: siehe STATUS.
