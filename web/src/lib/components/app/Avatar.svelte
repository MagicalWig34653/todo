<script lang="ts">
	import { avatarHue, initialsOf } from '#lib/access.js';
	import { cn } from '#lib/utils.js';
	import UsersIcon from '@lucide/svelte/icons/users';

	/** Round initials badge with a stable colour per name; teams show a group icon. Decorative: the name is always written next to it. */
	let { name, team = false, size = 'md', class: className }: { name: string; team?: boolean; size?: 'sm' | 'md'; class?: string } = $props();
</script>

<span
	class={cn(
		'ring-background inline-flex shrink-0 items-center justify-center rounded-full font-semibold text-white ring-2 select-none',
		size === 'sm' ? 'size-6 text-[10px]' : 'size-8 text-xs',
		className
	)}
	style:background-color="hsl({avatarHue(name)} 42% 38%)"
	aria-hidden="true"
	data-testid="avatar"
>
	{#if team}<UsersIcon class={size === 'sm' ? 'size-3' : 'size-4'} aria-hidden="true" />{:else}{initialsOf(name)}{/if}
</span>
