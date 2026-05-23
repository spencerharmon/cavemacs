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
(require 'cavemacs-render)
(require 'cavemacs-project)

(defvar-local cavemacs-shell--conn nil
  "The `cavemacs-rpc-conn' for this buffer.")

(defvar-local cavemacs-shell--prompt-marker nil
  "Marker at the start of the user input area.")

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
    (define-key map (kbd "C-c C-c") #'cavemacs-shell-abort)
    (define-key map (kbd "C-c C-k") #'cavemacs-shell-abort)
    (define-key map (kbd "C-c C-n") #'cavemacs-shell-new-session-in-buffer)
    (define-key map (kbd "C-c C-s") #'cavemacs-shell-show-state)
    (define-key map (kbd "C-c C-l") #'cavemacs-shell-clear-output)
    (define-key map (kbd "C-c C-q") #'cavemacs-shell-quit)
    map)
  "Keymap for `cavemacs-shell-mode'.")

(define-derived-mode cavemacs-shell-mode fundamental-mode "cavemacs"
  "Major mode for cavemacs chat buffers."
  :group 'cavemacs
  (setq-local truncate-lines nil
              word-wrap t
              indent-tabs-mode nil
              ;; Ensure the rendered output above the prompt is read-only.
              inhibit-field-text-motion t)
  (setq-local mode-line-process '(:eval (cavemacs-shell--mode-line)))
  (add-hook 'kill-buffer-hook #'cavemacs-shell--on-kill nil t))

(defun cavemacs-shell--mode-line ()
  "Modeline contribution for the cavemacs shell."
  (concat " " cavemacs-shell--mode-line-info))

(defun cavemacs-shell--set-mode-info (text)
  (setq cavemacs-shell--mode-line-info text)
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
      (cavemacs-shell--insert-banner root)
      (cavemacs-shell--install-prompt)
      (cavemacs-shell--start-process :session-file session-file))
    (pop-to-buffer buf)
    buf))

(defun cavemacs-shell--buffer-name (root)
  (format cavemacs-shell-buffer-name-format
          (cavemacs-project-name root)))

(defun cavemacs-shell--insert-banner (root)
  "Insert a welcome banner."
  (let ((inhibit-read-only t))
    (insert (propertize
             (format "cavemacs %s — caveman session for %s\n\n"
                     (or (and (boundp 'cavemacs-version) cavemacs-version) "?")
                     (abbreviate-file-name root))
             'face 'cavemacs-meta-face))))

(defun cavemacs-shell--install-prompt ()
  "Insert the input-area separator and prompt marker."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (eq (char-before) ?\n) (insert "\n"))
    (let ((sep-start (point)))
      (insert (propertize
               (concat (make-string 70 ?─) "\n")
               'face 'cavemacs-meta-face
               'read-only t
               'rear-nonsticky '(read-only face)))
      (insert (propertize cavemacs-shell-prompt
                          'face 'cavemacs-user-prefix-face
                          'read-only t
                          'rear-nonsticky '(read-only face)))
      ;; Lock everything before this point as read-only.
      (put-text-property (point-min) (point) 'read-only t)
      (setq cavemacs-shell--prompt-marker (copy-marker (point) nil))
      (set-marker-insertion-type cavemacs-shell--prompt-marker nil)
      (ignore sep-start)))
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
    (ignore-errors (cavemacs-rpc-stop cavemacs-shell--conn))
    (setq cavemacs-shell--conn nil)))

;; -----------------------------------------------------------------------------
;; Input handling
;; -----------------------------------------------------------------------------

(defun cavemacs-shell--input-text ()
  "Return the current contents of the input area, trimmed."
  (when (and cavemacs-shell--prompt-marker
             (marker-position cavemacs-shell--prompt-marker))
    (string-trim
     (buffer-substring-no-properties
      (marker-position cavemacs-shell--prompt-marker)
      (point-max)))))

(defun cavemacs-shell--clear-input ()
  "Delete the contents of the input area."
  (let ((inhibit-read-only t))
    (delete-region (marker-position cavemacs-shell--prompt-marker)
                   (point-max))))

(defun cavemacs-shell-insert-newline ()
  "Insert a literal newline in the input area."
  (interactive)
  (insert "\n"))

(defun cavemacs-shell-send-or-newline ()
  "Submit the input area if at end-of-buffer; otherwise insert a newline."
  (interactive)
  (cond
   ((or (not cavemacs-shell--prompt-marker)
        (< (point) (marker-position cavemacs-shell--prompt-marker)))
    (newline))
   ((eobp)
    (cavemacs-shell-send))
   (t (newline))))

(defun cavemacs-shell-send ()
  "Send the contents of the input area to caveman as a `prompt' command."
  (interactive)
  (unless (cavemacs-rpc-live-p cavemacs-shell--conn)
    (user-error "cavemacs: RPC connection is not live"))
  (let ((text (cavemacs-shell--input-text)))
    (when (or (null text) (string-empty-p text))
      (user-error "cavemacs: nothing to send"))
    (cavemacs-shell--clear-input)
    ;; Render the user prompt locally (caveman will also emit message_start
    ;; for the user, but echoing locally avoids a perceptible delay).
    (cavemacs-render--at-output
      (cavemacs-render--ensure-blank-line-before)
      (insert (propertize "You" 'face 'cavemacs-user-prefix-face) "\n")
      (insert text)
      (insert "\n"))
    (cavemacs-rpc-send cavemacs-shell--conn "prompt" :message text)
    (cavemacs-shell--set-mode-info "sent")))

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
  (unless (cavemacs-rpc-live-p cavemacs-shell--conn)
    (user-error "Not connected"))
  (let ((resp (cavemacs-rpc-request-sync
               cavemacs-shell--conn "get_state" nil 10)))
    (with-help-window "*cavemacs-state*"
      (let ((print-length 32) (print-level 6))
        (pp (alist-get 'data resp) (current-buffer))))))

(defun cavemacs-shell-clear-output ()
  "Erase rendered output above the prompt marker."
  (interactive)
  (let ((inhibit-read-only t)
        (mark (and cavemacs-shell--prompt-marker
                   (marker-position cavemacs-shell--prompt-marker))))
    (when mark
      ;; Find the start of the separator line so we wipe it too.
      (save-excursion
        (goto-char mark)
        (forward-line -1)
        (beginning-of-line)
        (delete-region (point-min) (point))))
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
