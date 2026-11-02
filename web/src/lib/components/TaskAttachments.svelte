<script lang="ts">
	import { Select } from '#lib/components/ui/select/index.js';
	import { api, type Attachment, type AttachmentRole } from '#lib/api.js';
	import { ATTACHMENT_ROLES, checkFile, formatSize, isImage, sha256Hex } from '#lib/attachments.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { onMount } from 'svelte';
	import { sameList, startLiveRefresh } from '#lib/liveRefresh.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let { taskID, onchanged }: { taskID: string; onchanged?: () => unknown } = $props();

	let items = $state<Attachment[]>([]);
	let role = $state<AttachmentRole>('reference');
	let busy = $state(false);
	let loaded = $state(false);
	let loadFailed = $state(false);
	let problem = $state<string | null>(null);
	let input = $state<HTMLInputElement | null>(null);

	async function load() {
		try {
			items = await api.listAttachments(taskID);
			loadFailed = false;
		} catch (e) {
			loadFailed = true;
			throw e;
		} finally {
			loaded = true;
		}
	}
	$effect(() => {
		void taskID;
		loaded = false;
		attempt(load);
	});
	onMount(() =>
		startLiveRefresh(async () => {
			const before = items;
			const next = await api.listAttachments(taskID);
			if (items === before && !sameList(items, next)) items = next;
		}, { guardEditing: true })
	);

	async function upload(e: Event) {
		e.preventDefault();
		const file = input?.files?.[0];
		problem = null;
		if (!file) return;
		const p = checkFile(file);
		if (p) {
			problem = t(`attachments.problem.${p}` as MessageKey);
			return;
		}
		busy = true;
		const ok = await attempt(async () => {
			const checksum = await sha256Hex(file);
			const cap = await api.beginAttachment({
				taskID,
				filename: file.name,
				role,
				mediaType: file.type,
				size: file.size,
				checksum
			});
			try {
				await api.uploadAttachment(cap, file);
				await api.completeAttachment(cap.attachmentID);
			} catch (err) {
				// Best effort: drop the pending upload so it does not linger until expiry.
				await api.abortAttachment(cap.attachmentID).catch(() => {});
				throw err;
			}
			await load();
		});
		busy = false;
		if (ok && input) input.value = '';
		if (ok) await onchanged?.();
	}
</script>

<div class="flex flex-col gap-2">
	{#if !loaded}
		<div class="bg-muted/60 h-24 animate-pulse rounded-md" role="status" aria-label={t('common.loading')} data-testid="attachments-loading"></div>
	{:else if loadFailed && items.length === 0}
		<p class="text-destructive text-xs" role="alert" data-testid="attachments-error">{t('common.loadFailed')} <button type="button" class="underline" onclick={() => attempt(load)}>{t('common.retry')}</button></p>
	{:else if items.length === 0}<p class="text-muted-foreground text-xs">{t('attachments.empty')}</p>{/if}
	<ul class="flex flex-wrap gap-2">
		{#each items as a (a.id)}
			<li class="w-40 rounded-md border p-1 text-xs" data-testid="attachment">
				{#if isImage(a.mediaType)}
					<a href={api.attachmentPreviewURL(a.id)} target="_blank" rel="noopener">
						<img
							src={api.attachmentPreviewURL(a.id)}
							alt={t('attachments.preview', { name: a.filename })}
							class="h-24 w-full rounded object-cover"
							loading="lazy"
						/>
					</a>
				{:else}
					<div class="bg-muted text-muted-foreground flex h-24 items-center justify-center rounded">PDF</div>
				{/if}
				<p class="mt-1 truncate" title={a.filename}>{a.filename}</p>
				<p class="text-muted-foreground">{t(`attachments.role.${a.role}` as MessageKey)} · {formatSize(a.size)}</p>
				<a class="underline" href={api.attachmentDownloadURL(a.id)} download={a.filename}>{t('attachments.download')}</a>
			</li>
		{/each}
	</ul>
	<form class="flex flex-wrap items-center gap-2" onsubmit={upload}>
		<input
			bind:this={input}
			type="file"
			accept="image/png,image/jpeg,image/webp,application/pdf"
			aria-label={t('attachments.choose')}
			class="max-w-full text-xs"
		/>
		<Select  aria-label={t('attachments.role')} bind:value={role}>
			{#each ATTACHMENT_ROLES as r (r)}<option value={r}>{t(`attachments.role.${r}` as MessageKey)}</option>{/each}
		</Select>
		<Button type="submit" size="sm" disabled={busy}>{busy ? t('attachments.uploading') : t('attachments.upload')}</Button>
	</form>
	<p class="text-muted-foreground text-xs">{t('attachments.hint')}</p>
	{#if problem}<p role="alert" class="text-destructive text-xs">{problem}</p>{/if}
</div>
