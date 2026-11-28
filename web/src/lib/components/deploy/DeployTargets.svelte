<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { api, type Project } from '#lib/api.js';
	import { can, roleOf } from '#lib/access.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import {
		DEPLOY_PROTOCOLS,
		DEPLOY_STAGES,
		defaultPort,
		deployErrorText,
		emptyForm,
		endpointLabel,
		formOf,
		problemKey,
		protocolLabel,
		stageLabel,
		writeBody,
		type DeployForm,
		type DeployTarget,
		type DeployTestResult
	} from '#lib/deploy.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Checkbox } from '#lib/components/ui/checkbox/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Select } from '#lib/components/ui/select/index.js';
	import { Textarea } from '#lib/components/ui/textarea/index.js';
	import DeployPlans from './DeployPlans.svelte';
	import DeploySync from './DeploySync.svelte';
	import GitHubRepositories from './GitHubRepositories.svelte';
	import Server from '@lucide/svelte/icons/server';
	import ShieldAlert from '@lucide/svelte/icons/shield-alert';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import KeyRound from '@lucide/svelte/icons/key-round';

	/**
	 * Deploy targets of a project (card 354ADE12, phase 1b): list, create, edit, delete, connection test with SFTP host key
	 * confirmation, and the read-only sync view. Persons with manage edit targets; edit runs test and compare. The server checks
	 * every right again. Secrets are write-only: the form never shows a stored password, key or passphrase.
	 */
	let { project }: { project: Project } = $props();

	const role = $derived(roleOf(project));
	const canManage = $derived(can(role, 'editProject'));
	const canRun = $derived(can(role, 'addTask'));

	let status = $state<'loading' | 'failed' | 'ready'>('loading');
	let targets = $state<DeployTarget[]>([]);
	/** Dialog-wide confirmation line (saved, deleted). */
	let message = $state('');

	const projectID = $derived(project.id);
	$effect(() => {
		const id = projectID;
		untrack(() => void load(id));
	});
	async function load(id = projectID) {
		status = 'loading';
		try {
			targets = await api.listDeployTargets(id);
			status = 'ready';
		} catch {
			status = 'failed';
		}
	}
	const replace = (next: DeployTarget) => (targets = targets.map((x) => (x.id === next.id ? next : x)));

	// ---- form ---------------------------------------------------------------------------------------------------------
	let editing = $state<DeployTarget | 'new' | null>(null);
	let form = $state<DeployForm>(emptyForm());
	let formError = $state('');
	let saving = $state(false);
	let formEl = $state<HTMLFormElement | null>(null);
	const existing = $derived(editing && editing !== 'new' ? editing : undefined);
	const tls = $derived(form.protocol === 'ftps' || form.protocol === 'ftps-implicit');

	async function openForm(target?: DeployTarget) {
		editing = target ?? 'new';
		form = target ? formOf(target) : emptyForm();
		formError = '';
		message = '';
		closeView();
		await tick();
		formEl?.querySelector<HTMLInputElement>('input')?.focus();
	}
	function closeForm() {
		editing = null;
		formError = '';
		form.password = '';
		form.privateKey = '';
		form.passphrase = '';
	}
	async function save() {
		if (saving || !editing) return;
		const built = writeBody(form, existing);
		if ('problem' in built) {
			formError = t(problemKey(built.problem));
			return;
		}
		saving = true;
		formError = '';
		try {
			if (existing) {
				const updated = Object.keys(built.body).length ? await api.updateDeployTarget(existing.id, built.body) : existing;
				replace(updated);
			} else {
				targets = [...targets, await api.createDeployTarget(projectID, built.body)];
			}
			editing = null;
			message = t('deploy.saved');
		} catch (e) {
			formError = deployErrorText(e);
		} finally {
			saving = false;
			form.password = '';
			form.privateKey = '';
			form.passphrase = '';
		}
	}

	// ---- test and host key ------------------------------------------------------------------------------------------
	/** Result of the last test, shown under that target only. */
	let tested = $state<{ id: string; result?: DeployTestResult; error?: string } | null>(null);
	let testing = $state<string | null>(null);
	let confirming = $state(false);
	async function test(target: DeployTarget) {
		if (testing) return;
		testing = target.id;
		message = '';
		tested = null;
		try {
			tested = { id: target.id, result: await api.testDeployTarget(target.id) };
		} catch (e) {
			tested = { id: target.id, error: deployErrorText(e) };
		} finally {
			testing = null;
		}
	}
	async function confirmKey(target: DeployTarget, fingerprint: string) {
		if (confirming) return;
		confirming = true;
		try {
			replace(await api.confirmDeployHostKey(target.id, fingerprint));
			tested = null;
		} catch (e) {
			tested = { id: target.id, error: deployErrorText(e) };
		} finally {
			confirming = false;
		}
	}
	function testText(r: DeployTestResult): string {
		if (r.ok) return typeof r.files === 'number' ? t('deploy.test.ok', { files: r.files }) : t('deploy.test.okNoCount');
		return deployErrorText(r.code ?? 'deploy_failed');
	}

	// ---- delete -------------------------------------------------------------------------------------------------------
	let deleting = $state<DeployTarget | null>(null);
	let deleteBusy = $state(false);
	let deleteError = $state('');
	async function remove() {
		if (!deleting || deleteBusy) return;
		const id = deleting.id;
		deleteBusy = true;
		deleteError = '';
		try {
			await api.deleteDeployTarget(id);
			targets = targets.filter((x) => x.id !== id);
			deleting = null;
			message = t('deploy.deleted');
		} catch (e) {
			deleteError = deployErrorText(e);
		} finally {
			deleteBusy = false;
		}
	}

	// ---- sync view ----------------------------------------------------------------------------------------------------
	let viewing = $state<DeployTarget | null>(null);
	function openView(target: DeployTarget) {
		closeForm();
		deleting = null;
		message = '';
		viewing = target;
	}
	function closeView() {
		viewing = null;
	}

	// ---- upload plans -------------------------------------------------------------------------------------------------
	let uploading = $state<DeployTarget | null>(null);
	function openPlans(target: DeployTarget) {
		closeForm();
		deleting = null;
		message = '';
		uploading = target;
	}

	const heading = 'text-muted-foreground text-xs font-semibold tracking-wide uppercase';
	const fid = (name: string) => `deploy-f-${name}`;
