#
# ISSUE 147
#

SERVICE     = rocketchat
PROVISIONER = provisioner
DEBUG_SERVICE = $(SERVICE)-debug

.PHONY: help up down stop stop-debug-build build rebuild build-up rebuild-up tokens creds logs-provisioner reprovision term term-debug-build clean print

help:
	@echo ""
	@echo ""
	@echo " Available : "
	@echo ""
	@echo "  make up                - run  $(SERVICE) stack in background"
	@echo "  make down              - down $(SERVICE) stack"
	@echo "  make stop              - stop $(SERVICE) "
	@echo "  make stop-debug-build  - stop $(DEBUG_SERVICE) "
	@echo ""
	@echo "  make build             - build $(SERVICE) image"
	@echo "  make build-up          - build $(SERVICE) image then run"
	@echo ""
	@echo "  make rebuild           - full rebuild $(SERVICE) without cache"
	@echo "  make rebuild-up        - full rebuild $(SERVICE) without cache then run"
	@echo ""
	@echo "  make tokens            - print generated personal access tokens"
	@echo "  make creds             - print full credentials JSON (rocketchat-credentials.json)"
	@echo "  make logs-provisioner  - tail provisioner container logs"
	@echo "  make term              - open shell in $(SERVICE) container"
	@echo "  make term-debug-build  - build and get term on $(DEBUG_SERVICE) "
	@echo "  make clean             - delete all containers, images, volumes and unused network"
	@echo "  make print             - print this help"
	@echo ""
	@echo ""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

up:
	docker compose up -d $(SERVICE)
down:
	docker compose down
stop:
	docker compose stop $(SERVICE) # stop only - main

stop-debug-build :
	docker compose stop $(DEBUG_SERVICE) # stop only debug
	docker compose rm -sf $(DEBUG_SERVICE)

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

tokens:
	docker compose run --rm --no-deps --entrypoint sh $(PROVISIONER) -c 'cat /tokens/tokens.txt'

reprovision:
	docker compose run --rm --no-deps --entrypoint sh $(PROVISIONER) -c 'rm -f /tokens/.provisioned'
	docker compose up $(PROVISIONER)

creds:
	docker compose run --rm --no-deps --entrypoint sh $(PROVISIONER) -c 'cat /tokens/rocketchat-credentials.json'

logs-provisioner:
	docker compose logs -f $(PROVISIONER)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

clean:
	docker compose down -v --rmi all

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

term:
	docker exec -it $(SERVICE) /bin/sh

term-debug-build:
	docker compose up --build -d $(DEBUG_SERVICE)
	docker exec -it $(DEBUG_SERVICE) /bin/sh

print: help
