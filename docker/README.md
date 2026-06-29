# MCP help server -- Docker build

Production-deployment recipe for hosting the MCP help server (the
read-only introspection suite) on `www.swi-prolog.org` (or any other
reachable host).

The container builds SWI-Prolog from `swipl-devel` and the MCP pack
from `JanWielemaker/MCP`, then runs `examples/swipl_help_public.pl`
under `library(http/http_unix_daemon)`.  That loader registers the
four read-only server modules only:

  - `library(mcp/servers/prolog_help)`  -- manual, xref, pldoc
  - `library(mcp/servers/swipl_kernel)` -- C source grep
  - `library(mcp/servers/source)`       -- file listing / reading / grep
  - `library(mcp/servers/git)`          -- log / blame / show / diff / grep

It deliberately omits `target_toplevel` (spawns child processes) and
`dev_reload` (calls `make/0` in-process) -- those are appropriate
only in a trusted developer loop.

## Build & run

```
make image    # build the mcp-help image
make run      # detached container on port 3410 (host)
make logs     # follow the swipl stdout
make restart  # stop + rm + run, picking up any image rebuild
make stop     # stop + rm
```

The container listens on TCP 3410 inside; the published port defaults
to 3410 on the host and is overridable with `make run PORT=...`.
Endpoints (per the MCP 2024-11-05 transport):

  - `POST /mcp/messages` -- JSON-RPC request, JSON reply + `Mcp-Session-Id` header
  - `GET  /mcp/sse`      -- long-lived SSE stream for notifications

## Rebuilding individual layers

Bump the corresponding `ENV` line in `Dockerfile` so Docker rebuilds
just that layer (and everything after it):

```
make update-swipl   # rebuild swipl + MCP layers
make update-mcp     # rebuild MCP layer only
```

Both targets `sed` today's date into the matching `_VERSION` line and
then `docker build`.

## Health check

`HEALTHCHECK` POSTs an `initialize` request through to
`/mcp/messages`; the container is unhealthy when the dispatcher can't
respond to a valid JSON-RPC request within 5 s.  Health-check output
goes to `/tmp/health.log` inside the container.

## Behind a reverse proxy

For deployment on `www.swi-prolog.org`, terminate TLS in nginx and
proxy `/mcp/messages` and `/mcp/sse` to `http://localhost:3410`.  The
SSE handler holds the connection open indefinitely with a 15 s
heartbeat; configure the proxy with a matching or larger read
timeout (`proxy_read_timeout 1d;` is typical) and disable response
buffering for the SSE location:

```
location /mcp/sse {
    proxy_pass             http://localhost:3410;
    proxy_buffering        off;
    proxy_read_timeout     1d;
    proxy_http_version     1.1;
    proxy_set_header       Connection "";
}
```
