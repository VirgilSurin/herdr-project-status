#!/usr/bin/env zsh
# Unit tests for shell/hook.zsh. Run: zsh tests/run.zsh
# Uses a throwaway HOME, so it never touches the real ~/.aws or herdr.

emulate -R zsh
setopt err_return no_unset 2>/dev/null; unsetopt err_return no_unset

typeset -gi pass=0 fail=0
ok() {   # ok <description> <actual> <expected>
  if [[ $2 == $3 ]]; then (( pass++ ))
  else (( fail++ )); print -r -- "FAIL: $1"$'\n'"   got:      [$2]"$'\n'"   expected: [$3]"
  fi
}

root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

export HOME=$tmp/home XDG_STATE_HOME=$tmp/state XDG_CONFIG_HOME=$tmp/config
mkdir -p $HOME/.aws/sso/cache $tmp/proj/sub/deeper
unset HERDR_PANE_ID HERDR_WORKSPACE_ID AWS_PROFILE AWS_VAULT AWS_DEFAULT_PROFILE \
      AWS_CREDENTIAL_EXPIRATION AWS_SESSION_EXPIRATION AWS_CONFIG_FILE AWS_SSO_CACHE_DIR

source $root/shell/hook.zsh

# --- _ps_epoch ---------------------------------------------------------------
_ps_epoch 1970-01-01T01:00:00Z;              ok "epoch Z" $REPLY 3600
_ps_epoch 1970-01-01T01:00:00.811438Z;       ok "epoch fraction" $REPLY 3600
_ps_epoch 1970-01-01T01:00:00UTC;            ok "epoch UTC suffix" $REPLY 3600
_ps_epoch 1970-01-01T02:00:00+01:00;         ok "epoch +01:00" $REPLY 3600
_ps_epoch 1970-01-01T00:30:00-0030;          ok "epoch -0030" $REPLY 3600
_ps_epoch "1970-01-01 01:00:00";             ok "epoch space separator" $REPLY 3600
_ps_epoch not-a-date;                        ok "epoch rejects garbage" $? 1

# --- _ps_left ----------------------------------------------------------------
_ps_left -5;     ok "left expired" $REPLY expired
_ps_left 2520;   ok "left minutes" $REPLY 42m
_ps_left 11100;  ok "left hours" $REPLY 3h05m
_ps_left 200000; ok "left days" $REPLY 2d

# --- project.config parsing --------------------------------------------------
cat > $tmp/proj/project.config <<'EOF'
# watched vars
NODE_ENV
  stage = APP_STAGE     # custom label
DATABASE_URL:set
token=API_TOKEN:set
not a var name
EOF
cd $tmp/proj/sub/deeper
_ps_find_config
ok "config found upwards" $_ps_cfg_file $tmp/proj/project.config
ok "labels" "${(j:,:)_ps_labels}" "NODE_ENV,stage,DATABASE_URL,token"
ok "vars"   "${(j:,:)_ps_vars}"   "NODE_ENV,APP_STAGE,DATABASE_URL,API_TOKEN"
ok "modes"  "${(j:,:)_ps_modes}"  "value,value,set,set"

NODE_ENV=production APP_STAGE=a-very-long-stage-name-that-overflows DATABASE_URL=postgres://secret
unset API_TOKEN
_ps_env
ok "env segment" $REPLY "NODE_ENV=production  stage=a-very-long-stage-name-…  DATABASE_URL ✓  token ✗"
ok "env detail keeps full value" ${_ps_env_detail[2]} "stage=a-very-long-stage-name-that-overflows"
ok "env never leaks :set values" "${(M)${(j: :)_ps_env_detail}:#*secret*}" ""

unset NODE_ENV
_ps_env
ok "unset var shows dash" ${REPLY%%  *} "NODE_ENV=–"

cd $tmp
_ps_find_config
ok "leaving the project clears entries" "$#_ps_vars:$_ps_cfg_file" "0:"

