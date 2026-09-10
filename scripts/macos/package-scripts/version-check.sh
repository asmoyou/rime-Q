#!/bin/bash
# Also run in preinstall: GUI checks alone cannot protect command-line installs.
rimeq_compare_versions() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, av, /[.]/); split(b, bv, /[.]/);
        for (i = 1; i <= 3; i++) {
            if (av[i] + 0 < bv[i] + 0) { print -1; exit }
            if (av[i] + 0 > bv[i] + 0) { print 1; exit }
        }
        print 0;
    }'
}

rimeq_install_action() {
    local release_order build_order
    if [ -z "$1" ] && [ -z "$2" ]; then printf '%s\n' install; return; fi
    release_order=$(rimeq_compare_versions "$1" "$3") || return 1
    build_order=$(rimeq_compare_versions "$2" "$4") || return 1
    if [ "$release_order" -gt 0 ] || { [ "$release_order" -eq 0 ] && [ "$build_order" -gt 0 ]; }; then
        printf '%s\n' downgrade
    elif [ "$release_order" -lt 0 ]; then
        printf '%s\n' upgrade
    else
        printf '%s\n' repair
    fi
}
