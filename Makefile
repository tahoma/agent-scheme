EMACS ?= emacs

.DEFAULT_GOAL := help

.PHONY: help test

help:
	@printf '%s\n' 'Agent Scheme top-level actions:'
	@printf '  %-12s %s\n' 'help' 'Show this help.'
	@printf '  %-12s %s\n' 'test' 'Run the project test suite.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-28s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-28s %s\n' 'AGENT_SCHEME_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'

test:
	$(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el
