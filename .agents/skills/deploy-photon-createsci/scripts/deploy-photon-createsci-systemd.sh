#!/usr/bin/env bash
# 业务职责：将本地构建好的 Photon Node adapter 产物以轻量 release 包发布到 createsci.com，替代 Photon 专用 Docker 容器。
# 使用场景：用户希望 VPS 不承担 npm/bun 安装、不执行前端 build、也不运行 Photon Docker 镜像时，用本脚本上传 build/ 目录并由 systemd 管理 Node 运行进程。

set -euo pipefail

LOCAL_REPO="${LOCAL_REPO:-/Users/wang/code/xiaoji/photon}"
REMOTE="${REMOTE:-root@64.186.253.23}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-/srv/photon-systemd}"
REMOTE_RELEASES_DIR="${REMOTE_RELEASES_DIR:-$REMOTE_APP_DIR/releases}"
REMOTE_CURRENT_LINK="${REMOTE_CURRENT_LINK:-$REMOTE_APP_DIR/current}"
REMOTE_SERVICE_NAME="${REMOTE_SERVICE_NAME:-photon}"
REMOTE_NODE_VERSION="${REMOTE_NODE_VERSION:-20.20.2}"
REMOTE_NODE_DIR="${REMOTE_NODE_DIR:-/opt/node-v${REMOTE_NODE_VERSION}-linux-x64}"
REMOTE_NODE_BIN="${REMOTE_NODE_BIN:-$REMOTE_NODE_DIR/bin/node}"
REMOTE_COMPOSE="${REMOTE_COMPOSE:-/srv/lemmy/compose.yaml}"
REMOTE_DOCKER_SERVICE="${REMOTE_DOCKER_SERVICE:-photon}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-codex/createsci-production}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-19080}"
ORIGIN="${ORIGIN:-https://createsci.com}"
PUBLIC_INSTANCE_TYPE="${PUBLIC_INSTANCE_TYPE:-lemmyv3}"
PUBLIC_INSTANCE_URL="${PUBLIC_INSTANCE_URL:-createsci.com}"
PUBLIC_LOCK_TO_INSTANCE="${PUBLIC_LOCK_TO_INSTANCE:-true}"
PUBLIC_SSR_ENABLED="${PUBLIC_SSR_ENABLED:-false}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_LOCAL_CHECKS="${SKIP_LOCAL_CHECKS:-0}"
DISABLE_DOCKER_PHOTON="${DISABLE_DOCKER_PHOTON:-1}"
DISABLE_COMPOSE_PHOTON_PROFILE="${DISABLE_COMPOSE_PHOTON_PROFILE:-1}"
DEPLOY_VERSION=""
DEPLOY_COMMIT=""
DEPLOY_PREVIOUS_COMMIT=""
DEPLOY_TIME=""
DEPLOY_NOTES=""

# 业务职责：输出带阶段前缀的部署日志，让发布、迁移和回滚排障时能快速定位当前事务阶段。
log() {
  printf '[deploy-photon-systemd] %s\n' "$*"
}

# 业务职责：在本地发布流程开始前确认必需命令存在，避免已经变更线上状态后才发现本地缺少工具。
require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$name" >&2
    exit 1
  fi
}

# 业务职责：确保发布来源是固定生产分支，使 systemd release、Git 提交和线上行为保持同一条可追溯发布线。
assert_deploy_branch() {
  local branch
  branch="$(git -C "$LOCAL_REPO" branch --show-current)"
  if [[ "$branch" != "$DEPLOY_BRANCH" ]]; then
    printf 'Current branch is %s, expected production branch %s.\n' "$branch" "$DEPLOY_BRANCH" >&2
    exit 1
  fi
}

# 业务职责：默认拒绝未提交源码发布，避免线上 build 产物无法对应到可审计的 Git commit。
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

# 业务职责：读取 package.json 中的产品基线版本，用作首次 systemd 版本递增的起点。
read_package_version() {
  node -e "const pkg = require(process.argv[1]); console.log(pkg.version)" "$LOCAL_REPO/package.json"
}

