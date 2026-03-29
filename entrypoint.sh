#!/bin/sh
set -e

echo "=== SSH-Bridge starting - On-demand direct VNC tunnels ==="

# Fix SSH key permissions
chmod 700 /home/sshbridge/.ssh 2>/dev/null || true
chmod 600 /home/sshbridge/.ssh/id_* 2>/dev/null || true

while IFS=' ' read -r local_port ssh_user vnc_host vnc_port extra_opts || [ -n "$local_port" ]; do
    # Skip comments and empty lines
    [ -z "${local_port}" ] && continue
    [ "${local_port#\#}" != "$local_port" ] && continue

    echo "→ Listening on port ${local_port} → ${vnc_host}:${vnc_port} (direct)"

    socat TCP-LISTEN:"${local_port}",reuseaddr,fork,bind=0.0.0.0 \
          EXEC:"ssh -W ${vnc_host}:${vnc_port} ${ssh_user}@${vnc_host} \
                -N -T \
                -o ExitOnForwardFailure=yes \
                -o ConnectTimeout=10 \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                ${extra_opts}" \
          2>&1 | logger -t "ssh-bridge-${local_port}" &
done < /etc/tunnels.conf

echo "All on-demand listeners started."

# Keep container running
exec tail -f /dev/null