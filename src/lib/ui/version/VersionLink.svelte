<!--
业务职责：把当前部署版本号呈现为可点击入口，让用户从侧栏直接进入本次更新说明页。
使用场景：侧栏底部等轻量位置需要显示 Photon 当前发布版本，并连接到 /updates 二级页面。
-->
<script lang="ts">
  import Logo from '$lib/ui/generic/Logo.svelte'
  import type { ClassValue } from 'svelte/elements'

  interface Props {
    class?: ClassValue
  }

  let { class: clazz = '' }: Props = $props()
</script>

<a
  href="/updates"
  aria-label="查看当前版本更新内容"
  class={[
    'inline-flex items-center gap-2 rounded-lg px-1.5 py-1 font-medium',
    'hover:text-slate-900 hover:bg-slate-100 dark:hover:text-zinc-50 dark:hover:bg-zinc-900',
    'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-900',
    'transition-colors',
    clazz,
  ]}
>
  <Logo width={16} />
  <span>{__VERSION__}</span>
</a>
