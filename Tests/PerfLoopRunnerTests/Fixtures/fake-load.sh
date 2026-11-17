#!/bin/sh
# perfloop's fake iostat and ps (tests, linked under both names): the fake remote Mac's load, for the quiet gate. It is
# read from the file $FAKE_REMOTE_LOAD (`load=35 busy=swift-frontend:98,clang:40`, as the idle file's quiet keys); no
# file: a quiet Mac (3 % of the cores busy, nothing running). `ps` adds the ssh session's own sshd, which the runner
# leaves out.
load=3; busy=""
if [ -n "$FAKE_REMOTE_LOAD" ] && [ -f "$FAKE_REMOTE_LOAD" ]; then
  for kv in $(cat "$FAKE_REMOTE_LOAD"); do case "$kv" in load=*) load=${kv#load=} ;; busy=*) busy=${kv#busy=} ;; esac; done
fi
case "$(basename "$0")" in
  iostat)
    echo "      cpu    load average"; echo " us sy id   1m   5m   15m"; echo "  1  1 98  0.10 0.10 0.10"
    awk -v l="$load" 'BEGIN { printf "%3d %2d %2d  0.50 0.40 0.30\n", l, 0, 100 - l }' ;;
  ps)
    case "$*" in *pid=*) withpid=1 ;; *) withpid=0 ;; esac
    pid=100
    for p in $(echo "$busy" | tr ',' ' '); do
      pid=$((pid + 1)); name=${p%%:*}; pct=${p#*:}
      if [ $withpid = 1 ]; then echo "$pid $pct /usr/bin/$name"; else echo "$pct /usr/bin/$name"; fi
    done
    if [ $withpid = 1 ]; then echo "99 40.0 /usr/sbin/sshd-session"; fi ;;
esac
