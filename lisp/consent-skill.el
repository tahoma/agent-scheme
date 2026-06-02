;;; consent-skill.el --- Agent Skills interop helpers  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Concrete host helpers for importing, activating, trusting, reading, and
;; exporting Agent Skills.  These helpers keep Agent Skills as Scheme-readable
;; datums while routing effectful host filesystem operations through shared
;; policy gates.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-policy)
(require 'consent-redaction)

(define-error 'consent-skill-error
  "Consent Scheme skill error"
  'consent-eval-error)

(defun consent-skill--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun consent-skill--symbol (name)
  "Return NAME as a Scheme symbol datum."
  (consent--syntax-symbol name))

(defun consent-skill--symbol-value (value)
  "Return VALUE as a Scheme symbol datum."
  (cond
   ((consent-symbol-p value)
    value)
   ((symbolp value)
    (consent-skill--symbol (symbol-name value)))
   ((stringp value)
    (consent-skill--symbol value))
   (t
    (consent-skill--symbol (format "%S" value)))))

(defun consent-skill--symbol-named-p (value name)
  "Return non-nil when VALUE is a Scheme symbol named NAME."
  (and (consent-symbol-p value)
       (equal (consent-symbol-name value) name)))

(defun consent-skill--ensure-directory (directory)
  "Return DIRECTORY as an expanded directory path, or signal."
  (let ((path (file-name-as-directory (expand-file-name directory))))
    (unless (file-directory-p path)
      (signal 'consent-skill-error
              (list (format "skill directory does not exist: %s" directory))))
    path))

(defun consent-skill--basename (directory)
  "Return a stable skill name candidate from DIRECTORY."
  (file-name-nondirectory
   (directory-file-name
    (consent-skill--ensure-directory directory))))

(defun consent-skill--resolve-bundled-path
    (directory relative-path description)
  "Resolve RELATIVE-PATH under DIRECTORY as DESCRIPTION."
  (unless (stringp relative-path)
    (signal 'consent-skill-error
            (list (format "%s path must be a string" description))))
  (when (file-name-absolute-p relative-path)
    (signal 'consent-skill-error
            (list (format "%s path must be relative: %s"
                          description relative-path))))
  (let* ((root (consent-skill--ensure-directory directory))
         (root-true (file-name-as-directory (file-truename root)))
         (path (expand-file-name relative-path root))
         (checked-path (if (file-exists-p path)
                           (file-truename path)
                         path)))
    (unless (file-in-directory-p checked-path root-true)
      (signal 'consent-skill-error
              (list (format "%s path escapes skill directory: %s"
                            description relative-path))))
    checked-path))

(defun consent-skill--read-file (path)
  "Read and return PATH contents as a string."
  (unless (file-readable-p path)
    (signal 'consent-skill-error
            (list (format "skill resource is not readable: %s" path))))
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun consent-skill--frontmatter-value (text key)
  "Return KEY from TEXT's leading Markdown front matter, if present."
  (when (string-match "\\`---[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n---[ \t]*\n" text)
    (let ((frontmatter (match-string 1 text))
          (pattern (format "^%s:[ \t]*\\(.+\\)$" (regexp-quote key))))
      (when (string-match pattern frontmatter)
        (let ((value (string-trim (match-string 1 frontmatter))))
          (if (string-match "\\`[\"']\\(.*\\)[\"']\\'" value)
              (match-string 1 value)
            value))))))

(defun consent-skill--field-value (datum name)
  "Return field NAME from normalized skill DATUM."
  (cl-loop for field in (cdr-safe datum)
           when (and (consp field)
                     (consent-skill--symbol-named-p (car field) name))
           return (cadr field)))

(defun consent-skill--string-field (datum name)
  "Return string field NAME from DATUM, or nil."
  (let ((value (consent-skill--field-value datum name)))
    (when (stringp value)
      value)))

(defun consent-skill--normalized-datum
    (name directory trust instructions-text description)
  "Return a normalized Scheme-readable Agent Skill datum."
  (let ((requested-grants
         (consent-skill--frontmatter-value
          instructions-text "requested-grants")))
    (append
     (list (consent-skill--symbol "agent-skill")
           (list (consent-skill--symbol "name") name)
           (list (consent-skill--symbol "source")
                 (list (consent-skill--symbol "directory") directory))
           (list (consent-skill--symbol "trust")
                 (consent-skill--symbol-value trust))
           (list (consent-skill--symbol "instructions")
                 (list (consent-skill--symbol "markdown-resource")
                       "SKILL.md")))
     (when description
       (list (list (consent-skill--symbol "description")
                   description)))
     (when requested-grants
       (list
        (list (consent-skill--symbol "requested-grants")
              (consent-read requested-grants))))
     (list (list (consent-skill--symbol "instructions-text")
                 instructions-text)))))

(defun consent-skill--import-data (directory options)
  "Import DIRECTORY and return internal skill data using OPTIONS."
  (let* ((source-directory
          (directory-file-name (consent-skill--ensure-directory directory)))
         (fallback-name
          (or (consent-skill--option options :name nil)
              (consent-skill--basename source-directory)))
         (context (consent-skill--option options :context nil))
         (instructions-text
          (consent-skill-read-resource
           source-directory "SKILL.md" (list :skill-name fallback-name
                                             :context context)))
         (name (or (consent-skill--option options :name nil)
                   (consent-skill--frontmatter-value
                    instructions-text "name")
                   fallback-name))
         (description
          (consent-skill--frontmatter-value
           instructions-text "description"))
         (trust (consent-skill--option options :trust 'untrusted))
         (datum
          (consent-skill--normalized-datum
           name source-directory trust instructions-text description)))
    (list :name name
          :source-directory source-directory
          :datum datum)))

;;;###autoload
(defun consent-skill-read-resource
    (directory resource-path &optional options)
  "Read RESOURCE-PATH from skill DIRECTORY after policy approval.
OPTIONS may include `:skill-name' and `:context'."
  (let* ((skill-name (or (consent-skill--option options :skill-name nil)
                         (consent-skill--basename directory)))
         (context (consent-skill--option options :context nil))
         (path (consent-skill--resolve-bundled-path
                directory resource-path "skill resource")))
    (unless (file-regular-p path)
      (signal 'consent-skill-error
              (list (format "skill resource is not a regular file: %s"
                            resource-path))))
    (consent-policy-authorize-skill-resource-read
     skill-name path context)
    (consent-redact
     (consent-skill--read-file path)
     'skill-resource)))

;;;###autoload
(defun consent-skill-import (directory &optional options)
  "Import Agent Skill DIRECTORY and return a normalized datum.
OPTIONS may include `:name', `:trust', and `:context'."
  (plist-get (consent-skill--import-data directory options) :datum))

;;;###autoload
(defun consent-skill-activate (directory &optional options)
  "Import and activate Agent Skill DIRECTORY after policy approval.
OPTIONS may include `:name', `:trust', `:trust-scope', and `:context'."
  (let* ((data (consent-skill--import-data directory options))
         (name (plist-get data :name))
         (source-directory (plist-get data :source-directory))
         (trust-scope (consent-skill--option
                       options :trust-scope 'project))
         (context (consent-skill--option options :context nil)))
    (consent-policy-authorize-skill-activation
     name source-directory trust-scope context)
    (plist-get data :datum)))

;;;###autoload
(defun consent-skill-trust-project
    (project project-directory &optional context)
  "Authorize PROJECT skills rooted at PROJECT-DIRECTORY."
  (let ((directory (directory-file-name
                    (consent-skill--ensure-directory
                     project-directory))))
    (consent-policy-authorize-project-skill-trust
     project directory context)
    (list (consent-skill--symbol "project-skill-trust")
          (list (consent-skill--symbol "project") project)
          (list (consent-skill--symbol "project-directory")
                directory)
          (list (consent-skill--symbol "decision")
                (consent-skill--symbol "authorized")))))

;;;###autoload
(defun consent-skill-script-execution-request
    (directory script-path &optional options)
  "Authorize bundled SCRIPT-PATH from skill DIRECTORY and return a request datum.
OPTIONS may include `:skill-name' and `:context'.  This helper does
not execute the script; it records the policy decision and returns
the concrete host path for the caller that owns process execution."
  (let* ((skill-name (or (consent-skill--option options :skill-name nil)
                         (consent-skill--basename directory)))
         (context (consent-skill--option options :context nil))
         (path (consent-skill--resolve-bundled-path
                directory script-path "skill script")))
    (unless (file-regular-p path)
      (signal 'consent-skill-error
              (list (format "skill script is not a regular file: %s"
                            script-path))))
    (consent-policy-authorize-skill-script-execution
     skill-name path context)
    (list (consent-skill--symbol "skill-script-execution")
          (list (consent-skill--symbol "skill-name") skill-name)
          (list (consent-skill--symbol "script-path") path)
          (list (consent-skill--symbol "decision")
                (consent-skill--symbol "authorized")))))

;;;###autoload
(defun consent-skill-export
    (skill-datum export-directory &optional options)
  "Export SKILL-DATUM to EXPORT-DIRECTORY after policy approval.
OPTIONS may include `:name', `:instructions-text', and `:context'."
  (unless (and (consp skill-datum)
               (consent-skill--symbol-named-p
                (car skill-datum) "agent-skill"))
    (signal 'consent-skill-error
            (list "skill export expects a normalized agent-skill datum")))
  (let* ((name (or (consent-skill--option options :name nil)
                   (consent-skill--string-field skill-datum "name")))
         (instructions-text
          (or (consent-skill--option options :instructions-text nil)
              (consent-skill--string-field
               skill-datum "instructions-text")
              ""))
         (redacted-instructions-text
          (consent-redact instructions-text 'skill-export))
         (context (consent-skill--option options :context nil))
         (target-directory
          (file-name-as-directory (expand-file-name export-directory)))
         (target-file (expand-file-name "SKILL.md" target-directory)))
    (unless name
      (signal 'consent-skill-error
              (list "skill export requires a skill name")))
    (consent-policy-authorize-skill-export-write
     name target-file context)
    (make-directory target-directory t)
    (when (file-directory-p target-file)
      (signal 'consent-skill-error
              (list (format "skill export target is a directory: %s"
                            target-file))))
    (with-temp-file target-file
      (insert redacted-instructions-text))
    (list (consent-skill--symbol "skill-export")
          (list (consent-skill--symbol "skill-name") name)
          (list (consent-skill--symbol "export-path") target-file)
          (list (consent-skill--symbol "decision")
                (consent-skill--symbol "written")))))

(provide 'consent-skill)

;;; consent-skill.el ends here
