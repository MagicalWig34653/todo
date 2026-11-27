<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { formatCount, formatShare, formatTokens, formatUSD, type UsageSession, type UsageSummary } from '#lib/usage.js';
	import { uniqueKeys } from '#lib/keys.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

	let { summary }: { summary: UsageSummary } = $props();

	function result(s: UsageSession): string {
		if (s.commits === undefined && s.cardUpdates === undefined) return t('usage.sessions.noResult');
		const parts: string[] = [];
		if (s.commits !== undefined) parts.push(s.commits === 1 ? t('usage.sessions.commit') : t('usage.sessions.commits', { count: s.commits }));
		if (s.cardUpdates !== undefined) parts.push(s.cardUpdates === 1 ? t('usage.sessions.card') : t('usage.sessions.cards', { count: s.cardUpdates }));
		return parts.join(' · ');
	}
	const cards = (n: number) => (n === 0 ? t('usage.projects.noCards') : n === 1 ? t('usage.projects.card') : t('usage.projects.cards', { count: n }));
</script>

{#snippet shareBar(share: number)}
	<div class="bg-muted mt-1 h-2 overflow-hidden rounded-full" aria-hidden="true">
		<div class="h-full rounded-full bg-(--cost-input)" style:width="{Math.min(100, Math.max(0, share * 100))}%"></div>
	</div>
{/snippet}

<div class="grid grid-cols-1 gap-3 lg:grid-cols-2">
	<section class="bg-card min-w-0 rounded-xl border p-4" aria-labelledby="costs-models-title">
		<h3 id="costs-models-title" class="mb-3 text-base font-semibold">{t('usage.models.title')}</h3>
		<ul class="flex flex-col gap-3">
			{#each uniqueKeys(summary.models, (m) => m.family) as { item: model, key } (key)}
				<li data-testid="costs-model" data-family={model.family}>
					<div class="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
						<span class="font-medium">{t(`usage.family.${model.family}`)}</span>
						<span data-tabular>{formatShare(model.share)} · {formatUSD(model.costUSD)}</span>
					</div>
					{@render shareBar(model.share)}
					<p class="text-muted-foreground mt-0.5 text-xs">{t('usage.tokens', { value: formatTokens(model.tokens) })}</p>
				</li>
			{/each}
		</ul>
	</section>

	<section class="bg-card min-w-0 rounded-xl border p-4" aria-labelledby="costs-projects-title">
		<h3 id="costs-projects-title" class="mb-3 text-base font-semibold">{t('usage.projects.title')}</h3>
		<ul class="flex flex-col gap-3">
			{#each uniqueKeys(summary.projects, (p) => p.projectID ?? 'none') as { item: project, key } (key)}
				<li data-testid="costs-project">
					<div class="flex items-baseline justify-between gap-3 text-sm">
						<span class="min-w-0 font-medium [overflow-wrap:anywhere]">{project.projectName ?? t('usage.projects.none')}</span>
						<span class="shrink-0" data-tabular>{formatUSD(project.costUSD)}</span>
					</div>
					{@render shareBar(project.share)}
					<p class="text-muted-foreground mt-0.5 text-xs">
						{formatShare(project.share)} · {cards(project.doneCards)}{#if project.costPerDoneCard !== undefined}
							· {t('usage.projects.perCard', { amount: formatUSD(project.costPerDoneCard) })}{/if}
					</p>
				</li>
			{/each}
		</ul>
	</section>
</div>

<section class="bg-card min-w-0 rounded-xl border p-4" aria-labelledby="costs-sessions-title">
	<h3 id="costs-sessions-title" class="mb-1 text-base font-semibold">{t('usage.sessions.title')}</h3>
	{#if summary.sessions.length === 0}
		<p class="text-muted-foreground text-sm">{t('usage.sessions.empty')}</p>
	{:else}
		<ol class="divide-border flex flex-col divide-y">
			{#each uniqueKeys(summary.sessions, (s) => s.sessionKey) as { item: session, key } (key)}
				<li class={['flex flex-col gap-1 py-3', session.idle && 'border-l-warning -ml-4 border-l-4 pl-3']} data-testid="costs-session" data-idle={session.idle}>
					<div class="flex items-start justify-between gap-3">
						<div class="min-w-0">
							<p class="text-sm font-medium [overflow-wrap:anywhere]">{session.projectName ?? t('usage.projects.none')}</p>
							<p class="text-muted-foreground font-mono text-xs [overflow-wrap:anywhere]">{session.sessionKey}</p>
						</div>
						<div class="shrink-0 text-right" data-tabular>
							<p class="text-sm font-semibold">{formatUSD(session.costUSD)}</p>
							<p class="text-muted-foreground text-xs">{formatShare(session.share)}</p>
						</div>
					</div>
					{#if session.idle || session.subagent}
						<p class="flex flex-wrap gap-1.5">
							{#if session.idle}<Badge variant="warning"><TriangleAlert aria-hidden="true" />{t('usage.sessions.idle')}</Badge>{/if}
							{#if session.subagent}<Badge variant="outline">{t('usage.sessions.subagent')}</Badge>{/if}
						</p>
					{/if}
					<p class="text-muted-foreground text-[13px] [overflow-wrap:anywhere]">
						{session.models.join(', ')} · {t('usage.sessions.context', { value: formatTokens(session.maxContextTokens) })} · {t('usage.sessions.turns', { count: formatCount(session.turns) })} · {result(session)}
					</p>
				</li>
			{/each}
		</ol>
	{/if}
</section>
