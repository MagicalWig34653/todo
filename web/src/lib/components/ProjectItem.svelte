<script lang="ts">
	import type { Project } from '#lib/api.js';
	import { selfAndDescendants, type ProjectNode, flatten, buildTree, planDrop, planStep, type DropPlan, type DropZone } from '#lib/projectTree.js';
		import { ui } from '#lib/ui.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { cn } from '#lib/utils.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import Popover from './app/Popover.svelte';
	import MenuItem from './app/MenuItem.svelte';
	import Self from './ProjectItem.svelte';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import Star from '@lucide/svelte/icons/star';

	interface Props {
		node: ProjectNode;
		all: Project[];
		selectedID: string | null;
		depth?: number;
		/** Favorites list renders flat rows without children. */
		flat?: boolean;
		onselect: (id: string) => void;
		onrename: (p: Project, name: string) => Promise<boolean>;
		onadd: (parentID: string, name: string) => Promise<boolean>;
		onmove: (p: Project, parentID: string | null) => Promise<boolean>;
		ondelete: (p: Project) => Promise<boolean>;
		onshare: (p: Project) => void;
		onfavorite: (p: Project) => void;
		/** Persist a new place among the siblings (own order) or under another parent (shared tree). */
		onreorder: (p: Project, plan: DropPlan) => Promise<boolean>;
	}
	let { node, all, selectedID, depth = 0, flat = false, onselect, onrename, onadd, onmove, ondelete, onshare, onfavorite, onreorder }: Props = $props();

	type Mode = 'none' | 'rename' | 'sub' | 'move' | 'delete';
	let mode = $state<Mode>('none');
	let text = $state('');
	let menuOpen = $state(false);

	const project = $derived(node.project);
	const collapsed = $derived(!!workspace.collapsed[project.id]);
	const count = $derived(workspace.counts.get(project.id) ?? 0);
	const fav = $derived(!!project.isFavorite);
	const up = $derived(planStep(all, project.id, -1));
	const down = $derived(planStep(all, project.id, 1));
	let zone = $state<DropZone | null>(null);
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

	/** Row thirds: top = before, bottom = after, middle = as child. */
	function zoneAt(e: DragEvent): DropZone {
		const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
		const y = (e.clientY - r.top) / r.height;
		return y < 0.3 ? 'before' : y > 0.7 ? 'after' : 'into';
	}
	function dragover(e: DragEvent) {
		const id = ui.dragProjectID;
		if (flat || !id) return;
		const z = zoneAt(e);
		if (!planDrop(all, id, project.id, z)) {
			zone = null;
			return;
		}
		e.preventDefault();
		if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
		zone = z;
	}
	async function drop(e: DragEvent) {
		const id = ui.dragProjectID;
		const z = zone ?? zoneAt(e);
		zone = null;
		ui.dragProjectID = null;
		if (flat || !id) return;
		const plan = planDrop(all, id, project.id, z);
		const dragged = all.find((p) => p.id === id);
		if (!plan || !dragged) return;
		e.preventDefault();
		if (z === 'into' && workspace.collapsed[project.id]) workspace.toggleCollapsed(project.id);
		await onreorder(dragged, plan);
	}

	async function moveTo(value: string) {
		if (await onmove(project, value === '' ? null : value)) mode = 'none';
	}
</script>

