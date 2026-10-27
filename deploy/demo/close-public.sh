#!/bin/sh
# Run on VPS as root to close ONLY this demo, preserving SSH and unrelated rules.
set -eu
umask 077
BACKUP="/var/backups/yourmettings-close-$(date -u +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP"
cp -a /etc/nftables.conf "$BACKUP/nftables.conf"
cp -a /etc/ssh/sshd_config "$BACKUP/sshd_config"
systemctl disable --now caddy
sed '/YOURMETTINGS_HTTPS/d' /etc/nftables.conf > "$BACKUP/nftables-new.conf"
grep -q 'tcp dport 22 ct state new accept' "$BACKUP/nftables-new.conf"
nft -c -f "$BACKUP/nftables-new.conf"
install -m 644 "$BACKUP/nftables-new.conf" /etc/nftables.conf
nft -f /etc/nftables.conf
awk '
    /^# BEGIN YOURMETTINGS DEMO TUNNEL$/ {skip=1;next}
    /^# END YOURMETTINGS DEMO TUNNEL$/ {skip=0;next}
    !skip {print}
    END {if(skip) exit 2}
' /etc/ssh/sshd_config > "$BACKUP/sshd-new"
sshd -t -f "$BACKUP/sshd-new"
install -m 644 "$BACKUP/sshd-new" /etc/ssh/sshd_config
systemctl reload ssh
printf 'Public demo closed; SSH unchanged. Backup: %s\n' "$BACKUP"
