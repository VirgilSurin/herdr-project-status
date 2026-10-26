#!/bin/zsh -f
# Project bar: a live, few-rows-high view of the focused pane's project status,
# running in its own pane at the bottom of the tab (opened/closed by the `bar`
# action, see project-status.sh). It follows focus within its tab, counts the
# AWS session down on its own, and redraws only when the output changes.
# Keys: q closes the bar, r forces a redraw.
#
# Content comes from section functions named _ps_section_<name>, each adding
# one or more rows to $out (use `row`), from the followed pane's state in $st
# (assoc) and $env_entries. PS_BAR_SECTIONS picks and orders them; define your
# own in ~/.config/herdr-project-status/config.zsh (see config.example.zsh).

zmodload zsh/datetime zsh/mapfile zsh/zselect
setopt extendedglob

herdr=${HERDR_BIN_PATH:-herdr}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-project-status
tab=${PS_TAB_ID:-}
target=${PS_TARGET_PANE:-}
self=${HERDR_PANE_ID:-}
reg=${tab:+$state_dir/bars/$tab}

typeset -ga PS_BAR_SECTIONS=(project aws env)
typeset -gi PS_MAX_LEN=24
typeset -g  PS_PROD_PATTERN='*[Pp]rod*' PS_PROD_EXCLUDE='*[Nn]o[Pp]rod*'
cfg=${PS_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-project-status/config.zsh}
[[ -r $cfg ]] && source $cfg

# catppuccin mocha
rgb() { REPLY=$'\e[38;2;'$1';'$2';'$3'm' }
B=$'\e[1m' R=$'\e[0m'
rgb 249 226 175; YEL=$REPLY
rgb 243 139 168; RED=$REPLY
rgb 166 227 161; GRN=$REPLY
rgb 137 180 250; BLU=$REPLY
rgb 108 112 134; DIM=$REPLY
rgb 205 214 244; TXT=$REPLY
PROD=$'\e[1;38;2;255;255;255;48;2;61;0;0m'

