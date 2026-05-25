EMACS ?= emacs
AGENT_SCHEME_TEST_RUNNER = $(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el
AGENT_SCHEME_PORTABLE_TEST_SELECTOR ?= "agent-scheme-scheme-.*"
AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR ?= (not "agent-scheme-scheme-.*")
AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR ?= agent-scheme-models-test-live-local-openai-compatible-completion
AGENT_SCHEME_LIVE_MODEL_SELECTOR ?= "agent-scheme-models-test-live-local-.*"

.DEFAULT_GOAL := help

.PHONY: help test test-portable test-emacs-hosted test-live-model-ci test-live-model conformance-oracle

help:
	@printf '%s\n' 'Agent Scheme top-level actions:'
	@printf '  %-20s %s\n' 'help' 'Show this help.'
	@printf '  %-20s %s\n' 'test' 'Run the project test suite.'
	@printf '  %-20s %s\n' 'test-portable' 'Run the portable Chibi-backed ERT shard.'
	@printf '  %-20s %s\n' 'test-emacs-hosted' 'Run the remaining Emacs-hosted ERT shard.'
	@printf '  %-20s %s\n' 'test-live-model-ci' 'Run the CI live local model smoke test.'
	@printf '  %-20s %s\n' 'test-live-model' 'Run all opt-in live local model tests.'
	@printf '  %-20s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-40s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_PORTABLE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-hosted.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR=SEL' 'ERT selector used by make test-live-model-ci.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_LIVE_MODEL_SELECTOR=SEL' 'ERT selector used by make test-live-model.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_LIVE_MODEL_ENDPOINT=URL' 'OpenAI-compatible endpoint for live local model tests.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_LIVE_MODEL_ID=ID' 'Model id used by the live local smoke test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_CHIBI=chibi-scheme' 'Optional Chibi Scheme command for portable R7RS tests and oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GAUCHE=gosh' 'Optional Gauche command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GUILE=guile' 'Optional Guile command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_SAGITTARIUS=sagittarius' 'Optional Sagittarius command for oracle runs.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_RACKET=racket' 'Optional Racket command for oracle runs with the r7rs package.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_CHICKEN=csi' 'Optional CHICKEN command for oracle runs with the r7rs egg.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GAMBIT=gsi' 'Optional Gambit command for oracle runs in R7RS mode.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_GAMBIT_COMPILER=gsc' 'Optional Gambit compiler command for future compile checks.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_REFERENCES=a,b' 'Optional comma-separated oracle reference filter.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_STATUSES=a,b' 'Optional comma-separated oracle report status filter.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_ORACLE_SUMMARY=1' 'Print an oracle status summary before report lines.'

test:
	$(AGENT_SCHEME_TEST_RUNNER)

test-portable:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-emacs-hosted:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-live-model-ci:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-live-model:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_LIVE_MODEL_MATRIX=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(require 'agent-scheme-oracle)" --eval "(agent-scheme-oracle-batch-main)"
