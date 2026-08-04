;;; consent-base-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the initial `(scheme base)' primitive registry, common
;; base-library procedures, higher-order helpers, and result encoding.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)

(defun consent-base-test--external (source &optional options)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source nil options)))

(defun consent-base-test--manifest-spec (library name)
  "Return manifest metadata for binding NAME in LIBRARY."
  (seq-find
   (lambda (spec)
     (and (equal (plist-get spec :library) library)
          (equal (plist-get spec :name) name)))
   (consent-primitive-manifest-binding-specs)))

(defun consent-base-test--documentation-text (spec)
  "Return SPEC's public documentation text, or nil."
  (let* ((documentation (plist-get spec :documentation))
         (fields (consent--documentation-metadata-fields documentation))
         (entry (assoc "documentation" fields)))
    (and entry (cdr entry))))

(defun consent-base-test--documentation-field (spec name)
  "Return documentation field NAME from SPEC, or nil."
  (let* ((documentation (plist-get spec :documentation))
         (fields (consent--documentation-metadata-fields documentation))
         (entry (assoc name fields)))
    (and entry (cdr entry))))

(defun consent-base-test--documentation-field-present-p (spec name)
  "Return non-nil when SPEC has documentation field NAME."
  (let* ((documentation (plist-get spec :documentation))
         (fields (consent--documentation-metadata-fields documentation)))
    (and (assoc name fields) t)))

(defun consent-base-test--descriptor-field (descriptor name)
  "Return descriptor field NAME from DESCRIPTOR, or nil."
  (let ((entry (assq name descriptor)))
    (and entry
         (consp (cdr entry))
         (null (cddr entry))
         (cadr entry))))

(defun consent-base-test--parameter-type (spec name)
  "Return parameter NAME's documented type in SPEC, or nil."
  (let* ((parameters
          (consent-base-test--documentation-field spec "parameters"))
         (entry (assq name parameters)))
    (and entry
         (consent-base-test--descriptor-field (cdr entry) 'type))))

(defun consent-base-test--return-type (spec)
  "Return SPEC's documented return type, or nil."
  (consent-base-test--descriptor-field
   (consent-base-test--documentation-field spec "returns")
   'type))

(ert-deftest consent-base-test-registry-is-discoverable ()
  "Expose kernel and prelude binding metadata from Emacs."
  (let ((names (consent-base-primitive-names))
        (prelude-names (consent-base-prelude-binding-names))
        (specs (consent-base-primitive-specs))
        (binding-specs (consent-base-binding-specs)))
    (dolist (name '("+" "apply" "car" "vector-ref" "bytevector-u8-ref"))
      (should (member name names)))
    (dolist (name '("append" "cadr" "length" "map" "zero?"))
      (should-not (member name names))
      (should (member name prelude-names)))
    (dolist (name '("call-with-values" "call/cc" "dynamic-wind" "values"))
      (should (member name names)))
    (should
     (equal (plist-get
             (seq-find
              (lambda (spec)
                (equal (plist-get spec :name) "vector-ref"))
              specs)
             :minimum-arity)
            2))
    (should
     (eq (plist-get
          (seq-find
           (lambda (spec)
             (equal (plist-get spec :name) "vector-ref"))
           binding-specs)
          :source)
         'kernel))
    (should
     (eq (plist-get
          (seq-find
           (lambda (spec)
             (equal (plist-get spec :name) "append"))
           binding-specs)
          :source)
         'prelude))))

(ert-deftest consent-base-test-primitive-manifest-is-inspectable ()
  "Expose canonical metadata for primitives and effectful standard bindings."
  (let ((vector-ref (consent-base-test--manifest-spec
                     "(scheme base)" "vector-ref"))
        (vector-set (consent-base-test--manifest-spec
                     "(scheme base)" "vector-set!"))
        (delete-file (consent-base-test--manifest-spec
                      "(scheme file)" "delete-file"))
        (open-input-file (consent-base-test--manifest-spec
                          "(scheme file)" "open-input-file"))
        (current-second (consent-base-test--manifest-spec
                         "(scheme time)" "current-second")))
    (should vector-ref)
    (should (equal (plist-get vector-ref :minimum-arity) 2))
    (should (equal (plist-get vector-ref :maximum-arity) 2))
    (should (eq (plist-get vector-ref :source) 'kernel))
    (should (eq (plist-get vector-ref :effect) 'pure))
    (should (eq (plist-get vector-ref :backend-effect-path) 'direct-runtime))
    (should (eq (plist-get vector-ref :policy) 'allow))
    (should (eq (plist-get vector-ref :emacs-hook)
                'consent--primitive-vector-ref))
    (should (memq 'vector (plist-get vector-ref :test-categories)))
    (should (eq (plist-get vector-set :effect) 'mutation))
    (should (eq (plist-get vector-set :backend-effect-path)
                'runtime-mutation))
    (should (eq (plist-get delete-file :source) 'host-capability))
    (should (eq (plist-get delete-file :effect) 'host-file))
    (should (eq (plist-get delete-file :required-capability) 'file-system))
    (should (eq (plist-get delete-file :backend-effect-path)
                'shared-capability-request))
    (should (eq (plist-get delete-file :policy-category)
                'standard-host-effect))
    (should (eq (plist-get delete-file :policy) 'deny))
    (should (equal (plist-get open-input-file :minimum-arity) 1))
    (should (eq (plist-get open-input-file :effect) 'host-file))
    (should (eq (plist-get open-input-file :backend-effect-path)
                'shared-capability-request))
    (should (eq (plist-get open-input-file :policy) 'deny))
    (should (equal (plist-get current-second :minimum-arity) 0))
    (should (equal (plist-get current-second :maximum-arity) 0))
    (should (eq (plist-get current-second :effect) 'host-time))
    (should (eq (plist-get current-second :required-capability) 'clock))
    (should (eq (plist-get current-second :emacs-hook)
                'consent--primitive-current-second))
    (should (eq (plist-get current-second :portable-hook)
                'primitive-current-second))
    (should (eq (plist-get current-second :backend-effect-path)
                'shared-capability-request))
    (should (eq (plist-get current-second :policy-category)
                'standard-host-effect))
    (should (eq (plist-get current-second :policy) 'grant))))

(ert-deftest consent-base-test-public-manifest-bindings-have-docs ()
  "Public primitive manifest entries carry user-facing documentation."
  (dolist (spec (consent-primitive-manifest-binding-specs))
    (let ((documentation (consent-base-test--documentation-text spec)))
      (should (stringp documentation))
      (should (> (length documentation) 0))
      (when (eq (plist-get spec :source) 'kernel)
        (should
         (member "primitive-manifest-metadata"
                 (consent--documentation-metadata-origins
                  (plist-get spec :documentation)))))
      (when (eq (plist-get spec :source) 'host-capability)
        (should
         (member "primitive-manifest-string"
                 (consent--documentation-metadata-origins
                  (plist-get spec :documentation))))))))

(ert-deftest consent-base-test-kernel-manifest-docs-have-rich-metadata ()
  "Kernel primitive manifest documentation carries spec-derived signatures."
  (dolist (spec (consent-primitive-manifest-binding-specs))
    (when (eq (plist-get spec :source) 'kernel)
      (should
       (consent-base-test--documentation-field-present-p
        spec
        "documentation"))
      (should
       (consent-base-test--documentation-field-present-p spec "parameters"))
      (should
       (consent-base-test--documentation-field-present-p spec "returns"))
      (should
       (consent-base-test--documentation-field-present-p spec "effects"))
      (should
       (equal (consent-base-test--documentation-field spec "effects")
              (list (plist-get spec :effect))))))
  (let ((plus (consent-base-test--manifest-spec "(scheme base)" "+"))
        (floor-divide (consent-base-test--manifest-spec
                       "(scheme base)"
                       "floor/"))
        (vector-ref (consent-base-test--manifest-spec
                     "(scheme base)"
                     "vector-ref"))
        (read-char (consent-base-test--manifest-spec
                    "(scheme base)"
                    "read-char"))
        (bytevector-u8-set (consent-base-test--manifest-spec
                            "(scheme base)"
                            "bytevector-u8-set!")))
    (should (equal (consent-base-test--parameter-type plus 'numbers)
                   '(list-of number)))
    (should (eq (consent-base-test--return-type plus) 'number))
    (should (eq (consent-base-test--parameter-type vector-ref 'vector)
                'vector))
    (should
     (eq (consent-base-test--parameter-type vector-ref 'k)
         'exact-non-negative-integer))
    (should (eq (consent-base-test--return-type vector-ref) 'any))
    (should
     (equal (consent-base-test--return-type floor-divide)
            '(values integer integer)))
    (should
     (eq (consent-base-test--parameter-type read-char 'port)
         'textual-input-port))
    (should (equal (consent-base-test--return-type read-char)
                   '(or char eof-object)))
    (should
     (eq (consent-base-test--parameter-type bytevector-u8-set 'byte)
         'byte))
    (should (eq (consent-base-test--return-type bytevector-u8-set)
                'unspecified))))

(ert-deftest consent-base-test-effectful-manifest-has-backend-policy-path ()
  "Effectful manifest entries identify the shared backend policy path."
  (dolist (spec (consent-primitive-manifest-binding-specs))
    (when (eq (plist-get spec :source) 'host-capability)
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (plist-get spec :policy-category))))
  (dolist (binding '(("(scheme file)" "file-exists?" host-file file-system
    deny)
                     ("(scheme process-context)" "command-line"
                      host-process process-environment deny)
                     ("(scheme time)" "current-second" host-time clock grant)))
    (let ((spec (consent-base-test--manifest-spec
                 (nth 0 binding)
                 (nth 1 binding))))
      (should spec)
      (should (eq (plist-get spec :source) 'host-capability))
      (should (eq (plist-get spec :effect) (nth 2 binding)))
      (should (eq (plist-get spec :required-capability) (nth 3 binding)))
      (should (eq (plist-get spec :backend-effect-path)
                  'shared-capability-request))
      (should (eq (plist-get spec :policy-category)
                  'standard-host-effect))
      (should (eq (plist-get spec :policy) (nth 4 binding)))))
  (let ((read-char (consent-base-test--manifest-spec
                    "(scheme base)" "read-char")))
    (should read-char)
    (should (eq (plist-get read-char :effect) 'port-io))
    (should (eq (plist-get read-char :backend-effect-path)
                'runtime-port-check))))

(ert-deftest consent-base-test-derived-iteration-helpers-come-from-prelude ()
  "Keep string and vector higher-order helpers in portable Scheme."
  (let ((primitive-names (consent-base-primitive-names))
        (prelude-names (consent-base-prelude-binding-names)))
    (dolist (name '("string-map" "string-for-each"
                    "vector-map" "vector-for-each"))
      (should-not (member name primitive-names))
      (should (member name prelude-names))
      (let ((spec (consent-base-test--manifest-spec
                   "(scheme base)" name)))
        (should spec)
        (should (eq (plist-get spec :source) 'prelude))
        (should (eq (plist-get spec :effect) 'pure))
        (should (eq (plist-get spec :policy) 'allow))))))

(ert-deftest consent-base-test-primitive-registry-aligns-with-manifest ()
  "Keep Emacs kernel registry names, arities, and effects in the manifest."
  (dolist (spec (consent-base-primitive-specs))
    (let ((manifest-spec
           (consent-base-test--manifest-spec
            "(scheme base)"
            (plist-get spec :name))))
      (should manifest-spec)
      (should (equal (plist-get manifest-spec :minimum-arity)
                     (plist-get spec :minimum-arity)))
      (should (equal (plist-get manifest-spec :maximum-arity)
                     (plist-get spec :maximum-arity)))
      (should (eq (plist-get manifest-spec :source)
                  (plist-get spec :source)))
      (should (eq (plist-get manifest-spec :effect)
                  (plist-get spec :effect))))))

(ert-deftest consent-base-test-pairs-lists-and-equality ()
  "Evaluate common pair, list, association, and equality procedures."
  (should
   (equal (consent-base-test--external
           "(length (append '(1 2) '(3 4)))")
          "4"))
  (should
   (equal (consent-base-test--external "(cadr '(alpha beta gamma))")
          "beta"))
  (should
   (equal (consent-base-test--external
           "(define pair (list 1 2))
            (set-car! pair 9)
            pair")
          "(9 2)"))
  (should
   (equal (consent-base-test--external
           "(assoc 'b '((a . 1) (b . 2)))")
          "(b . 2)"))
  (should
   (equal (consent-base-test--external
           "(list (eq? 'a 'a) (eqv? 1 1) (equal? '(1 \"x\") '(1 \"x\")))")
          "(#t #t #t)")))

(ert-deftest consent-base-test-records-and-circular-equality ()
  "Evaluate R7RS records and equality over circular data."
  (should
   (equal (consent-base-test--external
           "(define-record-type <pare>
              (kons x y)
              pare?
              (x kar set-kar!)
              (y kdr))
            (let ((p (kons 1 2)))
              (set-kar! p 3)
              (list (pare? p)
                    (pare? (cons 1 2))
                    (kar p)
                    (kdr p)))")
          "(#t #f 3 2)"))
  (should
   (equal (consent-base-test--external
           "(let ((left '#1=(a b . #1#))
                  (right '#2=(a b a b . #2#)))
              (list (eq? left (cddr left))
                    (equal? left right)))")
          "(#t #t)")))

(ert-deftest consent-base-test-numbers-booleans-symbols-characters-strings ()
  "Evaluate scalar base-library procedures."
  (should
   (equal (consent-base-test--external
           "(list (/ 5 2) (abs -4) (modulo -13 4) (square 5))")
          "(5/2 4 3 25)"))
  (should
   (equal (consent-base-test--external
           "(list (boolean=? #t (not #f))
                  (integer? 4.0)
                  (exact-integer? 4)
                  (inexact? 4.0))")
          "(#t #t #t #t)"))
  (should
   (equal (consent-base-test--external
           "(string->symbol (symbol->string 'consent))")
          "consent"))
  (should
   (equal (consent-base-test--external
           "(list (char->integer #\\A)
                  (integer->char 66)
                  (string-ref (string #\\o #\\k) 1)
                  (string-append \"ag\" \"ent\"))")
          "(65 #\\B #\\k \"agent\")")))

(ert-deftest consent-base-test-features-parameters-and-utf8 ()
  "Evaluate base feature discovery, parameters, and UTF-8 conversion."
  (should
   (equal (consent-base-test--external
           "(let ((available (features)))
              (list (pair? (memq 'r7rs available))
                    (pair? (memq 'srfi-0 available))
                    (pair? (memq 'consent available))))")
          "(#t #t #t)"))
  (should
   (equal (consent-base-test--external
           "(let ((setting (make-parameter 'outer)))
              (list (setting)
                    (parameterize ((setting 'inner))
                      (setting))
                    (setting)))")
          "(outer inner outer)"))
  (should
   (equal (consent-base-test--external
           "(let ((bytes (string->utf8 \"agent\")))
              (list bytes
                    (utf8->string bytes)
                    (utf8->string bytes 1 4)))")
          "(#u8(97 103 101 110 116) \"agent\" \"gen\")")))

(ert-deftest consent-base-test-numeric-tower-exact-arithmetic ()
  "Evaluate exact rational arithmetic, integer division, and rounding."
  (should
   (equal (consent-base-test--external
           "(list (/ 3 4 5)
                  (+ 1/2 1/3)
                  (- 1 3/2)
                  (* 2/3 9/4)
                  (numerator (/ 6 4))
                  (denominator (/ 6 4)))")
          "(3/20 5/6 -1/2 3/2 3 2)"))
  (should
   (equal (consent-base-test--external
           "(list (floor 7/2)
                  (ceiling -7/2)
                  (truncate -7/2)
                  (round 7/2)
                  (round 5/2)
                  (gcd 32 -36)
                  (lcm 32 -36)
                  (expt 2 10)
                  (rationalize #e.3 1/10))")
          "(3 -3 -3 4 2 4 288 1024 1/3)"))
  (should
   (equal (consent-base-test--external
           "(call-with-values (lambda () (exact-integer-sqrt 17)) list)")
          "(4 1)")))

(ert-deftest consent-base-test-numeric-tower-conversions-and-radix-io ()
  "Evaluate exactness conversion and numeric string conversion."
  (should
   (equal (consent-base-test--external
           "(list (exact? #e1.5)
                  (inexact? #i3/2)
                  (exact (inexact 42))
                  (= #e1.0 1)
                  (number->string #e1.5)
                  (number->string (inexact 3/2))
                  (number->string 42 16)
                  (string->number \"2a\" 16)
                  (string->number \"not-a-number\"))")
          "(#t #t 42 #t \"3/2\" \"1.5\" \"2a\" 42 #f)")))

(ert-deftest consent-base-test-numeric-tower-complex-and-special-values ()
  "Evaluate representative complex arithmetic and inexact special predicates."
  (should
   (equal (consent-base-test--external
           "(import (scheme complex))
            (list (+ 1+2i 3/4-1/2i)
                  (* 1+2i 3-4i)
                  (real? 3+0i)
                  (real? 3+0.0i)
                  (integer? 3+0i)
                  (real-part 3/4-1/2i)
                  (imag-part 3/4-1/2i))")
          "(7/4+3/2i 11+2i #t #f #t 3/4 -1/2)"))
  (should
   (equal (consent-base-test--external
           "(import (scheme inexact))
            (list (real? +inf.0)
                  (rational? +inf.0)
                  (infinite? +inf.0)
                  (finite? 3/2)
                  (nan? +nan.0)
                  (= +nan.0 +nan.0))")
          "(#t #f #t #t #t #f)")))

(ert-deftest consent-base-test-inexact-transcendentals ()
  "Evaluate representative real-valued `(scheme inexact)' procedures."
  (should
   (equal (consent-base-test--external
           "(import (scheme inexact))
            (list (sqrt 9)
                  (sin 0)
                  (cos 0)
                  (tan 0)
                  (exp 0)
                  (log 1))")
          "(3.0 0.0 1.0 0.0 1.0 0.0)")))

