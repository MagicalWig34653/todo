/** Project groups and rule selections (ADR 0037, card BEF08998 part 3): pure helpers for the settings pages. No DOM. */

import type { MessageKey } from './i18n/index.js';

export type SelectionMode = 'selected' | 'all_except';

/** A connection's or mandate's choice: explicit projects plus the rule (contracts/connections.yaml 1.7.0, `Selection`). */
export interface Selection {
	mode: SelectionMode;
	projectIDs: string[];
	groupIDs: string[];
	excludedProjectIDs: string[];
	excludedGroupIDs: string[];
}

/** `selection` as the server answers it; absent/null means "explicit projects only". */
export interface SelectionDTO {
	mode: string;
	projectIDs: string[];
	groupIDs: string[];
	excludedProjectIDs: string[];
	excludedGroupIDs: string[];
}

export interface ProjectGroup {
	id: string;
	name: string;
	/** Members the person can read now. */
	projectIDs: string[];
}

/** How a group change moves the reach of one connection or mandate (`dryRun` answers it before saving). */
export interface SelectionChange {
	kind: 'mandate' | 'connection';
	grantID: string;
	name: string;
	added: string[];
	removed: string[];
}

export interface SelectionPreview {
	projectIDs: string[];
	/** Own projects an agent created: "all" leaves them out until the person picks them or puts them in a group. */
	agentCreatedProjectIDs: string[];
}

export const MAX_GROUP_NAME = 80;

const k = (id: string) => id.toLowerCase();

export const emptySelection = (): Selection => ({ mode: 'selected', projectIDs: [], groupIDs: [], excludedProjectIDs: [], excludedGroupIDs: [] });

export const isPlain = (s: Selection) =>
	s.mode === 'selected' && s.groupIDs.length === 0 && s.excludedProjectIDs.length === 0 && s.excludedGroupIDs.length === 0;

/** Whether the selection names anything at all (an empty group counts: it may get members). */
export const namesSomething = (s: Selection) => s.projectIDs.length > 0 || s.groupIDs.length > 0 || s.mode === 'all_except';

/** Request body part: a plain list goes without `selection` (old meaning, old servers). */
export function selectionBody(s: Selection): { projectIDs: string[]; selection?: Omit<Selection, 'projectIDs'> } {
	if (isPlain(s)) return { projectIDs: [...s.projectIDs] };
	return {
		projectIDs: [...s.projectIDs],
		selection: { mode: s.mode, groupIDs: [...s.groupIDs], excludedProjectIDs: [...s.excludedProjectIDs], excludedGroupIDs: [...s.excludedGroupIDs] }
	};
}

/** Form state from a server answer: with a rule its own explicit list counts, otherwise `explicit`. */
export function selectionFrom(explicit: readonly string[], dto: SelectionDTO | null | undefined): Selection {
	if (!dto) return { ...emptySelection(), projectIDs: [...explicit] };
	return {
		mode: dto.mode === 'all_except' ? 'all_except' : 'selected',
		projectIDs: [...dto.projectIDs],
		groupIDs: [...dto.groupIDs],
		excludedProjectIDs: [...dto.excludedProjectIDs],
		excludedGroupIDs: [...dto.excludedGroupIDs]
	};
}

export function toggleID(list: readonly string[], id: string): string[] {
	return list.some((x) => k(x) === k(id)) ? list.filter((x) => k(x) !== k(id)) : [...list, id];
}

export const hasID = (list: readonly string[], id: string) => list.some((x) => k(x) === k(id));

/** Added and removed ids (compared case-insensitively). */
export function diffIDs(before: readonly string[], after: readonly string[]): { added: string[]; removed: string[] } {
	const was = new Set(before.map(k)), will = new Set(after.map(k));
	return { added: after.filter((id) => !was.has(k(id))), removed: before.filter((id) => !will.has(k(id))) };
}

/** Same rules as the server: 1 to 80 characters after trimming, unique per person regardless of case. */
export function groupNameProblem(raw: string, groups: readonly ProjectGroup[], selfID?: string): MessageKey | null {
	const name = raw.trim().replace(/\s+/g, ' ');
	if (!name || name.length > MAX_GROUP_NAME) return 'projectGroups.error.name';
	if (groups.some((g) => g.name.toLowerCase() === name.toLowerCase() && (!selfID || k(g.id) !== k(selfID)))) return 'projectGroups.error.taken';
	return null;
}

/** Same choice? Order and letter case of the ids do not matter. */
export function sameSelection(a: Selection, b: Selection): boolean {
	const norm = (s: Selection) => JSON.stringify([s.mode, ...[s.projectIDs, s.groupIDs, s.excludedProjectIDs, s.excludedGroupIDs].map((l) => l.map(k).sort())]);
	return norm(a) === norm(b);
}

/** Drops ids that no longer exist in the loaded lists (a project or group vanished while the form was open). */
export function pruneSelection(s: Selection, projectIDs: readonly string[], groupIDs: readonly string[]): Selection {
	const p = new Set(projectIDs.map(k)), g = new Set(groupIDs.map(k));
	return {
		mode: s.mode,
		projectIDs: s.projectIDs.filter((id) => p.has(k(id))),
		groupIDs: s.groupIDs.filter((id) => g.has(k(id))),
		excludedProjectIDs: s.excludedProjectIDs.filter((id) => p.has(k(id))),
		excludedGroupIDs: s.excludedGroupIDs.filter((id) => g.has(k(id)))
	};
}

/** One line describing a rule ("Alle eigenen Projekte außer …", "Gruppen: …"); null for a plain list. */
export function describeRule(
	dto: SelectionDTO | null | undefined,
	groupName: (id: string) => string,
	projectName: (id: string) => string
): { key: MessageKey; groups: string; excluded: string } | null {
	if (!dto) return null;
	const excluded = [...dto.excludedGroupIDs.map(groupName), ...dto.excludedProjectIDs.map(projectName)].join(', ');
	const key: MessageKey = dto.mode === 'all_except'
		? excluded ? 'projectGroups.rule.allExcept' : 'projectGroups.rule.all'
		: dto.groupIDs.length ? excluded ? 'projectGroups.rule.groupsExcept' : 'projectGroups.rule.groups' : 'projectGroups.rule.selectedExcept';
	return { key, groups: dto.groupIDs.map(groupName).join(', '), excluded };
}

/** The sentence the page shows under the choice: new projects join by themselves with "all except" and with groups. */
export function selectionSummaryKey(s: Selection): MessageKey | null {
	if (s.mode === 'all_except') return 'projectGroups.selection.allExceptHint';
	if (s.groupIDs.length > 0) return 'projectGroups.selection.groupsHint';
	return null;
}
