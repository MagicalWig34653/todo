<script lang="ts">
	import { untrack } from 'svelte';
	import { api, ApiError, type BoardColumn } from '#lib/api.js';
	import { attachFile } from '#lib/attachFile.js';
	import { checkFile, formatSize } from '#lib/attachments.js';
	import { cardDetail } from '#lib/cardDetail.svelte.js';
	import { createDraftTask, type CardDraft } from '#lib/cardDraft.js';
	import { errorMessage, t, type MessageKey } from '#lib/i18n/index.js';
	import { notice } from '#lib/notice.svelte.js';
	import { PRIORITIES } from '#lib/planning.js';
	import { buildTree, flatten } from '#lib/projectTree.js';
	import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import Paperclip from '@lucide/svelte/icons/paperclip';
	import X from '@lucide/svelte/icons/x';
	import CardHeader from './CardHeader.svelte';
	import Markdown from './Markdown.svelte';
	import SideSection from './SideSection.svelte';

	/**
	 * The large card window as a draft (card A42C423B): the same layout as a stored card (main column, properties on the
	 * right), but nothing is sent before "Anlegen". Then the task, its planning, labels and files are stored and the window
	 * shows the stored card; "Abbrechen" (or Escape, the close button) drops the draft without a trace.
	 */
	let { currentProjectID }: { currentProjectID: string | null } = $props();

	const options = $derived(flatten(buildTree(workspace.projects)));
	// Preselected once per draft: the open project, else "Eingang", else the first. Live refresh must not reset the choice.
	const initialProject = untrack(
		() => currentProjectID ?? workspace.projects.find((p) => p.name === 'Eingang')?.id ?? workspace.projects[0]?.id ?? ''
	);
	let draft = $state<CardDraft>({ title: '', description: '', projectID: initialProject, columnID: null, priority: 0, due: '', labelIDs: [], files: [] });
	let preview = $state(false);
	let busy = $state(false);
	let error = $state('');
	let fileProblem = $state('');
	let columns = $state<BoardColumn[]>([]);
	let fileInput = $state<HTMLInputElement | null>(null);

	// Columns of the chosen project; the first real column is preselected (a project without own columns has none).
	$effect(() => {
		const projectID = draft.projectID;
		columns = [];
		draft.columnID = null;
		if (!projectID) return;
		let stale = false;
		api.projectBoard(projectID).then(
			(board) => {
				if (stale) return;
				columns = board.mode === 'columns' ? board.columns.filter((c) => c.id) : [];
				draft.columnID = columns[0]?.id ?? null;
			},
			() => undefined
		);
		return () => {
			stale = true;
		};
	});

	function addFiles(e: Event) {
		const input = e.currentTarget as HTMLInputElement;
		fileProblem = '';
		for (const file of Array.from(input.files ?? [])) {
			const problem = checkFile(file);
			if (problem) fileProblem = t(`attachments.problem.${problem}` as MessageKey);
			else draft.files = [...draft.files, file];
		}
		input.value = '';
	}

	async function create(e: Event) {
		e.preventDefault();
		if (busy) return;
		if (!draft.title.trim()) {
			error = t('quickAdd.emptyTitle');
			return;
		}
		busy = true;
		error = '';
		try {
			const out = await createDraftTask(api, draft, (taskID, file) => attachFile(taskID, file));
			ui.changeTick++;
			void workspace.reloadTasks().catch(() => undefined);
			cardDetail.created(out.task.id);
			if (out.failed.length) notice.text = t('draft.partial');
		} catch (err) {
			// Nothing stored: every input stays so the user can try again.
			error = err instanceof ApiError ? errorMessage(err.reason) : t('draft.failed');
		} finally {
			busy = false;
		}
	}

	const tabClass = (active: boolean) =>
		['rounded-md px-2 py-1 text-xs font-medium', active ? 'bg-background text-foreground shadow-xs' : 'text-muted-foreground hover:text-foreground'];
</script>