# 业务职责：将当前发布版本按 patch 位递增，保证每次部署后的用户可见版本号都向前推进。
increment_patch_version() {
  local version="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"
  patch="${patch%%-*}"

  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
    printf 'Invalid semantic version for deploy increment: %s\n' "$version" >&2
    exit 1
  fi

  printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
}

# 业务职责：读取线上 current release 的元数据；缺失时返回空值，使首次迁移部署可以平滑回退到本地基线。
read_remote_release_file() {
  local filename="$1"
  ssh "$REMOTE" "cat '$REMOTE_CURRENT_LINK/$filename' 2>/dev/null || true" | tr -d '\r' | head -n 1
}

# 业务职责：在构建前生成本次发布的用户可见版本、提交范围和更新说明，供 Vite 注入到前端页面。
resolve_deploy_metadata() {
  local package_version
  local previous_version
  local notes

  DEPLOY_COMMIT="$(git -C "$LOCAL_REPO" rev-parse --short=12 HEAD)"
  DEPLOY_PREVIOUS_COMMIT="$(read_remote_release_file COMMIT)"
  previous_version="$(read_remote_release_file DEPLOY_VERSION)"
  package_version="$(read_package_version)"

  if [[ -n "$previous_version" ]]; then
    DEPLOY_VERSION="$(increment_patch_version "$previous_version")"
  else
    DEPLOY_VERSION="$(increment_patch_version "$package_version")"
  fi

  DEPLOY_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "$DEPLOY_PREVIOUS_COMMIT" ]] &&
    git -C "$LOCAL_REPO" cat-file -e "$DEPLOY_PREVIOUS_COMMIT^{commit}" 2>/dev/null &&
    git -C "$LOCAL_REPO" merge-base --is-ancestor "$DEPLOY_PREVIOUS_COMMIT" HEAD; then
    notes="$(git -C "$LOCAL_REPO" log --reverse --no-merges --pretty=format:'- %s' "$DEPLOY_PREVIOUS_COMMIT..HEAD")"
  else
    notes=""
  fi

  if [[ -z "$notes" ]]; then
    notes="$(git -C "$LOCAL_REPO" log -1 --pretty=format:'- %s')"
  fi

  DEPLOY_NOTES="$notes"
  log "Resolved deploy metadata: version=$DEPLOY_VERSION commit=$DEPLOY_COMMIT previous=${DEPLOY_PREVIOUS_COMMIT:-none}"
}

# 业务职责：补齐 workerd 的当前本机平台可选二进制包，保证本地 SvelteKit 配置解析和质量检查不会因可选依赖缺失而失败。
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

# 业务职责：在本机安装依赖并运行类型检查与 Lint，把质量风险拦在 release 包生成之前，VPS 不参与任何依赖安装。
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

# 业务职责：在本机生成 SvelteKit Node adapter 运行产物，产出的 build/ 是 Photon systemd 运行时唯一需要上传的应用文件。
build_local_release() {
  if command -v bun >/dev/null 2>&1; then
    (
      cd "$LOCAL_REPO"
      export ADAPTER=node DEPLOY_VERSION DEPLOY_COMMIT DEPLOY_PREVIOUS_COMMIT DEPLOY_TIME DEPLOY_NOTES
      bun run build
    )
  else
    require_command npm
    (
      cd "$LOCAL_REPO"
      export ADAPTER=node DEPLOY_VERSION DEPLOY_COMMIT DEPLOY_PREVIOUS_COMMIT DEPLOY_TIME DEPLOY_NOTES
      npm run build
    )
  fi
}

