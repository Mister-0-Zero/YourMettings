#!/bin/sh
# Run only on the designated VPS as root after reviewing this script/configs.
# Installs a bootstrap 503 gateway; activating the proxy is a separate step.
set -eu
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BACKUP="/var/backups/yourmettings-demo-$(date -u +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP"
cp -a /etc/ssh/sshd_config "$BACKUP/sshd_config"
cp -a /etc/nftables.conf "$BACKUP/nftables.conf"
nft list ruleset > "$BACKUP/ruleset.nft"
sshd -T > "$BACKUP/sshd-effective.txt"
printf '%s\n' "$BACKUP" > /var/backups/yourmettings-demo-latest

# Official Caddy signed repository, not a downloaded shell installer.
apt-get -o Acquire::Retries=2 update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl gpg ca-certificates
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$BACKUP/caddy-key.asc"
gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$BACKUP/caddy-key.asc"
chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
chmod 644 /etc/apt/sources.list.d/caddy-stable.list
apt-get -o Acquire::Retries=2 update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy
systemctl stop caddy
cp -a /etc/caddy/Caddyfile "$BACKUP/Caddyfile"
install -m 644 "$SCRIPT_DIR/Caddyfile.bootstrap" /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# A Match block must be at the END of the main file, after global directives.
if ! grep -q '^# BEGIN YOURMETTINGS DEMO TUNNEL$' /etc/ssh/sshd_config; then
    cp /etc/ssh/sshd_config "$BACKUP/sshd-new"
    cat >> "$BACKUP/sshd-new" <<'EOF'

# BEGIN YOURMETTINGS DEMO TUNNEL
Match User alexey
    AllowTcpForwarding remote
    PermitListen 127.0.0.1:18000
    GatewayPorts no
    IPQoS none
    ClientAliveInterval 15
    ClientAliveCountMax 3
# END YOURMETTINGS DEMO TUNNEL
EOF
    sshd -t -f "$BACKUP/sshd-new"
    sshd -T -f "$BACKUP/sshd-new" -C user=alexey,host=postman.server,addr=127.0.0.1 > "$BACKUP/sshd-new-effective.txt"
    grep -qx 'passwordauthentication no' "$BACKUP/sshd-new-effective.txt"
    grep -qx 'permitrootlogin no' "$BACKUP/sshd-new-effective.txt"
    grep -qx 'allowtcpforwarding remote' "$BACKUP/sshd-new-effective.txt"
    grep -qx 'permitlisten 127.0.0.1:18000' "$BACKUP/sshd-new-effective.txt"
    grep -qx 'clientaliveinterval 15' "$BACKUP/sshd-new-effective.txt"
    grep -qx 'clientalivecountmax 3' "$BACKUP/sshd-new-effective.txt"
    install -m 644 "$BACKUP/sshd-new" /etc/ssh/sshd_config
    systemctl reload ssh
fi

# Add only IPv4 443, leaving the existing SSH/established/default-drop policy intact.
if ! grep -q 'YOURMETTINGS_HTTPS' /etc/nftables.conf; then
    grep -q 'tcp dport 22 ct state new accept' /etc/nftables.conf
    sed '/tcp dport 22 ct state new accept/a\        ip daddr 194.117.80.169 tcp dport 443 ct state new accept comment "YOURMETTINGS_HTTPS"' /etc/nftables.conf > "$BACKUP/nftables-new.conf"
    nft -c -f "$BACKUP/nftables-new.conf"
    grep -q 'tcp dport 22 ct state new accept' "$BACKUP/nftables-new.conf"
    install -m 644 "$BACKUP/nftables-new.conf" /etc/nftables.conf
    nft -f /etc/nftables.conf
fi
systemctl enable nftables
systemctl enable --now caddy
caddy version
sshd -T -C user=alexey,host=postman.server,addr=127.0.0.1 | grep -E 'passwordauthentication|permitrootlogin|allowtcpforwarding|permitlisten|gatewayports'
printf 'Bootstrap installed. Backup: %s\n' "$BACKUP"
