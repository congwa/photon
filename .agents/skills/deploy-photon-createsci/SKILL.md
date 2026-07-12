---
name: deploy-photon-createsci
description: Deploy and maintain the user's local Photon fork for createsci.com on the SFO private backend. Use when fixing Photon UI behavior, validating the Svelte/SvelteKit app, committing Photon changes, deploying a local build artifact through SFO systemd, using the SFO Docker fallback, restarting Photon, or verifying the dmit_4_02 OpenResty edge to SFO request path.
---

# Deploy Photon CreateSci

## Purpose

This skill handles the owned Photon fork at `/Users/wang/code/xiaoji/photon` and deploys it to SFO (`root@108.62.160.202`). The preferred model is a local SvelteKit Node adapter build, upload of the `build/` release artifact, and `systemd` restart. `dmit_4_02` is only the OpenResty/TLS/WireGuard edge and must never receive Photon artifacts or source. SFO is a runtime host: do not run frontend dependency installation or builds on it. Docker image deployment remains only as a fallback path.

## Fixed Context

- Local repo: `/Users/wang/code/xiaoji/photon`
- Production branch: `codex/createsci-production`
- Production host: SFO `root@108.62.160.202`
- Public edge: dmit_4_02 `64.186.253.23` (OpenResty only)
- Production release root: `/srv/photon-systemd`
- Production compose file: `/srv/lemmy/compose.yaml`
- Preferred production service: systemd unit `photon`
- Legacy Docker service/container: compose service `photon`, container `createsci-photon`
- Runtime port: `127.0.0.1:19080`
- SFO internal entry: nginx `10.88.0.1:18080`
- Public entry: dmit_4_02 OpenResty `https://createsci.com/`
- Lemmy API health: `https://createsci.com/api/v3/site`
- PWA retirement: nginx owns `https://createsci.com/service-worker.js` with `Cache-Control: no-store`

## Preferred No-Docker Model

- Build Photon locally with the SvelteKit Node adapter and upload only the generated `build/` directory to `/srv/photon-systemd/releases/<release-id>`.
- Run Photon directly with Node through systemd: `node /srv/photon-systemd/current/build/index.js`.
- Keep nginx pointed at `127.0.0.1:19080`; the systemd service uses the same host and port as the former Docker container.
- SFO uses the preinstalled `/usr/bin/node`; fail closed if it is missing instead of downloading or building a runtime during deployment.
- Compose operations must support SFO's current standalone `docker-compose` v1 as well as a future `docker compose` plugin.
- Because the adapter-node output is self-contained enough for this app, the release package does not need `node_modules`; a local smoke test verified `build/` alone can return HTTP 200.
- Lemmy, PostgreSQL 18, and pictrs remain in the SFO compose stack. Postfix is not part of production; mail uses Resend SMTP.

## Remote Build Ban

- All dependency installation and frontend build work must happen on the local machine or CI before deployment.
- The production server may run only Git metadata sync, prebuilt Node runtime installation, release artifact unpacking, systemd restart, optional legacy Photon container stop, and verification commands.
- Do not use the VPS as a fallback builder. If local Docker or CI is unavailable, stop and report the blocker instead of running npm, bun, Vite, SvelteKit, or Docker build commands over SSH.
- If using the fallback Docker route, the Photon compose service must use `image: createsci-photon:createsci-current` or another prebuilt image tag and must not contain `build:`.
- Do not create a source checkout on SFO. Release metadata (`COMMIT`, version, time, notes) lives beside the uploaded immutable build.

## Workflow

1. Inspect local changes first.
   - Run `git status --short`, `git diff`, and targeted `rg`/file reads.
   - Preserve unrelated user changes. Do not reset or checkout files unless explicitly requested.

2. Fix locally in the Photon repo.
   - For the homepage bottom spinner bug, edit `src/lib/feature/post/feed/VirtualFeed.svelte`.
   - Use both Lemmy pagination cursor and page fullness: no `next_page`, or a returned page shorter than `params.limit`, means no more feed content for this UI. CreateSci's quiet homepage can receive `next_page: "P1"` even with one post, so cursor-only checks keep the bottom spinner visible.
   - Keep service worker changes aligned with nginx: production currently retires `/service-worker.js` at nginx, so do not rely on browser cache clearing as the product fix.

3. Validate before commit.
   - Prefer `bun install --frozen-lockfile` when `bun` exists; otherwise use the repo's available Node tooling.
   - Run at least `bun run check` or `npm run check`.
   - Run `bun run lint` or `npm run lint` when feasible.
   - Do not run a standalone production build unless diagnosing a local failure. The deploy script's local Docker build is the authoritative production build.

