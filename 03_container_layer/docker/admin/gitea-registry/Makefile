#
# ISSUE 142
#

SERVICE       = gitea-registry
PROVISIONER   = gitea-registry-provisioner
DEBUG_SERVICE = $(SERVICE)-debug

help:
	@echo ""
	@echo ""
	@echo " Available : "
	@echo ""
	@echo "  make up                - run the full stack (db + gitea + provisioner) in background"
	@echo "  make down              - stop and remove all containers"
	@echo "  make stop              - stop $(SERVICE) only"
	@echo ""
	@echo "  make build             - build the provisioner image"
	@echo "  make build-up          - build provisioner image then start the full stack"
	@echo ""
	@echo "  make rebuild           - full rebuild without cache"
	@echo "  make rebuild-up        - full rebuild without cache then start"
	@echo ""
	@echo "  make reprovision       - remove the provisioning stamp and restart provisioner"
	@echo "  make logs-provisioner  - tail provisioner output"
	@echo ""
	@echo "  make tokens            - display generated registry tokens"
	@echo ""
	@echo "  make term              - open shell in $(SERVICE) container"
	@echo "  make term-debug-build  - build and open shell in $(DEBUG_SERVICE)"
	@echo "  make clean             - delete all containers, images, volumes and unused network"
	@echo "  make print             - print this help"
	@echo ""
	@echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

up:
	docker compose up -d
down:
	docker compose down
stop:
	docker compose stop $(SERVICE)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

build:
	docker compose build

rebuild:
	docker compose down
	docker compose build --no-cache

# # # # # # # # # # # #

build-up:
	docker compose build
	docker compose up -d

rebuild-up:
	docker compose down
	docker compose build --no-cache
	docker compose up -d

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

reprovision:
	docker exec $(SERVICE) rm -f /data/gitea/.provisioned
	docker compose restart $(PROVISIONER)

logs-provisioner:
	docker compose logs -f $(PROVISIONER)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

tokens:
	docker run --rm -v gitea-registry-tokens:/tokens alpine cat /tokens/tokens.txt

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

clean:
	docker compose down -v --rmi all

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

term:
	docker exec -it $(SERVICE) /bin/sh

term-debug-build:
	@echo "Uncomment the 'debug' service in compose.yml first, then re-run."

print: help
