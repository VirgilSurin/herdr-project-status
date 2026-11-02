# Modeline: the shell keeps the last terminal row for itself (a scroll region
# of rows 1..LINES-1) and draws the project status there, like an nvim/emacs
# modeline. Sourced by hook.zsh, which computes the status; this file only
# renders it. Turned on per project with `@modeline = on` in project.config,
# or for every directory with PS_MODELINE=on.
#
# Terminal facts this relies on (checked in herdr 0.7.5 / libghostty):
# - zle clears everything below the prompt when it draws it, so the row is
#   drawn from zle-line-init (and the idle tick / resize trap), not precmd;
# - scrollback keeps growing while the region starts at row 1;
# - a program that moves the cursor below the region (Claude Code's inline UI
#   does on exit) leaves every later line on the last row, so each prompt
#   releases the region, frees the last row and reserves it again.
# Colors are palette indexes, so the bar follows the terminal theme.

zmodload zsh/sched

typeset -gi _ps_ml_on=${_ps_ml_on:-0}   # the region is ours (kept across a reload)
typeset -g  _ps_ml_line=""       # rendered row, ready to print
typeset -g  _ps_ml_base=""       # base SGR (bg + fg) every piece returns to
typeset -g  _ps_ml_buf=""
typeset -gi _ps_ml_len=0 _ps_ml_full=0 _ps_ml_sep=0

# All terminal output goes through here (tests replace it).
_ps_ml_emit() {
  [[ -n $TTY ]] && print -rn -- "$1" >$TTY 2>/dev/null
}

_ps_ml_wanted() {
  [[ ${_ps_opts[modeline]:-$PS_MODELINE} == on ]] && (( LINES >= 4 ))
}

