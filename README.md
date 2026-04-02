# SSH Relay

A lightweight Docker-based SSH tunnel relay for on-demand VNC access. Uses `socat`
and OpenSSH's `-W` proxy flag to forward local ports to remote VNC servers through
SSH — no persistent tunnels, no VPN, no open inbound firewall rules required.

Deployed alongside Guacamole on an internal Docker bridge network. Guacamole's `guacd`
daemon connects to `ssh-relay:<local_port>` as if it were a direct VNC server;
ssh-relay transparently forwards the traffic through an SSH tunnel to the real
VNC server.

## Features

- **On-demand tunneling**: socat listeners start at container startup; SSH is only
  invoked when a client actually connects
- **SSH multiplexing**: ControlMaster/ControlPersist means the first VNC session to a
  host authenticates SSH; subsequent sessions reuse the existing connection instantly
- **Lightweight**: Alpine-based Docker image with minimal dependencies (~20 MB)
- **Secure**: Runs as non-root user (`sshrelay:1000`) with read-only key mounts
- **Flexible configuration**: Simple text-based `tunnels.conf` — one line per tunnel
- **Scales to 500+ tunnels**: Zero startup overhead regardless of tunnel count

## Prerequisites

- Docker & Docker Compose
- SSH private key(s) with access to the remote hosts
- Remote hosts must have SSH running and `AllowTcpForwarding yes` (default on most
  Linux/Windows SSH servers)
- VNC server running on each remote host

## Quick Start

### 1. Set up SSH keys

Place your private SSH key in the `ssh-keys/` directory:

```bash
mkdir -p ssh-keys
chmod 700 ssh-keys
cp ~/.ssh/your_key ssh-keys/
chmod 600 ssh-keys/your_key
```

> **Non-standard key filenames** (anything other than `id_rsa`, `id_ed25519`,
> `id_ecdsa`, etc.) are not auto-discovered by SSH. Specify them explicitly with
> `-i /home/sshrelay/.ssh/your_key` in the `extra_options` column of `tunnels.conf`.

### 2. Configure tunnels

Edit `tunnels.conf` with your tunnel definitions:

```text
# local_port   ssh_user     remote_host           remote_port   extra_options
10001          opex         10.10.1.101            5900          -i /home/sshrelay/.ssh/vnc_key
10002          opex         10.10.1.102            5900          -i /home/sshrelay/.ssh/vnc_key
```

**Fields:**

| Column | Description |
| --- | --- |
| `local_port` | Port the container listens on — this is what Guacamole connects to |
| `ssh_user` | OS/SSH account on the remote host — **not** the VNC login |
| `remote_host` | Hostname or IP of the remote machine |
| `remote_port` | Port on the remote host (5900 = VNC display :0, 5901 = :1) |
| `extra_options` | Optional SSH flags (key, port, proxy jump, etc.) |

### 3. Start ssh-relay and verify

```bash
docker compose up -d --build ssh-relay

# Confirm one socat listener per tunnels.conf entry
docker compose exec ssh-relay ss -tlnp

# Check startup logs
docker compose logs ssh-relay
```

