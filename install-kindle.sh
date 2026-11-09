#!/usr/bin/env bash
# Copy the plugin to the Kindle, point it at this laptop, and pin this laptop's
# SSH host key there. Needs `ssh kindle` to work (KOReader's SSH server running
# on the Kindle). Override the detected address or user with LAPTOP_IP / LAPTOP_USER.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAPTOP_IP="${LAPTOP_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')}"
LAPTOP_USER="${LAPTOP_USER:-$(id -un)}"

tar -C "$HERE" -cf - askclaude.koplugin | ssh kindle 'tar -C /mnt/us/koreader/plugins -xf -'
echo "Plugin copied."

# Pre-trust the laptop's host key, so the Kindle never has to accept an unknown one.
{ printf '%s ' "$LAPTOP_IP"; cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub; } |
    ssh kindle 'mkdir -p /mnt/us/koreader/settings/askclaude/.ssh &&
                cat > /mnt/us/koreader/settings/askclaude/.ssh/known_hosts'
echo "Laptop host key ($LAPTOP_IP) pinned on the Kindle."

printf 'return { host = "%s", user = "%s" }\n' "$LAPTOP_IP" "$LAPTOP_USER" |
    ssh kindle 'cat > /mnt/us/koreader/settings/askclaude/computer.lua'
echo "Kindle set to connect to $LAPTOP_USER@$LAPTOP_IP."
echo "Restart KOReader to load the plugin."