(ert-deftest consent-base-test-numeric-tower-polar-special-values ()
  "Evaluate polar complex operations with canonical inexact special values."
  (should
   (equal (consent-base-test--external
           "(import (scheme complex))
            (list (make-polar +inf.0 0)
                  (make-polar 1 +inf.0)
                  (make-polar +nan.0 0))")
          "(+inf.0+nan.0i +nan.0+nan.0i +nan.0+nan.0i)")))

(ert-deftest consent-base-test-vectors-bytevectors-and-higher-order-calls ()
  "Evaluate vector, bytevector, apply, map, and for-each procedures."
  (should
   (equal (consent-base-test--external
           "(define v (vector 'a 'b 'c))
            (vector-set! v 1 'changed)
            v")
          "#(a changed c)"))
  (should
   (equal (consent-base-test--external
           "(define b (bytevector 1 2 3))
            (bytevector-u8-set! b 1 9)
            b")
          "#u8(1 9 3)"))
  (should
   (equal (consent-base-test--external "(apply + 1 '(2 3 4))")
          "10"))
  (should
   (equal (consent-base-test--external
           "(map (lambda (x) (* x x)) '(2 3 4))")
          "(4 9 16)"))
  (should
   (equal (consent-base-test--external
           "(define total 0)
            (for-each (lambda (x) (set! total (+ total x))) '(1 2 3))
            total")
          "6"))
  (should
   (equal (consent-base-test--external
           "(string-map
              (lambda (c) c)
              \"HAL\")")
          "\"HAL\""))
  (should
   (equal (consent-base-test--external
           "(let ((chars '()))
              (string-for-each
                (lambda (c) (set! chars (cons c chars)))
                \"abc\")
              chars)")
          "(#\\c #\\b #\\a)"))
  (should
   (equal (consent-base-test--external
           "(vector-map + '#(1 2 3) '#(4 5 6 7))")
          "#(5 7 9)"))
  (should
   (equal (consent-base-test--external
           "(let ((result (make-list 3)))
              (vector-for-each
                (lambda (index)
                  (list-set! result index (* index index)))
                '#(0 1 2))
              result)")
          "(0 1 4)"))
  (should
   (equal (consent-base-test--external
           "(list
              (string-length \"abc\")
              (vector-length '#(a b c d))
              (bytevector-length #u8(1 2 3 4 5)))")
          "(3 4 5)")))

(ert-deftest consent-base-test-arity-type-errors-and-result-rendering ()
  "Cover primitive errors and stable Scheme-readable result records."
  (should-error (consent-eval-source "(car '())")
                :type 'consent-eval-error)
  (should-error (consent-eval-source "(+ 1 \"bad\")")
                :type 'consent-eval-error)
  (should-error (consent-eval-source "(map + '(1 2) 3)")
                :type 'consent-eval-error)
  (should
   (equal (consent-result->external
           (consent-eval-source-result "(+ 1 2)"))
          "(evaluation-result (status ok) (value 3) (events ()) (budget\
 (steps-used 5) (host-calls 1)))"))
  (let ((error-result
         (consent-result->external
          (consent-eval-source-result "(car '())"))))
    (should
     (string-match-p
      (regexp-quote
       "(evaluation-result (status error) (error (condition (condition (type\
 type-error)")
      error-result))
    (should
     (string-match-p
      (regexp-quote "(message \"car expected pair, got ()\")")
      error-result))
    (should
     (string-match-p
      (regexp-quote "(restarts ((restart (id abort)")
      error-result))))

;;; consent-base-test.el ends here
