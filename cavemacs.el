;;; cavemacs.el --- Emacs front-end for the caveman-code agent  -*- lexical-binding: t; -*-

;; Author: Spencer Harmon <spencer@spencerharmon.com>
;; URL: https://github.com/spencerharmon/cavemacs
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (markdown-mode "2.5") (transient "0.7"))
;; Keywords: tools, convenience, ai
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; cavemacs is an Emacs front-end for the caveman-code terminal coding
;; agent (https://github.com/JuliusBrussee/caveman-code).
;;
;; It wraps the `caveman --mode rpc' JSONL protocol, presenting a
;; streaming chat buffer with tool-call approvals, markdown rendering,
;; per-project session persistence, and integration with the rest of
;; the Caveman ecosystem (cavekit, cavemem).
;;
;; Quick start:
;;
;;   (require 'cavemacs)
;;   M-x cavemacs
;;
;; Customize:
;;
;;   M-x customize-group RET cavemacs RET

;;; Code:

(defconst cavemacs--version-file
  (expand-file-name ".cavemacs-version"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "File storing the auto-incrementing reload version.")

(defun cavemacs--bump-version ()
  "Read MAJOR.MINOR.PATCH from `cavemacs--version-file', bump PATCH, write back.
Return the new version string."
  (let* ((raw (when (file-readable-p cavemacs--version-file)
                (with-temp-buffer
                  (insert-file-contents cavemacs--version-file)
                  (string-trim (buffer-string)))))
         (parts (mapcar #'string-to-number
                        (split-string (or raw "0.1.0") "\\." t)))
         (major (or (nth 0 parts) 0))
         (minor (or (nth 1 parts) 1))
         (patch (1+ (or (nth 2 parts) 0)))
         (new (format "%d.%d.%d" major minor patch)))
    (with-temp-file cavemacs--version-file
      (insert new "\n"))
    new))

(defconst cavemacs-version (cavemacs--bump-version)
  "Cavemacs version. PATCH auto-increments on every load/reload.")

(require 'cavemacs-config)
(require 'cavemacs-rpc)
(require 'cavemacs-project)
(require 'cavemacs-pretty)
(require 'cavemacs-render)
(require 'cavemacs-shell)
(require 'cavemacs-tools)
(require 'cavemacs-session)
(require 'cavemacs-commands)
(require 'cavemacs-cavekit)
(require 'cavemacs-cavemem)
(require 'cavemacs-caveman)
(require 'cavemacs-flags)

(defgroup cavemacs nil
  "Emacs front-end for the caveman-code agent."
  :group 'tools
  :prefix "cavemacs-")

;; All shared customs (cavemacs-binary, cavemacs-extra-args, etc.) live
;; in cavemacs-config.el so cavemacs-shell.el can use them without a
;; require cycle.

;;;###autoload
(defun cavemacs (&optional arg)
  "Open or resume a cavemacs session for the current project.

With prefix ARG, always create a fresh ephemeral session in the
current project; never resume an existing one."
  (interactive "P")
  (let* ((root (cavemacs-project-root))
         (live (cavemacs-shell-live-buffers-for-project root)))
    (cond
     ((and (not arg) (= (length live) 1))
      (pop-to-buffer (car live)))
     ((and (not arg) (> (length live) 1))
      (cavemacs-session-browser root))
     ((and (not arg) (cavemacs-session-have-saved-p root))
      (cavemacs-session-browser root))
     (t
      (cavemacs-shell-new :project-root root)))))

;;;###autoload
(defun cavemacs-new ()
  "Unconditionally start a fresh session buffer for the current project."
  (interactive)
  (cavemacs-shell-new :project-root (cavemacs-project-root)))

;;;###autoload
(defun cavemacs-continue ()
  "Continue the most recent session for the current project.
Equivalent to `caveman -c' semantics."
  (interactive)
  (let* ((root (cavemacs-project-root))
         (path (cavemacs-session-most-recent-path root)))
    (unless path
      (user-error "No prior session found for %s" root))
    (cavemacs-shell-new :project-root root :session-file path)))

(provide 'cavemacs)
;;; cavemacs.el ends here
