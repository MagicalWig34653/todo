<script lang="ts">
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { findEntry, normalizeArea, searchSettings, SERVER_CATEGORY_BY_ENTRY, visibleGroups, settingsPath } from '#lib/settingsNav.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import PageHeader from './app/PageHeader.svelte';
	import AppearanceSettings from './AppearanceSettings.svelte';
	import EmailSettings from './EmailSettings.svelte';
	import NotificationSettings from './NotificationSettings.svelte';
	import AccessOverview from './AccessOverview.svelte';
	import ProfilePage from './settings/ProfilePage.svelte';
	import PasskeysPage from './settings/PasskeysPage.svelte';
	import SessionsPage from './settings/SessionsPage.svelte';
	import RecoveryPage from './settings/RecoveryPage.svelte';
	import ConnectionsPage from './settings/ConnectionsPage.svelte';
	import RunnerPage from './settings/RunnerPage.svelte';
	import DataPage from './settings/DataPage.svelte';
	import AdminAccounts from './settings/AdminAccounts.svelte';
	import AdminInvitations from './settings/AdminInvitations.svelte';
	import AdminInfo from './settings/AdminInfo.svelte';
	import ServerOverview from './settings/ServerOverview.svelte';
	import ServerSettingsPage from './settings/ServerSettingsPage.svelte';
	import ClaudeConnect from './help/ClaudeConnect.svelte';

	/**
	 * Settings hub. `area` is the URL segment (`/einstellungen/<area>`). Wide screens: group list on the left, page on the
	 * right (landing page = all entries with description). Phones: the list is its own screen, an entry opens the page.
	 * New pages hook in here: add the entry to lib/settingsNav.ts and one `{:else if}` branch below.
	 */
	let { area, onarea, onnav }: { area?: string; onarea: (a: string | undefined) => void; onnav: (target: 'teams' | 'agents' | 'general' | 'project', projectID?: string) => void } = $props();

	const isAdmin = $derived(!!auth.user?.isAdmin);
	const groups = $derived(visibleGroups(isAdmin));
	const id = $derived(normalizeArea(area));
	const entry = $derived(findEntry(id));
	const denied = $derived(!!entry?.adminOnly && !isAdmin);
	const unknown = $derived(id !== undefined && !entry);
	let query = $state('');
	const found = $derived(searchSettings(groups, query, t));

	function open(e: MouseEvent, to: string | undefined) {
		if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
		e.preventDefault();
		query = '';
		onarea(to);
	}
	const item = 'flex min-h-10 w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-sm transition-colors hover:bg-muted aria-[current=page]:bg-ui-accent-soft aria-[current=page]:text-ui-accent-ink aria-[current=page]:font-medium';
</script>

