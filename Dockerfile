# 业务职责：在本机或 CI 中构建 createsci.com 使用的 Photon 运行镜像，确保生产服务器只接收已构建好的运行产物。
# 使用场景：部署脚本通过 docker buildx 生成 linux/amd64 镜像后传到 VPS，VPS 不执行 npm install、bun install 或前端 build。

# Dependency stage shared by local image builds
FROM oven/bun:1.2.9-alpine AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

# Bun stage
FROM deps AS bun-builder
WORKDIR /app
COPY . .
RUN ADAPTER=bun bun run build

# Node.js stage
FROM node:20-alpine AS node-builder
WORKDIR /app
COPY package.json ./
COPY --from=deps /app/node_modules /app/node_modules
COPY . .
RUN ADAPTER=node npm run build

# Final Node.js image
FROM node:20-alpine AS node
USER node
WORKDIR /app
ENV NODE_ENV=production
COPY --from=node-builder /app/build /app/build
COPY --from=node-builder /app/node_modules /app/node_modules
COPY --from=node-builder /app/package.json /app/package.json
EXPOSE 3000
CMD ["node", "build/index.js"]

# Final Bun image
FROM oven/bun:1.2.9-alpine AS bun
WORKDIR /app
ENV NODE_ENV=production
COPY --from=bun-builder /app/build /app/build
COPY --from=bun-builder /app/node_modules /app/node_modules
EXPOSE 3000
USER bun
CMD ["bun", "build/index.js"]
