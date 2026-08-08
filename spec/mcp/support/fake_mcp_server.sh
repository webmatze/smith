#!/bin/bash
#
# A minimal MCP server over stdio, for the specs that need a *real* process:
# orphan cleanup, restart-after-crash, a command that never answers.
#
# Deliberately not Node and not Crystal — the test suite must not depend on an
# external MCP server, and it must not compile a second binary to run.
#
# Behaviour is steered through the environment:
#   FAKE_PID_FILE      write the server's pid here on startup
#   FAKE_LABEL         appended to every tool result
#   FAKE_CRASH_ON_CALL exit non-zero on the Nth tools/call, every time
#   FAKE_CRASH_ONCE    path to a marker file; crash on the first call unless it
#                      exists — so a restarted process serves the retry
#   FAKE_TOOL_NAME     name of the single exported tool (default: echo)
#   FAKE_SILENT        accept the connection but never answer anything

[ -n "$FAKE_PID_FILE" ] && printf '%s' "$$" > "$FAKE_PID_FILE"

tool=${FAKE_TOOL_NAME:-echo}
calls=0

while IFS= read -r line; do
  [ -n "$FAKE_SILENT" ] && continue

  # The client always sends a numeric id first; this is enough to echo it back.
  id=${line#*\"id\":}
  id=${id%%,*}

  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"bashfake","version":"1"}}}\n' "$id"
      ;;
    *'"method":"tools/list"'*)
      # The schema uses a nested $ref on purpose: passing those through
      # untouched is what stage 1 promises.
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"%s","description":"Echo text back","inputSchema":{"type":"object","properties":{"text":{"$ref":"#/$defs/t"}},"$defs":{"t":{"type":"string"}}}}]}}\n' "$id" "$tool"
      ;;
    *'"method":"tools/call"'*)
      calls=$((calls + 1))
      if [ -n "$FAKE_CRASH_ON_CALL" ] && [ "$calls" -ge "$FAKE_CRASH_ON_CALL" ]; then
        exit 3
      fi
      if [ -n "$FAKE_CRASH_ONCE" ] && [ ! -f "$FAKE_CRASH_ONCE" ]; then
        : > "$FAKE_CRASH_ONCE"
        exit 3
      fi
      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"pong%s"}]}}\n' "$id" "${FAKE_LABEL:+ $FAKE_LABEL}"
      ;;
  esac
done