> ssh-relay publishes no host ports by design — tunnel ports are only reachable from
> other services on the same Docker network (i.e., `guacd`). End-to-end VNC testing
> requires the full Guacamole stack — see [Local Testing with Guacamole](#local-testing-with-guacamole-full-stack) below.

---

## How It Works

### Architecture

```text
Browser → Guacamole (Java) → guacd → ssh-relay:<local_port> → SSH tunnel → VNC server
```

When a user opens a VNC connection in Guacamole, `guacd` connects to
`ssh-relay:<local_port>` as if it were a plain VNC server. ssh-relay's socat
listener accepts that connection, spawns an SSH process using `-W` (stdio forwarding),
and proxies all bytes bidirectionally through the SSH tunnel to the real VNC server.
From guacd's perspective it's talking directly to VNC — the SSH layer is invisible.

### entrypoint.sh — step by step

#### 1. Key permission correction

```sh
chmod 700 /home/sshrelay/.ssh
find /home/sshrelay/.ssh ... -exec chmod 600 {} \;
```

SSH refuses to use key files that are world- or group-readable. Because `ssh-keys/`
is bind-mounted from the host, the files may arrive with incorrect permissions (e.g.,
if the host user's UID differs from `sshrelay:1000`). The entrypoint corrects this
on every startup.

#### 2. Temporary directory creation

```sh
mkdir -p /tmp/ssh-ctrl /tmp/ssh-tunnel
```

- `/tmp/ssh-ctrl/` — holds SSH ControlMaster Unix sockets (one per unique
  `ssh_user@remote_host`)
- `/tmp/ssh-tunnel/` — holds per-tunnel wrapper shell scripts

#### 3. Per-tunnel wrapper script generation

For each line in `tunnels.conf`, the entrypoint writes a small shell script like:

```sh
# /tmp/ssh-tunnel/tunnel-10001.sh
exec ssh -W 10.10.1.101:5900 opex@10.10.1.101 \
     -N -T \
     -o ControlMaster=auto \
     -o ControlPath=/tmp/ssh-ctrl/opex_10.10.1.101 \
     -o ControlPersist=60 \
     ...
```

This indirection exists because socat's `EXEC:` address type splits its argument
on `:` — passing `ssh -W host:port` inline would be misinterpreted as two
parameters. A wrapper script path contains no colons and is parsed correctly.

#### 4. SSH ControlMaster multiplexing

The wrapper scripts use `ControlMaster=auto` + `ControlPersist=60`:

- **First VNC connection** to a remote host: SSH authenticates fully (key exchange,
  public key auth — typically 1–3 seconds), then creates a Unix domain socket at
  `/tmp/ssh-ctrl/user_host`. This process stays alive for 60 seconds after the
  last channel closes.
- **All subsequent VNC connections** to the same host: SSH opens a new channel
  over the existing authenticated session via the socket — takes under 100ms. No
  re-authentication, no key exchange overhead.
- **Unreachable hosts**: no pre-connection at startup; a failed first attempt is
  logged to stdout and the listener stays up for retry.

This is what makes 500+ tunnels practical — there is zero startup overhead
regardless of how many tunnel entries exist.

#### 5. socat listener launch

```sh
socat TCP-LISTEN:10001,reuseaddr,fork,bind=0.0.0.0 \
      EXEC:"/tmp/ssh-tunnel/tunnel-10001.sh"
```

- `TCP-LISTEN` — listens on the specified port
- `reuseaddr` — allows immediate restart without `Address already in use` errors
- `fork` — spawns a child process per connection so the listener stays up for
  concurrent sessions
- `bind=0.0.0.0` — accepts connections from any interface on the Docker network
- `EXEC:` — when a client connects, executes the wrapper script; socat wires its
  stdin/stdout to the TCP socket, making SSH `-W` act as a transparent byte pipe

All output from socat and the SSH process is prefixed with `[ssh-relay-<port>]`
and written to stdout where `docker compose logs` captures it.

---

## Configuration

### Tunnel Configuration (`tunnels.conf`)

Each non-comment, non-blank line defines one tunnel. Fields are space-separated.

```text
# local_port   ssh_user     remote_host           remote_port   extra_options
10001          opex         10.10.1.101            5900          -i /home/sshrelay/.ssh/vnc_key
```

`entrypoint.sh` already sets `StrictHostKeyChecking=no`, `BatchMode=yes`, `ConnectTimeout=10`,
`ServerAliveInterval=15`, `ServerAliveCountMax=3`, `ExitOnForwardFailure=yes`, and
`ControlMaster`/`ControlPersist`. Do not repeat these in `extra_options`.

**Useful `extra_options`:**

| Option | Purpose |
| --- | --- |
| `-i /home/sshrelay/.ssh/keyname` | Explicit key file (required for non-standard filenames) |
| `-o IdentitiesOnly=yes` | Use only the key specified with `-i`; skip all others |
| `-p 2222` | Non-standard SSH port on the remote host |
| `-o ProxyJump=bastion.internal` | Route through a bastion/jump host |
| `-o Compression=yes` | Compress traffic (useful on slow or WAN links) |
| `-o LogLevel=DEBUG` | Verbose SSH logging for troubleshooting a specific tunnel |

### Docker Compose (`docker-compose.yml`)

`docker-compose.yml` is intentionally single-service — it builds and runs ssh-relay
in isolation for standalone image development and verification. It mounts two
read-only volumes:

- `./ssh-keys` → `/home/sshrelay/.ssh`
- `./tunnels.conf` → `/etc/tunnels.conf`

No host ports are published. For full functional testing with guacamole and guacd,
use `gscl-tgt-guacamole/server_setup/local/compose.yaml`.

---

## Local Testing with Guacamole (full stack)

Full-stack local testing (postgres + guacd + guacamole + ssh-relay) is managed from
the `gscl-tgt-guacamole` repository, which is the single source of truth for how all
services are composed. The ssh-relay `docker-compose.yml` is intentionally
single-service only.

```text
gscl-tgt-guacamole/
  server_setup/
    local/      ← full-stack local testing
    nonprod/    ← nonprod server deployment
    prod/       ← production server deployment
```

### Before you begin

- `gscl-tgt-guacamole` cloned locally
- SSH tunnel key in `gscl-tgt-guacamole/server_setup/local/ssh-keys/`
  (`ssh-keys/` is gitignored)
- `tunnels.conf` created from the example:

  ```bash
  cd gscl-tgt-guacamole/server_setup/local
  cp tunnels.conf.example tunnels.conf
  # edit tunnels.conf with your targets
  ```

### 1. Start the full stack

```bash
cd gscl-tgt-guacamole/server_setup/local
docker compose pull
docker compose up -d
```

This pulls all four services from the registry and starts them. To use a locally
built ssh-relay image instead of pulling, build it first:

```bash
# In the gscl-ssh-relay repo:
docker compose build
# Then back in gscl-tgt-guacamole/server_setup/local — the local image takes precedence
# if you edit ssh-relay's image tag in compose.yaml to match your local build tag.
```

### 2. Verify ssh-relay

```bash
# Confirm one socat listener per tunnels.conf entry
docker compose exec ssh-relay ss -tlnp

# Check startup logs (look for "Listening on port ..." per entry)
docker compose logs ssh-relay

# Confirm guacd can reach ssh-relay (replace 10001 with your local_port)
docker compose exec guacd nc -z ssh-relay 10001 && echo OK
```

### 3. Open Guacamole

```bash
open http://localhost:8080/guacamole
```

Log in with `username` / `changeme` (configured in `server_setup/local/.env`).

### 4. Configure and test connections

Go to **top-right menu → Settings → Connections → New Connection**.

#### Connection type A — Direct VNC (baseline, no relay)

Tests that Guacamole and guacd can reach the VNC server directly. Use this first
to confirm VNC credentials are correct before testing through ssh-relay.

| Field | Value |
| --- | --- |
| Protocol | VNC |
| Name | `myhost-direct` |
| Hostname | `10.10.1.101` (direct IP, must be routable from guacd) |
| Port | `5900` |
| Password | VNC server password |

> ⚠️ This only works if the VNC server is directly routable from inside the
> Docker network. If not, skip to Connection type B.

#### Connection type B — VNC via ssh-relay (standard tunnel)

The primary use case. guacd connects to ssh-relay, which SSH-tunnels to the
remote VNC server.

| Field | Value |
| --- | --- |
| Protocol | VNC |
| Name | `myhost-relay` |
| Hostname | `ssh-relay` |
| Port | `10001` (matching `local_port` in `tunnels.conf`) |
| Password | VNC server password |

> **Important:** The password is the VNC server's password — not the SSH key
> passphrase. Guacamole does not prompt for passwords at runtime; set it here
> in the connection definition.

#### Connection type C — VNC via ssh-relay, non-standard SSH port

For remote hosts where SSH listens on a non-standard port (e.g., 2222). Add
`-p 2222` to the `extra_options` column in `tunnels.conf` for that entry:

```text
10002  opex  10.10.1.102  5900  -i /home/sshrelay/.ssh/vnc_key -p 2222 -o StrictHostKeyChecking=no
```

Guacamole connection: hostname `ssh-relay`, port `10002`.

#### Connection type D — VNC via ssh-relay with bastion/jump host

For remote hosts only reachable via a bastion host:

```text
10003  opex  10.10.1.103  5900  -i /home/sshrelay/.ssh/vnc_key -o ProxyJump=bastion.internal -o StrictHostKeyChecking=no
```

Guacamole connection: hostname `ssh-relay`, port `10003`.

#### Connection type E — non-VNC port (SSH console)

ssh-relay can tunnel any TCP port, not just VNC. To expose SSH on the remote
host as an RDP/SSH connection in Guacamole:

```text
10004  opex  10.10.1.101  22  -i /home/sshrelay/.ssh/vnc_key -o StrictHostKeyChecking=no
```

Guacamole connection: protocol SSH, hostname `ssh-relay`, port `10004`.

### 5. Validate a working tunnel end-to-end

After connecting from Guacamole, verify in logs:

```bash
# ssh-relay should show socat/SSH activity for the port
docker compose logs ssh-relay

# guacd should show the VNC session joined
docker compose logs guacd | grep -E "joined|connect|ERROR"
```

Expected guacd output for a successful connection:

```text
guacd[N]: INFO:  User "@..." joined connection "$..." (1 users now present)
guacd[N]: INFO:  User "@..." disconnected (0 users remain)
```

### 6. Tear down

```bash
docker compose down
```

---

## Security Considerations

### ✅ Current security measures

- Non-root user (`sshrelay:1000`)
- Read-only mounted volumes for keys and config
- SSH keepalive and timeout settings
- SSH batch mode (no interactive prompts)
- Wrapper scripts use `ControlPersist=60` — multiplexed sessions time out after
  60 seconds of inactivity

### ⚠️ Recommendations

1. **Host key verification**: `StrictHostKeyChecking=no` is the default for convenience.
   For hardened deployments, pre-populate known hosts in the Dockerfile:

   ```dockerfile
   RUN ssh-keyscan -t ed25519 10.10.1.101 >> /home/sshrelay/.ssh/known_hosts
   ```

   Then remove `-o StrictHostKeyChecking=no` and `-o UserKnownHostsFile=/dev/null` from `entrypoint.sh`.

2. **Restrict key scope**: Use a dedicated SSH key with minimal permissions on remote
   hosts — only SSH access needed, no shell if possible (`command=""` in
   `authorized_keys`).

3. **Network isolation**: ssh-relay should only be accessible from `guacd` — keep it
   on a private Docker bridge and never publish tunnel ports to the host.

4. **Key rotation**: Regularly rotate SSH keys and update `ssh-keys/` accordingly.

---

## Troubleshooting

### View live logs

```bash
docker compose logs -f ssh-relay
docker compose logs -f guacd
```

### Test the SSH tunnel manually

Run the exact SSH command ssh-relay uses (replace values with your config):

```bash
docker compose exec ssh-relay ssh \
  -W 10.10.1.101:5900 opex@10.10.1.101 \
  -i /home/sshrelay/.ssh/vnc_key \
  -o StrictHostKeyChecking=no -v
```

A working tunnel prints `RFB 003.xxx` (the VNC server greeting) before hanging.

### Test network connectivity from guacd to ssh-relay

```bash
docker compose exec guacd nc -z ssh-relay 10001 && echo REACHABLE
```

### Verify socat listeners are active

```bash
docker compose exec ssh-relay ss -tlnp
```

Expect one `LISTEN` entry per `tunnels.conf` line.

### DNS resolution failures

```text
ssh: Could not resolve hostname myhost.internal: Name does not resolve
```

The container cannot resolve the hostname. Use a direct IP address in `tunnels.conf`
instead, or configure Docker DNS to resolve internal names.

### `Unable to connect to VNC server` in guacd

Most common causes (in order):

1. **Wrong VNC password** in Guacamole connection settings
2. **TightVNC IP access control** — add the Docker subnet to TightVNC's allowed
   IP list on the remote machine
3. **TightVNC "query on connect"** — the remote user must accept the connection;
   disable this in TightVNC Server Options
4. **VNC server not running** on the remote machine

### SSH key not found / permission denied

- Key filename must match what is specified with `-i` in `tunnels.conf`
- Non-standard filenames (not `id_rsa`, `id_ed25519`, etc.) require explicit `-i`
- Key permissions must be `600` — entrypoint corrects this, but only for files
  owned by `sshrelay`. If the mounted key is owned by a different UID, run:
  `sudo chown 1000 ssh-keys/your_key` on the host.

### Port already in use

Change `local_port` in `tunnels.conf` and restart:

```bash
docker compose down && docker compose up -d
```

---

## Performance & Limits

- **Startup time**: O(1) regardless of tunnel count — wrapper scripts are generated
  in milliseconds; no pre-connection to remote hosts
- **First VNC session to a host**: ~1–3s SSH authentication + ControlMaster creation
- **Subsequent VNC sessions to same host**: <100ms channel reuse via ControlMaster
- **Memory per listener**: one idle socat process (~1 MB) + one wrapper script file
- **Memory per active host**: one persistent SSH ControlMaster process after first use
- **ulimits**: set `nofile: 8192` in Compose for 500+ listeners (OS default is often
  1024 which socat can exhaust)

---

## Advanced Usage

### Multiple SSH keys

Place multiple keys in `ssh-keys/` and specify each explicitly with `-i` per tunnel:

```text
10001  opex   10.10.1.101  5900  -i /home/sshrelay/.ssh/key_datacenter_a
10050  admin  10.10.2.101  5900  -i /home/sshrelay/.ssh/key_datacenter_b
```

### SSH config file

Mount an SSH config file to simplify `tunnels.conf`:

```yaml
volumes:
  - ./ssh_config:/home/sshrelay/.ssh/config:ro
```

With a config defining `Host` blocks, `tunnels.conf` can omit per-entry key and
port options.

### Dynamic port mapping (development)

Expose tunnel ports to the host for testing with a native VNC client:

```yaml
ports:
  - "10000-10010:10000-10010"
```

Then connect from the host: `open vnc://localhost:10001`

---

## Contributing

Open a pull request against `main`. The Vela pipeline will run a dry-run Docker build
on your PR automatically. Ensure `tunnels.conf` entries and any Dockerfile changes
build cleanly before requesting review.

---

## License

Derived from [mpritter76/ssh-relay](https://github.com/mpritter76/ssh-relay).
See upstream repository for original license terms.
