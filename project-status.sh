#!/usr/bin/env bash
# herdr-project-status: plugin-side entry point.
#
#   project-status.sh bar [<pane>]   action: toggle the project bar in this tab
#   project-status.sh reconcile      startup + focus/close events
#   project-status.sh show | doctor  actions: open the details / doctor overlay
#   project-status.sh details-ui     the details overlay pane
#   project-status.sh doctor-ui      the doctor overlay pane
#
# The shell hook (shell/hook.zsh) does the real work on every prompt: it writes
# a per-pane state file with its shell's status, which the project bar
# (bar.zsh) renders for whichever pane is focused. With PS_SIDEBAR=prod|all
# the hook also reports herdr sidebar tokens; panes of one workspace share
# those, so the last prompt wins, and reconcile fixes that up on focus by
# re-reporting each workspace from the pane you are looking at. Reconcile also
# drops state left by closed panes. It is idempotent and only calls herdr when
# the sidebar would actually change.
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays. Needs jq.

PS_ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="project-status"
# Fixed paths shared with the shell hook, which never sees HERDR_PLUGIN_* vars.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-project-status"
USER_CONFIG="${PS_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-project-status/config.zsh}"
SEP=$'\x1f'   # field separator for jq output; not whitespace, so empty fields survive `read`

# ps_setting <NAME> <default>: a scalar PS_* setting from the user's zsh config
# (last plain `NAME=value` assignment, quotes stripped), else the default.
ps_setting() {
  local v=""
  [ -r "$USER_CONFIG" ] && v=$(sed -n -E "s/^[[:space:]]*(typeset[[:space:]]+-[a-z]+[[:space:]]+|integer[[:space:]]+)?$1=['\"]?([^'\"#[:space:]]*).*/\\2/p" "$USER_CONFIG" | tail -n1)
  printf '%s' "${v:-$2}"
}
ps_ttl_ms() { ps_setting PS_TTL_MS 43200000; }

# state_get <file> <key>: first value for key in a key=value state file.
state_get() {
  local line
  while IFS= read -r line; do
    case $line in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "$1"
  return 1
}

ps_snapshot() { "$HERDR" api snapshot 2>/dev/null; }

# ps_report <workspace> <aws> <aws_prod> <env>: empty values clear the token.
ps_report() {
  local ws=$1 args=() name val
  shift
  for name in aws aws_prod env; do
    val=$1; shift
    if [ -n "$val" ]; then args+=(--token "$name=$val"); else args+=(--clear-token "$name"); fi
  done
  "$HERDR" workspace report-metadata "$ws" --source "$PLUGIN_ID" --ttl-ms "$(ps_ttl_ms)" "${args[@]}" >/dev/null 2>&1
}

ps_reconcile() {
  [ -d "$STATE_DIR" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local snap panes wss f pane
  snap=$(ps_snapshot) || return 0
  panes=$(printf '%s' "$snap" | jq -r --arg s "$SEP" \
    '.result.snapshot.panes[] | [.pane_id, .tab_id, .workspace_id, (.focused | tostring)] | join($s)') || return 0
  wss=$(printf '%s' "$snap" | jq -r --arg s "$SEP" \
    '.result.snapshot.workspaces[] | [.workspace_id, .active_tab_id, (.tokens.aws // ""), (.tokens.aws_prod // ""), (.tokens.env // "")] | join($s)') || return 0

  # Drop state left behind by panes that are gone (killed shells skip zshexit).
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    pane=${f##*/}
    case $'\n'"$panes" in *$'\n'"$pane$SEP"*) ;; *) rm -f "$f" ;; esac
  done

  # Sidebar off: nothing to report beyond clearing tokens a previous setting
  # left behind, which the loop below does since every wanted value is empty.
  local sidebar; sidebar=$(ps_setting PS_SIDEBAR off)

  local ws active cur_aws cur_prod cur_env p_pane p_tab p_ws p_focused
  local best best_rank best_time rank t want_aws want_prod want_env
  while IFS="$SEP" read -r ws active cur_aws cur_prod cur_env; do
    [ -n "$ws" ] || continue
    # Prefer the focused pane of the active tab, then any pane of the active
    # tab, then any pane of the workspace; newest report breaks ties.
    best="" best_rank=0 best_time=0
    while IFS="$SEP" read -r p_pane p_tab p_ws p_focused; do
      [ "$p_ws" = "$ws" ] && [ -f "$STATE_DIR/$p_pane" ] || continue
      rank=1
      if [ "$p_tab" = "$active" ]; then
        rank=2
        [ "$p_focused" = true ] && rank=3
      fi
      t=$(state_get "$STATE_DIR/$p_pane" updated); t=${t:-0}
      if [ $rank -gt $best_rank ] || { [ $rank -eq $best_rank ] && [ "$t" -gt $best_time ]; }; then
        best="$STATE_DIR/$p_pane" best_rank=$rank best_time=$t
      fi
    done <<EOF
$panes
EOF
    want_aws="" want_prod="" want_env=""
    if [ -n "$best" ]; then
      case $sidebar in
        all)  want_aws=$(state_get "$best" aws)
              want_prod=$(state_get "$best" aws_prod)
              want_env=$(state_get "$best" env) ;;
        prod) want_prod=$(state_get "$best" aws_prod) ;;
      esac
    fi
    [ "$want_aws|$want_prod|$want_env" = "$cur_aws|$cur_prod|$cur_env" ] && continue
    ps_report "$ws" "$want_aws" "$want_prod" "$want_env"
  done <<EOF
