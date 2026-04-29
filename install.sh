#!/bin/bash

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🎵 installing leproxy - duckdns reverse proxy hosting ${NC}\n"

# Source existing .env if it exists
# This script can be used to edit values in here
#  they autofill and are line-editable
[[ -f .env ]] && source .env

# for DuckDNS domain management
echo -e "\n${GREEN}Setup DuckDNS configuration - see https://www.duckdns.org/domains${NC}"
echo "  for ipv6, append or only enter: &ipv6=1234::5678"
echo ""
read -p "public host ip (blank for auto): " -i "${PUBLIC_IP:-}" -e PUBLIC_IP
# without .duckdns.org
read -p "subdomains (eg a,b,c): " -i "${DUCKDNS_NAMES:-}" -e DUCKDNS_NAMES
# port only if your service is on docker0
#  which we assume is 172.17.0.1 (run ip addr | grep docker0)
# each may have an ip as well, eg 1.2.3.4:1234
read -p "their docker0 ports (eg 9090,9091,9090): " -i "${NAMES_PORTS:-}" -e NAMES_PORTS
read -p "DuckDNS token: " -i "${DUCKDNS_TOKEN:-}" -e DUCKDNS_TOKEN
echo ""

# ── Tunnel mode ───────────────────────────────────────────────────────────────
# Tunnel mode: Caddy runs here; a remote jump server (jamsend-fe) runs
#   ssh-tunnel-destiny so it holds the public IP. ssh-tunnel-source here
#   reverse-forwards jump:80/443 back to Caddy over SSH.
#
# In tunnel mode PUBLIC_IP is the jump server's IP (what DuckDNS points to),
#   not this machine's IP.
#
# Direct mode: Caddy binds 80/443 directly (UPnP or port forward).
#   coturn and upnp-forwarder run on the app server alongside the app.
echo -e "${GREEN}Tunnel mode${NC}"
echo "  Use tunnel if this machine is behind NAT without reliable UPnP."
echo "  PUBLIC_IP above should be the jump server's IP, not yours."
echo ""

_TUNNEL_DEFAULT=""
[[ "${TUNNEL_MODE:-false}" == "true" ]] && _TUNNEL_DEFAULT="y"
read -p "Use SSH tunnel mode? (y/N): " -i "$_TUNNEL_DEFAULT" -n 1 -e REPLY
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    TUNNEL_MODE=true
    echo -e "${GREEN}Tunnel mode enabled.${NC}"
    [[ -z "${PUBLIC_IP:-}" ]] && echo -e "${YELLOW}Warning: PUBLIC_IP blank — DuckDNS will point here, not the jump server.${NC}"
else
    TUNNEL_MODE=false
    echo -e "${GREEN}Direct mode. Caddy will bind 80/443 here.${NC}"
fi

# ── SSH key generation ────────────────────────────────────────────────────────
if [[ -n "${SSH_PRIVATE_KEY:-}" && -n "${SSH_PUBLIC_KEY:-}" ]]; then
    read -p "Generate new SSH keys? (y/N): " -n 1 -e REPLY
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        GENERATE_KEYS=true
    else
        GENERATE_KEYS=false
        echo -e "${GREEN}Using existing SSH keys.${NC}"
    fi
else
    echo -e "${YELLOW}No existing SSH keys found. Generating new ones...${NC}"
    GENERATE_KEYS=true
fi

if [[ "${GENERATE_KEYS}" == true ]]; then
    ssh-keygen -t ed25519 -f tunnel_key -N ""
    SSH_PRIVATE_KEY=$(cat tunnel_key)
    SSH_PUBLIC_KEY=$(cat tunnel_key.pub)
    rm tunnel_key tunnel_key.pub
    echo -e "${GREEN}New SSH keys generated.${NC}"
fi

read -p "Sure? Ctrl-C to abort writing .env: "

cat > .env << EOF
PUBLIC_IP="${PUBLIC_IP}"
DUCKDNS_NAMES=${DUCKDNS_NAMES}
NAMES_PORTS=${NAMES_PORTS}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
TUNNEL_MODE=${TUNNEL_MODE}
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
EOF

