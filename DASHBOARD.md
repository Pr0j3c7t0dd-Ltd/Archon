# Archon Dashboard

**URL:** http://localhost:3090

**Port:** 3090 (HTTP, REST + SSE + web UI all served from this one process)

## How it's running

`archon serve` is managed by launchd as user agent **`diy.archon.serve`**.
It autostarts on login and auto-restarts on crash.

- Binary: `/usr/local/bin/archon` (v0.4.1)
- Web UI: `~/.archon/web-dist/0.4.1/`
- Plist: `~/Library/LaunchAgents/diy.archon.serve.plist`
- Logs: `~/.archon/logs/serve.out.log`, `~/.archon/logs/serve.err.log`

## Common commands

```sh
# Status
launchctl print "gui/$(id -u)/diy.archon.serve" | grep -E "state|pid"

# Restart
launchctl kickstart -k "gui/$(id -u)/diy.archon.serve"

# Stop
launchctl bootout "gui/$(id -u)/diy.archon.serve"

# Start again after stop
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/diy.archon.serve.plist

# Tail logs
tail -F ~/.archon/logs/serve.out.log ~/.archon/logs/serve.err.log

# Update + redeploy (from repo root)
./scripts/deploy.sh
```

## Health check

```sh
curl -s http://localhost:3090/api/health | jq
```
