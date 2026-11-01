/** Small helpers against overlapping async work in components. */

/**
 * One operation per key at a time (for example one PUT per OAuth grant). `run` returns `undefined` without calling `fn`
 * while the key is busy, so a second request is never sent before the first one answered. `onchange` mirrors the busy
 * keys into component state.
 */
export function createKeyedGate(onchange: (busy: string[]) => void = () => {}) {
	const busy = new Set<string>();
	const publish = () => onchange([...busy]);
	return {
		has: (key: string) => busy.has(key),
		async run<T>(key: string, fn: () => Promise<T>): Promise<{ value: T } | undefined> {
			if (busy.has(key)) return undefined;
			busy.add(key);
			publish();
			try {
				return { value: await fn() };
			} finally {
				busy.delete(key);
				publish();
			}
		}
	};
}

/** Latest-wins loading: every `begin()` invalidates the tokens handed out before. */
export function createLatest() {
	let seq = 0;
	return {
		begin() {
			const mine = ++seq;
			return () => mine === seq;
		}
	};
}
