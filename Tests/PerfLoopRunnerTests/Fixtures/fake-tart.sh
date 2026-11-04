#!/bin/sh
# perfloop's fake tart (tests): one VM named in $FAKE_TART_VM, its state in the file $FAKE_TART_STATE ("running" while a
# `run` is alive), every call logged to $FAKE_TART_LOG. `run` stays up until `stop` or a signal, as tart does.
echo "$*" >> "${FAKE_TART_LOG:-/dev/null}"
state() { cat "$FAKE_TART_STATE" 2>/dev/null || echo stopped; }
case "$1" in
  list) printf '[{"Name":"%s","State":"%s","Source":"OCI"}]\n' "$FAKE_TART_VM" "$(state)" ;;
  run) echo running > "$FAKE_TART_STATE"; trap 'echo stopped > "$FAKE_TART_STATE"; exit 0' TERM INT
       while [ "$(state)" = running ]; do sleep 0.1; done ;;
  ip) [ "$(state)" = running ] && echo 192.168.64.9 || { echo "VM is not running" >&2; exit 1; } ;;
  stop) echo stopped > "$FAKE_TART_STATE" ;;
  *) echo "fake tart: $1?" >&2; exit 1 ;;
esac
