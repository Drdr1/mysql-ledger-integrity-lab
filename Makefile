DB_HOST ?= 127.0.0.1
DB_PORT ?= 3306
DB_USER ?= root
DB_PASSWORD ?= rootpw
DB_NAME ?= ledger
MYSQL = mysql -h $(DB_HOST) -P $(DB_PORT) -u$(DB_USER) -p$(DB_PASSWORD) $(DB_NAME)

.PHONY: up down install test all

up:
	docker compose up -d

down:
	docker compose down -v

install:
	$(MYSQL) < schema/00_install.sql

test:
	DB_HOST=$(DB_HOST) DB_PORT=$(DB_PORT) DB_USER=$(DB_USER) \
	DB_PASSWORD=$(DB_PASSWORD) DB_NAME=$(DB_NAME) pytest -v tests/

all: up
	@echo "waiting for mysql..."; sleep 20
	$(MAKE) install
	$(MAKE) test
