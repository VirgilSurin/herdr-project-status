# ~/.config/herdr-project-status/config.zsh — optional overrides, sourced by
# shell/hook.zsh at shell startup. Every line is optional; these are the defaults.

# File looked up from $PWD upwards (usually sits at the repo root).
PS_CONFIG_NAME=project.config

# Env values longer than this are cut with "…" in the sidebar/prompt.
PS_MAX_LEN=24

# How long herdr keeps the tokens without a refresh (max 86400000 = 24h).
PS_TTL_MS=43200000

# Re-send an unchanged status at most this often, so the time left stays fresh.
PS_REFRESH_S=60

# zsh glob patterns: a profile is "prod" when it matches PATTERN but not EXCLUDE.
PS_PROD_PATTERN='*[Pp]rod*'
PS_PROD_EXCLUDE='*[Nn]o[Pp]rod*'

# Between env entries.
PS_SEPARATOR='  '

# 1 = also export PROJECT_STATUS_AWS/ENV for starship inside herdr.
PS_PROMPT_IN_HERDR=0
