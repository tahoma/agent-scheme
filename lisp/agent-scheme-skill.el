;;; agent-scheme-skill.el --- Agent Skills interop helpers  -*- lexical-binding: t; -*-
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
(require 'agent-scheme-reader)
(require 'agent-scheme-runtime)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)

(define-error 'agent-scheme-skill-error
  "Agent Scheme skill error"
  'agent-scheme-eval-error)

(defun agent-scheme-skill--option (options key default)
  "Return OPTIONS value for KEY, falling back to DEFAULT."
  (if (plist-member options key)
      (plist-get options key)
    default))

(defun agent-scheme-skill--symbol (name)
  "Return NAME as a Scheme symbol datum."
  (agent-scheme--syntax-symbol name))

(defun agent-scheme-skill--symbol-value (value)
  "Return VALUE as a Scheme symbol datum."
  (cond
   ((agent-scheme-symbol-p value)
    value)
   ((symbolp value)
    (agent-scheme-skill--symbol (symbol-name value)))
   ((stringp value)
    (agent-scheme-skill--symbol value))
   (t
    (agent-scheme-skill--symbol (format "%S" value)))))

(defun agent-scheme-skill--symbol-named-p (value name)
  "Return non-nil when VALUE is a Scheme symbol named NAME."
  (and (agent-scheme-symbol-p value)
       (equal (agent-scheme-symbol-name value) name)))

(defun agent-scheme-skill--ensure-directory (directory)
  "Return DIRECTORY as an expanded directory path, or signal."
  (let ((path (file-name-as-directory (expand-file-name directory))))
    (unless (file-directory-p path)
      (signal 'agent-scheme-skill-error
              (list (format "skill directory does not exist: %s" directory))))
    path))

(defun agent-scheme-skill--basename (directory)
  "Return a stable skill name candidate from DIRECTORY."
  (file-name-nondirectory
   (directory-file-name
    (agent-scheme-skill--ensure-directory directory))))

(defun agent-scheme-skill--resolve-bundled-path
    (directory relative-path description)
  "Resolve RELATIVE-PATH under DIRECTORY as DESCRIPTION."
  (unless (stringp relative-path)
    (signal 'agent-scheme-skill-error
            (list (format "%s path must be a string" description))))
  (when (file-name-absolute-p relative-path)
    (signal 'agent-scheme-skill-error
            (list (format "%s path must be relative: %s"
                          description relative-path))))
  (let* ((root (agent-scheme-skill--ensure-directory directory))
         (root-true (file-name-as-directory (file-truename root)))
         (path (expand-file-name relative-path root))
         (checked-path (if (file-exists-p path)
                           (file-truename path)
                         path)))
    (unless (file-in-directory-p checked-path root-true)
      (signal 'agent-scheme-skill-error
              (list (format "%s path escapes skill directory: %s"
                            description relative-path))))
    checked-path))

(defun agent-scheme-skill--read-file (path)
  "Read and return PATH contents as a string."
  (unless (file-readable-p path)
    (signal 'agent-scheme-skill-error
            (list (format "skill resource is not readable: %s" path))))
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun agent-scheme-skill--frontmatter-value (text key)
  "Return KEY from TEXT's leading Markdown front matter, if present."
  (when (string-match "\\`---[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n---[ \t]*\n" text)
    (let ((frontmatter (match-string 1 text))
          (pattern (format "^%s:[ \t]*\\(.+\\)$" (regexp-quote key))))
      (when (string-match pattern frontmatter)
        (let ((value (string-trim (match-string 1 frontmatter))))
          (if (string-match "\\`[\"']\\(.*\\)[\"']\\'" value)
              (match-string 1 value)
            value))))))

(defun agent-scheme-skill--field-value (datum name)
  "Return field NAME from normalized skill DATUM."
  (cl-loop for field in (cdr-safe datum)
           when (and (consp field)
                     (agent-scheme-skill--symbol-named-p (car field) name))
           return (cadr field)))

(defun agent-scheme-skill--string-field (datum name)
  "Return string field NAME from DATUM, or nil."
  (let ((value (agent-scheme-skill--field-value datum name)))
    (when (stringp value)
      value)))

(defun agent-scheme-skill--normalized-datum
    (name directory trust instructions-text description)
  "Return a normalized Scheme-readable Agent Skill datum."
  (let ((requested-grants
         (agent-scheme-skill--frontmatter-value
          instructions-text "requested-grants")))
    (append
     (list (agent-scheme-skill--symbol "agent-skill")
           (list (agent-scheme-skill--symbol "name") name)
           (list (agent-scheme-skill--symbol "source")
                 (list (agent-scheme-skill--symbol "directory") directory))
           (list (agent-scheme-skill--symbol "trust")
                 (agent-scheme-skill--symbol-value trust))
           (list (agent-scheme-skill--symbol "instructions")
                 (list (agent-scheme-skill--symbol "markdown-resource")
                       "SKILL.md")))
     (when description
       (list (list (agent-scheme-skill--symbol "description")
                   description)))
     (when requested-grants
       (list
        (list (agent-scheme-skill--symbol "requested-grants")
              (agent-scheme-read requested-grants))))
     (list (list (agent-scheme-skill--symbol "instructions-text")
                 instructions-text)))))

(defun agent-scheme-skill--import-data (directory options)
  "Import DIRECTORY and return internal skill data using OPTIONS."
  (let* ((source-directory
          (directory-file-name (agent-scheme-skill--ensure-directory directory)))
         (fallback-name
          (or (agent-scheme-skill--option options :name nil)
              (agent-scheme-skill--basename source-directory)))
         (context (agent-scheme-skill--option options :context nil))
         (instructions-text
          (agent-scheme-skill-read-resource
           source-directory "SKILL.md" (list :skill-name fallback-name
                                             :context context)))
         (name (or (agent-scheme-skill--option options :name nil)
                   (agent-scheme-skill--frontmatter-value
                    instructions-text "name")
                   fallback-name))
         (description
          (agent-scheme-skill--frontmatter-value
           instructions-text "description"))
         (trust (agent-scheme-skill--option options :trust 'untrusted))
         (datum
          (agent-scheme-skill--normalized-datum
           name source-directory trust instructions-text description)))
    (list :name name
          :source-directory source-directory
          :datum datum)))

;;;###autoload
(defun agent-scheme-skill-read-resource
    (directory resource-path &optional options)
  "Read RESOURCE-PATH from skill DIRECTORY after policy approval.
OPTIONS may include `:skill-name' and `:context'."
  (let* ((skill-name (or (agent-scheme-skill--option options :skill-name nil)
                         (agent-scheme-skill--basename directory)))
         (context (agent-scheme-skill--option options :context nil))
         (path (agent-scheme-skill--resolve-bundled-path
                directory resource-path "skill resource")))
    (unless (file-regular-p path)
      (signal 'agent-scheme-skill-error
              (list (format "skill resource is not a regular file: %s"
                            resource-path))))
    (agent-scheme-policy-authorize-skill-resource-read
     skill-name path context)
    (agent-scheme-redact
     (agent-scheme-skill--read-file path)
     'skill-resource)))

;;;###autoload
(defun agent-scheme-skill-import (directory &optional options)
  "Import Agent Skill DIRECTORY and return a normalized datum.
OPTIONS may include `:name', `:trust', and `:context'."
  (plist-get (agent-scheme-skill--import-data directory options) :datum))

;;;###autoload
(defun agent-scheme-skill-activate (directory &optional options)
  "Import and activate Agent Skill DIRECTORY after policy approval.
OPTIONS may include `:name', `:trust', `:trust-scope', and `:context'."
  (let* ((data (agent-scheme-skill--import-data directory options))
         (name (plist-get data :name))
         (source-directory (plist-get data :source-directory))
         (trust-scope (agent-scheme-skill--option
                       options :trust-scope 'project))
         (context (agent-scheme-skill--option options :context nil)))
    (agent-scheme-policy-authorize-skill-activation
     name source-directory trust-scope context)
    (plist-get data :datum)))

;;;###autoload
(defun agent-scheme-skill-trust-project
    (project project-directory &optional context)
  "Authorize PROJECT skills rooted at PROJECT-DIRECTORY."
  (let ((directory (directory-file-name
                    (agent-scheme-skill--ensure-directory
                     project-directory))))
    (agent-scheme-policy-authorize-project-skill-trust
     project directory context)
    (list (agent-scheme-skill--symbol "project-skill-trust")
          (list (agent-scheme-skill--symbol "project") project)
          (list (agent-scheme-skill--symbol "project-directory")
                directory)
          (list (agent-scheme-skill--symbol "decision")
                (agent-scheme-skill--symbol "authorized")))))

;;;###autoload
(defun agent-scheme-skill-script-execution-request
    (directory script-path &optional options)
  "Authorize bundled SCRIPT-PATH from skill DIRECTORY and return a request datum.
OPTIONS may include `:skill-name' and `:context'.  This helper does
not execute the script; it records the policy decision and returns
the concrete host path for the caller that owns process execution."
  (let* ((skill-name (or (agent-scheme-skill--option options :skill-name nil)
                         (agent-scheme-skill--basename directory)))
         (context (agent-scheme-skill--option options :context nil))
         (path (agent-scheme-skill--resolve-bundled-path
                directory script-path "skill script")))
    (unless (file-regular-p path)
      (signal 'agent-scheme-skill-error
              (list (format "skill script is not a regular file: %s"
                            script-path))))
    (agent-scheme-policy-authorize-skill-script-execution
     skill-name path context)
    (list (agent-scheme-skill--symbol "skill-script-execution")
          (list (agent-scheme-skill--symbol "skill-name") skill-name)
          (list (agent-scheme-skill--symbol "script-path") path)
          (list (agent-scheme-skill--symbol "decision")
                (agent-scheme-skill--symbol "authorized")))))

;;;###autoload
(defun agent-scheme-skill-export
    (skill-datum export-directory &optional options)
  "Export SKILL-DATUM to EXPORT-DIRECTORY after policy approval.
OPTIONS may include `:name', `:instructions-text', and `:context'."
  (unless (and (consp skill-datum)
               (agent-scheme-skill--symbol-named-p
                (car skill-datum) "agent-skill"))
    (signal 'agent-scheme-skill-error
            (list "skill export expects a normalized agent-skill datum")))
  (let* ((name (or (agent-scheme-skill--option options :name nil)
                   (agent-scheme-skill--string-field skill-datum "name")))
         (instructions-text
          (or (agent-scheme-skill--option options :instructions-text nil)
              (agent-scheme-skill--string-field
               skill-datum "instructions-text")
              ""))
         (redacted-instructions-text
          (agent-scheme-redact instructions-text 'skill-export))
         (context (agent-scheme-skill--option options :context nil))
         (target-directory
          (file-name-as-directory (expand-file-name export-directory)))
         (target-file (expand-file-name "SKILL.md" target-directory)))
    (unless name
      (signal 'agent-scheme-skill-error
              (list "skill export requires a skill name")))
    (agent-scheme-policy-authorize-skill-export-write
     name target-file context)
    (make-directory target-directory t)
    (when (file-directory-p target-file)
      (signal 'agent-scheme-skill-error
              (list (format "skill export target is a directory: %s"
                            target-file))))
    (with-temp-file target-file
      (insert redacted-instructions-text))
    (list (agent-scheme-skill--symbol "skill-export")
          (list (agent-scheme-skill--symbol "skill-name") name)
          (list (agent-scheme-skill--symbol "export-path") target-file)
          (list (agent-scheme-skill--symbol "decision")
                (agent-scheme-skill--symbol "written")))))

(provide 'agent-scheme-skill)

;;; agent-scheme-skill.el ends here
