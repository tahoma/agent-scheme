EMACS ?= emacs
# Gambit is the default compile host: `gsc -exe -nopreload' produces a standalone
# native executable with no runtime dependency, so the default `make compile'
# artifact is the one suitable for `make install'. Racket remains available with
# CONSENT_COMPILE_HOST=racket (relocatable as a file, but it loads boot files from
# the installed Racket, so it only runs where Racket is present).
CONSENT_COMPILE_HOST ?= gambit
CONSENT_COMPILE_BUILD_DIR ?= build/compile
# GNU-standard installation variables (see the GNU Coding Standards). `make
# install` stages the host-compiled binary selected by CONSENT_COMPILE_HOST under
# $(DESTDIR)$(bindir); `make uninstall` removes exactly those paths. DESTDIR is
# the staging-root prefix used by packagers and the verification flow.
PREFIX ?= /usr/local
DESTDIR ?=
bindir ?= $(PREFIX)/bin
mandir ?= $(PREFIX)/share/man
datadir ?= $(PREFIX)/share
INSTALL ?= install
# Version-scoped install location for the runtime-provided Consent Scheme library
# tree (prelude, syntax prelude, and source-libraries). The host-compiled binary
# carries an embedded copy as a zero-dependency floor; installing the tree here
# lets it be inspected and overridden, and the binary baked with the matching
# datadir resolves it ahead of the embedded copy. Version-scoped so multiple
# installed runtimes do not collide.
consentlibdir = $(datadir)/consent/$(CONSENT_VERSION)
# Runtime library files (resolver-logical / datadir-relative paths; each lives at
# scheme/<path> in the source tree). Single-sourced from the runtime's own library
# declarations: `make compile' enumerates `consent-runtime-source-files' and writes
# the per-host manifest, which install/dist read here. Empty before a compile has
# run (install guards on the prebuilt binary first), so install/dist work only
# after `make compile' for the matching CONSENT_COMPILE_HOST.
CONSENT_RUNTIME_LIBRARY_FILES := $(shell cat '$(CONSENT_COMPILE_BUILD_DIR)/$(CONSENT_COMPILE_HOST)/runtime-source-manifest' 2>/dev/null)
# The host-compiled binary `make install`/`make dist` operate on, the optional
# generated man page (#458 owns its content; install/dist degrade gracefully
# without it), and the versioned distribution output tree.
CONSENT_VERSION_FILE ?= scheme/consent/version.sld
CONSENT_VERSION := $(shell awk 'match($$0, /\(consent-version [0-9]+ [0-9]+ [0-9]+\)/) { text = substr($$0, RSTART + 1, RLENGTH - 2); split(text, parts, " "); print parts[2] "." parts[3] "." parts[4]; exit }' $(CONSENT_VERSION_FILE))
CONSENT_COMPILE_BINARY = $(CONSENT_COMPILE_BUILD_DIR)/$(CONSENT_COMPILE_HOST)/bin/consent
CONSENT_COMPILE_MANIFEST = $(CONSENT_COMPILE_BUILD_DIR)/$(CONSENT_COMPILE_HOST)/manifest.scm
CONSENT_MANPAGE ?= docs/consent.1
CONSENT_DIST_DIR ?= $(CONSENT_COMPILE_BUILD_DIR)/dist
CONSENT_DIST_NAME = consent-$(CONSENT_VERSION)-$(CONSENT_COMPILE_HOST)
CONSENT_LINT_BUILD_DIR ?= build/lint
CONSENT_PORTABLE_LINT_BUILD_DIR ?= build/lint-portable
CONSENT_GUILE ?= guile
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
CONSENT_PORTABLE_GAMBIT_TEST_SELECTOR ?= "^consent-scheme-gambit-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GAMBIT_NATIVE_TEST_SELECTOR ?= "^consent-scheme-gambit-native-host-test-r7rs-suite$$"
CONSENT_PORTABLE_RACKET_TEST_SELECTOR ?= "^consent-scheme-racket-host-test-r7rs-suite$$"
CONSENT_PORTABLE_COMPILED_TEST_SELECTOR ?= "^consent-scheme-compiled-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GUILE_TEST_SELECTOR ?= "^consent-scheme-guile-host-test-r7rs-suite$$"
CONSENT_PORTABLE_GAUCHE_TEST_SELECTOR ?= "^consent-scheme-gauche-host-test-r7rs-suite$$"
CONSENT_PORTABLE_CHIBI_TEST_SELECTOR ?= "^consent-scheme-chibi-host-test-r7rs-suite$$"
CONSENT_EMACS_HOSTED_TEST_SELECTOR ?= (not "consent-scheme-.*")
CONSENT_EMACS_CORE_TEST_SELECTOR ?= (or "consent-base.*" "consent-eval.*" "consent-interpreter-module.*" "consent-macro.*" "consent-reader.*" "consent-result.*" "consent-runtime.*")
CONSENT_EMACS_LIBRARY_TEST_SELECTOR ?= (or "consent-conformance.*" "consent-fixture.*" "consent-host-adapter-fixture.*" "consent-library.*" "consent-oracle.*")
CONSENT_EMACS_CAPABILITY_TEST_SELECTOR ?= (or "consent-agent-io.*" "consent-agent-registry.*" "consent-approval.*" "consent-capability.*" "consent-context.*" "consent-helper.*" "consent-memory.*" "consent-models.*" "consent-network.*" "consent-plan.*" "consent-policy.*" "consent-redaction.*" "consent-session.*" "consent-task.*" "consent-test.*" "consent-transcript.*")
# The tools shard keeps the lighter Emacs-hosted tools/docs surface (CI, compile,
# diagnostics, doc-pass tests, ...) after #556 split the heavier integration
# surface (REPL, VCS, reflect, native-CLI daemon) into `test-emacs-integration'
# and stranded the four full-native-build tests into `test-emacs-native-build'.
# The trailing `(not ...)' clause keeps the native-build tests out of the trimmed
# `make test' default even though `consent-compile.*' is the broader pattern this
# selector uses; the dedicated build shard runs them in `make test-full' and the
# exhaustive CI lane.
CONSENT_EMACS_TOOLS_TEST_SELECTOR ?= (and (or "consent-ci.*" "consent-compile.*" "consent-control-loop-doc.*" "consent-debugger.*" "consent-diagnostics.*" "consent-diff.*" "consent-docstring-metadata-doc.*" "consent-feature-reflection-doc.*" "consent-job.*" "consent-script.*" "consent-skill.*" "consent-smoke.*" "consent-scheme-documentation-test-.*" "consent-scheme-module-ownership-test-.*" "^consent-scheme-eval-test-bootstrap-avoids-host-call/cc$$" "^consent-scheme-module-boundary-test-runtime-version-loads-outside-repo$$") (not "^consent-compile-portable-test-\\(racket\\|gambit\\)-\\(builds-runner\\|install-and-dist\\)$$"))
# The integration shard takes the heavyweight Emacs-hosted runtime surfaces
# split out of `test-emacs-tools' by #556 -- REPL, VCS, reflect, and the
# native-CLI daemon -- so they overlap with the other Emacs shards rather than
# stretching one shard's wall time past the rest of the trimmed default.
CONSENT_EMACS_INTEGRATION_TEST_SELECTOR ?= (or "consent-native-cli-daemon.*" "consent-reflect.*" "consent-repl.*" "consent-vcs.*")
# The native-build shard isolates the four full host-compile + install/dist
# tests (gambit/racket builds-runner and install-and-dist) so they only run in
# the exhaustive `make test-full' loop. The native build path is already
# exercised separately by `test-portable-gambit-native' and
# `test-portable-compiled'; these ERT cases additionally cover the install/dist
# packaging surface, which belongs in the exhaustive set rather than the trimmed
# inner loop (#556). Tests in `consent-compile-portable-test.el' that do not
# shell out to gsc/raco (rejects-unknown-host, *-missing-tools-fail,
# install-without-binary-fails) stay in `test-emacs-tools' since they are fast.
CONSENT_EMACS_NATIVE_BUILD_TEST_SELECTOR ?= "^consent-compile-portable-test-\\(racket\\|gambit\\)-\\(builds-runner\\|install-and-dist\\)$$"
CONSENT_PARITY_TEST_SELECTOR ?= "^consent-parity-test-.*"
CONSENT_LIVE_MODEL_CI_SELECTOR ?= consent-models-test-live-local-openai-compatible-completion
CONSENT_LIVE_MODEL_SELECTOR ?= "consent-models-test-live-local-.*"
CONSENT_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche
CONSENT_EMACS_TEST_SHARD_TARGETS ?= test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools test-emacs-integration
# Representative portable host kept in the trimmed default make test shard set.
# The reader/writer/docstring machinery exercised by the portable shards is
# host-independent, so one host is enough for the fast local loop; the full host
# matrix stays available through make test-full and the scheduled CI lane.
CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS ?= test-portable-racket
# Trimmed default: the Emacs byte-compile lint gate, the portable-host compiler
# warnings gate, one representative portable host, the full Emacs shard set, and
# the cross-implementation parity gate (#374). `test-emacs-native-build' is
# deliberately not here -- the four full host-compile + install/dist tests
# dominated the old single-shard tools target's wall time, so #556 stranded them
# in an opt-in shard that only runs in the exhaustive `make test-full' loop.
CONSENT_TEST_SHARD_TARGETS ?= lint-elisp lint-portable $(CONSENT_DEFAULT_PORTABLE_TEST_SHARD_TARGETS) $(CONSENT_EMACS_TEST_SHARD_TARGETS) test-parity
# Exhaustive opt-in set: the Emacs byte-compile lint gate, the portable-host
# compiler warnings gate, every portable host shard, every Emacs shard, the
# native-build install/dist shard isolated by #556, and the parity gate.
CONSENT_FULL_TEST_SHARD_TARGETS ?= lint-elisp lint-portable $(CONSENT_PORTABLE_TEST_SHARD_TARGETS) $(CONSENT_EMACS_TEST_SHARD_TARGETS) test-emacs-native-build test-parity
CONSENT_PORTABLE_TEST_JOBS ?= $(words $(CONSENT_PORTABLE_TEST_SHARD_TARGETS))
CONSENT_EMACS_TEST_JOBS ?= $(words $(CONSENT_EMACS_TEST_SHARD_TARGETS))
# Default `make test' parallelism (#556): raised from the shard-count fallback
# to 16 so the per-shard ERT processes can overlap on hosts with more
# performance cores than there are shards, instead of being bounded by the
# shard count alone. Override CONSENT_TEST_JOBS to tune for narrower hardware.
CONSENT_TEST_JOBS ?= 16
CONSENT_FULL_TEST_JOBS ?= 16

