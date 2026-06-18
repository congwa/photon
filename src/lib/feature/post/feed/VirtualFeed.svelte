<script lang="ts">
  /*
   * 业务职责：负责 Photon 帖子信息流的虚拟列表和无限滚动体验，让大列表滚动保持流畅，同时避免低内容量站点在首页底部长期显示加载器。
   * 使用场景：首页、社区页等帖子列表启用 infiniteScroll 与虚拟化时使用；只有当前页达到分页大小且 Lemmy 提供下一页游标时，业务上才继续请求更多帖子。
   */
  import { browser } from '$app/environment'
  import { client } from '$lib/api/client.svelte'
  import type { GetPosts, PostView } from '$lib/api/types'
  import { errorMessage } from '$lib/app/error'
  import { t } from '$lib/app/i18n'
  import VirtualList from '$lib/app/render/VirtualList.svelte'
  import { settings } from '$lib/app/settings.svelte'
  import Placeholder from '$lib/ui/info/Placeholder.svelte'
  import EndPlaceholder from '$lib/ui/layout/EndPlaceholder.svelte'
  import { Button, Material, Spinner } from 'mono-svelte'
  import { onDestroy, untrack } from 'svelte'
  import type { Attachment } from 'svelte/attachments'
  import {
    ArchiveBox,
    ArrowsPointingOut,
    ArrowTopRightOnSquare,
    ChevronDoubleUp,
    ExclamationTriangle,
    Icon,
  } from 'svelte-hero-icons/dist'
  import InfiniteScroll from 'svelte-infinite-scroll'
  import { expoOut } from 'svelte/easing'
  import { SvelteSet } from 'svelte/reactivity'
  import { fly } from 'svelte/transition'
  import { Post } from '..'
  import { filterPost, type FilteredItem } from '../filters.svelte'
  import { ReactiveState } from '$lib/app/util.svelte'

  interface Props {
    posts: PostView[]
    params: GetPosts
    virtualList?: { itemHeights: (number | null)[] }
    lastSeen?: number
    community?: boolean
    children?: import('svelte').Snippet
  }

  let {
    posts = $bindable(),
    params = $bindable(),
    virtualList = $bindable(),
    lastSeen = $bindable(0),
    community = false,
    children,
  }: Props = $props()

  let filteredPosts: FilteredItem[] = $derived(
    posts.map((post) => ({
      id: post.post.id,
      action: filterPost(post),
    })),
  )

  let listEl = $state<HTMLUListElement>()
  let listComp = $state<{
    scrollToIndex: (index: number, window?: boolean) => void
    rerender: () => void
  }>()

  let error = $state()
  let loading = $state(false)

  const abortLoad = new AbortController()
  let seenIds = new SvelteSet<number>(posts.map((post) => post.post.id))
  const feedPageLimit = $derived(params.limit ?? 20)

  /*
   * 业务职责：判断信息流是否值得继续触发无限滚动，避免 Lemmy 在短首页仍返回 page cursor 时让用户看到无意义的底部 spinner。
   * 关键约束：只有上一页达到请求的分页大小且存在下一页游标，才代表列表很可能还有内容；少于分页大小的小站首页应直接展示结束态。
   */
  const canLoadAnotherPage = (
    pagePosts: PostView[],
    pageCursor?: GetPosts['page_cursor'],
  ) => pagePosts.length >= feedPageLimit && Boolean(pageCursor)

  let hasMore = $state(canLoadAnotherPage(posts, params.page_cursor))

  /*
   * 业务职责：从当前信息流中移除被用户隐藏或被操作折叠的帖子，确保前端展示状态立即响应用户的帖子级操作。
   * 输入输出：输入是 Lemmy post id；输出是更新后的本地帖子列表，不向后端提交删除或隐藏请求。
   */
  const removePost = (postId: number) => {
    const index = posts.findIndex((post) => post.post.id === postId)
    if (index === -1) return
    posts = posts.toSpliced(index, 1)
  }

  /*
   * 业务职责：按 Lemmy 返回的分页游标加载下一页帖子，并在追加内容前更新本地分页状态。
   * 关键约束：Lemmy 可能在短首页仍返回 next_page，因此必须同时参考返回帖子数量和游标，避免小站首页底部长期显示加载器或重复请求首屏数据。
   */
  async function loadMore() {
    if (!hasMore || loading) return

    try {
      loading = true

      const newPosts = await client({
        func: (input, init) =>
          fetch(input, { ...init, signal: abortLoad.signal }),
      })
        .getPosts(params)
        .catch((e) => {
          throw new Error(e)
        })

      error = null

      params.page_cursor = newPosts.next_page
      hasMore = canLoadAnotherPage(newPosts.posts, newPosts.next_page)

      posts.push(
        ...newPosts.posts.filter((post) => {
          if (seenIds.has(post.post.id)) return false
          seenIds.add(post.post.id)
          return true
        }),
      )

      loading = false
    } catch (e) {
      error = e
      loading = false
    }
  }

  const observer = browser
    ? new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (!entry.isIntersecting) return

            const element = entry.target as HTMLElement
            const id = element.getAttribute('data-index')

            if (!id) return

            lastSeen = Number(id)

            observer?.unobserve(element)
          })
        },
        {
          threshold: 0.5,
        },
      )
    : null

  const intersectionAttach: Attachment = (node) => {
    observer?.observe(node)
    return () => {
      observer?.unobserve(node)
    }
  }

  $effect(() => {
    if (listComp) {
      untrack(() => {
        if (lastSeen != 0) {
          listComp?.scrollToIndex(lastSeen, true)
        }
      })
    }
  })

  let initialOffset = $derived(listEl?.offsetTop)

  onDestroy(() => {
    abortLoad?.abort()
    observer?.disconnect()
  })
