;;; consent-script-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Coverage for `consent-script': the narrow shebang recognition rule, the
;; line-preserving strip, the `consent-script-run-file' batch equivalent of the
;; runtime's `--script', and the noninteractive fail-closed policy posture a
;; script inherits.  Kept at parity with tests/scheme/consent-script-test.scm.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-script)
(require 'consent-policy)
(require 'consent-audit)

(defconst consent-script-test--sh-polyglot
  (concat "#!/bin/sh\n"
          "#|\n"
          "exec consent-scheme --script \"$0\" \"$@\"\n"
          "|#\n"
          "(display \"hi\\n\")\n")
  "The `/bin/sh' polyglot recommended in docs/executable-scripts.md.")

(defun consent-script-test--write (contents)
  "Write CONTENTS to a fresh temp file and return its path."
  (let ((path (make-temp-file "consent-script-test-" nil ".scm")))
    (with-temp-file path (insert contents))
    path))

;;;; Narrow recognition rule

(ert-deftest consent-script-test-recognizes-shebang-lines ()
  "Recognize `#!' followed by `/' or whitespace as a shebang."
  (should (consent-script-shebang-line-p
    "#!/usr/bin/env consent-scheme --script"))
  (should (consent-script-shebang-line-p "#!/bin/sh\n"))
  (should (consent-script-shebang-line-p "#! /bin/sh\n"))
  (should (consent-script-shebang-line-p "#!\tfoo\n")))

(ert-deftest consent-script-test-leaves-directive-tokens ()
  "Do not treat `#!'-tokens or indented `#!' as shebang lines."
  (should-not (consent-script-shebang-line-p "#!fold-case\n(x)"))
  (should-not (consent-script-shebang-line-p "#!r6rs"))
  (should-not (consent-script-shebang-line-p "#!"))
  (should-not (consent-script-shebang-line-p " #!/bin/sh"))
  (should-not (consent-script-shebang-line-p "(display 1)\n")))

;;;; Line-preserving strip

(ert-deftest consent-script-test-strip-keeps-line-numbers ()
  "Consume the shebang text but keep its terminating newline as a blank line."
  (should (equal (consent-script-strip-shebang "#!/bin/sh\n(display 1)\n")
                 "\n(display 1)\n"))
  (should (equal (consent-script-strip-shebang "#!/bin/sh/no/newline") ""))
  (should (equal (consent-script-strip-shebang "#!fold-case\n(x)")
                 "#!fold-case\n(x)"))
  (should (equal (consent-script-strip-shebang "(display 1)\n")
                 "(display 1)\n")))

;;;; Batch run-file equivalent of --script

(ert-deftest consent-script-test-run-file-runs-polyglot ()
  "Run a shebang + `/bin/sh' polyglot script directly through the batch path."
  (let ((path (consent-script-test--write
               (concat "#!/bin/sh\n"
                       "#|\nexec consent-scheme --script \"$0\" \"$@\"\n|#\n"
                       "(define (greet who) (string-append \"hi \" who))\n"
                       "(greet \"world\")\n"))))
    (unwind-protect
        (should (equal (consent-value->external
                        (consent-script-run-file path))
                               "\"hi world\""))
      (delete-file path))))

(ert-deftest consent-script-test-run-file-normalizes-command-line ()
  "Expose script command-line as the script path followed by user arguments."
  (let ((path (consent-script-test--write
               (concat "#!/usr/bin/env consent-scheme\n"
                       "(import (scheme base) (scheme process-context))\n"
                       "(command-line)\n"))))
    (unwind-protect
        (should
         (equal
          (consent-value->external
           (consent-script-run-file path nil nil '("alpha" "beta")))
          (consent-value->external (list path "alpha" "beta"))))
      (delete-file path))))

(ert-deftest consent-script-test-run-file-reports-line-numbers ()
  "Keep datum line numbers aligned with the file despite the stripped shebang."
  (let ((source (consent-script-source-from-file
                 (consent-script-test--write
                   consent-script-test--sh-polyglot))))
    ;; The polyglot's program form is on line 5 of the original file; the strip
    ;; preserves that by leaving a blank first line in place of the shebang.
    (should (string-prefix-p "\n#|" source))))

;;;; Fail-closed policy posture

(ert-deftest consent-script-test-run-file-fails-closed ()
  "Deny a confirm-gated action in a script with a Scheme-readable audit\
 record."
  (let ((path (consent-script-test--write
               (concat "#!/usr/bin/env consent-scheme --script\n"
                       "(import (scheme base) (scheme file))\n"
                       "(file-exists?\
 \"fixtures/r7rs/conformance-cases.scm\")\n"))))
    (unwind-protect
        (progn
          (consent-audit-clear)
          (should-error (consent-script-run-file path)
                        :type 'consent-policy-error)
          (should
           (seq-find
            (lambda (entry)
              (and (string-match-p (regexp-quote
                "(category standard-host-effect)") entry)
                   (string-match-p (regexp-quote
                     "(operation \"file-exists?\")") entry)
                   (string-match-p (regexp-quote "(decision denied)") entry)))
            (mapcar #'consent-result->external
                    (consent-audit-recent-entries)))))
      (delete-file path))))

;;; consent-script-test.el ends here
