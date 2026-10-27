<script lang="ts">
	import type { Project } from '#lib/api.js';
	import { selfAndDescendants, type ProjectNode, flatten, buildTree } from '#lib/projectTree.js';
	import { t } from '#lib/i18n/index.js';
	import { cn } from '#lib/utils.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import Self from './ProjectItem.svelte';
	import { Select } from '#lib/components/ui/select/index.js';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Folder from '@lucide/svelte/icons/folder';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';

	interface Props {
		node: ProjectNode;
		all: Project[];
		selectedID: string | null;
		depth?: number;
		onselect: (id: string) => void;
		onrename: (p: Project, name: string) => Promise<boolean>;
		onadd: (parentID: string, name: string) => Promise<boolean>;
		onmove: (p: Project, parentID: string | null) => Promise<boolean>;
		ondelete: (p: Project) => Promise<boolean>;
	}
	let { node, all, selectedID, depth = 0, onselect, onrename, onadd, onmove, ondelete }: Props = $props();

	type Mode = 'none' | 'menu' | 'rename' | 'sub' | 'move' | 'delete';
	let mode = $state<Mode>('none');
	let text = $state('');
	let collapsed = $state(false);

	const project = $derived(node.project);
	const targets = $derived.by(() => {
		const blocked = selfAndDescendants(all, project.id);
		return flatten(buildTree(all)).filter((x) => !blocked.has(x.project.id));
	});

	function open(next: Mode) {
		mode = next;
		text = next === 'rename' ? project.name : '';
	}

	async function submit(e: Event) {
		e.preventDefault();
		const name = text.trim();
		if (!name) return;
		const ok = mode === 'rename' ? await onrename(project, name) : await onadd(project.id, name);
		if (ok) mode = 'none';
	}

	async function moveTo(value: string) {
		if (await onmove(project, value === '' ? null : value)) mode = 'none';
	}
</script>

<li data-testid="project-item">
	<div
		class={cn(
			'group flex items-center gap-0.5 rounded-lg pr-1 transition-colors',
			selectedID === project.id ? 'bg-ui-accent-soft text-ui-accent-ink font-medium' : 'text-foreground/90 hover:bg-muted'
		)}
		style:padding-left="{depth * 12 + 2}px"
	>
		{#if node.children.length > 0}
			<button
				class="text-muted-foreground inline-flex size-6 shrink-0 items-center justify-center rounded"
				aria-label={collapsed ? t('projects.expand') : t('projects.collapse')}
				aria-expanded={!collapsed}
				onclick={() => (collapsed = !collapsed)}><ChevronRight class={['size-3.5 transition-transform', !collapsed && 'rotate-90']} aria-hidden="true" /></button
			>
		{:else}
			<span class="size-6 shrink-0"></span>
		{/if}
		<button class="flex min-h-9 min-w-0 flex-1 items-center gap-2 py-1 text-left text-sm" onclick={() => onselect(project.id)}>
			<Folder class="size-4 shrink-0 opacity-70" aria-hidden="true" />
			<span class="truncate">{project.name}</span>
		</button>
		<Button
			variant="ghost"
			size="icon-sm"
			aria-label={t('projects.title') + ': ' + project.name}
			aria-expanded={mode !== 'none'}
			onclick={() => open(mode === 'none' ? 'menu' : 'none')}><Ellipsis aria-hidden="true" /></Button
		>
	</div>

	{#if mode !== 'none'}
		<div class="bg-card my-1 flex flex-col gap-2 rounded-lg border p-2 shadow-card" style:margin-left="{depth * 12 + 26}px">
			{#if mode === 'menu'}
				<div class="flex flex-wrap gap-1">
					<Button size="sm" variant="outline" onclick={() => open('rename')}>{t('common.rename')}</Button>
					<Button size="sm" variant="outline" onclick={() => open('sub')}>{t('projects.addSub')}</Button>
					<Button size="sm" variant="outline" onclick={() => open('move')}>{t('common.move')}</Button>
					<Button size="sm" variant="destructive" onclick={() => open('delete')}>{t('common.delete')}</Button>
				</div>
			{:else if mode === 'rename' || mode === 'sub'}
				<form class="flex gap-1" onsubmit={submit}>
					<Input
						bind:value={text}
						aria-label={mode === 'rename' ? t('common.rename') : t('projects.subPlaceholder')}
						placeholder={mode === 'sub' ? t('projects.subPlaceholder') : ''}
					/>
					<Button type="submit" size="lg">{t('common.save')}</Button>
					<Button type="button" size="lg" variant="ghost" onclick={() => open('none')}>{t('common.cancel')}</Button>
				</form>
			{:else if mode === 'move'}
				<label class="flex items-center gap-2 text-sm">
					{t('projects.moveTo')}
					<Select
						class="flex-1"
						value={project.parentID ?? ''}
						onchange={(e) => moveTo(e.currentTarget.value)}
					>
						<option value="">{t('projects.root')}</option>
						{#each targets as target (target.project.id)}
							<option value={target.project.id}>{'  '.repeat(target.depth)}{target.project.name}</option>
						{/each}
					</Select>
				</label>
				<Button size="sm" variant="ghost" onclick={() => open('none')}>{t('common.cancel')}</Button>
			{:else if mode === 'delete'}
				<p class="text-sm">{t('projects.deleteConfirm', { name: project.name })}</p>
				<div class="flex gap-1">
					<Button size="sm" variant="destructive" onclick={() => ondelete(project)}>{t('common.delete')}</Button>
					<Button size="sm" variant="ghost" onclick={() => open('none')}>{t('common.cancel')}</Button>
				</div>
			{/if}
		</div>
	{/if}

	{#if node.children.length > 0 && !collapsed}
		<ul>
			{#each node.children as child (child.project.id)}
				<Self node={child} {all} {selectedID} depth={depth + 1} {onselect} {onrename} {onadd} {onmove} {ondelete} />
			{/each}
		</ul>
	{/if}
</li>
