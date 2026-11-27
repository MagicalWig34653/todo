<script lang="ts">
	import { api } from '#lib/api.js';
	import { t } from '#lib/i18n/index.js';
	import {
		OPEN_FOLDER_LIMIT,
		SYNC_STATUSES,
		buildManifest,
		buildTree,
		countKey,
		deployErrorText,
		statusKey,
		summaryOf,
		type DeployCompareResult,
		type DeployTarget,
		type SyncStatus,
		type TreeDir
	} from '#lib/deploy.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import ArrowLeft from '@lucide/svelte/icons/arrow-left';
	import Eye from '@lucide/svelte/icons/eye';
	import FileIcon from '@lucide/svelte/icons/file';
	import Folder from '@lucide/svelte/icons/folder';
	import FolderOpen from '@lucide/svelte/icons/folder-open';

	/**
	 * Read-only sync view of one deploy target (card 354ADE12, phase 1b, concept 8.2): the person picks the local repo folder, the
	 * browser hashes the files (only path, size and SHA-256 leave the browser), the server lists the target and compares. Shown as a
	 * file tree with a status per file, like "Sync with Deployed" in PhpStorm, but without any action on the server.
	 */
	let { target, onback }: { target: DeployTarget; onback: () => void } = $props();

	let phase = $state<'idle' | 'hashing' | 'comparing' | 'done' | 'error'>('idle');
	let progress = $state({ done: 0, total: 0 });
	let error = $state('');
	let result = $state<DeployCompareResult | null>(null);
	let onlyDiff = $state(false);
	/** Picked files for "compare again"; raw so the File objects are never proxied. */
	let lastFiles = $state.raw<File[]>([]);

	const tree = $derived<TreeDir | null>(result?.files ? buildTree(result.files, onlyDiff) : null);
	const counts = $derived(result ? summaryOf(result) : null);

	async function pick(e: Event & { currentTarget: HTMLInputElement }) {
		lastFiles = Array.from(e.currentTarget.files ?? []);
		e.currentTarget.value = '';
		await run();
	}

	async function run() {
		if (phase === 'hashing' || phase === 'comparing') return;
		error = '';
		result = null;
		if (lastFiles.length === 0) {
			phase = 'error';
			error = t('deploy.sync.emptyFolder');
			return;
		}
		phase = 'hashing';
		progress = { done: 0, total: lastFiles.length };
		let manifest: Awaited<ReturnType<typeof buildManifest>>;
		try {
			manifest = await buildManifest(
				lastFiles.map((f) => ({ relativePath: f.webkitRelativePath || f.name, size: f.size, bytes: () => f.arrayBuffer() })),
				(done, total) => (progress = { done, total })
			);
		} catch {
			// The browser refuses to read a file that changed after the folder was picked (NotReadableError).
			phase = 'error';
			error = t('deploy.sync.unreadable');
			return;
		}
		if (manifest === 'tooMany' || manifest === 'empty') {
			phase = 'error';
			error = t(manifest === 'tooMany' ? 'deploy.sync.tooMany' : 'deploy.sync.emptyFolder');
			return;
		}
		phase = 'comparing';
		try {
			const r = await api.compareDeployTarget(target.id, manifest);
			if (!r.ok) {
				phase = 'error';
				error = deployErrorText(r.code ?? 'deploy_failed');
				return;
			}
			result = r;
			phase = 'done';
		} catch (err) {
			phase = 'error';
			error = deployErrorText(err);
		}
	}

	const tone: Record<SyncStatus, string> = {
		same: 'text-muted-foreground',
		new: 'text-success',
		changed: 'text-warning',
		serverOnly: 'text-destructive',
		unverified: 'text-muted-foreground italic'
	};
	const chip: Record<SyncStatus, string> = {
		same: 'bg-muted text-muted-foreground',
		new: 'bg-success-soft text-success',
		changed: 'bg-warning-soft text-warning',
		serverOnly: 'bg-destructive/10 text-destructive',
		unverified: 'bg-muted text-muted-foreground'
	};
	const sizes = (repo?: number, server?: number) =>
		[repo !== undefined ? `${t('deploy.sync.repo')} ${t('deploy.sync.bytes', { n: repo })}` : '', server !== undefined ? `${t('deploy.sync.server')} ${t('deploy.sync.bytes', { n: server })}` : '']
			.filter(Boolean)
			.join(' · ');
	const busy = $derived(phase === 'hashing' || phase === 'comparing');
</script>

