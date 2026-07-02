;;; Portable stdlib support manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library records optional stdlib support as Scheme-readable data.
;;; It is source-loaded by each bootstrap so vendored, shimmed, or owned
;;; SRFI/R7RS-large implementations stay visible to tools without querying host
;;; state.

(define-library (stdlib manifest)
  (export stdlib-manifest stdlib-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe optional libraries owned or surfaced locally.
    (define stdlib-manifest
      '(((library . (stdlib json))
         (status . direct-portable-implementation)
         (source-url . "https://github.com/scheme-requests-for-implementation/srfi-180")
         (upstream-revision . "671857bac55c53e3190a24ec53b457321a1d8f12")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ())
         (implementation-library . (stdlib json))
         (import-aliases . ((stdlib json) (consent json)
                            (srfi 180) (srfi srfi-180)))
         (dependencies . ((stdlib and-let-star)))
         (test-status . (import-resolution representative-read-write
                         emacs-json-oracle portable-host-suite)))
        ((library . (consent json))
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((consent json)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-180))
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((srfi srfi-180)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi 180))
         (status . alias)
         (target . (stdlib json))
         (import-aliases . ((srfi 180)))
         (dependencies . ((stdlib json)))
         (test-status . (import-resolution)))
        ((library . (srfi 16))
         (status . built-in-shim)
         (source . built-in-shim)
         (source-url . "https://srfi.schemers.org/srfi-16/")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (target . (scheme case-lambda))
         (implementation-library . (scheme case-lambda))
         (import-aliases . ((srfi 16) (srfi srfi-16)))
         (dependencies . ((scheme case-lambda)))
         (test-status . (import-resolution representative-case-lambda-behavior
                         missing-export-diagnostic portable-host-suite)))
        ((library . (srfi srfi-16))
         (status . alias)
         (target . (scheme case-lambda))
         (import-aliases . ((srfi srfi-16)))
         (dependencies . ((scheme case-lambda)))
         (test-status . (import-resolution)))
        ((library . (stdlib and-let-star))
         (status . vendored-adapted-implementation)
         (source-url . "https://okmij.org/ftp/Scheme/lib/myenv-chez.scm")
         (source-test-url . "https://okmij.org/ftp/Scheme/tests/vland.scm")
         (upstream-revision . "myenv-chez.scm,v 1.7 2006/01/19 02:14:07")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((define-library-wrapper
                            (library . (stdlib and-let-star)))
                           (registry-aliases
                            (aliases (srfi 2) (srfi srfi-2)))
                           (adapted-tests
                            (file . "tests/scheme/stdlib-and-let-star-test.scm"))))
         (implementation-library . (stdlib and-let-star))
         (import-aliases . ((stdlib and-let-star) (srfi 2) (srfi srfi-2)))
         (dependencies . ((scheme base)))
         (test-status . (import-resolution representative-and-let-star-behavior
                         missing-export-diagnostic adapted-upstream-tests
                         portable-host-suite)))
        ((library . (srfi 2))
         (status . alias)
         (target . (stdlib and-let-star))
         (import-aliases . ((srfi 2)))
         (dependencies . ((stdlib and-let-star)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-2))
         (status . alias)
         (target . (stdlib and-let-star))
         (import-aliases . ((srfi srfi-2)))
         (dependencies . ((stdlib and-let-star)))
         (test-status . (import-resolution)))
        ((library . (stdlib comparator))
         (status . vendored-adapted-implementation)
         (source-url . "https://github.com/scheme-requests-for-implementation/srfi-128")
         (upstream-revision . "3ec333638e787d75a16de83fcf9645c998e4d976")
         (upstream-license . "MIT")
         (local-license . "MIT")
         (vendored? . #t)
         (local-patches . ((library-name
                            (from . (srfi 128))
                            (to . (stdlib comparator)))
                           (inlined-includes
                            (files "srfi/128.body1.scm" "srfi/128.body2.scm"))
                           (documentation-metadata
                            (scope exported-procedures))
                           (default-hash
                            (source local-portable-implementation))
                           (stateful-hasher
                            (source upstream-style-case-lambda))
                           (hash-helpers
                            (source local-portable-procedures))))
         (implementation-library . (stdlib comparator))
         (import-aliases . ((stdlib comparator) (scheme comparator)
                            (srfi 128) (srfi srfi-128)))
         (dependencies . ((scheme base) (scheme case-lambda) (scheme char)
                          (scheme inexact) (scheme complex)))
         (test-status . (import-resolution representative-comparator-behavior
                         alias-import missing-export-diagnostic
                         portable-host-suite)))
        ((library . (scheme comparator))
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((scheme comparator)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))
        ((library . (srfi 128))
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((srfi 128)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))
        ((library . (srfi srfi-128))
         (status . alias)
         (target . (stdlib comparator))
         (import-aliases . ((srfi srfi-128)))
         (dependencies . ((stdlib comparator)))
         (test-status . (import-resolution)))))

    (define (stdlib-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "Stdlib library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest stdlib-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