.DEFAULT_GOAL := help

.PHONY: help print-version clean clean-compile compile install uninstall dist compile-elisp lint-elisp lint-portable repl test test-full test-portable test-portable-chibi test-portable-gambit test-portable-gambit-native test-portable-racket test-portable-compiled test-portable-guile test-portable-gauche test-emacs-hosted test-emacs-core test-emacs-library test-emacs-capabilities test-emacs-tools test-emacs-integration test-emacs-native-build test-parity test-live-model-ci test-live-model conformance-oracle

help:
	@printf '%s\n' 'Consent Scheme top-level actions:'
	@printf '  %-26s %s\n' 'help' 'Show this help.'
	@printf '  %-26s %s\n' 'clean' 'Remove generated Elisp bytecode.'
	@printf '  %-26s %s\n' 'clean-compile' 'Remove host-compiled portable executable outputs.'
	@printf '  %-26s %s\n' 'compile' 'Build host-compiled portable executable artifacts.'
	@printf '  %-26s %s\n' 'install' 'Install the host-compiled binary (run make compile first).'
	@printf '  %-26s %s\n' 'uninstall' 'Remove an installed host-compiled binary and man page.'
	@printf '  %-26s %s\n' 'dist' 'Build a versioned distribution tarball of the compiled binary.'
	@printf '  %-26s %s\n' 'print-version' 'Print the canonical runtime version from version.sld.'
	@printf '  %-26s %s\n' 'compile-elisp' 'Byte-compile checked-in Elisp sources.'
	@printf '  %-26s %s\n' 'lint-elisp' 'Byte-compile Elisp sources with warnings-as-errors.'
	@printf '  %-26s %s\n' 'lint-portable' 'Compile portable libraries under Guile with warnings-as-errors.'
	@printf '  %-26s %s\n' 'repl' 'Start the portable terminal REPL shell (ARGS=... passes flags).'
	@printf '  %-26s %s\n' 'test' 'Run the trimmed default local shard set.'
	@printf '  %-26s %s\n' 'test-full' 'Run the exhaustive local shard set across every host and Emacs shard.'
	@printf '  %-26s %s\n' 'test-portable' 'Run the default portable R7RS host shards.'
	@printf '  %-26s %s\n' 'test-portable-chibi' 'Run the optional portable R7RS Chibi full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit' 'Run the portable R7RS Gambit full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gambit-native' 'Build and run the Gambit-compiled Consent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-racket' 'Run the portable R7RS Racket full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-compiled' 'Build and run the Racket-compiled Consent Scheme full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-guile' 'Run the portable R7RS Guile full-suite host shard.'
	@printf '  %-26s %s\n' 'test-portable-gauche' 'Run the portable R7RS Gauche full-suite host shard.'
	@printf '  %-26s %s\n' 'test-emacs-hosted' 'Run all non-portable Emacs-hosted ERT tests.'
	@printf '  %-26s %s\n' 'test-emacs-core' 'Run the Emacs-hosted core language/runtime shard.'
	@printf '  %-26s %s\n' 'test-emacs-library' 'Run the Emacs-hosted library/conformance shard.'
	@printf '  %-26s %s\n' 'test-emacs-capabilities' 'Run the Emacs-hosted capability and policy shard.'
	@printf '  %-26s %s\n' 'test-emacs-tools' 'Run the Emacs-hosted tools and docs shard.'
	@printf '  %-26s %s\n' 'test-emacs-integration' 'Run the Emacs-hosted REPL/VCS/reflect/native-CLI integration shard.'
	@printf '  %-26s %s\n' 'test-emacs-native-build' 'Run the Emacs-hosted full host-compile + install/dist shard (opt-in).'
	@printf '  %-26s %s\n' 'test-parity' 'Diff the Emacs and portable cores over the shared corpus (#374).'
	@printf '  %-26s %s\n' 'test-live-model-ci' 'Run the CI live local model smoke test.'
	@printf '  %-26s %s\n' 'test-live-model' 'Run all opt-in live local model tests.'
	@printf '  %-26s %s\n' 'conformance-oracle' 'Compare pure shared fixtures with reference R7RS implementations.'
	@printf '\n%s\n' 'Variables:'
	@printf '  %-50s %s\n' 'EMACS=emacs' 'Emacs command used by make test.'
	@printf '  %-50s %s\n' 'CONSENT_COMPILE_HOST=gambit|racket' 'Host compiler selected by make compile (default gambit: standalone binary).'
	@printf '  %-50s %s\n' 'CONSENT_COMPILE_BUILD_DIR=build/compile' 'Output tree used by make compile.'
	@printf '  %-50s %s\n' 'PREFIX=/usr/local' 'Install prefix for make install/uninstall.'
	@printf '  %-50s %s\n' 'DESTDIR=' 'Staging root prepended to install/uninstall paths.'
	@printf '  %-50s %s\n' 'bindir=$$(PREFIX)/bin' 'Directory make install writes the consent binary to.'
	@printf '  %-50s %s\n' 'mandir=$$(PREFIX)/share/man' 'Directory make install writes the man page to.'
	@printf '  %-50s %s\n' 'datadir=$$(PREFIX)/share' 'Base dir for the installed runtime library tree.'
	@printf '  %-50s %s\n' 'INSTALL=install' 'install(1) command used by make install/dist.'
	@printf '  %-50s %s\n' 'CONSENT_MANPAGE=docs/consent.1' 'Optional man page installed/packaged when present.'
	@printf '  %-50s %s\n' 'CONSENT_DIST_DIR=build/compile/dist' 'Output tree used by make dist.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_TARGET_ROOT=DIR' 'Optional portable Scheme implementation root for the current harness.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SOURCE_METADATA=on|off' 'Default source metadata mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_DOCSTRING_RETENTION=full|simple|none' 'Default docstring retention mode injected by CI matrix shards.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_JOBS=N' 'Parallel jobs used by make test.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SHARD_TARGETS=a b' 'Trimmed default shard targets run by make test.'
	@printf '  %-50s %s\n' 'CONSENT_FULL_TEST_SHARD_TARGETS=a b' 'Exhaustive shard targets run by make test-full.'
	@printf '  %-50s %s\n' 'CONSENT_TEST_SELECTOR=SEL' 'Optional ERT selector for make test.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable.'
	@printf '  %-50s %s\n' 'CONSENT_PORTABLE_CHIBI_TEST_SELECTOR=SEL' 'ERT selector used by make test-portable-chibi.'
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
	@printf '  %-50s %s\n' 'CONSENT_EMACS_INTEGRATION_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-integration.'
	@printf '  %-50s %s\n' 'CONSENT_EMACS_NATIVE_BUILD_TEST_SELECTOR=SEL' 'ERT selector used by make test-emacs-native-build.'
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

