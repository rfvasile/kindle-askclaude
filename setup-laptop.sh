#!/usr/bin/env bash
# One-time laptop setup for Ask Claude. Run it yourself (it uses sudo):
#   bash setup-laptop.sh
#
# 1. Authorizes the Kindle's key, locked to kindle_ask.py: no shell, no port forwarding.
# 2. Makes the SSH server keys-only (no password logins). sshd was off before this,
#    so no existing logins depend on passwords.
# 3. Starts sshd now and at boot, and opens port 22 in ufw for the home network only.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/server/kindle_ask.py"
PUB="$HOME/.ssh/kindle_to_laptop.pub"
AK="$HOME/.ssh/authorized_keys"
SUBNET="${SUBNET:-192.168.1.0/24}"

[ -f "$PUB" ] || { echo "missing $PUB" >&2; exit 1; }

touch "$AK"
chmod 700 "$HOME/.ssh"
chmod 600 "$AK"
if grep -qF "$(awk '{print $2}' "$PUB")" "$AK"; then
    echo "Kindle key already authorized."
else
    printf 'command="/usr/bin/python3 -I %s",restrict %s\n' "$SCRIPT" "$(cat "$PUB")" >> "$AK"
    echo "Authorized the Kindle key (restricted to kindle_ask.py)."
fi

sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf >/dev/null <<'EOF'
# Added by Ask Claude setup: key-based SSH logins only.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t
sudo systemctl enable sshd
sudo systemctl restart sshd
echo "SSH server running (keys only)."

if systemctl is-active -q ufw; then
    sudo ufw allow from "$SUBNET" to any port 22 proto tcp comment 'Ask Claude (Kindle)'
fi
echo "Done."