# --- AWS: credential expiry from env (Granted) -------------------------------
export AWS_PROFILE=nomics_apios_dev
strftime -s exp '%Y-%m-%dT%H:%M:%S' $(( EPOCHSECONDS + 2520 + 30 ))
AWS_SESSION_EXPIRATION="${exp}$(strftime %z $EPOCHSECONDS | sed -E 's/(..)$/:\1/')"
export AWS_SESSION_EXPIRATION
_ps_aws
ok "aws from Granted env" $REPLY "nomics_apios_dev · 42m"
unset AWS_SESSION_EXPIRATION

# --- AWS: SSO session fallback -----------------------------------------------
cat > $HOME/.aws/config <<'EOF'
[profile nomics_apios_dev]
sso_session = necko
region = eu-west-1

[profile legacy_sso]
sso_start_url = https://legacy.awsapps.com/start/

[profile static_keys]
region = eu-west-1

[sso-session necko]
sso_start_url = https://necko.awsapps.com/start#/
sso_region = eu-west-1
EOF
TZ=UTC strftime -s soon '%Y-%m-%dT%H:%M:%SZ' $(( EPOCHSECONDS + 7200 + 30 ))
TZ=UTC strftime -s later '%Y-%m-%dT%H:%M:%SZ' $(( EPOCHSECONDS + 3 * 86400 ))
print -r -- '{"startUrl": "https://necko.awsapps.com/start#/", "accessToken": "x", "expiresAt": "'$soon'"}' > $HOME/.aws/sso/cache/a.json
# client registration: has expiresAt but no accessToken, must be ignored
print -r -- '{"clientId": "c", "clientSecret": "s", "expiresAt": "'$later'"}' > $HOME/.aws/sso/cache/b.json
print -r -- '{"startUrl": "https://legacy.awsapps.com/start", "accessToken": "y", "expiresAt": "'$later'"}' > $HOME/.aws/sso/cache/c.json

_ps_aws
ok "aws from sso-session cache" $REPLY "nomics_apios_dev · 2h00m"

AWS_PROFILE=legacy_sso; _ps_sso_at=0
_ps_aws
ok "aws from legacy sso_start_url" $REPLY "legacy_sso · 3d"

AWS_PROFILE=static_keys; _ps_sso_at=0
_ps_aws
ok "aws without expiry info" $REPLY "static_keys"

unset AWS_PROFILE
_ps_aws
ok "no profile, no segment" "$REPLY" ""

# --- prod detection ----------------------------------------------------------
_ps_is_prod nomics_apios_prod;   ok "prod" $? 0
_ps_is_prod nomics_noprod;       ok "noprod is not prod" $? 1
_ps_is_prod nomics_apios_dev;    ok "dev is not prod" $? 1

# --- precmd outside herdr: prompt vars only ----------------------------------
export AWS_PROFILE=nomics_apios_prod
_project_status_precmd
ok "prod exported for starship" "${PROJECT_STATUS_AWS_PROD:-}" "nomics_apios_prod"
ok "non-prod var unset when prod" "${PROJECT_STATUS_AWS:-unset}" "unset"
ok "no state written outside herdr" "$(ls $XDG_STATE_HOME/herdr-project-status 2>/dev/null)" ""

# --- precmd inside herdr: state file (herdr call stubbed) ---------------------
export HERDR_PANE_ID=w1:p1 HERDR_WORKSPACE_ID=w1
mkdir -p $_ps_state_dir
_ps_herdr=$tmp/fake-herdr
print -r -- '#!/bin/sh
printf "%s\n" "$@" > "'$tmp'/herdr-args"' > $_ps_herdr; chmod +x $_ps_herdr
export AWS_PROFILE=nomics_apios_dev
PS_SIDEBAR=off _ps_last_key=""
_project_status_precmd
sleep 0.3
ok "sidebar off: herdr never called" "$([[ -e $tmp/herdr-args ]] && echo sent || echo none)" none
ok "sidebar off: state still written" "$(command grep '^aws_profile=' $_ps_state_dir/w1:p1)" "aws_profile=nomics_apios_dev"
ok "state has raw expiry for the bar" "$(command grep -c -E '^aws_expires=[0-9]+$' $_ps_state_dir/w1:p1)" 1
ok "state has expiry source" "$(command grep '^aws_src=' $_ps_state_dir/w1:p1)" "aws_src=sso session"