# Print the canonical runtime version (the dotted form derived from
# version.sld). Used by the release workflow to cross-check the release tag.
print-version:
	@printf '%s\n' '$(CONSENT_VERSION)'

clean:
	find lisp -name '*.elc' -exec rm -f {} +

clean-compile:
	rm -rf '$(CONSENT_COMPILE_BUILD_DIR)'

compile:
	CONSENT_COMPILE_HOST='$(CONSENT_COMPILE_HOST)' \
	CONSENT_COMPILE_BUILD_DIR='$(CONSENT_COMPILE_BUILD_DIR)' \
	CONSENT_INSTALL_DATADIR='$(consentlibdir)' \
	CONSENT_RACKET='$(CONSENT_RACKET)' \
	CONSENT_RACO='$(CONSENT_RACO)' \
	CONSENT_GAMBIT='$(CONSENT_GAMBIT)' \
	CONSENT_GAMBIT_COMPILER='$(CONSENT_GAMBIT_COMPILER)' \
	tools/compile-portable.sh

# GNU-style install of the host-compiled binary selected by CONSENT_COMPILE_HOST.
# Install deliberately does not run `compile`: it is commonly run under `sudo`,
# where a build step would create root-owned artifacts in the source tree. The
# documented flow is `make compile && sudo make install`. The recipe guards on
# the prebuilt binary the same way test-portable-compiled does, stages it with
# `install`, installs the generated man page only when one exists (#458), and
# then runs the staged binary's --version to confirm it executes and matches
# version.sld — catching a non-executable staging path or a Racket binary
# installed where Racket is absent.
install:
	@if [ ! -x '$(CONSENT_COMPILE_BINARY)' ]; then \
		printf '%s\n' 'consent install: no compiled binary at $(CONSENT_COMPILE_BINARY).' >&2; \
		printf '%s\n' 'consent install: run `make compile` first (CONSENT_COMPILE_HOST=gambit for a standalone binary), then `sudo make install`.' >&2; \
		exit 2; \
	fi
	$(INSTALL) -d '$(DESTDIR)$(bindir)'
	$(INSTALL) -m 755 '$(CONSENT_COMPILE_BINARY)' '$(DESTDIR)$(bindir)/consent'
	@for relpath in $(CONSENT_RUNTIME_LIBRARY_FILES); do \
		$(INSTALL) -d "$(DESTDIR)$(consentlibdir)/$$(dirname "$$relpath")"; \
		$(INSTALL) -m 644 "scheme/$$relpath" "$(DESTDIR)$(consentlibdir)/$$relpath"; \
	done
	@printf '%s\n' 'consent install: installed runtime library tree to $(DESTDIR)$(consentlibdir)'
	@if [ -f '$(CONSENT_MANPAGE)' ]; then \
		$(INSTALL) -d '$(DESTDIR)$(mandir)/man1'; \
		$(INSTALL) -m 644 '$(CONSENT_MANPAGE)' '$(DESTDIR)$(mandir)/man1/consent.1'; \
		printf '%s\n' 'consent install: installed man page to $(DESTDIR)$(mandir)/man1/consent.1'; \
	else \
		printf '%s\n' 'consent install: no man page at $(CONSENT_MANPAGE); skipping (generated by #458).'; \
	fi
	@staged='$(DESTDIR)$(bindir)/consent'; \
	version_output=$$("$$staged" --version 2>/dev/null) \
		|| { printf '%s\n' "consent install: staged $$staged failed --version" >&2; exit 1; }; \
	if [ "$$version_output" != 'Consent Scheme $(CONSENT_VERSION)' ]; then \
		printf '%s\n' "consent install: staged --version returned '$$version_output', expected 'Consent Scheme $(CONSENT_VERSION)'" >&2; \
		exit 1; \
	fi; \
	printf '%s\n' "consent install: installed $$staged ($$version_output)"

