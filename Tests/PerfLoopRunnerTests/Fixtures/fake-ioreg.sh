#!/bin/sh
# perfloop's fake ioreg (tests): the fake remote Mac's HIDIdleTime ($FAKE_REMOTE_IDLE s, default 1000) and its screen
# lock (locked while the file $FAKE_REMOTE_LOCKED exists). With $FAKE_REMOTE_TOUCH set, every idle reading is logged
# to $FAKE_REMOTE_TOUCH.reads, and a reading taken while the file $FAKE_REMOTE_TOUCH exists is 0 s (input just now; the
# file is used up), as the fake adapter's "touch" during a rep.
case "$*" in
  *IOHIDSystem*)
    idle=${FAKE_REMOTE_IDLE:-1000}
    if [ -n "$FAKE_REMOTE_TOUCH" ]; then
      echo read >> "$FAKE_REMOTE_TOUCH.reads"
      if [ -f "$FAKE_REMOTE_TOUCH" ]; then rm -f "$FAKE_REMOTE_TOUCH"; idle=0; fi
    fi
    echo "    | |   \"HIDIdleTime\" = $(awk -v s="$idle" 'BEGIN { printf "%d", s * 1000000000 }')" ;;
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
