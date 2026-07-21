;;; Portable owned-symbol and symbol-table tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (consent character)
        (consent reader)
        (only (consent runtime)
              consent-host-datum->consent-datum)
        (consent symbol)
        (only (consent library)
              consent-native-argument-value
              consent-runtime-datum->native-datum)
        (data avl-tree)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (raises? thunk)
  "Return #t when THUNK raises a Scheme condition."
  (guard (condition
          (else #t))
    (thunk)
    #f))

(define (numbered-symbol-name index)
  "Return the deterministic symbol name for INDEX."
  (string-append "owned-symbol-" (number->string index)))

;; Keep compiled-host stress bounded while direct hosts exercise full volume.
(define symbol-volume-host-run?
  (let ((value (get-environment-variable "TESTING_RUNNER_HOST_RUN")))
    (and value (string=? value "1"))))

(define (all-symbols-reintern? table symbols count)
  "Return whether SYMBOLS are TABLE's identities for COUNT numbered names."
  (let loop ((index (- count 1)) (rest symbols))
    (or (< index 0)
        (and (pair? rest)
             (eq? (car rest)
                  (consent-intern-symbol table
                                         (numbered-symbol-name index)))
             (loop (- index 1) (cdr rest))))))

(testing-registry-case
 'owned-symbol-records '(portable runtime symbol)
(let ((symbol (consent-intern-symbol
               (consent-make-symbol-table)
               "portable")))
  (test-assert 'owned-symbol-predicate (consent-symbol? symbol))
  (test-assert
   'language-symbol-recognized
   (if symbol-volume-host-run?
       (consent-symbol? 'portable)
       (not (consent-symbol? 'portable))))
  (test-equal 'immutable-symbol-name "portable" (consent-symbol-name symbol))))

(testing-registry-case
 'repeated-interning '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (first (consent-intern-symbol table "same"))
       (second (consent-intern-symbol table "same")))
  (test-assert 'repeated-interning (eq? first second))
  (test-equal 'single-root-entry
              1
              (avl-tree-size (consent-symbol-table-root table)))))

(testing-registry-case
 'native-argument-symbol-marshalling '(portable runtime symbol boundary)
(let* ((table (consent-make-symbol-table))
       (owned (consent-intern-symbol table "native-generated"))
       (original (list owned (vector owned)))
       (converted (consent-native-argument-value original #f))
       (converted-list-symbol (car converted))
       (converted-vector-symbol (vector-ref (cadr converted) 0))
       (host-only (list 'already-host #(1 "two"))))
  (test-assert
   'native-argument-symbol-crosses-runtime-boundary
   (and (symbol? converted-list-symbol)
        (if symbol-volume-host-run?
            (consent-symbol? converted-list-symbol)
            (not (consent-symbol? converted-list-symbol)))))
  (test-equal 'native-argument-symbol-keeps-name
              "native-generated"
              (symbol->string converted-list-symbol))
  (test-assert 'native-argument-symbol-reuses-host-interning
               (eq? converted-list-symbol converted-vector-symbol))
  (test-assert 'native-argument-marshalling-does-not-mutate-input
               (and (eq? (car original) owned)
                    (eq? (vector-ref (cadr original) 0) owned)))
  (test-assert 'native-argument-marshalling-rebuilds-changed-path
               (not (eq? original converted)))
  (let ((converted-host-only
         (consent-native-argument-value host-only #f)))
    (test-assert
     'native-argument-marshalling-hides-host-symbols-from-language
     (if symbol-volume-host-run?
         (and (not (eq? host-only converted-host-only))
              (consent-symbol? (car converted-host-only)))
         (eq? host-only converted-host-only))))))

(testing-registry-case
 'native-result-long-list-egress '(portable runtime symbol boundary stress)
(let* ((table (consent-make-symbol-table))
       (owned (consent-intern-symbol table "egress"))
       (count (if symbol-volume-host-run? 128 4096))
       (datum
        (let loop ((index 0) (result '()))
          (if (= index count)
              result
              (loop (+ index 1)
                    (cons (list owned owned) result)))))
       (converted (consent-runtime-datum->native-datum datum)))
  (test-equal 'native-result-long-list-length count (length converted))
  (test-equal 'native-result-long-list-first-name
              "egress"
              (symbol->string (car (car converted))))
  (test-assert
   'native-result-long-list-symbol-domain
   (if symbol-volume-host-run?
       (consent-symbol? (car (car converted)))
       (not (consent-symbol? (car (car converted))))))))

(testing-registry-case
 'native-result-cyclic-spine-is-conservative
 '(portable runtime symbol boundary)
(let ((cycle (cons 'cycle '())))
  (set-cdr! cycle cycle)
  (test-assert
   'native-result-cyclic-spine-keeps-identity
   (eq? cycle (consent-runtime-datum->native-datum cycle)))))

(testing-registry-case
 'owned-character-native-boundary-roundtrip
 '(portable runtime character boundary)
(let* ((owned (consent-make-character #x3bb))
       (runtime-datum (list owned (vector owned)))
       (native-argument
        (consent-native-argument-value runtime-datum #f))
       (native-result
        (consent-runtime-datum->native-datum runtime-datum))
       (roundtrip
        (consent-host-datum->consent-datum native-result)))
  (test-assert
   'owned-character-native-argument-is-host-character
   (and (char? (car native-argument))
        (= (char->integer (car native-argument)) #x3bb)
        (char? (vector-ref (cadr native-argument) 0))))
  (test-assert
   'owned-character-native-result-is-host-character
   (and (char? (car native-result))
        (= (char->integer (car native-result)) #x3bb)))
  (test-assert
   'owned-character-native-result-roundtrips
   (and (consent-character? (car roundtrip))
        (= (consent-character-code (car roundtrip)) #x3bb)
        (consent-character?
         (vector-ref (cadr roundtrip) 0))))))

(testing-registry-case
 'mutable-input-name-is-not-retained '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (name (string-copy "mutable"))
       (first (consent-intern-symbol table name)))
  (string-set! name 0 #\f)
  (let ((second (consent-intern-symbol table "mutable")))
    (test-assert 'mutated-input-does-not-poison-cache (eq? first second))
    (test-equal 'owned-name-remains-immutable
                "mutable"
                (consent-symbol-name second)))))

(testing-registry-case
 'returned-name-cannot-mutate-owned-symbol '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (symbol (consent-intern-symbol table "immutable"))
       (exposed (consent-symbol-name symbol)))
  (string-set! exposed 0 #\m)
  (test-equal 'returned-name-is-an-isolated-copy
              "immutable"
              (consent-symbol-name symbol))
  (test-assert 'returned-name-mutation-does-not-poison-table
               (eq? symbol
                    (consent-intern-symbol table "immutable")))))

(testing-registry-case
 'shared-root-branches '(portable runtime symbol)
(let* ((origin (consent-make-symbol-table))
       (inherited (consent-intern-symbol origin "inherited"))
       (root (consent-symbol-table-root origin))
       (left (consent-symbol-table-from-root root))
       (right (consent-symbol-table-from-root root))
       (left-inherited (consent-intern-symbol left "inherited"))
       (right-inherited (consent-intern-symbol right "inherited"))
       (left-only (consent-intern-symbol left "left-only"))
       (left-new (consent-intern-symbol left "new-in-both"))
       (right-new (consent-intern-symbol right "new-in-both")))
  (test-assert 'root-is-public-avl-tree (avl-tree? root))
  (test-assert 'inherited-record-is-shared
               (and (eq? inherited left-inherited)
                    (eq? inherited right-inherited)))
  (test-assert 'branch-local-insertion
               (and (avl-tree-contains?
                     (consent-symbol-table-root left)
                     "left-only")
                    (not (avl-tree-contains?
                          (consent-symbol-table-root right)
                          "left-only"))))
  (test-assert 'left-only-is-owned (consent-symbol? left-only))
  (test-assert 'branch-new-identities-are-isolated-but-equivalent
               (and (if symbol-volume-host-run?
                        (eq? left-new right-new)
                        (not (eq? left-new right-new)))
                    (consent-symbol-equivalent? left-new right-new)))))

(testing-registry-case
 'isolated-root-name-equivalence '(portable runtime symbol)
(let* ((left-table (consent-make-symbol-table))
       (right-table (consent-make-symbol-table))
       (left (consent-intern-symbol left-table "transported"))
       (right (consent-intern-symbol right-table "transported")))
  (test-assert
   'isolated-symbols-follow-language-equality
   (if symbol-volume-host-run?
       (eq? left right)
       (not (eq? left right))))
  (test-assert 'same-name-equivalence
               (consent-symbol-equivalent? left right))
  (test-assert 'variadic-name-equality
               (consent-symbol=? left right left))
  (test-assert 'different-names-are-not-equal
               (not (consent-symbol=?
                     left
                     (consent-intern-symbol right-table "different"))))))

(testing-registry-case
 'root-installation-is-handle-local '(portable runtime symbol)
(let* ((base (consent-make-symbol-table))
       (root (consent-symbol-table-root base))
       (source (consent-symbol-table-from-root root))
       (sibling (consent-symbol-table-from-root root)))
  (consent-intern-symbol source "installed")
  (consent-symbol-table-root-set!
   base
   (consent-symbol-table-root source))
  (test-assert 'installed-root-visible
               (avl-tree-contains?
                (consent-symbol-table-root base)
                "installed"))
  (test-assert 'sibling-root-unchanged
               (not (avl-tree-contains?
                     (consent-symbol-table-root sibling)
                     "installed")))))

(testing-registry-case
 'root-installation-discards-pending-overlay '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (kept (consent-intern-symbol table "kept"))
       (root (consent-symbol-table-root table))
       (discarded (consent-intern-symbol table "discarded")))
  (consent-symbol-table-root-set! table root)
  (let ((replacement (consent-intern-symbol table "discarded")))
    (test-assert 'installed-root-retains-shared-identity
                 (eq? kept (consent-intern-symbol table "kept")))
    (test-assert
     'pending-symbol-identity-follows-language-equality
     (if symbol-volume-host-run?
         (eq? discarded replacement)
         (not (eq? discarded replacement))))
    (test-assert 'discarded-name-remains-equivalent
                 (consent-symbol-equivalent? discarded replacement)))))

(testing-registry-case
 'symbol-table-hash-collision-and-resize-stress '(portable runtime symbol stress)
(let* ((table (consent-make-symbol-table))
       ;; These names have the same complete portable hash, not merely the
       ;; same initial bucket.
       (collision-left (consent-intern-symbol table "ab"))
       (collision-right (consent-intern-symbol table "bA"))
       (count 300)
       (symbols
        (let loop ((index 0) (result '()))
          (if (= index count)
              result
              (loop (+ index 1)
                    (cons (consent-intern-symbol
                           table
                           (numbered-symbol-name index))
                          result))))))
  (test-assert 'actual-hash-collision-keeps-distinct-symbols
               (and (not (eq? collision-left collision-right))
                    (string=? "ab" (consent-symbol-name collision-left))
                    (string=? "bA" (consent-symbol-name collision-right))))
  (test-assert 'bulk-symbol-identities-survive-resizes
               (all-symbols-reintern? table symbols count))
  (test-equal 'bulk-root-has-one-entry-per-name
              (+ count 2)
              (avl-tree-size (consent-symbol-table-root table)))))

(testing-registry-case
 'symbol-table-volume-and-snapshot-stress '(portable runtime symbol stress)
(let* ((table (consent-make-symbol-table))
       ;; Direct R7RS hosts exercise the large workload natively.  The compiled
       ;; host-run path interprets this test, so retain a multi-resize workload
       ;; there without adding tens of seconds to every compiled shard.
       (count (if symbol-volume-host-run? 64 4096))
       (branch-count (if symbol-volume-host-run? 16 1024))
       (symbols
        (let loop ((index 0) (result '()))
          (if (= index count)
              result
              (loop (+ index 1)
                    (cons (consent-intern-symbol
                           table
                           (numbered-symbol-name index))
                          result)))))
       (snapshot (consent-symbol-table-root table))
       (branch (consent-symbol-table-from-root snapshot)))
  (test-assert 'volume-reinterning-preserves-every-identity
               (all-symbols-reintern? table symbols count))
  (let loop ((index 0))
    (if (< index branch-count)
        (begin
          (consent-intern-symbol
           branch
           (string-append "branch-symbol-" (number->string index)))
          (loop (+ index 1)))))
  (test-equal 'volume-snapshot-size
              count
              (avl-tree-size snapshot))
  (test-equal 'volume-branch-size
              (+ count branch-count)
              (avl-tree-size (consent-symbol-table-root branch)))
  (test-equal 'volume-origin-remains-at-snapshot
              count
              (avl-tree-size (consent-symbol-table-root table)))))

(testing-registry-case
 'symbol-table-contracts '(portable runtime symbol)
(let* ((table (consent-make-symbol-table))
       (left (consent-intern-symbol table "left")))
  (test-assert 'equivalence-rejects-non-owned-values
               (and (not (consent-symbol-equivalent? left "left"))
                    (not (consent-symbol-equivalent? "left" left))))
  (test-assert 'symbol-name-rejects-non-symbol
               (raises? (lambda () (consent-symbol-name "left"))))
  (test-assert 'symbol-equality-rejects-non-symbol
               (raises? (lambda () (consent-symbol=? left "left"))))
  (test-assert 'intern-rejects-non-table
               (raises? (lambda () (consent-intern-symbol 'table "left"))))
  (test-assert 'intern-rejects-non-string
               (raises? (lambda () (consent-intern-symbol table 'left))))
  (test-assert 'root-constructor-rejects-non-tree
               (raises? (lambda () (consent-symbol-table-from-root 'root))))
  (test-assert 'root-access-rejects-non-table
               (raises? (lambda () (consent-symbol-table-root 'table))))
  (test-assert 'root-set-rejects-non-tree
               (raises?
                (lambda () (consent-symbol-table-root-set! table 'root))))))

(testing-registry-case
 'process-default-table '(portable runtime symbol)
(let ((first (consent-intern-symbol consent-default-symbol-table
                                    "process-default"))
      (second (consent-intern-symbol consent-default-symbol-table
                                     "process-default")))
  (test-assert 'process-default-table (eq? first second))))

(testing-registry-case
 'reader-interns-owned-symbols '(portable reader runtime symbol)
(let* ((table (consent-make-symbol-table))
       (options (list (cons 'symbol-table table)))
       (ordinary (consent-read "identifier" options))
       (vertical (consent-read "|identifier|" options))
       (quoted (consent-read "'identifier" options))
       (quasiquoted (consent-read "`(,identifier ,@identifiers)" options))
       (incremental (car (consent-read-from-string-at "identifier rest"
                                                       0
                                                       options))))
  (test-assert 'ordinary-owned-symbol (consent-symbol? ordinary))
  (test-assert 'vertical-shares-identity (eq? ordinary vertical))
  (test-assert 'incremental-shares-identity (eq? ordinary incremental))
  (test-assert 'quote-head-owned
               (and (consent-symbol? (car quoted))
                    (string=? "quote"
                              (consent-symbol-name (car quoted)))))
  (test-assert 'quoted-identifier-shares-identity
               (eq? ordinary (cadr quoted)))
  (test-assert 'quote-family-heads-are-owned
               (let* ((body (cadr quasiquoted))
                      (unquoted (car body))
                      (spliced (cadr body)))
                 (and (consent-symbol? (car quasiquoted))
                      (consent-symbol? (car unquoted))
                      (consent-symbol? (car spliced)))))))

(testing-registry-case
 'reader-default-table-and-recovery '(portable reader runtime symbol)
(let* ((first (consent-read "reader-default"))
       (second (consent-read "reader-default"))
       (recovery (consent-read-recover "broken )\nreader-default"))
       (datums (consent-recovery-result-datums recovery)))
  (test-assert 'reader-default-owned (consent-symbol? first))
  (test-assert 'reader-default-shares-identity (eq? first second))
  (test-assert 'recovery-owned-symbol
               (let loop ((rest datums))
                 (and (pair? rest)
                      (or (eq? first (car rest))
                          (loop (cdr rest))))))))

(testing-registry-case
 'reader-owned-symbols-do-not-consume-source-metadata
 '(portable reader runtime symbol)
(let ((symbol
       (consent-read
        "metadata-free-symbol"
        '((source-metadata . #t)
          (max-source-metadata . 0)))))
  (test-assert 'owned-symbol-read-under-zero-metadata-budget
               (and (consent-symbol? symbol)
                    (string=? "metadata-free-symbol"
                              (consent-symbol-name symbol))))))

(testing-runner-main "Consent owned symbols" (command-line))
