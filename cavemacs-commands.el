;;; cavemacs-commands.el --- Slash-command dispatch + completion  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Caveman slash commands come in two flavours:
;;
;;   Built-ins  -- "/model", "/compact", "/cost" and friends.  These are
;;                 implemented in caveman's interactive TUI and DO NOT
;;                 work as user prompts in --mode rpc (the LLM just
;;                 answers them in plain English).  We map the
;;                 important ones to their direct RPC equivalents
;;                 (set_model, compact, new_session, etc.) here.
;;
;;   User-defined -- extensions, prompt templates, skills.  Listed by
;;                   the `get_commands' RPC.  Caveman's `prompt' RPC
;;                   handler runs these for us; we just need to send
;;                   the text and it does the dispatch.
;;
;; Public API:
;;
;;   `cavemacs-commands-pick'  -- pick a command via completing-read
;;                                and insert into the input area.
;;   `cavemacs-commands-run'   -- pick + immediately submit.
;;
;;   `cavemacs-commands-capf'  -- a `completion-at-point' function
;;                                bound in cavemacs-shell-mode that
;;                                offers completions when the input
;;                                area starts with "/".  Works with
;;                                Corfu, Company, the built-in
;;                                completion UI, etc.
;;
;;   `cavemacs-commands-dispatch' -- internal: called by
;;                                   `cavemacs-shell-send' to route a
;;                                   slash-prefixed input to the right
;;                                   RPC verb instead of sending it as
;;                                   a literal `prompt'.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cavemacs-rpc)

;; Forward declarations -- cavemacs-shell calls into this module via
;; `cavemacs-commands-dispatch' on every send, and we need access to
;; shell internals without forming a require cycle.
(declare-function cavemacs-render--notice "cavemacs-render" (text &optional face))
(defvar cavemacs-shell--conn)
(defvar cavemacs-shell--input-start-marker)

