import type { JobState, RunnerBinding, RunnerDevice } from './api.js';

export const SCOPE_MAX = 4000;
export const LABEL_MAX = 100;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: string): boolean => UUID.test(v.trim());

/** Jobs that can still be stopped; finished ones (and awaiting_review, which has its own decision) cannot. */
export function canStopJob(state: JobState): boolean {
	return state === 'queued' || state === 'claimed' || state === 'running' || state === 'waiting_for_answer';
}

/** Devices that accept new bindings: pairing finished and not revoked. */
export function bindableDevices(devices: RunnerDevice[]): RunnerDevice[] {
	return devices.filter((d) => d.paired && !d.revokedAt);
}

export interface ProjectBinding extends RunnerBinding {
	deviceLabel: string;
}
/** Bindings of one project on devices that are still allowed to work. */
export function bindingsForProject(devices: RunnerDevice[], projectID: string): ProjectBinding[] {
	return devices
		.filter((d) => !d.revokedAt)
		.flatMap((d) => d.bindings.filter((b) => b.projectID === projectID).map((b) => ({ ...b, deviceLabel: d.label })));
}

/** Null when the binding form is valid, else the reason as a stable code. */
export function validateBinding(f: { projectID: string; deviceID: string; repositoryKey: string; label: string }): 'incomplete' | 'key' | null {
	if (!f.projectID || !f.deviceID || !f.label.trim() || f.label.trim().length > LABEL_MAX) return 'incomplete';
	return isUuid(f.repositoryKey) ? null : 'key';
}

export function validateRelease(f: { taskID: string; bindingID: string; scope: string }): boolean {
	const scope = f.scope.trim();
	return !!f.taskID && !!f.bindingID && scope.length > 0 && scope.length <= SCOPE_MAX;
}
