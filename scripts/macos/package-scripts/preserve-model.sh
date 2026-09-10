#!/bin/bash
# Called only after validating the installed Rime Q bundle and login user.
# as_login_user is supplied by preinstall, so personal files are never written as root.
preserve_rimeq_model() {
    local source="$1" directory="$2" expected="$3" actual temporary target
    [ -f "$source" ] && [ ! -L "$source" ] || return 0
    actual=$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo 'Rime Q: the previous model differs from this version; optional download remains available.'
        return 0
    fi
    target="$directory/wanxiang-lts-zh-hans.gram"
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 0
    temporary="$directory/.preserve-$(/usr/bin/uuidgen).gram"
    if as_login_user /bin/mkdir -p "$directory" \
        && as_login_user /bin/cp "$source" "$temporary" \
        && as_login_user /bin/mv -n "$temporary" "$target"; then
        echo 'Rime Q: preserved the enabled model in personal data.'
    else
        echo 'Rime Q: model preservation did not complete; optional download remains available.'
    fi
    as_login_user /bin/rm -f "$temporary" || true
}
