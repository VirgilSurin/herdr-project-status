# herdr-project-status: AWS profile + per-project env vars in herdr's sidebar
# (and, optionally, the starship prompt).
#
# Env vars only exist inside the shell, so the shell has to report them: this
# precmd hook computes the status on every prompt and, when it changed, pushes
# it to herdr as workspace metadata tokens ($aws, $aws_prod, $env). It also
# writes a per-pane state file that the plugin side reads to re-report on pane
# focus/close and to render the details pane.
#
# Source it AFTER `eval "$(direnv hook zsh)"` so direnv-loaded values are seen
# on the same prompt:
#   for _f in ${HOME}/.config/herdr/plugins/{,github/}*project-status*/shell/hook.zsh(N); do
#     source $_f; break
#   done
#
# The prompt path forks nothing: files are read through zsh/mapfile, time comes
# from zsh/datetime, and herdr is only called (backgrounded) when something
# changed or the refresh interval elapsed.

zmodload zsh/datetime zsh/mapfile
zmodload -F zsh/stat b:zstat
zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm

typeset -g  _ps_herdr=${commands[herdr]:-}
typeset -g  _ps_state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-project-status
typeset -g  _ps_cfg_key=""       # "<path>:<mtime>" of the parsed project.config
typeset -g  _ps_cfg_file=""
typeset -ga _ps_labels _ps_vars _ps_modes
typeset -g  _ps_sso_profile="" _ps_sso_exp=""
typeset -gi _ps_sso_at=0
typeset -g  _ps_last_key=""
typeset -gi _ps_last_sent=0
typeset -g  _ps_aws_detail=""    # full "<profile> · expires <time>" for the details pane
typeset -ga _ps_env_detail       # untruncated "label=value" entries

# Defaults; override any of these in ~/.config/herdr-project-status/config.zsh
# (see config.example.zsh).
_ps_settings() {
  typeset -g  PS_CONFIG_NAME=project.config
  typeset -gi PS_MAX_LEN=24
  typeset -gi PS_TTL_MS=43200000
  typeset -gi PS_REFRESH_S=60
  typeset -g  PS_PROD_PATTERN='*[Pp]rod*'
  typeset -g  PS_PROD_EXCLUDE='*[Nn]o[Pp]rod*'
  typeset -g  PS_SEPARATOR='  '
  typeset -gi PS_PROMPT_IN_HERDR=0
  local f=${PS_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-project-status/config.zsh}
  [[ -r $f ]] && source $f
}