</script>

<div class="flex min-w-0 flex-col gap-4" data-testid="deploy-targets">
	{#if viewing}
		<DeploySync target={viewing} onback={closeView} />
	{:else if uploading}
		<DeployPlans target={uploading} {canManage} onback={() => (uploading = null)} />
	{:else if status === 'loading'}
		<p class="text-muted-foreground min-h-16 text-sm" role="status">{t('deploy.loading')}</p>
	{:else if status === 'failed'}
		<div class="flex flex-wrap items-center gap-2" role="alert">
			<span>{t('deploy.loadFailed')}</span>
			<Button size="sm" variant="outline" onclick={() => void load()}>{t('common.retry')}</Button>
		</div>
	{:else if editing}
		<form bind:this={formEl} class="flex min-w-0 flex-col gap-4" novalidate data-testid="deploy-form" onsubmit={(e) => { e.preventDefault(); void save(); }}>
			<h3 class="font-semibold">{existing ? t('deploy.form.edit', { name: existing.name }) : t('deploy.form.new')}</h3>
			<div class="grid min-w-0 gap-3 sm:grid-cols-2">
				<div class="flex min-w-0 flex-col gap-1 sm:col-span-2">
					<label class="text-sm font-medium" for={fid('name')}>{t('deploy.form.name')}</label>
					<Input id={fid('name')} maxlength={120} autocomplete="off" placeholder={t('deploy.form.namePlaceholder')} bind:value={form.name} />
				</div>
				<div class="flex min-w-0 flex-col gap-1">
					<label class="text-sm font-medium" for={fid('stage')}>{t('deploy.form.stage')}</label>
					<Select id={fid('stage')} bind:value={form.stage}>
						{#each DEPLOY_STAGES as s (s)}<option value={s}>{t(`deploy.stage.${s}` as MessageKey)}</option>{/each}
					</Select>
				</div>
				<div class="flex min-w-0 flex-col gap-1">
					<label class="text-sm font-medium" for={fid('protocol')}>{t('deploy.form.protocol')}</label>
					<Select id={fid('protocol')} bind:value={form.protocol}>
						{#each DEPLOY_PROTOCOLS as p (p)}<option value={p}>{t(`deploy.form.protocol.${p}` as MessageKey)}</option>{/each}
					</Select>
				</div>
				{#if form.protocol === 'ftp'}
					<p class="bg-destructive/10 text-destructive flex items-start gap-2 rounded-lg p-3 text-sm font-medium sm:col-span-2" role="alert" data-testid="deploy-ftp-warning">
						<ShieldAlert class="mt-0.5 size-4 shrink-0" aria-hidden="true" />{t('deploy.form.ftpWarning')}
					</p>
				{/if}
				<div class="flex min-w-0 flex-col gap-1">
					<label class="text-sm font-medium" for={fid('host')}>{t('deploy.form.host')}</label>
					<Input id={fid('host')} autocomplete="off" autocapitalize="none" spellcheck={false} bind:value={form.host} />
				</div>
				<div class="flex min-w-0 flex-col gap-1">
					<label class="text-sm font-medium" for={fid('port')}>{t('deploy.form.port')}</label>
					<Input id={fid('port')} inputmode="numeric" autocomplete="off" placeholder={String(defaultPort(form.protocol))} bind:value={form.port} />
				</div>
				<div class="flex min-w-0 flex-col gap-1 sm:col-span-2">
					<label class="text-sm font-medium" for={fid('base')}>{t('deploy.form.basePath')}</label>
					<Input id={fid('base')} autocomplete="off" autocapitalize="none" spellcheck={false} aria-describedby={fid('base-h')} bind:value={form.basePath} />
					<p class="text-muted-foreground text-xs" id={fid('base-h')}>{t('deploy.form.basePathHint')}</p>
				</div>
				<div class="flex min-w-0 flex-col gap-1">
					<label class="text-sm font-medium" for={fid('user')}>{t('deploy.form.username')}</label>
					<Input id={fid('user')} autocomplete="off" autocapitalize="none" spellcheck={false} bind:value={form.username} />
				</div>
				{#if form.protocol === 'sftp'}
					<div class="flex min-w-0 flex-col gap-1">
						<label class="text-sm font-medium" for={fid('auth')}>{t('deploy.form.auth')}</label>
						<Select id={fid('auth')} bind:value={form.auth}>
							<option value="password">{t('deploy.form.auth.password')}</option>
							<option value="key">{t('deploy.form.auth.key')}</option>
						</Select>
					</div>
				{/if}
				<div class="flex min-w-0 flex-col gap-1 sm:col-span-2">
					{#if form.protocol === 'sftp' && form.auth === 'key'}
						<label class="text-sm font-medium" for={fid('key')}>{t('deploy.form.privateKey')}</label>
						<Textarea id={fid('key')} class="font-mono text-xs" rows={4} autocomplete="off" spellcheck={false} aria-describedby={fid('secret-h')} bind:value={form.privateKey} />
						<label class="mt-2 text-sm font-medium" for={fid('pass')}>{t('deploy.form.passphrase')}</label>
						<Input id={fid('pass')} type="password" autocomplete="off" bind:value={form.passphrase} />
					{:else}
						<label class="text-sm font-medium" for={fid('pw')}>{t('deploy.form.password')}</label>
						<Input id={fid('pw')} type="password" autocomplete="new-password" aria-describedby={fid('secret-h')} bind:value={form.password} />
					{/if}
					{#if existing}
						<p class="text-muted-foreground flex items-center gap-1.5 text-xs" id={fid('secret-h')} data-testid="deploy-secret-stored"><KeyRound class="size-3.5 shrink-0" aria-hidden="true" />{t('deploy.form.secretStored')}</p>
					{:else}
						<p class="text-muted-foreground text-xs" id={fid('secret-h')}>{t('deploy.form.secretHint')}</p>
					{/if}
				</div>
				{#if tls}
					<div class="flex min-w-0 flex-col gap-1 sm:col-span-2">
						<label class="text-sm font-medium" for={fid('cert')}>{t('deploy.form.tlsCertificate')}</label>
						<Textarea id={fid('cert')} class="font-mono text-xs" rows={3} spellcheck={false} aria-describedby={fid('cert-h')} bind:value={form.tlsCertificate} />
						<p class="text-muted-foreground text-xs" id={fid('cert-h')}>{existing?.tlsCertificatePinned ? t('deploy.form.tlsCertificateStored') : t('deploy.form.tlsCertificateHint')}</p>
						{#if existing?.tlsCertificatePinned}
							<label class="flex min-h-9 cursor-pointer items-center gap-2 text-sm">
								<Checkbox bind:checked={form.removeCertificate} />{t('deploy.form.removeCertificate')}
							</label>
						{/if}
					</div>
				{/if}
			</div>

			<fieldset class="flex min-w-0 flex-col gap-3">
				<legend class={heading}>{t('deploy.form.rules')}</legend>
				<p class="text-muted-foreground text-xs">{t('deploy.form.rulesHint')}</p>
				<div class="grid min-w-0 gap-3 sm:grid-cols-2">
					<div class="flex min-w-0 flex-col gap-1">
						<label class="text-sm font-medium" for={fid('inc')}>{t('deploy.form.includes')}</label>
						<Textarea id={fid('inc')} class="font-mono text-xs" rows={3} spellcheck={false} placeholder={t('deploy.form.includesPlaceholder')} bind:value={form.includes} />
					</div>
					<div class="flex min-w-0 flex-col gap-1">
						<label class="text-sm font-medium" for={fid('exc')}>{t('deploy.form.excludes')}</label>
						<Textarea id={fid('exc')} class="font-mono text-xs" rows={3} spellcheck={false} bind:value={form.excludes} />
					</div>
					<div class="flex min-w-0 flex-col gap-1 sm:col-span-2">
						<label class="text-sm font-medium" for={fid('map')}>{t('deploy.form.mappings')}</label>
						<Textarea id={fid('map')} class="font-mono text-xs" rows={2} spellcheck={false} aria-describedby={fid('map-h')} bind:value={form.mappings} />
						<p class="text-muted-foreground text-xs" id={fid('map-h')}>{t('deploy.form.mappingsHint')}</p>
					</div>
				</div>
				<label class="flex min-h-9 cursor-pointer items-start gap-3">
					<Checkbox class="mt-0.5" bind:checked={form.defaultExcludes} aria-labelledby={fid('def')} aria-describedby={existing ? fid('def-d') : undefined} />
					<span class="flex min-w-0 flex-col gap-0.5">
						<span class="text-sm font-medium" id={fid('def')}>{t('deploy.form.defaultExcludes')}</span>
						{#if existing}
							<span class="text-muted-foreground text-xs [overflow-wrap:anywhere]" id={fid('def-d')}>{t('deploy.form.defaultExcludesHint')} <span class="font-mono">{existing.effectiveExcludes.filter((x) => !(existing.rules.excludes ?? []).includes(x)).join(', ')}</span></span>
						{/if}
					</span>
				</label>
			</fieldset>

			<div class="flex flex-col gap-2">
				<p role="alert" class="text-destructive text-sm font-medium [overflow-wrap:anywhere] empty:hidden" data-testid="deploy-form-error">{formError}</p>
				<div class="flex flex-wrap gap-2">
					<Button type="submit" class="max-sm:w-full aria-disabled:opacity-60" aria-disabled={saving} data-testid="deploy-save">{saving ? t('deploy.form.saving') : t('deploy.form.save')}</Button>
					<Button type="button" variant="outline" class="max-sm:w-full" onclick={closeForm}>{t('deploy.cancel')}</Button>
				</div>
			</div>
		</form>
	{:else}
		<p class="text-muted-foreground text-sm">{t('deploy.intro')}</p>
		<p class="text-muted-foreground text-xs">{t('deploy.agentsNote')}</p>
		{#if !canManage}
			<p class="bg-muted/60 rounded-xl border p-3 text-sm">{t('deploy.readonly')}</p>
		{/if}

		{#if targets.length === 0}
			<p class="text-muted-foreground rounded-xl border border-dashed p-4 text-center text-sm" data-testid="deploy-empty">{t('deploy.empty')}</p>
		{:else}
			<ul class="flex flex-col divide-y rounded-xl border" aria-label={t('deploy.title')}>
				{#each targets as target (target.id)}
					{@const offer = tested?.id === target.id ? tested.result?.offeredHostKey : undefined}
					<li class="flex min-w-0 flex-col gap-2 px-3 py-3" data-testid="deploy-target" data-target-id={target.id}>
						<div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
							<Server class="text-muted-foreground size-4 shrink-0" aria-hidden="true" />
							<span class="min-w-0 font-medium [overflow-wrap:anywhere]" data-testid="deploy-name">{target.name}</span>
							<Badge variant={target.stage === 'prod' ? 'warning' : 'accent'} data-testid="deploy-stage">{stageLabel(target.stage)}</Badge>
							<Badge variant="outline" data-testid="deploy-protocol">{protocolLabel(target.protocol)}</Badge>
							{#if target.protocol === 'ftp'}
								<Badge variant="destructive" data-testid="deploy-ftp-badge"><ShieldAlert aria-hidden="true" />{t('deploy.ftpBadge')}</Badge>
							{/if}
						</div>
						<p class="text-muted-foreground font-mono text-xs [overflow-wrap:anywhere]" data-testid="deploy-endpoint">{endpointLabel(target)}</p>
						{#if target.protocol === 'sftp'}
							<p class={['flex items-center gap-1.5 text-xs font-medium', target.hostKey.confirmed ? 'text-success' : 'text-warning']}>
								{#if target.hostKey.confirmed}<ShieldCheck class="size-3.5 shrink-0" aria-hidden="true" />{:else}<ShieldAlert class="size-3.5 shrink-0" aria-hidden="true" />{/if}
								<span data-testid="deploy-hostkey">{target.hostKey.confirmed ? t('deploy.hostKey.confirmed') : t('deploy.hostKey.unconfirmed')}</span>
							</p>
						{:else if target.tlsCertificatePinned}
							<p class="text-success flex items-center gap-1.5 text-xs font-medium"><ShieldCheck class="size-3.5 shrink-0" aria-hidden="true" />{t('deploy.certPinned')}</p>
						{/if}
						<div class="flex flex-wrap gap-1.5" role="group" aria-label={t('deploy.actions', { name: target.name })}>
							{#if canRun}
								<Button size="sm" variant="outline" class="aria-disabled:opacity-60" aria-disabled={testing === target.id} data-testid="deploy-test" onclick={() => void test(target)}>{testing === target.id ? t('deploy.testing') : t('deploy.test')}</Button>
								<Button size="sm" variant="outline" data-testid="deploy-sync" onclick={() => openView(target)}>{t('deploy.sync')}</Button>
								<Button size="sm" variant="outline" data-testid="deploy-plans-open" onclick={() => openPlans(target)}>{t('deploy.plans.open')}</Button>
							{/if}
							{#if canManage}
								<Button size="sm" variant="ghost" data-testid="deploy-edit" onclick={() => void openForm(target)}>{t('deploy.edit')}</Button>
								<Button size="sm" variant="ghost" class="text-destructive" data-testid="deploy-delete" onclick={() => { deleting = target; deleteError = ''; message = ''; }}>{t('deploy.delete')}</Button>
							{/if}
						</div>

						{#if offer?.fingerprint}
							<div class="bg-warning-soft flex min-w-0 flex-col gap-2 rounded-lg p-3 text-sm" data-testid="deploy-hostkey-offer">
								<p class="font-semibold">{t('deploy.hostKey.offerTitle')}</p>
								<p>{t('deploy.hostKey.offerText', { type: offer.type ?? '?' })}</p>
								<code class="bg-background rounded-md border px-2 py-1 font-mono text-xs [overflow-wrap:anywhere]" data-testid="deploy-fingerprint">{offer.fingerprint}</code>
								{#if canManage}
									<div>
										<Button size="sm" class="aria-disabled:opacity-60" aria-disabled={confirming} data-testid="deploy-hostkey-confirm" onclick={() => void confirmKey(target, offer.fingerprint ?? '')}>{confirming ? t('deploy.hostKey.confirming') : t('deploy.hostKey.confirm')}</Button>
									</div>
								{/if}
							</div>
						{:else if tested?.id === target.id}
							<p
								role="status"
								class={['text-sm font-medium [overflow-wrap:anywhere]', tested.result?.ok ? 'text-success' : 'text-destructive']}
								data-testid="deploy-test-result"
							>{tested.result ? testText(tested.result) : tested.error}</p>
						{/if}

						{#if deleting?.id === target.id}
							<div class="border-destructive/40 flex min-w-0 flex-col gap-2 rounded-lg border p-3 text-sm" role="alertdialog" aria-label={t('deploy.delete')} data-testid="deploy-delete-confirm">
								<p class="[overflow-wrap:anywhere]">{t('deploy.deleteConfirm', { name: target.name })}</p>
								{#if deleteError}<p class="text-destructive font-medium" role="alert">{deleteError}</p>{/if}
								<div class="flex flex-wrap gap-2">
									<Button size="sm" variant="destructive" class="aria-disabled:opacity-60" aria-disabled={deleteBusy} data-testid="deploy-delete-yes" onclick={() => void remove()}>{t('deploy.deleteYes')}</Button>
									<Button size="sm" variant="outline" onclick={() => (deleting = null)}>{t('deploy.cancel')}</Button>
								</div>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		{#if canManage}
			<div><Button data-testid="deploy-add" class="max-sm:w-full" onclick={() => void openForm()}>{t('deploy.add')}</Button></div>
		{/if}
		<GitHubRepositories {project} />
	{/if}
	<p role="status" aria-live="polite" class="text-success text-sm font-medium empty:hidden" data-testid="deploy-status">{viewing || uploading || editing ? '' : message}</p>
</div>
