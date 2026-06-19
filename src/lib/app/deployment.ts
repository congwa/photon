/**
 * Business responsibility: expose the build-time deployment version, commit,
 * timestamp, and release notes that CreateSci users can inspect from the app.
 */

export interface DeploymentInfo {
  version: string
  commit: string
  previousCommit: string
  deployedAt: string
  notes: string
}

export const deploymentInfo: DeploymentInfo = {
  version: __VERSION__,
  commit: __DEPLOY_COMMIT__,
  previousCommit: __DEPLOY_PREVIOUS_COMMIT__,
  deployedAt: __DEPLOYED_AT__,
  notes: __DEPLOY_NOTES__,
}

/**
 * Business purpose: turn deploy-generated changelog text into concise update
 * rows so the release page can show what changed in the current deployment.
 */
export function getUpdateItems(notes: string = deploymentInfo.notes): string[] {
  const items = notes
    .split('\n')
    .map((line) => line.trim().replace(/^[-*]\s+/, ''))
    .filter(Boolean)

  return items.length > 0 ? items : ['本次部署未记录更新说明']
}

/**
 * Business purpose: format a Git commit for user-facing release metadata while
 * keeping the full hash available in the build artifact.
 */
export function shortCommit(commit: string): string {
  return commit ? commit.slice(0, 12) : 'local'
}

/**
 * Business purpose: render the UTC deploy time consistently across server and
 * browser so the update page does not show timezone-dependent hydration drift.
 */
export function formatDeployTime(deployedAt: string): string {
  if (!deployedAt) return '本地开发构建'

  return deployedAt.replace('T', ' ').replace('Z', ' UTC')
}
