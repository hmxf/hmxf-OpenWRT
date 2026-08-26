DEVICE ?= x86_64
PRESET ?= minimal
CACHE_ROOT ?= .cache/packages
LOCKED_VERSION := $(shell awk -F= '$$1 == "IMMORTALWRT_VERSION" { print $$2 }' locks/release.env)
DESTINATION ?=
TEST_MODE ?= canonical
UPSTREAM_STATE ?= build/upstream/UPSTREAM_STATE.env
STABLE_RELEASE_PRESENT ?= 1
UPDATE_MODE ?= auto
STABLE_VERSION ?= latest
CHANNEL ?= stable
IDENTITY ?= $(LOCKED_VERSION)
FIRMWARE_INPUT_ROOT ?= out/$(LOCKED_VERSION)
NIGHTLY_ASSETS ?=

.PHONY: validate test test-static test-contract test-component test-build test-matrix \
	check-latest image images matrix prepare-inputs stage-inputs cache-index cache-verify \
	smoke-x86 source-check source source-audit refresh-locks apply-locks \
	check-updates nightly restore-nightly stage-firmware

validate:
	./scripts/verify/validate-project.sh

test:
	./tests/run.sh all

test-static:
	./tests/run.sh static

test-contract:
	./tests/run.sh contract

test-component:
	./tests/run.sh component

test-build:
	./tests/run-build.sh "$(TEST_MODE)" "$(DEVICE)" "$(PRESET)"

test-matrix:
	./tests/run-build.sh "$(TEST_MODE)" matrix

check-latest:
	./scripts/locks/check-latest-release.sh

check-updates:
	./scripts/locks/check-upstream-updates.sh \
		--output "$(UPSTREAM_STATE)" \
		--stable-release-present "$(STABLE_RELEASE_PRESENT)" \
		--force "$(UPDATE_MODE)" \
		--stable-version "$(STABLE_VERSION)"

image: validate
	./scripts/build/build-imagebuilder.sh "$(DEVICE)" "$(PRESET)"

images: validate
	./scripts/build/build-imagebuilder.sh x86_64 "$(PRESET)"
	./scripts/build/build-imagebuilder.sh rpi4 "$(PRESET)"
	./scripts/build/build-imagebuilder.sh rpi5 "$(PRESET)"

matrix: validate
	./scripts/build/build-imagebuilder.sh x86_64 minimal
	./scripts/build/build-imagebuilder.sh x86_64 full
	./scripts/build/build-imagebuilder.sh rpi4 minimal
	./scripts/build/build-imagebuilder.sh rpi4 full
	./scripts/build/build-imagebuilder.sh rpi5 minimal
	./scripts/build/build-imagebuilder.sh rpi5 full

nightly:
	./scripts/build/build-nightly.sh "$(UPSTREAM_STATE)" matrix

restore-nightly:
	@[ -n "$(NIGHTLY_ASSETS)" ] || { \
		printf '%s\n' 'error: restore-nightly requires NIGHTLY_ASSETS=/path/to/flat-release-assets' >&2; \
		exit 2; \
	}
	./scripts/inputs/restore-nightly-inputs.sh "$(NIGHTLY_ASSETS)"

prepare-inputs: validate
	./scripts/inputs/restore-locked-inputs.sh "$(DEVICE)"

stage-inputs: validate
	@if [ -n "$(CANDIDATE)" ]; then \
		[ -n "$(DESTINATION)" ] || { \
			printf '%s\n' 'error: candidate staging requires an explicit DESTINATION' >&2; \
			exit 2; \
		}; \
		./scripts/inputs/stage-locked-input-release.sh --candidate "$(CANDIDATE)" "$(DESTINATION)"; \
	else \
		destination="$(DESTINATION)"; \
		[ -n "$$destination" ] || destination="dist/locked-inputs/$(LOCKED_VERSION)"; \
		./scripts/inputs/stage-locked-input-release.sh "$$destination"; \
	fi

cache-index:
	./scripts/cache/index-package-cache.sh update "$(CACHE_ROOT)"

cache-verify:
	./scripts/cache/index-package-cache.sh verify "$(CACHE_ROOT)"

smoke-x86:
	./scripts/verify/smoke-test-x86-uefi.sh "out/$$(awk -F= '$$1 == "IMMORTALWRT_VERSION" { print $$2 }' locks/release.env)/x86_64/$(PRESET)"

source-check: validate
	CHECK_ONLY=1 ./scripts/build/build-source.sh "$(DEVICE)" "$(PRESET)"

source: validate
	./scripts/build/build-source.sh "$(DEVICE)" "$(PRESET)"

source-audit: validate
	BUILD_CONFIG=configs/build-debug.env ./scripts/build/build-source.sh "$(DEVICE)" "$(PRESET)"

refresh-locks:
	./scripts/locks/refresh-locks.sh "$(VERSION)"

apply-locks:
	./scripts/locks/apply-lock-candidate.sh "$(CANDIDATE)"

stage-firmware: validate
	@[ -n "$(DESTINATION)" ] || { \
		printf '%s\n' 'error: stage-firmware requires DESTINATION' >&2; \
		exit 2; \
	}
	./scripts/inputs/stage-firmware-release.sh \
		"$(CHANNEL)" "$(FIRMWARE_INPUT_ROOT)" "$(DESTINATION)" "$(IDENTITY)"
