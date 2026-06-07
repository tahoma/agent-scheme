;;; consent-parity.el --- Emacs/portable dual-core parity bridge  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Cross-implementation parity bridge for the irreducible dual core.
;;
;; `docs/architecture.md' ("First-Class Portable Scheme") requires architectural
;; parity between the Emacs-hosted core (`lisp/consent-*.el') and the portable
;; core (`scheme/consent/*.sld').  This bridge turns that prose rule into an
;; executable gate: it runs the shared fixture corpus through both in-repo
;; implementations and reports any case whose normalized result differs between
;; the two cores.
;;
;; Scope is the dual core only -- the layers each host must implement in its own
;; language (reader, evaluator, macro, runtime).  Libraries that are
;; single-sourced from a portable `.sld' and loaded by both bootstraps cannot
;; diverge from themselves, so cases that import them fall out of scope.  The
;; single-sourced set is read from `consent--agent-source-library-files' and
;; `consent--standard-source-library-files', so a newly single-sourced library
;; drops out of the parity scope automatically as the migration proceeds.
;;
;; The Emacs-hosted result for each case is computed exactly as the Emacs
;; conformance gate computes it (`consent-test-fixture-actual').  The portable
;; result is produced by `tests/scheme/consent-parity-emit.scm' running under an
;; external R7RS host, which emits one Scheme-readable `(parity-actual ID
;; PAYLOAD)' record per case using the same normalization as the portable
;; fixture runner.  Because each side already matches the corpus `expect' field,
;; the gate is green by construction for today's corpus; its value is
;; forward-looking, catching future Emacs/portable drift the per-side gates miss
;; (notably in the `expand', `eval-result', and `error' phases that have no
;; external reference oracle).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'consent-reader)
(require 'consent-library)
(require 'consent-oracle)
(require 'consent-test-helper)

(defconst consent-parity-emitter-file
  "tests/scheme/consent-parity-emit.scm"
  "Repository-relative path to the portable parity emitter program.")

(defconst consent-parity-runnable-phases
  '(read read-all expand eval eval-result error)
  "Fixture phases the parity gate executes on both cores.")

(defconst consent-parity-hosts
  '((chibi "CONSENT_CHIBI" "chibi-scheme" ("-A" :library :script))
    (gauche "CONSENT_GAUCHE" "gosh" ("-I" :library "-r7" :script))
    (guile "CONSENT_GUILE" "guile"
           ("--no-auto-compile" "--r7rs" "-L" :library :script)))
  "Portable hosts the parity emitter can run under.
Each entry is (NAME ENV-VARIABLE EXECUTABLE ARGUMENT-TEMPLATE).  The
template uses the `:library' and `:script' placeholders.  Hosts are
listed in auto-discovery preference order; all three capture clean
standard output and need no compilation step.")

;;; Dual-core scope.

(defun consent-parity--single-sourced-library-names ()
  "Return library names loaded from single portable source on both cores.
These are excluded from parity scope: a single-sourced library cannot
diverge from itself."
  (mapcar
   (lambda (entry)
     (consent-test-fixture-host-datum (consent-read (car entry))))
   (append consent--agent-source-library-files
           consent--standard-source-library-files)))

(defun consent-parity--dual-core-source-p (source)
  "Return non-nil when SOURCE imports no single-sourced library."
  (let ((single (consent-parity--single-sourced-library-names)))
    (not (cl-some
          (lambda (name) (member name single))
          (consent-oracle--source-library-imports source)))))

(defun consent-parity-case-eligible-p (case)
  "Return non-nil when CASE is in scope for the dual-core parity gate."
  (let ((phase (consent-test-fixture-field case 'phase))
        (status (consent-test-fixture-field case 'status))
        (oracle (consent-test-fixture-field case 'oracle))
        (source (consent-test-fixture-field case 'source)))
    (and (eq oracle 'shared)
         (eq status 'implemented)
         (memq phase consent-parity-runnable-phases)
         (condition-case nil
             (consent-parity--dual-core-source-p source)
           (error t)))))

(defun consent-parity-cases ()
  "Return the shared fixture cases in scope for the parity gate."
  (cl-remove-if-not #'consent-parity-case-eligible-p
                    (consent-test-fixture-cases)))

;;; Normalized comparison keys.

(defun consent-parity--emacs-key (actual)
  "Return a host-comparable parity key for an Emacs ACTUAL plist."
  (pcase (plist-get actual :status)
    ('value (list 'value (plist-get actual :value)))
    ('values (cons 'values (plist-get actual :values)))
    ('result (list 'result (plist-get actual :value)))
    ('error (list 'error))
    (status (list 'unknown status))))

(defun consent-parity--portable-key (payload)
  "Return a host-comparable parity key for a portable record PAYLOAD."
  (pcase payload
    (`(value ,value) (list 'value value))
    (`(values ,values) (cons 'values values))
    (`(result ,value) (list 'result value))
    (`(error) (list 'error))
    (_ (list 'unknown payload))))

(defun consent-parity-emacs-actuals (cases)
  "Return an alist mapping each CASE id to its Emacs-hosted parity key."
  (mapcar
   (lambda (case)
     (cons (consent-test-fixture-field case 'id)
           (consent-parity--emacs-key
            (consent-test-fixture-actual case))))
   cases))

(defun consent-parity--parse-records (output)
  "Parse portable emitter OUTPUT into an alist of id to parity key."
  (let (alist)
    (dolist (datum (consent-read-all output))
      (let ((record (consent-test-fixture-host-datum datum)))
        (unless (and (consp record)
                     (eq (car record) 'parity-actual)
                     (= (length record) 3))
          (error "Malformed parity record: %S" record))
        (push (cons (nth 1 record)
                    (consent-parity--portable-key (nth 2 record)))
              alist)))
    (nreverse alist)))

;;; Portable host invocation.

(defun consent-parity--normalize-command (command)
  "Expand a repository-relative COMMAND path against the test root."
  (if (and (string-match-p "/" command)
           (not (file-name-absolute-p command))
           (boundp 'consent--test-root))
      (expand-file-name command consent--test-root)
    command))

(defun consent-parity--host-runner (host-entry)
  "Return the configured or discovered runner for HOST-ENTRY, or nil."
  (let ((configured (getenv (nth 1 host-entry))))
    (if (and configured (> (length configured) 0))
        (consent-parity--normalize-command configured)
      (executable-find (nth 2 host-entry)))))

(defun consent-parity-resolve-host ()
  "Return (HOST-ENTRY . RUNNER) for the selected or first available host.
Honor CONSENT_PARITY_HOST when set; otherwise pick the first available
host in `consent-parity-hosts' order.  Return nil when no host is
available."
  (let ((requested (getenv "CONSENT_PARITY_HOST")))
    (if (and requested (> (length requested) 0))
        (let* ((entry (or (assq (intern requested) consent-parity-hosts)
                          (error "Unknown parity host: %s" requested)))
               (runner (consent-parity--host-runner entry)))
          (and runner (cons entry runner)))
      (cl-some
       (lambda (entry)
         (let ((runner (consent-parity--host-runner entry)))
           (and runner (cons entry runner))))
       consent-parity-hosts))))

(defun consent-parity--host-arguments (host-entry library-directory script)
  "Return process arguments for HOST-ENTRY over LIBRARY-DIRECTORY and SCRIPT."
  (mapcar
   (lambda (token)
     (pcase token
       (:library library-directory)
       (:script script)
       (_ token)))
   (nth 3 host-entry)))

(defun consent-parity-run-emitter (host-entry runner)
  "Run the portable parity emitter under HOST-ENTRY using RUNNER.
Return the emitter's standard output, or signal an error with the
captured diagnostics when the emitter exits non-zero.

Standard error is captured separately so host startup chatter (for
example Guile's `imported module overrides core binding' warnings) never
pollutes the Scheme-readable record stream on standard output."
  (let ((library-directory (consent--test-target-library-directory))
        (output-buffer (generate-new-buffer " *consent-parity*"))
        (stderr-file (make-temp-file "consent-parity-stderr-"))
        (default-directory consent--test-root))
    (unwind-protect
        (let ((status
               (apply #'process-file runner nil
                      (list output-buffer stderr-file) nil
                      (consent-parity--host-arguments
                       host-entry
                       library-directory
                       consent-parity-emitter-file))))
          (with-current-buffer output-buffer
            (let ((output (buffer-string)))
              (unless (equal status 0)
                (error "Portable parity emitter failed (status %S):\n%s%s"
                       status
                       output
                       (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (buffer-string))))
              output)))
      (kill-buffer output-buffer)
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

;;; Comparison.

(defun consent-parity-compare (host-entry runner)
  "Return parity divergences between the Emacs and portable cores.
HOST-ENTRY and RUNNER select the portable host.  Each divergence is a
plist (:id ID :emacs KEY :portable KEY :reason REASON), where REASON is
`mismatch' or `missing-portable'."
  (let* ((cases (consent-parity-cases))
         (emacs-actuals (consent-parity-emacs-actuals cases))
         (portable-actuals
          (consent-parity--parse-records
           (consent-parity-run-emitter host-entry runner)))
         divergences)
    (dolist (entry emacs-actuals)
      (let* ((id (car entry))
             (emacs-key (cdr entry))
             (cell (assq id portable-actuals)))
        (cond
         ((null cell)
          (push (list :id id :emacs emacs-key :portable nil
                      :reason 'missing-portable)
                divergences))
         ((not (equal emacs-key (cdr cell)))
          (push (list :id id :emacs emacs-key :portable (cdr cell)
                      :reason 'mismatch)
                divergences)))))
    (nreverse divergences)))

(defun consent-parity-divergence-message (divergence)
  "Return a human-readable line describing one DIVERGENCE."
  (pcase (plist-get divergence :reason)
    ('missing-portable
     (format "%s: portable core emitted no result (Emacs gave %S)"
             (plist-get divergence :id)
             (plist-get divergence :emacs)))
    (_
     (format "%s: Emacs %S != portable %S"
             (plist-get divergence :id)
             (plist-get divergence :emacs)
             (plist-get divergence :portable)))))

(provide 'consent-parity)

;;; consent-parity.el ends here