# 业务职责：确保生产机具备 Node 运行时；只安装官方预编译 Node 二进制，不在 VPS 上运行 npm install 或任何前端构建。
ensure_remote_node_runtime() {
  log "Ensuring remote Node runtime $REMOTE_NODE_VERSION"
  ssh "$REMOTE" "set -euo pipefail
    if [[ ! -x '$REMOTE_NODE_BIN' ]]; then
      command -v curl >/dev/null
      command -v tar >/dev/null
      mkdir -p /opt
      tmp_dir=\"\$(mktemp -d)\"
      curl -fsSL 'https://nodejs.org/dist/v$REMOTE_NODE_VERSION/node-v$REMOTE_NODE_VERSION-linux-x64.tar.xz' -o \"\$tmp_dir/node.tar.xz\"
      tar -xJf \"\$tmp_dir/node.tar.xz\" -C /opt
      rm -rf \"\$tmp_dir\"
    fi
    '$REMOTE_NODE_BIN' --version
  "
}

# 业务职责：把本机 build/ 目录作为不可变 release 上传到 VPS，并通过 current 符号链接完成近原子切换。
upload_release() {
  local commit
  local release_id
  local notes_b64
  commit="$(git -C "$LOCAL_REPO" rev-parse --short=12 HEAD)"
  release_id="${commit}-$(date -u +%Y%m%d%H%M%S)"
  notes_b64="$(printf '%s' "$DEPLOY_NOTES" | base64 | tr -d '\n')"

  log "Uploading build/ as release $release_id"
  tar -C "$LOCAL_REPO" -czf - build | ssh "$REMOTE" "set -euo pipefail
    release_dir='$REMOTE_RELEASES_DIR/$release_id'
    tmp_dir=\"\$release_dir.tmp\"
    mkdir -p '$REMOTE_RELEASES_DIR'
    rm -rf \"\$tmp_dir\"
    mkdir -p \"\$tmp_dir\"
    tar -xzf - -C \"\$tmp_dir\"
    printf '%s\n' '$commit' > \"\$tmp_dir/COMMIT\"
    printf '%s\n' '$DEPLOY_VERSION' > \"\$tmp_dir/DEPLOY_VERSION\"
    printf '%s\n' '$DEPLOY_TIME' > \"\$tmp_dir/DEPLOY_TIME\"
    printf '%s\n' '$notes_b64' | base64 -d > \"\$tmp_dir/DEPLOY_NOTES.md\"
    mv \"\$tmp_dir\" \"\$release_dir\"
    ln -sfn \"\$release_dir\" '$REMOTE_CURRENT_LINK'
    chown -R root:root '$REMOTE_APP_DIR'
    find '$REMOTE_APP_DIR' -type d -exec chmod 755 {} +
    find '$REMOTE_APP_DIR' -type f -exec chmod 644 {} +
  "
}

# 业务职责：写入 Photon 的 systemd 服务单元，把公网反代仍指向的 127.0.0.1:19080 交给 Node adapter 进程监听。
install_systemd_service() {
  log "Installing systemd service $REMOTE_SERVICE_NAME"
  ssh "$REMOTE" "cat > '/etc/systemd/system/$REMOTE_SERVICE_NAME.service' <<EOF
[Unit]
Description=CreateSci Photon frontend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$REMOTE_CURRENT_LINK
Environment=HOST=$HOST
Environment=PORT=$PORT
Environment=ORIGIN=$ORIGIN
Environment=PUBLIC_INSTANCE_TYPE=$PUBLIC_INSTANCE_TYPE
Environment=PUBLIC_INSTANCE_URL=$PUBLIC_INSTANCE_URL
Environment=PUBLIC_LOCK_TO_INSTANCE=$PUBLIC_LOCK_TO_INSTANCE
Environment=PUBLIC_SSR_ENABLED=$PUBLIC_SSR_ENABLED
ExecStart=$REMOTE_NODE_BIN $REMOTE_CURRENT_LINK/build/index.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload"
}

