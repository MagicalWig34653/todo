<script lang="ts">
	import { api, type Label, type Task } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { notice } from '#lib/notice.svelte.js';
	import { buildTree, flatten } from '#lib/projectTree.js';
	import { formatWhen } from '#lib/planning.js';
	import { parseQuickAdd, matchByName } from '#lib/quickAdd.js';
	import { createQuickTask } from '#lib/quickAddCreate.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { errorMessage } from '#lib/i18n/index.js';
	import { ApiError } from '#lib/api.js';
	import Dialog from './app/Dialog.svelte';

	/** `today`: entries without a date get today as due date (Todoist behaviour in the Today view). */
	let { currentProjectID, view }: { currentProjectID: string | null; view?: string } = $props();

	let text = $state('');
	let projectID = $state('');
	let busy = $state(false);
	let error = $state('');
	let indent = $state(false);
	let asFeature = $state(false);
	let last = $state<Task | null>(null);
	let added = $state<string[]>([]);

	const options = $derived(flatten(buildTree(workspace.projects)));
	const parsed = $derived(parseQuickAdd(text));
	const project = $derived(
		(parsed.projectToken ? matchByName(workspace.projects, (p) => p.name, parsed.projectToken) : null) ??
			workspace.projects.find((p) => p.id === projectID)
	);
	const management = $derived(workspace.modeOf(project?.id) === 'management');
	const canIndent = $derived(!!last && last.projectID === project?.id);
	const label = (l: Label[], n: string) => matchByName(l, (x) => x.name, n);

	interface Chip {
		kind: string;
		text: string;
		bad?: boolean;
	}
	const chips = $derived.by<Chip[]>(() => {
		const out: Chip[] = [];
		const p = parsed;
		if (p.due) out.push({ kind: 'due', text: `${t('planning.due')} ${formatWhen(p.due.toISOString())}` });
		else if (view === 'today') out.push({ kind: 'due', text: `${t('planning.due')} ${t('quickAdd.today')}` });
		if (p.priority !== null) out.push({ kind: 'priority', text: t(`planning.priority.${p.priority}` as MessageKey) });
		if (p.recurrence) out.push({ kind: 'recurrence', text: t(`quickAdd.rec.${p.recurrence}` as MessageKey) });
		if (p.projectToken) out.push({ kind: 'project', text: `#${project?.name ?? p.projectToken}`, bad: !matchByName(workspace.projects, (x) => x.name, p.projectToken) });
		for (const l of p.labelTokens) out.push({ kind: 'label', text: `@${label(workspace.labels, l)?.name ?? l}` });
		if (p.sectionToken) out.push({ kind: 'section', text: `/${p.sectionToken}` });
		return out;
	});

	// Each time the dialog opens: reset the session and preselect the current project (else "Eingang", else the first).
	$effect(() => {
		if (!ui.quickAdd) return;
		text = '';
		error = '';
		indent = false;
		asFeature = false;
		last = null;
		added = [];
		const inbox = workspace.projects.find((p) => p.name === 'Eingang');
		projectID = currentProjectID ?? inbox?.id ?? workspace.projects[0]?.id ?? '';
	});

	function onkeydown(e: KeyboardEvent) {
		if (e.key === 'Tab' && !e.shiftKey && !indent && canIndent && text.trim()) {
			e.preventDefault();
			indent = true;
		} else if (e.key === 'Tab' && e.shiftKey && indent) {
			e.preventDefault();
			indent = false;
		}
	}

	async function submit(e: Event) {
		e.preventDefault();
		if (busy) return;
		const p = parseQuickAdd(text);
		if (!p.title && !p.projectToken) return;
		if (!p.due && view === 'today') p.due = new Date(new Date().setHours(0, 0, 0, 0));
		busy = true;
		error = '';
		try {
			const out = await createQuickTask(api, p, {
				projects: workspace.projects,
				labels: workspace.labels,
				defaultProjectID: projectID,
				columnID: null,
				parent: indent ? last : null,
				asFeature: management && asFeature
			});
			// Success: keep the field open for the next task.
			added = [out.task.title, ...added].slice(0, 5);
			last = out.task;
			text = '';
			asFeature = false;
			ui.changeTick++;
			if (out.newLabels.length) workspace.labels = [...workspace.labels, ...out.newLabels];
			if (out.failed.length) notice.text = t('quickAdd.partial');
			void workspace.reloadTasks().catch(() => undefined);
			document.querySelector<HTMLInputElement>('[data-testid="quick-add"] input[data-autofocus]')?.focus();
		} catch (err) {
			// The text stays in the field so nothing is lost (offline, server error).
			error = err instanceof ApiError ? errorMessage(err.reason) : err instanceof Error && err.message === 'empty_title' ? t('quickAdd.emptyTitle') : t('quickAdd.offline');
		} finally {
			busy = false;
		}
	}
