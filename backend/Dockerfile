# Multi-stage build — keeps the final image lean (no devDependencies, no tsc).
#
# Stage 1 — install all deps and compile TypeScript to dist/
FROM node:22-slim AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# Stage 2 — production image: only runtime deps + compiled JS
FROM node:22-slim AS runner
WORKDIR /app

ENV NODE_ENV=production
# Size V8's heap for the 256 MB VM (fly.toml [[vm]] memory). Node does NOT read
# the container/VM memory limit: left alone, V8 picks a max old-space of roughly
# a quarter of the HOST's RAM, which on a Fly worker is gigabytes. It therefore
# never feels pressure to run a major GC before the VM is out of memory, and the
# process is OOM-killed mid-request instead of collecting garbage (the same
# failure mode that killed the database machine on 2026-07-11).
#
# 192 MB leaves ~64 MB for everything outside the JS heap — the Node binary,
# native buffers, the TLS stack — inside a 256 MB budget. If this VM is ever
# resized, this number moves with it: roughly 75% of the new memory.
ENV NODE_OPTIONS=--max-old-space-size=192

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy compiled output from the builder stage
COPY --from=builder /app/dist ./dist

EXPOSE 8080

CMD ["node", "dist/index.js"]
