#!/bin/sh
# perfloop's fake sysctl (tests): the fake remote Mac's model is FakeMac1,1, whatever machine runs the tests (a Linux
# container has no hw.model at all). Anything else goes to the real sysctl.
if [ "$*" = "-n hw.model" ]; then echo "FakeMac1,1"; exit 0; fi
for s in /usr/sbin/sysctl /sbin/sysctl /usr/bin/sysctl; do [ -x "$s" ] && exec "$s" "$@"; done
exit 1