PS_SIDEBAR=all _ps_last_key=""
_project_status_precmd
sleep 0.3
ok "state file aws" "$(command grep '^aws=' $_ps_state_dir/w1:p1)" "aws=nomics_apios_dev · 2h00m"
ok "state file workspace" "$(command grep '^workspace=' $_ps_state_dir/w1:p1)" "workspace=w1"
ok "report sets aws, clears others" "$(tr '\n' ' ' < $tmp/herdr-args)" \
   "workspace report-metadata w1 --source project-status --ttl-ms 43200000 --token aws=nomics_apios_dev · 2h00m --clear-token aws_prod --clear-token env "
ok "prompt hides sidebar values in herdr" "${PROJECT_STATUS_AWS:-unset}" "unset"

rm -f $tmp/herdr-args
_project_status_precmd; sleep 0.2
ok "unchanged status is not re-sent" "$([[ -e $tmp/herdr-args ]] && echo sent || echo skipped)" skipped

PS_SIDEBAR=prod; AWS_PROFILE=nomics_apios_prod
_project_status_precmd; sleep 0.3
ok "sidebar prod: only the warning token" "$(tr '\n' ' ' < $tmp/herdr-args)" \
   "workspace report-metadata w1 --source project-status --ttl-ms 43200000 --clear-token aws --token aws_prod=nomics_apios_prod --clear-token env "

rm -f $tmp/herdr-args
PS_SIDEBAR=off
_project_status_precmd; sleep 0.3
ok "switching to off clears tokens once" "$(tr '\n' ' ' < $tmp/herdr-args)" \
   "workspace report-metadata w1 --source project-status --ttl-ms 43200000 --clear-token aws --clear-token aws_prod --clear-token env "
rm -f $tmp/herdr-args; _ps_last_sent=0
_project_status_precmd; sleep 0.2
ok "off stays quiet afterwards" "$([[ -e $tmp/herdr-args ]] && echo sent || echo none)" none
export AWS_PROFILE=nomics_apios_dev

_project_status_exit
ok "zshexit removes state" "$([[ -e $_ps_state_dir/w1:p1 ]] && echo present || echo gone)" gone

# --- self-reload when the hook file changes ----------------------------------
_ps_hook_mtime=0 _ps_last_key=stale
_project_status_precmd
ok "hook reloads itself when its file changed" "$_ps_hook_mtime" "$(zstat +mtime $root/shell/hook.zsh)"
ok "reload ran the new precmd" "$([[ $_ps_last_key == stale ]] && echo stale || echo fresh)" fresh

# --- bar: state written by the v0.1 hook -------------------------------------
mkdir -p $XDG_STATE_HOME/herdr-project-status
print -l "updated=$EPOCHSECONDS" "aws=" "aws_prod=te-gpt-prod · 3h" "env=" \
  "detail.aws=te-gpt-prod · credentials: 3h00m left (until 2026-10-27 01:18)" \
  > $XDG_STATE_HOME/herdr-project-status/old
got=$(zsh -f -c "source <(sed '/^cleanup()/,\$d' $root/bar.zsh)
  load_state old; print -r -- \${st[aws_profile]}/\${st[aws_src]}/\${st[aws_expires]}")
strftime -r -s _exp '%Y-%m-%d %H:%M' '2026-10-27 01:18'
ok "bar reads v0.1 state" "$got" "te-gpt-prod/credentials/$_exp"

# --- prompt cost -------------------------------------------------------------
cd $tmp/proj
_ps_last_sent=$EPOCHSECONDS
float t0=$EPOCHREALTIME
repeat 200 _project_status_precmd
float per_ms=$(( (EPOCHREALTIME - t0) * 1000 / 200 ))
printf 'precmd: %.3f ms/prompt\n' $per_ms
ok "precmd under 2ms" $(( per_ms < 2 )) 1

print "$pass passed, $fail failed"
(( fail == 0 ))