typeset -gi cols=80 rows=3
size() {
  local s
  s=$(stty size 2>/dev/null) && { rows=${s% *} cols=${s#* } }
  (( cols > 10 )) || cols=80
  (( rows > 0 ))  || rows=3
}

# row <label> [<color> <text>]... : one bar row, cut to the bar width.
# The label is a short blue column (AWS, ENV, ...); pass "" for none.
typeset -gi lw=4
row() {
  local label=$1 color text line plain
  shift
  line=" $B$BLU${(r:lw:)label}$R " plain=" ${(r:lw:)label} "
  while (( $# >= 2 )); do
    color=$1 text=$2
    shift 2
    local -i room=$(( cols - $#plain - 1 ))
    (( room > 0 )) || break
    (( $#text > room )) && text="${text[1,room-1]}…"
    line+="$color$text$R" plain+=$text
  done
  out+=("$line")
  REPLY=$plain
}

left_text() {  # seconds → "42m left", "3h05m left", "2d left", "expired"
  local -i s=$1
  if   (( s <= 0 ));     then REPLY=expired
  elif (( s < 3600 ));  then REPLY="$(( s / 60 ))m left"
  elif (( s < 86400 )); then printf -v REPLY '%dh%02dm left' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else                       REPLY="$(( s / 86400 ))d left"
  fi
}

# Project name + path on the left, "updated …" pushed to the right edge.
_ps_section_project() {
  local name dir=${st[cwd]:-} ago="updated just now"
  [[ -n ${st[config]:-} ]] && name=${st[config]:h:t} || name=${dir:t}
  local -i age=$(( EPOCHSECONDS - ${st[updated]:-$EPOCHSECONDS} ))
  (( age >= 60 ))   && ago="updated $(( age / 60 ))m ago"
  (( age >= 3600 )) && ago="updated $(( age / 3600 ))h ago"
  local left=" $B$TXT${name:-?}$R  " plain=" ${name:-?}  " where=${dir/#$HOME/\~} gap
  local -i room=$(( cols - $#plain - $#ago - 3 ))
  if (( room < 4 )); then where=""
  elif (( $#where > room )); then where="…${where[-room+1,-1]}"
  fi
  plain+=$where
  local -i pad=$(( cols - $#plain - $#ago - 1 ))
  (( pad < 1 )) && { pad=1; ago="" }
  printf -v gap '%*s' $pad ''
  out+=("$left$DIM$where$R$gap$DIM$ago$R")
}

_ps_section_aws() {
  local profile=${st[aws_profile]:-} exp=${st[aws_expires]:-}
  local -a segs
  if [[ -z $profile ]]; then row AWS $DIM "no profile"; return; fi
  if [[ $profile == ${~PS_PROD_PATTERN} && $profile != ${~PS_PROD_EXCLUDE} ]]; then
    segs=($PROD " ⚠ PROD " "" " " $B$RED $profile)
  else
    segs=($YEL $profile)
  fi
  if [[ -n $exp ]]; then
    local src
    case ${st[aws_src]:-} in
      "sso session") src=sso ;;
      credentials)   src=creds ;;
      *)             src=session ;;
    esac
    left_text $(( exp - EPOCHSECONDS ))
    if [[ $REPLY == expired ]]; then
      segs+=($DIM " · " $RED "$src expired")
    else
      local when; strftime -s when '%H:%M' $exp
      (( exp - EPOCHSECONDS > 86400 )) && strftime -s when '%b %d' $exp
      segs+=($DIM " · " $TXT "$src $REPLY" $DIM " (until $when)")
    fi
  else
    segs+=($DIM " · no expiry known")
  fi
  row AWS "${segs[@]}"
}

# Entries flow left to right and wrap onto spare rows (rows the remaining
# sections don't need); whatever still does not fit is cut with "…".
_ps_section_env() {
  if [[ -z ${st[config]:-} ]]; then row ENV $DIM "no project.config"; return; fi
  if (( ! $#env_entries )); then row ENV $DIM "project.config is empty"; return; fi
  local -i spare=$(( rows - $#out - sections_left ))
  (( spare < 1 )) && spare=1
  local e label value color
  local -a segs
  local -i used=$(( lw + 2 )) n=1 len
  local first=1 lab=ENV
  for e in $env_entries; do
    label=${e%%=*} value=${e#*=}
    (( $#value > PS_MAX_LEN )) && value="${value[1,PS_MAX_LEN-1]}…"
    case $value in
      ✓) color=$GRN ;; ✗) color=$RED ;; –) color=$DIM ;; *) color=$TXT ;;
    esac
    len=$(( (first ? 0 : 3) + $#label + 1 + $#value ))
    if (( ! first && used + len > cols - 1 && n < spare )); then
      row "$lab" "${segs[@]}"; segs=() lab="" first=1 used=$(( lw + 2 )) n+=1
      len=$(( $#label + 1 + $#value ))
    fi
    (( first )) || segs+=($DIM " · ")
    segs+=($DIM "$label " $color $value)
    used+=len first=0
  done
  row "$lab" "${segs[@]}"
}

typeset -gA st
typeset -ga env_entries out
typeset -gi sections_left=0
load_state() {  # load_state <pane>
  st=() env_entries=()
  local f=$state_dir/$1 line
  [[ -n $1 && -f $f ]] || return 1
  for line in ${(f)mapfile[$f]}; do
    if [[ $line == detail.env=* ]]; then env_entries+=(${line#detail.env=})
    else st[${line%%=*}]=${line#*=}
    fi
  done
  (( ${+st[aws_profile]} )) || legacy_aws
}

# Shells still running the v0.1 hook only write the formatted aws fields;
# recover profile, source and expiry from them.
legacy_aws() {
  local d=${st[detail.aws]:-} t
  st[aws_profile]=${${st[aws_prod]:-${st[aws]:-}}%% · *}
  [[ $d == *"· credentials"* ]] && st[aws_src]=credentials
  [[ $d == *"· sso session"* ]] && st[aws_src]="sso session"
  if [[ $d =~ '(until|expired at) ([0-9-]+ [0-9:]+)' ]] && strftime -r -s t '%Y-%m-%d %H:%M' ${match[2]}; then
    st[aws_expires]=$t
  fi
}

render() {
  out=()
  if ! load_state $target; then
    out=(" ${B}Project$R  ${DIM}no status for this pane yet — press enter in its shell$R")
    return
  fi
  local s
  local -i i=0
  for s in $PS_BAR_SECTIONS; do
    (( i++ ))
    sections_left=$(( $#PS_BAR_SECTIONS - i ))
    (( $+functions[_ps_section_$s] )) && _ps_section_$s
  done
}

typeset -g last=""
draw() {
  local frame=${(pj:\n:)out}
  [[ $frame == $last ]] && return
  last=$frame
  # Home, rewrite each row clearing its tail, then clear below: no flicker.
  # No newline after the last row, so the bar never scrolls.
  local line buf=$'\e[H'
  for line in "${(@)out[1,rows]}"; do buf+="$line"$'\e[K\n'; done
  print -rn -- "${buf%$'\n'}"$'\e[J'
}

# Follow the focused pane of our tab; keep the last one while the bar itself
# has focus.
follow() {
  local json
  json=$("$herdr" pane layout --pane ${self:-$target} 2>/dev/null) || return
  [[ $json =~ '"focused_pane_id":"([^"]+)"' ]] || return
  [[ ${match[1]} != $self ]] && target=${match[1]}
}

cleanup() {
  print -n $'\e[?25h'
  [[ -n $reg && -f $reg && $(<$reg) == $self ]] && rm -f $reg
}

# The bar action records our pane id right after opening us; pick it up in
# case herdr did not pass HERDR_PANE_ID.
if [[ -z $self && -n $reg ]]; then
  repeat 20; do [[ -s $reg ]] && break; zselect -t 5; done
  [[ -s $reg ]] && self=$(<$reg)
fi

trap cleanup EXIT
trap 'exit 0' INT TERM HUP
trap 'size; last=""' WINCH
size
print -n $'\e[?25l\e[H\e[2J'

local key
while :; do
  follow
  render
  draw
  if [[ -t 0 ]]; then
    if read -t 1 -k 1 -s key; then
      case $key in
        q) exit 0 ;;
        r) size; last="" ;;
      esac
    fi
  else
    zselect -t 100
  fi
done