</script>

<ul class="flex flex-col list-none" bind:this={listEl}>
  {#key posts}
    {#if posts.length == 0}
      <div class="h-full grid place-items-center my-8">
        <Placeholder
          icon={ArchiveBox}
          title={$t('routes.frontpage.empty.title')}
          description={$t('routes.frontpage.empty.description')}
        >
          <Button
            href="/communities"
            rounding="pill"
            color="primary"
            icon={ArrowTopRightOnSquare}
          >
            {$t('nav.communities')}
          </Button>
        </Placeholder>
      </div>
    {:else}
      <VirtualList
        id="feed"
        class="divide-y -mx-3 sm:-mx-6 divide-slate-100 dark:divide-zinc-900"
        items={posts}
        {initialOffset}
        overscan={3}
        estimatedHeight={settings.view == 'cozy' ? 500 : 150}
        bind:restore={virtualList}
        bind:this={listComp}
        initialScrollIndex={lastSeen}
      >
        {#snippet item(row)}
          <!--god svelte is gonna make me lose it-->
          {@const filter = new ReactiveState(filteredPosts[row])}
          <li
            in:fly={row < 7
              ? { duration: 800, easing: expoOut, y: 24, delay: row * 50 }
              : { opacity: 1, duration: 0 }}
            data-index={row}
            class={[
              'relative post-container',
              filter.value.action == 'hide' && 'hidden',
              row < 7 && '',
            ]}
            {@attach intersectionAttach}
          >
            <!--TODO make my component isolation not abysmal-->
            {#if filter.value.action == 'none'}
              <Post
                bind:post={posts[row]}
                hideCommunity={community}
                view={(posts[row].post.featured_community ||
                  posts[row].post.featured_local) &&
                settings.posts.compactFeatured
                  ? 'compact'
                  : settings.view}
                onhide={() => removePost(posts[row].post.id)}
                class="px-3 sm:px-6 hover:bg-slate-100/30 hover:dark:bg-zinc-900/30 transition-colors"
              ></Post>
            {:else if filter.value.action == 'minimize'}
              <Button
                onclick={() => {
                  filteredPosts[row].action = 'none'
                  filter.value.action = 'none'
                  listComp?.rerender()
                }}
                color="tertiary"
                rounding="none"
                icon={ArrowsPointingOut}
                class="text-slate-400 dark:text-zinc-600 w-full"
                size="xs"
              >
                {$t('settings.lemmy.contentFilter.minimized')}
              </Button>
            {/if}
          </li>
        {/snippet}
      </VirtualList>
    {/if}
  {/key}

  {#if settings.infiniteScroll && browser && posts.length > 0}
    {#if error}
      <Material color="error" class="flex flex-col gap-4">
        <div>
          <Icon
            src={ExclamationTriangle}
            size="20"
            micro
            class="inline-block rounded-lg clear-both float-left mr-2"
          />
          {errorMessage(error)}
        </div>
        <Button
          color="primary"
          {loading}
          disabled={loading}
          onclick={() => loadMore()}
        >
          {$t('message.retry')}
        </Button>
      </Material>
    {:else if hasMore}
      <div class="w-full h-32 grid place-items-center">
        <Spinner width={24} />
      </div>
    {:else}
      <div style="border-top-width: 0">
        <EndPlaceholder>
          {$t('routes.frontpage.endFeed', {
            community_name:
              params.community_name ??
              'Lemmy. There are no more posts. You saw them all.',
          })}
          {#snippet action()}
            <Button color="tertiary" icon={ChevronDoubleUp}>
              {$t('routes.post.scrollToTop')}
            </Button>
          {/snippet}
        </EndPlaceholder>
      </div>
    {/if}
    <InfiniteScroll window threshold={300} on:loadMore={loadMore} />
  {/if}
  {@render children?.()}
</ul>
