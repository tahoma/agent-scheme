EMACS ?= emacs
AGENT_SCHEME_COMPILE_HOST ?= racket
AGENT_SCHEME_COMPILE_BUILD_DIR ?= build/compile
AGENT_SCHEME_RACKET ?= racket
AGENT_SCHEME_RACO ?= raco
AGENT_SCHEME_GAMBIT ?= gsi
AGENT_SCHEME_GAMBIT_COMPILER ?= gsc
AGENT_SCHEME_CYCLONE ?= icyc
AGENT_SCHEME_CYCLONE_COMPILER ?= cyclone
AGENT_SCHEME_TEST_RUNNER = $(EMACS) -Q --batch --load tests/agent-scheme-test-runner.el
AGENT_SCHEME_TEST_ENV = $(if $(strip $(AGENT_SCHEME_TEST_TARGET_ROOT)),AGENT_SCHEME_TEST_TARGET_ROOT='$(AGENT_SCHEME_TEST_TARGET_ROOT)',)
AGENT_SCHEME_TEST_RUNNER_COMMAND = $(AGENT_SCHEME_TEST_ENV) $(AGENT_SCHEME_TEST_RUNNER)
AGENT_SCHEME_PARALLEL_MAKE = $(MAKE) --no-print-directory
AGENT_SCHEME_ELISP_SOURCES := $(sort $(wildcard lisp/*.el))
AGENT_SCHEME_PORTABLE_TEST_SELECTOR ?= "agent-scheme-scheme-.*"
AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR ?= "^agent-scheme-scheme-eval-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR ?= (and "agent-scheme-scheme-.*" (not "^agent-scheme-scheme-eval-test-r7rs-suite$$") (not "^agent-scheme-scheme-.*-host-test-r7rs-suite$$"))
AGENT_SCHEME_PORTABLE_GAMBIT_TEST_SELECTOR ?= "^agent-scheme-scheme-gambit-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR ?= "^agent-scheme-scheme-gambit-native-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_RACKET_TEST_SELECTOR ?= "^agent-scheme-scheme-racket-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_COMPILED_TEST_SELECTOR ?= "^agent-scheme-scheme-compiled-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_GUILE_TEST_SELECTOR ?= "^agent-scheme-scheme-guile-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_GAUCHE_TEST_SELECTOR ?= "^agent-scheme-scheme-gauche-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_CYCLONE_TEST_SELECTOR ?= "^agent-scheme-scheme-cyclone-host-test-r7rs-suite$$"
AGENT_SCHEME_PORTABLE_CYCLONE_NATIVE_TEST_SELECTOR ?= "^agent-scheme-scheme-cyclone-native-host-test-r7rs-suite$$"
AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR ?= (not "agent-scheme-scheme-.*")
AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR ?= (or "agent-scheme-base.*" "agent-scheme-eval.*" "agent-scheme-interpreter-module.*" "agent-scheme-macro.*" "agent-scheme-reader.*" "agent-scheme-result.*" "agent-scheme-runtime.*")
AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR ?= (or "agent-scheme-conformance.*" "agent-scheme-fixture.*" "agent-scheme-host-adapter-fixture.*" "agent-scheme-library.*" "agent-scheme-oracle.*")
AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR ?= (or "agent-scheme-agent-io.*" "agent-scheme-approval.*" "agent-scheme-capability.*" "agent-scheme-context.*" "agent-scheme-helper.*" "agent-scheme-memory.*" "agent-scheme-models.*" "agent-scheme-network.*" "agent-scheme-plan.*" "agent-scheme-policy.*" "agent-scheme-redaction.*" "agent-scheme-session.*" "agent-scheme-task.*" "agent-scheme-test.*" "agent-scheme-transcript.*")
AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR ?= (or "agent-scheme-ci.*" "agent-scheme-compile.*" "agent-scheme-control-loop-doc.*" "agent-scheme-debugger.*" "agent-scheme-diagnostics.*" "agent-scheme-diff.*" "agent-scheme-docstring-metadata-doc.*" "agent-scheme-feature-reflection-doc.*" "agent-scheme-job.*" "agent-scheme-native-cli-daemon-doc.*" "agent-scheme-reflect.*" "agent-scheme-repl.*" "agent-scheme-skill.*" "agent-scheme-smoke.*" "agent-scheme-vcs.*")
AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR ?= agent-scheme-models-test-live-local-openai-compatible-completion
AGENT_SCHEME_LIVE_MODEL_SELECTOR ?= "agent-scheme-models-test-live-local-.*"
AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche
AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-eval test-portable-rest
AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS ?= test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools
AGENT_SCHEME_TEST_SHARD_TARGETS ?= $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS) $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS)
AGENT_SCHEME_PORTABLE_TEST_JOBS ?= $(words $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS))
AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_JOBS ?= $(words $(AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS))
AGENT_SCHEME_EMACS_TEST_JOBS ?= $(words $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS))
AGENT_SCHEME_TEST_JOBS ?= $(words $(AGENT_SCHEME_TEST_SHARD_TARGETS))

.DEFAULT_GOAL := help

.PHONY: help clean clean-compile compile compile-elisp test test-portable test-portable-chibi test-portable-eval test-portable-rest test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche test-portable-cyclone test-portable-cyclone-native test-emacs-hosted test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools test-live-model-ci test-live-model conformance-oracle

help:
	@printf '%s\n' 'Agent Scheme top-level actions:'
	@printf '  %-26s %s\n' 'help' 'Show this help.'
	@printf '  %-26s %s\n' 'clean' 'Remove generated Elisp bytecode.'
	@printf '  %-26s %s\n' 'clean-compile' 'Remove host-compiled portable executable outputs.'
	@printf '  %-26s %s\n' 'compile' 'Build host-compiled portable executable artifacts.'
	@printf '  %-26s %s\n' 'compile-elisp' 'Byte-compile checked-in Elisp sources.'
	@printf '  %-26s %s\n' 'test' 'Run the project test suite across local shards.'
	@printf '  %-26s %s\n' 'test-portable' 'Run the default portable R7RS host shards.'
	@printf '  %-26s %s\n' 'test-portable-chibi' 'Run the optional portable R7RS Chibi shards.'
	@printf '  %-26s %s\n' 'test-portable-eval' 'Run the optional portable R7RS Chibi evaluator subset shard.'
	@printf '  %-26s %s\n' 'test-portable-rest' 'Run the optional portable R7RS Chibi non-evaluator subset shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit' 'Run the portable R7RS Gambit full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit-native' 'Build and run the Gambit-native Agent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-racket' 'Run the portable R7RS Racket full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-compiled' 'Build and run the compiled Agent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-guile' 'Run the portable R7RS Guile full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gauche' 'Run the portable R7RS Gauche full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-cyclone' 'Run the optional portable R7RS Cyclone interpreter host shard.'
	@printf '  %-26s %s\n' 'test-portable-cyclone-native' 'Build and run the Cyclone-native Agent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-emacs-hosted' 'Run all non-portable Emacs-hosted ERT tests.'
	@printf '  %-26s %s\n' 'test-emacs-core' 'Run the Emacs-hosted core language/runtime shard.'
	@printf '  %-26s %s\n' 'test-emacs-library' 'Run the Emacs-hosted library/conformance shard.'
	@printf '  %-26s %s\n' 'test-emacs-capabilities' 'Run the Emacs-hosted capability and policy shard.'
	@printf '  %-26s %s\n' 'test-emacs-tools' 'Run the Emacs-hosted tools, docs, and integration shard.'
	@printf '  %-26s %s\n' 'test-live-model-ci' 'Run the CI live local model smoke test.'
	@printf '  %-26s %s\n' 'test-live-model' 'Run all opt-in live local model tests.'
	@printf '  %-26s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-50s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_COMPILE_HOST=racket|gambit|cyclone' 'Host compiler path selected by make compile.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_COMPILE_BUILD_DIR=build/compile' 'Output tree used by make compile.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_TARGET_ROOT=DIR' 'Optional portable Scheme implementation root for the current harness.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_SOURCE_METADATA=on|off' 'Default source metadata mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_DOCSTRING_RETENTION=full|simple|none' 'Default docstring retention mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_JOBS=N' 'Parallel jobs used by make test.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_SHARD_TARGETS=a b' 'Shard targets run by make test.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS=a b' 'Optional portable shard targets run by make test-portable-chibi.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_JOBS=N' 'Parallel jobs used by make test-portable-chibi.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-eval.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-rest.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_GAMBIT_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gambit.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gambit-native.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_RACKET_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-racket.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_COMPILED_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-compiled.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_GUILE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-guile.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_GAUCHE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gauche.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_CYCLONE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-cyclone.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_PORTABLE_CYCLONE_NATIVE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-cyclone-native.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-hosted.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-core.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-library.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-capabilities.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-tools.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR=SEL' 'ERT selector used by make test-live-model-ci.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_LIVE_MODEL_SELECTOR=SEL' 'ERT selector used by make test-live-model.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_LIVE_MODEL_ENDPOINT=URL' 'OpenAI-compatible endpoint for live local model tests.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_LIVE_MODEL_ID=ID' 'Model id used by the live local smoke test.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_CHIBI=chibi-scheme' 'Optional Chibi Scheme command for Chibi portable checks and oracle runs.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_GAUCHE=gosh' 'Optional Gauche command for oracle runs.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_GUILE=guile' 'Optional Guile command for oracle runs.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_SAGITTARIUS=sagittarius' 'Optional Sagittarius command for oracle runs.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_RACKET=racket' 'Optional Racket command for oracle runs and compile packaging.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_RACO=raco' 'Optional Racket raco command for compile packaging.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_CHICKEN=csi' 'Optional CHICKEN command for oracle runs with the r7rs egg.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_GAMBIT=gsi' 'Optional Gambit command for oracle runs and compile checks.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_GAMBIT_COMPILER=gsc' 'Optional Gambit compiler command for compile checks.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_CYCLONE=icyc' 'Optional Cyclone interpreter command for oracle runs and portable checks.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_CYCLONE_COMPILER=cyclone' 'Optional Cyclone compiler command for compile checks.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_GAMBIT_NATIVE=agent-scheme' 'Optional Gambit-native compiled runner for tests.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_CYCLONE_NATIVE=agent-scheme' 'Optional Cyclone-native compiled runner for tests.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_ORACLE_REFERENCES=a,b' 'Optional comma-separated oracle reference filter.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_ORACLE_STATUSES=a,b' 'Optional comma-separated oracle report status filter.'
	@printf '  %-50s %s\n' 'AGENT_SCHEME_ORACLE_SUMMARY=1' 'Print an oracle status summary before report lines.'

clean:
	find lisp -name '*.elc' -exec rm -f {} +

clean-compile:
	rm -rf '$(AGENT_SCHEME_COMPILE_BUILD_DIR)'

compile:
	AGENT_SCHEME_COMPILE_HOST='$(AGENT_SCHEME_COMPILE_HOST)' \
	AGENT_SCHEME_COMPILE_BUILD_DIR='$(AGENT_SCHEME_COMPILE_BUILD_DIR)' \
	AGENT_SCHEME_RACKET='$(AGENT_SCHEME_RACKET)' \
	AGENT_SCHEME_RACO='$(AGENT_SCHEME_RACO)' \
	AGENT_SCHEME_GAMBIT='$(AGENT_SCHEME_GAMBIT)' \
	AGENT_SCHEME_GAMBIT_COMPILER='$(AGENT_SCHEME_GAMBIT_COMPILER)' \
	AGENT_SCHEME_CYCLONE='$(AGENT_SCHEME_CYCLONE)' \
	AGENT_SCHEME_CYCLONE_COMPILER='$(AGENT_SCHEME_CYCLONE_COMPILER)' \
	tools/compile-portable.sh

compile-elisp:
	$(EMACS) -Q --batch -L lisp --eval "(setq load-prefer-newer t)" -f batch-byte-compile $(AGENT_SCHEME_ELISP_SOURCES)

ifneq ($(strip $(AGENT_SCHEME_TEST_SELECTOR)),)
test:
	$(AGENT_SCHEME_TEST_RUNNER_COMMAND)
else
test:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_TEST_JOBS) $(AGENT_SCHEME_TEST_SHARD_TARGETS)
endif

ifneq ($(filter environment command line override,$(origin AGENT_SCHEME_PORTABLE_TEST_SELECTOR)),)
test-portable:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)
else
test-portable:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_PORTABLE_TEST_JOBS) $(AGENT_SCHEME_PORTABLE_TEST_SHARD_TARGETS)
endif

test-portable-chibi:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_JOBS) $(AGENT_SCHEME_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS)

test-portable-eval:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_EVAL_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-rest:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_REST_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-gambit:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_GAMBIT_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-gambit-native:
	@if command -v '$(AGENT_SCHEME_GAMBIT)' >/dev/null 2>&1 && command -v '$(AGENT_SCHEME_GAMBIT_COMPILER)' >/dev/null 2>&1; then \
		AGENT_SCHEME_COMPILE_HOST=gambit $(AGENT_SCHEME_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Gambit compile prerequisites are not available; Gambit native host shard will skip if no runner exists.'; \
	fi
	@if [ -f '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/gambit/logs/compile.log' ]; then cat '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/gambit/logs/compile.log'; fi
	@if [ -f '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/gambit/logs/smoke.log' ]; then cat '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/gambit/logs/smoke.log'; fi
	AGENT_SCHEME_GAMBIT_NATIVE='$(abspath $(AGENT_SCHEME_COMPILE_BUILD_DIR)/gambit/bin/agent-scheme)' AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-racket:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_RACKET_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-compiled:
	@if command -v '$(AGENT_SCHEME_RACKET)' >/dev/null 2>&1 && command -v '$(AGENT_SCHEME_RACO)' >/dev/null 2>&1; then \
		AGENT_SCHEME_COMPILE_HOST=racket $(AGENT_SCHEME_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Racket compile prerequisites are not available; compiled host shard will skip if no runner exists.'; \
	fi
	AGENT_SCHEME_COMPILED='$(abspath $(AGENT_SCHEME_COMPILE_BUILD_DIR)/racket/bin/agent-scheme)' AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_COMPILED_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-guile:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_GUILE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-gauche:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_GAUCHE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-cyclone:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_CYCLONE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-portable-cyclone-native:
	@if command -v '$(AGENT_SCHEME_CYCLONE)' >/dev/null 2>&1 && command -v '$(AGENT_SCHEME_CYCLONE_COMPILER)' >/dev/null 2>&1; then \
		AGENT_SCHEME_COMPILE_HOST=cyclone $(AGENT_SCHEME_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Cyclone compile prerequisites are not available; Cyclone native host shard will skip if no runner exists.'; \
	fi
	@if [ -f '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/cyclone/logs/compile.log' ]; then cat '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/cyclone/logs/compile.log'; fi
	@if [ -f '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/cyclone/logs/smoke.log' ]; then cat '$(AGENT_SCHEME_COMPILE_BUILD_DIR)/cyclone/logs/smoke.log'; fi
	AGENT_SCHEME_CYCLONE_NATIVE='$(abspath $(AGENT_SCHEME_COMPILE_BUILD_DIR)/cyclone/bin/agent-scheme)' AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_PORTABLE_CYCLONE_NATIVE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

ifneq ($(filter environment command line override,$(origin AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR)),)
test-emacs-hosted:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_HOSTED_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)
else
test-emacs-hosted:
	$(AGENT_SCHEME_PARALLEL_MAKE) -j$(AGENT_SCHEME_EMACS_TEST_JOBS) $(AGENT_SCHEME_EMACS_TEST_SHARD_TARGETS)
endif

test-emacs-core:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_CORE_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-emacs-library:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_LIBRARY_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-emacs-capabilities:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_CAPABILITY_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-emacs-tools:
	AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_EMACS_TOOLS_TEST_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-live-model-ci:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_CI_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

test-live-model:
	AGENT_SCHEME_LIVE_MODEL_TEST=1 AGENT_SCHEME_LIVE_MODEL_MATRIX=1 AGENT_SCHEME_TEST_SELECTOR='$(AGENT_SCHEME_LIVE_MODEL_SELECTOR)' $(AGENT_SCHEME_TEST_RUNNER_COMMAND)

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(setq load-prefer-newer t)" --eval "(require 'agent-scheme-oracle)" --eval "(agent-scheme-oracle-batch-main)"
