FROM vastai/comfy:v0.19.3-cuda-12.9-py312

SHELL ["/bin/bash", "-lc"]

ENV COMFY_ROOT=/workspace/ComfyUI \
    PREWARM_ROOT=/opt/wan22-prewarm \
    PREWARMED_IMAGE=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

WORKDIR /tmp/wan22-root-canvas

COPY docker/wan22-root-canvas/requirements-extra.txt /tmp/wan22-root-canvas/requirements-extra.txt
COPY docker/wan22-root-canvas/install_custom_nodes.py /tmp/wan22-root-canvas/install_custom_nodes.py

RUN python3 -m pip install --upgrade pip setuptools wheel && \
    python3 -m pip install --index-url https://download.pytorch.org/whl/cu124 torch torchvision torchaudio && \
    python3 -m pip install -r /tmp/wan22-root-canvas/requirements-extra.txt && \
    COMFY_ROOT=/opt/wan22-prewarm python3 /tmp/wan22-root-canvas/install_custom_nodes.py && \
    mkdir -p /opt/wan22-prewarm/custom_nodes && \
    mkdir -p /workspace/ComfyUI/input /workspace/ComfyUI/output /workspace/ComfyUI/models /workspace/ComfyUI/custom_nodes && \
    python3 -m pip cache purge || true && \
    rm -rf /root/.cache /tmp/wan22-root-canvas
