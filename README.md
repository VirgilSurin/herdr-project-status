# herdr-project-status

A **project bar** for herdr: a few live rows at the bottom of a tab. It shows the following for the pane you're focused on:

- the **active AWS profile** and how long its session has left (prod gets a red ⚠ PROD badge)
- the **env vars your project cares about**, chosen per repo with a `project.config` file
- anything else you add as a custom section

```
┌ your pane ────────────────────────────────────────────────────────────────┐
│ $ npm run dev                                                             │
├ Project ──────────────────────────────────────────────────────────────────┤
│ my-api  ~/work/my-api                                     updated just now │
│ AWS  nomics_apios_dev · sso 42m left (until 14:32)                         │
│ ENV  NODE_ENV development · stage dev · DATABASE_URL ✓ · API_TOKEN ✗       │
└───────────────────────────────────────────────────────────────────────────┘
```

It comes in two forms, and you can use either or both:

- **Project bar:** a herdr pane at the bottom of the tab, toggled with `prefix+i`.
- **Modeline:** a single row at the bottom of each shell, like an nvim or emacs modeline. Turn it on per project with `@modeline = on` in `project.config` (see [Modeline](#modeline)).

The bar is toggled per tab (`prefix+i`). It follows focus within its tab and counts the session down live. It stays visible while nvim or Claude Code run in the other panes. Outside herdr, in a plain Ghostty tab, the same values can show in your starship prompt.

## How it works

Env vars only exist inside each shell, so the plugin can't read them directly:

| Part | Job |
| --- | --- |
| `shell/hook.zsh` | A zsh `precmd` hook. On every prompt it finds the nearest `project.config`, works out the status, and writes it to a small per-pane state file. It forks nothing on the prompt path (about 0.1 ms per prompt), and it reloads itself when its file changes, so updates reach shells that are already open. |
| `shell/modeline.zsh` | The modeline. The shell keeps the terminal's last row for itself and draws the status there. |
| `bar.zsh` | The bar, running in a herdr plugin pane. About once a second it asks herdr which pane is focused in its tab, reads that pane's state file, and redraws only if the output changed. |
| `project-status.sh` | The plugin's actions and events. It opens and closes the bar, cleans up state from closed panes, and provides the details and doctor overlays. It also reports the optional sidebar tokens. |

AWS expiry is taken from `AWS_CREDENTIAL_EXPIRATION` / `AWS_SESSION_EXPIRATION` (set by Granted's `assume`). If neither is set, it uses the profile's SSO session token in `~/.aws/sso/cache`. Nothing calls AWS over the network.

### Where the bar docks, and why it's a pane

herdr 0.7.5 has no API for a status bar or for plugin-defined sidebar sections; the sidebar is drawn by herdr itself. A plugin *can* open its own pane, so the bar is a real pane:

- It opens below the tab's **bottom-most full-width pane**, so it spans the whole tab when the layout has one: a single pane, or anything stacked above a full-width pane.
- With only side-by-side panes, it docks under the focused pane.
- Existing panes are only resized; none of them restart.
- herdr keeps every split at 10% of the pane or more. On a short screen, or when docked under a tall pane, the bar can therefore come out a little taller than `PS_BAR_ROWS`. Env entries wrap into the extra rows.

## Install

There are two ways to use it. The shell hook is the same in both.

### Standalone (any terminal, no herdr)

You get the modeline, the starship segments and the `@env` background tint. It needs only zsh, and `direnv` if you want values from `.envrc` files.

```zsh
# 1. get the code anywhere
git clone <repo-url> ~/path/to/herdr-project-status

# 2. in ~/.zshrc, AFTER `eval "$(direnv hook zsh)"` if you use direnv
source ~/path/to/herdr-project-status/shell/hook.zsh
```

3. Open a new shell. Create a `project.config` at a repo root:
   ```
   @modeline = on
   NODE_ENV
   ```
   The next prompt in that repo draws the status on the terminal's last row. To get it in every directory instead, put `PS_MODELINE=on` in `~/.config/herdr-project-status/config.zsh` (see [`config.example.zsh`](config.example.zsh)).
4. Optional: add the prompt segments from [`starship.example.toml`](starship.example.toml) to `~/.config/starship.toml`.

To uninstall, remove the `source` line and open a new shell. Nothing else is written outside herdr. Without herdr there are no state files, and the bar pane, the details overlay and the doctor action aren't available.

### With herdr (adds the project bar)

This is the standalone setup plus the plugin, which needs herdr 0.7.5 or newer. If you installed the plugin from GitHub, the loop in step 2 finds the hook inside the plugin's folder, so there's no separate clone.

```sh
# 1. the plugin
herdr plugin install <you>/herdr-project-status --yes     # from GitHub
herdr plugin link ~/path/to/herdr-project-status          # or a local checkout
```

```zsh
# 2. the shell hook, in ~/.zshrc AFTER `eval "$(direnv hook zsh)"`
for _f in ~/path/to/herdr-project-status/shell/hook.zsh(N) \
          ~/.config/herdr/plugins/github/*project-status*/shell/hook.zsh(N); do
  source $_f; break
done; unset _f
```

3. Add the key bindings from [`herdr.example.toml`](herdr.example.toml) to `~/.config/herdr/config.toml`, then run `herdr server reload-config`.
4. Optional: add the prompt segments from [`starship.example.toml`](starship.example.toml) to `~/.config/starship.toml`.

Run the **doctor** action (`herdr plugin action invoke project-status.doctor`) to check each step and print any snippet that's missing.

| Action | Default key | What it does |
| --- | --- | --- |
| `project-status.bar` | `prefix+i` | Toggle the bar in the current tab. Press `q` in the bar to close it too. |
| `project-status.show` | `prefix+shift+i` | Overlay with the full, untruncated values. |
| `project-status.doctor` | none | Install check. |

## Modeline

```
│ $ npm run dev                                                              │
│ ready on :3000                                                             │
│ ❯ █                                                                        │
│ my-api │ AWS nomics_apios_dev 42m │ NODE_ENV development · stage dev · DB ✓ │
```

Add `@modeline = on` to a project's `project.config`, and every shell inside that project draws its status on the terminal's last row. It's 1 row per pane, so each pane shows its own project. It works the same in a plain Ghostty tab. Leaving the project gives the row back. `PS_MODELINE=on` turns it on everywhere, and `@modeline off` turns it back off for one project.

- **How:** the shell sets a scroll region over every row but the last and draws there. The row is drawn when the line editor starts, redrawn after ctrl-L, a resize, or a prompt redraw (vi-mode switches), and every 30 s at an idle prompt so the AWS time left counts down.
- **While commands run:** the row stays (`PS_MODELINE_KEEP=1`), so it's still there under `npm run dev`. Full-screen apps that use the alternate screen (nvim) simply cover it. Programs that draw inline over the whole screen, like Claude Code, fzf or less, are listed in `PS_MODELINE_YIELD` and get the row back while they run.
- **Theme:** colours are palette indexes, so the row follows your terminal theme. `PS_MODELINE_BG` / `PS_MODELINE_FG` take a palette index, `#rrggbb`, or `none`/`default`.
- **Custom sections:** define `_ps_modeline_<name>` in your config and add it to `PS_MODELINE_SECTIONS`. The example file has a git branch one.
- **Starship:** while the modeline shows, the `PROJECT_STATUS_AWS`/`ENV` prompt segments are left out. The prod warning stays.

## project.config

Put it at the repo root. It is looked up from `$PWD` upwards and re-read whenever it changes.

```
# one env var per line, `#` comments
NODE_ENV                # NODE_ENV  <value>
stage=APP_STAGE         # stage     <value of APP_STAGE>
DATABASE_URL:set        # ✓ / ✗ only, never the value
@modeline = on          # an option: lines starting with @ (bare `@modeline` means on)
```

The values of `:set` entries are never stored or displayed.

### Env tint

`@env` lines tint the pane's background while the active AWS profile matches, so you can see at a glance which environment a shell is pointed at:

```
@env dev  = *noprod OR te-gpt-sandbox, blue
@env test = *uat | *qa, yellow
@env prod = *prod, #3a0d0d
```

- **Matching:** rules are checked in file order and the first match wins, so put `*noprod` before `*prod`. Separate alternatives with `OR` or `|`. Patterns are zsh globs (`*`, `?`) over the whole profile name, case-insensitive.
- **Colours:** `blue`, `green`, `yellow`, `orange`, `red`, `purple`, `cyan` and `gray` are dark tints made for dark themes. On a light theme, use `#rrggbb`. `none` matches a profile without tinting it.
- **How:** the hook sets the terminal background with OSC 11 on every prompt while a rule matches. When the profile no longer matches, you leave the project or the shell exits, it sends OSC 111 once, which brings back the theme's background. Both sequences work in herdr panes and in Ghostty.
- The matched env name shows in the details overlay (`prefix+shift+i`).

## Settings

Copy [`config.example.zsh`](config.example.zsh) to `~/.config/herdr-project-status/config.zsh`. It covers:

- **Modeline:** `PS_MODELINE` (default for directories whose project.config doesn't say), `PS_MODELINE_SECTIONS`, `PS_MODELINE_BG`/`FG`, `PS_MODELINE_KEEP`, `PS_MODELINE_YIELD`, `PS_MODELINE_TICK_S`.
- **Bar:** `PS_BAR_ROWS` (content rows, default 3) and `PS_BAR_SECTIONS` (order and selection).
- **Custom sections:** define `_ps_section_<name>` in the same file and add it to `PS_BAR_SECTIONS`. The example file has a git branch section.
- **Sidebar tokens:** `PS_SIDEBAR=off` (default), `prod` (a red `$aws_prod` warning only) or `all` (`$aws`, `$aws_prod`, `$env`; add the commented rows in `herdr.example.toml`).
- File name, truncation, prod pattern, refresh interval, starship behaviour.

## Files it touches

- `~/.local/state/herdr-project-status/<pane_id>`: one small key=value file per reporting pane. It is removed when the pane's shell exits or the pane closes.
- `~/.local/state/herdr-project-status/bars/<tab_id>`: the bar's pane id for each tab, used by the toggle.
- Sidebar metadata from the source `project-status`, only when `PS_SIDEBAR` isn't `off`.

## Development

```sh
zsh tests/run.zsh      # parsing, @options, expiry, SSO fallback, prod split, modeline rendering and escapes, sidebar modes, state file, prompt cost
```

herdr facts this relies on, all checked against 0.7.5:
- `herdr workspace report-metadata` needs the workspace id *before* its options.
- Custom sidebar tokens are written `"$name"`; a bare `"name"` is rejected by `herdr config check`.
- `plugin pane open` only takes `--width`/`--height` for popups, so the bar is sized with `pane resize --amount` (a fraction of the split, clamped by herdr to 0.1–0.9).
- `layout.apply` recreates every pane (new terminals), so it can't be used to rearrange a tab that has live shells.
- `layout.export` leaves plugin panes out.
- In its terminal (libghostty), scrollback keeps growing while a scroll region starts at row 1. zle clears below the prompt whenever it draws it, so the modeline is drawn from `zle-line-init`, not `precmd`.

## Limitations

- herdr doesn't restore plugin panes after a server restart, so toggle the bar again afterwards.
- Values come from each shell's last prompt. A pane that is mid-command shows what it had when the command started; the time left keeps counting down regardless.
- The modeline is hidden while an alternate-screen app (nvim) or a yielding program runs. A completion list can cover it until the next prompt or idle tick.
- A program that resets the scroll region and leaves the cursor on the last row (Claude Code does on exit) is handled: every prompt frees the last row again. If the row ever looks wrong, ctrl-L redraws it.
- zsh only.
