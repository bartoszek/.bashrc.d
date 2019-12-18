#!/bin/bash

#ToDo:
# * add cpu utilization statistics (use $EPOCHREALTIME or /usr/bin/time -f {format} -o {output} $$)
# * probe pkgver in tmpfs for speed and reduce disk wear.
# * time `makepkg` stages in `aur sync` call (pipe to `ts -s [%.T]`|grep -P (prepare|build|package) )
# * refactor stop(): rename elapsed variable.
# * add info header to script (look CPF.sh)
# * add inline doc to functions
# * shellcheck fixes
# * allow for script to be sourced for function testing.

#unset ok fail; for pkg in `aur ^Crcmp-devel|vipe|cut -d: -f1`; do aursync-ccache --no-view $pkg && ok+=($pkg) || fail+=($pkg); done ; echo pkg-ok=${ok[@]}; echo pkg-fail=${fail[@]}

##
## Configuration (1=enable, 0=disable)
##
declare status_bar=1  # use screen to show status bar
declare edit=1        # use vipe to edit packages to be updated
declare debug=0       # 1: output debug info, 2: pause after every package update
[ $# -gt 0 ] && export $@

##
## Start: Add screen status bar
##

if ((status_bar)); then
  # Check if script was started in our screen session
  if [ -z "$INTERNAL_INIT_SCRIPT" ]; then
    # Create temporary screen config file to avoid conflicts with
    # user's .screenrc
    screencfg=$(mktemp)
    # Show status line at bottom of terminal
    echo hardstatus alwayslastline > "$screencfg"
    # Disable blanker (cmatrix screensaver)
    echo idle off >> "$screencfg"
    # Start script in a new screen session
    INTERNAL_INIT_SCRIPT=1 screen -h 100000 -mq -c "$screencfg" bash --norc -c "$0"
    # Store screen return code
    ret=$?
    # Remove temporary screen config file
    rm "$screencfg"
    # Exit with the same return code that screen exits with
    exit $ret
  fi
  
  function set_status {
    screen -X hardstatus string "[$1/$total] $2"
  }
else
  function set_status() {
    echo [$1/$total] $2 >&2
  }
fi 

##
## End: Add screen status bar
##

## Test if /tmp is allowing sudo file execution. If not remount.
mount -l -t tmpfs|grep -q "/tmp .*nosuid" && sudo mount -o remount,suid,size=32G /tmp/

shopt -s lastpipe
ok=()
fail=()
elapsed=()
declare -A start_time stop_time start_ccache stop_ccache
aursync_flags=(-c -D /tmp)                                                                      #clean container build
aursync_flags+=(-T)                                                                             #temp container per pacakge
aursync_flags+=(-f)                                                                             #force rebuild if package in the cache
aursync_flags+=(--bind-rw=/home/_ccache:/build/.ccache --makepkg-conf=/etc/makepkg.conf.ccache) #ccache
aursync_flags+=(--no-ver-shallow)                                                               #rebuild always
#aursync_flags+=(--no-ver)                                                                       #rabuild all deps
aursync_flags+=(--no-view)                                                                      #disable pkg review

# no longer vaible after build_env.patch
#aur chroot -B -D /tmp/x86_64 -M /etc/makepkg.conf.ccache -d aur-local-repo
#arch-nspawn /tmp/x86_64/root pacman --noconfirm -S ccache

now() { date +"%H:%M:%S"; }
now_ccache() { CCACHE_DIR=/home/_ccache ccache -s|sed -n -e 5,7p|grep -o "[0-9]*$"|(read hit_dir;read hit_pre;read miss; echo -e "$((hit_dir+hit_pre))\n$miss");}

start() { start_time[$1]=$(now); start_ccache[$1]=$(now_ccache); ((debug)) && echo $1: start=${start_time[$1]},ccache=${start_ccache[$1]} >&2 ; }

stop() {
  stop_time[$1]=$(now)
  stop_ccache[$1]=$(now_ccache)
  ((debug)) && echo "$1: stop=${stop_time[$1]},ccache=${stop_ccache[$1]}" >&2
  diff_time=$(datediff "${start_time[$1]}" "${stop_time[$1]}" -f "%H:%0M:%0S")
  ((debug)) && echo "$1: diff_time=$diff_time" >&2
  diff_ccache=($(paste <(echo "${stop_ccache[$1]}") <(echo "${start_ccache[$1]}")|while read -r a b; do echo $((a-b));done;))
  ((debug)) && echo "$1: diff_ccache=${diff_ccache[*]}" >&2
  rate_ccache=$(echo "${diff_ccache[@]}"|(read -r hit miss; bc -l <<<"if (($hit+$miss)>0) $hit/($hit+$miss)*100 else 0";))
  ((debug)) && echo "$1: rate_ccache=$rate_ccache" >&2
  bps=$(bc -l <<<"$(tr ' ' '+'<<<"${diff_ccache[@]}"|bc)/$(date -u -d "1970-1-1 $diff_time" +%s)"|sed 's/^\./0\./')
  ((debug)) && echo "$1: bps=$bps" >&2
  elapsed+=("$diff_time $1 ${rate_ccache} ${diff_ccache[*]} $bps")
  ((debug)) && echo "$1: elapsed=${elapsed[-1]}" >&2
  ((debug>1)) && read -rs -p "Press enter to continue"
}

vercmp-devel() {
  XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
  AURDEST=${AURDEST:-$XDG_CACHE_HOME/aurutils/sync}
  AURVCS=${AURVCS:-.*-(bzr|git|hg|svn)$}

  total="Nan"
  set_status "Nan" 'Probing AUR VCS packages...' 

  db_tmp=$(mktemp)
  latest_tmp=$(mktemp)
  trap 'rm -rf "$db_tmp" "$latest_tmp"' EXIT

  alias get_latest_revision="| xargs -r aur srcver"

  aur repo --list "$@" >"$db_tmp"

  if cd "$AURDEST"; then
    mapfile -t vcs < <(awk -v "mask=$AURVCS" '$1 ~ mask {print $1}' "$db_tmp"|grep -Fxf - <(printf '%s\n' *))
    total=${#vcs[@]}
    local i=0
    local limit=2
    for pkg in "${vcs[@]}"; do
      [ $(jobs -p|wc -l) -gt $limit ] && wait -n
      ((i++))
      { 
        set_status $i "Probing $pkg..."
        aur srcver "$pkg" >> "$latest_tmp"
      } &
    done  
    wait
    aur vercmp -p "$latest_tmp" <"$db_tmp"
  fi
}

total="Nan"
set_status "Nan" 'Probing AUR VCS packages...' 

start "total"
start "vercmp"
#readarray pkgs < <(aur vercmp-devel|(((edit)) && vipe || cat)|cut -d: -f1)
readarray pkgs < <(output=$(vercmp-devel) && (((edit)) && vipe <<<"$output" || echo "$output")|cut -d: -f1)
stop "vercmp"
total=${#pkgs[@]}
echo packages:${pkgs[@]} total:"$total" >&2
for pkg in "${pkgs[@]}"
  do
    #BUILDDIR=/tmp/pacaur pacaur --rebuild --noedit --noconfirm -m $pkg
    [ -z $i ] && i=1
    set_status $((i++)) "building $pkg..."
    start $pkg
    aur sync -L ${aursync_flags[@]} $pkg
    #aur sync -c -D /tmp/$(uname -m) --bind-rw=/home/_ccache:/build/.ccache --makepkg-conf=/etc/makepkg.conf.ccache --no-ver-shallow --no-view $pkg
    if [ "$?" -eq 0 ]
      then   ok+=(${pkg})
      else fail+=(${pkg})
    fi
    stop $pkg
  done
stop "total"

# print stats
((debug)) && \
  for key in ${!start_time[@]} ; do 
    echo $key: start_time=${start_time[$key]}, stop_time=${stop_time[$key]}, start_ccache=${start_ccache[$key]}, stop_ccache=${stop_ccache[$key]} >&2
  done 
padding_pkgname=$(for key in ${!stop_time[@]}; do wc -c <<<"$key";done|sort -n|tail -n1)
export LC_ALL=C # fix `bc` decimal format not working with `printf` when local decimal separator isn't dot.
printf "%8s\t%${padding_pkgname}s\t%6s%% (%4s:%-4s) %7s\n" "duration" "package name" "rate" "hit" "miss" "bps"
printf "%8s\t%${padding_pkgname}s\t%6.2f%% (%4d:%-4d) %7.2f\n" ${elapsed[@]}|datesort -i "%H:%M.%S"
echo pkg_ok=${ok[@]}
echo pkg_fail=${fail[@]} 

# print info to history 
set -o history
history -s \#pkg_ok=${ok[@]}
history -s \#pkg_fail=${fail[@]}

((status_bar)) && { echo "press enter to continue..."; read; }

# vim:set sw=2 ts=2 et:
