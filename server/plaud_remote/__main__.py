"""Entry point: `python -m plaud_remote`."""

from __future__ import annotations

import logging
import os
import secrets
import signal
import ssl
import sys
import threading

from . import __version__
from .store import Store
from .web import Application, Server
from .worker import WorkerPool

log = logging.getLogger("plaud_remote")


def build(
    data_dir: str,
    *,
    admin_password: str | None = None,
    max_upload_mb: int = 500,
    workers: int = 1,
    backoff_base: float = 15.0,
    poll_interval: float = 1.0,
) -> tuple[Application, WorkerPool, Store]:
    """Wire up the store, workers and request handling (nothing started, no socket bound)."""
    store = Store(data_dir)
    if not admin_password and store.admin_password_hash() is None:
        generated = secrets.token_urlsafe(12)
        store.set_admin_password(generated)
        # Shown once, on first start only; set PLAUD_REMOTE_ADMIN_PASSWORD to choose your own.
        print(f"\n  Web UI sign-in:  user 'admin'  password '{generated}'\n", flush=True)
    store.app_token()  # create the app token on first start
    pool = WorkerPool(store, workers=workers, backoff_base=backoff_base, poll_interval=poll_interval)
    app = Application(store, pool, admin_password=admin_password, max_upload_bytes=max_upload_mb * 1024 * 1024)
    return app, pool, store


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("PLAUD_REMOTE_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    app, pool, store = build(
        os.environ.get("PLAUD_REMOTE_DATA_DIR", "/data"),
        admin_password=os.environ.get("PLAUD_REMOTE_ADMIN_PASSWORD") or None,
        max_upload_mb=int(os.environ.get("PLAUD_REMOTE_MAX_UPLOAD_MB", "500")),
        workers=int(os.environ.get("PLAUD_REMOTE_WORKERS", "1")),
    )
    server = Server(
        (os.environ.get("PLAUD_REMOTE_HOST", "0.0.0.0"), int(os.environ.get("PLAUD_REMOTE_PORT", "8080"))),
        app,
    )
    cert, key = os.environ.get("PLAUD_REMOTE_TLS_CERT"), os.environ.get("PLAUD_REMOTE_TLS_KEY")
    if cert and key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    elif cert or key:
        raise SystemExit("Set both PLAUD_REMOTE_TLS_CERT and PLAUD_REMOTE_TLS_KEY, or neither")
    pool.start()

    def shutdown(*_: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    host, port = server.server_address[:2]
    log.info(
        "plaud-remote %s listening on %s://%s:%s", __version__, "https" if cert else "http", host, port
    )
    if not cert:
        log.info("Serving plain HTTP: the app only connects over HTTPS, so put a TLS proxy in front")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        pool.stop()
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
