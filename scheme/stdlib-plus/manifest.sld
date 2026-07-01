;;; Portable stdlib-plus support manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library records optional stdlib-plus support as Scheme-readable data.
;;; It is source-loaded by each bootstrap so vendored, shimmed, or owned
;;; SRFI/R7RS-large implementations stay visible to tools without querying host
;;; state.

(define-library (srfi manifest)
  (export srfi-manifest srfi-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe optional libraries owned or surfaced locally.
    (define srfi-manifest
      '(((library . (srfi 180))
         (status . direct-portable-implementation)
         (source-url . "https://github.com/scheme-requests-for-implementation/srfi-180")
         (upstream-revision . "671857bac55c53e3190a24ec53b457321a1d8f12")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ())
         (implementation-library . (consent json))
         (import-aliases . ((srfi 180) (srfi srfi-180)))
         (dependencies . ((consent json)))
         (test-status . (import-resolution representative-read-write
                         emacs-json-oracle portable-host-suite)))
        ((library . (srfi srfi-180))
         (status . alias)
         (target . (srfi 180))
         (import-aliases . ((srfi srfi-180)))
         (dependencies . ((srfi 180)))
         (test-status . (import-resolution)))
        ((library . (scheme comparator))
         (status . vendored-adapted-implementation)
         (source-url . "https://github.com/scheme-requests-for-implementation/srfi-128")
         (upstream-revision . "3ec333638e787d75a16de83fcf9645c998e4d976")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((library-name
                            (from . (srfi 128))
                            (to . (scheme comparator)))
                           (inlined-includes
                            (files "srfi/128.body1.scm" "srfi/128.body2.scm"))
                           (documentation-metadata
                            (scope exported-procedures))
                           (default-hash
                            (source local-portable-implementation))))
         (implementation-library . (scheme comparator))
         (import-aliases . ((scheme comparator) (srfi 128) (srfi srfi-128)))
         (dependencies . ((scheme base) (scheme case-lambda) (scheme char)
                          (scheme inexact) (scheme complex)))
         (test-status . (import-resolution representative-comparator-behavior
                         alias-import missing-export-diagnostic
                         portable-host-suite)))
        ((library . (srfi 128))
         (status . alias)
         (target . (scheme comparator))
         (import-aliases . ((srfi 128)))
         (dependencies . ((scheme comparator)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-128))
         (status . alias)
         (target . (scheme comparator))
         (import-aliases . ((srfi srfi-128)))
         (dependencies . ((scheme comparator)))
         (test-status . (import-resolution)))))

    (define (srfi-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Stdlib-plus library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest srfi-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
