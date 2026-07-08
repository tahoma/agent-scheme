;;; consent-repl-parity-test.el --- Shared cross-host REPL parity suite  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Emacs half of the shared cross-host REPL parity conformance suite.  It reads
;; the host-neutral parity corpus (fixtures/repl/parity-cases.scm) and drives the
;; SAME cases against the Emacs incremental stdin REPL (`consent-repl-stream'),
;; asserting the SAME expected record sequence the portable runner asserts
;; against the terminal REPL shell (tests/scheme/consent-repl-parity-test.scm).
;; Because both runners share one corpus, a host that drifts from the cross-host
;; REPL interaction contract (docs/repl-interaction-contract.md) fails its
;; runner.
;;
;; Both the corpus expectations and the emitted records are normalized to the
;; shared host shape with `consent-test-fixture-host-datum', so the comparison is
;; representation-independent: Scheme symbols, integers, strings, and the
;; canonical booleans compare equal across the two hosts' datum encodings.  Each
;; case `expect' enumerates every record the turn produces; the runner asserts
;; per-kind record counts and the contract-meaningful fields of each record,
;; correlating a `repl-result'/`repl-condition' to its submission by the
;; `(submission sub-N)' field rather than by record position.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-repl-stream)
(require 'consent-result)
(require 'consent-test-helper)

;;;; Corpus loading

(defun consent-repl-parity-test--file ()
  "Return the shared REPL parity corpus path."
  (expand-file-name
   "fixtures/repl/parity-cases.scm"
   (if (boundp 'consent--test-root) consent--test-root default-directory)))

(defun consent-repl-parity-test--suite ()
  "Read the parity corpus and return it in the shared host shape."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (consent-repl-parity-test--file))
                   (buffer-string)))
         (suite (consent-test-fixture-host-datum (consent-read source))))
    (unless (eq (car-safe suite) 'consent-fixture-suite)
      (ert-fail "REPL parity corpus must start with consent-fixture-suite"))
    suite))

;;;; Tagged-list and untagged-case accessors

(defun consent-repl-parity-test--field (datum name)
  "Return field NAME from tagged DATUM `(tag (field value) ...)', or nil."
  (cadr (assq name (cdr-safe datum))))

(defun consent-repl-parity-test--case-field (case name)
  "Return field NAME from an untagged CASE alist `((field value) ...)', or nil."
  (cadr (assq name case)))

(defun consent-repl-parity-test--kind (record)
  "Return the leading tag symbol of RECORD or pattern."
  (car-safe record))

(defun consent-repl-parity-test--of (records tag)
  "Return the RECORDS whose kind is TAG, in order."
  (seq-filter (lambda (record)
                (eq (consent-repl-parity-test--kind record) tag))
              records))

(defun consent-repl-parity-test--count (records tag)
  "Return the number of RECORDS whose kind is TAG."
  (length (consent-repl-parity-test--of records tag)))

(defun consent-repl-parity-test--union-kinds (&rest record-lists)
  "Return the distinct kinds appearing in any of RECORD-LISTS, in first-seen order."
  (let ((seen nil))
    (dolist (records record-lists)
      (dolist (record records)
        (let ((k (consent-repl-parity-test--kind record)))
          (unless (memq k seen) (push k seen)))))
    (nreverse seen)))

;;;; Option conversion

(defun consent-repl-parity-test--assoc-form-p (value)
  "Return non-nil when VALUE is an association written as `((key value) ...)'."
  (and (consp value)
       (consp (car value))
       (= (length (car value)) 2)
       (symbolp (caar value))))

(defun consent-repl-parity-test--option-value (value)
  "Convert a corpus option VALUE (record-style alist or atom) to a dotted alist."
  (if (consent-repl-parity-test--assoc-form-p value)
      (mapcar (lambda (entry)
                (cons (car entry)
                      (consent-repl-parity-test--option-value (cadr entry))))
              value)
    value))

