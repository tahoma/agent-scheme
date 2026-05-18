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
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GAUCHE=gosh' 'Optional Gauche command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GUILE=guile' 'Optional Guile command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_SAGITTARIUS=sagittarius' 'Optional Sagittarius command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_RACKET=racket' 'Optional Racket command for oracle runs with the r7rs package.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_CHICKEN=csi' 'Optional CHICKEN command for oracle runs with the r7rs egg.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_REFERENCES=a,b' 'Optional comma-separated oracle reference filter.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_STATUSES=a,b' 'Optional comma-separated oracle report status filter.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_SUMMARY=1' 'Print an oracle status summary before report lines.'

test:
	$(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(require 'agent-scheme-oracle)" --eval "(agent-scheme-oracle-batch-main)"