# _ps_ml_color 38|48 <palette index | #rrggbb | default | none> → SGR params.
_ps_ml_color() {
  setopt localoptions extendedglob
  case $2 in
    (<0-255>) REPLY="$1;5;$2" ;;
    (\#[[:xdigit:]](#c6))
      REPLY="$1;2;$(( 16#${2[2,3]} ));$(( 16#${2[4,5]} ));$(( 16#${2[6,7]} ))" ;;
    (*) REPLY=$(( $1 + 1 )) ;;   # 39 / 49: the terminal's default
  esac
}

# _ps_ml_add <sgr> <text>: append a piece (extra SGR params on top of the base,
# "" for none), cut with "…" at the row's end. Returns 1 once the row is full.
# Section functions call it; a pending section separator goes first.
_ps_ml_add() {
  (( _ps_ml_full )) && return 1
  if (( _ps_ml_sep )); then
    _ps_ml_sep=0
    _ps_ml_add 2 " │ " || return 1
  fi
  local text=$2 sgr="" back=""
  [[ -n $1 ]] && sgr=$'\e['"$1"m back=$_ps_ml_base
  local -i room=$(( COLUMNS - 1 - _ps_ml_len ))
  if (( $#text > room )); then
    _ps_ml_full=1
    (( room > 0 )) || return 1
    text="${text[1,room-1]}…"
  fi
  _ps_ml_buf+="$sgr$text$back"
  _ps_ml_len+=$#text
  (( ! _ps_ml_full ))
}

_ps_modeline_project() {
  local name=${PWD:t}
  [[ -n $_ps_cfg_file ]] && name=${_ps_cfg_file:h:t}
  _ps_ml_add 1 ${name:-/}
}

_ps_modeline_aws() {
  local p=$_ps_aws_profile
  [[ -n $p ]] || return 0
  if _ps_is_prod $p; then
    _ps_ml_add "1;97;41" " ⚠ PROD " && _ps_ml_add "1;31" " $p"
  else
    _ps_ml_add 34 "AWS " && _ps_ml_add 33 $p
  fi || return 0
  [[ -n $_ps_aws_at ]] || return 0
  _ps_left $(( _ps_aws_at - EPOCHSECONDS ))
  if [[ $REPLY == expired ]]; then _ps_ml_add 31 " expired"
  else _ps_ml_add "" " $REPLY"
  fi
}

# Whole entries only: the first one that does not fit becomes "…".
_ps_modeline_env() {
  [[ -n $_ps_cfg_file ]] || return 0
  local e label value color
  local -i first=1 need
  for e in $_ps_env_detail; do
    label=${e%%=*} value=${e#*=}
    (( $#value > PS_MAX_LEN )) && value="${value[1,PS_MAX_LEN-1]}…"
    case $value in
      (✓) color=32 ;; (✗) color=31 ;; (–) color=2 ;; (*) color="" ;;
    esac
    need=$(( (_ps_ml_sep || !first ? 3 : 0) + $#label + 1 + $#value ))
    if (( _ps_ml_len + need > COLUMNS - 3 )); then
      if (( first )); then _ps_ml_add 2 "…"; else _ps_ml_add 2 " …"; fi
      _ps_ml_full=1
      return 0
    fi
    (( first )) || _ps_ml_add 2 " · " || return 0
    _ps_ml_add 2 "$label " && _ps_ml_add "$color" "$value" || return 0
    first=0
  done
}

_ps_ml_render() {
  local bg fg s
  local -i before
  _ps_ml_color 48 $PS_MODELINE_BG; bg=$REPLY
  _ps_ml_color 38 $PS_MODELINE_FG; fg=$REPLY
  _ps_ml_base=$'\e[0;'"$bg;${fg}m"
  _ps_ml_buf=" " _ps_ml_len=1 _ps_ml_full=0 _ps_ml_sep=0
  for s in $PS_MODELINE_SECTIONS; do
    (( $+functions[_ps_modeline_$s] )) || continue
    before=$_ps_ml_len
    _ps_modeline_$s
    _ps_ml_sep=$(( _ps_ml_len > before || _ps_ml_sep ))
    (( _ps_ml_full )) && break
  done
  _ps_ml_line="$_ps_ml_base"$'\e[2K'"$_ps_ml_buf"$'\e[K\e[0m'
}

# Release the region, make sure the cursor is off the last row (moving down
# and back up only scrolls when it is on it), then reserve that row again.
_ps_ml_establish() {
  _ps_ml_emit $'\e7\e[r\e8\eD\e[A\e7\e[1;'$(( LINES - 1 ))$'r\e8'
  _ps_ml_on=1
}

_ps_ml_draw() {
  (( _ps_ml_on )) && _ps_ml_emit $'\e7\e['$LINES$';1H'"$_ps_ml_line"$'\e8'
}

# Erase the row and give the whole screen back.
_ps_ml_release() {
  _ps_ml_emit $'\e7\e['$LINES$';1H\e[0m\e[2K\e[r\e8'
  _ps_ml_on=0
}

# Called by the hook's precmd, after the status has been computed.
_ps_ml_update() {
  if _ps_ml_wanted; then
    _ps_ml_render
    _ps_ml_establish
    [[ -n ${(M)zsh_scheduled_events:#*:_ps_ml_tick} ]] || sched +$PS_MODELINE_TICK_S _ps_ml_tick
  elif (( _ps_ml_on )); then
    _ps_ml_release
  fi
}

# Every PS_MODELINE_TICK_S at an idle prompt: count the session down. sched
# only fires while the shell waits for input, never during a command.
_ps_ml_tick() {
  (( _ps_ml_on )) || return 0
  _ps_aws
  _ps_ml_render
  _ps_ml_draw
  sched +$PS_MODELINE_TICK_S _ps_ml_tick
}

# Does this command line start a program from PS_MODELINE_YIELD (at any
# command position, past VAR=x prefixes and wrappers like sudo/npx)?
_ps_ml_yields() {
  setopt localoptions extendedglob
  local x
  local -i cmdpos=1
  for x in ${(z)1}; do
    if [[ $x == ('|'|'||'|'&&'|';'|'&'|'|&'|'('|'{'|$'\n') ]]; then cmdpos=1; continue; fi
    (( cmdpos )) || continue
    [[ $x == [A-Za-z_][A-Za-z0-9_]#=* || $x == -* ]] && continue
    [[ $x == (sudo|env|command|exec|nohup|time|noglob|builtin|npx|bunx|pnpx|pnpm|dlx|uvx) ]] && continue
    (( ${PS_MODELINE_YIELD[(Ie)${x:t}]} )) && return 0
    cmdpos=0
  done
  return 1
}

_ps_ml_preexec() {
  (( _ps_ml_on )) || return 0
  if (( ! PS_MODELINE_KEEP )) || _ps_ml_yields "$3"; then _ps_ml_release; fi
}

_ps_ml_line_init() { _ps_ml_draw }

# Redraw zle first: its refresh would otherwise clear the row again.
_ps_ml_clear_screen() {
  zle .clear-screen
  zle -R
  (( _ps_ml_on )) && { _ps_ml_establish; _ps_ml_draw }
}

# Plugins redraw the prompt with reset-prompt (zsh-vi-mode on every mode
# switch), which clears below it as well.
_ps_ml_reset_prompt() {
  zle .reset-prompt
  (( _ps_ml_on )) && { zle -R; _ps_ml_draw }
}

# Resize: only while editing a command line; a running command gets the new
# size at the next prompt.
_ps_ml_winch() {
  (( _ps_ml_on )) || return 0
  zle || return 0
  _ps_ml_render
  _ps_ml_establish
  _ps_ml_draw
}

if [[ -o interactive ]]; then
  autoload -Uz add-zle-hook-widget
  add-zle-hook-widget line-init _ps_ml_line_init   # idempotent on re-source
  zle -N clear-screen _ps_ml_clear_screen
  zle -N reset-prompt _ps_ml_reset_prompt
  if (( $+functions[TRAPWINCH] )) && [[ ${functions[TRAPWINCH]} != *_ps_ml_winch* ]]; then
    functions[_ps_ml_prev_winch]=${functions[TRAPWINCH]}
  fi
  TRAPWINCH() {
    _ps_ml_winch
    (( $+functions[_ps_ml_prev_winch] )) && _ps_ml_prev_winch
    return 0
  }
fi
