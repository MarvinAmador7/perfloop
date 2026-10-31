#!/bin/sh
# perfloop's fake `open` (tests): `open -W -n -g APP --args …` runs APP's executable with the arguments and waits, as
# LaunchServices would in the console user's session.
app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --args) shift; break ;;
    -*) shift ;;
    *) app=$1; shift ;;
  esac
done
exe=$(sed -n 's:.*<key>CFBundleExecutable</key><string>\([^<]*\)</string>.*:\1:p' "$app/Contents/Info.plist")
echo "open $app ($exe) $*" >> "${FAKE_SSH_LOG:-/dev/null}"
"$app/Contents/MacOS/$exe" "$@"