# 业务职责：在迁移到 systemd 前停止旧 Photon 容器释放端口，并可选地给 compose 中的旧服务加 profile 防止后续默认 up 又拉起它。
disable_docker_photon() {
  if [[ "$DISABLE_DOCKER_PHOTON" != "1" ]]; then
    log "Leaving existing Docker Photon service untouched because DISABLE_DOCKER_PHOTON=0"
    return
  fi

  log "Stopping old Docker Photon service if it exists"
  ssh "$REMOTE" "set -euo pipefail
    if command -v docker >/dev/null 2>&1 && [[ -f '$REMOTE_COMPOSE' ]]; then
      docker compose -f '$REMOTE_COMPOSE' stop '$REMOTE_DOCKER_SERVICE' || true
      docker compose -f '$REMOTE_COMPOSE' rm -f '$REMOTE_DOCKER_SERVICE' || true
    fi
  "

  if [[ "$DISABLE_COMPOSE_PHOTON_PROFILE" != "1" ]]; then
    return
  fi

  log "Marking compose photon service behind an opt-in profile"
  ssh "$REMOTE" "REMOTE_COMPOSE='$REMOTE_COMPOSE' REMOTE_DOCKER_SERVICE='$REMOTE_DOCKER_SERVICE' python3 - <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import os
import subprocess

compose = Path(os.environ['REMOTE_COMPOSE'])
service = os.environ['REMOTE_DOCKER_SERVICE']
text = compose.read_text()
lines = text.splitlines(True)
service_header = f'  {service}:\\n'
profile_lines = ['    profiles:\\n', '      - docker-photon-disabled\\n']

try:
    start = lines.index(service_header)
except ValueError:
    raise SystemExit(f'compose service not found: {service}')

end = len(lines)
for index in range(start + 1, len(lines)):
    if lines[index].startswith('  ') and not lines[index].startswith('    '):
        end = index
        break

block = ''.join(lines[start:end])
if 'profiles:' not in block:
    backup = compose.with_name(compose.name + '.bak-systemd-' + datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'))
    backup.write_text(text)
    lines[start + 1:start + 1] = profile_lines
    compose.write_text(''.join(lines))

subprocess.check_call(['docker', 'compose', '-f', str(compose), 'config'], stdout=subprocess.DEVNULL)
PY"
}

# 业务职责：启动或重启 Photon 的 systemd 服务，让新 release 在固定本机端口对 nginx 生效。
restart_systemd_service() {
  log "Restarting systemd service $REMOTE_SERVICE_NAME"
  ssh "$REMOTE" "systemctl enable '$REMOTE_SERVICE_NAME' >/dev/null && systemctl restart '$REMOTE_SERVICE_NAME'"
}

# 业务职责：验证 systemd 管理的 Photon 本机端口、公网入口、PWA 注销脚本和 Lemmy API，确认迁移后基础访问链路完整。
verify_remote() {
  log "Verifying systemd Photon deployment"
  ssh "$REMOTE" "systemctl is-active --quiet '$REMOTE_SERVICE_NAME' && curl --retry 5 --retry-delay 2 --retry-connrefused -fsSI 'http://$HOST:$PORT/' >/dev/null"
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsSI "$ORIGIN/" >/dev/null
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsSI "$ORIGIN/service-worker.js" | grep -i 'cache-control:.*no-store' >/dev/null
  curl --retry 5 --retry-delay 2 --retry-connrefused -fsS "$ORIGIN/api/v3/site" | grep -q 'CreateSci'
}

# 业务职责：串联无 Docker Photon 发布事务；所有构建发生在本机，VPS 只安装 Node runtime、接收 build/、切换 systemd 服务并验证。
main() {
  require_command git
  require_command ssh
  require_command tar
  require_command curl
  require_command node
  [[ -d "$LOCAL_REPO/.git" ]] || { printf 'Not a git repo: %s\n' "$LOCAL_REPO" >&2; exit 1; }

  assert_deploy_branch
  assert_clean_repo
  resolve_deploy_metadata
  run_local_checks
  build_local_release
  ensure_remote_node_runtime
  upload_release
  install_systemd_service
  disable_docker_photon
  restart_systemd_service
  verify_remote
  log "Systemd deployment complete"
}

main "$@"
