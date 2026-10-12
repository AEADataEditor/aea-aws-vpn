FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

# systemd is PID 1 because the JumpCloud agent refuses to install without it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo curl wget ca-certificates gnupg \
      iproute2 iputils-ping dnsutils microsocks iptables \
 && rm -rf /var/lib/apt/lists/* \
 # Units that make no sense (or do harm) in a container
 && systemctl mask \
      systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
      systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-udev-trigger.service systemd-remount-fs.service sys-kernel-config.mount \
      sys-kernel-debug.mount sys-kernel-tracing.mount getty.target console-getty.service

# AWS VPN Client for Linux (AMD64 only; Ubuntu 22.04/24.04/26.04 supported)
# https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-install.html
RUN wget -qO- https://d20adtppz83p9s.cloudfront.net/GTK/latest/debian-repo/awsvpnclient_public_key.asc \
      > /etc/apt/trusted.gpg.d/awsvpnclient_public_key.asc \
 && echo "deb [arch=amd64] https://d20adtppz83p9s.cloudfront.net/GTK/latest/debian-repo ubuntu main" \
      > /etc/apt/sources.list.d/aws-vpn-client.list \
 && apt-get update \
 # The package's postinst runs `systemctl daemon-reload/enable/start`, which fail
 # without a running systemd. Shim systemctl for the install: `enable` works offline
 # (just creates symlinks), everything else is skipped. The daemon starts at boot.
 && mv /usr/bin/systemctl /usr/bin/systemctl.real \
 && printf '#!/bin/sh\n[ "$1" = enable ] && exec /usr/bin/systemctl.real "$@"\nexit 0\n' > /usr/bin/systemctl \
 && chmod +x /usr/bin/systemctl \
 && apt-get install -y awsvpnclient \
 && mv -f /usr/bin/systemctl.real /usr/bin/systemctl \
 && rm -rf /var/lib/apt/lists/*

# JumpCloud enrolls the machine on install, so it must NOT happen at build time
# (every container would share one device identity). Instead, a oneshot unit
# runs the Kickstart at runtime, reading the connect key from /run/secrets/jc_key
# (delivered by run.sh into the container's tmpfs, never into an image layer).
COPY jumpcloud-enroll.service /etc/systemd/system/jumpcloud-enroll.service

# SOCKS5 proxy on :1080 so the host can use the VPN (run.sh publishes it on 127.0.0.1 only)
COPY socks.service /etc/systemd/system/socks.service
RUN systemctl enable socks.service

# SAML sign-in: capture the login URL (no browser here) and let the host's browser
# reach the client's local callback listener on 8096-8115 (run.sh publishes these).
COPY xdg-open /usr/local/bin/xdg-open
COPY saml-forward.service /etc/systemd/system/saml-forward.service
RUN chmod +x /usr/local/bin/xdg-open && systemctl enable saml-forward.service

# The client sets VPN DNS via `resolvectl` (systemd-resolved), which a container lacks;
# this stand-in writes the pushed DNS servers into /etc/resolv.conf instead.
COPY resolvectl /usr/bin/resolvectl

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
