;;; cavemacs.el --- Emacs front-end for the caveman-code agent  -*- lexical-binding: t; -*-

;; Author: Spencer Harmon <spencer@spencerharmon.com>
;; URL: https://github.com/spencerharmon/cavemacs
;; Version: 0.0.51
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

(defconst cavemacs-version "0.0.51"
  "Cavemacs version. Bumped manually when tagging a release.")

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
(defun cavemacs ()
  "Start a fresh cavemacs session for the current project.

Project is detected via `project-current' / git. To resume or pick
an existing session for this project, use `cavemacs-session'."
  (interactive)
  (cavemacs-shell-new :project-root (cavemacs-project-root)))

;;;###autoload
(defalias 'cavemacs-new 'cavemacs
  "Compatibility alias; `cavemacs' now always starts a fresh session.")

;;;###autoload
(defun cavemacs-session (&optional arg)
  "Open the session picker for the current project (resume / fork / delete).

If exactly one live session buffer exists for the project, pop to it.
With prefix ARG, always open the picker even when only one is live."
  (interactive "P")
  (let* ((root (cavemacs-project-root))
         (live (cavemacs-shell-live-buffers-for-project root)))
    (cond
     ((and (not arg) (= (length live) 1))
      (pop-to-buffer (car live)))
     (t
      (cavemacs-session-browser root)))))

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
