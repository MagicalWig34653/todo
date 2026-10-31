<script lang="ts">
	import { t } from '#lib/i18n/index.js';
	import { findHelpPage, helpPath, HELP_PAGES } from '#lib/helpNav.js';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import PageHeader from './app/PageHeader.svelte';
	import AboutPage from './help/AboutPage.svelte';
	import ClaudeConnect from './help/ClaudeConnect.svelte';
	import KeysPage from './help/KeysPage.svelte';
	import ManualPage from './help/ManualPage.svelte';
	import StartPage from './help/StartPage.svelte';

	/** Help area (`/hilfe/<seite>`): landing list, same list -> detail pattern as the settings hub. */
	let { area, onarea, onsettings }: { area?: string; onarea: (a: string | undefined) => void; onsettings: () => void } = $props();
	const page = $derived(findHelpPage(area));
	const unknown = $derived(area !== undefined && !page);

	function open(e: MouseEvent, to: string | undefined) {
		if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
		e.preventDefault();
		onarea(to);
	}
	const item = 'flex min-h-10 w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-sm transition-colors hover:bg-muted aria-[current=page]:bg-ui-accent-soft aria-[current=page]:text-ui-accent-ink aria-[current=page]:font-medium';
</script>

<section class="flex flex-col gap-4" data-testid="help-hub">
	<PageHeader title={page ? t(page.label) : t('help.area')} description={page ? t(page.description) : t('help.landing.intro')} testid="view-heading" />
	<div class="grid gap-6 md:grid-cols-[15rem_minmax(0,1fr)]">
		<nav class={['flex-col gap-0.5', area !== undefined ? 'hidden md:flex' : 'flex']} aria-label={t('help.nav')} data-testid="help-nav">
			{#each HELP_PAGES as p (p.id)}
				<a class={item} href={helpPath(p.id)} aria-current={area === p.id ? 'page' : undefined} data-testid="help-link-{p.id}" onclick={(e) => open(e, p.id)}>
					<span class="flex min-w-0 flex-1 flex-col">
						<span class="truncate">{t(p.label)}</span>
						<span class="text-muted-foreground text-xs font-normal md:hidden">{t(p.description)}</span>
					</span>
					<ChevronRight class="text-muted-foreground size-4 shrink-0 md:hidden" aria-hidden="true" />
				</a>
			{/each}
		</nav>
		<div class={['flex min-w-0 flex-col gap-4', area === undefined && 'hidden md:flex']} data-testid="help-content">
			{#if area !== undefined}
				<a class="text-muted-foreground hover:text-foreground inline-flex w-fit items-center gap-1 text-sm md:hidden" href="/hilfe" onclick={(e) => open(e, undefined)}>
					<ChevronLeft class="size-4" aria-hidden="true" />{t('helpmenu.all')}
				</a>
			{/if}
			{#if unknown}
				<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" data-testid="help-notfound">{t('help.notFound')}</p>
			{:else if area === undefined}
				<ul class="grid gap-2 lg:grid-cols-2" data-testid="help-landing">
					{#each HELP_PAGES as p (p.id)}
						<li>
							<a class="bg-card hover:bg-muted flex h-full flex-col gap-0.5 rounded-xl border p-3 shadow-card transition-colors" href={helpPath(p.id)} data-testid="help-card-{p.id}" onclick={(e) => open(e, p.id)}>
								<span class="text-sm font-medium">{t(p.label)}</span>
								<span class="text-muted-foreground text-[13px]">{t(p.description)}</span>
							</a>
						</li>
					{/each}
				</ul>
			{:else if area === 'erste-schritte'}
				<StartPage {onsettings} />
			{:else if area === 'tastaturkuerzel'}
				<KeysPage />
			{:else if area === 'claude-code'}
				<ClaudeConnect />
			{:else if area === 'agentenhandbuch'}
				<ManualPage />
			{:else if area === 'ueber'}
				<AboutPage />
			{/if}
		</div>
	</div>
</section>
