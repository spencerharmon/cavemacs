;;; cavemacs-commands.el --- Slash-command completion + transient  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Caveman's slash commands (`/something`) come from three sources, all
;; surfaced by the `get_commands' RPC:
;;
;;   extension -- commands registered by an extension
;;   prompt    -- markdown prompt templates in ~/.cave/commands/* and
;;                .cave/commands/*
;;   skill     -- skills under ~/.cave/skills/<name>/SKILL.md
;;
;; This module exposes:
;;
;;   `cavemacs-commands-pick'  -- pick a command and insert it into the input.
;;   `cavemacs-commands-run'   -- pick + immediately submit.
;;
;;; Code:

(require 'cl-lib)
(require 'cavemacs-rpc)
(require 'cavemacs-shell)

(defun cavemacs-commands--fetch (conn)
  "Synchronously fetch the slash-command list from CONN."
  (let ((resp (cavemacs-rpc-request-sync conn "get_commands" nil 10)))
    (and (eq (alist-get 'success resp) t)
         (alist-get 'commands (alist-get 'data resp)))))

(defun cavemacs-commands-pick ()
  "Pick a slash command and insert it (with the leading slash) into the input area."
  (interactive)
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer"))
  (let* ((commands (cavemacs-commands--fetch cavemacs-shell--conn))
         (table (mapcar
                 (lambda (c)
                   (let ((name (alist-get 'name c))
                         (desc (or (alist-get 'description c) ""))
                         (src  (alist-get 'source c)))
                     (cons (format "/%s — %s  [%s]" name desc src)
                           (format "/%s" name))))
                 commands))
         (choice (and table (completing-read "Command: " table nil t))))
    (when choice
      (let ((slash (cdr (assoc choice table))))
        (goto-char (point-max))
        (insert slash " ")))))

(defun cavemacs-commands-run (cmd)
  "Submit CMD (a slash-prefixed command) immediately."
  (interactive (list (read-string "/")))
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer"))
  (let ((line (if (string-prefix-p "/" cmd) cmd (concat "/" cmd))))
    (goto-char (point-max))
    (insert line)
    (cavemacs-shell-send)))

(provide 'cavemacs-commands)
;;; cavemacs-commands.el ends here
