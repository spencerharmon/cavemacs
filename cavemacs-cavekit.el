;;; cavemacs-cavekit.el --- Cavekit transient menu  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Lightweight wrapper around the three cavekit v4 commands.  Just sends
;; the slash command to the active cavemacs session.  Slash commands are
;; only defined when cavekit is installed in this project (skills under
;; ~/.claude/skills or ~/.cave/skills, or via the plugin marketplace).
;;
;;; Code:

(require 'transient)
(require 'cavemacs-shell)
(require 'cavemacs-commands)

(defun cavemacs-cavekit--send (slash)
  "Send a cavekit slash command SLASH and submit."
  (cavemacs-commands-run slash))

(defun cavemacs-cavekit-spec ()
  "Run `/ck:spec' in the active cavemacs session."
  (interactive)
  (cavemacs-cavekit--send "/ck:spec"))

(defun cavemacs-cavekit-build ()
  "Run `/ck:build' in the active cavemacs session."
  (interactive)
  (cavemacs-cavekit--send "/ck:build"))

(defun cavemacs-cavekit-check ()
  "Run `/ck:check' in the active cavemacs session."
  (interactive)
  (cavemacs-cavekit--send "/ck:check"))

(defun cavemacs-cavekit-open-spec ()
  "Visit SPEC.md at the project root."
  (interactive)
  (let* ((root (cavemacs-project-root))
         (path (expand-file-name "SPEC.md" root)))
    (find-file path)))

(transient-define-prefix cavemacs-cavekit ()
  "Cavekit (spec-driven workflow) commands."
  ["Workflow"
   ("s" "/ck:spec  — create/amend/backprop SPEC.md"  cavemacs-cavekit-spec)
   ("b" "/ck:build — execute next task against spec" cavemacs-cavekit-build)
   ("c" "/ck:check — drift report"                   cavemacs-cavekit-check)]
  ["Files"
   ("o" "Open SPEC.md"                               cavemacs-cavekit-open-spec)])

(provide 'cavemacs-cavekit)
;;; cavemacs-cavekit.el ends here
