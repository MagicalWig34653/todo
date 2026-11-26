/**
 * Explanations show one sentence; the rest waits behind "Mehr erfahren" (UX concept §1). Splits after the first sentence
 * end (`.`, `!`, `?`, `…` followed by a space). German abbreviations ("z. B.", "bzw.", "ca.") and single letters do not end
 * a sentence. Whitespace is collapsed.
 */
const ABBREVIATION = /(?:^|[\s(„"])(?:\p{L}|ca|bzw|usw|vgl|etc|evtl|ggf|inkl|bspw|Nr|Std|Min)\.$/u;

export function splitLead(text: string): { lead: string; rest: string } {
	const s = text.replace(/\s+/g, ' ').trim();
	const end = /[.!?…](?= \S)/g;
	for (let m = end.exec(s); m; m = end.exec(s)) {
		const lead = s.slice(0, m.index + 1);
		if (m[0] === '.' && ABBREVIATION.test(lead)) continue;
		return { lead, rest: s.slice(m.index + 2) };
	}
	return { lead: s, rest: '' };
}
