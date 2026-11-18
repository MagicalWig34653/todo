import { undoRemainingMs } from './reviewUndo.js';

/** The most recent review decision the user may still take back (shown as a toast outside the card window). */
class ReviewUndoOffer {
	taskID = $state<string | null>(null);
	until = $state<string | null>(null);
	/** What the decision was, e.g. "Variante B gewählt: Radarkarte"; null = the generic "Entscheidung gespeichert". */
	message = $state<string | null>(null);

	offer(taskID: string, until: string | null | undefined, message: string | null = null): void {
		if (until && undoRemainingMs(until) > 0) {
			this.taskID = taskID;
			this.until = until;
			this.message = message;
		}
	}

	clear(): void {
		this.taskID = null;
		this.until = null;
		this.message = null;
	}
}

export const reviewUndo = new ReviewUndoOffer();
