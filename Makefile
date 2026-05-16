EMACS ?= emacs

.PHONY: test

test:
	$(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el
