#
# range42-catalog - admin/vaultwarden
#

SERVICE = vaultwarden
IMAGE   = vaultwarden/server:1.37.0-alpine

# Extra IP baked into the self-signed cert's SAN, next to 127.0.0.1 and
# localhost. Set it to the address clients will actually use:
#   make cert VW_CERT_IP=192.168.142.181
VW_CERT_IP ?= 127.0.0.1

.PHONY: help up down stop restart reload-env logs term hash cert tls clean print

help:
	@echo ""
	@echo " Available : "
	@echo ""
	@echo "  make up          - start Vaultwarden in the background (needs .env)"
	@echo "  make down        - stop and remove the container"
	@echo "  make stop        - stop $(SERVICE) only"
	@echo "  make restart     - restart $(SERVICE) (does NOT reload .env changes)"
	@echo "  make reload-env  - re-create $(SERVICE) so .env changes take effect"
	@echo ""
	@echo "  make hash        - generate an ADMIN_TOKEN argon2 hash for .env"
	@echo "  make cert        - self-signed TLS cert into ./ssl/ (VW_CERT_IP=<ip>)"
	@echo "  make tls         - enable TLS: compose.tls.example.yml -> compose.override.yml"
	@echo "  make logs        - tail $(SERVICE) logs"
	@echo "  make term        - open a shell in the $(SERVICE) container"
	@echo "  make clean       - stop and remove container AND the data volume"
	@echo "  make print       - print this help"
	@echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

up:
	docker compose up -d

down:
	docker compose down

stop:
	docker compose stop $(SERVICE)

restart:
	docker compose restart $(SERVICE)

# `restart` does NOT re-read .env (compose bakes env at container creation).
# Use this after editing .env (signups toggle, domain change, TLS switch).
reload-env:
	docker compose up -d --force-recreate $(SERVICE)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Generate an argon2 ADMIN_TOKEN hash to paste (quoted) into .env.
# Prompts for the token interactively and prints the "$argon2id$..." string.
# NOTE: needs a real TTY (`/vaultwarden hash` panics without one). From a
# non-interactive session use the argon2 CLI instead:
#   echo -n "<token>" | argon2 "$$(openssl rand -base64 16)" -id -t 3 -m 16 -p 4 -e
hash:
	docker run --rm -it $(IMAGE) /vaultwarden hash

# Self-signed TLS cert for the embedded Rocket server (see
# compose.tls.example.yml). SAN covers VW_CERT_IP + 127.0.0.1 + localhost so
# it stays valid through SSH tunnels. The hardened container (cap_drop: ALL)
# cannot read files owned by another uid: make the files root-owned.
cert:
	mkdir -p ssl
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
		-keyout ssl/key.pem -out ssl/cert.pem \
		-subj "/CN=range42-vaultwarden" \
		-addext "subjectAltName=IP:$(VW_CERT_IP),IP:127.0.0.1,DNS:localhost"
	@echo ""
	@echo "Now make the files readable by the (capability-dropped) container:"
	@echo "  sudo chown -R root:root ssl && sudo chmod 600 ssl/key.pem && sudo chmod 644 ssl/cert.pem"
	@echo "Clients need ssl/cert.pem as a trusted CA (browsers: accept the"
	@echo "warning; bw CLI: export NODE_EXTRA_CA_CERTS=<path-to-cert.pem>)."

# Enable TLS by installing the override (docker compose auto-loads
# compose.override.yml, so every other target keeps working unchanged).
tls:
	cp compose.tls.example.yml compose.override.yml
	@echo "TLS override installed. Set VW_DOMAIN=https://... in .env, then: make reload-env"

logs:
	docker compose logs -f $(SERVICE)

term:
	docker exec -it $(SERVICE) /bin/sh

# WARNING: `clean` deletes the vaultwarden-data volume - all stored
# credentials, accounts and the admin config are destroyed.
clean:
	docker compose down -v

print: help
