/**
 * Keys for a keyed `{#each}` over data the server or a person can repeat. Svelte throws `each_key_duplicate` (also in the
 * production build) when two entries share a key, and SvelteKit then shows its "500 Internal Error" page instead of the view
 * (card B0CF5F73: several screenshots of one build share `buildID`).
 *
 * The first entry keeps its key, later repeats get `#2`, `#3`, ... (a number that is already taken moves on), so keys stay
 * stable while the list only grows or loses entries elsewhere.
 */
export function uniqueKeys<T>(items: readonly T[], base: (item: T, index: number) => string): { item: T; key: string }[] {
	const used = new Set<string>();
	const repeats = new Map<string, number>();
	return items.map((item, index) => {
		const wanted = base(item, index);
		let key = wanted;
		while (used.has(key)) {
			const n = (repeats.get(wanted) ?? 1) + 1;
			repeats.set(wanted, n);
			key = `${wanted}#${n}`;
		}
		used.add(key);
		return { item, key };
	});
}
