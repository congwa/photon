/*
 * 业务职责：处理旧式 /comment/:id 访问形态，把误落到 instance 段的评论 ID 重定向到当前实例的标准评论路由。
 * 使用场景：用户或外部链接只携带评论 ID 时，前端需要补齐当前实例，避免直接展示 404。
 */
import { resolve } from '$app/paths'
import { instance } from '$lib/app/instance.svelte'
import { redirect } from '@sveltejs/kit'

/*
 * 业务职责：把缺少实例名的评论入口转成标准评论详情入口。
 * 输入输出：输入 params.instance 实际承载评论 ID；输出 302 到 /comment/{currentInstance}/{id}。
 */
export function load({ params }) {
  // If you somehow got to /comment/instance, it likely means you passed in an ID, not an instance.
  redirect(
    302,
    resolve(
      `/comment/${encodeURIComponent(instance.data.toLowerCase())}/${params.instance}`,
    ),
  )
}
