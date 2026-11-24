# Plaud Local remote processing server. Standard library only, so there is nothing to install.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PLAUD_REMOTE_DATA_DIR=/data \
    PLAUD_REMOTE_PORT=8080

RUN useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin plaud \
    && mkdir -p /data && chown plaud:plaud /data

WORKDIR /app
COPY plaud_remote/ ./plaud_remote/

USER plaud
VOLUME ["/data"]
EXPOSE 8080

# With built-in TLS (PLAUD_REMOTE_TLS_CERT and _KEY set) the server only speaks HTTPS, so the check
# must too. It skips certificate checks: the certificate names the public host, not 127.0.0.1, and
# may come from a private CA this image doesn't trust.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import os,ssl,urllib.request; tls = bool(os.environ.get('PLAUD_REMOTE_TLS_CERT')); urllib.request.urlopen(('https' if tls else 'http') + '://127.0.0.1:' + os.environ.get('PLAUD_REMOTE_PORT', '8080') + '/healthz', timeout=3, context=ssl._create_unverified_context() if tls else None)"]

CMD ["python", "-m", "plaud_remote"]
