#!/bin/sh
set -eu

LOG_FOLDER="${XUI_LOG_FOLDER:-/var/log/x-ui}"
mkdir -p "$LOG_FOLDER"

if [ "$XUI_ENABLE_FAIL2BAN" = "true" ]; then
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d
    touch "$LOG_FOLDER/3xipl.log" "$LOG_FOLDER/3xipl-banned.log"

    cat > /etc/fail2ban/jail.d/00-container-defaults.conf << 'EOF'
[DEFAULT]
backend = auto
banaction = iptables-allports
bantime = 30m
findtime = 32
maxretry = 1

[sshd]
enabled = false

[sshd-ddos]
enabled = false

[ssh]
enabled = false
EOF

    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled = true
backend = auto
filter = 3x-ipl
action = 3x-ipl
logpath = $LOG_FOLDER/3xipl.log
maxretry = 1
findtime = 32
bantime = 30m
EOF

    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex = [LIMIT_IP]s*Emails*=s*<F-USER>.+</F-USER>s*||s*Disconnecting OLD IPs*=s*<ADDR>s*||s*Timestamps*=s*d+
ignoreregex =
EOF

    SSH_PORTS=$(grep -oE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | grep -oE '[0-9]+' | paste -sd, - || true)
    [ -z "$SSH_PORTS" ] && SSH_PORTS="22"
    PANEL_PORT=$(/app/x-ui setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}' || true)
    EXEMPT_PORTS="$SSH_PORTS"
    [ -n "$PANEL_PORT" ] && EXEMPT_PORTS="$EXEMPT_PORTS,$PANEL_PORT"

    cat > /etc/fail2ban/action.d/3x-ipl.conf << EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ 	]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_FOLDER/3xipl-banned.log

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <Email> [IP] = <ip> unbanned." >> $LOG_FOLDER/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = $EXEMPT_PORTS
EOF

    if fail2ban-client -t >/dev/null 2>&1; then
        fail2ban-client -x start >/dev/null 2>&1 || true
    else
        echo "WARN - Fail2ban configuration validation failed; continuing without Fail2ban" >&2
    fi
fi

if [ -f /root/.acme.sh/acme.sh ]; then
    /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true
    crond
fi

exec /app/x-ui
