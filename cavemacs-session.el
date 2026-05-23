;;; cavemacs-session.el --- Per-project session enumeration + browser  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Sessions are persisted by caveman itself.  Default location:
;;
;;   ~/.cave/agent/sessions/<cwd-encoded>/<session>.jsonl
;;
;; The exact CWD-encoding scheme is documented in caveman's docs; rather
;; than reverse-engineer it, we list every session directory and inspect
;; the first line of each .jsonl file for a `cwd' field, matching
;; against the requested project root.  This is O(N) but N is small
;; (one entry per persisted session) and only runs when the browser is
;; opened.
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)
(require 'cavemacs-project)
(require 'cavemacs-shell)

(defcustom cavemacs-session-dir
  (expand-file-name "~/.cave/agent/sessions/")
  "Root directory where caveman stores per-project session JSONL files."
  :type 'directory
  :group 'cavemacs)

(defun cavemacs-session--list-files ()
  "Return a list of absolute paths to all session JSONL files."
  (when (file-directory-p cavemacs-session-dir)
    (let (out)
      (dolist (d (directory-files cavemacs-session-dir t "\\`[^.]" t))
        (when (file-directory-p d)
          (dolist (f (directory-files d t "\\.jsonl\\'" t))
            (push f out))))
      out)))

(defun cavemacs-session--meta (path)
  "Return a metadata alist for the session at PATH.

Includes :path, :cwd, :sessionId, :name, :model, :provider,
:created (epoch ms), :mtime (file mtime), :turns (count of role=user lines)."
  (let ((meta (list :path path
                    :mtime (float-time
                            (file-attribute-modification-time
                             (file-attributes path)))))
        (turns 0))
    (with-temp-buffer
      (condition-case _
          (insert-file-contents path nil 0 65536)
        (error nil))
      (goto-char (point-min))
      (let ((first-parsed nil))
        (while (not (eobp))
          (let ((line-end (line-end-position)))
            (let ((line (buffer-substring-no-properties (point) line-end)))
              (when (> (length line) 0)
                (condition-case _
                    (let* ((json-object-type 'alist)
                           (json-array-type 'list)
                           (json-key-type 'symbol)
                           (json-false :json-false)
                           (json-null nil)
                           (obj (json-read-from-string line)))
                      (unless first-parsed
                        (setq first-parsed obj)
                        (when-let ((cwd (alist-get 'cwd obj)))
                          (setq meta (plist-put meta :cwd cwd)))
                        (when-let ((sid (alist-get 'sessionId obj)))
                          (setq meta (plist-put meta :sessionId sid)))
                        (when-let ((nm (alist-get 'sessionName obj)))
                          (setq meta (plist-put meta :name nm)))
                        (when-let ((mdl (alist-get 'model obj)))
                          (setq meta (plist-put meta :model
                                                (or (alist-get 'id mdl) mdl)))
                          (setq meta (plist-put meta :provider
                                                (alist-get 'provider mdl))))
                        (when-let ((c (alist-get 'createdAt obj)))
                          (setq meta (plist-put meta :created c))))
                      (when (or (equal (alist-get 'role obj) "user")
                                (equal (alist-get 'type obj) "user_message"))
                        (cl-incf turns)))
                  (error nil))))
            (forward-line 1)))))
    (plist-put meta :turns turns)
    meta))

(defun cavemacs-session-most-recent-path (root)
  "Return the most recently modified session file rooted under ROOT, or nil."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (candidates
          (cl-loop for path in (cavemacs-session--list-files)
                   for meta = (cavemacs-session--meta path)
                   when (or (null (plist-get meta :cwd))
                            (string= (file-name-as-directory
                                      (expand-file-name (plist-get meta :cwd)))
                                     root))
                   collect meta)))
    (when candidates
      (plist-get
       (car (sort candidates (lambda (a b)
                               (> (plist-get a :mtime)
                                  (plist-get b :mtime)))))
       :path))))

(defun cavemacs-session-have-saved-p (root)
  "Return non-nil if at least one persisted session exists for ROOT."
  (not (null (cavemacs-session-most-recent-path root))))

;; -----------------------------------------------------------------------------
;; Browser (tabulated-list)
;; -----------------------------------------------------------------------------

(defvar-local cavemacs-session-browser--root nil)
(defvar-local cavemacs-session-browser--show-all nil)

(define-derived-mode cavemacs-session-browser-mode tabulated-list-mode
  "cavemacs-sessions"
  "Browse caveman sessions."
  (setq tabulated-list-format
        [("Modified" 20 t)
         ("Project"  24 t)
         ("Model"    24 t)
         ("Turns"     6 t :right-align t)
         ("Session"   8 t)
         ("Name"      0 t)])
  (setq tabulated-list-sort-key '("Modified" . t))
  (tabulated-list-init-header))

(defvar cavemacs-session-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'cavemacs-session-browser-resume)
    (define-key map (kbd "n")   #'cavemacs-session-browser-new)
    (define-key map (kbd "d")   #'cavemacs-session-browser-delete)
    (define-key map (kbd "g")   #'cavemacs-session-browser-refresh)
    (define-key map (kbd "a")   #'cavemacs-session-browser-toggle-all)
    map))

(defun cavemacs-session-browser (&optional root)
  "Open the session browser scoped to ROOT (defaults to current project)."
  (interactive)
  (let* ((root (file-name-as-directory
                (expand-file-name (or root (cavemacs-project-root)))))
         (buf (get-buffer-create (format "*cavemacs sessions: %s*"
                                         (cavemacs-project-name root)))))
    (with-current-buffer buf
      (cavemacs-session-browser-mode)
      (setq cavemacs-session-browser--root root)
      (cavemacs-session-browser-refresh))
    (pop-to-buffer buf)))

(defun cavemacs-session-browser-refresh ()
  "Reload the session list."
  (interactive)
  (let* ((root cavemacs-session-browser--root)
         (root-as-dir (and root (file-name-as-directory
                                 (expand-file-name root))))
         (all (mapcar #'cavemacs-session--meta (cavemacs-session--list-files)))
         (rows (cl-loop
                for m in all
                when (or cavemacs-session-browser--show-all
                         (null (plist-get m :cwd))
                         (string= (file-name-as-directory
                                   (expand-file-name (plist-get m :cwd)))
                                  root-as-dir))
                collect
                (let* ((path (plist-get m :path))
                       (mtime (plist-get m :mtime))
                       (cwd (or (plist-get m :cwd) "?"))
                       (project (file-name-nondirectory
                                 (directory-file-name cwd)))
                       (model (or (plist-get m :model) "?"))
                       (provider (or (plist-get m :provider) ""))
                       (turns (plist-get m :turns))
                       (sid (or (plist-get m :sessionId) "?"))
                       (name (or (plist-get m :name) "")))
                  (list path
                        (vector (format-time-string "%Y-%m-%d %H:%M" mtime)
                                (truncate-string-to-width project 24 nil nil "…")
                                (truncate-string-to-width
                                 (if (string-empty-p provider)
                                     model
                                   (format "%s/%s" provider model))
                                 24 nil nil "…")
                                (number-to-string (or turns 0))
                                (substring sid 0 (min 8 (length sid)))
                                name))))))
    (setq tabulated-list-entries (nreverse rows))
    (tabulated-list-print t)))

(defun cavemacs-session-browser-toggle-all ()
  "Toggle showing sessions from all projects."
  (interactive)
  (setq cavemacs-session-browser--show-all
        (not cavemacs-session-browser--show-all))
  (cavemacs-session-browser-refresh)
  (message "cavemacs: %s sessions"
           (if cavemacs-session-browser--show-all "all" "project-scoped")))

(defun cavemacs-session-browser-resume ()
  "Resume the session at point in a new cavemacs buffer."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No session at point"))
    (cavemacs-shell-new
     :project-root cavemacs-session-browser--root
     :session-file path)))

(defun cavemacs-session-browser-new ()
  "Start a fresh session for the current project."
  (interactive)
  (cavemacs-shell-new :project-root cavemacs-session-browser--root))

(defun cavemacs-session-browser-delete ()
  "Delete the session file at point."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No session at point"))
    (when (yes-or-no-p (format "Delete %s? " (file-name-nondirectory path)))
      (delete-file path)
      (cavemacs-session-browser-refresh))))

(provide 'cavemacs-session)
;;; cavemacs-session.el ends here
