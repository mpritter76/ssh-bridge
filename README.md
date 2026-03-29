# SSH-Bridge

A lightweight Docker-based SSH tunnel bridge for on-demand VNC access through jump hosts. Uses `socat` and SSH's `-W` flag to forward local ports to remote VNC servers securely.

## Features

- **On-demand tunneling**: Automatically establishes SSH tunnels to VNC servers on container startup
- **Lightweight**: Alpine-based Docker image with minimal dependencies
- **Secure**: Runs as non-root user with proper SSH key permissions
- **Flexible configuration**: Simple text-based tunnel definitions
- **Auto-reconnect**: Built-in SSH keepalive options for stable long-running connections
- **Multiple tunnels**: Support for 500+ simultaneous listeners

## Prerequisites

- Docker & Docker Compose
- SSH private key(s) for authentication to jump host
- Network access to your jump host and target VNC servers

## Quick Start

### 1. Set up SSH keys

Place your private SSH key in the `ssh-keys/` directory:

```bash
mkdir -p ssh-keys
chmod 700 ssh-keys
cp ~/.ssh/id_rsa ssh-keys/
chmod 600 ssh-keys/id_rsa
```

### 2. Configure tunnels

Edit `tunnels.conf` with your tunnel definitions:

```
# local_port   ssh_user     ssh_jump_host          target_vnc_host       vnc_port   extra_ssh_options
10001          jumpuser     gateway.company.com    vnc-server-001.local  5900       -o ServerAliveInterval=30
10002          jumpuser     gateway.company.com    vnc-server-002.local  5900       -o ServerAliveInterval=30
10003          jumpuser     gateway.company.com    vnc-server-003.local  5900       -o ServerAliveInterval=30
```

**Fields:**
- `local_port`: Port the container listens on (accessible from your host)
- `ssh_user`: SSH username for jump host authentication
- `ssh_jump_host`: Jump host address (hostname or IP)
- `target_vnc_host`: Internal hostname/IP of VNC server (reachable from jump host)
- `vnc_port`: VNC port (typically 5900, or 5901+ for multiple displays)
- `extra_ssh_options`: (Optional) Additional SSH flags

### 3. Start the container

```bash
docker compose up -d ssh-bridge
```

### 4. Connect to VNC

```bash
# Via VNC viewer
vncviewer localhost:10001

# Or SSH tunnel (if not using ssh-bridge)
ssh -L 10001:vnc-server-001.local:5900 jumpuser@gateway.company.com
```

## Configuration

### Docker Compose

The `docker-compose.yml` connects the container to a Docker network (default: `guacamole-net`) and mounts:
- `./ssh-keys` → `/home/sshbridge/.ssh` (read-only)
- `./tunnels.conf` → `/etc/tunnels.conf` (read-only)

Adjust the network name or add port mappings as needed:

```yaml
services:
  ssh-bridge:
    build: ./
    ports:
      - "10001:10001"
      - "10002:10002"
      - "10003:10003"
```

### Tunnel Configuration

Each line in `tunnels.conf` defines one tunnel. Skip empty lines and comments (starting with `#`).

**Example with multiple SSH options:**

```
10010  devops  jump-prod.example.com  internal-vnc.pod  5900  -i /home/sshbridge/.ssh/other_key -p 2222
```

**Common SSH options:**
- `-i /path/to/key`: Specific SSH key (default finds keys in `~/.ssh`)
- `-p PORT`: SSH port (default 22)
- `-o ServerAliveInterval=30`: Send keepalive every 30s
- `-o ConnectTimeout=10`: 10s connection timeout
- `-o StrictHostKeyChecking=no`: Skip host key verification (pre-configure with ssh-keyscan for better security)

## How It Works

1. **Container startup**: Reads `tunnels.conf` and launches a `socat` listener for each tunnel
2. **Incoming connection**: When a client connects to a local port, `socat` spawns an `ssh` subprocess
3. **SSH tunnel**: `ssh -W` creates a transparent tunnel from jump host to target VNC server
4. **Connection forwarding**: Traffic flows: `localhost:10001` → `socat` → `ssh` → `jump-host` → `vnc-server:5900`

## Security Considerations

### ✅ Current Security Measures
- Non-root user (`sshbridge:1000`)
- Read-only mounted volumes for keys and config
- SSH timeout and keepalive settings
- SSH batch mode enabled

### ⚠️ Recommendations

1. **Host key verification**: Pre-populate known hosts to enhance security:
   ```dockerfile
   RUN ssh-keyscan -t rsa gateway.company.com >> /home/sshbridge/.ssh/known_hosts
   ```

2. **Private network deployment**: Run in a Docker network (not exposed to public internet)

3. **Key rotation**: Regularly rotate SSH keys and update mounted volumes

4. **Firewall rules**: Restrict access to tunnel ports (e.g., via Docker networks)

5. **VNC security**: VNC over SSH is better than plain VNC, but consider:
   - VNC with TLS/SSL
   - Restricting VNC server to localhost-only access
   - Disabling VNC authentication if relying on SSH auth

## Troubleshooting

### Check logs

```bash
docker compose logs -f ssh-bridge
```

### Test SSH connection manually

```bash
docker compose exec ssh-bridge ssh -vvv jumpuser@gateway.company.com -W target-vnc:5900
```

### Verify tunnel is listening

```bash
docker compose exec ssh-bridge netstat -tlnp | grep socat
```

### Port already in use

If a port is occupied, change `local_port` in `tunnels.conf` and restart:

```bash
docker compose down
docker compose up -d ssh-bridge
```

### SSH key permission errors

Ensure keys are `600`:

```bash
chmod 600 ssh-keys/id_*
```

### Connection timeouts

- Verify jump host is reachable: `ping gateway.company.com`
- Check SSH server is running on jump host: `ssh jumpuser@gateway.company.com`
- Verify VNC server is accessible from jump host
- Increase `-o ConnectTimeout=` value in `tunnels.conf`

### No VNC connection despite tunnel active

- Verify correct VNC port (5900 is default, but may vary)
- Check firewall on VNC server allows local connections
- Test with `netstat` on jump host: `netstat -an | grep 5900`

## Performance & Limits

- **Resource limits** (optional, for 500+ listeners):
  ```yaml
  ulimits:
    nofile: 8192
  ```

- **TCP timeout**: Adjust SSH keepalive (`ServerAliveInterval`) for unstable networks

- **Memory**: Each tunnel uses minimal resources (~5-10MB), scales linearly

## Advanced Usage

### Multiple SSH keys

```bash
# Add multiple keys to ssh-keys/
cp ~/.ssh/id_rsa ssh-keys/key1
cp ~/.ssh/id_signing_key ssh-keys/key2
chmod 600 ssh-keys/key*
```

SSH will try all available keys in `/home/sshbridge/.ssh`.

### Using SSH config file

Mount an SSH config file:

```yaml
volumes:
  - ./ssh_config:/home/sshbridge/.ssh/config:ro
```

Then simplify `tunnels.conf`:

```
10001  vnc-prod-1  5900
```

### Dynamic port mapping

For development, expose all tunnel ports:

```yaml
ports:
  - "10000-11000:10000-11000"
```

## License

Include your project license here.

## Contributing

Include contribution guidelines here.