<section class="flex flex-col gap-4" data-testid="settings-hub">
	<PageHeader
		title={entry && !denied ? t(entry.label) : t('settings.title')}
		description={entry && !denied ? t(entry.description) : t('settings.landing.intro')}
		testid="view-heading"
	/>

	<div class="grid gap-6 md:grid-cols-[15rem_minmax(0,1fr)]">
		<nav class={['flex-col gap-3 md:sticky md:top-16 md:max-h-[calc(100dvh-5rem)] md:self-start md:overflow-y-auto', id !== undefined ? 'hidden md:flex' : 'flex']} aria-label={t('settings.nav')} data-testid="settings-nav">
			<Input type="search" bind:value={query} placeholder={t('settings.search')} aria-label={t('settings.search')} data-testid="settings-search" />
			{#if query.trim()}
				<ul class="flex flex-col gap-0.5" data-testid="settings-search-results">
					{#each found as e (e.id)}
						<li><a class={item} href={settingsPath(e.id)} onclick={(ev) => open(ev, e.id)}>{t(e.label)}</a></li>
					{:else}
						<li class="text-muted-foreground px-2.5 text-sm">{t('settings.search.empty')}</li>
					{/each}
				</ul>
			{:else}
				{#each groups as g (g.id)}
					<section aria-label={t(g.label)} data-testid="settings-group-{g.id}">
						<h3 class="text-muted-foreground px-2.5 pb-1 text-xs font-semibold tracking-wide uppercase">{t(g.label)}</h3>
						<ul class="flex flex-col gap-0.5">
							{#each g.entries as e (e.id)}
								<li>
									<a class={item} href={settingsPath(e.id)} aria-current={id === e.id ? 'page' : undefined} data-testid="settings-link-{e.id}" onclick={(ev) => open(ev, e.id)}>
										<span class="flex min-w-0 flex-1 flex-col">
											<span class="truncate">{t(e.label)}{#if e.soon} <span class="text-muted-foreground text-xs font-normal">({t('settings.soon')})</span>{/if}</span>
											<span class="text-muted-foreground text-xs font-normal md:hidden">{t(e.description)}</span>
										</span>
										<ChevronRight class="text-muted-foreground size-4 shrink-0 md:hidden" aria-hidden="true" />
									</a>
								</li>
							{/each}
						</ul>
					</section>
				{/each}
			{/if}
		</nav>

		<div class={['flex min-w-0 flex-col gap-4', id === undefined && 'hidden md:flex']} data-testid="settings-content">
			{#if id !== undefined}
				<a class="text-muted-foreground hover:text-foreground inline-flex w-fit items-center gap-1 text-sm md:hidden" href="/einstellungen" data-testid="settings-back" onclick={(ev) => open(ev, undefined)}>
					<ChevronLeft class="size-4" aria-hidden="true" />{t('settings.back')}
				</a>
			{/if}
			{#if unknown}
				<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" data-testid="settings-notfound">{t('settings.notFound')}</p>
			{:else if denied}
				<p class="bg-muted/60 rounded-lg px-3 py-2 text-sm" data-testid="admin-denied">{t('settings.denied')}</p>
			{:else if id === undefined}
				<div class="grid gap-6" data-testid="settings-landing">
					{#each groups as g (g.id)}
						<section aria-label={t(g.label)}>
							<h3 class="mb-2 text-sm font-semibold">{t(g.label)}</h3>
							<ul class="grid gap-2 lg:grid-cols-2">
								{#each g.entries as e (e.id)}
									<li>
										<a class="bg-card hover:bg-muted flex h-full flex-col gap-0.5 rounded-xl border p-3 shadow-card transition-colors" href={settingsPath(e.id)} data-testid="settings-card-{e.id}" onclick={(ev) => open(ev, e.id)}>
											<span class="text-sm font-medium">{t(e.label)}{#if e.soon} <span class="text-muted-foreground text-xs font-normal">({t('settings.soon')})</span>{/if}</span>
											<span class="text-muted-foreground text-[13px]">{t(e.description)}</span>
										</a>
									</li>
								{/each}
							</ul>
						</section>
					{/each}
				</div>
			{:else if id === 'profil'}
				<ProfilePage />
			{:else if id === 'passkeys'}
				<PasskeysPage />
			{:else if id === 'wiederherstellung'}
				<RecoveryPage />
			{:else if id === 'sitzungen'}
				<SessionsPage />
			{:else if id === 'darstellung'}
				<AppearanceSettings />
			{:else if id === 'benachrichtigungen'}
				<NotificationSettings />
			{:else if id === 'email'}
				<EmailSettings />
			{:else if id === 'berechtigungen'}
				<AccessOverview {onnav} />
			{:else if id === 'verbindungen'}
				<ConnectionsPage onopen={onarea} />
			{:else if id === 'runner'}
				<RunnerPage onagents={() => onnav('agents')} />
			{:else if id === 'mcp'}
				<ClaudeConnect />
			{:else if id === 'daten'}
				<DataPage />
			{:else if id === 'verwaltung-konten'}
				<AdminAccounts />
			{:else if id === 'verwaltung-einladungen'}
				<AdminInvitations />
			{:else if id === 'verwaltung-server'}
				<ServerOverview />
			{:else if id && SERVER_CATEGORY_BY_ENTRY[id]}
				<ServerSettingsPage category={SERVER_CATEGORY_BY_ENTRY[id]} />
			{:else if id === 'verwaltung-system'}
				<AdminInfo kind="system" />
			{/if}
		</div>
	</div>
</section>