4. Commit reproducible source.
   - Create and use branch `codex/createsci-production` for production-owned Photon changes unless the user explicitly names a different long-lived branch.
   - Commit only Photon source changes needed for the fix.
   - Use concise Chinese or scoped English commit messages.
   - Do not commit generated build output, secrets, or deployment-only logs.

5. Deploy without Docker.
   - Preferred: run `scripts/deploy-photon-createsci-systemd.sh` from this skill.
   - The script refuses to deploy unless local Git is on `codex/createsci-production`, runs local checks, builds `ADAPTER=node` locally, uploads only `build/`, ensures a prebuilt Node runtime exists on the VPS, installs or updates systemd unit `photon`, stops the legacy Docker Photon container to release `127.0.0.1:19080`, and verifies production.
   - The script can mark the old compose `photon` service behind a disabled profile so future default `docker compose up` does not recreate it.
   - If local build tools are unavailable, stop and explain the missing dependency instead of attempting any remote frontend build on the VPS.
   - Do not SSH into the server to run `npm install`, `npm run build`, `bun install`, `bun run build`, `docker build`, or `docker compose build`.

6. Docker fallback deploy.
   - Use `scripts/deploy-photon-createsci.sh` only if systemd deployment is temporarily unsuitable.
   - The fallback script builds the `linux/amd64` image locally, streams it to SFO, keeps compose image-only, and force-recreates only the Photon service. It does not copy the source repository to SFO.

7. Verify production.
   - `curl -I https://createsci.com/` should return 200 HTML from Photon.
   - `curl -I https://createsci.com/service-worker.js` should include `Cache-Control: no-store`.
   - `curl -s https://createsci.com/api/v3/site` should return Lemmy site data.
   - For systemd deployment, confirm `systemctl status photon` is active and `curl http://127.0.0.1:19080/` succeeds on the VPS.
   - For Docker fallback, confirm `docker ps` shows `createsci-photon` healthy/running and bound only to `127.0.0.1:19080`.
   - If public nginx returns 502 while SFO loopback succeeds, check SFO nginx plus dmit_4_02 `/var/log/openresty/createsci.com.error.log`; Photon SSR can emit large modulepreload `Link` headers and needs larger proxy header buffers.
   - If the bug is visual, use browser or Playwright verification after deployment.

8. Update knowledge base when deployment facts change.
   - Update `/Users/wang/code/xiaoji/vps/ops/sfo/deployment.md` for application/runtime changes and `/Users/wang/code/xiaoji/vps/ops/dmit-4-02/deployment.md` only for edge changes.
   - Keep sensitive values out of docs and final replies.

## Script

Use:

```bash
/Users/wang/code/xiaoji/photon/.agents/skills/deploy-photon-createsci/scripts/deploy-photon-createsci-systemd.sh
```

Docker fallback:

```bash
/Users/wang/code/xiaoji/photon/.agents/skills/deploy-photon-createsci/scripts/deploy-photon-createsci.sh
```

Useful environment overrides:

```bash
LOCAL_REPO=/Users/wang/code/xiaoji/photon \
DEPLOY_BRANCH=codex/createsci-production \
REMOTE=root@108.62.160.202 \
REMOTE_COMPOSE=/srv/lemmy/compose.yaml \
IMAGE_TAG=createsci-photon:createsci-current \
/Users/wang/code/xiaoji/photon/.agents/skills/deploy-photon-createsci/scripts/deploy-photon-createsci.sh
```

The scripts refuse to deploy a dirty local Photon repo unless `ALLOW_DIRTY=1` is set. Use that override only for emergency hotfixes, and document the exact diff afterwards. `SKIP_LOCAL_CHECKS=1` skips local type/lint checks only; it never skips the local systemd artifact build or local Docker image build and never permits remote builds.

## Rollback

Fast rollback options:

- Re-run the script from the previous Git commit and image tag if that commit is still available locally.
- For systemd, repoint `/srv/photon-systemd/current` to a previous release directory and restart `systemctl restart photon`.
- Or on SFO disable the systemd unit, remove the disabled profile from `/srv/lemmy/compose.yaml` photon service, and run `docker compose -f /srv/lemmy/compose.yaml up -d --no-deps --force-recreate photon`.
- Or edit `/srv/lemmy/compose.yaml` photon service back to `image: ghcr.io/xyphyn/photon:latest`, then run `docker compose -f /srv/lemmy/compose.yaml up -d --no-deps --force-recreate photon`.

After rollback, verify homepage, Lemmy API, `/service-worker.js`, and `127.0.0.1:19080` binding again.
