#!/bin/zsh
set -euo pipefail

APP_DIR="$HOME/Library/Application Support/MSIF14DP"
PLIST="$HOME/Library/LaunchAgents/com.feixqe.msif14dp.plist"
KARABINER_SCRIPT="$HOME/.config/karabiner/scripts/msi_f14_dp.sh"
KARABINER_AGENT="org.pqrs.service.agent.karabiner_console_user_server"

python3 - <<'PY'
import json
import pathlib

config_path = pathlib.Path.home() / ".config" / "karabiner" / "karabiner.json"
data = json.loads(config_path.read_text())
for profile in data.get("profiles", []):
    if profile.get("selected"):
        rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
        profile["complex_modifications"]["rules"] = [
            rule for rule in rules
            if rule.get("description") != "F14 switches MSI monitor input to DP"
        ]
        break
config_path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n")
PY

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$(id -u)/$KARABINER_AGENT" >/dev/null 2>&1 || true
rm -f "$PLIST"
rm -f "$KARABINER_SCRIPT"
rm -rf "$APP_DIR"
rm -f /tmp/msi_f14_dp.log

echo "已卸载 F14 -> DP 切换"
