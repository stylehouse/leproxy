#!/bin/bash

set -euo pipefail
# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🎵 installing leproxy - duckdns reverse proxy hosting ${NC}\n"

# Source existing .env if it exists
# This script can be used to edit values in here 
#  they autofill and are line-editable
[[ -f .env ]] && source .env

# for DuckDNS domain management
echo -e "\n${GREEN}Setup DuckDNS configuration - see https://www.duckdns.org/domains${NC}"
echo ""
echo "  for ipv6, append or only enter: &ipv6=1234::5678"
read -p "public host ip (eg 8.8.4.4): " -i "${PUBLIC_IP:-}" -e PUBLIC_IP
# without .duckdns.org
read -p "subdomains (eg a,b,c): " -i "${DUCKDNS_NAMES:-}" -e DUCKDNS_NAMES
# port only if your service is on docker0
#  which we assume is 172.17.0.1 (run ip addr | grep docker0)
# each may have an ip as well, eg 1.2.3.4:1234
read -p "their docker0 ports (eg 9090,9091,9090): " -i "${NAMES_PORTS:-}" -e NAMES_PORTS
read -p "token: " -i "${DUCKDNS_TOKEN:-}" -e DUCKDNS_TOKEN
echo ""





# SSH key generation with optional regeneration
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
    # Generate SSH keys for tunnel
    ssh-keygen -t ed25519 -f tunnel_key -N ""
    SSH_PRIVATE_KEY=$(cat tunnel_key)
    SSH_PUBLIC_KEY=$(cat tunnel_key.pub)
    rm tunnel_key tunnel_key.pub
    echo -e "${GREEN}New SSH keys generated.${NC}"
fi

read -p "are you sure? Ctrl-C to abort writing new .env"

cat > .env << EOF
PUBLIC_IP="${PUBLIC_IP}"
DUCKDNS_NAMES=${DUCKDNS_NAMES}
NAMES_PORTS=${NAMES_PORTS}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
EOF
cat > there/.env << EOF
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
EOF

bash build-docker-compose.sh

if [[ "${GENERATE_KEYS}" == true ]]; then
    echo "Now, if your proxy host is named 'd',"
    echo " scp -r there/{.,}* d:leproxy"
    echo "Then at d:leproxy run:"
    echo " sudo ufw allow 2029/tcp # etc"
    echo " docker compose up -d"
else
    echo "Then here:"
    echo " docker compose up -d"
    echo "By the way this:"
    echo " docker logs leproxy-ssh-tunnel-source-1"
    echo "Should say:"
    echo " debug1: forwarding_success: all expected forwarding replies received"
    

fi
