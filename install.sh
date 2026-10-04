#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/MSIF14DP"
BIN="$APP_DIR/msi-f14-dp"
KARABINER_JSON="$HOME/.config/karabiner/karabiner.json"
KARABINER_SCRIPT="$HOME/.config/karabiner/scripts/msi_f14_dp.sh"
KARABINER_AGENT="org.pqrs.service.agent.karabiner_console_user_server"
PLIST="$HOME/Library/LaunchAgents/com.feixqe.msif14dp.plist"

mkdir -p "$APP_DIR"
mkdir -p "$HOME/.config/karabiner/scripts"

swiftc -Osize \
  -framework Carbon \
  -framework IOKit \
  "$SCRIPT_DIR/main.swift" \
  -o "$BIN"

cat > "$KARABINER_SCRIPT" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail

timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
if "$HOME/Library/Application Support/MSIF14DP/msi-f14-dp" dp --quiet; then
  printf '%s F14 fired result=ok\n' "$timestamp" >> /tmp/msi_f14_dp.log
else
  switch_exit_code=$?
  printf '%s F14 fired result=error status=%s\n' "$timestamp" "$switch_exit_code" >> /tmp/msi_f14_dp.log
  exit "$switch_exit_code"
fi
SCRIPT
chmod +x "$KARABINER_SCRIPT"

cat > "$APP_DIR/route.json" <<'ROUTE'
{
  "includeReportIDByte" : false,
  "primaryUsagePage" : 1,
  "product" : "MSI Monitor MPG 271QR QD-OLED X50",
  "reportID" : 4,
  "reportKind" : "output",
  "reportLength" : 64,
  "transport" : "USB"
}
ROUTE

python3 - <<'PY'
import json
import pathlib
import shlex

config_path = pathlib.Path.home() / ".config" / "karabiner" / "karabiner.json"
data = json.loads(config_path.read_text())

rule = {
    "description": "F14 switches MSI monitor input to DP",
    "manipulators": [
        {
            "from": {"key_code": "f14"},
            "to_if_alone": [
                {"shell_command": shlex.quote(str(pathlib.Path.home() / ".config" / "karabiner" / "scripts" / "msi_f14_dp.sh"))}
            ],
            "type": "basic",
        }
    ],
}

for profile in data.get("profiles", []):
    if profile.get("selected"):
        rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
        rules = [r for r in rules if r.get("description") != rule["description"]]
        rules.append(rule)
        profile["complex_modifications"]["rules"] = rules
        break

config_path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n")
PY

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$(id -u)/$KARABINER_AGENT"

echo "已安装 F14 -> DP 切换"
echo "二进制: $BIN"
echo "Karabiner 脚本: $KARABINER_SCRIPT"
echo "Karabiner 配置: $KARABINER_JSON"
echo "旧 LaunchAgent 已停用: $PLIST"
