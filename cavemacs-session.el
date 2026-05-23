;;; cavemacs-session.el --- Per-project session enumeration + browser  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Sessions are persisted by caveman itself.  Default location:
;;
;;   ~/.cave/agent/sessions/<cwd-encoded>/<session>.jsonl
;;
;; Each .jsonl is an append-only event log; the first line is always
;; a `{"type":"session", "cwd":..., "id":..., "timestamp":...}'
;; envelope.  Subsequent lines are events:
;;
;;   - "message"               a turn (role=user|assistant); assistant
;;                              messages carry model/provider/usage.
;;   - "model_change"          a /model switch.
;;   - "thinking_level_change" a /thinking switch.
;;   - "session_name_change"   user named the session via /name.
;;
;; We compute browser metadata by scanning the file (capped at 64 KB
;; for responsiveness) and merging the latest signal of each kind:
;; latest model from the most recent model_change or assistant message,
;; turn count from message lines with role=user, name from the most
;; recent session_name_change.  When no name has been set, we derive
;; one from the first user message's content as a fallback.
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

(defcustom cavemacs-session-scan-bytes 65536
  "Number of bytes scanned from each session JSONL when building metadata.
Sessions larger than this still resume correctly; only the browser
preview (name, model, turn count) may be slightly stale."
  :type 'integer
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

(defun cavemacs-session--first-user-text (obj)
  "Extract a short single-line excerpt from an obj's user-message content."
  (let* ((msg (alist-get 'message obj))
         (content (and msg (alist-get 'content msg))))
    (cond
     ((stringp content)
      (substring-no-properties content))
     ((listp content)
      (mapconcat (lambda (part)
                   (cond ((stringp part) part)
                         ((alist-get 'text part) (alist-get 'text part))
                         (t "")))
                 content " "))
     (t ""))))

(defun cavemacs-session--meta (path)
  "Return a metadata alist for the session at PATH.

Plist keys:
  :path :cwd :sessionId :name :model :provider
  :created :mtime :turns"
  (let ((meta (list :path path
                    :mtime (float-time
                            (file-attribute-modification-time
                             (file-attributes path)))))
        (turns 0)
        (first-user-text nil))
    (with-temp-buffer
      (condition-case _
          (insert-file-contents path nil 0 cavemacs-session-scan-bytes)
        (error nil))
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((line-end (line-end-position))
               (line (buffer-substring-no-properties (point) line-end)))
          (when (> (length line) 0)
            (condition-case _
                (let* ((json-object-type 'alist)
                       (json-array-type 'list)
                       (json-key-type 'symbol)
                       (json-false :json-false)
                       (json-null nil)
                       (obj (json-read-from-string line))
                       (type (alist-get 'type obj)))
                  (pcase type
                    ("session"
                     ;; First-line envelope: cwd, id, timestamp.
                     (when-let ((cwd (alist-get 'cwd obj)))
                       (setq meta (plist-put meta :cwd cwd)))
                     (when-let ((sid (alist-get 'id obj)))
                       (setq meta (plist-put meta :sessionId sid)))
                     (when-let ((ts (alist-get 'timestamp obj)))
                       (setq meta (plist-put meta :created ts))))
                    ("model_change"
                     (when-let ((mid (alist-get 'modelId obj)))
                       (setq meta (plist-put meta :model mid)))
                     (when-let ((prov (alist-get 'provider obj)))
                       (setq meta (plist-put meta :provider prov))))
                    ("session_name_change"
                     (when-let ((nm (alist-get 'name obj)))
                       (setq meta (plist-put meta :name nm))))
                    ("message"
                     (let* ((msg (alist-get 'message obj))
                            (role (and msg (alist-get 'role msg))))
                       (when (equal role "user")
                         (cl-incf turns)
                         (unless first-user-text
                           (setq first-user-text
                                 (cavemacs-session--first-user-text obj))))
                       ;; Assistant messages also carry the model in
                       ;; effect at the time the reply was generated.
                       (when (equal role "assistant")
                         (when-let ((mid (alist-get 'model msg)))
                           (setq meta (plist-put meta :model mid)))
                         (when-let ((prov (alist-get 'provider msg)))
                           (setq meta (plist-put meta :provider prov))))))
                    (_ nil)))
              (error nil)))
          (forward-line 1))))
    (plist-put meta :turns turns)
    ;; Synthesize a fallback name from the first user message text.
    (unless (plist-get meta :name)
      (when (and first-user-text (not (string-empty-p first-user-text)))
        (plist-put
         meta :name
         (string-trim
          (truncate-string-to-width
           (replace-regexp-in-string "[\n\r\t ]+" " " first-user-text)
           60 nil nil "…")))))
    meta))

(defun cavemacs-session--cwd-match-p (meta root-as-dir)
  "Return non-nil if META's cwd is ROOT-AS-DIR."
  (when-let* ((cwd (plist-get meta :cwd)))
    (string= (file-name-as-directory (expand-file-name cwd))
             root-as-dir)))

(defun cavemacs-session-most-recent-path (root)
  "Return the most recently modified session file rooted under ROOT, or nil."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (candidates
          (cl-loop for path in (cavemacs-session--list-files)
                   for meta = (cavemacs-session--meta path)
                   when (cavemacs-session--cwd-match-p meta root)
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
;; Session browser (tabulated-list, project-scoped)
;; -----------------------------------------------------------------------------

(defvar-local cavemacs-session-browser--root nil)
(defvar-local cavemacs-session-browser--show-all nil)

(define-derived-mode cavemacs-session-browser-mode tabulated-list-mode
  "cavemacs-sessions"
  "Browse caveman sessions.

Default scope is the buffer's project root (set when the browser
is opened).  Press `a' to toggle between the project-scoped view
and showing every persisted session on this machine; when that
toggle is on, a Project column is added so cross-project rows can
be told apart."
  ;; Column layout is recomputed on every refresh because we hide
  ;; the Project column in project-scoped mode (a session browser
  ;; already pinned to one project does not need to repeat it).
  (tabulated-list-init-header))

