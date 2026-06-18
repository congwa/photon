/*
 * 业务职责：把评论详情入口解析到其所属帖子和线程锚点，让评论链接最终落在可阅读的帖子上下文中。
 * 使用场景：用户打开联邦评论链接时，先校验实例归属，再跳转到对应帖子并附带 thread/hash 定位评论。
 */
import { resolve } from '$app/paths'
import { client } from '$lib/api/client.svelte'
import { profile } from '$lib/app/auth'
import { redirect } from '@sveltejs/kit'

/*
 * 业务职责：加载评论所属帖子信息并生成帖子页重定向地址。
 * 输入输出：输入为实例名和评论 ID；输出为 302 跳转，跨实例时先进入确认页。
 */
export async function load({ params, fetch }) {
  if (profile.current.instance != params.instance)
    redirect(
      302,
      resolve(
        `/comment/${encodeURIComponent(params.instance)}/${params.id}/confirm`,
      ),
    )

  const comment = await client({
    instanceURL: profile.current.instance,
    func: fetch,
  }).getComment({
    id: Number(params.id),
  })

  const split = comment.comment_view.comment.path.split('.')

  const threadPath = split.slice(-3).join('.')

  redirect(
    302,
    resolve('/post/[instance]/[id=integer]', {
      instance: encodeURIComponent(params.instance),
      id: comment.comment_view.post.id.toString(),
    }) + `?thread=${threadPath}#${comment.comment_view.comment.id}`,
  )
}
