EMACS ?= emacs
CONSENT_COMPILE_HOST ?= racket
CONSENT_COMPILE_BUILD_DIR ?= build/compile
CONSENT_RACKET ?= racket
CONSENT_RACO ?= raco
CONSENT_GAMBIT ?= gsi
CONSENT_GAMBIT_COMPILER ?= gsc
CONSENT_TEST_RUNNER = $(EMACS) -Q --batch --load tests/consent-test-runner.el
CONSENT_TEST_ENV = $(if $(strip $(CONSENT_TEST_TARGET_ROOT)),CONSENT_TEST_TARGET_ROOT='$(CONSENT_TEST_TARGET_ROOT)',)
CONSENT_TEST_RUNNER_COMMAND = $(CONSENT_TEST_ENV) $(CONSENT_TEST_RUNNER)
CONSENT_PARALLEL_MAKE = $(MAKE) --no-print-directory
CONSENT_ELISP_SOURCES := $(sort $(wildcard lisp/*.el))
CONSENT_PORTABLE_TEST_SELECTOR ?= "consent-scheme-.*"
CONSENT_PORTABLE_EVAL_TEST_SELECTOR ?= "^consent-scheme-eval-test-r7rs-suite$$"
CONSENT_PORTABLE_REST_TEST_SELECTOR ?= (and "consent-scheme-.*" (not "^consent-scheme-eval-test-r7rs-suite$$") (not "^consent-scheme-.*-host-test-r7rs-suite$$"))
CONSENT_PORTABLE_GAMBIT_TEST_SELECTOR ?= "^consent-scheme-gambit-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR ?= "^consent-scheme-gambit-native-host-test-r7rs-suite$$"
CONSENT_PORTABLE_RACKET_TEST_SELECTOR ?= "^consent-scheme-racket-host-test-r7rs-suite$$"
CONSENT_PORTABLE_COMPILED_TEST_SELECTOR ?= "^consent-scheme-compiled-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GUILE_TEST_SELECTOR ?= "^consent-scheme-guile-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GAUCHE_TEST_SELECTOR ?= "^consent-scheme-gauche-host-test-r7rs-suite$$"
CONSENT_EMACS_HOSTED_TEST_SELECTOR ?= (not "consent-scheme-.*")
CONSENT_EMACS_CORE_TEST_SELECTOR ?= (or "consent-base.*" "consent-eval.*" "consent-interpreter-module.*" "consent-macro.*" "consent-reader.*" "consent-result.*" "consent-runtime.*")
CONSENT_EMACS_LIBRARY_TEST_SELECTOR ?= (or "consent-conformance.*" "consent-fixture.*" "consent-host-adapter-fixture.*" "consent-library.*" "consent-oracle.*")
CONSENT_EMACS_CAPABILITY_TEST_SELECTOR ?= (or "consent-agent-io.*" "consent-approval.*" "consent-capability.*" "consent-context.*" "consent-helper.*" "consent-memory.*" "consent-models.*" "consent-network.*" "consent-plan.*" "consent-policy.*" "consent-redaction.*" "consent-session.*" "consent-task.*" "consent-test.*" "consent-transcript.*")
CONSENT_EMACS_TOOLS_TEST_SELECTOR ?= (or "consent-ci.*" "consent-compile.*" "consent-control-loop-doc.*" "consent-debugger.*" "consent-diagnostics.*" "consent-diff.*" "consent-docstring-metadata-doc.*" "consent-feature-reflection-doc.*" "consent-job.*" "consent-native-cli-daemon.*" "consent-reflect.*" "consent-repl.*" "consent-script.*" "consent-skill.*" "consent-smoke.*" "consent-vcs.*" "consent-scheme-documentation-test-.*" "consent-scheme-module-ownership-test-.*" "^consent-scheme-eval-test-bootstrap-avoids-host-call/cc$$" "^consent-scheme-module-boundary-test-runtime-version-loads-outside-repo$$")
CONSENT_PARITY_TEST_SELECTOR ?= "^consent-parity-test-.*"
CONSENT_LIVE_MODEL_CI_SELECTOR ?= consent-models-test-live-local-openai-compatible-completion
CONSENT_LIVE_MODEL_SELECTOR ?= "consent-models-test-live-local-.*"
CONSENT_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche
CONSENT_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-eval test-portable-rest
CONSENT_EMACS_TEST_SHARD_TARGETS ?= test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools
# Representative portable host kept in the trimmed default make test shard set.
# The reader/writer/docstring machinery exercised by the portable shards is
# host-independent, so one host is enough for the fast local loop; the full host
# matrix stays available through make test-full and the scheduled CI lane.
CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-racket
# Trimmed default: one representative portable host, the full Emacs shard set,
# and the cross-implementation parity gate (#374).
CONSENT_TEST_SHARD_TARGETS ?= $(CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS) $(CONSENT_EMACS_TEST_SHARD_TARGETS) test-parity
# Exhaustive opt-in set: every portable host shard, every Emacs shard, and the
# parity gate.
CONSENT_FULL_TEST_SHARD_TARGETS ?= $(CONSENT_PORTABLE_TEST_SHARD_TARGETS) $(CONSENT_EMACS_TEST_SHARD_TARGETS) test-parity
CONSENT_PORTABLE_TEST_JOBS ?= $(words $(CONSENT_PORTABLE_TEST_SHARD_TARGETS))
CONSENT_OPTIONAL_PORTABLE_TEST_JOBS ?= $(words $(CONSENT_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS))
CONSENT_EMACS_TEST_JOBS ?= $(words $(CONSENT_EMACS_TEST_SHARD_TARGETS))
CONSENT_TEST_JOBS ?= $(words $(CONSENT_TEST_SHARD_TARGETS))
CONSENT_FULL_TEST_JOBS ?= $(words $(CONSENT_FULL_TEST_SHARD_TARGETS))

.DEFAULT_GOAL := help

.PHONY: help clean clean-compile compile compile-elisp repl test test-full test-portable test-portable-chibi test-portable-eval test-portable-rest test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche test-emacs-hosted test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools test-parity test-live-model-ci test-live-model conformance-oracle

help:
	@printf '%s\n' 'Consent Scheme top-level actions:'
	@printf '  %-26s %s\n' 'help' 'Show this help.'
	@printf '  %-26s %s\n' 'clean' 'Remove generated Elisp bytecode.'
	@printf '  %-26s %s\n' 'clean-compile' 'Remove host-compiled portable executable outputs.'
	@printf '  %-26s %s\n' 'compile' 'Build host-compiled portable executable artifacts.'
	@printf '  %-26s %s\n' 'compile-elisp' 'Byte-compile checked-in Elisp sources.'
	@printf '  %-26s %s\n' 'repl' 'Start the portable terminal REPL shell (ARGS=... passes flags).'
	@printf '  %-26s %s\n' 'test' 'Run the trimmed default local shard set.'
	@printf '  %-26s %s\n' 'test-full' 'Run the exhaustive local shard set across every host and Emacs shard.'
	@printf '  %-26s %s\n' 'test-portable' 'Run the default portable R7RS host shards.'
	@printf '  %-26s %s\n' 'test-portable-chibi' 'Run the optional portable R7RS Chibi shards.'
	@printf '  %-26s %s\n' 'test-portable-eval' 'Run the optional portable R7RS Chibi evaluator subset shard.'
	@printf '  %-26s %s\n' 'test-portable-rest' 'Run the optional portable R7RS Chibi non-evaluator subset shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit' 'Run the portable R7RS Gambit full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit-native' 'Build and run the Gambit-native Consent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-racket' 'Run the portable R7RS Racket full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-compiled' 'Build and run the compiled Consent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-guile' 'Run the portable R7RS Guile full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gauche' 'Run the portable R7RS Gauche full-suite host shard.'
	@printf '  %-26s %s\n' 'test-emacs-hosted' 'Run all non-portable Emacs-hosted ERT tests.'
	@printf '  %-26s %s\n' 'test-emacs-core' 'Run the Emacs-hosted core language/runtime shard.'
	@printf '  %-26s %s\n' 'test-emacs-library' 'Run the Emacs-hosted library/conformance shard.'
	@printf '  %-26s %s\n' 'test-emacs-capabilities' 'Run the Emacs-hosted capability and policy shard.'
	@printf '  %-26s %s\n' 'test-emacs-tools' 'Run the Emacs-hosted tools, docs, and integration shard.'
	@printf '  %-26s %s\n' 'test-parity' 'Diff the Emacs and portable cores over the shared corpus (#374).'
	@printf '  %-26s %s\n' 'test-live-model-ci' 'Run the CI live local model smoke test.'
	@printf '  %-26s %s\n' 'test-live-model' 'Run all opt-in live local model tests.'
	@printf '  %-26s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-50s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-50s %s\n' 'CONSENT_COMPILE_HOST=racket|gambit' 'Host compiler path selected by make compile.'
	@printf '  %-50s %s\n' 'CONSENT_COMPILE_BUILD_DIR=build/compile' 'Output tree used by make compile.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_TARGET_ROOT=DIR' 'Optional portable Scheme implementation root for the current harness.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SOURCE_METADATA=on|off' 'Default source metadata mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_DOCSTRING_RETENTION=full|simple|none' 'Default docstring retention mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_JOBS=N' 'Parallel jobs used by make test.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SHARD_TARGETS=a b' 'Trimmed default shard targets run by make test.'
	@printf '  %-50s %s\n' 'CONSENT_FULL_TEST_SHARD_TARGETS=a b' 'Exhaustive shard targets run by make test-full.'
	@printf '  %-50s %s\n' 'CONSENT_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS=a b' 'Optional portable shard targets run by make test-portable-chibi.'
	@printf '  %-50s %s\n' 'CONSENT_OPTIONAL_PORTABLE_TEST_JOBS=N' 'Parallel jobs used by make test-portable-chibi.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_EVAL_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-eval.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_REST_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-rest.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_GAMBIT_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gambit.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gambit-native.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_RACKET_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-racket.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_COMPILED_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-compiled.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_GUILE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-guile.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_GAUCHE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-gauche.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_HOSTED_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-hosted.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_CORE_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-core.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_LIBRARY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-library.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_CAPABILITY_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-capabilities.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_TOOLS_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-tools.'
	@printf '  %-50s %s\n' 'CONSENT_PARITY_TEST_SELECTOR=SEL' 'ERT selector used by make test-parity.'
	@printf '  %-50s %s\n' 'CONSENT_PARITY_HOST=chibi|gauche|guile' 'Portable host that runs the parity emitter (auto-discovered when unset).'
	@printf '  %-50s %s\n' 'CONSENT_LIVE_MODEL_CI_SELECTOR=SEL' 'ERT selector used by make test-live-model-ci.'
	@printf '  %-50s %s\n' 'CONSENT_LIVE_MODEL_SELECTOR=SEL' 'ERT selector used by make test-live-model.'
	@printf '  %-50s %s\n' 'CONSENT_LIVE_MODEL_ENDPOINT=URL' 'OpenAI-compatible endpoint for live local model tests.'
	@printf '  %-50s %s\n' 'CONSENT_LIVE_MODEL_ID=ID' 'Model id used by the live local smoke test.'
	@printf '  %-50s %s\n' 'CONSENT_CHIBI=chibi-scheme' 'Optional Chibi Scheme command for Chibi portable checks and oracle runs.'
	@printf '  %-50s %s\n' 'CONSENT_GAUCHE=gosh' 'Optional Gauche command for oracle runs.'
	@printf '  %-50s %s\n' 'CONSENT_GUILE=guile' 'Optional Guile command for oracle runs.'
	@printf '  %-50s %s\n' 'CONSENT_SAGITTARIUS=sagittarius' 'Optional Sagittarius command for oracle runs.'
	@printf '  %-50s %s\n' 'CONSENT_RACKET=racket' 'Optional Racket command for oracle runs and compile packaging.'
	@printf '  %-50s %s\n' 'CONSENT_RACO=raco' 'Optional Racket raco command for compile packaging.'
	@printf '  %-50s %s\n' 'CONSENT_CHICKEN=csi' 'Optional CHICKEN command for oracle runs with the r7rs egg.'
	@printf '  %-50s %s\n' 'CONSENT_GAMBIT=gsi' 'Optional Gambit command for oracle runs and compile checks.'
	@printf '  %-50s %s\n' 'CONSENT_GAMBIT_COMPILER=gsc' 'Optional Gambit compiler command for compile checks.'
	@printf '  %-50s %s\n' 'CONSENT_GAMBIT_NATIVE=consent' 'Optional Gambit-native compiled runner for tests.'
	@printf '  %-50s %s\n' 'CONSENT_ORACLE_REFERENCES=a,b' 'Optional comma-separated oracle reference filter.'
	@printf '  %-50s %s\n' 'CONSENT_ORACLE_STATUSES=a,b' 'Optional comma-separated oracle report status filter.'
	@printf '  %-50s %s\n' 'CONSENT_ORACLE_SUMMARY=1' 'Print an oracle status summary before report lines.'

clean:
	find lisp -name '*.elc' -exec rm -f {} +

clean-compile:
	rm -rf '$(CONSENT_COMPILE_BUILD_DIR)'

compile:
	CONSENT_COMPILE_HOST='$(CONSENT_COMPILE_HOST)' \
	CONSENT_COMPILE_BUILD_DIR='$(CONSENT_COMPILE_BUILD_DIR)' \
	CONSENT_RACKET='$(CONSENT_RACKET)' \
	CONSENT_RACO='$(CONSENT_RACO)' \
	CONSENT_GAMBIT='$(CONSENT_GAMBIT)' \
	CONSENT_GAMBIT_COMPILER='$(CONSENT_GAMBIT_COMPILER)' \
	tools/compile-portable.sh

compile-elisp:
	$(EMACS) -Q --batch -L lisp --eval "(setq load-prefer-newer t)" -f batch-byte-compile $(CONSENT_ELISP_SOURCES)

# Start the portable terminal REPL shell outside Emacs (docs/portable-repl.md).
# Reads Consent Scheme forms from stdin, writes interaction-contract records to
# stderr, and keeps program output on stdout. Pass arguments through ARGS, e.g.
# make repl ARGS='--session demo'.
repl:
	@tools/consent-repl $(ARGS)

ifneq ($(strip $(CONSENT_TEST_SELECTOR)),)
test:
	$(CONSENT_TEST_RUNNER_COMMAND)
else
test:
	$(CONSENT_PARALLEL_MAKE) -j$(CONSENT_TEST_JOBS) $(CONSENT_TEST_SHARD_TARGETS)
endif

# Exhaustive escape hatch: run every portable host shard and every Emacs shard.
# Use before landing axis-sensitive reader/writer/docstring changes, and as the
# scheduled CI lane's local equivalent.
test-full:
	$(CONSENT_PARALLEL_MAKE) -j$(CONSENT_FULL_TEST_JOBS) $(CONSENT_FULL_TEST_SHARD_TARGETS)

ifneq ($(filter environment command line override,$(origin CONSENT_PORTABLE_TEST_SELECTOR)),)
test-portable:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)
else
test-portable:
	$(CONSENT_PARALLEL_MAKE) -j$(CONSENT_PORTABLE_TEST_JOBS) $(CONSENT_PORTABLE_TEST_SHARD_TARGETS)
endif

test-portable-chibi:
	$(CONSENT_PARALLEL_MAKE) -j$(CONSENT_OPTIONAL_PORTABLE_TEST_JOBS) $(CONSENT_OPTIONAL_PORTABLE_TEST_SHARD_TARGETS)

test-portable-eval:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_EVAL_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-rest:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_REST_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-gambit:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_GAMBIT_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-gambit-native:
	@if command -v '$(CONSENT_GAMBIT)' >/dev/null 2>&1 && command -v '$(CONSENT_GAMBIT_COMPILER)' >/dev/null 2>&1; then \
		CONSENT_COMPILE_HOST=gambit $(CONSENT_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Gambit compile prerequisites are not available; Gambit native host shard will skip if no runner exists.'; \
	fi
	@if [ -f '$(CONSENT_COMPILE_BUILD_DIR)/gambit/logs/compile.log' ]; then cat '$(CONSENT_COMPILE_BUILD_DIR)/gambit/logs/compile.log'; fi
	@if [ -f '$(CONSENT_COMPILE_BUILD_DIR)/gambit/logs/smoke.log' ]; then cat '$(CONSENT_COMPILE_BUILD_DIR)/gambit/logs/smoke.log'; fi
	CONSENT_GAMBIT_NATIVE='$(abspath $(CONSENT_COMPILE_BUILD_DIR)/gambit/bin/consent)' CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-racket:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_RACKET_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-compiled:
	@if command -v '$(CONSENT_RACKET)' >/dev/null 2>&1 && command -v '$(CONSENT_RACO)' >/dev/null 2>&1; then \
		CONSENT_COMPILE_HOST=racket $(CONSENT_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Racket compile prerequisites are not available; compiled host shard will skip if no runner exists.'; \
	fi
	CONSENT_COMPILED='$(abspath $(CONSENT_COMPILE_BUILD_DIR)/racket/bin/consent)' CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_COMPILED_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-guile:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_GUILE_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-gauche:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_GAUCHE_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

ifneq ($(filter environment command line override,$(origin CONSENT_EMACS_HOSTED_TEST_SELECTOR)),)
test-emacs-hosted:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_HOSTED_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)
else
test-emacs-hosted:
	$(CONSENT_PARALLEL_MAKE) -j$(CONSENT_EMACS_TEST_JOBS) $(CONSENT_EMACS_TEST_SHARD_TARGETS)
endif

test-emacs-core:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_CORE_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-emacs-library:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_LIBRARY_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-emacs-capabilities:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_CAPABILITY_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-emacs-tools:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_TOOLS_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

# Cross-implementation parity gate: run the shared fixture corpus through the
# Emacs-hosted and portable cores and fail on any result divergence (#374). The
# Emacs-hosted ERT bridge spawns the portable emitter under the host selected by
# CONSENT_PARITY_HOST (auto-discovered from chibi-scheme/gosh/guile when unset),
# and skips when no portable host is available.
test-parity:
	CONSENT_TEST_SELECTOR='$(CONSENT_PARITY_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-live-model-ci:
	CONSENT_LIVE_MODEL_TEST=1 CONSENT_TEST_SELECTOR='$(CONSENT_LIVE_MODEL_CI_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-live-model:
	CONSENT_LIVE_MODEL_TEST=1 CONSENT_LIVE_MODEL_MATRIX=1 CONSENT_TEST_SELECTOR='$(CONSENT_LIVE_MODEL_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

conformance-oracle:
	$(EMACS) -Q --batch -L lisp --eval "(require 'consent-oracle)" --eval "(consent-oracle-batch-main)"
