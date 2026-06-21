SHELL := /usr/bin/env bash
SCRIPTS := dependabot-merger.sh tests/run_tests.sh

.PHONY: all lint test check

all: check

lint:
	shellcheck -x $(SCRIPTS)

test:
	./tests/run_tests.sh

check: lint test
