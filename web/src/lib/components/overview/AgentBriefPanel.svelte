<script lang="ts">
	import { onMount } from 'svelte';
	import { api, ApiError, type ProjectStructure } from '#lib/api.js';
	import { BRIEF_MAX, BRIEF_TEMPLATE } from '#lib/commandCenter.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt, notice } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import Panel from '../app/Panel.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';

	/** Agent brief (Markdown rules for agents of this project) and the standard agent workflow columns. */
	interface Props {
		projectID: string;
		/** Called after the columns were created so boards and the overview reload. */
		onchanged?: () => void | Promise<void>;
	}
	let { projectID, onchanged }: Props = $props();

	let structure = $state<ProjectStructure | null>(null);
	let draft = $state('');
	let version = $state(0);
	let savedText = $state('');
	let message = $state('');
	let busy = $state(false);

	const dirty = $derived(draft !== savedText);
	const columnsOwn = $derived(structure?.columnMode === 'columns');

	async function load(keepDraft = false) {
		const s = await api.projectStructure(projectID);
		structure = s;
		version = s.brief.version;
		savedText = s.brief.text;
		if (!keepDraft || draft === '') draft = s.brief.text;
	}

	onMount(() => {
		attempt(() => load());
	});

	async function save() {
		busy = true;
		message = '';
		try {
			const saved = await api.putAgentBrief(projectID, draft, version);
			version = saved.version;
			savedText = saved.text;
			draft = saved.text;
			message = t('cc.brief.saved', { version: saved.version });
			notice.clear();
		} catch (e) {
			if (e instanceof ApiError && e.isConflict) {
				// Keep the user's text, adopt the server revision so a second save can overwrite knowingly.
				await load(true).catch(() => undefined);
				notice.text = t('cc.brief.conflict');
				notice.conflict = true;
			} else {
				await attempt(async () => {
					throw e;
				});
			}
		} finally {
			busy = false;
		}
	}

	async function createColumns() {
		busy = true;
		const ok = await attempt(async () => {
			await api.applyColumnTemplate(projectID, 'agent_workflow');
			await load(true);
			await onchanged?.();
		});
		busy = false;
		if (ok) message = t('cc.columns.done');
	}
</script>

<div class="flex flex-col gap-4" data-testid="brief-panel">
	<Panel title={t('cc.brief.title')} description={t('cc.brief.hint')}>
		<Textarea
			bind:value={draft}
			rows={10}
			maxlength={BRIEF_MAX}
			class="font-mono text-[13px]"
			aria-label={t('cc.brief.label')}
			data-testid="brief-text"
		/>
		<div class="flex flex-wrap items-center justify-between gap-2">
			<span class="text-muted-foreground text-xs" data-tabular>{t('cc.brief.count', { count: draft.length, max: BRIEF_MAX })}</span>
			<div class="flex flex-wrap gap-2">
				{#if draft.trim() === ''}
					<Button variant="ghost" size="sm" onclick={() => (draft = BRIEF_TEMPLATE)}>{t('cc.brief.insertTemplate')}</Button>
				{/if}
				<Button size="sm" disabled={busy || !dirty} data-testid="brief-save" onclick={save}>{t('cc.brief.save')}</Button>
			</div>
		</div>
		{#if message}<p class="text-success text-sm" role="status" data-testid="brief-status">{message}</p>{/if}
	</Panel>

	<Panel title={t('cc.columns.title')} description={t('cc.columns.hint')}>
		{#if structure?.template.complete}
			<p class="text-success text-sm" data-testid="columns-complete">{t('cc.columns.complete')}</p>
		{:else if structure}
			<p class="text-sm" data-testid="columns-missing">
				{t('cc.columns.missing', { roles: structure.template.missingRoles.map((r) => t(`cc.role.${r}` as MessageKey)).join(', ') })}
			</p>
		{/if}
		{#if columnsOwn && !structure?.template.complete}<p class="text-muted-foreground text-sm">{t('cc.columns.own')}</p>{/if}
		<div>
			<Button variant="outline" size="sm" disabled={busy || columnsOwn || !structure} data-testid="columns-create" onclick={createColumns}>
				{t('cc.columns.create')}
			</Button>
		</div>
	</Panel>
</div>
