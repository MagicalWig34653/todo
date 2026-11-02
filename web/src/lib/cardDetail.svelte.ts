import { buildCardParam, type CardRef } from './cardRef.js';

/**
 * State of the large card detail window. Any component opens a card with `cardDetail.open(ref)`; the Workspace renders
 * the window. Opening pushes a history entry (`?card=<type>:<id>`), so the browser's back button closes it and a reload
 * or a shared link opens the same card.
 */
class CardDetailState {
	ref = $state<CardRef | null>(null);
	/** `?card=` was present but invalid: the window shows a friendly message. */
	invalid = $state(false);
	/** True when this window pushed its own history entry (so closing can go back instead of rewriting the URL). */
	private pushed = false;

	get visible(): boolean {
		return this.ref !== null || this.invalid;
	}

	open(ref: CardRef): void {
		if (this.ref && this.ref.type === ref.type && this.ref.id === ref.id) return;
		this.ref = ref;
		this.invalid = false;
		const url = new URL(location.href);
		url.searchParams.set('card', buildCardParam(ref));
		history.pushState(null, '', url.pathname + url.search.replace(/%3A/gi, ':'));
		this.pushed = true;
	}

	/** Applies the card of a route (page load, popstate) without touching the history. */
	apply(ref: CardRef | undefined, invalid = false): void {
		this.ref = ref ?? null;
		this.invalid = !ref && invalid;
		if (!ref && !invalid) this.pushed = false;
	}

	/** Closed by the user (button, Escape, backdrop): back to the entry before the window, or just drop the parameter. */
	close(): void {
		if (!this.visible) return;
		const wasPushed = this.pushed;
		this.ref = null;
		this.invalid = false;
		this.pushed = false;
		if (wasPushed) {
			history.back();
			return;
		}
		const url = new URL(location.href);
		if (url.searchParams.has('card')) {
			url.searchParams.delete('card');
			history.replaceState(null, '', url.pathname + url.search);
		}
	}

	/** Leaves for another page (link inside the window): no history step back, the navigation pushes its own entry. */
	leave(): void {
		this.ref = null;
		this.invalid = false;
		this.pushed = false;
	}
}

export const cardDetail = new CardDetailState();
