;;; cavemacs-cavekit.el --- Cavekit transient menu  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Lightweight wrapper around the three cavekit v4 commands.  Just sends
;; the slash command to the active cavemacs session.  Slash commands are
;; only defined when cavekit is installed in this project (skills under
;; ~/.claude/skills or ~/.cave/skills, or via the plugin marketplace).
;;
;;; Code:

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

(defconst cavemacs-cavekit--menu
  '(("/ck:spec   create/amend/backprop SPEC.md"  . cavemacs-cavekit-spec)
    ("/ck:build  execute next task against spec" . cavemacs-cavekit-build)
    ("/ck:check  drift report"                   . cavemacs-cavekit-check)
    ("Open SPEC.md"                              . cavemacs-cavekit-open-spec))
  "Menu entries for `cavemacs-cavekit'.")

;;;###autoload
(defun cavemacs-cavekit ()
  "Pick a cavekit action.

Uses `completing-read' rather than `transient' to avoid the
load-order pitfall on Emacs 30, where the built-in transient 0.7
gets loaded before straight.el's newer version, causing
`transient-define-prefix' to expand into a `transient--set-layout'
call that 0.7 does not provide."
  (interactive)
  (let* ((choice (completing-read "cavekit: "
                                  (mapcar #'car cavemacs-cavekit--menu)
                                  nil t))
         (fn (cdr (assoc choice cavemacs-cavekit--menu))))
    (when fn (call-interactively fn))))

(provide 'cavemacs-cavekit)
;;; cavemacs-cavekit.el ends here
