EMACS ?= emacs

.DEFAULT_GOAL := help

.PHONY: help test conformance-oracle

help:
	@printf '%s\n' 'Agent Scheme top-level actions:'
	@printf '  %-20s %s\n' 'help' 'Show this help.'
	@printf '  %-20s %s\n' 'test' 'Run the project test suite.'
	@printf '  %-20s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-40s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_CHIBI=chibi-scheme' 'Optional Chibi Scheme command for portable R7RS tests and oracle runs.'

test:
	$(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(require 'agent-scheme-oracle)" --eval "(agent-scheme-oracle-batch-main)"
