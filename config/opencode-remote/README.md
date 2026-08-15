# ocremote — opencode serve + telegram bridge

One command for the stack you used to start by hand:

```bash
opencode serve --port 4096 &
opencode-telegram start
```

## Use

```bash
ocremote            # status (agent / serve / bot)
ocremote start
ocremote stop
ocremote restart
ocremote logs -f    # follow serve + bot + launchd logs
ocremote install    # always-on at login (launchd KeepAlive)
ocremote uninstall
```

## How it fits together

| Piece | Role |
| --- | --- |
| `ocremote` | Human seam — only thing you type |
| `remote-launch.sh` | Process owner — starts serve (or reuses a healthy one), waits for health, runs the bot in the foreground |
| `com.hhouse.opencode-remote` | launchd unit — RunAtLoad + KeepAlive after `install` |

Port and URL come from the bot's own config
(`OPENCODE_API_URL` in `~/Library/Application Support/opencode-telegram-bot/.env`).
No second hardcoded copy.

## Setup (once per machine)

```bash
# from the dotfiles root — links ~/.config/opencode-remote and ~/go/bin/ocremote
./install

# optional: come up at login and stay up
ocremote install
```

Needs `opencode` and `opencode-telegram` on PATH, and a configured bot
(`opencode-telegram config` once).
