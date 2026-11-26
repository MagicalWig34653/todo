<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { hasID, toggleID, type ProjectGroup } from '#lib/projectGroups.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';

	/** The person's groups as checkboxes (ADR 0037): "new project" dialog and the project's "Projektgruppen" dialog. */
	let { groups, selected = $bindable(), disabled = false, testid }: { groups: ProjectGroup[]; selected: string[]; disabled?: boolean; testid: string } = $props();
</script>

<fieldset class="flex min-w-0 flex-col gap-1" {disabled} data-testid={testid}>
	<legend class="text-xs font-semibold">{t('projectGroups.ofProject')}</legend>
	<p class="text-muted-foreground text-xs">{groups.length ? t('projectGroups.ofProjectHint') : t('projectGroups.ofProjectNone')}</p>
	{#if groups.length}
		<div class="flex max-h-40 flex-col overflow-auto">
			{#each groups as g (g.id)}
				<label class="hover:bg-muted/50 flex min-h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-sm">
					<Checkbox checked={hasID(selected, g.id)} onchange={() => (selected = toggleID(selected, g.id))} data-testid="{testid}-group" data-name={g.name} />
					<span class="min-w-0 break-words">{g.name}</span>
				</label>
			{/each}
		</div>
	{/if}
</fieldset>
