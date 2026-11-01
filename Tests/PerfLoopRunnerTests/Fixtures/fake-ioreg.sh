#!/bin/sh
# perfloop's fake ioreg (tests): the fake remote Mac's HIDIdleTime ($FAKE_REMOTE_IDLE s, default 1000) and its screen
# lock (locked while the file $FAKE_REMOTE_LOCKED exists).
case "$*" in
  *IOHIDSystem*) echo "    | |   \"HIDIdleTime\" = $(awk -v s="${FAKE_REMOTE_IDLE:-1000}" 'BEGIN { printf "%d", s * 1000000000 }')" ;;
  *Root*)
    l=false; if [ -n "$FAKE_REMOTE_LOCKED" ] && [ -f "$FAKE_REMOTE_LOCKED" ]; then l=true; fi
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>IOConsoleUsers</key><array><dict>
<key>CGSSessionScreenIsLocked</key><$l/><key>kCGSSessionUserNameKey</key><string>mar</string>
</dict></array></dict></plist>
PLIST
    ;;
esac
