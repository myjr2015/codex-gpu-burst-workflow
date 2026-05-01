# syntax=docker/dockerfile:1.7

FROM vastai/comfy:v0.19.3-cuda-12.9-py312

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_TIMEOUT=1800 \
    PIP_RETRIES=20 \
    KJ_ENV_IMAGE=1 \
    KJ_CUSTOM_NODE_SEED_DIR=/opt/codex/kj-custom_nodes

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ffmpeg \
        git \
    && rm -rf /var/lib/apt/lists/*

COPY install-kj-env.sh /opt/codex/install-kj-env.sh

RUN chmod +x /opt/codex/install-kj-env.sh \
    && /opt/codex/install-kj-env.sh

LABEL org.opencontainers.image.title="codex-wan22-kj-comfy" \
      org.opencontainers.image.description="Wan2.2 KJ ComfyUI environment image without model weights. v2 records torch compatibility and preinstalls missing torch auxiliary packages without forcing torch reinstall." \
      org.opencontainers.image.version="cuda129-py312-kj-v2" \
      org.opencontainers.image.base.name="vastai/comfy:v0.19.3-cuda-12.9-py312"
