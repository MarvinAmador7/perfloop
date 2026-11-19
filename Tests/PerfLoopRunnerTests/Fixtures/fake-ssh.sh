#!/bin/sh
# perfloop's fake ssh (tests): "the remote Mac" is a directory. Runs the remote command locally with HOME=$FAKE_REMOTE_HOME
# and $FAKE_BIN (a fake `open`) first on PATH. FAKE_SSH_FAIL=auth|hostkey|changed|refused|timeout prints what real ssh
# prints for those and exits 255. Every call is logged to $FAKE_SSH_LOG.
op=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-l|-F) shift 2 ;;
    -O) op=$2; shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1; shift
if [ -n "$op" ]; then echo "control $op $host" >> "${FAKE_SSH_LOG:-/dev/null}"; exit 0; fi
case "$FAKE_SSH_FAIL" in
  auth) echo "$host: Permission denied (publickey,password,keyboard-interactive)." >&2; exit 255 ;;
  hostkey) printf 'No ED25519 host key is known for %s and you have requested strict checking.\nHost key verification failed.\n' "$host" >&2; exit 255 ;;
  changed) printf '@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.\n' >&2; exit 255 ;;
  refused) echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255 ;;
  timeout) echo "ssh: connect to host $host port 22: Operation timed out" >&2; exit 255 ;;
esac
echo "ssh $host $*" >> "${FAKE_SSH_LOG:-/dev/null}"
# FAKE_SSH_DROP=FILE: while FILE exists, a rep's connection drops (once per FILE): the rep goes on "there" in the
# background, as one in the GUI session does, and ssh exits 255.
case "$*" in *rep.sh*)
  if [ -n "$FAKE_SSH_DROP" ] && [ -f "$FAKE_SSH_DROP" ]; then
    rm -f "$FAKE_SSH_DROP"; in=$(mktemp); cat > "$in"
    (HOME="$FAKE_REMOTE_HOME" PATH="$FAKE_BIN:$PATH" /bin/sh -c "$*" < "$in"; rm -f "$in") > /dev/null 2>&1 &
    echo "Connection to $host closed by remote host." >&2; exit 255
  fi ;;
esac
HOME="$FAKE_REMOTE_HOME" PATH="$FAKE_BIN:$PATH" exec /bin/sh -c "$*"