# Remove exactly the paths `install` writes. Idempotent (`rm -f`); per GNU
# convention it does not rmdir shared directories such as $(bindir).
uninstall:
	rm -f '$(DESTDIR)$(bindir)/consent'
	rm -f '$(DESTDIR)$(mandir)/man1/consent.1'
	rm -rf '$(DESTDIR)$(consentlibdir)'

# Build a versioned distribution tarball of the host-compiled binary plus its
# manifest, README, license, and the man page when present. Named from
# version.sld and CONSENT_COMPILE_HOST under $(CONSENT_DIST_DIR). A standalone
# CONSENT_COMPILE_HOST=gambit binary is the relocatable artifact; a Racket
# tarball still requires Racket on the target (documented caveat).
dist:
	@if [ ! -x '$(CONSENT_COMPILE_BINARY)' ]; then \
		printf '%s\n' 'consent dist: no compiled binary at $(CONSENT_COMPILE_BINARY).' >&2; \
		printf '%s\n' 'consent dist: run `make compile` first.' >&2; \
		exit 2; \
	fi
	@stage='$(CONSENT_DIST_DIR)/$(CONSENT_DIST_NAME)'; \
	rm -rf "$$stage"; \
	$(INSTALL) -d "$$stage/bin"; \
	$(INSTALL) -m 755 '$(CONSENT_COMPILE_BINARY)' "$$stage/bin/consent"; \
	$(INSTALL) -m 644 '$(CONSENT_COMPILE_MANIFEST)' "$$stage/manifest.scm"; \
	$(INSTALL) -m 644 README.md "$$stage/README.md"; \
	$(INSTALL) -m 644 LICENSE "$$stage/LICENSE"; \
	for relpath in $(CONSENT_RUNTIME_LIBRARY_FILES); do \
		$(INSTALL) -d "$$stage/share/consent/$(CONSENT_VERSION)/$$(dirname "$$relpath")"; \
		$(INSTALL) -m 644 "scheme/$$relpath" "$$stage/share/consent/$(CONSENT_VERSION)/$$relpath"; \
	done; \
	if [ -f '$(CONSENT_MANPAGE)' ]; then \
		$(INSTALL) -d "$$stage/share/man/man1"; \
		$(INSTALL) -m 644 '$(CONSENT_MANPAGE)' "$$stage/share/man/man1/consent.1"; \
	fi; \
	tarball='$(CONSENT_DIST_DIR)/$(CONSENT_DIST_NAME).tar.gz'; \
	tar -czf "$$tarball" -C '$(CONSENT_DIST_DIR)' '$(CONSENT_DIST_NAME)'; \
	printf '%s\n' "consent dist: wrote $$tarball"

