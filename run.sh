#!/usr/bin/env bash
# Build and run the AWS Client VPN container (systemd as PID 1, JumpCloud enrolled at runtime).
#
# Usage:
#   ./run.sh build
#   JC_CONNECT_KEY=<key> ./run.sh up    # start container; enroll in JumpCloud on first start
#   ./run.sh shell                      # bash inside the container
#   curl --proxy socks5h://127.0.0.1:1080 http://internal-host/   # use the VPN from the host
#   ./run.sh login <profile>            # connect to a SAML endpoint (prints the URL to open in your browser)
#   ./run.sh vpn <args>                 # AWS VPN Client CLI, e.g. vpn import-profile / connect / list-profiles
#   ./run.sh stop                       # stop, keeping the enrolled container; `up` restarts it
#   ./run.sh commit                     # also save it as image aws-vpn:enrolled
#   ./run.sh down                       # DELETE the container (the JumpCloud device stays in the console)
set -euo pipefail

IMAGE="${IMAGE:-aws-vpn}"
NAME="${NAME:-aws-vpn}"
cd "$(dirname "$0")"

build() {
  docker build -t "$IMAGE" .
}

up() {
  # systemd in a container needs a privileged container (or equivalent cgroup access).
  # Deliberately NOT --network host: a privileged container on the host network could
  # touch host interfaces, and the agent would register under the host's hostname.
  docker run -d --name "$NAME" --hostname "$NAME" \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --device /dev/net/tun \
    -p "127.0.0.1:${SOCKS_PORT:-1080}:1080" \
    -p 127.0.0.1:8096-8115:8096-8115 \
    -p 127.0.0.1:35001:35001 \
    -v "$PWD:/vpn" \
    "$IMAGE"

  until docker exec "$NAME" systemctl is-system-running --wait >/dev/null 2>&1 \
     || [ "$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)" = degraded ]; do
    sleep 1
  done

  if [ -n "${JC_CONNECT_KEY:-}" ]; then
    # Key goes straight into the container's tmpfs; the unit deletes it after enrolling.
    docker exec -i "$NAME" sh -c 'umask 077; mkdir -p /run/secrets; cat > /run/secrets/jc_key' \
      <<<"$JC_CONNECT_KEY"
    docker exec "$NAME" systemctl start jumpcloud-enroll.service
    docker exec "$NAME" systemctl --no-pager status jcagent.service || true
  else
    echo "JC_CONNECT_KEY not set: skipping JumpCloud enrollment" >&2
  fi
}

start() {
  # Restart the existing (already enrolled) container; no re-enrollment.
  docker start "$NAME"
}

commit() {
  # Snapshot the enrolled container as an image. Anything started from it shares
  # this ONE JumpCloud device identity, so run at most one such container at a time.
  docker commit "$NAME" "${IMAGE}:enrolled"
  echo "Saved ${IMAGE}:enrolled (run with: IMAGE=${IMAGE}:enrolled JC_CONNECT_KEY= ./run.sh up)"
}

case "${1:-}" in
  build) build ;;
  up)    if docker container inspect "$NAME" >/dev/null 2>&1; then start; else up; fi ;;
  shell) docker exec -it "$NAME" bash ;;
  vpn)   shift; docker exec -it "$NAME" aws-vpn-client "$@" ;;
  url)   docker exec "$NAME" cat /run/saml-url ;;
  login) # SAML sign-in: run connect, print the login URL to open in the host browser
         profile="${2:?usage: $0 login <profile-name>}"
         docker exec "$NAME" rm -f /run/saml-url
         ( for _ in $(seq 120); do
             if u=$(docker exec "$NAME" cat /run/saml-url 2>/dev/null) && [ -n "$u" ]; then
               echo; echo "Open this URL in your browser to sign in:"; echo "$u"; echo; break
             fi; sleep 1
           done ) &
         docker exec -it "$NAME" aws-vpn-client connect --profile-name "$profile"; wait ;;
  stop)  docker stop "$NAME" ;;
  commit) commit ;;
  down)  docker rm -f "$NAME" ;;
  *)     echo "usage: $0 {build|up|shell|vpn|login|url|stop|commit|down}" >&2; exit 1 ;;
esac