;; -----------------------------------------------------------------------------
;; Built-in command registry
;; -----------------------------------------------------------------------------
;;
;; Each entry: (NAME DESCRIPTION HANDLER).  HANDLER takes ARGS-STRING
;; (the rest of the line after "/name", may be "") and the live CONN.
;; HANDLER returns non-nil if it handled the command, nil to fall
;; through to sending the literal text as a regular `prompt'.

(defun cavemacs-commands--builtin-model (_args conn)
  "Open a model picker via get_available_models + set_model."
  (let* ((resp (cavemacs-rpc-request-sync conn "get_available_models" nil 15))
         (models (alist-get 'models (alist-get 'data resp))))
    (if (null models)
        (cavemacs-render--notice "/model: no models available"
                                 'cavemacs-error-face)
      (let* ((table (mapcar (lambda (m)
                              (cons (format "%s/%s — %s"
                                            (alist-get 'provider m)
                                            (alist-get 'id m)
                                            (or (alist-get 'name m) ""))
                                    m))
                            models))
             (choice (completing-read "Switch to model: " table nil t)))
        (when choice
          (let ((m (cdr (assoc choice table))))
            (cavemacs-rpc-request
             conn "set_model"
             (lambda (r)
               (if (eq (alist-get 'success r) t)
                   (cavemacs-render--notice
                    (format "model -> %s/%s"
                            (alist-get 'provider m) (alist-get 'id m))
                    'cavemacs-meta-face)
                 (cavemacs-render--notice
                  (format "set_model failed: %s" (alist-get 'error r))
                  'cavemacs-error-face)))
             :provider (alist-get 'provider m)
             :modelId  (alist-get 'id m)))))))
  t)

(defun cavemacs-commands--builtin-compact (args conn)
  "/compact [instructions]: manually compact context."
  (cavemacs-render--notice "/compact: compacting context…" 'cavemacs-meta-face)
  (if (and args (not (string-empty-p args)))
      (cavemacs-rpc-send conn "compact" :customInstructions args)
    (cavemacs-rpc-send conn "compact"))
  t)

(defun cavemacs-commands--builtin-new (_args conn)
  "/new, /clear: reset the session."
  (cavemacs-rpc-send conn "new_session")
  (cavemacs-render--notice "session reset" 'cavemacs-meta-face)
  t)

(defun cavemacs-commands--builtin-name (args conn)
  "/name <text>: set the session display name."
  (if (or (null args) (string-empty-p args))
      (cavemacs-render--notice "/name: usage: /name <new name>"
                               'cavemacs-error-face)
    (cavemacs-rpc-send conn "set_session_name" :name args)
    (cavemacs-render--notice (format "session name -> %s" args)
                             'cavemacs-meta-face))
  t)

(defun cavemacs-commands--builtin-session (_args conn)
  "/session: show session stats."
  (cavemacs-rpc-request
   conn "get_session_stats"
   (lambda (r)
     (if (eq (alist-get 'success r) t)
         (with-help-window "*cavemacs-session-stats*"
           (let ((print-length 32) (print-level 6))
             (pp (alist-get 'data r) (current-buffer))))
       (cavemacs-render--notice
        (format "/session failed: %s" (alist-get 'error r))
        'cavemacs-error-face))))
  t)

(defun cavemacs-commands--builtin-export (args conn)
  "/export [path]: export session to HTML."
  (cavemacs-rpc-request
   conn "export_html"
   (lambda (r)
     (if (eq (alist-get 'success r) t)
         (cavemacs-render--notice
          (format "/export: wrote %s"
                  (alist-get 'path (alist-get 'data r)))
          'cavemacs-meta-face)
       (cavemacs-render--notice
        (format "/export failed: %s" (alist-get 'error r))
        'cavemacs-error-face)))
   (if (and args (not (string-empty-p args)))
       (list :outputPath args)
     nil))
  t)

(defun cavemacs-commands--builtin-copy (_args conn)
  "/copy: copy the last assistant message to the kill ring."
  (cavemacs-rpc-request
   conn "get_last_assistant_text"
   (lambda (r)
     (if (eq (alist-get 'success r) t)
         (let ((text (alist-get 'text (alist-get 'data r))))
           (if (and text (not (string-empty-p text)))
               (progn (kill-new text)
                      (cavemacs-render--notice
                       (format "/copy: %d chars to kill ring" (length text))
                       'cavemacs-meta-face))
             (cavemacs-render--notice "/copy: no assistant message yet"
                                      'cavemacs-error-face)))
       (cavemacs-render--notice
        (format "/copy failed: %s" (alist-get 'error r))
        'cavemacs-error-face))))
  t)

(defun cavemacs-commands--builtin-bash (args conn)
  "/bash <cmd>: run a shell command via the `bash' RPC."
  (if (or (null args) (string-empty-p args))
      (cavemacs-render--notice "/bash: usage: /bash <command>"
                               'cavemacs-error-face)
    (cavemacs-render--notice (format "$ %s" args) 'cavemacs-meta-face)
    (cavemacs-rpc-request
     conn "bash"
     (lambda (r)
       (if (eq (alist-get 'success r) t)
           (let* ((data (alist-get 'data r))
                  (out (or (alist-get 'output data)
                           (alist-get 'stdout data) "")))
             (cavemacs-render--notice
              (or out "(no output)") 'cavemacs-meta-face))
         (cavemacs-render--notice
          (format "/bash failed: %s" (alist-get 'error r))
          'cavemacs-error-face)))
     :command args))
  t)

(defun cavemacs-commands--builtin-abort (_args conn)
  "/abort: cancel current run."
  (cavemacs-rpc-send conn "abort") t)

(defun cavemacs-commands--builtin-thinking (args conn)
  "/thinking <off|minimal|low|medium|high|xhigh>: set thinking level."
  (let ((level (and args (string-trim args))))
    (if (member level '("off" "minimal" "low" "medium" "high" "xhigh"))
        (progn (cavemacs-rpc-send conn "set_thinking_level" :level level)
               (cavemacs-render--notice
                (format "thinking -> %s" level) 'cavemacs-meta-face))
      (cavemacs-render--notice
       "/thinking: usage: /thinking <off|minimal|low|medium|high|xhigh>"
       'cavemacs-error-face)))
  t)

(defun cavemacs-commands--builtin-help (_args _conn)
  "/help: show cavemacs's own help text in the buffer."
  (cavemacs-render--notice
   (concat "cavemacs slash commands:\n"
           (mapconcat
            (lambda (entry)
              (format "  /%-12s %s" (car entry) (nth 1 entry)))
            cavemacs-commands--builtins "\n"))
   'cavemacs-meta-face)
  t)

(defconst cavemacs-commands--builtins
  '(;; Name        Description                                   Handler
    ("help"        "Show this list of commands"                  cavemacs-commands--builtin-help)
    ("model"       "Switch model"                                cavemacs-commands--builtin-model)
    ("thinking"    "Set thinking level"                          cavemacs-commands--builtin-thinking)
    ("compact"     "Compact context"                             cavemacs-commands--builtin-compact)
    ("new"         "Start a new session"                         cavemacs-commands--builtin-new)
    ("clear"       "Alias for /new"                              cavemacs-commands--builtin-new)
    ("name"        "Set session display name"                    cavemacs-commands--builtin-name)
    ("session"     "Show session stats"                          cavemacs-commands--builtin-session)
    ("export"      "Export session to HTML"                      cavemacs-commands--builtin-export)
    ("copy"        "Copy last assistant message to kill ring"    cavemacs-commands--builtin-copy)
    ("bash"        "Run a shell command"                         cavemacs-commands--builtin-bash)
    ("abort"       "Abort current run"                           cavemacs-commands--builtin-abort))
  "Locally-dispatched slash commands.  Each entry is (NAME DESC HANDLER).
HANDLER takes (ARGS-STRING CONN) and returns non-nil if handled.")

;; -----------------------------------------------------------------------------
;; Parsing
;; -----------------------------------------------------------------------------

(defun cavemacs-commands--parse (input)
  "Parse INPUT as a slash command.  Return (NAME . ARGS) or nil.
INPUT is trimmed before matching, so leading/trailing whitespace is OK."
  (when (stringp input)
    (let ((trimmed (string-trim input)))
      (when (string-match
             "\\`/\\([A-Za-z0-9_:-]+\\)\\(?: +\\(.*\\)\\)?\\'"
             trimmed)
        (cons (match-string 1 trimmed)
              (string-trim (or (match-string 2 trimmed) "")))))))

;; -----------------------------------------------------------------------------
;; Dispatch (called by cavemacs-shell-send)
;; -----------------------------------------------------------------------------

(defun cavemacs-commands-dispatch (input conn)
  "Try to dispatch INPUT as a slash command on CONN.
Returns non-nil if the input was a built-in command (and was
handled locally).  Returns nil if INPUT should be sent to caveman
as a regular `prompt'.  User-defined commands (extension/prompt/
skill) fall through here: caveman's RPC `prompt' handler dispatches
them, so we let it."
  (when-let* ((parsed (cavemacs-commands--parse input))
              (name (car parsed))
              (args (cdr parsed))
              (entry (assoc name cavemacs-commands--builtins)))
    (let ((handler (nth 2 entry)))
      (condition-case err
          (funcall handler args conn)
        (error
         (cavemacs-render--notice
          (format "/%s error: %s" name (error-message-string err))
          'cavemacs-error-face)
         t)))))

;; -----------------------------------------------------------------------------
;; Listing for completion + picker
;; -----------------------------------------------------------------------------

(defvar-local cavemacs-commands--user-cache nil
  "Cached (TIMESTAMP . COMMANDS) for this buffer's `get_commands' result.")

(defun cavemacs-commands--user-commands (conn &optional max-age)
  "Return user-defined slash commands from CONN, cached for MAX-AGE seconds.
MAX-AGE defaults to 5."
  (let* ((max-age (or max-age 5))
         (cache cavemacs-commands--user-cache)
         (now (float-time))
         (fresh (and cache (< (- now (car cache)) max-age))))
    (if fresh
        (cdr cache)
      (let* ((resp (and conn (cavemacs-rpc-live-p conn)
                        (cavemacs-rpc-request-sync conn "get_commands" nil 5)))
             (cmds (and resp (eq (alist-get 'success resp) t)
                        (alist-get 'commands (alist-get 'data resp)))))
        (setq cavemacs-commands--user-cache (cons now (or cmds '())))
        (or cmds '())))))

(defun cavemacs-commands--all (conn)
  "Return a list of plists: (:name :description :source) for every command."
  (append
   (mapcar (lambda (b)
             (list :name (car b) :description (nth 1 b) :source "builtin"))
           cavemacs-commands--builtins)
   (mapcar (lambda (c)
             (list :name (alist-get 'name c)
                   :description (or (alist-get 'description c) "")
                   :source (or (alist-get 'source c) "user")))
           (cavemacs-commands--user-commands conn))))

;; -----------------------------------------------------------------------------
;; completion-at-point function
;; -----------------------------------------------------------------------------

(defun cavemacs-commands-capf ()
  "Completion-at-point for slash commands inside the cavemacs input area.

Active only when the input area starts with \"/\" and point is on
the first word (the command name).  Plays nice with Corfu, Company,
default completion UI."
  (when (and (boundp 'cavemacs-shell--input-start-marker)
             cavemacs-shell--input-start-marker
             (>= (point) (marker-position
                          cavemacs-shell--input-start-marker)))
    (let* ((input-start (marker-position
                         cavemacs-shell--input-start-marker))
           (first-char (and (< input-start (point-max))
                            (char-after input-start))))
      (when (eq first-char ?/)
        (save-excursion
          (let* ((bow (1+ input-start)) ; just after the "/"
                 (eow (progn (goto-char bow)
                             (skip-chars-forward "A-Za-z0-9_:-")
                             (point))))
            ;; Only offer completion if point is within the name word.
            (when (and (>= (point) bow) (<= (point) eow))
              (let* ((cmds (cavemacs-commands--all
                            (and (boundp 'cavemacs-shell--conn)
                                 cavemacs-shell--conn)))
                     (candidates
                      (mapcar (lambda (c) (plist-get c :name)) cmds))
                     (anno-table
                      (mapcar (lambda (c)
                                (cons (plist-get c :name)
                                      (format "  [%s] %s"
                                              (plist-get c :source)
                                              (plist-get c :description))))
                              cmds)))
                (list bow eow candidates
                      :annotation-function
                      (lambda (cand) (cdr (assoc cand anno-table)))
                      :exclusive 'no)))))))))

(defun cavemacs-commands-setup-capf ()
  "Install `cavemacs-commands-capf' into the local CAPF list.
Call from `cavemacs-shell-mode-hook' (already done automatically
when this file is loaded)."
  (add-hook 'completion-at-point-functions
            #'cavemacs-commands-capf nil t))

;; -----------------------------------------------------------------------------
;; Interactive entry points
;; -----------------------------------------------------------------------------

(defun cavemacs-commands-pick ()
  "Pick a slash command via `completing-read' and insert it.
Includes both cavemacs built-ins and user-defined commands."
  (interactive)
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer"))
  (let* ((cmds (cavemacs-commands--all cavemacs-shell--conn))
         (table (mapcar (lambda (c)
                          (cons (format "/%s — %s  [%s]"
                                        (plist-get c :name)
                                        (plist-get c :description)
                                        (plist-get c :source))
                                (concat "/" (plist-get c :name))))
                        cmds))
         (choice (completing-read "Command: " table nil t)))
    (when choice
      (let ((slash (cdr (assoc choice table))))
        (goto-char (point-max))
        (insert slash " ")))))

(defun cavemacs-commands-run (cmd)
  "Insert CMD into the input area and submit immediately."
  (interactive (list (read-string "/")))
  (unless (and (boundp 'cavemacs-shell--conn)
               (cavemacs-rpc-live-p cavemacs-shell--conn))
    (user-error "Not in a live cavemacs buffer"))
  (let ((line (if (string-prefix-p "/" cmd) cmd (concat "/" cmd))))
    (goto-char (point-max))
    (insert line)
    (cavemacs-shell-send)))

(declare-function cavemacs-shell-send "cavemacs-shell")

(provide 'cavemacs-commands)
;;; cavemacs-commands.el ends here
