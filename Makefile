EMACS ?= emacs
AGENT_SCHEME_TEST_RUNNER = $(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el
AGENT_SCHEME_PARALLEL_MAKE = $(MAKE) --no-print-directory
AGENT_SCHEME_PORTABLE_TEST_SELECTOR ?= "agent-scheme-scheme-.*"
AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR ?= "^agent-scheme-scheme-eval-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR ?= (and "agent-scheme-scheme-.*" (not "^agent-scheme-scheme-eval-test-r7rs-suite$$"))
AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR ?= (not "agent-scheme-scheme-.*")
AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR ?= (or "agent-scheme-base.*" "agent-scheme-eval.*" "agent-scheme-interpreter-module.*" "agent-scheme-macro.*" "agent-scheme-reader.*" "agent-scheme-result.*" "agent-scheme-runtime.*")
AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR ?= (or "agent-scheme-conformance.*" "agent-scheme-fixture.*" "agent-scheme-host-adapter-fixture.*" "agent-scheme-library.*" "agent-scheme-oracle.*")
AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR ?= (or "agent-scheme-agent-io.*" "agent-scheme-approval.*" "agent-scheme-capability.*" "agent-scheme-context.*" "agent-scheme-helper.*" "agent-scheme-memory.*" "agent-scheme-models.*" "agent-scheme-network.*" "agent-scheme-plan.*" "agent-scheme-policy.*" "agent-scheme-redaction.*" "agent-scheme-session.*" "agent-scheme-task.*")
AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR ?= (or "agent-scheme-ci.*" "agent-scheme-compile.*" "agent-scheme-control-loop-doc.*" "agent-scheme-debugger.*" "agent-scheme-diagnostics.*" "agent-scheme-diff.*" "agent-scheme-feature-reflection-doc.*" "agent-scheme-job.*" "agent-scheme-native-cli-daemon-doc.*" "agent-scheme-reflect.*" "agent-scheme-repl.*" "agent-scheme-skill.*" "agent-scheme-smoke.*" "agent-scheme-vcs.*")
AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR ?= agent-scheme-models-test-live-local-openai-compatible-completion
AGENT_SCHEME_LIVE_MODEL_SELECTOR ?= "agent-scheme-models-test-live-local-.*"
AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-eval test-portable-rest
AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS ?= test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools
AGENT_SCHEME_TEST_SHARD_TARGETS ?= $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS) $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS)
AGENT_SCHEME_PORTABLE_TEST_JOBS ?= $(words $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS))
AGENT_SCHEME_EMACS_TEST_JOBS ?= $(words $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS))
AGENT_SCHEME_TEST_JOBS ?= $(words $(AGENT_SCHEME_TEST_SHARD_TARGETS))

.DEFAULT_GOAL := help

.PHONY: help test test-portable test-portable-eval test-portable-rest test-emacs-hosted test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools test-live-model-ci test-live-model conformance-oracle

help:
	@printf '%s\n' 'Agent Scheme top-level actions:'
	@printf '  %-26s %s\n' 'help' 'Show this help.'
	@printf '  %-26s %s\n' 'test' 'Run the project test suite across local shards.'
	@printf '  %-26s %s\n' 'test-portable' 'Run the portable Chibi-backed ERT shards.'
	@printf '  %-26s %s\n' 'test-portable-eval' 'Run the portable Chibi-backed evaluator shard.'
	@printf '  %-26s %s\n' 'test-portable-rest' 'Run the remaining portable Chibi-backed shard.'
	@printf '  %-26s %s\n' 'test-emacs-hosted' 'Run all non-portable Emacs-hosted ERT tests.'
	@printf '  %-26s %s\n' 'test-emacs-core' 'Run the Emacs-hosted core language/runtime shard.'
	@printf '  %-26s %s\n' 'test-emacs-library' 'Run the Emacs-hosted library/conformance shard.'
	@printf '  %-26s %s\n' 'test-emacs-capabilities' 'Run the Emacs-hosted capability and policy shard.'
	@printf '  %-26s %s\n' 'test-emacs-tools' 'Run the Emacs-hosted tools, docs, and integration shard.'
	@printf '  %-26s %s\n' 'test-live-model-ci' 'Run the CI live local model smoke test.'
	@printf '  %-26s %s\n' 'test-live-model' 'Run all opt-in live local model tests.'
	@printf '  %-26s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-40s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_TEST_JOBS=N' 'Parallel jobs used by make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_TEST_SHARD_TARGETS=a b' 'Shard targets run by make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_PORTABLE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-eval.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-rest.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-hosted.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-core.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-library.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-capabilities.'
	@printf '  %-40s %s\n' 'AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-tools.'
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

ifneq ($(strip $(AGENT_SCHEME_TEST_SELECTOR)),)
test:
	$(AGENT_SCHEME_TEST_RUNNER)
else
test:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_TEST_JOBS) $(AGENT_SCHEME_TEST_SHARD_TARGETS)
endif

ifneq ($(filter environment command line override,$(origin AGENT_SCHEME_PORTABLE_TEST_SELECTOR)),)
test-portable:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)
else
test-portable:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_PORTABLE_TEST_JOBS) $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS)
endif

test-portable-eval:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-portable-rest:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

ifneq ($(filter environment command line override,$(origin AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR)),)
test-emacs-hosted:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)
else
test-emacs-hosted:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_EMACS_TEST_JOBS) $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS)
endif

test-emacs-core:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-emacs-library:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-emacs-capabilities:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-emacs-tools:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-live-model-ci:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

test-live-model:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_LIVE_MODEL_MATRIX=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER)

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(require 'agent-scheme-oracle)" --eval "(agent-scheme-oracle-batch-main)"
