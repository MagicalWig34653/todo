<script lang="ts">
	import { onMount } from 'svelte';
	import { adminSettings, expandSelection, followsParent, transferReady, type AdminUser, type OwnedProject, type TransferTeam } from '#lib/adminSettings.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Dialog from '../app/Dialog.svelte';
	import PersonPicker from '../PersonPicker.svelte';

	/** Admin hands the projects of a locked account to a person or a team (contracts/admin-settings.yaml). */
	let { user, ondone, onclose }: { user: AdminUser; ondone: () => void | Promise<void>; onclose: () => void } = $props();

	// Mounted per account (the parent renders it with {#if}), so the dialog starts open.
	let open = $state(true);
	let rows = $state<OwnedProject[]>([]);
	let teams = $state<TransferTeam[]>([]);
	let loaded = $state(false);
	let selected = $state<Set<string>>(new Set());
	let targetType = $state<'person' | 'team'>('person');
	let personID = $state('');
	let personName = $state('');
	let teamID = $state('');
	let step = $state<'form' | 'confirm' | 'done'>('form');
	let busy = $state(false);
	let doneCount = $state(0);
	let doneTarget = $state('');

	const targetID = $derived(targetType === 'person' ? personID.trim() : teamID);
	const targetLabel = $derived(
		targetType === 'team'
			? t('settings.admin.transfer.teamTarget', { name: teams.find((x) => x.id === teamID)?.name ?? '' })
			: personName || personID.trim()
	);
	const ready = $derived(transferReady({ type: targetType, id: targetID }, selected));

	$effect(() => {
		if (!open) onclose();
	});
	onMount(() => void init(user));

	async function init(u: AdminUser) {
		notice.clear();
		rows = [];
		selected = new Set();
		loaded = false;
		step = 'form';
		targetType = 'person';
		personID = personName = teamID = '';
		await attempt(async () => {
			const [list, tms] = await Promise.all([adminSettings.ownedProjects(u.id), adminSettings.transferTeams()]);
			rows = list;
			teams = tms;
			selected = new Set(list.map((r) => r.id));
		});
		loaded = true;
	}

	function toggle(r: OwnedProject, on: boolean) {
		const next = new Set(selected);
		if (on) next.add(r.id);
		else next.delete(r.id);
		selected = on ? expandSelection(rows, next) : next;
	}
	function pickAll(on: boolean) {
		selected = on ? new Set(rows.map((r) => r.id)) : new Set();
	}

	async function submit() {
		busy = true;
		const target = { type: targetType, id: targetID };
		const ok = await attempt(async () => {
			const result = await adminSettings.transferProjects(user.id, target, [...selected]);
			doneCount = result.transferred;
			doneTarget = targetLabel;
		});
		busy = false;
		if (ok) {
			step = 'done';
			await ondone();
		}
	}
</script>

<Dialog bind:open title={t('settings.admin.transfer.title', { name: user.displayName })} testid="admin-transfer-dialog">
	<div class="flex flex-col gap-3 text-sm">
			{#if step === 'done'}
				<p class="font-medium" data-testid="admin-transfer-done">{t('settings.admin.transfer.done', { count: doneCount, target: doneTarget })}</p>
				<div class="flex justify-end">
					<Button onclick={() => (open = false)} data-testid="admin-transfer-close">{t('settings.admin.transfer.close')}</Button>
				</div>
			{:else if !loaded}
				<p class="text-muted-foreground">{t('settings.admin.transfer.loading')}</p>
			{:else if rows.length === 0}
				<p class="text-muted-foreground">{t('settings.admin.transfer.empty')}</p>
			{:else if step === 'confirm'}
				<p data-testid="admin-transfer-summary">
					{t('settings.admin.transfer.confirm', { count: selected.size, name: user.displayName, target: targetLabel })}
				</p>
				<div class="flex flex-wrap justify-end gap-2">
					<Button variant="ghost" onclick={() => (step = 'form')}>{t('settings.admin.transfer.back')}</Button>
					<Button disabled={busy} onclick={submit} data-testid="admin-transfer-submit">{t('settings.admin.transfer.submit')}</Button>
				</div>
			{:else}
				<p class="text-muted-foreground">{t('settings.admin.transfer.intro')}</p>
				<div class="flex gap-2">
					<Button size="sm" variant="ghost" onclick={() => pickAll(true)}>{t('settings.admin.transfer.selectAll')}</Button>
					<Button size="sm" variant="ghost" onclick={() => pickAll(false)}>{t('settings.admin.transfer.selectNone')}</Button>
				</div>
				<ul class="flex max-h-60 flex-col divide-y overflow-auto rounded-md border" data-testid="admin-transfer-projects">
					{#each rows as r (r.id)}
						{@const follows = followsParent(rows, r, selected)}
						<li class="flex items-start gap-2 px-2 py-1.5">
							<input
								type="checkbox"
								class="mt-1"
								checked={selected.has(r.id)}
								disabled={follows}
								title={follows ? t('settings.admin.transfer.follows') : undefined}
								onchange={(e) => toggle(r, e.currentTarget.checked)}
								aria-label={r.name}
								data-testid="admin-transfer-project-{r.id}"
							/>
							<div class="min-w-0 flex-1">
								<div class="truncate font-medium">{r.name}</div>
								<div class="text-muted-foreground text-xs">
									{t('settings.admin.transfer.tasks', { count: r.taskCount })}{#if r.parentName} · {t('settings.admin.transfer.inParent', { name: r.parentName })}{/if}
								</div>
							</div>
						</li>
					{/each}
				</ul>
				<fieldset class="flex flex-col gap-2">
					<legend class="mb-1 font-medium">{t('settings.admin.transfer.target')}</legend>
					<div class="flex gap-4">
						<label class="flex items-center gap-1.5">
							<input type="radio" bind:group={targetType} value="person" data-testid="admin-transfer-type-person" />
							{t('settings.admin.transfer.targetPerson')}
						</label>
						<label class="flex items-center gap-1.5">
							<input type="radio" bind:group={targetType} value="team" data-testid="admin-transfer-type-team" />
							{t('settings.admin.transfer.targetTeam')}
						</label>
					</div>
					{#if targetType === 'person'}
						<PersonPicker bind:value={personID} bind:name={personName} idLabel={t('settings.admin.transfer.personID')} />
					{:else if teams.length === 0}
						<p class="text-muted-foreground">{t('settings.admin.transfer.teamNone')}</p>
					{:else}
						<Select bind:value={teamID} aria-label={t('settings.admin.transfer.teamLabel')} data-testid="admin-transfer-team">
							<option value="">{t('settings.admin.transfer.teamLabel')}</option>
							{#each teams as tm (tm.id)}<option value={tm.id}>{tm.name}</option>{/each}
						</Select>
					{/if}
				</fieldset>
				<div class="flex flex-wrap justify-end gap-2">
					<Button variant="ghost" onclick={() => (open = false)}>{t('settings.admin.transfer.cancel')}</Button>
					<Button disabled={!ready} onclick={() => (step = 'confirm')} data-testid="admin-transfer-next">{t('settings.admin.transfer.next')}</Button>
				</div>
			{/if}
		</div>
</Dialog>
