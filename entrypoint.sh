#!/bin/sh
set -e

echo "=== SSH Relay starting - On-demand direct VNC tunnels ==="

# Fix SSH key permissions (covers all key files, not just id_*)
chmod 700 /home/sshrelay/.ssh 2>/dev/null || true
find /home/sshrelay/.ssh -maxdepth 1 -type f ! -name '*.pub' ! -name 'config' ! -name 'known_hosts' -exec chmod 600 {} \; 2>/dev/null || true

CTRL_DIR="/tmp/ssh-ctrl"
SCRIPT_DIR="/tmp/ssh-tunnel"
mkdir -p "$CTRL_DIR" "$SCRIPT_DIR"

while IFS=' ' read -r local_port ssh_user remote_host remote_port extra_opts || [ -n "$local_port" ]; do
    # Skip comments and empty lines
    [ -z "${local_port}" ] && continue
    [ "${local_port#\#}" != "$local_port" ] && continue

    ctrl_path="${CTRL_DIR}/${ssh_user}_${remote_host}"
    tunnel_script="${SCRIPT_DIR}/tunnel-${local_port}.sh"

    # Write a per-tunnel wrapper script so socat EXEC receives a plain path with no
    # colons — socat's EXEC address type would misparse 'ssh -W host:port' if passed
    # inline. ControlMaster=auto + ControlPersist means the first connection to a
    # host establishes a persistent multiplexed SSH session; all subsequent socat
    # fork()s reuse it instantly with no re-authentication overhead. This scales to
    # 500+ tunnels with no startup delay and no idle ControlMaster processes.
    cat > "${tunnel_script}" <<EOF
#!/bin/sh
exec ssh -W ${remote_host}:${remote_port} ${ssh_user}@${remote_host} \
     -N -T \
     -o ControlMaster=auto \
     -o ControlPath=${ctrl_path} \
     -o ControlPersist=60 \
     -o ConnectTimeout=10 \
     -o ExitOnForwardFailure=yes \
     -o ServerAliveInterval=15 \
     -o ServerAliveCountMax=3 \
     -o BatchMode=yes \
     -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null \
     ${extra_opts}
EOF
    chmod +x "${tunnel_script}"

    echo "Listening on port ${local_port} -> ${remote_host}:${remote_port}"

    socat TCP-LISTEN:"${local_port}",reuseaddr,fork,bind=0.0.0.0 \
          EXEC:"${tunnel_script}" \
          2>&1 | sed "s/^/[ssh-relay-${local_port}] /" &
done < /etc/tunnels.conf

echo "All on-demand listeners started."

# Keep container running
exec tail -f /dev/null