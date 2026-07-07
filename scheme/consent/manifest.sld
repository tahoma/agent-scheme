;;; Portable Consent Scheme core library manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light manifest records the public and internal library surface
;;; owned by the core Consent Scheme runtime. It is metadata, not authority to
;;; import or execute the named libraries.

(define-library (consent manifest)
  (export consent-library-manifest consent-library-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe core runtime libraries and primitive overlays.
    (define consent-library-manifest
      '(((library . (consent manifest))
         (visibility . public-consent)
         (layer . manifest)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "manifest.sld")
         (implementation-library . (consent manifest))
         (exports . (consent-library-manifest consent-library-manifest-ref))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (scheme base))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . base-snapshot)
         (implementation-source . base-environment-snapshot)
         (exports . (* + - / < <= = > >= apply binary-port? boolean=?
                     boolean? bytevector bytevector-append bytevector-copy
                     bytevector-copy! bytevector-length bytevector-u8-ref
                     bytevector-u8-set! bytevector?
                     call-with-current-continuation call-with-port
                     call-with-values call/cc car cdr ceiling char->integer
                     char<=? char<? char=? char>=? char>? char-ready? char?
                     close-input-port close-output-port close-port complex?
                     cons dynamic-wind eq? equal? eqv? eof-object
                     eof-object? error error-object-irritants
                     error-object-message error-object? current-error-port
                     current-input-port current-output-port denominator
                     exact exact-integer-sqrt exact-integer? exact? expt
                     features file-error? flush-output-port floor floor/
                     floor-quotient floor-remainder gcd
                     get-output-bytevector get-output-string inexact
                     inexact? input-port-open? input-port? integer->char
                     integer? lcm list->string list->vector list?
                     make-bytevector make-parameter make-string make-vector
                     modulo newline null? number->string number?
                     open-input-bytevector open-input-string
                     open-output-bytevector open-output-string
                     output-port-open? output-port? numerator pair?
                     peek-char peek-u8 port? procedure? quotient raise
                     raise-continuable rational? rationalize read-bytevector
                     read-bytevector! read-char read-error? read-line
                     read-string read-u8 real? remainder round set-car!
                     set-cdr! string string->list string->number
                     string->symbol string->utf8 string->vector
                     string-append string-copy string-copy! string-fill!
                     string-length string-ref string-set! string<=? string<?
                     string=? string>=? string>? string? substring
                     symbol->string symbol=? symbol? textual-port? truncate
                     truncate/ truncate-quotient truncate-remainder
                     u8-ready? utf8->string vector vector->list
                     vector->string vector-append vector-copy vector-copy!
                     vector-fill! vector-length vector-ref vector-set!
                     vector? values with-exception-handler write-bytevector
                     write-char write-string write-u8 not list caar cadr
                     cdar cddr length append reverse list-tail list-ref
                     list-set! make-list list-copy memq memv member assq
                     assv assoc zero? positive? negative? abs square even?
                     odd? min max map for-each string-map string-for-each
                     vector-map vector-for-each cond case and or when unless
                     let let* do parameterize cond-expand guard guard-aux))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ()))
        ((library . (scheme case-lambda))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "case-lambda.sld")
         (implementation-library . (scheme case-lambda))
         (exports . (case-lambda))
         (owner . r7rs-small)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (scheme char))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-char)
         (exports . (char-alphabetic? char-ci<=? char-ci<? char-ci=?
                     char-ci>=? char-ci>? char-downcase char-foldcase
                     char-lower-case? char-numeric? char-upcase
                     char-upper-case? char-whitespace? digit-value
                     string-ci<=? string-ci<? string-ci=? string-ci>=?
                     string-ci>? string-downcase string-foldcase
                     string-upcase))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme complex))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-complex)
         (exports . (angle imag-part magnitude make-polar make-rectangular
                     real-part))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme cxr))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-cxr)
         (exports . (caaar caadr cadar caddr cdaar cdadr cddar cdddr
                     caaaar caaadr caadar caaddr cadaar cadadr caddar
                     cadddr cdaaar cdaadr cdadar cdaddr cddaar cddadr
                     cdddar cddddr))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme eval))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-eval)
         (exports . (environment eval))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme file))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-file)
         (exports . (call-with-input-file call-with-output-file delete-file
                     file-exists? open-binary-input-file
                     open-binary-output-file open-input-file
                     open-output-file with-input-from-file
                     with-output-to-file))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme inexact))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-inexact)
         (exports . (acos asin atan cos exp finite? infinite? log nan? sin
                     sqrt tan))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme lazy))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "lazy.sld")
         (implementation-library . (scheme lazy))
         (exports . (delay delay-force force make-promise promise?))
         (owner . r7rs-small)
         (provider . repo-source)
         (dependencies . ((scheme base))))
        ((library . (scheme load))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-load)
         (exports . (load))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme process-context))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-process-context)
         (exports . (command-line emergency-exit exit
                     get-environment-variable
                     get-environment-variables))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme read))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-read)
         (exports . (read))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme repl))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-repl)
         (exports . (interaction-environment))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme r5rs))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . derived)
         (implementation-source . scheme-base-subset)
         (implementation-id . scheme-r5rs)
         (exports . (guard-aux guard cond-expand parameterize do let* let
                     unless when or and case cond vector-for-each vector-map
                     string-for-each string-map for-each map max min odd?
                     even? square abs negative? positive? zero? assoc assv
                     assq member memv memq list-copy make-list list-set!
                     list-ref list-tail reverse append length cddr cdar cadr
                     caar list not write-u8 write-string write-char
                     write-bytevector with-exception-handler values vector?
                     vector-set! vector-ref vector-length vector-fill!
                     vector-copy! vector-copy vector-append vector->string
                     vector->list vector utf8->string u8-ready?
                     truncate-remainder truncate-quotient truncate/ truncate
                     textual-port? symbol? symbol=? symbol->string substring
                     string? string>? string>=? string=? string<? string<=?
                     string-set! string-ref string-length string-fill!
                     string-copy! string-copy string-append string->vector
                     string->utf8 string->symbol string->number string->list
                     string set-cdr! set-car! round remainder real? read-u8
                     read-string read-line read-error? read-char
                     read-bytevector! read-bytevector rationalize rational?
                     raise-continuable raise quotient procedure? port?
                     peek-u8 peek-char pair? numerator output-port?
                     output-port-open? open-output-string
                     open-output-bytevector open-input-string
                     open-input-bytevector number? number->string null?
                     newline modulo make-vector make-string make-parameter
                     make-bytevector list? list->vector list->string lcm
                     integer? integer->char input-port? input-port-open?
                     inexact? inexact get-output-string
                     get-output-bytevector gcd floor-remainder
                     floor-quotient floor/ floor flush-output-port
                     file-error? features expt exact? exact-integer?
                     exact-integer-sqrt exact denominator
                     current-output-port current-input-port
                     current-error-port error-object? error-object-message
                     error-object-irritants error eof-object? eof-object
                     eqv? equal? eq? dynamic-wind cons complex? close-port
                     close-output-port close-input-port char? char-ready?
                     char>? char>=? char=? char<? char<=? char->integer
                     ceiling cdr car call/cc call-with-values call-with-port
                     call-with-current-continuation bytevector?
                     bytevector-u8-set! bytevector-u8-ref bytevector-length
                     bytevector-copy! bytevector-copy bytevector-append
                     bytevector boolean? boolean=? binary-port? apply >= > =
                     <= < / - + * exact->inexact inexact->exact))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme time))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-time)
         (exports . (current-jiffy current-second jiffies-per-second))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (scheme write))
         (visibility . public)
         (category . standard)
         (layer . standard)
         (status . implemented)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . scheme-write)
         (exports . (display write write-shared write-simple))
         (owner . r7rs-small)
         (provider . consent-core)
         (dependencies . ((scheme base))))
        ((library . (consent capability))
         (visibility . public-consent)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "capability.sld")
         (implementation-library . (consent capability))
         (exports . (grant-capability! current-grants grant-ref
                     grant-attenuate grant-revoke! handle-ref handle-live?
                     handle-kind handle-revalidate handle-release!
                     call-with-capability-grant with-capability-grant))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (consent capability primitive))))
        ((library . (consent capability primitive))
         (visibility . internal-runtime)
         (layer . primitive)
         (status . internal)
         (source-kind . primitive-library)
         (implementation-source . primitive-declaration)
         (implementation-id . consent-capability)
         (exports . (grant-capability! current-grants grant-ref
                     grant-attenuate grant-revoke!
                     call-with-capability-grant handle-ref handle-live?
                     handle-kind handle-revalidate handle-release!))
         (owner . consent-core)
         (provider . host-adapter)
         (dependencies . ()))
        ((library . (consent reader))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "reader.sld")
         (implementation-library . (consent reader))
         (exports . (consent-read consent-read-all
                     consent-read-from-string-at consent-read-recover
                     consent-read-recover-from-string-at
                     consent-resync-to-next-form consent-recovery-result?
                     consent-recovery-result-datums
                     consent-recovery-result-diagnostics
                     consent-recovery-result-spans
                     consent-recovery-result-status consent-recovery-step?
                     consent-recovery-step-status
                     consent-recovery-step-datum
                     consent-recovery-step-diagnostic
                     consent-recovery-step-span consent-recovery-step-next
                     consent-recovery-step-pending consent-read-eof
                     consent-read-eof? consent-source-metadata-count
                     consent-datum-source consent-datum-source-set!
                     consent-copy-datum-source! consent-validate-datum
                     consent-datum->external consent-datum->external-bounded
                     consent-number? consent-number-lexeme
                     consent-number-exactness consent-number-radix
                     consent-number-kind consent-number-value
                     consent-make-canonical-integer
                     consent-make-canonical-decimal
                     consent-make-canonical-rational
                     consent-make-canonical-infnan
                     consent-make-canonical-complex consent-number-zero?
                     consent-number-negative? consent-number-abs
                     consent-number->external consent-integer->radix-string
                     consent-make-record-type consent-record-type?
                     consent-record-type-name consent-record-type-fields
                     consent-make-record consent-record? consent-record-type
                     consent-record-fields))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme char) (scheme inexact)
                          (scheme write))))
        ((library . (consent runtime))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "runtime.sld")
         (implementation-library . (consent runtime))
         (exports . (consent-default-maximum-steps
                     consent-default-maximum-value-nodes
                     consent-default-maximum-source-metadata
                     consent-default-maximum-host-callbacks
                     consent-version-components consent-version
                     consent-set-library-search-directories!
                     consent-library-search-directory-list
                     consent-register-embedded-source!
                     consent-embedded-source-ref
                     consent-register-native-library!
                     consent-native-library-ref
                     consent-install-native-applier!
                     consent-native-applier-ref
                     consent-host-datum->consent-datum
                     consent-make-empty-environment consent-unspecified
                     consent-unspecified? make-undefined undefined?
                     undefined make-cell cell? cell-value set-cell-value!
                     make-environment environment? environment-frame
                     set-environment-frame! environment-parent
                     environment-imported-names
                     set-environment-imported-names! make-syntax-environment
                     syntax-environment? syntax-environment-frame
                     set-syntax-environment-frame! syntax-environment-parent
                     syntax-environment-imported-names
                     set-syntax-environment-imported-names!
                     make-syntax-context syntax-context? syntax-context-id
                     syntax-context-value-environment
                     syntax-context-syntax-environment make-identifier
                     identifier? identifier-name identifier-context
                     make-formals formals? formals-required formals-rest
                     make-documentation-metadata documentation-metadata?
                     documentation-metadata-fields
                     documentation-metadata-origins
                     documentation-metadata-from-body
                     documentation-body-result make-procedure
                     consent-procedure? procedure-formals procedure-body
                     procedure-environment procedure-syntax-environment
                     procedure-documentation make-primitive-procedure
                     consent-primitive-procedure? primitive-procedure-name
                     primitive-procedure-function
                     primitive-procedure-minimum-arity
                     primitive-procedure-maximum-arity
                     make-consent-parameter consent-parameter?
                     parameter-value set-parameter-value!
                     parameter-converter make-multiple-values
                     multiple-values? multiple-values-values
                     make-continuation continuation? continuation-procedure
                     continuation-dynamic-winds
                     continuation-exception-handlers
                     continuation-current-error make-dynamic-wind-frame
                     dynamic-wind-frame? dynamic-wind-frame-before
                     dynamic-wind-frame-after make-consent-error-object
                     consent-error-object? consent-error-object-message
                     consent-error-object-irritants make-consent-eof-object
                     consent-eof-object? consent-eof-object
                     make-consent-port consent-port? consent-port-medium
                     consent-port-input? consent-port-output?
                     consent-port-textual? consent-port-binary?
                     consent-port-open? set-consent-port-open?!
                     consent-port-source set-consent-port-source!
                     consent-port-position set-consent-port-position!
                     consent-port-contents set-consent-port-contents!
                     consent-port-backing-domain consent-port-operations
                     consent-port-grant consent-port-limits
                     consent-port-handle consent-port-status
                     set-consent-port-status! consent-port-path
                     consent-port-counters set-consent-port-counters!
                     make-environment-specifier environment-specifier?
                     environment-specifier-environment
                     environment-specifier-syntax-environment
                     environment-specifier-immutable?
                     make-string-output-port string-output-port?
                     string-output-port-contents
                     set-string-output-port-contents! make-sequence
                     sequence? sequence-forms sequence-allow-definitions
                     make-bounce bounce? bounce-expression
                     bounce-environment bounce-syntax-environment
                     bounce-continuation make-eval-context eval-context?
                     context-steps set-context-steps! context-maximum-steps
                     context-maximum-value-nodes
                     context-maximum-source-metadata context-value-nodes
                     set-context-value-nodes! context-interned-symbols
                     set-context-interned-symbols!
                     context-maximum-interned-symbols
                     set-context-maximum-interned-symbols!
                     context-host-callbacks set-context-host-callbacks!
                     context-maximum-host-callbacks context-event-count
                     set-context-event-count! context-maximum-events
                     context-maximum-event-nodes set-context-maximum-steps!
                     set-context-maximum-value-nodes!
                     set-context-maximum-source-metadata!
                     set-context-maximum-host-callbacks!
                     set-context-maximum-events! context-output-bytes
                     set-context-output-bytes! context-maximum-output-bytes
                     set-context-maximum-output-bytes!
                     context-maximum-wall-time-ms
                     set-context-maximum-wall-time-ms! context-wall-clock
                     set-context-wall-clock! context-wall-start
                     set-context-wall-start! context-exhaustion-reason
                     set-context-exhaustion-reason!
                     context-syntax-environment
                     set-context-syntax-environment! context-libraries
                     set-context-libraries! context-include-paths
                     context-include-directory
                     set-context-include-directory! context-file-paths
                     context-internal-libraries-allowed?
                     context-docstring-retention
                     context-boundary-contract-checking
                     context-policy-actions
                     context-policy-confirmation-function
                     context-capability-grants
                     set-context-capability-grants!
                     context-active-capability-grants
                     set-context-active-capability-grants!
                     context-audit-events set-context-audit-events!
                     context-current-input-port
                     set-context-current-input-port!
                     context-current-output-port
                     set-context-current-output-port!
                     context-current-error-port
                     set-context-current-error-port! context-current-error
                     set-context-current-error! context-session-id
                     context-request-id context-request context-focus
                     context-region-context context-buffer-context
                     context-project-context context-conversation-summary
                     context-command-line context-interaction-environment
                     set-context-interaction-environment!
                     context-base-syntax-installed
                     set-context-base-syntax-installed!
                     context-next-syntax-id set-context-next-syntax-id!
                     context-exception-handlers
                     set-context-exception-handlers! context-dynamic-winds
                     set-context-dynamic-winds! make-syntax-transformer
                     syntax-transformer? syntax-transformer-ellipsis
                     syntax-transformer-literals syntax-transformer-rules
                     syntax-transformer-value-environment
                     syntax-transformer-syntax-environment
                     make-pattern-binding pattern-binding?
                     pattern-binding-depth set-pattern-binding-depth!
                     pattern-binding-captures set-pattern-binding-captures!
                     pattern-binding-empty-prefixes
                     set-pattern-binding-empty-prefixes! make-syntax-scope
                     syntax-scope? syntax-scope-forms
                     syntax-scope-syntax-environment make-library-binding
                     library-binding? library-binding-name
                     library-binding-kind library-binding-object
                     library-binding-library-key make-library library?
                     library-name library-key library-exports
                     library-value-environment library-syntax-environment
                     option-ref eval-error budget-error
                     normalize-include-directory path-absolute? path-join
                     path-normalize normalize-include-paths
                     context-reader-options authorize-file-capability
                     file-authorization-path audit-file-capability-result!
                     authorize-code-loading audit-code-loading-result!
                     process-capability-effect
                     process-capability-policy-category
                     process-capability-request process-capability-handle
                     process-port-capability-handle
                     authorize-process-capability
                     authorize-process-environment-capability
                     audit-process-capability-result!
                     network-capability-effect network-capability-request
                     network-capability-handle
                     network-port-capability-handle
                     authorize-network-capability
                     audit-network-capability-result!
                     authorize-clock-capability
                     audit-clock-capability-result! new-eval-context
                     record-audit-event! record-context-event! note-step!
                     note-host-callback! note-interned-symbol!
                     note-value-allocation! value-node-count
                     charge-value-allocation! charge-string-allocation!
                     charge-bytevector-allocation! charge-vector-allocation!
                     charge-list-allocation! charge-literal!
                     check-value-budget note-output! check-wall-time!
                     budget-spec-ref budget-spec-dimensions
                     budget-ceiling-snapshot budget-tighten! budget-restore!
                     values-list single-value identity-continuation continue
                     continuation-value proper-list-elements second third
                     fourth expect-symbol identifier-datum?
                     identifier-datum-name identifier-key identifier-named?
                     expect-identifier-key frame-cell environment-cell
                     environment-cell-imported?
                     current-environment-imported? environment-define!
                     environment-set! environment-define-or-set!
                     environment-ref environment-cell-for-identifier
                     environment-ref-identifier environment-set-identifier!
                     ensure-distinct-names parse-formals))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (consent reader)
                          (consent version))))
        ((library . (consent base))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "base.sld")
         (implementation-library . (consent base))
         (exports . (scheme-base-library-key consent-install-base-backend!
                     base-primitive-registry base-prelude-forms
                     base-syntax-forms consent-base-prelude-load-paths
                     consent-base-syntax-load-paths read-port-string
                     read-all-datums resolve-source-text
                     resolve-source-entry define-primitive!
                     ensure-base-syntax! consent-make-base-environment
                     consent-base-primitive-names
                     consent-base-primitive-specs
                     consent-base-prelude-binding-names
                     consent-base-prelude-binding-specs
                     consent-base-binding-specs
                     consent-primitive-manifest-binding-specs))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme char) (scheme inexact)
                          (scheme write) (consent reader)
                          (consent runtime))))
        ((library . (consent library))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "library.sld")
         (implementation-library . (consent library))
         (exports . (consent-standard-source-library-specs
                     consent-stdlib-source-library-specs
                     consent-runtime-source-files
                     consent-library-catalog-entries
                     consent-library-catalog-entry
                     consent-library-catalog-search
                     consent-library-catalog-runtime-source-files
                     consent-library-catalog-sources
                     consent-library-catalog-diagnostics
                     consent-library-catalog-add-manifest!
                     consent-library-catalog-remove-manifest!
                     consent-library-catalog-add-root!
                     consent-library-catalog-remove-root!
                     consent-library-catalog-refresh!
                     consent-install-library-backend!
                     consent-native-argument-value consent-apply-callable
                     import-form? define-library-form? eval-import
                     eval-define-library resolve-library library-available?
                     library-name-key library-registry-ref
                     library-registry-set! export-specs
                     ensure-compatible-import-bindings
                     path-policy-allows-file? path-directory
                     read-file-string with-include-directory form-named?))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme char) (scheme file)
                          (consent reader) (consent runtime)
                          (consent base))))
        ((library . (consent macro))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "macro.sld")
         (implementation-library . (consent macro))
         (exports . (consent-expand consent-expand-source
                     consent-macroexpand consent-macroexpand-1
                     consent-macroexpand-library consent-macro-binding-info
                     consent-syntax-source definition-form?
                     define-values-form? begin-form? make-lambda-expression
                     parse-definition parse-define-values formals-names
                     define-values-bound-names record-definition-form?
                     body-definition-form? tagged-list?
                     single-argument-syntax syntax-error-form?
                     syntax-error-message raise-syntax-error
                     make-empty-syntax-environment syntax-environment-ref
                     syntax-environment-define! with-syntax-environment
                     special-operator-active? syntax-binding-for-operator
                     proper-list-elements/maybe append-tail
                     syntax-definition-form? eval-define-syntax
                     make-local-syntax-scope expand-expression
                     expand-expression/fully expand-sequence-forms))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (consent reader)
                          (consent runtime) (consent base)
                          (consent library))))
        ((library . (consent result))
         (visibility . public-consent)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "result.sld")
         (implementation-library . (consent result))
         (exports . (result-field value->result-datum strip-identifiers
                     budget-result-field ok-result-datum
                     debugger-condition-datum debugger-exception-datum
                     debugger-field-values debugger-field-value
                     debugger-expect-condition debugger-restart-id-name
                     debugger-default-restarts condition-result-datum
                     budget-exhausted-condition? consent-result->external
                     consent-value->external))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (consent reader)
                          (consent runtime))))
        ((library . (consent interpreter))
         (visibility . internal-runtime)
         (layer . runtime)
         (status . internal)
         (source-kind . source-library)
         (source-file . "interpreter.sld")
         (implementation-library . (consent interpreter))
         (exports . (consent-eval consent-eval-source consent-eval-string
                     consent-expand consent-expand-source
                     consent-eval-result consent-eval-source-result
                     consent-make-interaction-context
                     consent-interaction-context?
                     consent-interaction-context-session-id
                     consent-interaction-program-output
                     consent-interaction-eval-form
                     consent-interaction-program-input-port
                     consent-interaction-seed-program-input!
                     consent-interaction-program-input-remainder
                     consent-repl-session-manager
                     consent-repl-seed-initial-session!
                     consent-session-manager-current-context
                     consent-program-input-from-string
                     consent-program-input-from-bytevector
                     consent-make-empty-environment
                     consent-make-base-environment
                     consent-base-primitive-names
                     consent-base-primitive-specs
                     consent-base-prelude-binding-names
                     consent-base-prelude-binding-specs
                     consent-base-binding-specs
                     consent-standard-source-library-specs
                     consent-stdlib-source-library-specs
                     consent-primitive-manifest-binding-specs
                     consent-result->external consent-value->external
                     consent-unspecified consent-unspecified?
                     consent-procedure? consent-primitive-procedure?))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base) (scheme char) (scheme file)
                          (scheme inexact) (scheme process-context)
                          (scheme read) (scheme write) (consent reader)
                          (consent runtime) (consent result)
                          (consent base) (consent library)
                          (consent macro))))
        ((library . (consent eval))
         (visibility . public-consent)
         (layer . api)
         (status . documented-unavailable-on-some-hosts)
         (source-kind . facade)
         (source-file . "eval.sld")
         (implementation-library . (consent eval))
         (exports . (consent-eval consent-eval-source consent-eval-string
                     consent-expand consent-expand-source
                     consent-eval-result consent-eval-source-result
                     consent-make-interaction-context
                     consent-interaction-context?
                     consent-interaction-context-session-id
                     consent-interaction-program-output
                     consent-interaction-eval-form
                     consent-interaction-program-input-port
                     consent-interaction-seed-program-input!
                     consent-interaction-program-input-remainder
                     consent-repl-session-manager
                     consent-repl-seed-initial-session!
                     consent-session-manager-current-context
                     consent-program-input-from-string
                     consent-program-input-from-bytevector
                     consent-make-empty-environment
                     consent-make-base-environment
                     consent-base-primitive-names
                     consent-base-primitive-specs
                     consent-base-prelude-binding-names
                     consent-base-prelude-binding-specs
                     consent-base-binding-specs
                     consent-standard-source-library-specs
                     consent-stdlib-source-library-specs
                     consent-primitive-manifest-binding-specs
                     consent-result->external consent-value->external
                     consent-unspecified consent-unspecified?
                     consent-procedure? consent-primitive-procedure?))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((consent interpreter))))
        ((library . (consent version))
         (visibility . public-consent)
         (layer . api)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "version.sld")
         (implementation-library . (consent version))
         (exports . (consent-version-datum))
         (owner . consent-core)
         (provider . repo-source)
         (dependencies . ((scheme base))))))

    (define (consent-library-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Consent core or standard library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest consent-library-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