# ── Build docker-compose.yml ──────────────────────────────────────────────────
# TUNNEL_MODE exported so build-docker-compose.pl can read $ENV{TUNNEL_MODE}
#   to include/exclude ssh-tunnel-source and its ssh_config Docker config entry
export TUNNEL_MODE
bash build-docker-compose.sh

# ── Generate there/ ───────────────────────────────────────────────────────────
# there/ is always generated. It is the staging directory that prod-jamsend/prod.sh
#   reads from. leproxy owns the SSH infrastructure here; jamsend owns coturn.
#
# Tunnel mode:  ssh-tunnel-destiny + ssh_config + SSH keys
# Direct mode:  minimal (no jump server needed; .env kept for symmetry)
#
# Note: TLS certs for coturn are NOT exported here — Caddy hasn't necessarily
#   issued them yet. prod.sh extracts them from the running Caddy container
#   after deployment. Re-run prod.sh after first deploy to populate certs.
mkdir -p there

cat > there/.env << EOF
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
EOF

# env_to_authorized_keys.sh writes SSH_PUBLIC_KEY → /root/.ssh/authorized_keys
#   inside the ssh-tunnel-destiny container at startup
[[ -f env_to_authorized_keys.sh ]] && cp env_to_authorized_keys.sh there/

if [[ "${TUNNEL_MODE}" == "true" ]]; then

    # ssh_config maps alias 'jamsend-fe' → PUBLIC_IP for ssh-tunnel-source.
    # Mounted into the ssh-tunnel-source container via Docker configs.
    cat > there/ssh_config << EOF
Host jamsend-fe
    HostName ${PUBLIC_IP}
    Port 2029
    User root
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ExitOnForwardFailure yes
EOF

    # Jump server compose: just ssh-tunnel-destiny.
    # prod-jamsend/prod.sh appends coturn and adds TLS certs before rsyncing.
    cat > there/docker-compose.yml << 'DCEOF'
services:
  # Accepts the reverse SSH tunnel from leproxy's ssh-tunnel-source.
  # Exposes 80/443 publicly; Caddy on the leproxy machine handles TLS.
  # Port 2029 is the SSH listen port that ssh-tunnel-source connects to.
  ssh-tunnel-destiny:
    build:
      context: .
      dockerfile_inline: |
        FROM alpine:3.19
        RUN apk add --no-cache \
            openssh-server \
            curl \
            bind-tools \
            iputils \
            iproute2 && \
            mkdir /run/sshd && \
            mkdir -p /root/.ssh
        RUN ssh-keygen -A
        COPY env_to_authorized_keys.sh /root/
        RUN chmod +x /root/env_to_authorized_keys.sh
        RUN sed -i '/^AllowTcpForwarding no/d; /^GatewayPorts no/d' /etc/ssh/sshd_config && \
            echo "AllowTcpForwarding yes"    >> /etc/ssh/sshd_config && \
            echo "GatewayPorts yes"          >> /etc/ssh/sshd_config && \
            echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
        CMD ["/bin/sh", "-c", "/root/env_to_authorized_keys.sh && /usr/sbin/sshd -D -p 2029"]
    environment:
      - SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
    ports:
      - "2029:2029"
      - "80:80"
      - "443:443"
      - "9999:9999"
    restart: always
DCEOF

    echo ""
    echo -e "${GREEN}there/ generated (ssh-tunnel-destiny).${NC}"
    echo "prod-jamsend/prod.sh will append coturn, extract TLS certs, and rsync to the jump server."
    echo ""
    echo "Start leproxy here first:"
    echo "  docker compose up -d"
    echo "Then run prod-jamsend/prod.sh to complete the jump server setup."
    echo ""
    echo "Firewall rules needed on the jump server (if not already open):"
    echo "  sudo ufw allow 2029/tcp"
    echo "  sudo ufw allow 80,443/tcp"
    echo "  sudo ufw allow 3478/tcp && sudo ufw allow 3478/udp    # TURN"
    echo "  sudo ufw allow 5349/tcp                               # TURNS"
    echo "  sudo ufw allow 49152:65535/udp                        # TURN relay range"

else

    echo ""
    echo -e "${GREEN}Direct mode: no jump server. there/ is minimal.${NC}"
    echo "Start leproxy:"
    echo "  docker compose up -d"

fi
