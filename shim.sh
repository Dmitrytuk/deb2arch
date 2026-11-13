#!/bin/bash
# deb2arch compatibility shim.
# Installed under the names of Debian-only commands (apt-key, invoke-rc.d, ...) and
# placed at the END of PATH while a carried-over Debian maintainer script runs, so a
# real Arch tool with the same name (e.g. killall from psmisc) always wins.
#
# Policy: Arch packages do not start/enable services or touch package-manager
# state from scriptlets, so most Debian helpers are safe no-ops here.

cmd="${0##*/}"

case "$cmd" in
  invoke-rc.d|deb-systemd-invoke)
    # invoke-rc.d <service> <action>   |   deb-systemd-invoke <action> <unit>
    args=(); for a in "$@"; do [[ $a == -* ]] || args+=("$a"); done
    if [[ $cmd == invoke-rc.d ]]; then svc="${args[0]}"; act="${args[1]}"
    else act="${args[0]}"; svc="${args[1]}"; fi
    # Only "stop" is honoured; start/restart are left to the user (Arch policy).
    if [[ $act == stop && -n $svc ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl stop "${svc%.service}" 2>/dev/null || true
    fi
    exit 0 ;;

  killall)
    # minimal fallback when psmisc is not installed: killall [-q] [-w] name... -> pkill -x
    for a in "$@"; do [[ $a == -* ]] || pkill -x "$a" 2>/dev/null; done
    exit 0 ;;

  addgroup)
    sys=(); pos=()
    for a in "$@"; do
      case "$a" in --system) sys=(-r);; -*) ;; *) pos+=("$a");; esac
    done
    if (( ${#pos[@]} == 2 )); then usermod -aG "${pos[1]}" "${pos[0]}"; exit 0; fi   # addgroup USER GROUP
    [[ -n ${pos[0]:-} ]] && { getent group "${pos[0]}" >/dev/null || groupadd "${sys[@]}" "${pos[0]}"; }
    exit 0 ;;

  adduser)
    opts=(); pos=(); grp=""; ingroup=""; system=0; nohome=0
    while (($#)); do
      case "$1" in
        --system) system=1; opts+=(-r);;
        --group) grp=1;;
        --home) opts+=(-d "$2"); shift;;
        --shell) opts+=(-s "$2"); shift;;
        --ingroup) ingroup="$2"; shift;;
        --no-create-home) nohome=1;;
        --gecos|--uid|--gid|--firstuid|--lastuid|--conf) shift;;
        -*) ;;
        *) pos+=("$1");;
      esac
      shift
    done
    if (( ${#pos[@]} == 2 )); then usermod -aG "${pos[1]}" "${pos[0]}"; exit 0; fi   # adduser USER GROUP
    u="${pos[0]:-}"; [[ -n $u ]] || exit 0
    getent passwd "$u" >/dev/null && exit 0
    if [[ -n $grp ]]; then
      getent group "$u" >/dev/null || groupadd $( ((system)) && echo -r ) "$u"
      ingroup="${ingroup:-$u}"
    fi
    [[ -n $ingroup ]] && opts+=(-g "$ingroup")
    ((system || nohome)) || opts+=(-m)
    useradd "${opts[@]}" "$u"
    exit 0 ;;

  *)
    # apt-key, apt-get, update-rc.d, deb-systemd-helper, update-alternatives, ucf, ...
    echo "deb2arch: '$cmd $*' skipped (Debian-specific, no Arch equivalent)" >&2
    exit 0 ;;
esac
