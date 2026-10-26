# ~/.config/herdr-project-status/config.zsh — optional overrides. Sourced by the
# shell hook at shell startup and by the project bar when it opens. Every line
# is optional; these are the defaults. Keep scalar settings as plain NAME=value
# lines: the plugin side reads PS_SIDEBAR / PS_BAR_ROWS / PS_TTL_MS from this
# file without running zsh.

# File looked up from $PWD upwards (usually sits at the repo root).
PS_CONFIG_NAME=project.config

# --- project bar --------------------------------------------------------------
# Content rows (herdr adds a border above and below). herdr keeps every split
# at 10% of the tab or more, so short screens may get a few more rows; env
# entries wrap into them.
PS_BAR_ROWS=3

# Sections, top to bottom, one or more rows each. Built-ins: project aws env.
PS_BAR_SECTIONS=(project aws env)

# Add a section: define _ps_section_<name> and list it above. It adds rows with
# `row <label> [<color> <text>]...` (cut to the bar width); $st holds the
# followed pane's state (cwd, config, aws_profile, ...), $cols the bar width,
# and $DIM $TXT $YEL $RED $GRN $BLU are colors. Example (runs git about once a
# second while the bar is open, so keep it cheap):
#
#   PS_BAR_ROWS=4
#   PS_BAR_SECTIONS=(project aws env git)
#   _ps_section_git() {
#     local b; b=$(git -C ${st[cwd]} branch --show-current 2>/dev/null) || return
#     row GIT $TXT ${b:-detached}
#   }

# --- herdr sidebar tokens -----------------------------------------------------
# off  = never touch the sidebar (default)
# prod = only a red $aws_prod token when a prod profile is active
# all  = $aws, $aws_prod and $env (add the rows from herdr.example.toml)
PS_SIDEBAR=off

# How long herdr keeps sidebar tokens without a refresh (max 86400000 = 24h).
PS_TTL_MS=43200000

# --- shared -------------------------------------------------------------------
# Re-write an unchanged status at most this often (keeps the bar's "updated"
# age and the sidebar time-left fresh).
PS_REFRESH_S=60

# Env values longer than this are cut with "…" in the bar, sidebar and prompt.
PS_MAX_LEN=24

# zsh glob patterns: a profile is "prod" when it matches PATTERN but not EXCLUDE.
PS_PROD_PATTERN='*[Pp]rod*'
PS_PROD_EXCLUDE='*[Nn]o[Pp]rod*'

# Between env entries in the sidebar/prompt.
PS_SEPARATOR='  '

# 1 = also export PROJECT_STATUS_AWS/ENV for starship inside herdr.
PS_PROMPT_IN_HERDR=0
