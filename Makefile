# Postgres Manager
#
# The real work lives in Scripts/ so that CI, the Makefile and install.sh all
# run exactly the same steps.

.PHONY: all app dmg run install test icon clean

all: app

app:
	@Scripts/build-app.sh release

debug:
	@Scripts/build-app.sh debug

dmg: app
	@Scripts/make-dmg.sh

run: app
	@pkill -x PostgresManager 2>/dev/null || true
	@open build/PostgresManager.app

install:
	@./install.sh

test:
	@Scripts/test.sh

icon:
	@swift Scripts/make-icon.swift Resources

clean:
	swift package clean
	rm -rf build
