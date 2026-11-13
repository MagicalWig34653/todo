import { buildCardParam, neighborsOf, sameCard, type CardRef } from './cardRef.js';
import { DEFAULT_TAB, type CardTab } from './cardTabs.js';

/**
 * State of the large card detail window. Any component opens a card with `cardDetail.open(ref)`; the Workspace renders
 * the window. Opening pushes a history entry (`?card=<type>:<id>`), so the browser's back button closes it and a reload
 * or a shared link opens the same card.
 */
class CardDetailState {
	ref = $state<CardRef | null>(null);
	/** `?card=` was present but invalid: the window shows a friendly message. */
	invalid = $state(false);
	/** Selected tab (`?tab=`, default overview). A tab change rewrites the URL without a new history entry. */
	tab = $state<CardTab>(DEFAULT_TAB);
	/** The cards of the list or column the window was opened from, in display order (for the up/down navigation). */
	siblings = $state<CardRef[]>([]);
	/** True when this window pushed its own history entry (so closing can go back instead of rewriting the URL). */
	private pushed = false;

	get visible(): boolean {
		return this.ref !== null || this.invalid;
	}

	get neighbors() {
		return neighborsOf(this.siblings, this.ref);
	}

	open(ref: CardRef, siblings: readonly CardRef[] = []): void {
		if (sameCard(this.ref, ref)) return;
		this.ref = ref;
		this.siblings = [...siblings];
		this.invalid = false;
		this.tab = DEFAULT_TAB;
		const url = new URL(location.href);
		url.searchParams.set('card', buildCardParam(ref));
		url.searchParams.delete('tab');
		history.pushState(null, '', url.pathname + url.search.replace(/%3A/gi, ':'));
		this.pushed = true;
	}

	/** Shows another card of the list without a new history entry (the back button still closes the window). */
	step(delta: -1 | 1): void {
		const { prev, next } = this.neighbors;
		const target = delta < 0 ? prev : next;
		if (!target) return;
		this.ref = target;
		const url = new URL(location.href);
		url.searchParams.set('card', buildCardParam(target));
		history.replaceState(history.state, '', url.pathname + url.search.replace(/%3A/gi, ':'));
	}

	/** Selects a tab of the open card; the URL changes in place (the back button still closes the window). */
	setTab(tab: CardTab): void {
		if (this.tab === tab) return;
		this.tab = tab;
		if (!this.ref) return;
		const url = new URL(location.href);
		if (tab === DEFAULT_TAB) url.searchParams.delete('tab');
		else url.searchParams.set('tab', tab);
		history.replaceState(history.state, '', url.pathname + url.search.replace(/%3A/gi, ':'));
	}

	/** Applies the card of a route (page load, popstate) without touching the history. */
	apply(ref: CardRef | undefined, invalid = false, tab: CardTab = DEFAULT_TAB): void {
		this.ref = ref ?? null;
		this.tab = ref ? tab : DEFAULT_TAB;
		this.invalid = !ref && invalid;
		if (!ref && !invalid) this.pushed = false;
		if (!ref || !this.siblings.some((c) => sameCard(c, ref))) this.siblings = [];
	}

	/** Closed by the user (button, Escape, backdrop): back to the entry before the window, or just drop the parameter. */
	close(): void {
		if (!this.visible) return;
		const wasPushed = this.pushed;
		this.ref = null;
		this.siblings = [];
		this.invalid = false;
		this.pushed = false;
		this.tab = DEFAULT_TAB;
		if (wasPushed) {
			history.back();
			return;
		}
		const url = new URL(location.href);
		if (url.searchParams.has('card')) {
			url.searchParams.delete('card');
			url.searchParams.delete('tab');
			history.replaceState(null, '', url.pathname + url.search);
		}
	}

	/** Leaves for another page (link inside the window): no history step back, the navigation pushes its own entry. */
	leave(): void {
		this.tab = DEFAULT_TAB;
		this.ref = null;
		this.siblings = [];
		this.invalid = false;
		this.pushed = false;
	}
}

export const cardDetail = new CardDetailState();