</script>

<Dialog bind:open={ui.quickAdd} title={t('quickAdd.title')} testid="quick-add" sheet>
	{#if workspace.projects.length === 0}
		<p class="text-muted-foreground text-sm">{t('quickAdd.noProject')}</p>
	{:else}
		<form class="flex flex-col gap-3" onsubmit={submit}>
			<Input
				data-autofocus
				bind:value={text}
				{onkeydown}
				placeholder={t('quickAdd.titlePlaceholder')}
				aria-label={t('tasks.titleLabel')}
				aria-describedby="qa-hint"
				enterkeyhint="done"
				autocomplete="off"
				autocapitalize="sentences"
				class={['h-11 text-base', indent && 'ml-6']}
			/>
			<p id="qa-hint" class="text-muted-foreground text-xs">{t('quickAdd.hint')}</p>
			<div class="flex min-h-6 flex-wrap gap-1.5" aria-live="polite" data-testid="quick-add-chips">
				{#each chips as c (c.kind + c.text)}
					<span class={['rounded-full border px-2 py-0.5 text-xs', c.bad ? 'border-warning text-warning' : 'bg-muted']} data-testid="qa-chip" data-kind={c.kind}>{c.text}</span>
				{/each}
			</div>
			{#if error}<p role="alert" class="text-destructive text-sm" data-testid="quick-add-error">{error}</p>{/if}
			<div class="flex flex-wrap items-end gap-2">
				<label class="flex min-w-0 flex-1 flex-col gap-1 text-xs font-medium">
					{t('search.project')}
					<Select bind:value={projectID}>
						{#each options as o (o.project.id)}<option value={o.project.id}>{'  '.repeat(o.depth)}{o.project.name}</option>{/each}
					</Select>
				</label>
				{#if canIndent}
					<label class="flex min-h-9 items-center gap-2 text-sm">
						<input type="checkbox" bind:checked={indent} data-testid="qa-subtask" />
						{t('quickAdd.subtaskOf', { title: last?.title ?? '' })}
					</label>
				{/if}
				{#if management}
					<label class="flex min-h-9 items-center gap-2 text-sm"><input type="checkbox" bind:checked={asFeature} data-testid="qa-feature" />{t('quickAdd.feature')}</label>
				{/if}
			</div>
			{#if added.length}
				<ul class="text-muted-foreground flex flex-col gap-0.5 text-xs" aria-label={t('quickAdd.added')} data-testid="quick-add-added">
					{#each added as a, i (i)}<li class="truncate">✓ {a}</li>{/each}
				</ul>
			{/if}
			<div class="flex justify-end gap-2">
				<Button type="button" variant="ghost" onclick={() => (ui.quickAdd = false)}>{t('quickAdd.done')}</Button>
				<Button type="submit" disabled={!text.trim() || busy}>{t('quickAdd.submit')}</Button>
			</div>
		</form>
	{/if}
</Dialog>
