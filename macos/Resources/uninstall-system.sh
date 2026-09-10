#!/bin/bash
set -eu
# Called only after the app's uninstall confirmation and macOS authentication.
APP='/Library/Input Methods/RimeQ.app'
if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    echo 'The installed Rime Q application is unavailable.' >&2
    exit 1
fi
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$identifier" = 'com.asmoyou.inputmethod.RimeQ' ] || exit 1
case "${1:-}" in
    --dry-run) echo "Would remove only $APP; personal dictionaries are retained."; exit 0 ;;
    '') ;;
    *) exit 2 ;;
esac
[ "$(/usr/bin/id -u)" -eq 0 ] || exit 1
/bin/rm -rf "$APP"
[ ! -e "$APP" ]
/usr/sbin/pkgutil --forget com.asmoyou.inputmethod.RimeQ >/dev/null 2>&1 || true