(defun consent-repl-parity-test--case-options (case)
  "Return CASE's `(options ...)' field as an evaluator option plist."
  (let ((options (consent-repl-parity-test--case-field case 'options))
        (plist nil))
    (dolist (entry options)
      (setq plist
            (append plist
                    (list (intern (concat ":" (symbol-name (car entry))))
                          (consent-repl-parity-test--option-value
                           (cadr entry))))))
    plist))

;;;; Expectation matching

(defun consent-repl-parity-test--correlated-kind-p (kind)
  "Return non-nil when KIND's pattern is correlated by submission, not position."
  (memq kind '(repl-result repl-condition)))

(defun consent-repl-parity-test--find-by-submission (records tag submission)
  "Return the RECORDS record of kind TAG whose `submission' field is SUBMISSION."
  (seq-find (lambda (record)
              (equal (consent-repl-parity-test--field record 'submission)
                     submission))
            (consent-repl-parity-test--of records tag)))

(defun consent-repl-parity-test--value-match-p (actual expected)
  "Return non-nil when ACTUAL satisfies EXPECTED.
EXPECTED is either an atom (compared with `equal') or a nested record pattern
`(KIND (field value) ...)'."
  (if (consp expected)
      (and (consp actual)
           (eq (consent-repl-parity-test--kind actual)
               (consent-repl-parity-test--kind expected))
           (consent-repl-parity-test--fields-match-p actual (cdr expected)))
    (equal actual expected)))

(defun consent-repl-parity-test--fields-match-p (record fields)
  "Return non-nil when RECORD's fields all satisfy the FIELDS expectation list."
  (cl-every
   (lambda (entry)
     (consent-repl-parity-test--value-match-p
      (consent-repl-parity-test--field record (car entry))
      (cadr entry)))
   fields))

(defun consent-repl-parity-test--match-record (id pattern record)
  "Assert each field of expected PATTERN against actual RECORD for case ID."
  (dolist (entry (cdr pattern))
    (let* ((fname (car entry))
           (expected (cadr entry))
           (got (consent-repl-parity-test--field record fname)))
      (should
       (consent-repl-parity-test--field-ok id (consent-repl-parity-test--kind pattern)
                                           fname got expected)))))

(defun consent-repl-parity-test--field-ok (id kind fname got expected)
  "Return non-nil when GOT matches EXPECTED, attaching ID/KIND/FNAME on failure."
  (or (consent-repl-parity-test--value-match-p got expected)
      (ert-fail (format "case %s record %s field %s: expected %S, got %S"
                        id kind fname expected got))))

(defun consent-repl-parity-test--serialize (records)
  "Serialize RECORDS through the consent writer for a host-portable stream compare."
  (mapcar #'consent-result->external records))

(defun consent-repl-parity-test--run-roundtrip (case raw session options)
  "Replay RAW (the captured records) to a fresh SESSION and assert the round-trip.
A `reproduced' case must replay to an EQUAL serialized stream; a `partial' case
must NOT (it drops an unreplayable bare reader condition or EOF-truncated form).
Serializing through the consent writer makes the compare representation-stable."
  (let* ((mode (consent-repl-parity-test--case-field case 'replay))
         (replayed (consent-repl-stream-replay-records raw session options))
         (same (equal (consent-repl-parity-test--serialize raw)
                      (consent-repl-parity-test--serialize replayed))))
    (should mode)
    (if (eq mode 'reproduced)
        (should same)
      (should-not same))))

(defun consent-repl-parity-test--run-case (case)
  "Drive one CASE against the Emacs REPL and assert its expected records."
  (let* ((id (consent-repl-parity-test--case-field case 'id))
         (input (consent-repl-parity-test--case-field case 'input))
         (session (consent-repl-parity-test--case-field case 'session))
         (options (consent-repl-parity-test--case-options case))
         (expect (consent-repl-parity-test--case-field case 'expect))
         (raw (consent-repl-stream-records-from-string input session options))
         (actual (mapcar #'consent-test-fixture-host-datum raw))
         (queues (make-hash-table :test #'eq)))
    ;; Per-kind record counts must match exactly: an extra, missing, or
    ;; mis-kinded record is a divergence.
    (dolist (k (consent-repl-parity-test--union-kinds expect actual))
      (let ((actual-count (consent-repl-parity-test--count actual k))
            (expect-count (consent-repl-parity-test--count expect k)))
        (unless (= actual-count expect-count)
          (ert-fail
           (format "case %s record %s count: expected %S, got %S\nexpected: %S\nactual: %S"
                   id k expect-count actual-count expect actual)))))
    ;; Positional queues for non-correlated kinds (prompt, submission, exit).
    (dolist (k (consent-repl-parity-test--union-kinds actual))
      (puthash k (consent-repl-parity-test--of actual k) queues))
    (dolist (pattern expect)
      (let ((kind (consent-repl-parity-test--kind pattern)))
        (if (consent-repl-parity-test--correlated-kind-p kind)
            (let* ((submission (consent-repl-parity-test--field pattern 'submission))
                   (record (consent-repl-parity-test--find-by-submission
                            actual kind submission)))
              (should record)
              (consent-repl-parity-test--match-record id pattern record))
          (let ((record (car (gethash kind queues))))
            (should record)
            (puthash kind (cdr (gethash kind queues)) queues)
            (consent-repl-parity-test--match-record id pattern record)))))
    (consent-repl-parity-test--run-roundtrip case raw session options)))

;;;; Tests

(ert-deftest consent-repl-parity-suite-shape ()
  "The shared parity corpus is well-formed and pins the contract version."
  (let* ((suite (consent-repl-parity-test--suite))
         (cases (cdr (assq 'cases (cdr suite))))
         (contract (consent-repl-parity-test--field suite 'contract)))
    (should (eq (consent-repl-parity-test--field suite 'kind) 'repl-parity))
    (should (= (consent-repl-parity-test--field suite 'version) 1))
    (should cases)
    (should (eq (car-safe contract) 'repl-interaction-contract))
    (should (= (consent-repl-parity-test--field contract 'version) 1))
    ;; Case ids are unique so a divergence is reported against a stable name.
    (let ((ids (mapcar (lambda (case)
                         (consent-repl-parity-test--case-field case 'id))
                       cases)))
      (should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

(ert-deftest consent-repl-parity-suite-runs-against-emacs-host ()
  "Every shared parity case emits the contract record sequence on the Emacs host."
  (let ((cases (cdr (assq 'cases (cdr (consent-repl-parity-test--suite))))))
    (should cases)
    (dolist (case cases)
      (consent-repl-parity-test--run-case case))))

(ert-deftest consent-repl-parity-stream-separation ()
  "Program output reaches the program-output stream, never a result rendering."
  (let ((records nil)
        (output nil)
        (lines (list "(import (scheme base) (scheme write))\n"
                     "(display \"emitted\")\n"
                     "(+ 1 2)\n"
                     "(exit)\n")))
    (let ((exit-code
           (consent-repl-stream-run
            (lambda ()
              (if (null lines) consent-repl-stream--eof (pop lines)))
            (lambda (record) (push record records))
            (lambda (text) (push text output))
            "project-main")))
      (setq records (nreverse records))
      (setq output (nreverse output))
      (should (= exit-code 0))
      (should (equal (apply #'concat output) "emitted"))
      (should (= (consent-repl-parity-test--count
                  (mapcar #'consent-test-fixture-host-datum records)
                  'repl-result)
                 3))
      (should-not
       (seq-some
        (lambda (result)
          (let ((display (consent-repl-parity-test--field result 'display)))
            (and (stringp display) (string-match-p "emitted" display))))
        (consent-repl-parity-test--of
         (mapcar #'consent-test-fixture-host-datum records) 'repl-result))))))

(provide 'consent-repl-parity-test)

;;; consent-repl-parity-test.el ends here
