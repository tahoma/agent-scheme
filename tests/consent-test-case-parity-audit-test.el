;;; consent-test-case-parity-audit-test.el --- Test ownership audit  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Validate the Scheme-data ownership map that connects retained ERT surfaces
;; to canonical portable programs and partitions exact mixed surfaces.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'consent-reader)
(require 'consent-test-helper)

(defconst consent-test-case-parity-audit-map-file
  "tests/scheme/ert-portable-parity-map.scm"
  "Repository-relative ERT-to-portable ownership map.")

(defconst consent-test-case-parity-audit-plan-file
  "tests/scheme/test-plan.scm"
  "Repository-relative portable Scheme test plan.")

(defun consent-test-case-parity-audit--read-datum (relative)
  "Read one Scheme datum from RELATIVE and return host Lisp data."
  (consent-test-fixture-host-datum
   (consent-read
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name relative consent--test-root))
      (buffer-string)))))

(defun consent-test-case-parity-audit--field (datum name)
  "Return field NAME from Scheme record DATUM."
  (cadr (assq name (cdr datum))))

(defun consent-test-case-parity-audit--ert-cases (relative)
  "Return statically declared ERT test names in RELATIVE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative consent--test-root))
    (let (names)
      (goto-char (point-min))
      (while (re-search-forward
              "^(ert-deftest[[:space:]]+\\([^()[:space:]]+\\)"
              nil t)
        (push (intern (match-string 1)) names))
      (nreverse names))))

(defun consent-test-case-parity-audit--program-paths ()
  "Return portable program paths declared by the Scheme test plan."
  (let* ((plan
          (consent-test-case-parity-audit--read-datum
           consent-test-case-parity-audit-plan-file))
         (programs
          (consent-test-case-parity-audit--field plan 'programs)))
    (mapcar
     (lambda (program)
       (consent-test-case-parity-audit--field program 'path))
     programs)))

(defun consent-test-case-parity-audit--ert-files ()
  "Return every repository ERT test file."
  (mapcar
   (lambda (path)
     (file-relative-name path consent--test-root))
   (directory-files-recursively
    (expand-file-name "tests" consent--test-root)
    "-test\\.el\\'")))

(defun consent-test-case-parity-audit--case-marker-p (relative case-name)
  "Return non-nil when RELATIVE contains CASE-NAME as a Scheme identifier."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative consent--test-root))
    (goto-char (point-min))
    (re-search-forward
     (concat "\\_<" (regexp-quote (symbol-name case-name)) "\\_>")
     nil t)))

(ert-deftest consent-test-case-parity-audit-covers-portable-surfaces ()
  "Require every ERT surface to declare its portable ownership or boundary."
  (let* ((map
          (consent-test-case-parity-audit--read-datum
           consent-test-case-parity-audit-map-file))
         (surfaces
          (consent-test-case-parity-audit--field map 'surfaces))
         (ert-files
          (mapcar
           (lambda (surface)
             (consent-test-case-parity-audit--field surface 'ert-file))
           surfaces))
         (program-paths (consent-test-case-parity-audit--program-paths)))
    (should
     (= (length ert-files) (length (delete-dups (copy-sequence ert-files)))))
    (should
     (equal (sort (copy-sequence ert-files) #'string-lessp)
            (sort (consent-test-case-parity-audit--ert-files) #'string-lessp)))
    (dolist (surface surfaces)
      (let ((ert-file
             (consent-test-case-parity-audit--field surface 'ert-file))
            (ownership
             (consent-test-case-parity-audit--field surface 'ownership))
            (portable-files
             (consent-test-case-parity-audit--field surface 'portable-files)))
        (should (symbolp ownership))
        (should (file-exists-p (expand-file-name ert-file consent--test-root)))
        (should (consent-test-case-parity-audit--ert-cases ert-file))
        (when (null portable-files)
          (should (assq 'boundary-reason (cdr surface))))
        (dolist (portable-file portable-files)
          (should
           (file-exists-p
            (expand-file-name portable-file consent--test-root)))
          (unless (string-suffix-p "consent-parity-emit.scm" portable-file)
            (should (member portable-file program-paths))))))))

(ert-deftest consent-test-case-parity-audit-partitions-exact-mixed-surfaces ()
  "Partition every ERT case on exact mixed surfaces without silent defaults."
  (let* ((map
          (consent-test-case-parity-audit--read-datum
           consent-test-case-parity-audit-map-file))
         (surfaces
          (consent-test-case-parity-audit--field map 'surfaces)))
    (dolist (surface surfaces)
      (when (eq (consent-test-case-parity-audit--field surface 'ownership)
                'mixed-exact)
        (let* ((ert-file
                (consent-test-case-parity-audit--field surface 'ert-file))
               (portable-cases
                (consent-test-case-parity-audit--field
                 surface 'portable-cases))
               (emacs-only-cases
                (consent-test-case-parity-audit--field
                 surface 'emacs-only-cases))
               (classified
                (append (mapcar #'car portable-cases)
                        (mapcar #'car emacs-only-cases))))
          (should
           (equal
            (sort
             (mapcar #'symbol-name
                     (consent-test-case-parity-audit--ert-cases ert-file))
             #'string-lessp)
            (sort (mapcar #'symbol-name classified) #'string-lessp)))
          (dolist (mapping portable-cases)
            (let ((portable-file (cadr mapping))
                  (portable-case (caddr mapping)))
              (should
               (consent-test-case-parity-audit--case-marker-p
                portable-file portable-case)))))))))

(provide 'consent-test-case-parity-audit-test)

;;; consent-test-case-parity-audit-test.el ends here