{#snippet dirNode(dir: TreeDir, depth: number)}
	<ul class={depth === 0 ? 'flex flex-col' : 'flex flex-col border-l pl-3'} aria-label={depth === 0 ? t('deploy.sync.tree') : undefined}>
		{#each dir.children as node (`${node.kind}:${node.path}`)}
			{#if node.kind === 'dir'}
				<li data-testid="deploy-sync-dir" data-path={node.path}>
					<details open={node.total <= OPEN_FOLDER_LIMIT} class="group">
						<summary class="hover:bg-muted flex min-h-8 cursor-pointer list-none items-center gap-1.5 rounded-md px-1.5 text-sm font-medium">
							<Folder class="text-muted-foreground size-4 shrink-0 group-open:hidden" aria-hidden="true" />
							<FolderOpen class="text-muted-foreground hidden size-4 shrink-0 group-open:block" aria-hidden="true" />
							<span class="min-w-0 [overflow-wrap:anywhere]">{node.name}</span>
							<span class="ml-auto flex shrink-0 gap-1">
								{#each SYNC_STATUSES as s (s)}
									{#if s !== 'same' && node.counts[s]}<span class={['rounded-full px-1.5 text-[11px] font-semibold', chip[s]]} title={t(statusKey(s))} data-tabular>{node.counts[s]}</span>{/if}
								{/each}
							</span>
						</summary>
						{@render dirNode(node, depth + 1)}
					</details>
				</li>
			{:else}
				<li class="flex min-h-8 min-w-0 flex-wrap items-center gap-x-1.5 rounded-md px-1.5 py-1 text-sm" data-testid="deploy-sync-file" data-status={node.status} data-path={node.path}>
					<FileIcon class={['size-4 shrink-0', tone[node.status]]} aria-hidden="true" />
					<span class={['min-w-0 [overflow-wrap:anywhere]', node.status === 'same' ? 'text-muted-foreground' : 'font-medium']}>{node.name}</span>
					<span class={['rounded-full px-2 py-0.5 text-[11px] font-semibold', chip[node.status]]}>{t(statusKey(node.status))}</span>
					{#if node.status !== 'same'}<span class="text-muted-foreground ml-auto text-xs" data-tabular>{sizes(node.repoSize, node.serverSize)}</span>{/if}
				</li>
			{/if}
		{/each}
	</ul>
{/snippet}

<section class="flex min-w-0 flex-col gap-4" data-testid="deploy-sync-view" aria-labelledby="deploy-sync-h">
	<div class="flex min-w-0 flex-wrap items-center gap-2">
		<Button size="sm" variant="ghost" onclick={onback}><ArrowLeft aria-hidden="true" />{t('deploy.sync.back')}</Button>
	</div>
	<h3 class="font-semibold [overflow-wrap:anywhere]" id="deploy-sync-h">{t('deploy.sync.title', { name: target.name })}</h3>
	<p class="bg-muted/60 flex items-start gap-2 rounded-xl border p-3 text-sm" data-testid="deploy-sync-readonly">
		<Eye class="text-muted-foreground mt-0.5 size-4 shrink-0" aria-hidden="true" />{t('deploy.sync.readonly')}
	</p>

	<div class="flex min-w-0 flex-col gap-2">
		<div class="flex flex-wrap items-center gap-2">
			<label
				class={[
					'bg-ui-accent text-ui-accent-foreground hover:bg-ui-accent/90 focus-within:ring-ring/40 inline-flex h-9 cursor-pointer items-center rounded-lg px-3.5 text-sm font-medium focus-within:ring-2 max-sm:w-full max-sm:justify-center',
					busy && 'pointer-events-none opacity-60'
				]}
			>
				{t('deploy.sync.pick')}
				<input type="file" class="sr-only" webkitdirectory multiple disabled={busy} data-testid="deploy-sync-folder" onchange={pick} />
			</label>
			{#if result && lastFiles.length}
				<Button variant="outline" class="max-sm:w-full" disabled={busy} onclick={() => void run()}>{t('deploy.sync.again')}</Button>
			{/if}
		</div>
		<p class="text-muted-foreground text-xs">{t('deploy.sync.pickHint')}</p>
	</div>

	<p role="status" aria-live="polite" class="text-sm empty:hidden" data-tabular>
		{phase === 'hashing' ? t('deploy.sync.hashing', { done: progress.done, total: progress.total }) : phase === 'comparing' ? t('deploy.sync.comparing') : ''}
	</p>
	{#if phase === 'error'}<p class="text-destructive text-sm font-medium" role="alert" data-testid="deploy-sync-error">{error}</p>{/if}

	{#if result && counts && tree}
		<div class="flex min-w-0 flex-col gap-2" data-testid="deploy-sync-summary">
			<h4 class="text-muted-foreground text-xs font-semibold tracking-wide uppercase">{t('deploy.sync.summary')}</h4>
			<ul class="flex flex-wrap gap-1.5">
				{#each SYNC_STATUSES as s (s)}
					{#if counts[s] > 0 || s !== 'unverified'}
						<li class={['rounded-full px-2.5 py-1 text-xs font-semibold', chip[s]]} title={t(`deploy.sync.legend.${s}`)} data-testid="deploy-sync-count-{s}" data-tabular>{t(countKey(s), { n: counts[s] })}</li>
					{/if}
				{/each}
			</ul>
			<label class="flex min-h-9 w-fit cursor-pointer items-center gap-2 text-sm">
				<Checkbox bind:checked={onlyDiff} data-testid="deploy-sync-only-diff" />{t('deploy.sync.onlyDiff')}
			</label>
		</div>
		<div class="min-w-0 rounded-xl border p-2">
			{#if tree.children.length === 0}
				<p class="text-muted-foreground p-2 text-sm">{t('deploy.sync.noDiff')}</p>
			{:else}
				{@render dirNode(tree, 0)}
			{/if}
		</div>
	{/if}
</section>
