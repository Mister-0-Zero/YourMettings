#!/bin/sh
# Server-side keepalives release orphaned reverse listeners after PC reboot/VPN loss.
# Only the existing managed alexey block is changed. No firewall or routing changes.
set -eu
umask 077
SOURCE=/etc/ssh/sshd_config
test "$(grep -c '^# BEGIN YOURMETTINGS DEMO TUNNEL$' "$SOURCE")" = 1
test "$(grep -c '^# END YOURMETTINGS DEMO TUNNEL$' "$SOURCE")" = 1
BACKUP="/var/backups/yourmettings-liveness-$(date -u +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP"
cp -a "$SOURCE" "$BACKUP/sshd_config"
awk '
    /^# BEGIN YOURMETTINGS DEMO TUNNEL$/ {managed=1}
    managed && /^[[:space:]]*ClientAlive(Interval|CountMax)[[:space:]]/ {next}
    /^# END YOURMETTINGS DEMO TUNNEL$/ {
        print "    ClientAliveInterval 15"
        print "    ClientAliveCountMax 3"
        managed=0
    }
    {print}
' "$SOURCE" > "$BACKUP/sshd-new"
sshd -t -f "$BACKUP/sshd-new"
sshd -T -f "$BACKUP/sshd-new" -C user=alexey,host=postman.server,addr=127.0.0.1 > "$BACKUP/effective.txt"
grep -qx 'passwordauthentication no' "$BACKUP/effective.txt"
grep -qx 'permitrootlogin no' "$BACKUP/effective.txt"
grep -qx 'authenticationmethods publickey' "$BACKUP/effective.txt"
grep -qx 'allowtcpforwarding remote' "$BACKUP/effective.txt"
grep -qx 'permitlisten 127.0.0.1:18000' "$BACKUP/effective.txt"
grep -qx 'gatewayports no' "$BACKUP/effective.txt"
grep -qx 'clientaliveinterval 15' "$BACKUP/effective.txt"
grep -qx 'clientalivecountmax 3' "$BACKUP/effective.txt"
install -m 644 "$BACKUP/sshd-new" "$SOURCE"
if ! systemctl reload ssh; then
    cp -a "$BACKUP/sshd_config" "$SOURCE"
    systemctl reload ssh
    exit 1
fi
printf 'Managed SSH server keepalives enabled. Backup: %s\n' "$BACKUP"
printf 'Existing SSH sessions retain old settings until they reconnect.\n'
