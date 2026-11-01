#!/bin/sh
# perfloop's fake rsync (tests): drops -e and the "host:" of remote paths (the fake remote is a local directory), then
# runs the real rsync.
n=$#; i=0
while [ $i -lt $n ]; do
  a=$1; shift; i=$((i + 1))
  case "$a" in
    -e) shift; i=$((i + 1)); continue ;;
    *:/*) a=${a#*:} ;;
  esac
  set -- "$@" "$a"
done
echo "rsync $*" >> "${FAKE_SSH_LOG:-/dev/null}"
exec /usr/bin/rsync "$@"