;; `define-derived-mode' creates an empty `cavemacs-session-browser-mode-map'
;; as part of its expansion.  Bind keys against THAT map; a separate
;; `defvar' to a fresh let-bound map would be ignored.
(define-key cavemacs-session-browser-mode-map (kbd "RET") #'cavemacs-session-browser-resume)
(define-key cavemacs-session-browser-mode-map (kbd "o")   #'cavemacs-session-browser-resume)
(define-key cavemacs-session-browser-mode-map (kbd "n")   #'cavemacs-session-browser-new)
(define-key cavemacs-session-browser-mode-map (kbd "d")   #'cavemacs-session-browser-delete)
(define-key cavemacs-session-browser-mode-map (kbd "g")   #'cavemacs-session-browser-refresh)
(define-key cavemacs-session-browser-mode-map (kbd "a")   #'cavemacs-session-browser-toggle-all)
(define-key cavemacs-session-browser-mode-map (kbd "q")   #'quit-window)

(defun cavemacs-session-browser--columns ()
  "Return the tabulated-list-format vector for the current scope.

When `cavemacs-session-browser--show-all' is on, prepend a
Project column so the rows are disambiguatable.  Otherwise drop
it -- the browser is already pinned to a single project and
repeating it on every row is noise."
  (let ((name-col '("Name"     0 t)))
    (if cavemacs-session-browser--show-all
        (vector '("Modified" 17 t)
                '("Project"  24 t)
                '("Model"    34 t)
                '("Turns"     5 t :right-align t)
                '("Session"   8 t)
                name-col)
      (vector '("Modified" 17 t)
              '("Model"    34 t)
              '("Turns"     5 t :right-align t)
              '("Session"   8 t)
              name-col))))

(defun cavemacs-session-browser--row (m)
  "Build a (PATH . VECTOR) row from session metadata plist M."
  (let* ((path (plist-get m :path))
         (mtime (plist-get m :mtime))
         (cwd (or (plist-get m :cwd) "?"))
         (project (file-name-nondirectory (directory-file-name cwd)))
         (model (or (plist-get m :model) ""))
         (provider (or (plist-get m :provider) ""))
         (model-cell (cond
                      ((and (not (string-empty-p provider))
                            (not (string-empty-p model)))
                       (format "%s/%s" provider model))
                      ((not (string-empty-p model)) model)
                      ((not (string-empty-p provider)) provider)
                      (t "?")))
         (turns (or (plist-get m :turns) 0))
         (sid (or (plist-get m :sessionId) "?"))
         (name (or (plist-get m :name) "(unnamed)"))
         (date-cell (format-time-string "%Y-%m-%d %H:%M" mtime))
         (sid-cell (substring sid 0 (min 8 (length sid))))
         (name-cell (propertize name 'face 'bold)))
    (list path
          (if cavemacs-session-browser--show-all
              (vector date-cell
                      (truncate-string-to-width project 24 nil nil "…")
                      (truncate-string-to-width model-cell 34 nil nil "…")
                      (number-to-string turns)
                      sid-cell
                      name-cell)
            (vector date-cell
                    (truncate-string-to-width model-cell 34 nil nil "…")
                    (number-to-string turns)
                    sid-cell
                    name-cell)))))

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
                         (cavemacs-session--cwd-match-p m root-as-dir))
                collect (cavemacs-session-browser--row m))))
    (setq tabulated-list-format (cavemacs-session-browser--columns))
    (setq tabulated-list-sort-key '("Modified" . t))
    (tabulated-list-init-header)
    (setq tabulated-list-entries rows)
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
  "Resume the session at point in a new cavemacs buffer.

The new buffer's project root is taken from the session's
recorded `cwd' (so this works correctly even from the
cross-project `a' view), falling back to the browser's own root."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No session at point"))
    (let* ((meta (cavemacs-session--meta path))
           (cwd (or (plist-get meta :cwd)
                    cavemacs-session-browser--root)))
      (cavemacs-shell-new
       :project-root cwd
       :session-file path))))

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

