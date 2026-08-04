;;; consent-oracle.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Compare pure shared Consent Scheme fixture cases with external R7RS
;; implementations.  Reference adapters are represented with
;; `consent-oracle-reference'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'consent-eval)
(require 'consent-reader)

(defgroup consent-oracle nil
  "Reference implementation oracle runner for Consent Scheme fixtures."
  :group 'consent)

(defconst consent-oracle--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Consent Scheme oracle source.")

(defcustom consent-oracle-root-directory
  (file-name-directory
   (directory-file-name consent-oracle--source-directory))
  "Repository root used for fixture loading and reference processes."
  :type 'directory
  :group 'consent-oracle)

(defcustom consent-oracle-chibi-command nil
  "Optional Chibi Scheme executable for oracle runs.
When nil, `consent-oracle-chibi-reference' consults
CONSENT_CHIBI and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-gauche-command nil
  "Optional Gauche executable for oracle runs.
When nil, `consent-oracle-gauche-reference' consults
CONSENT_GAUCHE and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-guile-command nil
  "Optional Guile executable for oracle runs.
When nil, `consent-oracle-guile-reference' consults
CONSENT_GUILE and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-sagittarius-command nil
  "Optional Sagittarius executable for oracle runs.
When nil, `consent-oracle-sagittarius-reference' consults
CONSENT_SAGITTARIUS and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-racket-command nil
  "Optional Racket executable for oracle runs.
When nil, `consent-oracle-racket-reference' consults
CONSENT_RACKET and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-chicken-command nil
  "Optional CHICKEN Scheme executable for oracle runs.
When nil, `consent-oracle-chicken-reference' consults
CONSENT_CHICKEN and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-gambit-command nil
  "Optional Gambit Scheme interpreter executable for oracle runs.
When nil, `consent-oracle-gambit-reference' consults
CONSENT_GAMBIT and then PATH for gsi."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defcustom consent-oracle-gambit-compiler-command nil
  "Optional Gambit Scheme compiler executable for compile checks.
When nil, `consent-oracle-gambit-compiler-executable' consults
CONSENT_GAMBIT_COMPILER and then PATH for gsc."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'consent-oracle)

(defconst consent-oracle--policy-gated-libraries
  '((scheme file)
    (scheme load)
    (scheme process-context)
    (scheme repl)
    (scheme time))
  "R7RS libraries whose host effects are policy-gated in Consent Scheme.")

(defconst consent-oracle-statuses
  '(portable-agree
    implementation-variant
    agent-mismatch
    unsupported-reference
    policy-gated
    not-oracle-eligible)
  "Stable oracle report status order.")

(defconst consent-oracle-reference-names
  '(chibi gauche guile sagittarius racket chicken gambit)
  "Stable oracle reference adapter name order.")

(cl-defstruct (consent-oracle-reference
               (:constructor consent-oracle-reference
                             (&key name command arguments evaluator
                                   program-filter)))
  "Reference implementation adapter.
NAME is a symbol such as `chibi'.  COMMAND is an executable path
or nil when unavailable.  ARGUMENTS is a list of command-line
arguments that precede the generated fixture program path.
PROGRAM-FILTER optionally receives generated Scheme source and
returns source to write for the reference implementation.
EVALUATOR is an optional test hook that receives a fixture case
and returns a normalized actual plist."
  name command arguments evaluator program-filter)

(cl-defstruct (consent-oracle-report
               (:constructor consent-oracle--make-report
                             (&key case-id results status)))
  "Oracle report for one fixture case.
RESULTS is a list of plists with `:name', `:status', and optional
`:payload' or `:message' entries."
  case-id results status)

