FROM python:3.12-slim

# Labels for container metadata
LABEL maintainer="meshbridge" \
      description="MeshBridge — Meshtastic ↔ Telegram gateway" \
      version="0.1.0"

# Install tini (PID 1 init) for signal handling
RUN apt-get update && \
    apt-get install -y --no-install-recommends tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first (cache-friendly layer ordering)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy upstream application code and project files
COPY upstream/ ./upstream/
COPY entrypoint.sh ./
RUN chmod +x /app/entrypoint.sh
COPY mock-meshtastic.py ./upstream/

# Create non-root user and data directory
RUN groupadd -r meshbridge && \
    useradd -r -g meshbridge -d /app -s /sbin/nologin meshbridge && \
    mkdir -p /app/data && \
    chown -R meshbridge:meshbridge /app

USER meshbridge

# Set working directory to upstream so `python mesh.py` works directly
WORKDIR /app/upstream

EXPOSE 5000

# Health check: verify Flask webapp is responsive on port 5000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/')" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
