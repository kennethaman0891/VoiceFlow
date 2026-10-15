# ============================================================
# VoiceFlow — Development environment (Tauri build)
#
# All dependencies for building the Tauri desktop app in a
# clean, reproducible container. Use for CI or remote builds.
#
# Required system packages:
#   - Rust toolchain
#   - Node.js 18+
#   - WebKit2GTK, ALSA, OpenSSL (Tauri Linux deps)
#   - pkg-config, cmake, curl
#
# Build:
#   docker build -f docker/dev/Dockerfile -t voiceflow/dev .
#
# Run (interactive):
#   docker run -it --rm #     -v $(pwd)/tauri-app:/workspace/tauri-app #     -v voiceflow-cargo-cache:/root/.cargo/registry #     -v voiceflow-npm-cache:/workspace/tauri-app/node_modules #     -e GROQ_API_KEY=your_key_here #     voiceflow/dev #     bash
#
# Run (build):
#   docker run --rm #     -v $(pwd)/tauri-app:/workspace/tauri-app #     -v voiceflow-models:/workspace/tauri-app/src-tauri/models #     -v voiceflow-dist:/workspace/tauri-app/dist #     voiceflow/dev #     /workspace/scripts/build-tauri.sh
# ============================================================

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# ── System dependencies (Tauri + Rust + Node) ──────────────────
RUN apt-get update && apt-get install -y --no-install-recommends     # Tauri / WebKit
    libwebkit2gtk-4.1-dev     libayatana-appindicator3-dev     librsvg2-dev     libssl-dev     libasound2-dev     libxdo-dev     xdotool     # Build tools
    build-essential     curl     git     pkg-config     cmake     make     # Runtime
    ca-certificates     dbus     wget     unzip     && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r devuser && useradd -r -g devuser -d /home/devuser -s /bin/bash devuser &&     mkdir -p /home/devuser && chown -R devuser:devuser /home/devuser

# ── Rust toolchain ─────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Install Rust for non-root user as well
USER devuser
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/home/devuser/.cargo/bin:${PATH}"

# ── Node.js 20 (LTS) ──────────────────────────────────────────
USER root
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash -     && apt-get install -y nodejs     && npm install -g npm@latest

USER devuser

# ── Working directory ──────────────────────────────────────────
WORKDIR /workspace

# ── Helper scripts ─────────────────────────────────────────────
USER root
COPY scripts/ /workspace/scripts/
RUN chmod +x /workspace/scripts/*.sh

USER devuser

# ── Verify installs ───────────────────────────────────────────
RUN rustc --version && cargo --version && node --version && npm --version

# Default shell
SHELL ["/bin/bash", "-c"]
