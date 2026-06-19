<!--
业务职责：展示当前 Photon 部署版本的变更摘要，帮助站点用户理解刚上线的更新内容。
使用场景：用户点击侧栏或头像菜单里的版本号后，进入本页查看版本号、部署时间、提交和本次发布说明。
-->
<script lang="ts">
  import {
    deploymentInfo,
    formatDeployTime,
    getUpdateItems,
    shortCommit,
  } from '$lib/app/deployment'
  import { Header } from '$lib/ui/layout'
  import { Badge, Button } from 'mono-svelte'
  import {
    ArrowLeft,
    CheckCircle,
    Clock,
    CodeBracketSquare,
    Cube,
    Icon,
    Sparkles,
  } from 'svelte-hero-icons/dist'

  const updateItems = $derived(getUpdateItems())
  const deployedAt = $derived(formatDeployTime(deploymentInfo.deployedAt))
  const commit = $derived(shortCommit(deploymentInfo.commit))
</script>

<svelte:head>
  <title>更新内容 {deploymentInfo.version}</title>
</svelte:head>

<Header pageHeader>
  更新内容
  {#snippet extended()}
    <div class="flex flex-wrap items-center gap-2">
      <Badge color="blue-subtle" class="text-sm">
        v{deploymentInfo.version}
      </Badge>
      <Button href="/" size="sm" rounding="lg" icon={ArrowLeft}>
        返回首页
      </Button>
    </div>
  {/snippet}
</Header>

<div class="mx-auto flex w-full max-w-3xl flex-col gap-6">
  <section class="grid gap-3 sm:grid-cols-3" aria-label="部署信息">
    <div
      class="rounded-lg border border-slate-200 bg-slate-50 p-4 dark:border-zinc-800 dark:bg-zinc-950"
    >
      <div
        class="mb-2 flex items-center gap-2 text-slate-500 dark:text-zinc-400"
      >
        <Icon src={Cube} size="16" micro />
        <span class="text-sm">版本</span>
      </div>
      <div class="font-mono text-lg font-semibold">
        {deploymentInfo.version}
      </div>
    </div>

    <div
      class="rounded-lg border border-slate-200 bg-slate-50 p-4 dark:border-zinc-800 dark:bg-zinc-950"
    >
      <div
        class="mb-2 flex items-center gap-2 text-slate-500 dark:text-zinc-400"
      >
        <Icon src={Clock} size="16" micro />
        <span class="text-sm">部署时间</span>
      </div>
      <div class="font-mono text-sm font-semibold">{deployedAt}</div>
    </div>

    <div
      class="rounded-lg border border-slate-200 bg-slate-50 p-4 dark:border-zinc-800 dark:bg-zinc-950"
    >
      <div
        class="mb-2 flex items-center gap-2 text-slate-500 dark:text-zinc-400"
      >
        <Icon src={CodeBracketSquare} size="16" micro />
        <span class="text-sm">提交</span>
      </div>
      <div class="font-mono text-sm font-semibold">{commit}</div>
    </div>
  </section>

  <section class="flex flex-col gap-3" aria-label="本次更新">
    <div class="flex items-center gap-2">
      <Icon
        src={Sparkles}
        size="18"
        micro
        class="text-primary-900 dark:text-primary-100"
      />
      <h2 class="text-xl font-semibold tracking-normal">本次更新</h2>
    </div>

    <ul
      class="divide-y divide-slate-200 border-y border-slate-200 dark:divide-zinc-800 dark:border-zinc-800"
    >
      {#each updateItems as item}
        <li class="flex gap-3 py-4">
          <Icon
            src={CheckCircle}
            size="18"
            micro
            class="mt-0.5 shrink-0 text-emerald-600 dark:text-emerald-300"
          />
          <span class="min-w-0 break-words leading-relaxed">{item}</span>
        </li>
      {/each}
    </ul>
  </section>
</div>