(defun consent-oracle--host-datum (datum)
  "Convert Consent Scheme fixture DATUM to a host datum."
  (cond
   ((eq datum consent-true) t)
   ((eq datum consent-false) :scheme-false)
   ((null datum) nil)
   ((consent-symbol-p datum)
    (intern (consent-symbol-name datum)))
   ((consent-number-p datum)
    (or (consent-number-value datum)
        (consent-number-lexeme datum)))
   ((or (stringp datum) (characterp datum))
    datum)
   ((consent-character-p datum)
    (consent-character-code datum))
   ((consent-bytevector-p datum)
    (append (consent-bytevector-bytes datum) nil))
   ((consp datum)
    (cons (consent-oracle--host-datum (car datum))
          (consent-oracle--host-datum (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'consent-oracle--host-datum
                     (append datum nil))))
   (t
    (error "Unsupported fixture datum: %S" datum))))

(defun consent-oracle--fixture-file ()
  "Return the canonical shared fixture corpus path."
  (expand-file-name
   "fixtures/r7rs/conformance-cases.scm"
   consent-oracle-root-directory))

(defun consent-oracle--raw-symbol-name (value)
  "Return VALUE's Consent Scheme symbol name, or nil."
  (when (consent-symbol-p value)
    (consent-symbol-name value)))

(defun consent-oracle--tagged-datum (value)
  "Normalize tagged fixture VALUE while retaining its typed payload."
  (unless (and (consp value)
               (consent-oracle--raw-symbol-name (car value)))
    (error "Fixture value must be tagged: %S" value))
  (let ((tag
         (intern (consent-oracle--raw-symbol-name (car value)))))
    (cons
     tag
     (if (eq tag 'condition)
         (mapcar #'consent-oracle--host-datum (cdr value))
       (cdr value)))))

(defun consent-oracle--normalize-case (case)
  "Normalize CASE metadata while retaining source and expected datums."
  (mapcar
   (lambda (entry)
     (let* ((name
             (intern
              (or (consent-oracle--raw-symbol-name (car entry))
                  (error "Invalid fixture field: %S" entry))))
            (value (cadr entry)))
       (list
        name
        (if (memq name '(source expect))
            (consent-oracle--tagged-datum value)
          (consent-oracle--host-datum value)))))
   case))

(defun consent-oracle--normalize-suite (suite)
  "Normalize parsed fixture SUITE without erasing typed case payloads."
  (unless (and (consp suite)
               (equal
                (consent-oracle--raw-symbol-name (car suite))
                "consent-fixture-suite"))
    (error "Fixture corpus must start with consent-fixture-suite"))
  (let ((version nil)
        (cases nil))
    (dolist (entry (cdr suite))
      (pcase (consent-oracle--raw-symbol-name (car entry))
        ("version"
         (setq version
               (consent-oracle--host-datum (cadr entry))))
        ("cases"
         (setq cases
               (mapcar #'consent-oracle--normalize-case
                       (cdr entry))))))
    (list 'consent-fixture-suite
          (list 'version version)
          (cons 'cases cases))))

(defun consent-oracle-fixture-suite ()
  "Read and return the canonical fixture suite as host data."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (consent-oracle--fixture-file))
                   (buffer-string)))
         (suite (consent-read source)))
    (consent-oracle--normalize-suite suite)))

(defun consent-oracle-fixture-cases ()
  "Return all shared fixture cases as host data."
  (let ((cases-field (assq 'cases (cdr (consent-oracle-fixture-suite)))))
    (unless cases-field
      (error "Fixture corpus must include a cases field"))
    (cdr cases-field)))

(defun consent-oracle--field (case field)
  "Return FIELD from fixture CASE."
  (cadr (assq field case)))

(defun consent-oracle--source-file (path)
  "Return the validated fixture source file named by relative PATH."
  (unless (and (stringp path)
               (string-match-p
                "\\`programs/[[:alnum:]_.-]+\\.scm\\'"
                path))
    (error "Invalid fixture source file path: %S" path))
  (let* ((root
          (file-name-as-directory
           (file-name-directory (consent-oracle--fixture-file))))
         (file (expand-file-name path root)))
    (unless (and (file-in-directory-p file root)
                 (file-regular-p file))
      (error "Missing fixture source file: %S" path))
    file))

(defun consent-oracle--source-text (case)
  "Materialize CASE source text at the oracle boundary."
  (pcase (consent-oracle--field case 'source)
    (`(text ,text) text)
    (`(form ,form)
     (concat (consent-datum->external form) "\n"))
    (`(forms . ,forms)
     (concat
      (mapconcat #'consent-datum->external forms "\n")
      "\n"))
    (`(file ,path)
     (with-temp-buffer
       (insert-file-contents-literally
        (consent-oracle--source-file path))
       (buffer-string)))
    (_
     (error "Unsupported fixture source representation"))))

(defun consent-oracle--datum-symbol-name (datum)
  "Return DATUM's symbol name, or nil when DATUM is not a Scheme symbol."
  (when (consent-symbol-p datum)
    (consent-symbol-name datum)))

(defun consent-oracle--datum-symbol-p (datum name)
  "Return non-nil when DATUM is a Scheme symbol named NAME."
  (equal (consent-oracle--datum-symbol-name datum) name))

(defun consent-oracle--library-part (datum)
  "Return a host library-name part for DATUM."
  (cond
   ((consent-symbol-p datum)
    (intern (consent-symbol-name datum)))
   ((consent-number-p datum)
    (or (consent-number-value datum)
        (intern (consent-number-lexeme datum))))
   (t nil)))

(defun consent-oracle--direct-library-name (import-set)
  "Return direct library name for IMPORT-SET, or nil."
  (let ((parts nil)
        (cursor import-set)
        (valid t))
    (while (and valid (consp cursor))
      (let ((part (consent-oracle--library-part (car cursor))))
        (if part
            (push part parts)
          (setq valid nil)))
      (setq cursor (cdr cursor)))
    (when (and valid (null cursor) parts)
      (nreverse parts))))

(defun consent-oracle--import-set-library-names (import-set)
  "Return direct library names referenced by IMPORT-SET."
  (let ((modifier (and (consp import-set)
                       (consent-oracle--datum-symbol-name
                        (car import-set)))))
    (cond
     ((member modifier '("only" "except" "prefix" "rename"))
      (consent-oracle--import-set-library-names (cadr import-set)))
     (t
      (let ((direct (consent-oracle--direct-library-name import-set)))
        (if direct (list direct) nil))))))

(defun consent-oracle--source-library-imports (source)
  "Return library names imported by SOURCE."
  (let ((imports nil))
    (dolist (form (consent-read-all source))
      (when (and (consp form)
                 (consent-oracle--datum-symbol-p (car form) "import"))
        (dolist (import-set (cdr form))
          (setq imports
                (append (consent-oracle--import-set-library-names
                         import-set)
                        imports)))))
    (nreverse imports)))

(defun consent-oracle--policy-gated-source-p (source)
  "Return non-nil when SOURCE imports a policy-gated library."
  (cl-some
   (lambda (library)
     (member library consent-oracle--policy-gated-libraries))
   (consent-oracle--source-library-imports source)))

;;;###autoload
(defun consent-oracle-case-classification (case)
  "Return oracle classification for fixture CASE before execution."
  (let ((kind (consent-oracle--field case 'kind))
        (phase (consent-oracle--field case 'phase))
        (status (consent-oracle--field case 'status))
        (oracle (consent-oracle--field case 'oracle))
        (oracle-eligibility
         (consent-oracle--field case 'oracle-eligibility))
        (options (consent-oracle--field case 'options))
        (source (consent-oracle--source-text case)))
    (cond
     ((memq oracle-eligibility '(policy-gated not-oracle-eligible))
      oracle-eligibility)
     ((eq status 'policy-gated)
      'policy-gated)
     ((not (eq kind 'r7rs-conformance))
      'not-oracle-eligible)
     ((not (memq oracle '(shared portable-only)))
      'not-oracle-eligible)
     ((not (eq status 'implemented))
      'not-oracle-eligible)
     ((not (memq phase '(read read-all eval)))
      'not-oracle-eligible)
     (options
      'not-oracle-eligible)
     ((condition-case nil
          (consent-oracle--policy-gated-source-p source)
        (error t))
      'policy-gated)
     (t
      'eligible))))

(defun consent-oracle--fixture-options-plist (case)
  "Return CASE options as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (consent-oracle--field case 'options))
      (unless (and (listp entry)
                   (symbolp (car entry))
                   (= (length entry) 2))
        (error "Invalid options entry for fixture %S: %S"
               (consent-oracle--field case 'id)
               entry))
      (setq plist
            (plist-put plist
                       (intern (concat ":" (symbol-name (car entry))))
                       (cadr entry))))
    plist))

(defun consent-oracle--agent-actual (case)
  "Run CASE through Consent Scheme and return a normalized actual plist."
  (let ((phase (consent-oracle--field case 'phase))
        (source (consent-oracle--source-text case))
        (options (consent-oracle--fixture-options-plist case)))
    (condition-case condition
        (pcase phase
          ('read
           (list :status 'value
                 :value
                 (consent-datum->external
                  (consent-read source options))))
          ('read-all
           (list :status 'values
                 :values
                 (mapcar #'consent-datum->external
                         (consent-read-all source options))))
          ('eval
           (let ((value (consent-eval-source source nil options)))
             (if (consent--multiple-values-p value)
                 (list :status 'values
                       :values
                       (mapcar #'consent-value->external
                               (consent--multiple-values-values value)))
               (list :status 'value
                     :value (consent-value->external value)))))
          (_
           (error "Unsupported oracle phase: %S" phase)))
      (error
       (list :status 'error :condition condition)))))

(defun consent-oracle--scheme-string (string)
  "Return STRING as an R7RS string literal."
  (consent-datum->external string))

(defun consent-oracle--emit-support-source ()
  "Return Scheme support code for emitting normalized oracle results."
  (mapconcat
   #'identity
   '("(define (consent-oracle-emit results)"
     "  (cond"
     "   ((null? results) (write (list 'values '())))"
     "   ((null? (cdr results)) (write (list 'value (car results))))"
     "   (else (write (list 'values results))))"
     "  (newline))")
   "\n"))

(defun consent-oracle--read-program (source read-all-p)
  "Return a Scheme program that reads SOURCE.
When READ-ALL-P is non-nil, read every datum and emit them as
multiple values."
  (mapconcat
   #'identity
   (list
    "(import (scheme base) (scheme read) (scheme write))"
    (consent-oracle--emit-support-source)
    (format "(define consent-oracle-input (open-input-string %s))"
            (consent-oracle--scheme-string source))
    (if read-all-p
        (mapconcat
         #'identity
         '("(define (consent-oracle-read-all input)"
           "  (let loop ((values '()))"
           "    (let ((value (read input)))"
           "      (if (eof-object? value)"
           "          (reverse values)"
           "          (loop (cons value values))))))"
           "(consent-oracle-emit"
           " (consent-oracle-read-all consent-oracle-input))")
         "\n")
      "(consent-oracle-emit (list (read consent-oracle-input)))"))
   "\n"))

(defun consent-oracle--top-level-form-p (datum)
  "Return non-nil when DATUM is a top-level declaration form."
  (and (consp datum)
       (member (consent-oracle--datum-symbol-name (car datum))
               '("define" "define-record-type" "define-syntax"
                 "define-values" "define-library" "import"))))

(defun consent-oracle--eval-program (source)
  "Return a Scheme program that evaluates SOURCE and emits the final values."
  (let* ((forms (consent-read-all source))
         (prelude (butlast forms))
         (final (car (last forms))))
    (when (null forms)
      (error "Oracle source contains no forms"))
    (mapconcat
     #'identity
     (append
      (list
       "(import (scheme base) (scheme write))"
       (consent-oracle--emit-support-source))
      (mapcar #'consent-datum->external prelude)
      (list
       (if (consent-oracle--top-level-form-p final)
           (mapconcat
            #'identity
            (list
             (consent-datum->external final)
             "(call-with-values (lambda () (if #f #f)) (lambda results\
 (consent-oracle-emit results)))")
            "\n")
         (format
          "(call-with-values (lambda () %s) (lambda results\
 (consent-oracle-emit results)))"
          (consent-datum->external final)))))
     "\n")))

(defun consent-oracle--program-for-case (case)
  "Return a reference Scheme program for CASE."
  (pcase (consent-oracle--field case 'phase)
    ('read
      (consent-oracle--read-program
      (consent-oracle--source-text case)
      nil))
    ('read-all
      (consent-oracle--read-program
      (consent-oracle--source-text case)
      t))
    ('eval
     (consent-oracle--eval-program
      (consent-oracle--source-text case)))
    (phase
     (error "Unsupported oracle phase: %S" phase))))

(defun consent-oracle--program-for-reference (reference case)
  "Return a generated source program for REFERENCE and fixture CASE."
  (let* ((program (consent-oracle--program-for-case case))
         (program-filter
          (consent-oracle-reference-program-filter reference)))
    (if program-filter
        (funcall program-filter program)
      program)))

(defun consent-oracle--reference-datum-result (datum)
  "Return normalized oracle result for DATUM, or nil."
  (cond
   ((and (consp datum)
         (consent-oracle--datum-symbol-p (car datum) "value")
         (consp (cdr datum))
         (null (cddr datum)))
    (list :status 'value
          :value (consent-datum->external
                  (cadr datum))))
   ((and (consp datum)
         (consent-oracle--datum-symbol-p (car datum) "values")
         (consp (cdr datum))
         (listp (cadr datum))
         (null (cddr datum)))
    (list :status 'values
          :values
          (mapcar #'consent-datum->external
                  (cadr datum))))))

(defun consent-oracle--normalize-reference-output-line (line)
  "Normalize known reference writer spellings in raw output LINE."
  (replace-regexp-in-string
   "#vu8("
   "#u8("
   line
   t
   t))

(defun consent-oracle--parse-reference-output (output)
  "Parse reference implementation OUTPUT into a normalized actual plist."
  (let ((trimmed (string-trim output)))
    (or
     (catch 'result
       (dolist (line (reverse (split-string trimmed "\n" t "[[:space:]\r]+")))
         (condition-case nil
             (let ((result
                    (consent-oracle--reference-datum-result
                     (consent-read
                      (consent-oracle--normalize-reference-output-line
                       line)))))
               (when result
                 (throw 'result result)))
           (error nil))))
     (list :status 'error
           :message (format "Malformed oracle output: %s" trimmed)))))

;;;###autoload
(defun consent-oracle-run-reference (reference case)
  "Run REFERENCE against fixture CASE and return a normalized actual plist."
  (cond
   ((consent-oracle-reference-evaluator reference)
    (funcall (consent-oracle-reference-evaluator reference) case))
   ((not (consent-oracle-reference-command reference))
    (list :status 'unsupported-reference
          :message "reference command not found"))
   (t
    (let* ((program (consent-oracle--program-for-reference reference case))
           (program-file (make-temp-file "consent-oracle-" nil ".scm"))
           (output-buffer (generate-new-buffer " *consent-oracle*"))
           (default-directory consent-oracle-root-directory))
      (unwind-protect
          (progn
            (with-temp-file program-file
              (insert program)
              (insert "\n"))
            (condition-case condition
                (let ((status
                       (apply
                        #'process-file
                        (consent-oracle-reference-command reference)
                        nil
                        output-buffer
                        nil
                        (append
                         (consent-oracle-reference-arguments reference)
                         (list program-file)))))
                  (with-current-buffer output-buffer
                    (let ((output (buffer-string)))
                      (if (equal status 0)
                          (condition-case parse-condition
                              (consent-oracle--parse-reference-output output)
                            (error
                             (list :status 'error
                                   :message
                                   (format "Could not parse oracle output: %s"
                                           (error-message-string
                                            parse-condition)))))
                        (list :status 'error
                              :message (string-trim output))))))
              (file-error
               (list :status 'unsupported-reference
                     :message (error-message-string condition)))))
        (when (buffer-live-p output-buffer)
          (kill-buffer output-buffer))
        (when (file-exists-p program-file)
          (delete-file program-file)))))))

(defun consent-oracle--actual-key (actual)
  "Return a comparable semantic key for ACTUAL."
  (pcase (plist-get actual :status)
    ('value
     (list 'value (plist-get actual :value)))
    ('values
     (cons 'values (plist-get actual :values)))
    ('error
     '(error))
    (_ nil)))

(defun consent-oracle--normalize-external (external)
  "Normalize known reference writer variation in EXTERNAL."
  (if (stringp external)
      (replace-regexp-in-string
       "\\+\\+nan\\.0i"
       "+nan.0i"
       external
       t
       t)
    external))

(defun consent-oracle--normalize-payload (payload)
  "Normalize oracle report PAYLOAD values before comparison."
  (if (listp payload)
      (mapcar #'consent-oracle--normalize-external payload)
    (consent-oracle--normalize-external payload)))

(defun consent-oracle--result-entry (name actual)
  "Return a report result entry named NAME for ACTUAL."
  (pcase (plist-get actual :status)
    ('value
     (list :name name :status 'ok
           :payload
           (consent-oracle--normalize-payload
            (plist-get actual :value))))
    ('values
     (list :name name :status 'ok
           :payload
           (consent-oracle--normalize-payload
            (plist-get actual :values))))
    ('error
     (list :name name :status 'error
           :message (or (plist-get actual :message)
                        (when (plist-get actual :condition)
                          (error-message-string
                           (plist-get actual :condition))))))
    ('unsupported-reference
     (list :name name :status 'unsupported-reference
           :message (plist-get actual :message)))
    (_
     (list :name name :status 'error
           :message (format "Unknown actual result: %S" actual)))))

(defun consent-oracle--supported-result-p (entry)
  "Return non-nil when ENTRY came from a supported reference run."
  (not (eq (plist-get entry :status) 'unsupported-reference)))

(defun consent-oracle--entry-key (entry)
  "Return a comparable key for report ENTRY."
  (pcase (plist-get entry :status)
    ('ok
     (let ((payload (plist-get entry :payload)))
       (if (listp payload)
           (cons 'values payload)
         (list 'value payload))))
    ('error
     '(error))
    (_ nil)))

(defun consent-oracle--classify-results (agent-entry reference-entries)
  "Classify oracle comparison between AGENT-ENTRY and REFERENCE-ENTRIES."
  (let ((supported (cl-remove-if-not
                    #'consent-oracle--supported-result-p
                    reference-entries)))
    (cond
     ((null supported)
      'unsupported-reference)
     ((cl-some
       (lambda (entry)
         (not (equal (consent-oracle--entry-key entry)
                     (consent-oracle--entry-key (car supported)))))
       (cdr supported))
      'implementation-variant)
     ((equal (consent-oracle--entry-key agent-entry)
             (consent-oracle--entry-key (car supported)))
      'portable-agree)
     (t
      'agent-mismatch))))

;;;###autoload
(defun consent-oracle-run-case (case &optional references)
  "Run fixture CASE against REFERENCES and return an oracle report."
  (let ((classification (consent-oracle-case-classification case))
        (case-id (consent-oracle--field case 'id)))
    (if (not (eq classification 'eligible))
        (consent-oracle--make-report
         :case-id case-id
         :results nil
         :status classification)
      (let* ((active-references (or references
                                    (consent-oracle-default-references)))
             (reference-entries
              (mapcar
               (lambda (reference)
                 (consent-oracle--result-entry
                  (consent-oracle-reference-name reference)
                  (consent-oracle-run-reference reference case)))
               active-references))
             (agent-entry
              (consent-oracle--result-entry
               'consent
               (consent-oracle--agent-actual case)))
             (status
              (consent-oracle--classify-results
               agent-entry reference-entries)))
        (consent-oracle--make-report
         :case-id case-id
         :results (append reference-entries (list agent-entry))
         :status status)))))

(defun consent-oracle--host-external (datum)
  "Return DATUM rendered as a small Scheme-readable external datum."
  (cond
   ((null datum) "()")
   ((symbolp datum) (symbol-name datum))
   ((stringp datum) (consent-datum->external datum))
   ((consp datum)
    (concat "("
            (mapconcat #'consent-oracle--host-external datum " ")
            ")"))
   (t
    (format "%S" datum))))

(defun consent-oracle--entry-datum (entry)
  "Return ENTRY as a host datum for report rendering."
  (let ((base (list (plist-get entry :name)
                    (plist-get entry :status)))
        (payload (plist-get entry :payload))
        (message (plist-get entry :message)))
    (cond
     (payload
      (append base (list payload)))
     ((and message (> (length message) 0))
      (append base (list message)))
     (t
      base))))

;;;###autoload
(defun consent-oracle-report->external (report)
  "Return REPORT as a Scheme-readable external representation."
  (consent-oracle--host-external
   `(oracle-report
     (case ,(consent-oracle-report-case-id report))
     (results ,(mapcar #'consent-oracle--entry-datum
                       (consent-oracle-report-results report)))
     (status ,(consent-oracle-report-status report)))))

;;;###autoload
(defun consent-oracle-filter-reports (reports statuses)
  "Return REPORTS whose status is included in STATUSES.
When STATUSES is nil, return REPORTS unchanged."
  (if statuses
      (cl-remove-if-not
       (lambda (report)
         (memq (consent-oracle-report-status report) statuses))
       reports)
    reports))

(defun consent-oracle--summary-datum (reports)
  "Return a Scheme-readable summary datum for REPORTS."
  `(oracle-summary
    (total ,(length reports))
    ,@(mapcar
       (lambda (status)
         (list status
               (cl-count-if
                (lambda (report)
                  (eq (consent-oracle-report-status report) status))
                reports)))
       consent-oracle-statuses)))

;;;###autoload
(defun consent-oracle-summary->external (reports)
  "Return a Scheme-readable summary for REPORTS."
  (consent-oracle--host-external
   (consent-oracle--summary-datum reports)))

;;;###autoload
(defun consent-oracle-parse-status-filter (value)
  "Parse comma-separated oracle status filter VALUE."
  (when (and value (> (length (string-trim value)) 0))
    (let ((statuses
           (mapcar
            (lambda (part)
              (intern (string-trim part)))
            (split-string value "," t "[[:space:]\n\t]+"))))
      (dolist (status statuses)
        (unless (memq status consent-oracle-statuses)
          (error "Unknown oracle status filter: %S" status)))
      statuses)))

(defun consent-oracle--configured-command (custom env-name executable)
  "Return CUSTOM, ENV-NAME, or discovered EXECUTABLE command."
  (or custom
      (let ((env (getenv env-name)))
        (and env (not (string-empty-p env)) env))
      (executable-find executable)))

(defun consent-oracle--racket-r7rs-program (program)
  "Return PROGRAM wrapped for Racket's R7RS language mode."
  (concat "#lang r7rs\n" program))

(defun consent-oracle--racket-r7rs-available-p (command)
  "Return non-nil when COMMAND can load Racket's R7RS language package."
  (when command
    (with-temp-buffer
      (condition-case nil
          (equal 0 (process-file command nil t nil "-l" "r7rs/lang/reader"))
        (file-error nil)))))

(defun consent-oracle--chicken-r7rs-available-p (command)
  "Return non-nil when COMMAND can load CHICKEN's R7RS egg."
  (when command
    (with-temp-buffer
      (condition-case nil
          (equal 0
                 (process-file
                  command nil t nil
                  "-q" "-R" "r7rs" "-b" "-e" "(import (scheme base))"))
        (file-error nil)))))

(defun consent-oracle--gambit-library-search-directory ()
  "Return the repository Scheme library directory for Gambit."
  (expand-file-name "scheme" consent-oracle-root-directory))

(defun consent-oracle--gambit-r7rs-arguments ()
  "Return Gambit arguments for strict R7RS mode and local library search."
  (list
   (format "-:r7rs,search=%s"
           (consent-oracle--gambit-library-search-directory))))

(defun consent-oracle--gambit-r7rs-available-p (command)
  "Return non-nil when COMMAND supports Gambit's R7RS mode."
  (when command
    (with-temp-buffer
      (condition-case nil
          (equal 0
                 (apply
                  #'process-file
                  command
                  nil
                  t
                  nil
                  (append
                   (consent-oracle--gambit-r7rs-arguments)
                   '("-e"
                     "(import (scheme base) (scheme write)) (write (+ 1 2))\
 (newline)"))))
        (file-error nil)))))

;;;###autoload
(defun consent-oracle-chibi-reference ()
  "Return the Chibi Scheme reference adapter."
  (consent-oracle-reference
   :name 'chibi
   :command
   (consent-oracle--configured-command
    consent-oracle-chibi-command
    "CONSENT_CHIBI"
    "chibi-scheme")))

;;;###autoload
(defun consent-oracle-gauche-reference ()
  "Return the Gauche reference adapter."
  (consent-oracle-reference
   :name 'gauche
   :command
   (consent-oracle--configured-command
    consent-oracle-gauche-command
    "CONSENT_GAUCHE"
    "gosh")))

;;;###autoload
(defun consent-oracle-guile-reference ()
  "Return the Guile reference adapter."
  (consent-oracle-reference
   :name 'guile
   :command
   (consent-oracle--configured-command
    consent-oracle-guile-command
    "CONSENT_GUILE"
    "guile")
   :arguments '("--no-auto-compile" "--r7rs")))

;;;###autoload
(defun consent-oracle-sagittarius-reference ()
  "Return the Sagittarius reference adapter."
  (consent-oracle-reference
   :name 'sagittarius
   :command
   (consent-oracle--configured-command
    consent-oracle-sagittarius-command
    "CONSENT_SAGITTARIUS"
    "sagittarius")
   :arguments '("-r" "7")))

;;;###autoload
(defun consent-oracle-racket-reference ()
  "Return the Racket reference adapter."
  (consent-oracle-reference
   :name 'racket
   :command
   (consent-oracle--configured-command
    consent-oracle-racket-command
    "CONSENT_RACKET"
    "racket")
   :program-filter #'consent-oracle--racket-r7rs-program))

;;;###autoload
(defun consent-oracle-chicken-reference ()
  "Return the CHICKEN Scheme reference adapter."
  (consent-oracle-reference
   :name 'chicken
   :command
   (consent-oracle--configured-command
    consent-oracle-chicken-command
    "CONSENT_CHICKEN"
    "csi")
   :arguments '("-q" "-R" "r7rs" "-s")))

;;;###autoload
(defun consent-oracle-gambit-compiler-executable ()
  "Return the configured or discovered Gambit compiler executable."
  (consent-oracle--configured-command
   consent-oracle-gambit-compiler-command
   "CONSENT_GAMBIT_COMPILER"
   "gsc"))

;;;###autoload
(defun consent-oracle-gambit-reference ()
  "Return the Gambit Scheme reference adapter."
  (consent-oracle-reference
   :name 'gambit
   :command
   (consent-oracle--configured-command
    consent-oracle-gambit-command
    "CONSENT_GAMBIT"
    "gsi")
   :arguments (consent-oracle--gambit-r7rs-arguments)))

(defun consent-oracle--reference-builder (name)
  "Return the reference builder function for NAME."
  (pcase name
    ('chibi #'consent-oracle-chibi-reference)
    ('gauche #'consent-oracle-gauche-reference)
    ('guile #'consent-oracle-guile-reference)
    ('sagittarius #'consent-oracle-sagittarius-reference)
    ('racket #'consent-oracle-racket-reference)
    ('chicken #'consent-oracle-chicken-reference)
    ('gambit #'consent-oracle-gambit-reference)
    (_ (error "Unknown oracle reference: %S" name))))

;;;###autoload
(defun consent-oracle-selected-references (names)
  "Return reference adapters selected by NAMES."
  (mapcar
   (lambda (name)
     (funcall (consent-oracle--reference-builder name)))
   names))

;;;###autoload
(defun consent-oracle-all-references ()
  "Return all candidate reference implementation adapters."
  (consent-oracle-selected-references
   consent-oracle-reference-names))

;;;###autoload
(defun consent-oracle-default-references ()
  "Return the default reference implementation adapters."
  (consent-oracle-selected-references '(chibi sagittarius)))

;;;###autoload
(defun consent-oracle-parse-reference-filter (value)
  "Parse comma-separated oracle reference adapter filter VALUE."
  (when (and value (> (length (string-trim value)) 0))
    (let ((names
           (mapcar
            (lambda (part)
              (intern (string-trim part)))
            (split-string value "," t "[[:space:]\n\t]+"))))
      (dolist (name names)
        (unless (memq name consent-oracle-reference-names)
          (error "Unknown oracle reference filter: %S" name)))
      names)))

;;;###autoload
(defun consent-oracle-run-suite (&optional references)
  "Run the shared fixture suite against REFERENCES."
  (mapcar (lambda (case)
            (consent-oracle-run-case case references))
          (consent-oracle-fixture-cases)))

;;;###autoload
(defun consent-oracle-batch-main ()
  "Run the oracle suite and print Scheme-readable reports."
  (let* ((reference-names
          (consent-oracle-parse-reference-filter
           (getenv "CONSENT_ORACLE_REFERENCES")))
         (references
          (and reference-names
               (consent-oracle-selected-references reference-names)))
         (reports (consent-oracle-run-suite references))
         (statuses
          (consent-oracle-parse-status-filter
           (getenv "CONSENT_ORACLE_STATUSES")))
         (selected (consent-oracle-filter-reports reports statuses)))
    (when (getenv "CONSENT_ORACLE_SUMMARY")
      (princ (consent-oracle-summary->external reports))
      (princ "\n"))
    (dolist (report selected)
      (princ (consent-oracle-report->external report))
      (princ "\n"))))

(provide 'consent-oracle)

;;; consent-oracle.el ends here
