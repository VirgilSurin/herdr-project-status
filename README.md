# herdr-project-status

A status bar for herdr that shows, for the pane you are working in:

- the **active AWS profile** and how long its session has left. Prod profiles are shown in red.
- the **env vars your project cares about**, chosen per repo through a `project.config` file.

```
● my-api
  main ✓
  nomics_apios_dev · 42m
  NODE_ENV=development  stage=dev  DATABASE_URL ✓
```

It renders in herdr's sidebar. Outside herdr (a plain Ghostty tab), the same values can show in your starship prompt.

## How it works

Env vars only exist inside each shell, so a herdr plugin can't read them on its own. The package has two halves:

| Part | Job |
| --- | --- |
| `shell/hook.zsh` | A zsh `precmd` hook. On every prompt it finds the nearest `project.config` and works out the status. When the status changes, it pushes it to herdr as workspace metadata tokens (`$aws`, `$aws_prod`, `$env`). It forks nothing on the prompt path (about 0.1 ms per prompt) and calls herdr in the background only when something changed. |
| `herdr-plugin.toml` + `project-status.sh` | The herdr plugin. On focus and close events it re-reports each workspace from the pane you're looking at, using the per-pane state files the hook writes, and it removes state left by closed panes. It also provides the **details** and **doctor** overlays. |

AWS expiry is taken from `AWS_CREDENTIAL_EXPIRATION` / `AWS_SESSION_EXPIRATION` (set by Granted's `assume`). If neither is set, it uses the profile's SSO session token in `~/.aws/sso/cache`. Nothing calls AWS over the network.

## Install

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

3. Add the sidebar rows from [`herdr.example.toml`](herdr.example.toml) to `~/.config/herdr/config.toml`, then run `herdr server reload-config`.
   Optionally, bind the details overlay:
   ```toml
   [[keys.command]]
   key = "prefix+i"
   type = "plugin_action"
   command = "project-status.show"
   ```
4. Optional: add the prompt segments from [`starship.example.toml`](starship.example.toml) to `~/.config/starship.toml`.

Run the **doctor** action (`herdr plugin action invoke project-status.doctor`) to check each step and print any snippet that's missing.

## project.config

Put it at the repo root. It is looked up from `$PWD` upwards and re-read whenever it changes.

```
# one env var per line, `#` comments
NODE_ENV                # NODE_ENV=<value>
stage=APP_STAGE         # stage=<value of APP_STAGE>
DATABASE_URL:set        # ✓ / ✗ only, never the value
```

Long values are cut to 24 characters in the sidebar. The details overlay shows them in full, except `:set` entries, which are never stored or displayed.

## Settings

Copy [`config.example.zsh`](config.example.zsh) to `~/.config/herdr-project-status/config.zsh` and change what you need. The settings cover the file name, truncation length, prod pattern, TTL, refresh interval, and whether the prompt also shows values inside herdr.

## Files it touches

- `~/.local/state/herdr-project-status/<pane_id>`: one small key=value file per reporting pane. It is removed when the pane's shell exits or the pane closes.
- herdr workspace metadata from the source `project-status`, which expires after `PS_TTL_MS` if it isn't refreshed.

## Development

```sh
zsh tests/run.zsh      # parsing, expiry, SSO fallback, prod split, state file, prompt cost
```

Notes:
- Under the shell, `herdr workspace report-metadata` needs the workspace id *before* its options.
- Custom sidebar tokens are written `"$name"`; a bare `"name"` is rejected by `herdr config check`.

## Limitations

- The time left only refreshes on a prompt, or at most every `PS_REFRESH_S` seconds while you type commands. An idle pane keeps showing its last value.
- Panes share one set of workspace tokens. Whichever pane is focused, or prompted last, wins.
- zsh only.
