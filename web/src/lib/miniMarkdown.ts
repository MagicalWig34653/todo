/** Tiny, safe Markdown subset for the agent manual (no HTML is ever produced; the view renders blocks as text). */
export type MdInline = { kind: 'text' | 'code' | 'strong'; text: string };
export type MdBlock =
	| { kind: 'heading'; level: 1 | 2 | 3; inline: MdInline[] }
	| { kind: 'paragraph'; inline: MdInline[] }
	| { kind: 'list'; items: MdInline[][] }
	| { kind: 'code'; text: string };

export function parseInline(s: string): MdInline[] {
	const out: MdInline[] = [];
	const re = /`([^`]+)`|\*\*([^*]+)\*\*/g;
	let last = 0;
	for (let m = re.exec(s); m; m = re.exec(s)) {
		if (m.index > last) out.push({ kind: 'text', text: s.slice(last, m.index) });
		out.push(m[1] !== undefined ? { kind: 'code', text: m[1] } : { kind: 'strong', text: m[2]! });
		last = m.index + m[0].length;
	}
	if (last < s.length) out.push({ kind: 'text', text: s.slice(last) });
	return out;
}

export function parseMarkdown(src: string): MdBlock[] {
	const blocks: MdBlock[] = [];
	const lines = src.replace(/\r\n/g, '\n').split('\n');
	let para: string[] = [];
	let list: MdInline[][] | null = null;
	const flush = () => {
		if (para.length) blocks.push({ kind: 'paragraph', inline: parseInline(para.join(' ')) });
		if (list) blocks.push({ kind: 'list', items: list });
		para = [];
		list = null;
	};
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i]!;
		if (line.startsWith('```')) {
			flush();
			const code: string[] = [];
			for (i++; i < lines.length && !lines[i]!.startsWith('```'); i++) code.push(lines[i]!);
			blocks.push({ kind: 'code', text: code.join('\n') });
			continue;
		}
		const h = /^(#{1,3})\s+(.*)$/.exec(line);
		if (h) {
			flush();
			blocks.push({ kind: 'heading', level: h[1]!.length as 1 | 2 | 3, inline: parseInline(h[2]!) });
			continue;
		}
		const li = /^\s*[-*]\s+(.*)$/.exec(line);
		if (li) {
			if (para.length) {
				blocks.push({ kind: 'paragraph', inline: parseInline(para.join(' ')) });
				para = [];
			}
			(list ??= []).push(parseInline(li[1]!));
			continue;
		}
		if (line.trim() === '') {
			flush();
			continue;
		}
		if (list) flush();
		para.push(line.trim());
	}
	flush();
	return blocks;
}
