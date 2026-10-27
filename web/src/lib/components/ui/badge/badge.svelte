<script lang="ts" module>
	import { tv, type VariantProps } from 'tailwind-variants';
	export const badgeVariants = tv({
		base: 'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap [&_svg]:size-3',
		variants: {
			variant: {
				default: 'bg-muted text-muted-foreground',
				accent: 'bg-ui-accent-soft text-ui-accent-ink',
				destructive: 'bg-destructive/10 text-destructive',
				success: 'bg-success-soft text-success',
				warning: 'bg-warning-soft text-warning',
				outline: 'border text-foreground'
			}
		},
		defaultVariants: { variant: 'default' }
	});
	export type BadgeVariant = VariantProps<typeof badgeVariants>['variant'];
</script>

<script lang="ts">
	import type { HTMLAttributes } from 'svelte/elements';
	import { cn } from '#lib/utils.js';
	let {
		class: className,
		variant = 'default',
		children,
		...rest
	}: HTMLAttributes<HTMLSpanElement> & { variant?: BadgeVariant } = $props();
</script>

<span data-slot="badge" class={cn(badgeVariants({ variant }), className)} {...rest}>{@render children?.()}</span>