compile-elisp:
	$(EMACS) -Q --batch -L lisp --eval "(setq load-prefer-newer t)" -f batch-byte-compile $(CONSENT_ELISP_SOURCES)

# Quality gate: byte-compile every checked-in Elisp source with
# `byte-compile-error-on-warn' so any byte-compiler warning (unbound variables,
# arity mismatches, unused lexicals, obsolete calls) fails the build. Bytecode
# is redirected into a throwaway build directory so the gate leaves no stale
# `.elc' beside the sources and never races the parallel test shards that load
# the `.el' files directly.
#
# The docstring-width sub-check is disabled (`byte-compile-docstring-max-column'
# unbounded) so the gate is deterministic across Emacs versions. `cl-defstruct'
# auto-generates a constructor docstring with a `(fn &key SLOT...)' line whose
# width scales with the slot count; Emacs 30 excludes that machine-generated
# line from the width check while Emacs 29 does not, so a wide struct (notably
# the `consent--eval-context' god-object tracked by #371) would fail the gate on
# one Emacs but not another. Docstring style and width are owned by the separate
# checkdoc slice, not this gate; this target enforces the semantic warning
# classes the issue motivates.
lint-elisp:
	@rm -rf '$(CONSENT_LINT_BUILD_DIR)'
	@mkdir -p '$(CONSENT_LINT_BUILD_DIR)'
	$(EMACS) -Q --batch -L lisp \
		--eval "(setq load-prefer-newer t)" \
		--eval "(setq byte-compile-error-on-warn t)" \
		--eval "(setq byte-compile-docstring-max-column most-positive-fixnum)" \
		--eval "(setq byte-compile-dest-file-function (lambda (source) (expand-file-name (concat (file-name-nondirectory source) \"c\") \"$(CONSENT_LINT_BUILD_DIR)\")))" \
		-f batch-byte-compile $(CONSENT_ELISP_SOURCES)
	@rm -rf '$(CONSENT_LINT_BUILD_DIR)'