<li data-testid="project-item">
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div
		class={cn(
			'group relative flex items-center gap-0.5 rounded-lg pr-1 transition-colors',
			selectedID === project.id ? 'bg-ui-accent-soft text-ui-accent-ink glow-accent font-medium' : 'text-foreground/90 hover:bg-muted',
			zone === 'before' && 'before:bg-ui-accent before:absolute before:inset-x-1 before:-top-px before:h-0.5 before:rounded',
			zone === 'after' && 'after:bg-ui-accent after:absolute after:inset-x-1 after:-bottom-px after:h-0.5 after:rounded',
			zone === 'into' && 'ring-ui-accent ring-2 ring-inset',
			ui.dragProjectID === project.id && 'opacity-50'
		)}
		draggable={flat ? undefined : 'true'}
		data-drop-zone={zone ?? undefined}
		ondragstart={(e) => {
			ui.dragProjectID = project.id;
			e.dataTransfer?.setData('text/plain', project.id);
			if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
		}}
		ondragend={() => {
			ui.dragProjectID = null;
			zone = null;
		}}
		ondragover={dragover}
		ondragleave={(e) => {
			if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node | null)) zone = null;
		}}
		ondrop={drop}
		style:padding-left="{depth * 14 + 2}px"
	>
		{#if !flat && node.children.length > 0}
			<button
				class="text-muted-foreground inline-flex size-6 shrink-0 items-center justify-center rounded"
				aria-label={collapsed ? t('projects.expand') : t('projects.collapse')}
				aria-expanded={!collapsed}
				onclick={() => workspace.toggleCollapsed(project.id)}
				><ChevronRight class={['size-3.5 transition-transform', !collapsed && 'rotate-90']} aria-hidden="true" /></button
			>
		{:else}
			<span class="size-6 shrink-0"></span>
		{/if}
		<button class="flex min-h-9 min-w-0 flex-1 items-center gap-2 py-1 text-left text-sm" aria-current={selectedID === project.id ? 'page' : undefined} onclick={() => onselect(project.id)}>
			<span class="w-3.5 shrink-0 text-center text-[17px] leading-none font-semibold" style:color={workspace.colorOf(project.id)} aria-hidden="true">#</span>
			<span class="truncate">{project.name}</span>
		</button>
		{#if count > 0}<span class="text-muted-foreground group-hover:hidden group-focus-within:hidden pr-1.5 text-xs" data-tabular data-testid="project-count">{count}</span>{/if}
		<Popover
			label={t('projects.menu', { name: project.name })}
			align="end"
			bind:open={menuOpen}
			class="text-muted-foreground hover:bg-background/70 hidden size-7 shrink-0 items-center justify-center rounded-md [@media(hover:none)]:inline-flex group-hover:inline-flex group-focus-within:inline-flex aria-expanded:inline-flex"
		>
			{#snippet trigger()}<Ellipsis class="size-4" aria-hidden="true" />{/snippet}
			{#snippet children(close)}
				<MenuItem onclick={() => { onfavorite(project); close(); }}>
					<Star class="size-4" aria-hidden="true" />{fav ? t('projects.unfavorite') : t('projects.favorite')}
				</MenuItem>
				<MenuItem onclick={() => { open('rename'); close(); }}>{t('common.rename')}</MenuItem>
				<MenuItem onclick={() => { open('sub'); close(); }}>{t('projects.addSub')}</MenuItem>
				<MenuItem disabled={!up} testid="project-move-up" onclick={() => { if (up) onreorder(project, up); close(); }}>{t('projects.moveUp')}</MenuItem>
				<MenuItem disabled={!down} testid="project-move-down" onclick={() => { if (down) onreorder(project, down); close(); }}>{t('projects.moveDown')}</MenuItem>
				<MenuItem testid="project-move-to" onclick={() => { open('move'); close(); }}>{t('projects.moveToMenu')}</MenuItem>
				<MenuItem onclick={() => { onshare(project); close(); }}>{t('project.share')}</MenuItem>
				<MenuItem danger onclick={() => { open('delete'); close(); }}>{t('common.delete')}</MenuItem>
			{/snippet}
		</Popover>
	</div>

	{#if mode !== 'none'}
		<div class="bg-card my-1 flex flex-col gap-2 rounded-lg border p-2 shadow-card" style:margin-left="{depth * 14 + 26}px">
			{#if mode === 'rename' || mode === 'sub'}
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
					<Select class="flex-1" value={project.parentID ?? ''} onchange={(e) => moveTo(e.currentTarget.value)}>
						<option value="">{t('projects.root')}</option>
						{#each targets as target (target.project.id)}
							<option value={target.project.id}>{'  '.repeat(target.depth)}{target.project.name}</option>
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

	{#if !flat && node.children.length > 0 && !collapsed}
		<ul>
			{#each node.children as child (child.project.id)}
				<Self node={child} {all} {selectedID} depth={depth + 1} {onselect} {onrename} {onadd} {onmove} {ondelete} {onshare} {onfavorite} {onreorder} />
			{/each}
		</ul>
	{/if}
</li>
