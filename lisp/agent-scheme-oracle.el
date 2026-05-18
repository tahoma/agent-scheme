;;; agent-scheme-oracle.el --- R7RS reference oracle runner  -*- lexical-binding: t; -*-

;;; Commentary:

;; Compare pure shared Agent Scheme fixture cases with external R7RS
;; implementations.  Reference adapters are represented with
;; `agent-scheme-oracle-reference'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-scheme-eval)
(require 'agent-scheme-reader)

(defgroup agent-scheme-oracle nil
  "Reference implementation oracle runner for Agent Scheme fixtures."
  :group 'agent-scheme)

(defconst agent-scheme-oracle--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Agent Scheme oracle source.")

(defcustom agent-scheme-oracle-root-directory
  (file-name-directory
   (directory-file-name agent-scheme-oracle--source-directory))
  "Repository root used for fixture loading and reference processes."
  :type 'directory
  :group 'agent-scheme-oracle)

(defcustom agent-scheme-oracle-chibi-command nil
  "Optional Chibi Scheme executable for oracle runs.
When nil, `agent-scheme-oracle-chibi-reference' consults
AGENT_SCHEME_CHIBI and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'agent-scheme-oracle)

(defcustom agent-scheme-oracle-gauche-command nil
  "Optional Gauche executable for oracle runs.
When nil, `agent-scheme-oracle-gauche-reference' consults
AGENT_SCHEME_GAUCHE and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'agent-scheme-oracle)

(defcustom agent-scheme-oracle-guile-command nil
  "Optional Guile executable for oracle runs.
When nil, `agent-scheme-oracle-guile-reference' consults
AGENT_SCHEME_GUILE and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'agent-scheme-oracle)

(defcustom agent-scheme-oracle-sagittarius-command nil
  "Optional Sagittarius executable for oracle runs.
When nil, `agent-scheme-oracle-sagittarius-reference' consults
AGENT_SCHEME_SAGITTARIUS and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'agent-scheme-oracle)

(defcustom agent-scheme-oracle-racket-command nil
  "Optional Racket executable for oracle runs.
When nil, `agent-scheme-oracle-racket-reference' consults
AGENT_SCHEME_RACKET and then PATH."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'agent-scheme-oracle)

(defconst agent-scheme-oracle--policy-gated-libraries
  '((scheme file)
    (scheme load)
    (scheme process-context)
    (scheme repl)
    (scheme time))
  "R7RS libraries whose host effects are policy-gated in Agent Scheme.")

(defconst agent-scheme-oracle-statuses
  '(portable-agree
    implementation-variant
    agent-mismatch
    unsupported-reference
    policy-gated
    not-oracle-eligible)
  "Stable oracle report status order.")

(defconst agent-scheme-oracle-reference-names
  '(chibi gauche guile sagittarius racket)
  "Stable oracle reference adapter name order.")

