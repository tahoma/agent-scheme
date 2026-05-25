;;; Portable Agent Scheme base-library registry and bootstrap metadata.
;;;
;;; This library owns `(scheme base)' primitive metadata, prelude discovery, and
;;; base-environment construction hooks without importing the evaluator module.

(define-library (agent-scheme base)
  (export scheme-base-library-key
          agent-scheme-install-base-backend!
          base-primitive-registry
          base-prelude-forms
          base-syntax-forms
          read-port-string
          read-all-datums
          define-primitive!
          ensure-base-syntax!
          agent-scheme-make-base-environment
          agent-scheme-base-primitive-names
          agent-scheme-base-primitive-specs
          agent-scheme-base-prelude-binding-names
          agent-scheme-base-prelude-binding-specs
          agent-scheme-base-binding-specs
          agent-scheme-primitive-manifest-binding-specs)
  (import (scheme base)
          (scheme file)
          (agent-scheme reader)
          (except (agent-scheme runtime) make-parameter))
  (begin
    ;; Registry key for the required R7RS `(scheme base)' library.
    (define scheme-base-library-key '(scheme base))

    ;; Backend hook resolving primitive implementation identifiers.
    (define base-primitive-resolver
      (lambda (name)
        (eval-error "base primitive backend is not installed" name)))
    ;; Backend hook for evaluating derived base prelude forms.
    (define base-trampoline
      (lambda (sequence environment context)
        (eval-error "base trampoline backend is not installed")))
    ;; Backend hook for installing derived base syntax forms.
    (define base-define-syntax
      (lambda (form environment context syntax-environment)
        (eval-error "base syntax backend is not installed")))

    ;; Install the evaluator backend hooks used for base bootstrapping.
    (define (agent-scheme-install-base-backend!
             primitive-resolver trampoline define-syntax)
      (set! base-primitive-resolver primitive-resolver)
      (set! base-trampoline trampoline)
      (set! base-define-syntax define-syntax)
      agent-scheme-unspecified)

    ;; Resolve a registry implementation name through the installed backend.
    (define (base-primitive-implementation name)
      (base-primitive-resolver name))

    ;; Registry mapping primitive names to implementation identifiers and
    ;; arities.
    (define base-primitive-registry
      ;; Each entry is `(name implementation minimum-arity maximum-arity)'.
      ;; A false maximum means the primitive accepts arbitrarily many arguments.
      (list
       (list '* 'primitive* 0 #f)
       (list '+ 'primitive+ 0 #f)
       (list '- 'primitive- 1 #f)
       (list '/ 'primitive/ 1 #f)
       (list '< 'primitive< 2 #f)
       (list '<= 'primitive<= 2 #f)
       (list '= 'primitive= 2 #f)
       (list '> 'primitive> 2 #f)
       (list '>= 'primitive>= 2 #f)
       (list 'apply 'primitive-apply 2 #f)
       (list 'binary-port? 'primitive-binary-port? 1 1)
       (list 'boolean=? 'primitive-boolean=? 2 #f)
       (list 'boolean? 'primitive-boolean? 1 1)
       (list 'bytevector 'primitive-bytevector 0 #f)
       (list 'bytevector-append 'primitive-bytevector-append 0 #f)
       (list 'bytevector-copy 'primitive-bytevector-copy 1 3)
       (list 'bytevector-copy! 'primitive-bytevector-copy! 3 5)
       (list 'bytevector-length 'primitive-bytevector-length 1 1)
       (list 'bytevector-u8-ref 'primitive-bytevector-u8-ref 2 2)
       (list 'bytevector-u8-set! 'primitive-bytevector-u8-set! 3 3)
       (list 'bytevector? 'primitive-bytevector? 1 1)
       (list 'call-with-current-continuation 'primitive-call/cc 1 1)
       (list 'call-with-port 'primitive-call-with-port 2 2)
       (list 'call-with-values 'primitive-call-with-values 2 2)
       (list 'call/cc 'primitive-call/cc 1 1)
       (list 'car 'primitive-car 1 1)
       (list 'cdr 'primitive-cdr 1 1)
       (list 'ceiling 'primitive-ceiling 1 1)
       (list 'char->integer 'primitive-char->integer 1 1)
       (list 'char<=? 'primitive-char<=? 2 #f)
       (list 'char<? 'primitive-char<? 2 #f)
       (list 'char=? 'primitive-char=? 2 #f)
       (list 'char>=? 'primitive-char>=? 2 #f)
       (list 'char>? 'primitive-char>? 2 #f)
       (list 'char-ready? 'primitive-char-ready? 0 1)
       (list 'char? 'primitive-char? 1 1)
       (list 'close-input-port 'primitive-close-input-port 1 1)
       (list 'close-output-port 'primitive-close-output-port 1 1)
       (list 'close-port 'primitive-close-port 1 1)
       (list 'complex? 'primitive-complex? 1 1)
       (list 'cons 'primitive-cons 2 2)
       (list 'current-error-port 'primitive-current-error-port 0 0)
       (list 'current-input-port 'primitive-current-input-port 0 0)
       (list 'current-output-port 'primitive-current-output-port 0 0)
       (list 'dynamic-wind 'primitive-dynamic-wind 3 3)
       (list 'eq? 'primitive-eq? 2 2)
       (list 'equal? 'primitive-equal? 2 2)
       (list 'eqv? 'primitive-eqv? 2 2)
       (list 'eof-object 'primitive-eof-object 0 0)
       (list 'eof-object? 'primitive-eof-object? 1 1)
       (list 'error 'primitive-error 1 #f)
       (list 'error-object-irritants 'primitive-error-object-irritants 1 1)
       (list 'error-object-message 'primitive-error-object-message 1 1)
       (list 'error-object? 'primitive-error-object? 1 1)
       (list 'denominator 'primitive-denominator 1 1)
       (list 'exact 'primitive-exact 1 1)
       (list 'exact-integer-sqrt 'primitive-exact-integer-sqrt 1 1)
       (list 'exact-integer? 'primitive-exact-integer? 1 1)
       (list 'exact? 'primitive-exact? 1 1)
       (list 'expt 'primitive-expt 2 2)
       (list 'features 'primitive-features 0 0)
       (list 'file-error? 'primitive-file-error? 1 1)
       (list 'floor 'primitive-floor 1 1)
       (list 'floor/ 'primitive-floor/ 2 2)
       (list 'floor-quotient 'primitive-floor-quotient 2 2)
       (list 'floor-remainder 'primitive-floor-remainder 2 2)
       (list 'flush-output-port 'primitive-flush-output-port 0 1)
       (list 'gcd 'primitive-gcd 0 #f)
       (list 'get-output-bytevector 'primitive-get-output-bytevector 1 1)
       (list 'get-output-string 'primitive-get-output-string 1 1)
       (list 'inexact 'primitive-inexact 1 1)
       (list 'inexact? 'primitive-inexact? 1 1)
       (list 'input-port-open? 'primitive-input-port-open? 1 1)
       (list 'input-port? 'primitive-input-port? 1 1)
       (list 'integer->char 'primitive-integer->char 1 1)
       (list 'integer? 'primitive-integer? 1 1)
       (list 'lcm 'primitive-lcm 0 #f)
       (list 'list->string 'primitive-list->string 1 1)
       (list 'list->vector 'primitive-list->vector 1 1)
       (list 'list? 'primitive-list? 1 1)
       (list 'make-bytevector 'primitive-make-bytevector 1 2)
       (list 'make-parameter 'primitive-make-parameter 1 2)
       (list 'make-string 'primitive-make-string 1 2)
       (list 'make-vector 'primitive-make-vector 1 2)
       (list 'modulo 'primitive-modulo 2 2)
       (list 'newline 'primitive-newline 0 1)
       (list 'null? 'primitive-null? 1 1)
       (list 'number->string 'primitive-number->string 1 2)
       (list 'number? 'primitive-number? 1 1)
       (list 'numerator 'primitive-numerator 1 1)
       (list 'open-input-bytevector 'primitive-open-input-bytevector 1 1)
       (list 'open-input-string 'primitive-open-input-string 1 1)
       (list 'open-output-bytevector 'primitive-open-output-bytevector 0 0)
       (list 'open-output-string 'primitive-open-output-string 0 0)
       (list 'output-port-open? 'primitive-output-port-open? 1 1)
       (list 'output-port? 'primitive-output-port? 1 1)
       (list 'pair? 'primitive-pair? 1 1)
       (list 'peek-char 'primitive-peek-char 0 1)
       (list 'peek-u8 'primitive-peek-u8 0 1)
       (list 'port? 'primitive-port? 1 1)
       (list 'procedure? 'primitive-procedure? 1 1)
       (list 'quotient 'primitive-quotient 2 2)
       (list 'raise 'primitive-raise 1 1)
       (list 'raise-continuable 'primitive-raise-continuable 1 1)
       (list 'rational? 'primitive-rational? 1 1)
       (list 'rationalize 'primitive-rationalize 2 2)
       (list 'read-bytevector 'primitive-read-bytevector 1 2)
       (list 'read-bytevector! 'primitive-read-bytevector! 1 4)
       (list 'read-char 'primitive-read-char 0 1)
       (list 'read-error? 'primitive-read-error? 1 1)
       (list 'read-line 'primitive-read-line 0 1)
       (list 'read-string 'primitive-read-string 1 2)
       (list 'read-u8 'primitive-read-u8 0 1)
       (list 'real? 'primitive-real? 1 1)
       (list 'remainder 'primitive-remainder 2 2)
       (list 'round 'primitive-round 1 1)
       (list 'set-car! 'primitive-set-car! 2 2)
       (list 'set-cdr! 'primitive-set-cdr! 2 2)
       (list 'string 'primitive-string 0 #f)
       (list 'string->list 'primitive-string->list 1 3)
       (list 'string->number 'primitive-string->number 1 2)
       (list 'string->symbol 'primitive-string->symbol 1 1)
       (list 'string->utf8 'primitive-string->utf8 1 3)
       (list 'string->vector 'primitive-string->vector 1 3)
       (list 'string-append 'primitive-string-append 0 #f)
       (list 'string-copy 'primitive-string-copy 1 3)
       (list 'string-copy! 'primitive-string-copy! 3 5)
       (list 'string-fill! 'primitive-string-fill! 2 4)
       (list 'string-length 'primitive-string-length 1 1)
       (list 'string-ref 'primitive-string-ref 2 2)
       (list 'string-set! 'primitive-string-set! 3 3)
       (list 'string<=? 'primitive-string<=? 2 #f)
       (list 'string<? 'primitive-string<? 2 #f)
       (list 'string=? 'primitive-string=? 2 #f)
       (list 'string>=? 'primitive-string>=? 2 #f)
       (list 'string>? 'primitive-string>? 2 #f)
       (list 'string? 'primitive-string? 1 1)
       (list 'substring 'primitive-substring 3 3)
       (list 'symbol->string 'primitive-symbol->string 1 1)
       (list 'symbol=? 'primitive-symbol=? 2 #f)
       (list 'symbol? 'primitive-symbol? 1 1)
       (list 'textual-port? 'primitive-textual-port? 1 1)
       (list 'truncate 'primitive-truncate 1 1)
       (list 'truncate/ 'primitive-truncate/ 2 2)
       (list 'truncate-quotient 'primitive-truncate-quotient 2 2)
       (list 'truncate-remainder 'primitive-truncate-remainder 2 2)
       (list 'u8-ready? 'primitive-u8-ready? 0 1)
       (list 'utf8->string 'primitive-utf8->string 1 3)
       (list 'vector 'primitive-vector 0 #f)
       (list 'vector->list 'primitive-vector->list 1 3)
       (list 'vector->string 'primitive-vector->string 1 3)
       (list 'vector-append 'primitive-vector-append 0 #f)
       (list 'vector-copy 'primitive-vector-copy 1 3)
       (list 'vector-copy! 'primitive-vector-copy! 3 5)
       (list 'vector-fill! 'primitive-vector-fill! 2 4)
       (list 'vector-length 'primitive-vector-length 1 1)
       (list 'vector-ref 'primitive-vector-ref 2 2)
       (list 'vector-set! 'primitive-vector-set! 3 3)
       (list 'vector? 'primitive-vector? 1 1)
       (list 'values 'primitive-values 0 #f)
       (list 'with-exception-handler
             'primitive-with-exception-handler
             2
             2)
       (list 'write-bytevector 'primitive-write-bytevector 1 4)
       (list 'write-char 'primitive-write-char 1 2)
       (list 'write-string 'primitive-write-string 1 4)
       (list 'write-u8 'primitive-write-u8 1 2)))

    ;; Kernel primitive names grouped by effect tier for manifest metadata.
    (define primitive-mutation-names
      '(bytevector-copy! bytevector-u8-set! read-bytevector!
        set-car! set-cdr! string-copy! string-fill! string-set!
        vector-copy! vector-fill! vector-set!))

    ;; Kernel primitive names that observe or update port state.
    (define primitive-port-io-names
      '(binary-port? call-with-port char-ready? close-input-port
        close-output-port close-port eof-object eof-object? file-error?
        flush-output-port get-output-bytevector get-output-string
        input-port-open? input-port? newline open-input-bytevector
        open-input-string open-output-bytevector open-output-string
        output-port-open? output-port? peek-char peek-u8 port?
        read-bytevector read-char read-error? read-line read-string
        read-u8 textual-port? u8-ready? write-bytevector write-char
        write-string write-u8))

    ;; Kernel primitive names that affect evaluator control flow.
    (define primitive-control-names
      '(apply call-with-current-continuation call-with-values call/cc
        dynamic-wind error raise raise-continuable values
        with-exception-handler))

    ;; Return the effect tier for primitive NAME.
    (define (primitive-effect-for-name name)
      (cond
       ((memq name primitive-mutation-names) 'mutation)
       ((memq name primitive-port-io-names) 'port-io)
       ((memq name primitive-control-names) 'control)
       ((eq? name 'make-parameter) 'dynamic-state)
       (else 'pure)))

    ;; Return a future backend lowering hint for EFFECT.
    (define (primitive-emitter-hook-for-effect effect)
      (cond
       ((eq? effect 'mutation) 'runtime-mutation)
       ((eq? effect 'port-io) 'capability-port)
       ((eq? effect 'control) 'runtime-control)
       ((eq? effect 'dynamic-state) 'runtime-parameter)
       ((eq? effect 'host-file) 'capability-file)
       ((eq? effect 'host-process) 'capability-process)
       ((eq? effect 'host-time) 'capability-time)
       ((eq? effect 'host-repl) 'capability-repl)
       ((eq? effect 'eval) 'runtime-eval)
       (else 'inline-or-call)))

    ;; Return the shared backend execution path for EFFECT.
    (define (primitive-backend-effect-path-for-effect effect)
      (cond
       ((eq? effect 'pure) 'direct-runtime)
       ((eq? effect 'mutation) 'runtime-mutation)
       ((eq? effect 'port-io) 'runtime-port-check)
       ((eq? effect 'control) 'runtime-control)
       ((eq? effect 'dynamic-state) 'runtime-parameter)
       ((memq effect '(host-file host-process host-time host-repl))
        'shared-capability-request)
       (else 'direct-runtime)))

    ;; Return test category tags for NAME and EFFECT.
    (define (primitive-test-categories-for-name name effect)
      (cond
       ((memq name '(vector vector? vector-ref vector-set! vector-length
                    vector-copy vector-copy! vector-fill! vector-append
                    vector->list vector->string vector-map vector-for-each
                    string->vector))
        '(vector))
       ((memq name '(bytevector bytevector? bytevector-length
                     bytevector-u8-ref bytevector-u8-set! bytevector-copy
                     bytevector-copy! bytevector-append read-bytevector
                     read-bytevector! write-bytevector))
        '(bytevector))
       ((eq? effect 'port-io)
        '(port))
       ((eq? effect 'control)
        '(control))
       (else
        '(base))))

    ;; Return canonical manifest metadata for one base primitive ENTRY.
    (define (base-primitive-manifest-spec entry)
      (let* ((name (car entry))
             (effect (primitive-effect-for-name name)))
        (list (list 'name name)
              (list 'library scheme-base-library-key)
              (list 'minimum-arity (third entry))
              (list 'maximum-arity (fourth entry))
              (list 'source 'kernel)
              (list 'effect effect)
              (list 'required-capability #f)
              (list 'emacs-hook #f)
              (list 'portable-hook #f)
              (list 'backend-effect-path
                    (primitive-backend-effect-path-for-effect effect))
              (list 'emitter-hook
                    (primitive-emitter-hook-for-effect effect))
              (list 'policy-category 'pure-r7rs)
              (list 'policy 'allow)
              (list 'test-categories
                    (primitive-test-categories-for-name name effect)))))

    ;; Primitive metadata is exported for tests and future conformance reports;
    ;; it describes the kernel surface without exposing implementation closures.
    (define (agent-scheme-base-primitive-names)
      (map car base-primitive-registry))

    ;; Public metadata accessor for kernel primitive arity and source specs.
    (define (agent-scheme-base-primitive-specs)
      (map (lambda (spec)
             (list (assq 'name spec)
                   (assq 'minimum-arity spec)
                   (assq 'maximum-arity spec)
                   (assq 'source spec)
                   (assq 'effect spec)))
           (map base-primitive-manifest-spec base-primitive-registry)))

    ;; Prelude source paths are the only host-files read during base environment
    ;; construction; they support project-root and library-path test layouts.
    (define agent-scheme-base-prelude-load-paths
      ;; Portable Scheme tests may run from the project root or with the
      ;; `agent-scheme' directory on the implementation's library path.
      '("scheme/agent-scheme/base-prelude.scm"
        "agent-scheme/base-prelude.scm"))

    ;; Syntax prelude paths mirror value prelude loading so derived syntax stays
    ;; portable source, not embedded host data.
    (define agent-scheme-base-syntax-load-paths
      '("scheme/agent-scheme/base-syntax.scm"
        "agent-scheme/base-syntax.scm"))

    ;; Cache for parsed base prelude forms shared across base environment
    ;; creation.
    (define base-prelude-forms-cache #f)
    ;; Cache for parsed syntax prelude forms shared across evaluation contexts.
    (define base-syntax-forms-cache #f)

    ;; Read all characters from PORT into a string.
    (define (read-port-string port)
      (let loop ((chars '()))
        (let ((char (read-char port)))
          (if (eof-object? char)
              (list->string (reverse chars))
              (loop (cons char chars))))))

    ;; Read and parse all datums from PORT.
    (define (read-all-datums port)
      (agent-scheme-read-all (read-port-string port)))

    ;; Prelude forms are cached after reader validation; metadata extraction
    ;; depends on each top-level form remaining one define.
    (define (base-prelude-forms)
      (or base-prelude-forms-cache
          (let ((forms
                 (let try ((paths agent-scheme-base-prelude-load-paths))
                   (if (null? paths)
                       (eval-error "unable to load base prelude")
                       (guard (condition
                               (else (try (cdr paths))))
                         (call-with-input-file
                             (car paths)
                           read-all-datums))))))
            (set! base-prelude-forms-cache forms)
            forms)))

    ;; Syntax prelude forms are cached separately because they install into the
    ;; current syntax environment, not the value environment.
    (define (base-syntax-forms)
      (or base-syntax-forms-cache
          (let ((forms
                 (let try ((paths agent-scheme-base-syntax-load-paths))
                   (if (null? paths)
                       (eval-error "unable to load base syntax prelude")
                       (guard (condition
                               (else (try (cdr paths))))
                         (call-with-input-file
                             (car paths)
                           read-all-datums))))))
            (set! base-syntax-forms-cache forms)
            forms)))

    ;; Return minimum and maximum arity metadata for Scheme formals.
    (define (formals-arity formals)
      (cond
       ((symbol? formals)
        (cons 0 #f))
       (else
        (let loop ((cursor formals) (minimum 0))
          (cond
           ((null? cursor)
            (cons minimum minimum))
           ((pair? cursor)
            (loop (cdr cursor) (+ minimum 1)))
           ((symbol? cursor)
            (cons minimum #f))
           (else
            (eval-error "prelude definition has invalid formals")))))))

    ;; Extract name, arity, and source metadata from one prelude define.
    (define (prelude-definition-spec form)
      (if (not (and (pair? form)
                    (eq? (car form) 'define)
                    (pair? (cdr form))
                    (pair? (cdr (cdr form)))))
          (eval-error "prelude form must be one definition" form))
      (let ((target (second form)))
        (cond
         ((symbol? target)
          (if (not (null? (cdr (cdr (cdr form)))))
              (eval-error
               "prelude variable definition must have one initializer"))
          (let ((initializer (third form)))
            (if (not (and (pair? initializer)
                          (eq? (car initializer) 'lambda)))
                (eval-error
                 "prelude variable definition must initialize a lambda"))
            (let ((arity (formals-arity (second initializer))))
              (list (list 'name target)
                    (list 'minimum-arity (car arity))
                    (list 'maximum-arity (cdr arity))
                    (list 'source 'prelude)))))
         ((pair? target)
          (let ((arity (formals-arity (cdr target))))
            (list (list 'name (car target))
                  (list 'minimum-arity (car arity))
                  (list 'maximum-arity (cdr arity))
                  (list 'source 'prelude))))
         (else
          (eval-error
           "prelude define target must be an identifier or function signature"
           form)))))

    ;; Prelude binding specs identify derived procedures separately from kernel
    ;; primitives so tests can catch accidental boundary movement.
    (define (agent-scheme-base-prelude-binding-specs)
      (map prelude-definition-spec (base-prelude-forms)))

    ;; Public metadata accessor for derived base prelude names.
    (define (agent-scheme-base-prelude-binding-names)
      (map (lambda (spec)
             (second (assq 'name spec)))
           (agent-scheme-base-prelude-binding-specs)))

    ;; Public metadata accessor for all base binding specs.
    (define (agent-scheme-base-binding-specs)
      (append (agent-scheme-base-primitive-specs)
              (agent-scheme-base-prelude-binding-specs)))

    ;; Explicit manifest metadata for currently host-effecting standard
    ;; primitives.  These records keep denied stubs visible before the full
    ;; capability system exists.
    (define standard-primitive-manifest-specs
      (list
       (list (list 'name 'delete-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-delete-file)
             (list 'portable-hook 'primitive-delete-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'file-exists?)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-file-exists?)
             (list 'portable-hook 'primitive-file-exists?)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-call-with-input-file)
             (list 'portable-hook 'primitive-call-with-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'call-with-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-call-with-output-file)
             (list 'portable-hook 'primitive-call-with-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-open-binary-input-file)
             (list 'portable-hook 'primitive-open-binary-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-binary-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-open-binary-output-file)
             (list 'portable-hook 'primitive-open-binary-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-input-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-open-input-file)
             (list 'portable-hook 'primitive-open-input-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'open-output-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 1)
             (list 'maximum-arity 1)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-open-output-file)
             (list 'portable-hook 'primitive-open-output-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-input-from-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-with-input-from-file)
             (list 'portable-hook 'primitive-with-input-from-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'with-output-to-file)
             (list 'library '(scheme file))
             (list 'minimum-arity 2)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-with-output-to-file)
             (list 'portable-hook 'primitive-with-output-to-file)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(file policy)))
       (list (list 'name 'load)
             (list 'library '(scheme load))
             (list 'minimum-arity 1)
             (list 'maximum-arity 2)
             (list 'source 'host-capability)
             (list 'effect 'host-file)
             (list 'required-capability 'file-system)
             (list 'emacs-hook 'agent-scheme--primitive-load)
             (list 'portable-hook 'primitive-load)
             (list 'emitter-hook 'capability-file)
             (list 'policy 'deny)
             (list 'test-categories '(load file policy)))
       (list (list 'name 'command-line)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'emergency-exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'exit)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variable)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'get-environment-variables)
             (list 'library '(scheme process-context))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-process)
             (list 'required-capability 'process-environment)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-process)
             (list 'policy 'deny)
             (list 'test-categories '(process policy)))
       (list (list 'name 'interaction-environment)
             (list 'library '(scheme repl))
             (list 'minimum-arity 0)
             (list 'maximum-arity 0)
             (list 'source 'host-capability)
             (list 'effect 'host-repl)
             (list 'required-capability 'repl)
             (list 'emacs-hook
                   'agent-scheme--primitive-interaction-environment)
             (list 'portable-hook 'primitive-interaction-environment)
             (list 'emitter-hook 'capability-repl)
             (list 'policy 'session)
             (list 'test-categories '(repl policy session)))
       (list (list 'name 'current-jiffy)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))
       (list (list 'name 'current-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))
       (list (list 'name 'jiffies-per-second)
             (list 'library '(scheme time))
             (list 'minimum-arity 0)
             (list 'maximum-arity #f)
             (list 'source 'host-capability)
             (list 'effect 'host-time)
             (list 'required-capability 'clock)
             (list 'emacs-hook 'agent-scheme--policy-denied-primitive)
             (list 'portable-hook 'policy-denied-primitive)
             (list 'emitter-hook 'capability-time)
             (list 'policy 'deny)
             (list 'test-categories '(time policy)))))

    ;; Add shared backend policy-path metadata to host-effecting standard specs.
    (define (standard-primitive-manifest-spec spec)
      (append spec
              (list (list 'backend-effect-path 'shared-capability-request)
                    (list 'policy-category 'standard-host-effect))))

    ;; Return manifest metadata for standard-library primitive bindings.
    (define (standard-primitive-binding-specs)
      (map standard-primitive-manifest-spec standard-primitive-manifest-specs))

    ;; Return manifest metadata for portable prelude SPEC.
    (define (prelude-manifest-spec spec)
      (let* ((name (second (assq 'name spec)))
             (effect 'pure))
        (append spec
                (list (list 'library scheme-base-library-key)
                      (list 'effect effect)
                      (list 'required-capability #f)
                      (list 'emacs-hook #f)
                      (list 'portable-hook #f)
                      (list 'backend-effect-path 'direct-runtime)
                      (list 'emitter-hook 'inline-or-call)
                      (list 'policy-category 'pure-r7rs)
                      (list 'policy 'allow)
                      (list 'test-categories
                            (primitive-test-categories-for-name
                             name
                             effect))))))

    ;; Public manifest accessor shared by portable tests and future tools.
    (define (agent-scheme-primitive-manifest-binding-specs)
      (append (map base-primitive-manifest-spec base-primitive-registry)
              (map prelude-manifest-spec
                   (agent-scheme-base-prelude-binding-specs))
              (standard-primitive-binding-specs)))

    ;; Install a primitive procedure binding into ENVIRONMENT.
    (define (define-primitive! environment
                               name
                               function
                               minimum-arity
                               maximum-arity)
      (environment-define!
       environment
       name
       (make-primitive-procedure
        name function minimum-arity maximum-arity)))

    ;; The base environment installs primitive kernel bindings first, then
    ;; evaluates derived Scheme definitions in the same environment.
    (define (agent-scheme-make-base-environment)
      (let ((environment (agent-scheme-make-empty-environment)))
        (let loop ((rest base-primitive-registry))
          (if (null? rest)
              (begin
                ;; Derived base procedures are ordinary Scheme definitions
                ;; loaded through the same evaluator and trampoline.
                (base-trampoline
                 (make-sequence (base-prelude-forms) #t)
                 environment
                 (new-eval-context '()))
                environment)
              (begin
                (define-primitive! environment
                                   (car (car rest))
                                   (base-primitive-implementation (second (car rest)))
                                   (third (car rest))
                                   (fourth (car rest)))
                (loop (cdr rest)))))))

    ;; Install derived base syntax into CONTEXT once.
    (define (ensure-base-syntax! context environment)
      (if (not (context-base-syntax-installed context))
          (begin
            (for-each
             (lambda (form)
               (base-define-syntax
                form
                environment
                context
                (context-syntax-environment context)))
             (base-syntax-forms))
            (set-context-base-syntax-installed! context #t))))

    ))
