<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type PlanningTask } from '#lib/api.js';
	import { isOwner } from '#lib/access.js';
	import { bindingsForProject, type ProjectBinding } from '#lib/agentsLogic.js';
	import { autoStartBlock, autoStartNeedsDevice, saveAutoStart } from '#lib/autoStart.js';
	import { t } from '#lib/i18n/index.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Select } from '#lib/components/ui/select/index.js';

	/**
	 * Per-card permission "Wächter darf diese Karte zum geplanten Start automatisch starten" (ADR 0033 stage C).
	 * Only hides and explains; the backend checks owner, session, start time and binding again.
	 */
	let {
		taskID,
		projectID,
		version,
		status,
		plannedAt,
		plannedAllDay = false,
		autoStart,
		onchanged
	}: {
		taskID: string;
		projectID: string;
		version: number;
		status: string;
		plannedAt: string | null | undefined;
		plannedAllDay?: boolean;
		autoStart: boolean;
		onchanged?: (pt: PlanningTask) => unknown;
	} = $props();

	let bindings = $state<ProjectBinding[]>([]);
	let loaded = $state(false);
	let accountAllowed = $state<boolean | null>(null);
	let busy = $state(false);
	let error = $state('');
	let info = $state('');
	let deviceID = $state('');

	// The version moves with every save of this switch; the prop is the starting point after each reload.
	/* svelte-ignore state_referenced_locally */
	let ownVersion = $state<number | null>(null);
	/* svelte-ignore state_referenced_locally */
	let ownEnabled = $state<boolean | null>(null);
	const enabled = $derived(ownEnabled ?? autoStart);
	const currentVersion = $derived(ownVersion ?? version);
	$effect(() => {
		void version;
		void autoStart;
		ownVersion = null;
		ownEnabled = null;
	});

	const project = $derived(workspace.projects.find((p) => p.id === projectID));
	const owner = $derived(project ? isOwner(project) : false);
	const needsDevice = $derived(autoStartNeedsDevice(bindings));
	const devices = $derived([...new Map(bindings.map((b) => [b.deviceID, b.deviceLabel])).entries()]);
	// While the bindings load, the reason "no binding" must not flash: only judge the binding once they are known.
	const block = $derived(autoStartBlock({ status, plannedAt, plannedAllDay, isOwner: owner, bindings: loaded ? bindings.length : 1 }));
	const disabled = $derived(busy || (!enabled && block !== null) || (enabled && !owner));
	const needsChoice = $derived(needsDevice && !enabled && !deviceID);

	onMount(() => {
		void (async () => {
			try {
				bindings = bindingsForProject(await api.listDevices(), projectID);
			} catch {
				bindings = [];
			}
			loaded = true;
		})();
		void api.autoStartSetting().then((s) => (accountAllowed = s.allowed), () => (accountAllowed = null));
	});

	async function toggle(next: boolean) {
		if (busy) return;
		if (next && needsDevice && !deviceID) {
			error = t('autostart.error.device_required');
			return;
		}
		busy = true;
		error = '';
		info = '';
		const r = await saveAutoStart((id, body) => api.setAutoStart(id, body), { taskID, version: currentVersion }, next, deviceID || undefined);
		busy = false;
		if (r.ok) {
			ownVersion = r.task.task.version;
			ownEnabled = r.task.autoStart ?? next;
			info = next ? t('autostart.enabled') : t('autostart.disabled');
			await onchanged?.(r.task);
		} else {
			error = t(r.key);
		}
	}
	const id = $derived(`autostart-${taskID}`);
</script>

<div class="flex flex-col gap-1.5 text-sm" data-testid="autostart-toggle">
	<label class="flex items-start gap-2" for={id}>
		<input
			{id}
			type="checkbox"
			role="switch"
			class="focus-visible:ring-ring mt-0.5 size-4 shrink-0 rounded focus-visible:ring-2 focus-visible:outline-none"
			checked={enabled}
			{disabled}
			aria-describedby="{id}-hint"
			data-testid="autostart-switch"
			onchange={(ev) => toggle((ev.currentTarget as HTMLInputElement).checked)}
		/>
		<span class="font-medium">{t('autostart.toggle')}</span>
	</label>
	<div id="{id}-hint" class="text-muted-foreground flex flex-col gap-1 text-xs">
		{#if !enabled && block}
			<p data-testid="autostart-reason">{t(block)}</p>
		{:else if !owner}
			<p data-testid="autostart-reason">{t('autostart.block.owner')}</p>
		{:else}
			<p>{t('autostart.toggle.hint')}</p>
		{/if}
		{#if accountAllowed === false}<p data-testid="autostart-account-off">{t('autostart.account.offNote')}</p>{/if}
	</div>
	{#if needsDevice && !enabled && owner}
		<label class="flex flex-col gap-1 text-xs font-medium">{t('autostart.device')}
			<Select bind:value={deviceID} data-testid="autostart-device">
				<option value="">–</option>
				{#each devices as [did, label] (did)}<option value={did}>{label}</option>{/each}
			</Select>
		</label>
		{#if needsChoice && !block}<span class="sr-only">{t('autostart.error.device_required')}</span>{/if}
	{/if}
	<p class="min-h-4 text-xs" role="status" aria-live="polite" data-testid="autostart-info">{info}</p>
	{#if error}<p class="text-destructive text-xs" role="alert" data-testid="autostart-error">{error}</p>{/if}
</div>
