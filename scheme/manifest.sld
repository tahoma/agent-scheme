;;; Top-level Scheme collection manifest index.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This load-light index links collection-local manifests to their source
;;; roots. Collection manifests keep source-file paths relative to their own
;;; domain; this index is the boundary that gives those paths repository
;;; meaning.

(define-library (manifest index)
  (export manifest-index manifest-index-ref)
  (import (scheme base))
  (begin
    ;; Index entries link collection-local manifests to their source roots.
    (define manifest-index
      '(((collection . manifest)
         (category . manifest)
         (manifest-library . (manifest index))
         (manifest-variable . manifest-index-manifest)
         (manifest-file . "manifest.sld")
         (source-root . ""))
        ((collection . consent)
         (category . consent)
         (manifest-library . (consent manifest))
         (manifest-variable . consent-library-manifest)
         (manifest-file . "consent/manifest.sld")
         (source-root . "consent/"))
        ((collection . stdlib)
         (category . stdlib)
         (manifest-library . (stdlib manifest))
         (manifest-variable . stdlib-manifest)
         (manifest-file . "stdlib/manifest.sld")
         (source-root . "stdlib/"))
        ((collection . agent)
         (category . agent)
         (manifest-library . (agent manifest))
         (manifest-variable . agent-library-manifest)
         (manifest-file . "agent/manifest.sld")
         (source-root . "agent/"))
        ((collection . cli)
         (category . cli)
         (manifest-library . (cli manifest))
         (manifest-variable . cli-library-manifest)
         (manifest-file . "cli/manifest.sld")
         (source-root . "cli/"))
        ((collection . emacs)
         (category . emacs)
         (manifest-library . (emacs manifest))
         (manifest-variable . emacs-library-manifest)
         (manifest-file . "emacs/manifest.sld")
         (source-root . "emacs/"))))

    ;; Manifest entry exposing this index as an ordinary source library.
    (define manifest-index-manifest
      '(((library . (manifest index))
         (visibility . public)
         (layer . manifest)
         (status . implemented)
         (source-kind . source-library)
         (source-file . "manifest.sld")
         (implementation-library . (manifest index))
         (exports . (manifest-index manifest-index-ref))
         (owner . consent)
         (provider . repo-source)
         (dependencies . ((scheme base))))))

    (define (manifest-index-ref collection)
      "Return collection manifest metadata for COLLECTION, or #f."
      #((parameters
         (collection (type symbol)
          (description "Collection name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest index entry for COLLECTION, or #f."))
        (effects pure))
      (let loop ((rest manifest-index))
        (cond
         ((null? rest) #f)
         ((eq? (cdr (assq 'collection (car rest))) collection)
          (car rest))
         (else (loop (cdr rest))))))))
