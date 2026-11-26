// UX step 1 "Lesbarkeit" (card 8B820AA8, design/ux-konzept/konzept.md §7): short previews on "Für dich", one-line
// explanations with the rest behind "Mehr erfahren", card tabs only when they have something to show.
import { describe, expect, it } from 'vitest';
import { splitLead } from '../src/lib/explainer';
import { previewParts } from '../src/lib/forYou';
import { tabAfterKey, visibleTabs } from '../src/lib/cardTabs';

describe('splitLead', () => {
	it('keeps a single sentence whole', () => {
		expect(splitLead('Was dich braucht und was in deinen Projekten passiert.')).toEqual({ lead: 'Was dich braucht und was in deinen Projekten passiert.', rest: '' });
	});
	it('splits after the first sentence', () => {
		expect(splitLead('Geplanter Start und Dauer pro Karte. Ziehen verschiebt den Start, die Frist ändert sich nie.')).toEqual({
			lead: 'Geplanter Start und Dauer pro Karte.',
			rest: 'Ziehen verschiebt den Start, die Frist ändert sich nie.'
		});
		expect(splitLead('Wirklich? Ja!  Weiter.')).toEqual({ lead: 'Wirklich?', rest: 'Ja! Weiter.' });
	});
	it('does not split at German abbreviations or numbers', () => {
		const s = 'Eine Verbindung, z. B. das Brain, bzw. Codex, ca. 3.5 Stunden lang. Rest.';
		expect(splitLead(s)).toEqual({ lead: 'Eine Verbindung, z. B. das Brain, bzw. Codex, ca. 3.5 Stunden lang.', rest: 'Rest.' });
	});
	it('handles empty text', () => {
		expect(splitLead('')).toEqual({ lead: '', rest: '' });
		expect(splitLead('   ')).toEqual({ lead: '', rest: '' });
	});
});

describe('previewParts (Für dich)', () => {
	it('renders Markdown a server flattened into one line as plain text: headline, then the rest', () => {
		const prompt = '**Wie soll die Anmeldung weiterlaufen?** - Variante A: Passkey zuerst, `E-Mail` nur als Rückfall - Variante B: beide gleichberechtigt nebeneinander - Variante C: nur Passkey, Rückfall über Wiederherstellungscodes Bitte eine Variante wählen, davon hängt der nächste Schritt ab.';
		const p = previewParts(prompt);
		expect(p.lead).toBe('Wie soll die Anmeldung weiterlaufen?');
		expect(p.rest.startsWith('Variante A: Passkey zuerst, E-Mail nur als Rückfall · Variante B:')).toBe(true);
		expect(p.lead + p.rest).not.toMatch(/\*\*|`|##/);
	});
	it('reads multi-line Markdown (heading, list) the same way', () => {
		const p = previewParts('## Plan\n\n- **erster** Schritt\n- zweiter Schritt');
		expect(p).toEqual({ lead: 'Plan', rest: 'erster Schritt · zweiter Schritt' });
	});
	it('a short question stays one headline', () => {
		expect(previewParts('Soll der Runner bei erschöpftem Kontingent pausieren?')).toEqual({ lead: 'Soll der Runner bei erschöpftem Kontingent pausieren?', rest: '' });
	});
	it('a very long first sentence is cut at a word with an ellipsis, the rest follows', () => {
		const long = 'Wort '.repeat(60).trim() + '. Zweiter Satz.';
		const p = previewParts(long);
		expect(p.lead.length).toBeLessThanOrEqual(141);
		expect(p.lead.endsWith('…')).toBe(true);
		expect(p.rest).toContain('Zweiter Satz.');
	});
});

describe('visibleTabs (card window)', () => {
	it('hides tabs without data: Änderungen and Tests have no source yet, Bericht and Pipeline only with content', () => {
		expect(visibleTabs({ report: false, pipeline: false }, 'overview')).toEqual(['overview', 'activity']);
		expect(visibleTabs({ report: true, pipeline: false }, 'overview')).toEqual(['overview', 'activity', 'report']);
		expect(visibleTabs({ report: true, pipeline: true }, 'activity')).toEqual(['overview', 'activity', 'report', 'pipeline']);
	});
	it('keeps a deep-linked tab visible so old addresses stay valid', () => {
		expect(visibleTabs({ report: false, pipeline: false }, 'tests')).toEqual(['overview', 'activity', 'tests']);
		expect(visibleTabs({ report: false, pipeline: false }, 'pipeline')).toEqual(['overview', 'activity', 'pipeline']);
	});
	it('arrow keys move through the visible tabs only', () => {
		const tabs = visibleTabs({ report: true, pipeline: false }, 'overview');
		expect(tabAfterKey('report', 'ArrowRight', tabs)).toBe('overview');
		expect(tabAfterKey('overview', 'ArrowLeft', tabs)).toBe('report');
		expect(tabAfterKey('overview', 'End', tabs)).toBe('report');
	});
});
