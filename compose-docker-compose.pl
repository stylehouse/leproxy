use FindBin '$Bin';
use feature 'say';


@ports = split ',', $ENV{NAMES_PORTS};
@names = split ',', $ENV{DUCKDNS_NAMES};

!@names and die "No ENV DUCKDNS_NAMES: ".$ENV{NAMES_PORTS};
@ports != @names and die "miscount NAMES_PORTS <-> DUCKDNS_NAMES";

open $fh, '>', "$Bin/docker-compose.yml";
print $fh <<'';
services:
  # tells duckdns your ip
  duckdns-updater:
    build:
      context: .
      dockerfile_inline: |
        FROM alpine:3.19
        RUN apk add --no-cache curl
        COPY duckdns_update.sh /
        CMD ["ash","duckdns_update.sh"]
    environment:
      - PUBLIC_IP=${PUBLIC_IP}
      - DUCKDNS_NAMES=${DUCKDNS_NAMES}
      - DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
    # dont leave a failing update loop going
    restart: no
  
  # ssh -R connects their :80 and :443 to the Caddy service here
  ssh-tunnel-source:
    build:
      context: .
      dockerfile_inline: |
        FROM alpine:3.19
        RUN apk add --no-cache openssh-client
        RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
    command: |
      sh -c 'echo "$$SSH_PRIVATE_KEY" > /root/.ssh/id_ed25519 && \
      chmod 600 /root/.ssh/id_ed25519 && \
      exec ssh -v -N \
        -R 0.0.0.0:80:caddy:80 \
        -R 0.0.0.0:443:caddy:443 \
        -i /root/.ssh/id_ed25519 \
        -o ServerAliveInterval=30 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=accept-new \
        -p 2029 \
        root@d'
    environment:
      - SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
    depends_on:
      - caddy
    networks:
      - web
    restart: always
  
  # this caddy uses HTTP/TLS challenges (requiring port 443 access)
  #  not building modules for duckdns saves a bit of time here
  caddy:
    image: caddy:2
    # doesn't expose the hosting to your local network
    #  only way in is the proxy with a domain name
    # ports:
    #   - "2080:80"
    #   - "2443:443"
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ./logs:/var/log/caddy
    configs:
      - source: caddy_config
        target: /etc/caddy/Caddyfile
    networks:
      - web
    restart: always
  
volumes:
  caddy_data:
  caddy_config:
networks:
  web:
configs:
  caddy_config:
    content: |

# all dockers on your machine can bind ports on the docker0 interface
#  which is usually at this ip
$docker0ip = '172.17.0.1';

# < $docker0ip should be derived from `ip addr | grep docker0`?
for $name (@names) {
    ($port,$host) = reverse split ':', shift @ports;
    $host ||= $docker0ip;
    say " - handle $name -> $host:$port";
    $host !~ /^[\w\.:]+$/ and die "weird host: $host";
    $port !~ /^\d+$/ and die "weird host: $port";

    $extra = "";
    if ($name =~ /^d?(jam|vou)/) {
        # share a WebRTC signaling server aft Caddy
        $extra .= <<"";
          handle_path /peerjs-server/* {
              reverse_proxy $host:9995
          }

    }

    print $fh <<""
      $name.duckdns.org {
          encode zstd gzip

    . $extra
    . <<"";
          handle {
              reverse_proxy $host:$port
          }
          header {
              Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
              X-Content-Type-Options "nosniff"
              X-XSS-Protection "1; mode=block"
              X-Frame-Options "DENY"
          }
          log {
              output file /var/log/caddy/$name/access.log
              format console
          }
      }
      http://$name.duckdns.org {
          redir https://{host}{uri} permanent
      }

}

close STDOUT;
say "done";