# Portable twin of lint-elisp (#421): compile the host-loadable portable Consent
# Scheme libraries under Guile with the high-signal static warning classes
# (unbound variable, arity mismatch, use-before-definition, unused lexical,
# format/case-datum) promoted to errors. Guile is the gate host because, among
# the portable hosts already in CI, it is the only one with a usable `-W`
# warning facility; see tools/lint-portable.sh and docs/development.md. Skips
# (does not fail) when Guile is unavailable, matching the portable host shards.
lint-portable:
	CONSENT_GUILE='$(CONSENT_GUILE)' \
	CONSENT_PORTABLE_LINT_BUILD_DIR='$(CONSENT_PORTABLE_LINT_BUILD_DIR)' \
	tools/lint-portable.sh

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
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_CHIBI_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-gambit:
	CONSENT_TEST_SELECTOR='$(CONSENT_PORTABLE_GAMBIT_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

test-portable-gambit-native:
	@if command -v '$(CONSENT_GAMBIT)' >/dev/null 2>&1 && command -v '$(CONSENT_GAMBIT_COMPILER)' >/dev/null 2>&1; then \
		CONSENT_COMPILE_HOST=gambit $(CONSENT_PARALLEL_MAKE) compile; \
	else \
		printf '%s\n' 'Gambit compile prerequisites are not available; Gambit-compiled host shard will skip if no runner exists.'; \
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

test-emacs-integration:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_INTEGRATION_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

# Opt-in native-build shard (#556): the four full host-compile + install/dist
# tests that dominated the old tools-shard wall time. Not part of the trimmed
# `make test' default; included in `make test-full' and the exhaustive CI lane
# so the install/dist packaging surface remains covered.
test-emacs-native-build:
	CONSENT_TEST_SELECTOR='$(CONSENT_EMACS_NATIVE_BUILD_TEST_SELECTOR)' $(CONSENT_TEST_RUNNER_COMMAND)

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
