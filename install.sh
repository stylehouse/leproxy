#!/bin/bash

set -euo pipefail
# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🎵 installing leproxy - duckdns reverse proxy hosting ${NC}\n"

# Source existing .env if it exists
[[ -f .env ]] && source .env

# for DuckDNS domain management
echo -e "\n${GREEN}Setup DuckDNS configuration - see https://www.duckdns.org/domains${NC}"
echo "  for ipv6, append or only enter: &ipv6=1234::5678"
read -p "public host ip (eg 8.8.4.4): " -i "${PUBLIC_IP:-}" -e PUBLIC_IP
read -p "subdomains (eg a,b,c): " -i "${DUCKDNS_NAMES:-}" -e DUCKDNS_NAMES
# port only if your service is on docker0
#  which we assume is 172.17.0.1 (run ip addr | grep docker0)
# each may have an ip as well, eg 1.2.3.4:1234
read -p "their docker0 ports (9090,9091,): " -i "${NAMES_PORTS:-}" -e NAMES_PORTS
read -p "token: " -i "${DUCKDNS_TOKEN:-}" -e DUCKDNS_TOKEN



# Generate SSH keys for tunnel
ssh-keygen -t ed25519 -f tunnel_key -N ""
PRIVATE_KEY=$(cat tunnel_key)
PUBLIC_KEY=$(cat tunnel_key.pub)
rm tunnel_key tunnel_key.pub

read -p "are you sure? "

cat > .env << EOF
PUBLIC_IP="${PUBLIC_IP}"
DUCKDNS_NAMES=${DUCKDNS_NAMES}
NAMES_PORTS=${NAMES_PORTS}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
SSH_PRIVATE_KEY="${PRIVATE_KEY}"
SSH_PUBLIC_KEY="${PUBLIC_KEY}"
EOF
cat > there/.env << EOF
SSH_PUBLIC_KEY="${PUBLIC_KEY}"
EOF

bash build-docker-compose.sh

echo "Now: scp -r there/{.,}* d:leproxy"
echo " if your docker hoster's hostname is 'd'."
echo "And: sudo ufw allow 2029/tcp"
echo "And compose up there."