<form class="flex min-h-0 min-w-0 flex-1 flex-col text-sm" data-testid="card-draft" onsubmit={create}>
	<CardHeader projectID={draft.projectID || null} />
	<div class="min-h-0 flex-1 overflow-y-auto overscroll-contain md:grid md:grid-cols-[minmax(0,1fr)_minmax(260px,300px)] md:overflow-hidden lg:grid-cols-[minmax(0,1fr)_320px]">
		<!-- Main column: title, description, attachments -->
		<div class="flex min-w-0 flex-col gap-5 px-4 py-5 md:overflow-y-auto md:overscroll-contain md:px-8 md:py-6">
			<Input
				data-autofocus
				bind:value={draft.title}
				aria-label={t('tasks.titleLabel')}
				placeholder={t('draft.titlePlaceholder')}
				autocomplete="off"
				autocapitalize="sentences"
				class="h-auto border-transparent bg-transparent px-0 py-1 text-2xl font-semibold tracking-tight shadow-none focus-visible:ring-0 md:text-[1.7rem]"
			/>

			<section class="flex flex-col gap-2">
				<div class="flex items-center justify-between gap-2">
					<h3 class="text-muted-foreground text-sm font-semibold" id="draft-description-label">{t('card.description')}</h3>
					<div class="bg-muted flex gap-0.5 rounded-lg p-0.5" role="group" aria-label={t('card.description')}>
						<button type="button" class={tabClass(!preview)} aria-pressed={!preview} onclick={() => (preview = false)}>{t('draft.write')}</button>
						<button type="button" class={tabClass(preview)} aria-pressed={preview} data-testid="draft-preview" onclick={() => (preview = true)}>{t('draft.preview')}</button>
					</div>
				</div>
				{#if preview}
					<div class="min-h-40 rounded-lg border px-3 py-2">
						{#if draft.description.trim()}<Markdown text={draft.description} />{:else}<p class="text-muted-foreground">{t('draft.previewEmpty')}</p>{/if}
					</div>
				{:else}
					<Textarea bind:value={draft.description} aria-labelledby="draft-description-label" placeholder={t('draft.descriptionPlaceholder')} class="min-h-40 text-sm leading-relaxed" />
				{/if}
			</section>

			<section class="flex flex-col gap-2" aria-label={t('card.side.attachments')}>
				<div class="flex items-center justify-between gap-2">
					<h3 class="text-muted-foreground text-sm font-semibold">{t('card.side.attachments')}</h3>
					<Button type="button" variant="outline" size="sm" onclick={() => fileInput?.click()}>
						<Paperclip class="size-4" aria-hidden="true" />{t('draft.addFiles')}
					</Button>
					<input
						bind:this={fileInput}
						type="file"
						multiple
						class="sr-only"
						tabindex="-1"
						aria-hidden="true"
						accept="image/png,image/jpeg,image/webp,application/pdf"
						data-testid="draft-files"
						onchange={addFiles}
					/>
				</div>
				{#if draft.files.length}
					<ul class="flex flex-col gap-1">
						{#each draft.files as file, i (i)}
							<li class="bg-muted/60 flex min-h-9 items-center justify-between gap-2 rounded-lg px-3" data-testid="draft-file">
								<span class="min-w-0 truncate">{file.name} <span class="text-muted-foreground">· {formatSize(file.size)}</span></span>
								<button
									type="button"
									class="text-muted-foreground hover:text-foreground hit-area relative inline-flex size-7 shrink-0 items-center justify-center rounded-md"
									aria-label={t('draft.removeFile', { name: file.name })}
									onclick={() => (draft.files = draft.files.filter((_, j) => j !== i))}
								>
									<X class="size-4" aria-hidden="true" />
								</button>
							</li>
						{/each}
					</ul>
				{:else}
					<p class="text-muted-foreground text-xs">{t('attachments.hint')}</p>
				{/if}
				{#if fileProblem}<p role="alert" class="text-destructive text-xs">{fileProblem}</p>{/if}
			</section>
		</div>

		<!-- Properties, as in the stored card -->
		<aside class="bg-muted/50 flex min-w-0 flex-col border-t px-4 py-2 md:overflow-y-auto md:overscroll-contain md:border-t-0 md:border-l md:px-5" aria-label={t('card.sidebar')}>
			<SideSection title={t('card.side.project')}>
				<Select class="w-full" bind:value={draft.projectID} aria-label={t('card.side.project')}>
					{#each options as o (o.project.id)}<option value={o.project.id}>{'  '.repeat(o.depth)}{o.project.name}</option>{/each}
				</Select>
			</SideSection>
			{#if columns.length}
				<SideSection title={t('draft.column')}>
					<Select class="w-full" bind:value={draft.columnID} aria-label={t('draft.column')}>
						{#each columns as c (c.id)}<option value={c.id}>{c.name}</option>{/each}
					</Select>
				</SideSection>
			{/if}
			<SideSection title={t('planning.priority')}>
				<Select class="w-full" bind:value={draft.priority} aria-label={t('planning.priority')}>
					{#each PRIORITIES as p (p)}<option value={p}>{t(`planning.priority.${p}` as MessageKey)}</option>{/each}
				</Select>
			</SideSection>
			<SideSection title={t('draft.due')}>
				<Input type="date" bind:value={draft.due} aria-label={t('draft.due')} />
			</SideSection>
			<SideSection title={t('card.side.labels')}>
				{#if workspace.labels.length}
					<div class="flex flex-wrap gap-1.5">
						{#each workspace.labels as l (l.id)}
							<label class="has-checked:border-ui-accent has-checked:bg-ui-accent-soft has-checked:text-ui-accent-ink bg-background inline-flex min-h-8 items-center gap-1.5 rounded-full border px-2.5 text-xs font-medium">
								<input type="checkbox" class="accent-ui-accent" value={l.id} bind:group={draft.labelIDs} />{l.name}
							</label>
						{/each}
					</div>
				{:else}
					<p class="text-muted-foreground text-xs">{t('draft.noLabels')}</p>
				{/if}
			</SideSection>
		</aside>
	</div>
	<footer class="flex shrink-0 flex-wrap items-center justify-end gap-2 border-t px-4 py-3 md:px-5">
		{#if error}<p role="alert" class="text-destructive mr-auto text-sm" data-testid="draft-error">{error}</p>{/if}
		<Button type="button" variant="ghost" onclick={() => cardDetail.close()}>{t('common.cancel')}</Button>
		<Button type="submit" disabled={busy} data-testid="draft-create">{busy ? t('draft.creating') : t('draft.create')}</Button>
	</footer>
</form>
