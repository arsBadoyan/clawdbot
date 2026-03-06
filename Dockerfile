# Build OpenClaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for OpenClaw build
RUN apt-get update \
&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
git \
ca-certificates \
curl \
python3 \
make \
g++ \
&& rm -rf /var/lib/apt/lists/*

# Install Bun (OpenClaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Use latest OpenClaw automatically (main branch).
# You can still override in Railway Variables if needed.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements
RUN set -eux; \
find ./extensions -name 'package.json' -type f | while read -r f; do \
sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# Add vdirsyncer + khal for CalDAV workflows
# + libasound2 is required by sag binary
RUN apt-get update \
&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
ca-certificates \
tini \
curl \
tar \
python3 \
python3-venv \
vdirsyncer \
khal \
libasound2 \
&& rm -rf /var/lib/apt/lists/*

# Install sag (ElevenLabs CLI TTS)
ARG SAG_VERSION=0.2.2
RUN set -eux; \
arch="$(dpkg --print-architecture)"; \
case "$arch" in \
amd64) sag_arch="linux_amd64" ;; \
arm64) sag_arch="linux_arm64" ;; \
*) echo "Unsupported arch: $arch" && exit 1 ;; \
esac; \
url="https://github.com/steipete/sag/releases/download/v${SAG_VERSION}/sag_${SAG_VERSION}_${sag_arch}.tar.gz"; \
curl -fL "$url" -o /tmp/sag.tar.gz; \
mkdir -p /tmp/sagx; \
tar -xzf /tmp/sag.tar.gz -C /tmp/sagx; \
install -m 0755 /tmp/sagx/sag /usr/local/bin/sag; \
rm -rf /tmp/sag.tar.gz /tmp/sagx; \
sag --version

# openclaw update expects pnpm. Provide it in runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Persist user-installed tools by default by targeting the Railway volume.
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built OpenClaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
&& chmod +x /usr/local/bin/openclaw

# Copy wrapper app
COPY src ./src

# IMPORTANT: copy your custom skills into runtime image
COPY skills ./skills

# The wrapper listens on $PORT.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "--"]
CMD ["node", "src/server.js"]
