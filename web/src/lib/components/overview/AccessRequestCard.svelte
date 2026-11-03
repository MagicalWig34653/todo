<script lang="ts">
	import { api } from '#lib/api.js';
	import type { ForYouAccessRequest } from '#lib/forYou.js';
	import { type MessageKey, t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { formatWhen } from '#lib/planning.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Bot from '@lucide/svelte/icons/bot';

	/** Notice "a connection wanted a project" (ADR 0028). Allowing adds the project to the connection (the person's own click is the confirmation). */
	let { item, ondone }: { item: ForYouAccessRequest; ondone: (item: ForYouAccessRequest) => void } = $props();
	let busy = $state(false);

	async function decide(kind: 'allow' | 'ignore') {
		if (busy) return;
		busy = true;
		await attempt(async () => {
			try {
				if (kind === 'allow') await api.allowAccessRequest(item.id);
				else await api.ignoreAccessRequest(item.id);
				ondone(item);
			} finally {
				busy = false;
			}
		});
	}
</script>

<article class="bg-card flex min-w-0 flex-col gap-2 rounded-xl border p-3 [overflow-wrap:anywhere]" data-testid="access-card">
	<span class="text-ui-accent flex items-center gap-1.5 text-xs font-semibold"><Bot class="size-3.5" aria-hidden="true" />{t('forYou.access.kind')}<span class="bg-muted text-muted-foreground rounded-full px-1.5 py-0.5 font-medium">{t('share.conn.badge')}</span></span>
	<span class="text-sm font-semibold" data-testid="access-title">{t('forYou.access.title', { name: item.connectionName, project: item.projectName })}</span>
	<span class="text-muted-foreground text-xs">{item.count > 1 ? t('forYou.access.many', { count: item.count, when: formatWhen(item.lastAt) }) : t('forYou.access.once', { when: formatWhen(item.lastAt) })}</span>
	<span class="text-muted-foreground text-xs">{t('forYou.access.hint', { role: t(`sharing.role.${item.role}` as MessageKey) })}</span>
	<div class="flex flex-wrap gap-2">
		<Button disabled={busy} onclick={() => decide('allow')} data-testid="access-allow">{t('forYou.access.allow')}</Button>
		<Button variant="outline" disabled={busy} onclick={() => decide('ignore')} data-testid="access-ignore">{t('forYou.access.ignore')}</Button>
	</div>
</article>