# Trim leading/trailing whitespace of $1 into REPLY.
_ps_trim() {
  setopt localoptions extendedglob
  REPLY=${${1##[[:space:]]#}%%[[:space:]]#}
}

# Nearest $PS_CONFIG_NAME from $PWD upwards; reparse only when path or mtime
# changed, so editing the file is picked up on the next prompt.
_ps_find_config() {
  local d=$PWD
  while [[ ! -f $d/$PS_CONFIG_NAME ]]; do
    [[ $d == / ]] && { d=; break }
    d=${d:h}
  done
  local f=${d:+${d%/}/$PS_CONFIG_NAME} key=""
  if [[ -n $f ]]; then
    local -a st
    zstat -A st +mtime -- $f 2>/dev/null
    key="$f:${st[1]}"
  fi
  [[ $key == $_ps_cfg_key ]] && return
  _ps_cfg_key=$key _ps_cfg_file=$f
  _ps_parse_config $f
}

# project.config format, one entry per line, `#` starts a comment:
#   NODE_ENV            show the value
#   stage=APP_STAGE     show the value under a custom label
#   DATABASE_URL:set    show only ✓/✗ (for secrets)
_ps_parse_config() {
  setopt localoptions extendedglob
  _ps_labels=() _ps_vars=() _ps_modes=()
  [[ -n $1 && -r $1 ]] || return
  local line label var mode
  for line in ${(f)mapfile[$1]}; do
    _ps_trim ${line%%\#*}; line=$REPLY
    [[ -n $line ]] || continue
    mode=value
    if [[ $line == *:set ]]; then mode=set line=${line%:set}; fi
    if [[ $line == *=* ]]; then
      _ps_trim ${line%%=*}; label=$REPLY
      _ps_trim ${line#*=};  var=$REPLY
    else
      label=$line var=$line
    fi
    [[ $var == [A-Za-z_][A-Za-z0-9_]# ]] || continue
    _ps_labels+=(${label:-$var}) _ps_vars+=($var) _ps_modes+=($mode)
  done
}

# Sidebar/prompt string for the configured env vars into REPLY; the untruncated
# entries go to _ps_env_detail.
_ps_env() {
  local -a out
  local i val
  _ps_env_detail=()
  for (( i = 1; i <= $#_ps_vars; i++ )); do
    if [[ ${_ps_modes[i]} == set ]]; then
      [[ -n ${(P)_ps_vars[i]} ]] && val=✓ || val=✗
      out+=("${_ps_labels[i]} $val")
      _ps_env_detail+=("${_ps_labels[i]}=$val")
      continue
    fi
    val=${(P)_ps_vars[i]}
    val=${val//$'\n'/ }
    [[ -n $val ]] || val=–
    _ps_env_detail+=("${_ps_labels[i]}=$val")
    (( $#val > PS_MAX_LEN )) && val="${val[1,PS_MAX_LEN-1]}…"
    out+=("${_ps_labels[i]}=$val")
  done
  REPLY=${(pj:$PS_SEPARATOR:)out}
}

# ISO-8601 timestamp (Z, UTC, ±HH:MM, optional fraction) → epoch seconds in REPLY.
_ps_epoch() {
  setopt localoptions extendedglob
  local d='[0-9]'
  [[ $1 == (#b)(${~d}(#c4)-${~d}(#c2)-${~d}(#c2))[T\ ](${~d}(#c2):${~d}(#c2):${~d}(#c2))(.${~d}##|)(Z|UTC|[+-]${~d}(#c2):#${~d}(#c2)|) ]] || return 1
  local base="${match[1]}T${match[2]}" zone=${match[4]//:/}
  # strftime -r -s creates a missing target as an integer parameter, which
  # would leave a global REPLY integer-typed; parse into a scalar local instead.
  local TZ=UTC t=""
  strftime -r -s t '%Y-%m-%dT%H:%M:%S' $base 2>/dev/null || return 1
  if [[ $zone == [+-]* ]]; then
    local -i off=$(( ${zone[2,3]} * 3600 + ${zone[4,5]} * 60 ))
    [[ $zone == +* ]] && (( t -= off )) || (( t += off ))
  fi
  REPLY=$t
}

# Seconds left → "42m", "3h05m", "2d", or "expired" in REPLY.
_ps_left() {
  local -i s=$1
  if   (( s <= 0 ));     then REPLY=expired
  elif (( s < 3600 ));  then REPLY="$(( s / 60 ))m"
  elif (( s < 86400 )); then printf -v REPLY '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else                       REPLY="$(( s / 86400 ))d"
  fi
}

# SSO token expiry (epoch, REPLY) for a profile, from ~/.aws/config and the
# ~/.aws/sso/cache token files matching its start URL. Cached for 60s.
_ps_sso_expiry() {
  local profile=$1
  if [[ $profile == $_ps_sso_profile ]] && (( EPOCHSECONDS - _ps_sso_at < 60 )); then
    REPLY=$_ps_sso_exp
    [[ -n $REPLY ]]
    return
  fi
  _ps_sso_profile=$profile _ps_sso_at=$EPOCHSECONDS _ps_sso_exp=""

  local line section="" key val session="" url=""
  local -A starts
  for line in ${(f)mapfile[${AWS_CONFIG_FILE:-$HOME/.aws/config}]}; do
    _ps_trim $line; line=$REPLY
    [[ $line == [\#\;]* ]] && continue
    if [[ $line == \[*\] ]]; then
      _ps_trim ${${line#\[}%\]}; section=$REPLY
      continue
    fi
    [[ $line == *=* ]] || continue
    _ps_trim ${line%%=*}; key=$REPLY
    _ps_trim ${line#*=};  val=$REPLY
    if [[ $section == "profile $profile" || ( $profile == default && $section == default ) ]]; then
      [[ $key == sso_session ]]   && session=$val
      [[ $key == sso_start_url ]] && url=$val
    elif [[ $section == "sso-session "* && $key == sso_start_url ]]; then
      _ps_trim ${section#sso-session }; starts[$REPLY]=$val
    fi
  done
  [[ -z $url && -n $session ]] && url=${starts[$session]}
  [[ -n $url ]] || return 1
  url=${${url%/}%\#}

  local f json start expires
  local -i best=0
  for f in ${AWS_SSO_CACHE_DIR:-$HOME/.aws/sso/cache}/*.json(N); do
    json=${mapfile[$f]}
    [[ $json == *'"accessToken"'* ]] || continue
    [[ $json =~ '"startUrl"[[:space:]]*:[[:space:]]*"([^"]*)"' ]] || continue
    start=${match[1]}
    [[ ${${start%/}%\#} == $url ]] || continue
    [[ $json =~ '"expiresAt"[[:space:]]*:[[:space:]]*"([^"]*)"' ]] || continue
    expires=${match[1]}
    _ps_epoch $expires && (( REPLY > best )) && best=$REPLY
  done
  (( best )) && _ps_sso_exp=$best
  REPLY=$_ps_sso_exp
  [[ -n $REPLY ]]
}

# "<profile> · <time left>" in REPLY (empty when no profile is active).
_ps_aws() {
  REPLY="" _ps_aws_detail=""
  local profile=${AWS_PROFILE:-${AWS_VAULT:-$AWS_DEFAULT_PROFILE}}
  [[ -n $profile ]] || return 0
  local exp=${AWS_CREDENTIAL_EXPIRATION:-$AWS_SESSION_EXPIRATION} at="" left="" src=""
  if [[ -n $exp ]] && _ps_epoch $exp; then
    at=$REPLY src=credentials
  elif _ps_sso_expiry $profile; then
    at=$REPLY src="sso session"
  fi
  if [[ -n $at ]]; then
    _ps_left $(( at - EPOCHSECONDS )); left=$REPLY
    strftime -s REPLY '%Y-%m-%d %H:%M' $at
    if [[ $left == expired ]]; then
      _ps_aws_detail="$profile · $src expired at $REPLY"
    else
      _ps_aws_detail="$profile · $src: $left left (until $REPLY)"
    fi
  else
    _ps_aws_detail="$profile · no expiry known"
  fi
  REPLY="$profile${left:+ · $left}"
}

_ps_is_prod() {
  [[ $1 == ${~PS_PROD_PATTERN} && $1 != ${~PS_PROD_EXCLUDE} ]]
}

# Per-pane state for the plugin side (re-report on focus, details pane).
# key=value lines, values are newline-free.
_ps_write_state() {
  [[ -n $HERDR_PANE_ID ]] || return
  local f=$_ps_state_dir/$HERDR_PANE_ID e
  local -a lines=(
    "workspace=$HERDR_WORKSPACE_ID"
    "pane=$HERDR_PANE_ID"
    "updated=$EPOCHSECONDS"
    "cwd=$PWD"
    "config=$_ps_cfg_file"
    "aws=$1" "aws_prod=$2" "env=$3"
    "detail.aws=$_ps_aws_detail"
  )
  for e in $_ps_env_detail; do lines+=("detail.env=$e"); done
  print -rl -- $lines >| $f.tmp 2>/dev/null && zf_mv -f $f.tmp $f 2>/dev/null
}

_ps_report() {
  local -a args
  local name val
  for name val in aws "$1" aws_prod "$2" env "$3"; do
    if [[ -n $val ]]; then args+=(--token "$name=$val"); else args+=(--clear-token $name); fi
  done
  ("$_ps_herdr" workspace report-metadata "$HERDR_WORKSPACE_ID" \
    --source project-status --ttl-ms $PS_TTL_MS $args >/dev/null 2>&1 &)
}

_project_status_precmd() {
  _ps_find_config
  _ps_aws;  local aws=$REPLY aws_prod=""
  if [[ -n $aws ]] && _ps_is_prod ${aws%% · *}; then aws_prod=$aws aws=""; fi
  _ps_env;  local env=$REPLY

  # starship segments ([env_var.PROJECT_STATUS_*]). Inside herdr the sidebar
  # already shows them, so only the prod warning stays in the prompt by default.
  local in_herdr=${HERDR_WORKSPACE_ID:+1}
  if [[ -n $aws_prod ]]; then export PROJECT_STATUS_AWS_PROD=$aws_prod; else unset PROJECT_STATUS_AWS_PROD; fi
  if [[ -z $in_herdr ]] || (( PS_PROMPT_IN_HERDR )); then
    if [[ -n $aws ]]; then export PROJECT_STATUS_AWS=$aws; else unset PROJECT_STATUS_AWS; fi
    if [[ -n $env ]]; then export PROJECT_STATUS_ENV=$env; else unset PROJECT_STATUS_ENV; fi
  else
    unset PROJECT_STATUS_AWS PROJECT_STATUS_ENV
  fi

  [[ -n $in_herdr && -n $_ps_herdr ]] || return 0
  local key="$aws|$aws_prod|$env"
  [[ $key == $_ps_last_key ]] && (( EPOCHSECONDS - _ps_last_sent < PS_REFRESH_S )) && return 0
  _ps_last_key=$key _ps_last_sent=$EPOCHSECONDS
  _ps_write_state "$aws" "$aws_prod" "$env"
  _ps_report "$aws" "$aws_prod" "$env"
}

# The plugin's pane.closed/pane.exited handler re-reports the workspace from
# whichever pane is left; removing our state file keeps it from picking us.
_project_status_exit() {
  [[ -n $HERDR_PANE_ID ]] && zf_rm -f $_ps_state_dir/$HERDR_PANE_ID 2>/dev/null
}

_ps_settings
if [[ -n $HERDR_PANE_ID ]]; then
  zf_mkdir -p $_ps_state_dir 2>/dev/null
fi
autoload -Uz add-zsh-hook
add-zsh-hook precmd _project_status_precmd   # idempotent on re-source
add-zsh-hook zshexit _project_status_exit
