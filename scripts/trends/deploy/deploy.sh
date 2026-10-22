#!/usr/bin/env bash
# Installs or updates 趨勢's daily job on the HK host: build_trends.py into /opt/yuedu-trends and
# the systemd units, then enables the timer. The store in /var/lib/yuedu-trends is kept. Caddy's
# file (./Caddyfile) is installed by hand once; see the plan's T2.
set -euo pipefail

host=${TRENDS_HOST:-ubuntu@43.129.29.13}
key=${TRENDS_KEY:-$HOME/.ssh/yuedu_deploy_ed25519}
here=$(cd "$(dirname "$0")" && pwd)
ssh_options=(-i "$key" -o IdentitiesOnly=yes)

scp "${ssh_options[@]}" "$here/../build_trends.py" "$here/yuedu-trends.service" "$here/yuedu-trends.timer" \
    "$host:/tmp/"
ssh "${ssh_options[@]}" "$host" 'set -e
    id yuedu-trends >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin yuedu-trends
    sudo install -D -m 644 /tmp/build_trends.py /opt/yuedu-trends/build_trends.py
    sudo install -m 644 /tmp/yuedu-trends.service /tmp/yuedu-trends.timer /etc/systemd/system/
    rm /tmp/build_trends.py /tmp/yuedu-trends.service /tmp/yuedu-trends.timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now yuedu-trends.timer
    systemctl list-timers yuedu-trends.timer --no-pager'
