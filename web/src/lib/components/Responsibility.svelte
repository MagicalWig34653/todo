<script lang="ts">
	import { roleOf } from '#lib/access.js';
	import { api } from '#lib/api.js';
	import { directory } from '#lib/assignees.svelte.js';
	import { candidatesFor, mayDecideReview, mayHandOverQuestion, mayHandOverReview } from '#lib/assignment.js';
	import { auth } from '#lib/auth.svelte.js';
	import { t } from '#lib/i18n/index.js';
	import { attempt } from '#lib/notice.svelte.js';
	import { workspace } from '#lib/workspace.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Select } from '#lib/components/ui/select/index.js';

	/**
	 * One line of a question or review: "Für <Name>" (or "Entscheidet: <Name>" when somebody else has to decide a named
	 * review) and "Weitergeben" with the list of assignable people. Nothing to show and nothing to do = no line.
	 */
	interface Props {
		kind: 'question' | 'review';
		id: string;
		projectID?: string | null;
		/** The person stored on the question or review (`reviewerID` of a review). */
		assigneeID?: string | null;
		assigneeName?: string | null;
		/** Belongs to a local runner job: cannot be handed over. */
		runner?: boolean;
		onchanged?: () => void | Promise<void>;
	}
	let { kind, id, projectID, assigneeID, assigneeName, runner = false, onchanged }: Props = $props();

	const project = $derived(workspace.projects.find((p) => p.id === projectID));
	const role = $derived(project ? roleOf(project) : 'read');
	const others = $derived(kind === 'review' && !mayDecideReview(assigneeID, auth.user?.id, role));
	const allowed = $derived(
		!!project && (kind === 'question' ? mayHandOverQuestion(role, runner) : mayHandOverReview({ reviewerID: assigneeID, meID: auth.user?.id, role, runner }))
	);
	const people = $derived(candidatesFor(directory.people(projectID), kind).filter((p) => p.userID !== assigneeID));
	const name = $derived(assigneeID ? directory.label(projectID, assigneeID, assigneeName) : null);

	let open = $state(false);
	let busy = $state(false);

	$effect(() => {
		if (assigneeID && !assigneeName) void directory.load(projectID);
	});

	function toggle() {
		open = !open;
		if (open) void directory.load(projectID, true);
	}
	async function handOver(value: string) {
		if (!value || busy) return;
		busy = true;
		const target = value === 'none' ? null : value;
		await attempt(() => (kind === 'question' ? api.setQuestionAssignee(id, target) : api.setReviewAssignee(id, target)));
		busy = false;
		open = false;
		// Also after a refusal: show the real state.
		await onchanged?.();
	}
</script>

{#if name || allowed}
	<div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-xs" data-testid="handover">
		{#if name}
			<span class={['min-w-0 [overflow-wrap:anywhere]', others ? 'font-medium' : 'text-muted-foreground']} data-testid="handover-line">{t(others ? 'assign.decides' : 'assign.for', { name })}</span>
		{/if}
		{#if allowed}
			<Button type="button" variant="ghost" size="sm" class="text-ui-accent-ink -mx-2 h-8 px-2 text-xs" aria-expanded={open} onclick={toggle}>{t('assign.handover')}</Button>
			{#if open}
				<Select class="max-w-full min-w-40 [&_select]:h-8 [&_select]:text-xs" aria-label={t('assign.handoverTo')} disabled={busy} value="" onchange={(e) => handOver(e.currentTarget.value)}>
					<option value="" disabled>{t('assign.choose')}</option>
					{#if assigneeID}<option value="none">{t('assign.nobody')}</option>{/if}
					{#each people as p (p.userID)}<option value={p.userID}>{p.displayName}</option>{/each}
				</Select>
			{/if}
		{/if}
	</div>
{/if}
