;;; cavemacs-tools.el --- Extension UI handler (approvals, inputs)  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Caveman's tool-call approvals, file-pick dialogs, and other interactive
;; UI prompts all arrive over the RPC channel as `extension_ui_request'
;; messages.  The methods we handle:
;;
;;   confirm  -- yes/no  (used for tool approvals among other things)
;;   select   -- pick one of N options
;;   input    -- single-line text input
;;   editor   -- multi-line text input
;;   notify   -- info/warning/error message (no reply needed)
;;   setStatus, setWidget, setTitle, set_editor_text -- decorative
;;
;; Each interactive request is presented synchronously via
;; `read-char-choice' / `read-string', which keeps the implementation
;; small and dependency-free while still being responsive.
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cavemacs-rpc)

;; Forward declarations: these live in cavemacs-render and cavemacs-shell,
;; which we cannot `require' here without introducing a load cycle
;; (cavemacs-shell already loads us via its event-router wiring).
(declare-function cavemacs-render--notice "cavemacs-render" (text &optional face))
(declare-function cavemacs-shell--set-mode-info "cavemacs-shell" (text))
(defvar cavemacs-shell--prompt-marker)
(defvar cavemacs-shell--input-start-marker)
(defvar cavemacs-shell--mode-line-info)
(defvar cavemacs-shell--conn)

(defcustom cavemacs-tools-autopilot nil
  "When non-nil, auto-approve all `confirm' requests from caveman.
This mirrors caveman's own `--autopilot' mode.  Use with caution: tool
calls will execute without user prompt."
  :type 'boolean
  :group 'cavemacs)

(defun cavemacs-tools-install-ui-handler (conn buffer)
  "Install the cavemacs UI handler on CONN, dispatching prompts in BUFFER."
  (cavemacs-rpc-add-ui-handler
   conn (cavemacs-tools--make-handler buffer)))

(defun cavemacs-tools--make-handler (buffer)
  "Return a UI handler closure bound to BUFFER."
  (lambda (req)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (cavemacs-tools--handle req cavemacs-shell--conn)))))

(defun cavemacs-tools--handle (req conn)
  "Dispatch a single extension_ui_request REQ on CONN.  Return non-nil if claimed."
  (let ((method (alist-get 'method req)))
    (pcase method
      ("confirm"          (cavemacs-tools--confirm conn req) t)
      ("select"           (cavemacs-tools--select conn req) t)
      ("input"            (cavemacs-tools--input conn req) t)
      ("editor"           (cavemacs-tools--editor conn req) t)
      ("notify"           (cavemacs-tools--notify req) t)
      ("setStatus"        (cavemacs-tools--set-status req) t)
      ("setWidget"        t)              ; ignore in v1, claim to silence
      ("setTitle"         t)
      ("set_editor_text"  (cavemacs-tools--set-editor-text req) t)
      (_ nil))))

(defun cavemacs-tools--confirm (conn req)
  "Handle a `confirm' request."
  (let* ((title (or (alist-get 'title req) "Confirm"))
         (message (alist-get 'message req))
         (prompt (if message (format "%s — %s [y/n/a]? " title message)
                   (format "%s [y/n/a]? " title)))
         (answer (cond
                  (cavemacs-tools-autopilot ?y)
                  (t
                   (let ((inhibit-quit nil))
                     (condition-case nil
                         (read-char-choice prompt '(?y ?Y ?n ?N ?a ?A ?\C-g))
                       (quit ?n)))))))
    (pcase answer
      ((or ?y ?Y) (cavemacs-rpc-reply-ui conn req :confirmed t))
      ((or ?a ?A)
       (setq-local cavemacs-tools-autopilot t)
       (message "cavemacs: autopilot enabled for this buffer")
       (cavemacs-rpc-reply-ui conn req :confirmed t))
      (_           (cavemacs-rpc-reply-ui conn req :confirmed :json-false)))))

(defun cavemacs-tools--select (conn req)
  "Handle a `select' request via `completing-read'."
  (let* ((title (or (alist-get 'title req) "Select"))
         (options (or (alist-get 'options req) '()))
         (choice (condition-case nil
                     (completing-read (format "%s: " title) options nil t)
                   (quit nil))))
    (if choice
        (cavemacs-rpc-reply-ui conn req :value choice)
      (cavemacs-rpc-reply-ui conn req :cancelled t))))

(defun cavemacs-tools--input (conn req)
  "Handle an `input' request via `read-string'."
  (let* ((title (or (alist-get 'title req) "Input"))
         (placeholder (alist-get 'placeholder req))
         (prompt (if placeholder
                     (format "%s (%s): " title placeholder)
                   (format "%s: " title)))
         (value (condition-case nil (read-string prompt) (quit nil))))
    (if (and value (not (string-empty-p value)))
        (cavemacs-rpc-reply-ui conn req :value value)
      (cavemacs-rpc-reply-ui conn req :cancelled t))))

(defun cavemacs-tools--editor (conn req)
  "Handle an `editor' request via a temporary edit buffer."
  (let* ((title (or (alist-get 'title req) "Edit"))
         (prefill (or (alist-get 'prefill req) ""))
         (buf (generate-new-buffer (format " *cavemacs-edit: %s*" title))))
    (with-current-buffer buf
      (insert prefill)
      (text-mode)
      (setq-local header-line-format
                  (format "%s — C-c C-c submit, C-c C-k cancel" title))
      (let ((map (copy-keymap text-mode-map)))
        (define-key map (kbd "C-c C-c")
                    (lambda ()
                      (interactive)
                      (let ((value (buffer-substring-no-properties
                                    (point-min) (point-max))))
                        (kill-buffer buf)
                        (cavemacs-rpc-reply-ui conn req :value value))))
        (define-key map (kbd "C-c C-k")
                    (lambda ()
                      (interactive)
                      (kill-buffer buf)
                      (cavemacs-rpc-reply-ui conn req :cancelled t)))
        (use-local-map map)))
    (pop-to-buffer buf)))

(defun cavemacs-tools--notify (req)
  "Surface a `notify' request via `message' (and the buffer log)."
  (let* ((msg (alist-get 'message req))
         (kind (or (alist-get 'notifyType req) "info"))
         (face (pcase kind
                 ("warning" 'warning)
                 ("error"   'error)
                 (_         'shadow))))
    (message "cavemacs[%s]: %s" kind msg)
    (when (and (boundp 'cavemacs-shell--prompt-marker)
               cavemacs-shell--prompt-marker)
      (cavemacs-render--notice (format "● %s" msg) face))))

(defun cavemacs-tools--set-status (req)
  "Reflect a `setStatus' request in the modeline."
  (when (and (boundp 'cavemacs-shell--mode-line-info))
    (let ((text (alist-get 'statusText req)))
      (cavemacs-shell--set-mode-info (or text "idle")))))

(defun cavemacs-tools--set-editor-text (req)
  "Replace the input area with REQ's text (used by some extensions)."
  (when (and (boundp 'cavemacs-shell--input-start-marker)
             cavemacs-shell--input-start-marker)
    (let ((inhibit-read-only t)
          (text (or (alist-get 'text req) "")))
      (delete-region (marker-position cavemacs-shell--input-start-marker)
                     (point-max))
      (goto-char (point-max))
      (insert text))))

(provide 'cavemacs-tools)
;;; cavemacs-tools.el ends here
