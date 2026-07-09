#!/usr/bin/env bash
# 业务职责：将本地维护的 Photon fork 以可复现的 Docker 镜像发布到 createsci.com，保证生产 VPS 只运行已构建产物。
# 使用场景：本地 Photon 修复完成并提交后，用本脚本在本机构建 linux/amd64 镜像、同步远端源码记录、加载镜像并只重启 createsci-photon 服务；远端禁止 npm/bun 安装和前端构建。

set -euo pipefail

LOCAL_REPO="${LOCAL_REPO:-/Users/wang/code/xiaoji/photon}"
REMOTE="${REMOTE:-root@64.186.253.23}"
REMOTE_REPO="${REMOTE_REPO:-/srv/photon}"
REMOTE_COMPOSE="${REMOTE_COMPOSE:-/srv/lemmy/compose.yaml}"
REMOTE_SERVICE="${REMOTE_SERVICE:-photon}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-codex/createsci-production}"
IMAGE_TAG="${IMAGE_TAG:-createsci-photon:createsci-current}"
PLATFORM="${PLATFORM:-linux/amd64}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_LOCAL_CHECKS="${SKIP_LOCAL_CHECKS:-0}"

# 业务职责：输出带阶段前缀的部署日志，帮助后续排障区分本地构建、远端同步和线上验证阶段。
log() {
  printf '[deploy-photon] %s\n' "$*"
}

# 业务职责：在执行破坏性较低但影响线上的步骤前确认必要命令存在，避免部署进行到一半才发现环境缺失。
require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$name" >&2
    exit 1
  fi
}

# 业务职责：确保本地 Photon 仓库状态可追溯；默认拒绝未提交源码部署，避免线上镜像无法对应 Git 提交。
assert_clean_repo() {
  local worktree_clean=0
  local index_clean=0
  git -C "$LOCAL_REPO" diff --quiet || worktree_clean=$?
  git -C "$LOCAL_REPO" diff --cached --quiet || index_clean=$?

  if [[ "$ALLOW_DIRTY" != "1" && ( "$worktree_clean" -ne 0 || "$index_clean" -ne 0 ) ]]; then
    printf 'Local repo has uncommitted changes. Commit first or set ALLOW_DIRTY=1 for an emergency deploy.\n' >&2
    git -C "$LOCAL_REPO" status --short >&2
    exit 1
  fi
}

# 业务职责：确认本次发布来自固定生产分支，使线上 /srv/photon、GitHub 和本地维护分支保持同一条可追踪发布线。
assert_deploy_branch() {
  local branch
  branch="$(git -C "$LOCAL_REPO" branch --show-current)"
  if [[ "$branch" != "$DEPLOY_BRANCH" ]]; then
    printf 'Current branch is %s, expected production branch %s.\n' "$branch" "$DEPLOY_BRANCH" >&2
    exit 1
  fi
}

# 业务职责：在本机运行 Photon 的依赖安装、类型检查和 Lint，提前发现质量问题；最终 Node adapter 构建只在本机 Docker 镜像阶段执行一次。
run_local_checks() {
  if [[ "$SKIP_LOCAL_CHECKS" == "1" ]]; then
    log "Skipping local checks because SKIP_LOCAL_CHECKS=1"
    return
  fi

  if command -v bun >/dev/null 2>&1; then
    (cd "$LOCAL_REPO" && bun install --frozen-lockfile && bun run check && bun run lint)
  else
    require_command npm
    (cd "$LOCAL_REPO" && npm install --package-lock=false --include=optional && ensure_workerd_optional_dependency && npm run check && npm run lint)
  fi
}

# 业务职责：补齐 workerd 的当前平台可选二进制包，避免 npm 在无 package-lock 模式下漏装 Cloudflare adapter 的平台依赖导致 Svelte 配置无法加载。
ensure_workerd_optional_dependency() {
  if node -e "require('workerd')" >/dev/null 2>&1; then
    return
  fi

  local package_spec
  package_spec="$(node - <<'NODE'
const workerd = require('./node_modules/workerd/package.json')
const platform = process.platform
const arch = process.arch
const name = `@cloudflare/workerd-${platform}-${arch === 'x64' ? '64' : arch}`
const version = workerd.optionalDependencies?.[name]
if (!version) {
  throw new Error(`No workerd optional dependency for ${platform}/${arch}`)
}
console.log(`${name}@${version}`)
NODE
)"

  log "Installing missing optional dependency $package_spec"
  npm install --no-save --package-lock=false "$package_spec"
}

# 业务职责：在本机产出目标服务器可运行的 amd64 Photon 镜像，这是部署流程中唯一允许执行前端 build 的阶段。
build_local_image() {
  require_command docker
  log "Building $IMAGE_TAG for $PLATFORM"
  docker buildx build --platform "$PLATFORM" --target node -t "$IMAGE_TAG" --load "$LOCAL_REPO"
}

