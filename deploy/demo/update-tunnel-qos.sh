#!/bin/sh
# Connection-only tuning; no VPN/route/firewall changes.
set -eu
umask 077
SOURCE=/etc/ssh/sshd_config
grep -q '^# BEGIN YOURMETTINGS DEMO TUNNEL$' "$SOURCE"
BACKUP="/var/backups/yourmettings-qos-$(date -u +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP"
cp -a "$SOURCE" "$BACKUP/sshd_config"
awk '
    /^# BEGIN YOURMETTINGS DEMO TUNNEL$/ {managed=1}
    managed && /^[[:space:]]*IPQoS / {next}
    {print}
    managed && /^[[:space:]]*GatewayPorts no$/ {print "    IPQoS none"}
    /^# END YOURMETTINGS DEMO TUNNEL$/ {managed=0}
' "$SOURCE" > "$BACKUP/sshd-new"
sshd -t -f "$BACKUP/sshd-new"
sshd -T -f "$BACKUP/sshd-new" -C user=alexey,host=postman.server,addr=127.0.0.1 > "$BACKUP/effective.txt"
grep -qx 'passwordauthentication no' "$BACKUP/effective.txt"
grep -qx 'permitrootlogin no' "$BACKUP/effective.txt"
grep -qx 'permitlisten 127.0.0.1:18000' "$BACKUP/effective.txt"
grep -qx 'ipqos none none' "$BACKUP/effective.txt"
install -m 644 "$BACKUP/sshd-new" "$SOURCE"
systemctl reload ssh
printf 'SSH QoS updated only for alexey. Backup: %s\n' "$BACKUP"
