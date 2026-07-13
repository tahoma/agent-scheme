;;; Portable Consent Scheme test-program and shard plan.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;; This is project test data, not a runtime library.  `(testing plan)` owns
;; validation and selection; the host launcher owns only process invocation.

(testing-plan
 (version 1)
 (programs
  ((program
    (path "tests/scheme/consent-reader-test.scm")
    (tags (full direct compiled core)))
   (program
   (path "tests/scheme/consent-fixture-test.scm")
    (tags (full direct conformance self-host-gap)))
   (program
   (path "tests/scheme/consent-native-cli-daemon-adapter-test.scm")
    (tags (full direct compiled integration)))
   (program
   (path "tests/scheme/consent-native-cli-daemon-process-test.scm")
    (tags (full direct integration self-host-gap)))
   (program
   (path "tests/scheme/consent-module-boundary-test.scm")
    (tags (full direct core self-host-gap)))
   (program
   (path "tests/scheme/consent-transcript-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-repl-test.scm")
    (tags (full direct repl self-host-gap)))
   (program
   (path "tests/scheme/consent-repl-parity-test.scm")
    (tags (full direct repl parity self-host-gap)))
   (program
   (path "tests/scheme/consent-session-test.scm")
    (tags (full direct agent self-host-gap)))
   (program
   (path "tests/scheme/consent-session-store-test.scm")
    (tags (full direct compiled agent registered)))
   (program
   (path "tests/scheme/consent-context-test.scm")
    (tags (full direct compiled agent registered)))
   (program
   (path "tests/scheme/consent-diagnostics-test.scm")
    (tags (full direct agent registered self-host-gap)))
   (program
   (path "tests/scheme/consent-diff-test.scm")
    (tags (full direct agent registered self-host-gap)))
   (program
   (path "tests/scheme/consent-network-test.scm")
    (tags (full direct compiled agent registered)))
   (program
   (path "tests/scheme/testing-harness-test.scm")
    (tags (full direct testing self-host-gap)))
   (program
   (path "tests/scheme/testing-registry-test.scm")
    (tags (full direct compiled testing)))
   (program
   (path "tests/scheme/testing-runner-test.scm")
    (tags (full direct compiled testing)))
   (program
   (path "tests/scheme/testing-plan-test.scm")
    (tags (full direct compiled testing)))
   (program
   (path "tests/scheme/consent-plan-test.scm")
    (tags (full direct compiled agent registered)))
   (program
   (path "tests/scheme/consent-redaction-test.scm")
    (tags (full direct agent registered self-host-gap)))
   (program
   (path "tests/scheme/consent-task-test.scm")
    (tags (full direct agent registered self-host-gap)))
   (program
   (path "tests/scheme/consent-vcs-test.scm")
    (tags (full direct compiled agent registered)))
   (program
   (path "tests/scheme/consent-agent-memory-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-registry-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-proposal-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-runner-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-reliability-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-prompt-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-agent-generated-source-test.scm")
    (tags (full direct compiled agent)))
   (program
   (path "tests/scheme/consent-models-openai-test.scm")
    (tags (full direct compiled agent models)))
   (program
   (path "tests/scheme/consent-script-test.scm")
    (tags (full direct integration self-host-gap)))
   (program
   (path "tests/scheme/stdlib-list-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-comparator-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-rbtree-test.scm")
    (tags (full direct compiled stdlib slow)))
   (program
   (path "tests/scheme/stdlib-mapping-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-and-let-star-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-receive-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-assume-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/stdlib-testing-test.scm")
    (tags (full direct compiled stdlib testing)))
   (program
   (path "tests/scheme/stdlib-testing-upstream-test.scm")
    (tags (full direct compiled stdlib testing upstream)))
   (program
   (path "tests/scheme/stdlib-random-bits-test.scm")
    (tags (full direct compiled stdlib random)))
   (program
   (path "tests/scheme/stdlib-random-bits-upstream-test.scm")
    (tags (full direct compiled stdlib random upstream)))
   (program
   (path "tests/scheme/stdlib-random-distributions-test.scm")
    (tags (full direct compiled stdlib random)))
   (program
   (path "tests/scheme/stdlib-random-data-generators-test.scm")
    (tags (full direct compiled stdlib random)))
   (program
   (path "tests/scheme/stdlib-random-data-generators-upstream-test.scm")
    (tags (full direct compiled stdlib random upstream slow)))
   (program
   (path "tests/scheme/stdlib-property-testing-test.scm")
    (tags (full direct compiled stdlib testing)))
   (program
   (path "tests/scheme/stdlib-property-testing-upstream-test.scm")
    (tags (full direct compiled stdlib testing upstream)))
   (program
   (path "tests/scheme/stdlib-eager-comprehensions-test.scm")
    (tags (full direct stdlib self-host-gap)))
   (program
   (path "tests/scheme/stdlib-eager-comprehensions-upstream-test.scm")
    (tags (full direct stdlib upstream self-host-gap)))
   (program
   (path "tests/scheme/stdlib-lightweight-testing-test.scm")
    (tags (full direct stdlib testing self-host-gap)))
   (program
   (path "tests/scheme/stdlib-lightweight-testing-upstream-test.scm")
    (tags (full direct stdlib testing upstream self-host-gap)))
   (program
    (path "tests/scheme/stdlib-json-reference-test.scm")
    (tags (full direct compiled stdlib reference stress slow)))
   (program
   (path "tests/scheme/stdlib-generator-test.scm")
    (tags (full direct compiled stdlib)))
   (program
   (path "tests/scheme/consent-eval-test.scm")
    (tags (full direct core evaluator slow self-host-gap)))
   (program
   (path "tests/scheme/stdlib-mapping-conformance-test.scm")
    (tags (full direct stdlib conformance slow self-host-gap)))
   (program
    (path "tests/scheme/consent-manifest-smoke-test.scm")
    (tags (compiled smoke)))
   (program
    (path "tests/scheme/consent-reflect-test.scm")
    (tags (reflect reflection)))
   (program
    (path "tests/scheme/consent-reflect-stress-test.scm")
    (tags (reflect-stress reflection stress slow)))
   (program
    (path "tests/scheme/consent-models-live-test.scm")
    (tags (live-direct agent models integration)))
   (program
    (path "tests/scheme/consent-models-compiled-live-test.scm")
    (tags (live-compiled agent models integration self-hosted)))))
 (shards
  ((shard (name full) (selector (tag full)))
   (shard
    (name full-evaluator)
    (selector (and (tag full) (tag evaluator))))
   (shard
    (name full-support)
    (selector (and (tag full) (not (tag evaluator)))))
   (shard (name compiled) (selector (tag compiled)))
   (shard (name reflect) (selector (tag reflect)))
   (shard (name reflect-stress) (selector (tag reflect-stress)))
   (shard (name live-direct) (selector (tag live-direct)))
   (shard (name live-compiled) (selector (tag live-compiled))))))
