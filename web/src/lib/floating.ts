/** Pure viewport-collision placement for anchored panels (menus, popovers). No DOM access, so it is unit-testable. */

export interface Rect {
	top: number;
	left: number;
	right: number;
	bottom: number;
}

export interface Placement {
	top: number;
	left: number;
	/** Panel max-height in px; the panel scrolls internally beyond it. */
	maxHeight: number;
	/** Panel max-width in px. */
	maxWidth: number;
	side: 'bottom' | 'top' | 'overlay';
}

export interface PlaceOptions {
	align?: 'start' | 'end';
	/** Distance between anchor and panel. */
	gap?: number;
	/** Minimum distance to every viewport edge. */
	margin?: number;
	/** Smallest side space still worth using before the panel overlays the anchor instead (landscape phones). */
	minUsable?: number;
}

/**
 * Places a panel of natural size (width x height) next to `anchor` inside a viewport of vw x vh:
 * flip to the side with room, shift horizontally into the viewport, and cap the height (scrolling) so the
 * panel never leaves the viewport. When neither side offers a usable amount of space the panel overlays the anchor.
 */
export function placePanel(anchor: Rect, size: { width: number; height: number }, viewport: { width: number; height: number }, opts: PlaceOptions = {}): Placement {
	const { align = 'start', gap = 4, margin = 8, minUsable = 160 } = opts;
	const maxWidth = Math.max(0, viewport.width - 2 * margin);
	const width = Math.min(size.width, maxWidth);
	let left = align === 'end' ? anchor.right - width : anchor.left;
	left = Math.max(margin, Math.min(left, viewport.width - width - margin));

	const below = viewport.height - anchor.bottom - gap - margin;
	const above = anchor.top - gap - margin;
	const full = Math.max(0, viewport.height - 2 * margin);
	const h = size.height;

	let side: Placement['side'];
	let top: number;
	let maxHeight: number;
	if (h <= below) {
		side = 'bottom';
		top = anchor.bottom + gap;
		maxHeight = below;
	} else if (h <= above) {
		side = 'top';
		top = anchor.top - gap - h;
		maxHeight = above;
	} else {
		const best = Math.max(below, above);
		if (best >= Math.min(h, minUsable)) {
			maxHeight = best;
			if (below >= above) {
				side = 'bottom';
				top = anchor.bottom + gap;
			} else {
				side = 'top';
				top = margin;
			}
		} else {
			side = 'overlay';
			maxHeight = full;
			top = margin;
		}
	}
	// Final guard: whatever was chosen, the box [top, top + min(h, maxHeight)] stays inside the margins.
	maxHeight = Math.max(0, Math.min(maxHeight, full));
	const shown = Math.min(h, maxHeight);
	top = Math.max(margin, Math.min(top, viewport.height - shown - margin));
	return { top, left, maxHeight, maxWidth, side };
}
