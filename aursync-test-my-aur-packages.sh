#!/bin/bash
##
## Configuration (1=enable, 0=disable)
##
declare status_bar=1  # use screen to show status bar
declare edit=1        # use vipe to edit packages to be updated
declare debug=0       # 1: output debug info, 2: pause after every package update
declare redownload=0  # 0: use ~/.cache/aurutils/cache 1: use /tmp/aurutils/cache
[ $# -gt 0 ] && export "$@"

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
    INTERNAL_INIT_SCRIPT=1 screen -mq -c "$screencfg" bash --norc -c "$0"
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
total="Nan"
set_status Nan 'Initializing build env...' 

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

start "total"
start "aurrpc"
readarray -t pkgs < <(auracle --searchby maintainer -F {pkgbase} search bartus|uniq)
readarray -t -O ${#pkgs[@]} pkgs < <(curl -sSL 'https://aur.archlinux.org/packages/?SeB=c&PP=250&K=bartus'|hq td:first-of-type text)
readarray -t pkgs < <(printf "%s\n" "${pkgs[@]}"|(((edit)) && vipe || cat))
stop "aurrpc"
total=${#pkgs[@]}
echo packages:${pkgs[@]} total:"$total" >&2
for pkg in "${pkgs[@]}"
  do
    #BUILDDIR=/tmp/pacaur pacaur --rebuild --noedit --noconfirm -m $pkg
    [ -z $i ] && i=1
    set_status $((i++)) "building $pkg..."
    start $pkg
    ((redownload)) && export AURDEST="/tmp/aurutils/sync"
    aur sync -L ${aursync_flags[@]} $pkg
    #aur sync -c -D /tmp/$(uname -m) --bind-rw=/home/_ccache:/build/.ccache --makepkg-conf=/etc/makepkg.conf.ccache --no-ver-shallow --no-view $pkg
    if [ "$?" -eq 0 ]
      then   ok+=(${pkg})
      else fail+=(${pkg})
    fi
    ((redownload)) && rm -rf $AURDEST/$pkg
    stop $pkg
  done
stop "total"
tee -a $HOME/AUR/.aursync-test.log < <(
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
)

# print info to history 
set -o history
history -s \#pkg_ok=${ok[@]}
history -s \#pkg_fail=${fail[@]}

((status_bar)) && { echo "press enter to continue..."; read; }

# vim:set sw=2 ts=2 et:
