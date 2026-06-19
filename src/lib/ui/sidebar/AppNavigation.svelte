<!--
业务职责：集中呈现应用级设置入口，帮助用户在不离开当前内容上下文时调整偏好、配色方案和主题。
使用场景：桌面右侧信息栏展示应用工具区；入口保持与侧栏按钮一致的交互样式，降低用户迁移位置后的学习成本。
-->
<script lang="ts">
  import { t } from '$lib/app/i18n'
  import { theme } from '$lib/app/theme/theme.svelte'
  import { Option, Select } from 'mono-svelte'
  import {
    ChevronUpDown,
    Cog6Tooth,
    ComputerDesktop,
    Icon,
    Moon,
    Sun,
    Swatch,
  } from 'svelte-hero-icons/dist'
  import type { ClassValue } from 'svelte/elements'
  import SidebarButton from './SidebarButton.svelte'

  interface Props {
    class?: ClassValue
  }

  let { class: clazz = '' }: Props = $props()
</script>

<div class={['flex flex-col gap-1', clazz]}>
  <SidebarButton
    href="/settings"
    label={$t('nav.menu.settings')}
    icon={Cog6Tooth}
  />
  <Select bind:value={theme.colorScheme} size="sm">
    {#snippet target(attachment)}
      <SidebarButton
        {@attach attachment}
        label={$t('nav.menu.colorscheme.label')}
        icon={theme.colorScheme == 'system'
          ? ComputerDesktop
          : theme.colorScheme == 'light'
            ? Sun
            : Moon}
        class="w-full relative"
      >
        <Option value="system" class="hidden" icon={ComputerDesktop}>
          {$t('nav.menu.colorscheme.system')}
        </Option>
        <Option value="light" class="hidden" icon={Sun}>
          {$t('nav.menu.colorscheme.light')}
        </Option>
        <Option value="dark" class="hidden" icon={Moon}>
          {$t('nav.menu.colorscheme.dark')}
        </Option>
        <Icon micro size="16" src={ChevronUpDown} class="ml-auto" />
      </SidebarButton>
    {/snippet}
  </Select>
  <SidebarButton href="/theme" label={$t('nav.menu.theme')} icon={Swatch} />
</div>
