;;; agent-scheme-scheme-host-helper-test.el --- Portable host bridge helper tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the multi-host portable R7RS bridge used by CI host shards.

;;; Code:

(require 'ert)
(require 'agent-scheme-scheme-host)

(ert-deftest agent-scheme-portable-host-helper-test-builds-gauche-arguments ()
  "Build Gauche R7RS arguments with the target library path before the test file."
  (should
   (equal
    (agent-scheme--scheme-host-arguments
     'gauche
     "scheme"
     "tests/scheme/agent-scheme-reader-test.scm")
    '("-I" "scheme" "-r7" "tests/scheme/agent-scheme-reader-test.scm"))))

(ert-deftest agent-scheme-portable-host-helper-test-builds-guile-arguments ()
  "Build Guile R7RS arguments with auto-compilation disabled."
  (should
   (equal
    (agent-scheme--scheme-host-arguments
     'guile
     "scheme"
     "tests/scheme/agent-scheme-reader-test.scm")
    '("--no-auto-compile"
      "--r7rs"
      "-L"
      "scheme"
      "tests/scheme/agent-scheme-reader-test.scm"))))

(ert-deftest agent-scheme-portable-host-helper-test-builds-racket-collection ()
  "Generate Racket collection wrappers from portable `.sld' libraries."
  (let* ((source-root (make-temp-file "agent-scheme-racket-source-" t))
         (library-root (expand-file-name "scheme" source-root))
         (target-root (make-temp-file "agent-scheme-racket-target-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "agent-scheme" library-root) t)
          (with-temp-file
              (expand-file-name "agent-scheme/example.sld" library-root)
            (insert "(define-library (agent-scheme example)\n")
            (insert "  (export example)\n")
            (insert "  (import (scheme base))\n")
            (insert "  (begin (define example 'ok)))\n"))
          (make-directory (expand-file-name "agent" library-root) t)
          (with-temp-file
              (expand-file-name "agent/example.sld" library-root)
            (insert "(define-library (agent example)\n")
            (insert "  (export example)\n")
            (insert "  (import (scheme base))\n")
            (insert "  (begin (define example 'ok)))\n"))
          (let ((collection-root
                 (agent-scheme--scheme-host-racket-collection-root
                  library-root
                  target-root)))
            (should
             (equal
              (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "agent-scheme/example.rkt" collection-root))
                (buffer-string))
              (concat
               "#lang r7rs\n"
               "(define-library (agent-scheme example)\n"
               "  (export example)\n"
               "  (import (scheme base))\n"
               "  (begin (define example 'ok)))\n")))
            (should
             (file-exists-p
              (expand-file-name "agent/example.rkt" collection-root)))))
      (delete-directory source-root t)
      (delete-directory target-root t))))

(provide 'agent-scheme-scheme-host-helper-test)

;;; agent-scheme-scheme-host-helper-test.el ends here
