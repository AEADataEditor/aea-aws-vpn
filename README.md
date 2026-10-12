# AWS Client VPN in a container

Runs the AWS VPN Client (command-line) in an Ubuntu 26.04 container with systemd, enrolled in
JumpCloud, and exposes the VPN to the host through a SOCKS5 proxy on `127.0.0.1:1080`.

Requirements: Docker, an AMD64 host, the Client VPN profile (`*.ovpn`) in this directory, and a
JumpCloud connect key.

Your repo directory is mounted in the container at `/vpn`, so the profile is visible there.

## Start from scratch

```bash
# 1. Build the image
./run.sh build

# 2. Create the container and enroll it in JumpCloud (needs the connect key; first time only)
JC_CONNECT_KEY=<connect key> ./run.sh up

# 3. Import the VPN profile (first time only; it is kept inside the container)
./run.sh vpn import-profile --profile-name work --config-path /vpn/cvpn-endpoint-0ce84d6810ccb6be0.ovpn

# 4. Connect. This prints a URL: open it in your host browser and sign in (SAML).
./run.sh login work

# 5. Check
./run.sh vpn get-connection-status --profile-name work
```

Never put the connect key in a file in this repo. `run.sh` sends it straight into the container's
memory-only `/run`, and the enrollment unit deletes it afterwards.

## Pick up again (next day)

```bash
./run.sh up            # restarts the existing container; already enrolled, no key needed
./run.sh login work    # the VPN connection does not survive a stop, so sign in again
```

When you are done:

```bash
./run.sh stop          # keeps the container, its JumpCloud enrollment and the imported profile
```

**Do not run `./run.sh down`** unless you want to start over: it deletes the container and its
enrollment, and the next `up` creates a new JumpCloud device.

## Using the VPN from the host

Traffic goes through the SOCKS5 proxy at `127.0.0.1:1080` (loopback only). Use `socks5h` so
hostnames are resolved inside the container.

```bash
# SSH
ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1080 %h %p' user@host.internal

# curl
curl --proxy socks5h://127.0.0.1:1080 http://internal-host/
```

For everyday use put this in `~/.ssh/config` (adjust the patterns to your VPN's hosts or subnets):

```
Host bi1.orldata.org 172.21.*
    ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
```

`nc` must be the OpenBSD netcat (`netcat-openbsd`). Alternative: `ncat --proxy 127.0.0.1:1080 --proxy-type socks5 %h %p`.

## Commands

| Command | What it does |
|---|---|
| `./run.sh build` | Build the image |
| `./run.sh up` | Create + start the container, or restart the existing one. `JC_CONNECT_KEY` is only used on creation |
| `./run.sh login <profile>` | Connect (SAML); prints the sign-in URL to open in your browser |
| `./run.sh vpn <args>` | Run the `aws-vpn-client` CLI (`connect`, `disconnect`, `list-profiles`, `get-connection-status`, ...) |
| `./run.sh url` | Show the last captured sign-in URL |
| `./run.sh shell` | Shell inside the container |
| `./run.sh stop` | Stop, keeping the container |
| `./run.sh commit` | Save the container as image `aws-vpn:enrolled` (optional backup) |
| `./run.sh down` | Delete the container |

Environment: `SOCKS_PORT` (host port for the proxy, default 1080), `IMAGE`, `NAME`.

## How it works

- **systemd is PID 1**, because the JumpCloud agent refuses to install without it. The container
  therefore runs `--privileged` (not on the host network).
- **JumpCloud** is enrolled at runtime by `jumpcloud-enroll.service`, not at build time; otherwise
  every container from the image would share one device identity.
- **SOCKS proxy**: `socks.service` runs `microsocks` on port 1080.
- **SAML sign-in**: there is no browser in the container, so the `xdg-open` shim saves the URL.
  After sign-in your browser is redirected to `http://127.0.0.1:35001/` (or a port in 8096-8115);
  those ports are published on the host's loopback and forwarded to the client by
  `saml-forward.service`.
- **DNS**: the client sets VPN DNS through `resolvectl`; `resolvectl` here is a small stand-in that
  rewrites `/etc/resolv.conf`.

## License

MIT, see [LICENSE](LICENSE). The AWS VPN Client and the JumpCloud agent are downloaded at
runtime or build time and are under their own vendors' terms; they are not part of this repository.

## Troubleshooting

- **`Already connected to profile`**: you are connected; nothing to do.
- **`General SOCKS server failure`**: usually DNS or the VPN is down. Check with
  `./run.sh vpn get-connection-status --profile-name work` and
  `./run.sh shell`, then `getent hosts <name>` and `ip route`.
- **`Permission denied (publickey)`**: the network works; the username or key is wrong for that server.
- **`port is already allocated` on `up`**: something on the host uses 1080, 35001 or 8096-8115.
  Set `SOCKS_PORT` for the proxy; the SAML ports are fixed.
- **Services not running**: `./run.sh shell`, then
  `systemctl status jcagent aws-client-vpn-daemon socks saml-forward`.
- **A new JumpCloud device appears after every `down` + `up`**: delete stale ones in the JumpCloud console.
