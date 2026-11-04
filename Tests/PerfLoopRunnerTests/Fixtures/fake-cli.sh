#!/bin/sh
# A fake `perfloop` for the MCP server's tests: logs its arguments to $FAKE_CLI_LOG, answers headless verbs at once,
# and "runs" a stage for $FAKE_CLI_SLEEP seconds (default 1), printing progress. `exp promote 9999` fails (exit 6).
echo "$*" >> "${FAKE_CLI_LOG:-/dev/null}"
case "$1 $2" in
  "exp status") echo "champion 0000 · no open experiments" ;;
  "exp screen"|"exp full"|"exp new"|"profile "*|"guards "*)
    echo "perfloop: $1 $2 pair 1" >&2; sleep "${FAKE_CLI_SLEEP:-1}"; echo "exp 0001 · promising" ;;
  "exp promote") if [ "$3" = 9999 ]; then echo "perfloop: refused: not won" >&2; exit 6; fi; echo "exp $3 · promoted" ;;
  *) echo "ok: $*" ;;
esac
