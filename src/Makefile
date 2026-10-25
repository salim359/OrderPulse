# SAM Makefile builder — compiles TypeScript with tsc, then packages JS + deps.
# ARTIFACTS_DIR is set by `sam build` for each function.

.PHONY: build-EmailWorkerFunction build-AuditWorkerFunction build-common

build-EmailWorkerFunction: build-common
	cp -R dist/. "$(ARTIFACTS_DIR)/"
	cp package.json package-lock.json "$(ARTIFACTS_DIR)/" 2>/dev/null || cp package.json "$(ARTIFACTS_DIR)/"
	cd "$(ARTIFACTS_DIR)" && npm install --omit=dev --no-audit --no-fund

build-AuditWorkerFunction: build-common
	cp -R dist/. "$(ARTIFACTS_DIR)/"
	cp package.json package-lock.json "$(ARTIFACTS_DIR)/" 2>/dev/null || cp package.json "$(ARTIFACTS_DIR)/"
	cd "$(ARTIFACTS_DIR)" && npm install --omit=dev --no-audit --no-fund

build-common:
	npm ci --no-audit --no-fund
	npx tsc -p tsconfig.json
