# Setup

## 1. `ssh kindle`

Start KOReader's SSH server on the Kindle (Settings → Network → SSH server); it shows the Kindle's IP. Copy your computer's public key into `koreader/settings/SSH/authorized_keys` on the Kindle over USB, then add to `~/.ssh/config`:

```
Host kindle
    HostName 192.168.1.50   # the Kindle's IP
    Port 2222
    User root
```

Check with `ssh kindle true`.

## 2. Kindle key pair

The Kindle signs in to the computer with its own key. KOReader's SSH client only reads Dropbear-format keys:

```sh
sudo pacman -S dropbear   # Debian/Ubuntu: sudo apt install dropbear-bin
dropbearkey -t ed25519 -f id_laptop | grep '^ssh-ed25519' > ~/.ssh/kindle_to_laptop.pub
ssh kindle 'cat > /mnt/us/koreader/settings/SSH/id_laptop' < id_laptop
rm id_laptop
```

## What the scripts change

`setup-laptop.sh`:
- authorizes the Kindle's key in `~/.ssh/authorized_keys`, restricted to running `server/kindle_ask.py`
- turns off password logins for sshd, and starts sshd now and at boot
- opens port 22 in ufw for `SUBNET` only

`install-kindle.sh`:
- copies the plugin to the Kindle
- points it at this computer (`koreader/settings/askclaude/computer.lua`)
- pins this computer's SSH host key on the Kindle
