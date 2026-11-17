/** Short, human-readable form of an entry id (first 8 characters, upper case, as shown in messages) and local lookup by it. */

export function shortID(id: string | null | undefined): string {
	return id ? id.slice(0, 8).toUpperCase() : '';
}

/** The normalised short id when the input is exactly 8 hex characters (any case, optional leading #), otherwise null. */
export function parseShortIdQuery(raw: string): string | null {
	const m = /^#?([0-9a-fA-F]{8})$/.exec(raw.trim());
	return m ? m[1]!.toUpperCase() : null;
}

export interface IdHit {
	kind: 'task' | 'question' | 'review';
	id: string;
	/** Id for the card reference: the task id for reviews (a review card is addressed by its task), else the entry id. */
	cardID: string;
	title: string;
}

export function findByShortID(
	short: string,
	src: {
		tasks: readonly { id: string; title: string }[];
		questions: readonly { id: string; taskID: string; prompt: string }[];
		reviews: readonly { id: string; taskID: string; summary: string }[];
	}
): IdHit[] {
	const is = (id: string) => shortID(id) === short;
	return [
		...src.tasks.filter((x) => is(x.id)).map((x): IdHit => ({ kind: 'task', id: x.id, cardID: x.id, title: x.title })),
		...src.questions.filter((x) => is(x.id)).map((x): IdHit => ({ kind: 'question', id: x.id, cardID: x.id, title: x.prompt })),
		...src.reviews.filter((x) => is(x.id)).map((x): IdHit => ({ kind: 'review', id: x.id, cardID: x.taskID, title: x.summary }))
	];
}
