;;; consent-agent-registry-test.el --- Agent abstraction and registry tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent registry)' contract evaluated
;; through the Emacs Consent interpreter.  The same Scheme source backs the
;; portable host shards (tests/scheme/consent-agent-registry-test.scm), so these
;; expectations are the Emacs half of the cross-host parity check for the agent
;; datum, the registry surface, and deterministic automatic selection.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-result)

(defun consent-agent-registry-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source)))

(ert-deftest consent-agent-registry-test-agent-datum-and-accessors ()
  "Compose an agent datum and read every field through its accessors."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define agent
        (make-agent 'coder-1
                    '((name \"Coder One\")
                      (role coder)
                      (model portable-coder)
                      (rules (no-secrets))
                      (skills (edit-file))
                      (budget (budget (max-steps 8)))
                      (description \"Writes code.\"))))
      (list (agent? agent)
            (agent-id agent)
            (agent-name agent)
            (agent-role agent)
            (agent-model agent)
            (agent-rules agent)
            (agent-skills agent)
            (agent-budget agent)
            (agent-description agent)
            (agent-field-value agent 'role)
            (agent-field-value agent 'missing 'fallback))")
    "(#t coder-1 \"Coder One\" coder portable-coder (no-secrets) (edit-file) (budget (max-steps 8)) \"Writes code.\" coder fallback)")))

(ert-deftest consent-agent-registry-test-agent-defaults ()
  "Minimal construction fills the documented agent field defaults."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define agent (make-agent 'minimal '()))
      (list (agent-name agent)
            (agent-role agent)
            (agent-model agent)
            (agent-rules agent)
            (agent-skills agent)
            (agent-budget agent)
            (agent-description agent))")
    "(\"minimal\" planner auto () () default \"\")")))

(ert-deftest consent-agent-registry-test-registry-surface ()
  "Seed, register, list in registration order, and reference agents."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'rev '((role reviewer))))
      (register-agent registry (make-agent 'cod '((role coder))))
      (list (agent-registry? registry)
            (default-agent-id registry)
            (agent-role (default-agent registry))
            (map agent-id (agents registry))
            (agent-id (agent-ref registry 'cod))
            (agent-ref registry 'absent))")
    "(#t default planner (default rev cod) cod #f)")))

(ert-deftest consent-agent-registry-test-register-replaces-by-id ()
  "Re-registering an id replaces the agent in place without duplicating it."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder))))
      (register-agent registry (make-agent 'cod '((role summarizer))))
      (list (length (agents registry))
            (agent-role (agent-ref registry 'cod)))")
    "(2 summarizer)")))

(ert-deftest consent-agent-registry-test-set-default-agent ()
  "Setting the default agent updates and returns the chosen agent."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'p2 '((role planner))))
      (define returned (set-default-agent! registry 'p2))
      (list (agent-id returned)
            (default-agent-id registry)
            (agent-id (default-agent registry)))")
    "(p2 p2 p2)")))

(ert-deftest consent-agent-registry-test-mutating-verbs-fail-on-unknown ()
  "Registering a non-agent or defaulting an unknown id raises an error."
  (should-error
   (consent-eval-source
    "(import (scheme base) (agent registry))
     (register-agent (make-agent-registry) '(not-an-agent))"))
  (should-error
   (consent-eval-source
    "(import (scheme base) (agent registry))
     (set-default-agent! (make-agent-registry) 'ghost)")))

(ert-deftest consent-agent-registry-test-automatic-selection-default ()
  "With no configuration, automatic selection resolves to the default agent."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder))))
      (define selection (select-agent registry '()))
      (list (agent-selection? selection)
            (agent-selection-status selection)
            (agent-selection-basis selection)
            (agent-selection-agent-id selection)
            (agent-id (agent-selection-agent selection))
            (agent-selection-considered selection))")
    "(#t selected default-agent default default (default cod))")))

(ert-deftest consent-agent-registry-test-selection-bases ()
  "Role, fallback, explicit, and explicit-miss selection bases are stable."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder))))
      (register-agent registry (make-agent 'rev '((role reviewer))))
      (list (agent-selection-basis
             (select-agent registry '((role reviewer))))
            (agent-selection-basis
             (select-agent registry '((role nomatch))))
            (agent-selection-basis
             (select-agent registry '((agent cod) (role reviewer))))
            (agent-selection-agent-id
             (select-agent registry '((agent cod))))
            (agent-selection-basis
             (select-agent registry '((agent ghost) (role coder)))))")
    "(role-match default-agent explicit-agent cod role-match)")))

(ert-deftest consent-agent-registry-test-selection-model-match ()
  "A requested model selects the first matching agent, then falls back."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder) (model m1))))
      (list (agent-selection-basis
             (select-agent registry '((model m1))))
            (agent-selection-agent-id
             (select-agent registry '((model m1))))
            (agent-selection-basis
             (select-agent registry '((model nomatch)))))")
    "(model-match cod default-agent)")))

(ert-deftest consent-agent-registry-test-selection-records-context ()
  "Selection records the requested role, model, goal, and session."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder))))
      (define selection
        (select-agent registry
                      '((role coder)
                        (model portable-coder)
                        (goal the-goal)
                        (session named-1))))
      (list (agent-selection-field-value selection 'requested-role)
            (agent-selection-field-value selection 'requested-model)
            (agent-selection-field-value selection 'goal)
            (agent-selection-field-value selection 'session))")
    "(coder portable-coder the-goal named-1)")))

(ert-deftest consent-agent-registry-test-selection-is-deterministic ()
  "Identical selection inputs produce equal, replayable decision records."
  (should
   (equal
    (consent-agent-registry-test--external
     "(import (scheme base) (agent registry))
      (define registry (make-agent-registry))
      (register-agent registry (make-agent 'cod '((role coder))))
      (equal? (select-agent registry '((role coder)))
              (select-agent registry '((role coder))))")
    "#t")))

(provide 'consent-agent-registry-test)
;;; consent-agent-registry-test.el ends here
