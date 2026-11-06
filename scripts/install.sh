#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build.sh"
app_dir="$HOME/Applications/SpacePaper.app"
agent_file="$HOME/Library/LaunchAgents/local.kitano.spacepaper.plist"
state_dir="$HOME/Library/Application Support/SpacePaper"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$state_dir"
login_enabled=1
if [[ -d "$app_dir" && ! -f "$agent_file" ]]; then
    login_enabled=0
fi
# Stop the registered job first. Never send a durable quit to an absent process.
/bin/launchctl bootout "gui/$(id -u)/local.kitano.spacepaper" 2>/dev/null || true
"$project_dir/dist/SpacePaper.app/Contents/MacOS/SpacePaper" --quit 2>/dev/null || true
python3 - "$state_dir/instance.lock" <<'PY'
import fcntl, sys, time
with open(sys.argv[1], 'a') as lock:
    deadline = time.monotonic() + 5
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SystemExit('SpacePaperが終了していません。アプリの更新を中止します。')
            time.sleep(0.1)
PY
if [[ -d "$app_dir" ]]; then
    backup_dir="$project_dir/.history/$(date +%Y%m%dT%H%M%S)"
    mkdir -p "$backup_dir"
    mv "$app_dir" "$backup_dir/SpacePaper.app"
fi
ditto "$project_dir/dist/SpacePaper.app" "$app_dir"
if (( login_enabled )); then
python3 - "$app_dir" "$agent_file" "$state_dir" <<'PY'
import plistlib, sys
from pathlib import Path
app, agent, state = map(Path, sys.argv[1:])
value = {
    'Label': 'local.kitano.spacepaper',
    'ProgramArguments': [str(app / 'Contents/MacOS/SpacePaper')],
    'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
    'ThrottleInterval': 15, 'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Interactive',
    'StandardOutPath': str(state / 'launch.log'),
    'StandardErrorPath': str(state / 'launch.error.log'),
}
agent.write_bytes(plistlib.dumps(value))
PY
/bin/launchctl bootstrap "gui/$(id -u)" "$agent_file"
else
    /usr/bin/open -g "$app_dir"
fi
python3 - "$state_dir/instance.json" <<'PY'
import json, os, sys, time
from pathlib import Path
identity = Path(sys.argv[1])
deadline = time.monotonic() + 10
while True:
    try:
        value = json.loads(identity.read_text())
        os.kill(value['pid'], 0)
        break
    except (OSError, ValueError, KeyError):
        if time.monotonic() >= deadline:
            raise SystemExit('SpacePaperの起動を確認できません。launch.error.logを確認してください。')
        time.sleep(0.1)
PY
"$app_dir/Contents/MacOS/SpacePaper" --reconcile
print "Installed and started: $app_dir"
