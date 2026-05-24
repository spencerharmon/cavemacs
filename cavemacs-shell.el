;;; cavemacs-shell.el --- cavemacs chat buffer + major mode  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; A dedicated chat buffer for a single caveman session.  The buffer
;; layout is:
;;
;;   ┌──────────────────────────────────────────────────┐
;;   │  banner                                          │
;;   │                                                  │
;;   │  You                                             │
;;   │    earlier prompt                                │
;;   │                                                  │
;;   │  Assistant · github-copilot/gpt-4o               │
;;   │    response with **markdown**                    │
;;   │                                                  │
;;   │  ── 1200 in / 80 out / 1280 total · $0.0023      │
;;   │                                                  │
;;   ├── prompt marker (read-only above) ───────────────│
;;   │ > │_                                             │
;;   └──────────────────────────────────────────────────┘
;;
;; Everything above `cavemacs-shell--prompt-marker' is read-only
;; rendered output managed by cavemacs-render.el.  Below the marker is
;; the user input area, editable, multi-line.  RET sends the buffered
;; input to caveman as a `prompt' command (when on the final logical
;; line and not within an editable block; M-RET inserts a literal newline).
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cavemacs-config)
(require 'cavemacs-rpc)
(require 'cavemacs-pretty)
(require 'cavemacs-render)
(require 'cavemacs-project)

;; Used by `cavemacs-shell-send' to intercept slash commands.  Required
;; lazily inside the function to avoid a require cycle (cavemacs-commands
;; declares this file's internals via declare-function).
(declare-function cavemacs-commands-dispatch "cavemacs-commands" (input conn))
(declare-function cavemacs-commands-setup-capf "cavemacs-commands" ())

(defvar-local cavemacs-shell--conn nil
  "The `cavemacs-rpc-conn' for this buffer.")

(defvar-local cavemacs-shell--prompt-marker nil
  "Marker just before the input-area separator/prompt prefix.
Rendering inserts at this marker (which advances on insert), so
rendered output piles up above the separator while the input area
stays at the bottom of the buffer.")

(defvar-local cavemacs-shell--input-start-marker nil
  "Marker at the first user-editable position (just after the prompt prefix).
Point-max minus this marker is the user's current input.")

(defvar-local cavemacs-shell--project-root nil
  "Absolute project root directory associated with this buffer.")

(defvar-local cavemacs-shell--session-state nil
  "Last-known session state alist from a `get_state' response.")

(defvar-local cavemacs-shell--mode-line-info ""
  "Modeline tail string showing state, cost, etc.")

(defcustom cavemacs-shell-prompt "> "
  "Prefix string for the user input area."
  :type 'string
  :group 'cavemacs)

(defcustom cavemacs-shell-buffer-name-format "*cavemacs: %s*"
  "Format string for shell buffer names.
Takes one argument: the project name."
  :type 'string
  :group 'cavemacs)

(defvar cavemacs-shell-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'cavemacs-shell-send-or-newline)
    (define-key map (kbd "M-RET")   #'cavemacs-shell-insert-newline)
    ;; Bind both TAB representations.  Some minor modes (copilot,
    ;; yasnippet) override one or the other; binding both reduces
    ;; the chance of being shadowed.  In practice if copilot-mode
    ;; is active in this buffer it still wins via
    ;; emulation-mode-map-alists -- see
    ;; `cavemacs-shell--ensure-completion-bindings'.
    (define-key map (kbd "TAB")     #'cavemacs-shell-complete)
    (define-key map (kbd "<tab>")   #'cavemacs-shell-complete)
    (define-key map (kbd "/")       #'cavemacs-shell-self-insert-slash)
    (define-key map (kbd "C-c C-c") #'cavemacs-shell-abort)
    (define-key map (kbd "C-c C-k") #'cavemacs-shell-abort)
    (define-key map (kbd "C-c C-n") #'cavemacs-shell-new-session-in-buffer)
    (define-key map (kbd "C-c C-s") #'cavemacs-shell-show-state)
    (define-key map (kbd "C-c C-l") #'cavemacs-shell-clear-output)
    (define-key map (kbd "C-c C-q") #'cavemacs-shell-quit)
    (define-key map (kbd "C-c C-e") #'cavemacs-shell-show-stderr)
    (define-key map (kbd "C-c C-r") #'cavemacs-shell-restart)
    (define-key map (kbd "M-{")     #'cavemacs-render-previous-turn)
    (define-key map (kbd "M-}")     #'cavemacs-render-next-turn)
    (define-key map (kbd "C-a")     #'cavemacs-shell-beginning-of-line)
    (define-key map (kbd "<home>")  #'cavemacs-shell-beginning-of-line)
    (define-key map (kbd "C-c TAB") #'cavemacs-render-toggle-all)
    (define-key map (kbd "C-c C-<tab>") #'cavemacs-render-toggle-all)
    map)
  "Keymap for `cavemacs-shell-mode'.")

(define-derived-mode cavemacs-shell-mode fundamental-mode "cavemacs"
  "Major mode for cavemacs chat buffers."
  :group 'cavemacs
  (setq-local truncate-lines nil
              word-wrap t
              indent-tabs-mode nil
              inhibit-field-text-motion t
              ;; Chat-style scroll: keep point pinned to the bottom of
              ;; the window so the input area is always visible.  These
              ;; are the standard comint settings.
              scroll-conservatively 101
              scroll-margin 0)
  (setq-local mode-line-process '(:eval (cavemacs-shell--mode-line)))
  (setq-local filter-buffer-substring-function
              #'cavemacs-shell--filter-buffer-substring)
  ;; Slash-command completion.  Loaded lazily; if cavemacs-commands is
  ;; already on the load path (it is, since cavemacs.el requires it),
  ;; this is a no-op.
  (require 'cavemacs-commands)
  (cavemacs-commands-setup-capf)
  ;; Defang minor modes that aggressively bind TAB so our
  ;; `cavemacs-shell-complete' actually runs.  Most common offender
  ;; is copilot; yasnippet usually plays nicer but can win on empty
  ;; lines.  We deliberately do *not* disable the minor mode itself --
  ;; the user may want it elsewhere -- just its TAB binding in this
  ;; buffer.
  (cavemacs-shell--neutralize-rival-tab-bindings)
  (cavemacs-pretty-maybe-enable)
  (add-to-invisibility-spec 'cavemacs-collapse)
  (add-hook 'kill-buffer-hook #'cavemacs-shell--on-kill nil t))

(defun cavemacs-shell--neutralize-rival-tab-bindings ()
  "Unbind TAB in any minor-mode keymap that would shadow our binding.

Adds a buffer-local override so even modes that bind TAB via
`emulation-mode-map-alists' (like copilot) lose."
  ;; Override emulation maps (copilot, evil, etc.) at the highest
  ;; precedence using a buffer-local minor-mode-overriding-map-alist.
  (let ((override-map (make-sparse-keymap)))
    (define-key override-map (kbd "TAB")    #'cavemacs-shell-complete)
    (define-key override-map (kbd "<tab>")  #'cavemacs-shell-complete)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'cavemacs-shell-mode override-map)
                      minor-mode-overriding-map-alist))))

(defun cavemacs-shell--filter-buffer-substring (beg end delete)
  "Strip tool-card box rule glyphs (chars tagged `cavemacs-rule') from copied text.
DELETE follows `filter-buffer-substring' contract."
  (let ((src (current-buffer))
        (result nil)
        (p beg))
    (while (< p end)
      (let ((next (or (next-single-property-change p 'cavemacs-rule src end)
                      end)))
        (unless (get-text-property p 'cavemacs-rule src)
          (push (buffer-substring p next) result))
        (setq p next)))
    (when delete (delete-region beg end))
    (apply #'concat (nreverse result))))

(defun cavemacs-shell--mode-line ()
  "Modeline contribution for the cavemacs shell."
  (concat " " cavemacs-shell--mode-line-info))

(defun cavemacs-shell--set-mode-info (text)
  (setq cavemacs-shell--mode-line-info text)
  ;; Mirror coarse state into the pretty header-line dot.
  (when (boundp 'cavemacs-pretty--header-state)
    (cavemacs-pretty-state-put
     :status (cond ((string-match-p "exited\\|error" text) 'error)
                   ((string-match-p "idle\\|reset"  text) 'idle)
                   (t 'busy))))
  (force-mode-line-update))

;; -----------------------------------------------------------------------------
;; Buffer construction
;; -----------------------------------------------------------------------------

(cl-defun cavemacs-shell-new (&key project-root session-file)
  "Create a fresh cavemacs shell buffer and return it.

PROJECT-ROOT is the absolute path used as the subprocess CWD.
SESSION-FILE, when non-nil, is passed via `--session <path>' to
resume an on-disk session."
  (let* ((root (file-name-as-directory
                (expand-file-name (or project-root (cavemacs-project-root)))))
         (name (cavemacs-shell--buffer-name root))
         (buf (generate-new-buffer name)))
    (with-current-buffer buf
      (cavemacs-shell-mode)
      (setq cavemacs-shell--project-root root
            default-directory root)
      (cavemacs-render-init-buffer)
      (cavemacs-pretty-state-put :project (cavemacs-project-name root))
      (when cavemacs-thinking-level
        (cavemacs-pretty-state-put :thinking cavemacs-thinking-level))
      (cavemacs-shell--insert-banner root)
      (cavemacs-shell--install-prompt)
      (cavemacs-shell--start-process :session-file session-file))
    (pop-to-buffer buf)
    buf))

(defun cavemacs-shell--buffer-name (root)
  (format cavemacs-shell-buffer-name-format
          (cavemacs-project-name root)))

(defun cavemacs-shell--insert-banner (root)
  "Insert a welcome banner.

Includes the resolved project root and the exact argv we pass to
caveman.  When users hit cryptic startup failures (an extension
loaded from a path that surprises them, an auth error against an
unexpected provider, etc.) the banner is the single source of
truth for what cavemacs handed to the subprocess."
  (let ((inhibit-read-only t)
        (args (ignore-errors (cavemacs--default-process-args))))
    (insert
     (propertize
      (concat
       (format "cavemacs %s — caveman session\n"
               (or (and (boundp 'cavemacs-version) cavemacs-version) "?"))
       (format "  project root : %s\n" (abbreviate-file-name root))
       (format "  argv         : caveman %s\n"
               (mapconcat #'identity (or args '("--mode" "rpc")) " "))
       "\n")
      'face 'cavemacs-meta-face))))

(defun cavemacs-shell--install-prompt ()
  "Insert the input-area separator and prompt prefix, and set markers.

Layout (top to bottom):
   ...rendered output...
   [prompt-marker]            <- new render output inserted here
   ─────...
   > [input-start-marker]_    <- user types here"
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (eq (char-before) ?\n) (insert "\n"))
    (let ((prompt-pos (point)))
      ;; Insert the prompt furniture.
      (insert (propertize
               (concat (make-string 70 ?─) "\n")
               'face 'cavemacs-meta-face
               'read-only t
               'front-sticky '(read-only)
               'rear-nonsticky '(read-only face)))
      (insert (propertize cavemacs-shell-prompt
                          'face 'cavemacs-user-prefix-face
                          'read-only t
                          'front-sticky '(read-only)
                          'rear-nonsticky '(read-only face)))
      ;; Now create the markers.  prompt-marker is at prompt-pos
      ;; (before the separator).  insertion-type t means later
      ;; (insert ...) at that position pushes the marker forward,
      ;; so the separator+prefix stay anchored to the bottom of the
      ;; buffer while rendered output accumulates above.
      (setq cavemacs-shell--prompt-marker (copy-marker prompt-pos t))
      ;; input-start-marker: at point (right after the prefix).
      ;; insertion-type nil means user typing past it does not
      ;; advance the marker, so the marker keeps marking the
      ;; first user-editable column.
      (setq cavemacs-shell--input-start-marker (copy-marker (point) nil))
      ;; Make everything from BOB through the prompt prefix read-only.
      (put-text-property (point-min) (point) 'read-only t)))
  (goto-char (point-max)))

;; -----------------------------------------------------------------------------
;; Process lifecycle
;; -----------------------------------------------------------------------------

(cl-defun cavemacs-shell--start-process (&key session-file)
  "Spawn caveman, attach hooks, request initial state."
  (let* ((binary (cavemacs--binary))
         (base-args (cavemacs--default-process-args))
         (args (append base-args
                       (when session-file (list "--session" session-file))))
         (env cavemacs-environment)
         (conn (cavemacs-rpc-start binary
                                   :args args
                                   :environment env
                                   :owner-buffer (current-buffer))))
    (setq cavemacs-shell--conn conn)
    (cavemacs-rpc-add-event-hook
     conn (cavemacs-shell--make-event-router (current-buffer)))
    (when (fboundp 'cavemacs-tools-install-ui-handler)
      (cavemacs-tools-install-ui-handler conn (current-buffer)))
    (cavemacs-shell--set-mode-info "starting…")
    ;; Fire an initial state query; result populates modeline.
    (cavemacs-rpc-request
     conn "get_state"
     (cavemacs-shell--make-state-callback (current-buffer)))))

(defun cavemacs-shell--make-event-router (buffer)
  "Return a closure that routes events to the renderer in BUFFER."
  (lambda (event)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((type (alist-get 'type event)))
          (cavemacs-render-event event)
          ;; Mode-line state hints
          (pcase type
            ("turn_start" (cavemacs-shell--set-mode-info "thinking…"))
            ("tool_execution_start"
             (cavemacs-shell--set-mode-info
              (format "tool: %s" (alist-get 'toolName event))))
            ("agent_end"  (cavemacs-shell--set-mode-info "idle"))
            ("compaction_start" (cavemacs-shell--set-mode-info "compacting…"))
            ("cavemacs_process_exited"
             (cavemacs-shell--set-mode-info "exited"))))))))

(defun cavemacs-shell--make-state-callback (buffer)
  "Return a callback that updates BUFFER's session state from a get_state response."
  (lambda (resp)
    (when (and (buffer-live-p buffer)
               (eq (alist-get 'success resp) t))
      (with-current-buffer buffer
        (setq cavemacs-shell--session-state (alist-get 'data resp))
        (let* ((data cavemacs-shell--session-state)
               (model (alist-get 'model data))
               (provider (and model (alist-get 'provider model)))
               (mid (and model (alist-get 'id model))))
          (cavemacs-shell--set-mode-info
           (if (and provider mid)
               (format "idle · %s/%s" provider mid)
             "idle")))))))

(defun cavemacs-shell--on-kill ()
  "Tear down the RPC connection when the buffer is killed."
  (when cavemacs-shell--conn
    ;; Pass nil so the stderr buffer *is* killed at owner-buffer
    ;; death (no longer needed for postmortem).
    (ignore-errors (cavemacs-rpc-stop cavemacs-shell--conn nil))
    (setq cavemacs-shell--conn nil)))

(defun cavemacs-shell-show-stderr ()
  "Pop to the buffer containing caveman stderr for this session.

After an abnormal exit, the stderr buffer is retained until the
shell buffer itself is killed so users can inspect the failure."
  (interactive)
  (let ((buf (and cavemacs-shell--conn
                  (cavemacs-rpc-stderr-buffer cavemacs-shell--conn))))
    (unless (buffer-live-p buf)
      (user-error "cavemacs: no stderr buffer available"))
    (pop-to-buffer buf)
    (goto-char (point-max))))

(defun cavemacs-shell-restart ()
  "Restart caveman in this buffer with the same args.

Use this after \"command exited abnormally\".  Keeps the rendered
history in the buffer; spawns a fresh subprocess and re-attaches."
  (interactive)
  (when (and cavemacs-shell--conn
             (cavemacs-rpc-live-p cavemacs-shell--conn))
    (ignore-errors (cavemacs-rpc-stop cavemacs-shell--conn nil)))
  (setq cavemacs-shell--conn nil)
  (cavemacs-pretty-state-put :status 'idle)
  (cavemacs-shell--set-mode-info "restarting…")
  (cavemacs-shell--start-process :session-file nil)
  (message "cavemacs: restarting caveman"))

(defun cavemacs-shell--require-live-conn ()
  "Signal a helpful error if the RPC connection is dead.

The message points users at the actionable next steps
(M-x cavemacs-shell-show-stderr / M-x cavemacs-shell-restart),
which is much friendlier than a bare \"RPC connection is not live\"
that leaves users guessing what to do."
  (unless (cavemacs-rpc-live-p cavemacs-shell--conn)
    (user-error
     "cavemacs: caveman process is not running.  %s"
     "C-c C-e (show stderr) · C-c C-r (restart)")))

;; -----------------------------------------------------------------------------
;; Input handling
;; -----------------------------------------------------------------------------

(defun cavemacs-shell--input-text ()
  "Return the current contents of the input area, trimmed."
  (when (and cavemacs-shell--input-start-marker
             (marker-position cavemacs-shell--input-start-marker))
    (string-trim
     (buffer-substring-no-properties
      (marker-position cavemacs-shell--input-start-marker)
      (point-max)))))

(defun cavemacs-shell--clear-input ()
  "Delete the contents of the input area."
  (let ((inhibit-read-only t))
    (delete-region (marker-position cavemacs-shell--input-start-marker)
                   (point-max))))

(defun cavemacs-shell-insert-newline ()
  "Insert a literal newline in the input area."
  (interactive)
  (insert "\n"))

(defun cavemacs-shell-beginning-of-line (&optional arg)
  "Move point to the first editable column of the input area.

When point is inside the input area, jump to
`cavemacs-shell--input-start-marker' (the column just after the
prompt prefix) instead of column 0.  Column 0 is inside the
read-only prompt characters (the separator and `> ' prefix) and
landing there is confusing.

When point is in the rendered-output region above the input
area, behave as ordinary `move-beginning-of-line'.

ARG is forwarded to `move-beginning-of-line' for ARG-line jumps
in the output region; ignored in the input area.

Respects `shift-select-mode': if invoked with a shift-translated
binding (e.g. \\[universal-argument] then `C-S-a'), the mark is
set and selection extended, matching the convention of other
movement commands."
  (interactive "^p")
  (let ((input-start (and (boundp 'cavemacs-shell--input-start-marker)
                          cavemacs-shell--input-start-marker
                          (marker-position
                           cavemacs-shell--input-start-marker))))
    (cond
     ;; Inside input area: jump to its first editable column.  We
     ;; intentionally ignore ARG here; nobody types `C-u 3 C-a' to
     ;; move three lines into a multi-line prompt.
     ((and input-start (>= (point) input-start))
      (goto-char input-start))
     ;; Above input area: standard line-beginning behaviour.
     (t
      (move-beginning-of-line (or arg 1))))))

(defun cavemacs-shell-complete ()
  "Trigger completion in the cavemacs input area.
Forces `completion-at-point' to run our slash-command CAPF even
when other completion frontends (Copilot, Corfu, etc.) might
otherwise win the TAB key."
  (interactive)
  (cond
   ;; Inside the input area: always offer slash-command completion
   ;; via the standard CAPF mechanism.
   ((and (boundp 'cavemacs-shell--input-start-marker)
         cavemacs-shell--input-start-marker
         (>= (point) (marker-position cavemacs-shell--input-start-marker)))
    (completion-at-point))
   ;; On a collapsible block header: toggle it. The buffer-local TAB
   ;; binding otherwise shadows the text-property keymap.
   ((or (get-text-property (point) 'cavemacs-collapse-id)
         (get-text-property (line-beginning-position) 'cavemacs-collapse-id))
    (cavemacs-render-toggle-at-point))
   ;; Above the input area, no collapse target: regular indent.
   (t (indent-for-tab-command))))

(defun cavemacs-shell-self-insert-slash ()
  "Insert / and trigger slash-command completion if at start of input."
  (interactive)
  (insert "/")
  ;; Only auto-trigger when this is the *first* character of the
  ;; input area (so typing a literal '/' inside a longer prompt
  ;; like 'use the /etc/passwd file' does NOT pop completion).
  (when (and (boundp 'cavemacs-shell--input-start-marker)
             cavemacs-shell--input-start-marker
             (= (point) (1+ (marker-position
                             cavemacs-shell--input-start-marker))))
    (ignore-errors (completion-at-point))))

(defun cavemacs-shell-send-or-newline ()
  "Submit the input area if at end-of-buffer; otherwise insert a newline."
  (interactive)
  (cond
   ;; On a collapsible block header above the input area: toggle it.
   ((and cavemacs-shell--input-start-marker
         (< (point) (marker-position cavemacs-shell--input-start-marker))
         (or (get-text-property (point) 'cavemacs-collapse-id)
             (get-text-property (line-beginning-position) 'cavemacs-collapse-id)))
    (cavemacs-render-toggle-at-point))
   ((or (not cavemacs-shell--input-start-marker)
        (< (point) (marker-position cavemacs-shell--input-start-marker)))
    (newline))
   ((eobp)
    (cavemacs-shell-send))
   (t (newline))))

(defun cavemacs-shell-send ()
  "Send the contents of the input area.

If the input starts with \"/<name>\" and <name> is a cavemacs
built-in command (see `cavemacs-commands--builtins'), dispatch it
locally via the appropriate RPC verb instead of sending the literal
text as a `prompt' (caveman's `prompt' handler does not run
built-in slash commands in --mode rpc; the LLM would just answer
them as plain text).

User-defined slash commands (extensions/prompt-templates/skills)
are sent as a `prompt' -- caveman's RPC handler dispatches them
itself."
  (interactive)
  (cavemacs-shell--require-live-conn)
  (let ((text (cavemacs-shell--input-text)))
    (when (or (null text) (string-empty-p text))
      (user-error "cavemacs: nothing to send"))
    (cavemacs-shell--clear-input)
    (cond
     ;; Local dispatch for built-in slash commands.
     ((progn (require 'cavemacs-commands)
             (cavemacs-commands-dispatch text cavemacs-shell--conn))
      (cavemacs-shell--set-mode-info "idle"))
     ;; Everything else: send as a prompt.  Caveman will emit
     ;; `message_start' for the user message, which the renderer
     ;; turns into the visible "You ..." block.
     (t
      (cavemacs-rpc-send cavemacs-shell--conn "prompt" :message text)
      (cavemacs-shell--set-mode-info "sent")))
    ;; Park point in the now-empty input area so the user can keep
    ;; typing and so `(eobp)' will be true on the next RET.
    (goto-char (point-max))))

(defun cavemacs-shell-abort ()
  "Abort the current run, if any."
  (interactive)
  (when (cavemacs-rpc-live-p cavemacs-shell--conn)
    (cavemacs-rpc-send cavemacs-shell--conn "abort")
    (cavemacs-shell--set-mode-info "aborting…")))

(defun cavemacs-shell-new-session-in-buffer ()
  "Reset this buffer's session (caveman `new_session').
Does not spawn a new buffer."
  (interactive)
  (when (cavemacs-rpc-live-p cavemacs-shell--conn)
    (cavemacs-rpc-send cavemacs-shell--conn "new_session")
    (cavemacs-shell--set-mode-info "reset")))

(defun cavemacs-shell-show-state ()
  "Display the current `get_state' response in a help buffer."
  (interactive)
  (cavemacs-shell--require-live-conn)
  (let ((resp (cavemacs-rpc-request-sync
               cavemacs-shell--conn "get_state" nil 10)))
    (with-help-window "*cavemacs-state*"
      (let ((print-length 32) (print-level 6))
        (pp (alist-get 'data resp) (current-buffer))))))

(defun cavemacs-shell-clear-output ()
  "Erase rendered output above the prompt separator."
  (interactive)
  (let ((inhibit-read-only t)
        (mark (and cavemacs-shell--prompt-marker
                   (marker-position cavemacs-shell--prompt-marker))))
    (when mark
      ;; Delete everything from the start of the buffer up to (but not
      ;; including) the prompt marker -- that wipes only rendered turns
      ;; and leaves the banner... actually wipe the banner too: it's
      ;; informational and gets pushed off-screen quickly anyway.
      (delete-region (point-min) mark))
    (cavemacs-render-init-buffer)))

(defun cavemacs-shell-quit ()
  "Stop the caveman process and kill this buffer."
  (interactive)
  (when cavemacs-shell--conn
    (ignore-errors (cavemacs-rpc-stop cavemacs-shell--conn))
    (setq cavemacs-shell--conn nil))
  (kill-buffer (current-buffer)))

;; -----------------------------------------------------------------------------
;; Project lookup helpers used by `M-x cavemacs'
;; -----------------------------------------------------------------------------

(defun cavemacs-shell-live-buffers-for-project (root)
  "Return the list of live cavemacs shell buffers rooted at ROOT."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (cl-loop for buf in (buffer-list)
             when (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and (derived-mode-p 'cavemacs-shell-mode)
                              cavemacs-shell--project-root
                              (string= cavemacs-shell--project-root root)
                              (cavemacs-rpc-live-p cavemacs-shell--conn))))
             collect buf)))

(provide 'cavemacs-shell)
;;; cavemacs-shell.el ends here
