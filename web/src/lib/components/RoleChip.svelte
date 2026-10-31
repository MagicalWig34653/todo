<script lang="ts">
	import { roleOf, isOwner } from '#lib/access.js';
	import type { Project } from '#lib/api.js';
	import { t, type MessageKey } from '#lib/i18n/index.js';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';

	/** "Du: Bearbeiten" / "Du: Eigentümer": the viewer's own role in a project, with the explanation as tooltip. */
	let { project }: { project: Project } = $props();
	const role = $derived(roleOf(project));
	const owner = $derived(isOwner(project));
	const roleName = $derived(t(`sharing.role.${role}` as MessageKey));
	const label = $derived(owner ? t('access.youOwner') : t('access.youRole', { role: roleName }));
	const title = $derived(owner ? t('access.youOwnerTitle') : t('access.youRoleTitle', { role: roleName, help: t(`access.roleHelp.${role}` as MessageKey) }));
</script>

<span class="bg-muted text-foreground/80 inline-flex h-6 items-center gap-1 rounded-full px-2 text-xs font-medium" {title} data-testid="role-chip">
	<ShieldCheck class="size-3.5" aria-hidden="true" />{label}
</span>
