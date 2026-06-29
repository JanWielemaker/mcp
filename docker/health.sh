#!/bin/bash
#  HEALTHCHECK script for the MCP help server container.
#
#  We don't ship a /health endpoint -- the only thing the server
#  speaks is JSON-RPC over POST /mcp/messages and the SSE GET.  An
#  `initialize` request is the cheapest valid round-trip: any
#  2xx + parseable JSON reply means the dispatcher is up.

exec &> /tmp/health.log

POST_URL="http://localhost:3410/mcp/messages"

read -r -d '' INITIALIZE <<'JSON'
{ "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "healthcheck", "version": "0" }
  }
}
JSON

curl --fail -s --retry 2 --max-time 5 \
     -H 'Content-Type: application/json' \
     --data-binary "$INITIALIZE" \
     "$POST_URL" \
     | grep -q '"jsonrpc":"2.0"'
