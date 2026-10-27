import type { TeamMembership } from './api.js';

/** The directory search needs at least two characters (contracts/sharing.yaml). */
export const MIN_SEARCH_LENGTH = 2;

/** Name for a member row: own account, the display name from the member list, else the raw ID. */
export function memberLabel(m: Pick<TeamMembership, 'userID' | 'displayName'>, selfID: string | undefined, selfText: string): string {
	if (m.userID === selfID) return selfText;
	return m.displayName?.trim() || m.userID;
}

/** Author or actor name with a fallback text when the account no longer exists. */
export function personName(name: string | null | undefined, fallback: string): string {
	return name?.trim() || fallback;
}