(cl-defstruct (agent-scheme-oracle-reference
               (:constructor agent-scheme-oracle-reference
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

(cl-defstruct (agent-scheme-oracle-report
               (:constructor agent-scheme-oracle--make-report
                             (&key case-id results status)))
  "Oracle report for one fixture case.
RESULTS is a list of plists with `:name', `:status', and optional
`:payload' or `:message' entries."
  case-id results status)

(defun agent-scheme-oracle--host-datum (datum)
  "Convert Agent Scheme fixture DATUM to a host datum."
  (cond
   ((eq datum agent-scheme-true) t)
   ((eq datum agent-scheme-false) :scheme-false)
   ((null datum) nil)
   ((agent-scheme-symbol-p datum)
    (intern (agent-scheme-symbol-name datum)))
   ((agent-scheme-number-p datum)
    (or (agent-scheme-number-value datum)
        (agent-scheme-number-lexeme datum)))
   ((or (stringp datum) (characterp datum))
    datum)
   ((agent-scheme-character-p datum)
    (agent-scheme-character-code datum))
   ((agent-scheme-bytevector-p datum)
    (append (agent-scheme-bytevector-bytes datum) nil))
   ((consp datum)
    (cons (agent-scheme-oracle--host-datum (car datum))
          (agent-scheme-oracle--host-datum (cdr datum))))
   ((vectorp datum)
    (vconcat (mapcar #'agent-scheme-oracle--host-datum
                     (append datum nil))))
   (t
    (error "Unsupported fixture datum: %S" datum))))

(defun agent-scheme-oracle--fixture-file ()
  "Return the canonical shared fixture corpus path."
  (expand-file-name
   "fixtures/r7rs/conformance-cases.scm"
   agent-scheme-oracle-root-directory))

(defun agent-scheme-oracle-fixture-suite ()
  "Read and return the canonical fixture suite as host data."
  (let* ((source (with-temp-buffer
                   (insert-file-contents (agent-scheme-oracle--fixture-file))
                   (buffer-string)))
         (suite (agent-scheme-oracle--host-datum
                 (agent-scheme-read source))))
    (unless (eq (car-safe suite) 'agent-scheme-fixture-suite)
      (error "Fixture corpus must start with agent-scheme-fixture-suite"))
    suite))

(defun agent-scheme-oracle-fixture-cases ()
  "Return all shared fixture cases as host data."
  (let ((cases-field (assq 'cases (cdr (agent-scheme-oracle-fixture-suite)))))
    (unless cases-field
      (error "Fixture corpus must include a cases field"))
    (cdr cases-field)))

(defun agent-scheme-oracle--field (case field)
  "Return FIELD from fixture CASE."
  (cadr (assq field case)))

(defun agent-scheme-oracle--datum-symbol-name (datum)
  "Return DATUM's symbol name, or nil when DATUM is not a Scheme symbol."
  (when (agent-scheme-symbol-p datum)
    (agent-scheme-symbol-name datum)))

(defun agent-scheme-oracle--datum-symbol-p (datum name)
  "Return non-nil when DATUM is a Scheme symbol named NAME."
  (equal (agent-scheme-oracle--datum-symbol-name datum) name))

(defun agent-scheme-oracle--library-part (datum)
  "Return a host library-name part for DATUM."
  (cond
   ((agent-scheme-symbol-p datum)
    (intern (agent-scheme-symbol-name datum)))
   ((agent-scheme-number-p datum)
    (or (agent-scheme-number-value datum)
        (intern (agent-scheme-number-lexeme datum))))
   (t nil)))

(defun agent-scheme-oracle--direct-library-name (import-set)
  "Return direct library name for IMPORT-SET, or nil."
  (let ((parts nil)
        (cursor import-set)
        (valid t))
    (while (and valid (consp cursor))
      (let ((part (agent-scheme-oracle--library-part (car cursor))))
        (if part
            (push part parts)
          (setq valid nil)))
      (setq cursor (cdr cursor)))
    (when (and valid (null cursor) parts)
      (nreverse parts))))

(defun agent-scheme-oracle--import-set-library-names (import-set)
  "Return direct library names referenced by IMPORT-SET."
  (let ((modifier (and (consp import-set)
                       (agent-scheme-oracle--datum-symbol-name
                        (car import-set)))))
    (cond
     ((member modifier '("only" "except" "prefix" "rename"))
      (agent-scheme-oracle--import-set-library-names (cadr import-set)))
     (t
      (let ((direct (agent-scheme-oracle--direct-library-name import-set)))
        (if direct (list direct) nil))))))

(defun agent-scheme-oracle--source-library-imports (source)
  "Return library names imported by SOURCE."
  (let ((imports nil))
    (dolist (form (agent-scheme-read-all source))
      (when (and (consp form)
                 (agent-scheme-oracle--datum-symbol-p (car form) "import"))
        (dolist (import-set (cdr form))
          (setq imports
                (append (agent-scheme-oracle--import-set-library-names
                         import-set)
                        imports)))))
    (nreverse imports)))

(defun agent-scheme-oracle--policy-gated-source-p (source)
  "Return non-nil when SOURCE imports a policy-gated library."
  (cl-some
   (lambda (library)
     (member library agent-scheme-oracle--policy-gated-libraries))
   (agent-scheme-oracle--source-library-imports source)))

;;;###autoload
(defun agent-scheme-oracle-case-classification (case)
  "Return oracle classification for fixture CASE before execution."
  (let ((kind (agent-scheme-oracle--field case 'kind))
        (phase (agent-scheme-oracle--field case 'phase))
        (status (agent-scheme-oracle--field case 'status))
        (oracle (agent-scheme-oracle--field case 'oracle))
        (oracle-eligibility
         (agent-scheme-oracle--field case 'oracle-eligibility))
        (options (agent-scheme-oracle--field case 'options))
        (source (agent-scheme-oracle--field case 'source)))
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
          (agent-scheme-oracle--policy-gated-source-p source)
        (error t))
      'policy-gated)
     (t
      'eligible))))

(defun agent-scheme-oracle--fixture-options-plist (case)
  "Return CASE options as an Emacs Lisp plist."
  (let (plist)
    (dolist (entry (agent-scheme-oracle--field case 'options))
      (unless (and (listp entry)
                   (symbolp (car entry))
                   (= (length entry) 2))
        (error "Invalid options entry for fixture %S: %S"
               (agent-scheme-oracle--field case 'id)
               entry))
      (setq plist
            (plist-put plist
                       (intern (concat ":" (symbol-name (car entry))))
                       (cadr entry))))
    plist))

(defun agent-scheme-oracle--agent-actual (case)
  "Run CASE through Agent Scheme and return a normalized actual plist."
  (let ((phase (agent-scheme-oracle--field case 'phase))
        (source (agent-scheme-oracle--field case 'source))
        (options (agent-scheme-oracle--fixture-options-plist case)))
    (condition-case condition
        (pcase phase
          ('read
           (list :status 'value
                 :value
                 (agent-scheme-datum->external
                  (agent-scheme-read source options))))
          ('read-all
           (list :status 'values
                 :values
                 (mapcar #'agent-scheme-datum->external
                         (agent-scheme-read-all source options))))
          ('eval
           (let ((value (agent-scheme-eval-source source nil options)))
             (if (agent-scheme--multiple-values-p value)
                 (list :status 'values
                       :values
                       (mapcar #'agent-scheme-value->external
                               (agent-scheme--multiple-values-values value)))
               (list :status 'value
                     :value (agent-scheme-value->external value)))))
          (_
           (error "Unsupported oracle phase: %S" phase)))
      (error
       (list :status 'error :condition condition)))))

(defun agent-scheme-oracle--scheme-string (string)
  "Return STRING as an R7RS string literal."
  (agent-scheme-datum->external string))

(defun agent-scheme-oracle--emit-support-source ()
  "Return Scheme support code for emitting normalized oracle results."
  (mapconcat
   #'identity
   '("(define (agent-scheme-oracle-emit results)"
     "  (cond"
     "   ((null? results) (write (list 'values '())))"
     "   ((null? (cdr results)) (write (list 'value (car results))))"
     "   (else (write (list 'values results))))"
     "  (newline))")
   "\n"))

(defun agent-scheme-oracle--read-program (source read-all-p)
  "Return a Scheme program that reads SOURCE.
When READ-ALL-P is non-nil, read every datum and emit them as
multiple values."
  (mapconcat
   #'identity
   (list
    "(import (scheme base) (scheme read) (scheme write))"
    (agent-scheme-oracle--emit-support-source)
    (format "(define agent-scheme-oracle-input (open-input-string %s))"
            (agent-scheme-oracle--scheme-string source))
    (if read-all-p
        (mapconcat
         #'identity
         '("(define (agent-scheme-oracle-read-all input)"
           "  (let loop ((values '()))"
           "    (let ((value (read input)))"
           "      (if (eof-object? value)"
           "          (reverse values)"
           "          (loop (cons value values))))))"
           "(agent-scheme-oracle-emit"
           " (agent-scheme-oracle-read-all agent-scheme-oracle-input))")
         "\n")
      "(agent-scheme-oracle-emit (list (read agent-scheme-oracle-input)))"))
   "\n"))

(defun agent-scheme-oracle--top-level-form-p (datum)
  "Return non-nil when DATUM is a top-level declaration form."
  (and (consp datum)
       (member (agent-scheme-oracle--datum-symbol-name (car datum))
               '("define" "define-record-type" "define-syntax"
                 "define-values" "define-library" "import"))))

(defun agent-scheme-oracle--eval-program (source)
  "Return a Scheme program that evaluates SOURCE and emits the final values."
  (let* ((forms (agent-scheme-read-all source))
         (prelude (butlast forms))
         (final (car (last forms))))
    (when (null forms)
      (error "Oracle source contains no forms"))
    (mapconcat
     #'identity
     (append
      (list
       "(import (scheme base) (scheme write))"
       (agent-scheme-oracle--emit-support-source))
      (mapcar #'agent-scheme-datum->external prelude)
      (list
       (if (agent-scheme-oracle--top-level-form-p final)
           (mapconcat
            #'identity
            (list
             (agent-scheme-datum->external final)
             "(call-with-values (lambda () (if #f #f)) (lambda results (agent-scheme-oracle-emit results)))")
            "\n")
         (format
          "(call-with-values (lambda () %s) (lambda results (agent-scheme-oracle-emit results)))"
          (agent-scheme-datum->external final)))))
     "\n")))

(defun agent-scheme-oracle--program-for-case (case)
  "Return a reference Scheme program for CASE."
  (pcase (agent-scheme-oracle--field case 'phase)
    ('read
     (agent-scheme-oracle--read-program
      (agent-scheme-oracle--field case 'source)
      nil))
    ('read-all
     (agent-scheme-oracle--read-program
      (agent-scheme-oracle--field case 'source)
      t))
    ('eval
     (agent-scheme-oracle--eval-program
      (agent-scheme-oracle--field case 'source)))
    (phase
     (error "Unsupported oracle phase: %S" phase))))

(defun agent-scheme-oracle--program-for-reference (reference case)
  "Return a generated source program for REFERENCE and fixture CASE."
  (let* ((program (agent-scheme-oracle--program-for-case case))
         (program-filter
          (agent-scheme-oracle-reference-program-filter reference)))
    (if program-filter
        (funcall program-filter program)
      program)))

(defun agent-scheme-oracle--reference-datum-result (datum)
  "Return normalized oracle result for DATUM, or nil."
  (cond
   ((and (consp datum)
         (agent-scheme-oracle--datum-symbol-p (car datum) "value")
         (consp (cdr datum))
         (null (cddr datum)))
    (list :status 'value
          :value (agent-scheme-datum->external
                  (cadr datum))))
   ((and (consp datum)
         (agent-scheme-oracle--datum-symbol-p (car datum) "values")
         (consp (cdr datum))
         (listp (cadr datum))
         (null (cddr datum)))
    (list :status 'values
          :values
          (mapcar #'agent-scheme-datum->external
                  (cadr datum))))))

(defun agent-scheme-oracle--normalize-reference-output-line (line)
  "Normalize known reference writer spellings in raw output LINE."
  (replace-regexp-in-string
   "#vu8("
   "#u8("
   line
   t
   t))

(defun agent-scheme-oracle--parse-reference-output (output)
  "Parse reference implementation OUTPUT into a normalized actual plist."
  (let ((trimmed (string-trim output)))
    (or
     (catch 'result
       (dolist (line (reverse (split-string trimmed "\n" t "[[:space:]\r]+")))
         (condition-case nil
             (let ((result
                    (agent-scheme-oracle--reference-datum-result
                     (agent-scheme-read
                      (agent-scheme-oracle--normalize-reference-output-line
                       line)))))
               (when result
                 (throw 'result result)))
           (error nil))))
     (list :status 'error
           :message (format "Malformed oracle output: %s" trimmed)))))

;;;###autoload
(defun agent-scheme-oracle-run-reference (reference case)
  "Run REFERENCE against fixture CASE and return a normalized actual plist."
  (cond
   ((agent-scheme-oracle-reference-evaluator reference)
    (funcall (agent-scheme-oracle-reference-evaluator reference) case))
   ((not (agent-scheme-oracle-reference-command reference))
    (list :status 'unsupported-reference
          :message "reference command not found"))
   (t
    (let* ((program (agent-scheme-oracle--program-for-reference reference case))
           (program-file (make-temp-file "agent-scheme-oracle-" nil ".scm"))
           (output-buffer (generate-new-buffer " *agent-scheme-oracle*"))
           (default-directory agent-scheme-oracle-root-directory))
      (unwind-protect
          (progn
            (with-temp-file program-file
              (insert program)
              (insert "\n"))
            (condition-case condition
                (let ((status
                       (apply
                        #'process-file
                        (agent-scheme-oracle-reference-command reference)
                        nil
                        output-buffer
                        nil
                        (append
                         (agent-scheme-oracle-reference-arguments reference)
                         (list program-file)))))
                  (with-current-buffer output-buffer
                    (let ((output (buffer-string)))
                      (if (equal status 0)
                          (condition-case parse-condition
                              (agent-scheme-oracle--parse-reference-output output)
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

(defun agent-scheme-oracle--actual-key (actual)
  "Return a comparable semantic key for ACTUAL."
  (pcase (plist-get actual :status)
    ('value
     (list 'value (plist-get actual :value)))
    ('values
     (cons 'values (plist-get actual :values)))
    ('error
     '(error))
    (_ nil)))

(defun agent-scheme-oracle--normalize-external (external)
  "Normalize known reference writer variation in EXTERNAL."
  (if (stringp external)
      (replace-regexp-in-string
       "\\+\\+nan\\.0i"
       "+nan.0i"
       external
       t
       t)
    external))

(defun agent-scheme-oracle--normalize-payload (payload)
  "Normalize oracle report PAYLOAD values before comparison."
  (if (listp payload)
      (mapcar #'agent-scheme-oracle--normalize-external payload)
    (agent-scheme-oracle--normalize-external payload)))

(defun agent-scheme-oracle--result-entry (name actual)
  "Return a report result entry named NAME for ACTUAL."
  (pcase (plist-get actual :status)
    ('value
     (list :name name :status 'ok
           :payload
           (agent-scheme-oracle--normalize-payload
            (plist-get actual :value))))
    ('values
     (list :name name :status 'ok
           :payload
           (agent-scheme-oracle--normalize-payload
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

(defun agent-scheme-oracle--supported-result-p (entry)
  "Return non-nil when ENTRY came from a supported reference run."
  (not (eq (plist-get entry :status) 'unsupported-reference)))

(defun agent-scheme-oracle--entry-key (entry)
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

(defun agent-scheme-oracle--classify-results (agent-entry reference-entries)
  "Classify oracle comparison between AGENT-ENTRY and REFERENCE-ENTRIES."
  (let ((supported (cl-remove-if-not
                    #'agent-scheme-oracle--supported-result-p
                    reference-entries)))
    (cond
     ((null supported)
      'unsupported-reference)
     ((cl-some
       (lambda (entry)
         (not (equal (agent-scheme-oracle--entry-key entry)
                     (agent-scheme-oracle--entry-key (car supported)))))
       (cdr supported))
      'implementation-variant)
     ((equal (agent-scheme-oracle--entry-key agent-entry)
             (agent-scheme-oracle--entry-key (car supported)))
      'portable-agree)
     (t
      'agent-mismatch))))

;;;###autoload
(defun agent-scheme-oracle-run-case (case &optional references)
  "Run fixture CASE against REFERENCES and return an oracle report."
  (let ((classification (agent-scheme-oracle-case-classification case))
        (case-id (agent-scheme-oracle--field case 'id)))
    (if (not (eq classification 'eligible))
        (agent-scheme-oracle--make-report
         :case-id case-id
         :results nil
         :status classification)
      (let* ((active-references (or references
                                    (agent-scheme-oracle-default-references)))
             (reference-entries
              (mapcar
               (lambda (reference)
                 (agent-scheme-oracle--result-entry
                  (agent-scheme-oracle-reference-name reference)
                  (agent-scheme-oracle-run-reference reference case)))
               active-references))
             (agent-entry
              (agent-scheme-oracle--result-entry
               'agent-scheme
               (agent-scheme-oracle--agent-actual case)))
             (status
              (agent-scheme-oracle--classify-results
               agent-entry reference-entries)))
        (agent-scheme-oracle--make-report
         :case-id case-id
         :results (append reference-entries (list agent-entry))
         :status status)))))

(defun agent-scheme-oracle--host-external (datum)
  "Return DATUM rendered as a small Scheme-readable external datum."
  (cond
   ((null datum) "()")
   ((symbolp datum) (symbol-name datum))
   ((stringp datum) (agent-scheme-datum->external datum))
   ((consp datum)
    (concat "("
            (mapconcat #'agent-scheme-oracle--host-external datum " ")
            ")"))
   (t
    (format "%S" datum))))

(defun agent-scheme-oracle--entry-datum (entry)
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
(defun agent-scheme-oracle-report->external (report)
  "Return REPORT as a Scheme-readable external representation."
  (agent-scheme-oracle--host-external
   `(oracle-report
     (case ,(agent-scheme-oracle-report-case-id report))
     (results ,(mapcar #'agent-scheme-oracle--entry-datum
                       (agent-scheme-oracle-report-results report)))
     (status ,(agent-scheme-oracle-report-status report)))))

;;;###autoload
(defun agent-scheme-oracle-filter-reports (reports statuses)
  "Return REPORTS whose status is included in STATUSES.
When STATUSES is nil, return REPORTS unchanged."
  (if statuses
      (cl-remove-if-not
       (lambda (report)
         (memq (agent-scheme-oracle-report-status report) statuses))
       reports)
    reports))

(defun agent-scheme-oracle--summary-datum (reports)
  "Return a Scheme-readable summary datum for REPORTS."
  `(oracle-summary
    (total ,(length reports))
    ,@(mapcar
       (lambda (status)
         (list status
               (cl-count-if
                (lambda (report)
                  (eq (agent-scheme-oracle-report-status report) status))
                reports)))
       agent-scheme-oracle-statuses)))

;;;###autoload
(defun agent-scheme-oracle-summary->external (reports)
  "Return a Scheme-readable summary for REPORTS."
  (agent-scheme-oracle--host-external
   (agent-scheme-oracle--summary-datum reports)))

;;;###autoload
(defun agent-scheme-oracle-parse-status-filter (value)
  "Parse comma-separated oracle status filter VALUE."
  (when (and value (> (length (string-trim value)) 0))
    (let ((statuses
           (mapcar
            (lambda (part)
              (intern (string-trim part)))
            (split-string value "," t "[[:space:]\n\t]+"))))
      (dolist (status statuses)
        (unless (memq status agent-scheme-oracle-statuses)
          (error "Unknown oracle status filter: %S" status)))
      statuses)))

(defun agent-scheme-oracle--configured-command (custom env-name executable)
  "Return CUSTOM, ENV-NAME, or discovered EXECUTABLE command."
  (or custom
      (let ((env (getenv env-name)))
        (and env (not (string-empty-p env)) env))
      (executable-find executable)))

(defun agent-scheme-oracle--racket-r7rs-program (program)
  "Return PROGRAM wrapped for Racket's R7RS language mode."
  (concat "#lang r7rs\n" program))

(defun agent-scheme-oracle--racket-r7rs-available-p (command)
  "Return non-nil when COMMAND can load Racket's R7RS language package."
  (when command
    (with-temp-buffer
      (condition-case nil
          (equal 0 (process-file command nil t nil "-l" "r7rs/lang/reader"))
        (file-error nil)))))

;;;###autoload
(defun agent-scheme-oracle-chibi-reference ()
  "Return the Chibi Scheme reference adapter."
  (agent-scheme-oracle-reference
   :name 'chibi
   :command
   (agent-scheme-oracle--configured-command
    agent-scheme-oracle-chibi-command
    "AGENT_SCHEME_CHIBI"
    "chibi-scheme")))

;;;###autoload
(defun agent-scheme-oracle-gauche-reference ()
  "Return the Gauche reference adapter."
  (agent-scheme-oracle-reference
   :name 'gauche
   :command
   (agent-scheme-oracle--configured-command
    agent-scheme-oracle-gauche-command
    "AGENT_SCHEME_GAUCHE"
    "gosh")))

;;;###autoload
(defun agent-scheme-oracle-guile-reference ()
  "Return the Guile reference adapter."
  (agent-scheme-oracle-reference
   :name 'guile
   :command
   (agent-scheme-oracle--configured-command
    agent-scheme-oracle-guile-command
    "AGENT_SCHEME_GUILE"
    "guile")
   :arguments '("--no-auto-compile" "--r7rs")))

;;;###autoload
(defun agent-scheme-oracle-sagittarius-reference ()
  "Return the Sagittarius reference adapter."
  (agent-scheme-oracle-reference
   :name 'sagittarius
   :command
   (agent-scheme-oracle--configured-command
    agent-scheme-oracle-sagittarius-command
    "AGENT_SCHEME_SAGITTARIUS"
    "sagittarius")
   :arguments '("-r" "7")))

;;;###autoload
(defun agent-scheme-oracle-racket-reference ()
  "Return the Racket reference adapter."
  (agent-scheme-oracle-reference
   :name 'racket
   :command
   (agent-scheme-oracle--configured-command
    agent-scheme-oracle-racket-command
    "AGENT_SCHEME_RACKET"
    "racket")
   :program-filter #'agent-scheme-oracle--racket-r7rs-program))

(defun agent-scheme-oracle--reference-builder (name)
  "Return the reference builder function for NAME."
  (pcase name
    ('chibi #'agent-scheme-oracle-chibi-reference)
    ('gauche #'agent-scheme-oracle-gauche-reference)
    ('guile #'agent-scheme-oracle-guile-reference)
    ('sagittarius #'agent-scheme-oracle-sagittarius-reference)
    ('racket #'agent-scheme-oracle-racket-reference)
    (_ (error "Unknown oracle reference: %S" name))))

;;;###autoload
(defun agent-scheme-oracle-selected-references (names)
  "Return reference adapters selected by NAMES."
  (mapcar
   (lambda (name)
     (funcall (agent-scheme-oracle--reference-builder name)))
   names))

;;;###autoload
(defun agent-scheme-oracle-all-references ()
  "Return all candidate reference implementation adapters."
  (agent-scheme-oracle-selected-references
   agent-scheme-oracle-reference-names))

;;;###autoload
(defun agent-scheme-oracle-default-references ()
  "Return the default reference implementation adapters."
  (agent-scheme-oracle-selected-references '(chibi sagittarius)))

;;;###autoload
(defun agent-scheme-oracle-parse-reference-filter (value)
  "Parse comma-separated oracle reference adapter filter VALUE."
  (when (and value (> (length (string-trim value)) 0))
    (let ((names
           (mapcar
            (lambda (part)
              (intern (string-trim part)))
            (split-string value "," t "[[:space:]\n\t]+"))))
      (dolist (name names)
        (unless (memq name agent-scheme-oracle-reference-names)
          (error "Unknown oracle reference filter: %S" name)))
      names)))

;;;###autoload
(defun agent-scheme-oracle-run-suite (&optional references)
  "Run the shared fixture suite against REFERENCES."
  (mapcar (lambda (case)
            (agent-scheme-oracle-run-case case references))
          (agent-scheme-oracle-fixture-cases)))

;;;###autoload
(defun agent-scheme-oracle-batch-main ()
  "Run the oracle suite and print Scheme-readable reports."
  (let* ((reference-names
          (agent-scheme-oracle-parse-reference-filter
           (getenv "AGENT_SCHEME_ORACLE_REFERENCES")))
         (references
          (and reference-names
               (agent-scheme-oracle-selected-references reference-names)))
         (reports (agent-scheme-oracle-run-suite references))
         (statuses
          (agent-scheme-oracle-parse-status-filter
           (getenv "AGENT_SCHEME_ORACLE_STATUSES")))
         (selected (agent-scheme-oracle-filter-reports reports statuses)))
    (when (getenv "AGENT_SCHEME_ORACLE_SUMMARY")
      (princ (agent-scheme-oracle-summary->external reports))
      (princ "\n"))
    (dolist (report selected)
      (princ (agent-scheme-oracle-report->external report))
      (princ "\n"))))

(provide 'agent-scheme-oracle)

;;; agent-scheme-oracle.el ends here