;; -----------------------------------------------------------------------------
;; Project browser (tabulated-list of distinct cwds, drills into sessions)
;; -----------------------------------------------------------------------------

(defun cavemacs-session--project-summaries ()
  "Return a list of project-summary plists.

Each entry: (:cwd :name :session-count :latest-mtime :latest-path).
Built by scanning every persisted session once and bucketing by cwd."
  (let ((buckets (make-hash-table :test 'equal)))
    (dolist (path (cavemacs-session--list-files))
      (let* ((m (cavemacs-session--meta path))
             (cwd (plist-get m :cwd))
             (mtime (plist-get m :mtime)))
        (when cwd
          (let* ((entry (gethash cwd buckets))
                 (prev-mtime (and entry (plist-get entry :latest-mtime))))
            (puthash
             cwd
             (list :cwd cwd
                   :name (file-name-nondirectory
                          (directory-file-name cwd))
                   :session-count (1+ (or (and entry
                                               (plist-get entry :session-count))
                                          0))
                   :latest-mtime (if (and prev-mtime (>= prev-mtime mtime))
                                     prev-mtime mtime)
                   :latest-path (if (and prev-mtime (>= prev-mtime mtime))
                                    (plist-get entry :latest-path)
                                  path))
             buckets)))))
    (let (out)
      (maphash (lambda (_k v) (push v out)) buckets)
      out)))

(define-derived-mode cavemacs-projects-mode tabulated-list-mode
  "cavemacs-projects"
  "Browse every project that has persisted caveman sessions.

`RET' opens the per-project session browser scoped to the
project at point."
  (setq tabulated-list-format
        (vector '("Modified" 17 t)
                '("Sessions" 8 t :right-align t)
                '("Project" 28 t)
                '("Path"     0 t)))
  (setq tabulated-list-sort-key '("Modified" . t))
  (tabulated-list-init-header))

(define-key cavemacs-projects-mode-map (kbd "RET")
            #'cavemacs-projects-open-at-point)
(define-key cavemacs-projects-mode-map (kbd "o")
            #'cavemacs-projects-open-at-point)
(define-key cavemacs-projects-mode-map (kbd "n")
            #'cavemacs-projects-new-at-point)
(define-key cavemacs-projects-mode-map (kbd "g")
            #'cavemacs-projects-refresh)
(define-key cavemacs-projects-mode-map (kbd "q") #'quit-window)

;;;###autoload
(defun cavemacs-projects ()
  "Open the cross-project session browser.

Lists every project that has at least one persisted cavemacs
session, sorted by most-recent activity.  `RET' on a row drills
into the per-project session browser for that project."
  (interactive)
  (let ((buf (get-buffer-create "*cavemacs projects*")))
    (with-current-buffer buf
      (cavemacs-projects-mode)
      (cavemacs-projects-refresh))
    (pop-to-buffer buf)))

(defun cavemacs-projects-refresh ()
  "Reload the projects list."
  (interactive)
  (let* ((projects (cavemacs-session--project-summaries))
         (rows
          (mapcar
           (lambda (p)
             (let* ((cwd (plist-get p :cwd))
                    (name (plist-get p :name))
                    (cnt (plist-get p :session-count))
                    (mtime (plist-get p :latest-mtime)))
               (list cwd
                     (vector (format-time-string "%Y-%m-%d %H:%M" mtime)
                             (number-to-string cnt)
                             (propertize
                              (truncate-string-to-width name 28 nil nil "…")
                              'face 'bold)
                             (abbreviate-file-name cwd)))))
           projects)))
    (setq tabulated-list-entries rows)
    (tabulated-list-print t)))

(defun cavemacs-projects-open-at-point ()
  "Open the per-project session browser for the project at point."
  (interactive)
  (let ((cwd (tabulated-list-get-id)))
    (unless cwd (user-error "No project at point"))
    (cavemacs-session-browser cwd)))

(defun cavemacs-projects-new-at-point ()
  "Start a fresh session in the project at point."
  (interactive)
  (let ((cwd (tabulated-list-get-id)))
    (unless cwd (user-error "No project at point"))
    (cavemacs-shell-new :project-root cwd)))

(provide 'cavemacs-session)
;;; cavemacs-session.el ends here
