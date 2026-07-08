#
# range42-catalog - admin/vaultwarden
#

SERVICE = vaultwarden
IMAGE   = vaultwarden/server:1.36.0-alpine

.PHONY: help up down stop restart logs term hash clean print

help:
	@echo ""
	@echo " Available : "
	@echo ""
	@echo "  make up        - start Vaultwarden in the background (needs .env)"
	@echo "  make down      - stop and remove the container"
	@echo "  make stop      - stop $(SERVICE) only"
	@echo "  make restart   - restart $(SERVICE) (e.g. after toggling signups)"
	@echo ""
	@echo "  make hash      - generate an ADMIN_TOKEN argon2 hash for .env"
	@echo "  make logs      - tail $(SERVICE) logs"
	@echo "  make term      - open a shell in the $(SERVICE) container"
	@echo "  make clean     - stop and remove container AND the data volume"
	@echo "  make print     - print this help"
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

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Generate an argon2 ADMIN_TOKEN hash to paste (quoted) into .env.
# Prompts for the token interactively and prints the "$argon2id$..." string.
hash:
	docker run --rm -it $(IMAGE) /vaultwarden hash

logs:
	docker compose logs -f $(SERVICE)

term:
	docker exec -it $(SERVICE) /bin/sh

# WARNING: `clean` deletes the vaultwarden-data volume - all stored
# credentials, accounts and the admin config are destroyed.
clean:
	docker compose down -v

print: help
