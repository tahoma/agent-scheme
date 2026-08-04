;;; consent-budget-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Tests for the comprehensive evaluation-budget surface from #51: the single
;; inspectable budget ledger and its explicit exhaustion reason ("stop
;; receipt"), the new output-byte and wall-time dimensions, and the
;; `current-budget' / `budget-remaining' / `budget-exhausted?' / `budget-yield'
;; / `with-budget' procedures.  The portable twin lives in
;; tests/scheme/consent-budget-test.scm; both cores must agree.

;;; Code:

(require 'ert)
(require 'consent-eval)
(require 'consent-test-options)

(defun consent-budget-test--expected-max-source-metadata ()
  "Return the max source metadata ceiling expected for this test run."
  (or (plist-get
       (consent-test-options-default-plist)
       :max-source-metadata)
      consent-eval-maximum-source-metadata))

(defun consent-budget-test--result (source &optional options)
  "Evaluate SOURCE under OPTIONS and return its rendered result record."
  (consent-result->external
   (consent-eval-source-result source nil options)))

(defun consent-budget-test--value (source &optional options)
  "Evaluate SOURCE under OPTIONS and return its rendered value."
  (consent-value->external
   (consent-eval-source source nil options)))

(ert-deftest consent-budget-test-ledger-shape ()
  "`current-budget' reports every enforced and reserved dimension and reason."
  (let ((text (consent-budget-test--result
               "(import (scheme base) (agent reflect)) (current-budget)")))
    (dolist (needle (list "(steps-used " "(max-steps 100000)"
                          "(host-calls " "(max-host-calls 10000)"
                          "(events-used " "(max-events 1000)"
                          "(max-event-nodes 100000)"
                          "(value-nodes-used " "(max-value-nodes 10000000)"
                          "(source-metadata-used "
                          (format "(max-source-metadata %s)"
;; readability-allow: external-identifier -- Existing helper stays intact.
                                  (consent-budget-test--expected-max-source-metadata))
                          "(interned-symbols-used "
                          "(max-interned-symbols 1000000)"
                          "(output-bytes-used " "(max-output-bytes 10485760)"
                          "(max-wall-time-ms #f)" "(reason #f)"))
      (should (string-match-p (regexp-quote needle) text)))))

(ert-deftest consent-budget-test-step-exhaustion-names-dimension ()
  "Step exhaustion halts with a budget-exhausted stop receipt naming `steps'."
  (let ((text (consent-budget-test--result
               "(import (scheme base)) (let loop ((i 0)) (loop (+ i 1)))"
               '(:max-steps 200))))
    (should (string-match-p (regexp-quote "(type budget-exhausted)") text))
    (should (string-match-p (regexp-quote "(reason steps)") text))))

(ert-deftest consent-budget-test-tail-loop-bounded-by-steps ()
  "A tail-recursive loop consumes the step budget without growing host stack.
Reaching a stop receipt at all proves the trampoline stayed iterative."
  (let ((text (consent-budget-test--result
               "(import (scheme base)) (let loop () (loop))"
               '(:max-steps 5000))))
    (should (string-match-p (regexp-quote "(type budget-exhausted)") text))))

(ert-deftest consent-budget-test-interned-symbol-flood-names-dimension ()
  "A `string->symbol' flood halts on the `interned-symbols' dimension.
The flood interns unbounded distinct symbols; with a generous step budget the
interned-symbol budget -- not the step budget -- is the binding constraint, so
the stop receipt names `interned-symbols'."
  (let ((text (consent-budget-test--result
               (concat "(import (scheme base))"
                       " (let loop ((i 0))"
                       "   (string->symbol (number->string i))"
                       "   (loop (+ i 1)))")
               '(:max-interned-symbols 100 :max-steps 1000000))))
    (should (string-match-p (regexp-quote "(type budget-exhausted)") text))
    (should (string-match-p (regexp-quote "(reason interned-symbols)") text))))

(ert-deftest consent-budget-test-host-callback-exhaustion-names-dimension ()
  "Host-callback exhaustion names the `host-callbacks' dimension."
  (let ((text (consent-budget-test--result
               "(import (scheme base)) (let loop ((i 0)) (loop (+ i 1)))"
               '(:max-host-callbacks 10))))
    (should (string-match-p (regexp-quote "(reason host-callbacks)") text))))

(ert-deftest consent-budget-test-output-exhaustion-names-dimension ()
  "Printed-output exhaustion names the `output-bytes' dimension."
  (let ((text (consent-budget-test--result
               (concat "(import (scheme base) (scheme write))"
                       " (let ((port (open-output-string)))"
                       "   (let loop ((i 0))"
                       "     (write-string \"xxxxx\" port) (loop (+ i 1))))")
               '(:max-output-bytes 32))))
    (should (string-match-p (regexp-quote "(reason output-bytes)") text))))

(ert-deftest consent-budget-test-yield-exhaustion-names-dimension ()
  "Yielded-event exhaustion names the `events' dimension."
  (let ((text (consent-budget-test--result
               (concat "(import (scheme base) (agent io))"
                       " (let loop ((i 0)) (agent-yield i) (loop (+ i 1)))")
               '(:max-events 4))))
    (should (string-match-p (regexp-quote "(reason events)") text))))

(ert-deftest consent-budget-test-wall-time-exhaustion-with-stub-clock ()
  "Wall-time exhaustion uses an injected deterministic clock and names it.
The stub advances 100 milliseconds per reading."
  (let* ((tick 0)
         (clock (lambda () (setq tick (+ tick 100)) tick))
         (text (consent-budget-test--result
                "(import (scheme base)) (let loop ((i 0)) (loop (+ i 1)))"
                (list :max-wall-time-ms 250 :wall-clock clock))))
    (should (string-match-p (regexp-quote "(reason wall-time)") text))))

(ert-deftest consent-budget-test-with-budget-tightens-and-restores ()
  "`with-budget' tightens the active budget then restores the outer ceiling."
  ;; The tightened body halts on the step budget.
  (should
   (string-match-p
    (regexp-quote "(reason steps)")
    (consent-budget-test--result
     (concat "(import (scheme base) (agent reflect))"
             " (with-budget '(budget (steps 50))"
             "   (let loop ((i 0)) (loop (+ i 1))))"))))
  ;; After a normally completing with-budget the outer ceiling is restored.
  (should
   (string-match-p
    (regexp-quote "(max-steps 100000)")
    (consent-budget-test--result
     (concat "(import (scheme base) (agent reflect))"
             " (with-budget '(budget (steps 50)) (+ 1 2))"
             " (current-budget)")))))

(ert-deftest consent-budget-test-budget-remaining-reports-headroom ()
  "`budget-remaining' reports headroom per enforced dimension and reason."
  (let ((text (consent-budget-test--result
               "(import (scheme base) (agent reflect)) (budget-remaining)"
               '(:max-steps 1000))))
    (should (string-match-p (regexp-quote "(budget-remaining ") text))
    (should (string-match-p (regexp-quote "(steps ") text))
    (should (string-match-p (regexp-quote "(source-metadata ") text))
    (should (string-match-p (regexp-quote "(interned-symbols ") text))
    (should (string-match-p (regexp-quote "(output-bytes ") text))
    (should (string-match-p (regexp-quote "(reason #f)") text))))

(ert-deftest consent-budget-test-budget-exhausted-predicate ()
  "`budget-exhausted?' classifies condition and evaluation-result datums."
  (should
   (equal "#t"
          (consent-budget-test--value
           (concat "(import (scheme base) (agent reflect))"
                   " (budget-exhausted? '(condition (type\
 budget-exhausted)))"))))
  (should
   (equal "#f"
          (consent-budget-test--value
           (concat "(import (scheme base) (agent reflect))"
                   " (budget-exhausted? '(condition (type\
 evaluation-error)))"))))
  (should
   (equal "#t"
          (consent-budget-test--value
           (concat "(import (scheme base) (agent reflect))"
                   " (budget-exhausted?"
                   "   '(evaluation-result (status error)"
                   "      (error (condition"
                   "               (condition (type\
 budget-exhausted))))))")))))

(ert-deftest consent-budget-test-budget-yield-emits-ledger ()
  "`budget-yield' emits the current ledger as an observable yield event."
  (let ((text (consent-budget-test--result
               (concat "(import (scheme base) (agent reflect))"
                       " (budget-yield) (recent-yields)"))))
    (should (string-match-p (regexp-quote "(yield (budget ") text))))

(provide 'consent-budget-test)

;;; consent-budget-test.el ends here