$wss
EOF
}

ps_focused_pane() {
  if [ -n "${HERDR_PANE_ID:-}" ]; then printf '%s' "$HERDR_PANE_ID"; return; fi
  ps_snapshot | jq -r '.result.snapshot.focused_pane_id // empty' 2>/dev/null
}

# Toggle the project bar in the focused pane's tab. It is opened below the
# tab's bottom-most full-width pane, so it spans the whole tab whenever the
# layout has such a pane (one pane, or anything stacked above a full-width
# one); otherwise it goes under the focused pane. Then the divider is moved
# down until the bar is PS_BAR_ROWS rows of content plus its borders. herdr
# keeps every split at 10% or more, so on short screens the bar can come out
# a bit taller; the spare rows are used for wrapping env entries.
ps_bar_toggle() {  # ps_bar_toggle [<pane>]: defaults to the focused pane
  local snap focused tab reg pid layout rows anchor ah out amount
  snap=$(ps_snapshot) || return 1
  focused=${1:-$(printf '%s' "$snap" | jq -r '.result.snapshot.focused_pane_id // empty')}
  [ -n "$focused" ] || return 1
  tab=$(printf '%s' "$snap" | jq -r --arg p "$focused" '.result.snapshot.panes[] | select(.pane_id == $p) | .tab_id')
  reg="$STATE_DIR/bars/$tab"

  if [ -s "$reg" ]; then
    pid=$(cat "$reg")
    rm -f "$reg"
    if printf '%s' "$snap" | jq -e --arg p "$pid" '.result.snapshot.panes | any(.pane_id == $p)' >/dev/null; then
      "$HERDR" plugin pane close "$pid" >/dev/null 2>&1
      return 0
    fi
  fi

  rows=$(ps_setting PS_BAR_ROWS 3)
  layout=$("$HERDR" pane layout --pane "$focused" 2>/dev/null) || return 1
  anchor=$(printf '%s' "$layout" | jq -r --arg f "$focused" '
    .result.layout as $l | $l.area as $a
    | ([$l.panes[] | select(.rect.width == $a.width and .rect.y + .rect.height == $a.y + $a.height)][0]
       // ($l.panes[] | select(.pane_id == $f)))
    | "\(.pane_id) \(.rect.height)"')
  ah=${anchor##* } anchor=${anchor% *}
  [ -n "$anchor" ] || return 1

  out=$("$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint bar --placement split \
    --direction down --target-pane "$anchor" --no-focus \
    --env "PS_TAB_ID=$tab" --env "PS_TARGET_PANE=$focused" 2>/dev/null) || return 1
  pid=$(printf '%s' "$out" | jq -r '.result.plugin_pane.pane.pane_id // empty')
  [ -n "$pid" ] || return 1
  mkdir -p "$STATE_DIR/bars" && printf '%s' "$pid" > "$reg"

  # The split starts at 0.5 of the anchor's height; herdr clamps ratios to 0.9.
  amount=$(awk -v r="$rows" -v ah="$ah" 'BEGIN { a = 0.5 - (r + 2) / ah; if (a < 0) a = 0; if (a > 0.4) a = 0.4; printf "%.4f", a }')
  "$HERDR" pane resize --pane "$pid" --direction down --amount "$amount" >/dev/null 2>&1
}

ps_open() {  # ps_open <entrypoint>
  "$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint "$1" --placement overlay \
    --env "PS_TARGET_PANE=$(ps_focused_pane)" --focus >/dev/null
}

# --- overlay panes -------------------------------------------------------------

if [ -t 1 ]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[0m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' BLU=$'\e[34m'
else
  B="" D="" R="" RED="" GRN="" YEL="" BLU=""
fi

wait_key() {
  printf '\n%spress any key to close%s' "$D" "$R"
  IFS= read -rsn1 _ 2>/dev/null || sleep 5
}

ps_details_ui() {
  local f="$STATE_DIR/${PS_TARGET_PANE:-}" line aws_line cfg
  printf '%s Project Status%s\n\n' "$B" "$R"
  if [ -z "${PS_TARGET_PANE:-}" ] || [ ! -f "$f" ]; then
    printf '  %sNo status reported for this pane yet.%s\n' "$YEL" "$R"
    printf '  Press enter in its shell once, or run the doctor action if it stays empty.\n'
    wait_key; return
  fi
  cfg=$(state_get "$f" config)
  printf '  %sdirectory%s  %s\n' "$D" "$R" "$(state_get "$f" cwd)"
  printf '  %sconfig%s     %s\n\n' "$D" "$R" "${cfg:-${D}none (no project.config above this directory)${R}}"

  aws_line=$(state_get "$f" detail.aws)
  if [ -n "$(state_get "$f" aws_prod)" ]; then
    printf '  %sAWS%s        %s%s⚠ %s%s\n' "$B" "$R" "$B" "$RED" "$aws_line" "$R"
  elif [ -n "$aws_line" ]; then
    printf '  %sAWS%s        %s%s%s\n' "$B" "$R" "$YEL" "$aws_line" "$R"
  else
    printf '  %sAWS%s        %sno profile active%s\n' "$B" "$R" "$D" "$R"
  fi

  printf '\n  %sENV%s\n' "$B" "$R"
  local any=0
  while IFS= read -r line; do
    case $line in
      detail.env=*)
        line=${line#detail.env=}; any=1
        printf '    %s%-18s%s %s\n' "$BLU" "${line%%=*}" "$R" "${line#*=}"
        ;;
    esac
  done < "$f"
  [ $any = 1 ] || printf '    %snothing configured%s\n' "$D" "$R"
  wait_key
}

ok()   { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$R" "$1"; }
info() { printf '  %s·%s %s\n' "$D" "$R" "$1"; }
snippet() { printf '%s' "$D"; sed 's/^/      /' "$1"; printf '%s\n' "$R"; }

ps_doctor_ui() {
  local zshrc="${ZDOTDIR:-$HOME}/.zshrc" herdr_cfg starship_cfg n newest sidebar
  herdr_cfg="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
  starship_cfg="${STARSHIP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml}"
  printf '%s Project Status: doctor%s\n\n' "$B" "$R"

  info "$("$HERDR" --version 2>/dev/null || echo 'herdr: not found')"
  if command -v jq >/dev/null 2>&1; then ok "jq found"; else bad "jq not on PATH (needed for focus/close reconcile)"; fi

  if grep -qs 'project-status' "$zshrc" "${ZDOTDIR:-$HOME}"/.zshrc.d/* 2>/dev/null; then
    ok "shell hook referenced from $zshrc"
  else
    bad "shell hook not sourced; add this to $zshrc (after the direnv hook):"
    printf '      %ssource %s/shell/hook.zsh%s\n' "$D" "$PS_ROOT" "$R"
  fi
  n=$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt 0 ]; then
    newest=$(ls -t "$STATE_DIR" | grep -v '^bars$' | head -n1)
    ok "hook active: $n pane(s) reporting, latest $newest"
  else
    bad "no pane has reported yet (open a new shell after sourcing the hook)"
  fi

  if grep -qs 'project-status.bar' "$herdr_cfg"; then
    ok "bar toggle bound ($herdr_cfg)"
  else
    bad "no key toggles the bar; add to $herdr_cfg, then: herdr server reload-config"
    snippet "$PS_ROOT/herdr.example.toml"
  fi

  sidebar=$(ps_setting PS_SIDEBAR off)
  if [ "$sidebar" = off ]; then
    info "sidebar tokens off (PS_SIDEBAR=prod|all in $USER_CONFIG to enable)"
  elif grep -qsE '"\$(aws|aws_prod|env)"' "$herdr_cfg"; then
    ok "sidebar tokens: $sidebar, rows reference them"
  else
    bad "PS_SIDEBAR=$sidebar but no sidebar rows use \$aws/\$aws_prod/\$env; see herdr.example.toml"
  fi

  if grep -qs 'PROJECT_STATUS_' "$starship_cfg"; then
    ok "starship segments configured"
  else
    info "starship segments not configured (optional, for shells outside herdr):"
    snippet "$PS_ROOT/starship.example.toml"
  fi

  if [ -n "${PS_TARGET_PANE:-}" ] && [ -f "$STATE_DIR/$PS_TARGET_PANE" ]; then
    ok "focused pane: aws='$(state_get "$STATE_DIR/$PS_TARGET_PANE" aws)$(state_get "$STATE_DIR/$PS_TARGET_PANE" aws_prod)' env='$(state_get "$STATE_DIR/$PS_TARGET_PANE" env)'"
  fi
  wait_key
}

case "${1:-}" in
  bar)        ps_bar_toggle "${2:-}" ;;
  reconcile)  ps_reconcile ;;
  show)       ps_open details ;;
  doctor)     ps_open doctor ;;
  details-ui) ps_details_ui ;;
  doctor-ui)  ps_doctor_ui ;;
  *) printf 'usage: %s bar|reconcile|show|doctor|details-ui|doctor-ui\n' "${0##*/}" >&2; exit 2 ;;
esac