# 业务职责：让远端 /srv/photon 与本地已提交版本对齐，仅用于记录线上镜像对应的 Git 提交，不在 VPS 上安装依赖或构建前端。
sync_remote_repo() {
  local commit
  commit="$(git -C "$LOCAL_REPO" rev-parse HEAD)"

  log "Syncing remote repo to $DEPLOY_BRANCH@$commit"
  ssh "$REMOTE" "set -euo pipefail
    cd '$REMOTE_REPO'
    git remote set-url origin '$(git -C "$LOCAL_REPO" remote get-url origin)'
    git fetch origin '$DEPLOY_BRANCH'
    git checkout -B '$DEPLOY_BRANCH' FETCH_HEAD
    git reset --hard '$commit'
  "
}

# 业务职责：确认生产 Compose 的 Photon 服务只消费预构建镜像，避免部署路径退回到 VPS 上执行 docker build、npm install 或 bun install。
assert_remote_runtime_only() {
  local expected_image="${1:-}"

  log "Checking remote compose keeps $REMOTE_SERVICE runtime-only"
  ssh "$REMOTE" "REMOTE_COMPOSE='$REMOTE_COMPOSE' REMOTE_SERVICE='$REMOTE_SERVICE' EXPECTED_IMAGE='$expected_image' python3 - <<'PY'
import json
import os
import subprocess

compose = os.environ['REMOTE_COMPOSE']
service_name = os.environ['REMOTE_SERVICE']
expected_image = os.environ.get('EXPECTED_IMAGE', '')

data = json.loads(
    subprocess.check_output(
        ['docker', 'compose', '-f', compose, 'config', '--format', 'json'],
        text=True,
    )
)
service = data.get('services', {}).get(service_name)
if service is None:
    raise SystemExit(f'compose service not found: {service_name}')

if 'build' in service:
    raise SystemExit(f'{service_name} must use a prebuilt image; remove build: from {compose}')

image = service.get('image')
if not image:
    raise SystemExit(f'{service_name} must declare image: so the VPS only runs a prebuilt artifact')

if expected_image and image != expected_image:
    raise SystemExit(f'{service_name} image is {image}, expected {expected_image}')

command_text = ' '.join(str(service.get(key) or '') for key in ('command', 'entrypoint')).lower()
for forbidden in ('npm install', 'npm run build', 'bun install', 'bun run build', 'docker build', 'docker compose build'):
    if forbidden in command_text:
        raise SystemExit(f'{service_name} command contains forbidden remote build step: {forbidden}')
PY"
}

# 业务职责：把本地构建好的 Photon 镜像流式加载到生产机，避免在远端产生大体积临时 tar 文件。
load_image_remote() {
  log "Streaming Docker image to $REMOTE"
  docker save "$IMAGE_TAG" | gzip -1 | ssh "$REMOTE" "gunzip | docker load"
}

# 业务职责：确保 Docker Compose 使用本地维护镜像，而不是重新拉取上游 latest 镜像覆盖本次部署。
ensure_compose_uses_local_image() {
  log "Ensuring compose service uses $IMAGE_TAG"
  ssh "$REMOTE" "python3 - <<'PY'
from pathlib import Path

compose = Path('$REMOTE_COMPOSE')
text = compose.read_text()
old = '    image: ghcr.io/xyphyn/photon:latest'
new = '    image: $IMAGE_TAG'
if old in text:
    compose.write_text(text.replace(old, new))
elif new not in text:
    raise SystemExit('photon image line is neither upstream nor expected local image tag')
PY"
}

# 业务职责：只重建 Photon 前端容器，保持 Lemmy、Postgres、pictrs 和 postfix 数据面稳定运行。
restart_remote_photon() {
  log "Restarting compose service $REMOTE_SERVICE"
  ssh "$REMOTE" "docker compose -f '$REMOTE_COMPOSE' up -d --no-deps --force-recreate '$REMOTE_SERVICE'"
}

# 业务职责：部署后验证公网入口、PWA 注销脚本、Lemmy API 和本机端口绑定，确认本次前端发布没有破坏站点基础链路。
verify_remote() {
  log "Verifying production"
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsSI https://createsci.com/ >/dev/null
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsSI https://createsci.com/service-worker.js | grep -i 'cache-control:.*no-store' >/dev/null
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsS https://createsci.com/api/v3/site | grep -q 'CreateSci'
  ssh "$REMOTE" "docker ps --filter name=createsci-photon --format '{{.Names}} {{.Image}} {{.Ports}}' && ss -ltnp | grep '127.0.0.1:19080'"
}

# 业务职责：串联完整发布事务，任何一步失败都停止后续线上变更，保证故障点清晰可恢复。
main() {
  require_command git
  require_command ssh
  require_command curl
  [[ -d "$LOCAL_REPO/.git" ]] || { printf 'Not a git repo: %s\n' "$LOCAL_REPO" >&2; exit 1; }

  assert_deploy_branch
  assert_clean_repo
  assert_remote_runtime_only
  run_local_checks
  build_local_image
  sync_remote_repo
  load_image_remote
  ensure_compose_uses_local_image
  assert_remote_runtime_only "$IMAGE_TAG"
  restart_remote_photon
  verify_remote
  log "Deployment complete"
}

main "$@"
