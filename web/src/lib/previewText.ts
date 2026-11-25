/**
 * Plain text for a short preview of Markdown written by agents: emphasis, code marks, headings, quotes, fences and link
 * targets go, list items are joined with "·". Works on multi-line text and on text the server already flattened to one
 * line. It is only a preview: the card detail renders the original.
 */
export function previewText(source: string): string {
	const code: string[] = [];
	const text = source
		.replace(/```[\w+-]*(?=\s|$)/g, ' ')
		// Code spans are kept verbatim (no emphasis handling inside), only their backticks go.
		.replace(/`([^`\n]+)`/g, (_, inner: string) => `\u0000${code.push(inner) - 1}\u0000`)
		.replace(/`/g, '')
		.replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/!?\[([^\]]*)\]\([^)\s]*$/g, '$1');

	let joined = '';
	for (const raw of text.split('\n')) {
		let line = raw.trim().replace(/^(>\s*)+/, '');
		if (!line || /^([-*_])(\s*\1){2,}$/.test(line)) continue;
		line = line.replace(/^#{1,6}\s+/, '');
		const bullet = /^[-*+]\s+/.test(line);
		if (bullet) line = line.replace(/^[-*+]\s+/, '').replace(/^\[[ xX]\]\s*/, '');
		const item = bullet || /^\d{1,3}[.)]\s/.test(line);
		joined += (joined ? (item ? ' · ' : ' ') : '') + line;
	}

	return joined
		.replace(/(^|\s)#{2,6}\s+/g, '$1')
		// A list the server flattened: " - " or " * " between words. A range such as "10 - 20" stays.
		.replace(/(?<=(\S)) [-*] (?=(\S))/g, (m, a: string, b: string) => (/\d/.test(a) && /\d/.test(b) ? m : ' · '))
		.replace(/· \[[ xX]\] /g, '· ')
		.replace(/\*\*|~~/g, '')
		.replace(/(?<![\p{L}\p{N}])__|__(?![\p{L}\p{N}])/gu, '')
		.replace(/(?<![\p{L}\p{N}*])\*(?=\S)([^*]*?\S)\*(?![\p{L}\p{N}*])/gu, '$1')
		.replace(/(?<![\p{L}\p{N}_])_(?=\S)([^_]*?\S)_(?![\p{L}\p{N}_])/gu, '$1')
		.replace(/\s+/g, ' ')
		.trim()
		.replace(/\u0000(\d+)\u0000/g, (_, i: string) => code[Number(i)] ?? '');
}
