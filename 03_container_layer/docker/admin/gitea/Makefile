#
# ISSUE 141
#

SERVICE       = gitea
PROVISIONER   = gitea-provisioner
DEBUG_SERVICE = $(SERVICE)-debug

.PHONY: up down stop build rebuild build-up rebuild-up reprovision \
        logs-provisioner tokens keys term term-debug-build clean print help

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
	@echo "  make reprovision       - remove provisioning stamps (.provisioned + .org-provisioned) and restart"
	@echo "  make logs-provisioner  - tail provisioner output"
	@echo "  make tokens            - print generated API tokens"
	@echo "  make keys              - print full credentials JSON (usernames + passwords)"
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
	docker run --rm -v gitea_gitea-tokens:/tokens alpine rm -f /tokens/.provisioned /tokens/.org-provisioned
	docker compose up $(PROVISIONER)

logs-provisioner:
	docker compose logs -f $(PROVISIONER)

tokens:
	docker run --rm -v gitea_gitea-tokens:/tokens alpine cat /tokens/tokens.txt

keys:
	docker run --rm -v gitea_gitea-tokens:/tokens alpine cat /tokens/gitea-credentials.json

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

clean:
	docker compose down -v --rmi all

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

term:
	docker exec -it $(SERVICE) /bin/sh

term-debug-build:
	docker compose up --build -d debug
	docker exec -it $(DEBUG_SERVICE) /bin/sh

print: help
