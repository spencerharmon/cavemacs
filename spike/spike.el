;;; spike.el --- M0 RPC spike for cavemacs -*- lexical-binding: t; -*-
;;
;; Validates the caveman --mode rpc transport from raw Elisp without any UI.
;; Run with:
;;   emacs --batch -l spike/spike.el -f cavemacs-spike-run
;;
;; What it does:
;;   1. Spawns `caveman --mode rpc --no-session` as a subprocess.
;;   2. Implements strict LF-delimited JSONL framing with partial-read buffering.
;;   3. Sends a `get_state` command with an id and waits for the matching response.
;;   4. Sends a `get_commands` command and prints the result.
;;   5. Sends `abort` (no-op when idle) to confirm a fire-and-forget command works.
;;   6. Closes stdin to trigger graceful shutdown; reports exit status.
;;
;; What it does NOT do:
;;   - Send a `prompt` (would require provider auth + tokens).
;;   - Render any output (no Emacs UI here; just *Messages*).
;;
;; Goal: prove the framing + envelope + correlation work end-to-end before
;; writing cavemacs-rpc.el for real.

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar cavemacs-spike--proc nil)
(defvar cavemacs-spike--buffer "")
(defvar cavemacs-spike--pending (make-hash-table :test 'equal))
(defvar cavemacs-spike--event-count 0)
(defvar cavemacs-spike--log nil) ; reverse list of (tag . payload)

(defun cavemacs-spike--log (tag obj)
  (push (cons tag obj) cavemacs-spike--log)
  (message "[spike:%s] %s" tag
           (let ((print-length 8) (print-level 4))
             (prin1-to-string obj))))

(defun cavemacs-spike--write (obj)
  "Serialize OBJ as one JSONL line and send to caveman."
  (let* ((json-encoding-pretty-print nil)
         (line (concat (json-encode obj) "\n")))
    (cavemacs-spike--log 'send obj)
    (process-send-string cavemacs-spike--proc line)))

(defun cavemacs-spike--dispatch (obj)
  "Route a single parsed JSONL OBJ to a pending response or as an event."
  (let ((type (cdr (assq 'type obj))))
    (cond
     ;; Response to a command we sent.
     ((equal type "response")
      (let* ((id (cdr (assq 'id obj)))
             (cb (and id (gethash id cavemacs-spike--pending))))
        (cavemacs-spike--log 'response obj)
        (when cb
          (remhash id cavemacs-spike--pending)
          (funcall cb obj))))
     ;; Extension UI request: log + send a "cancelled" reply so we don't hang.
     ((equal type "extension_ui_request")
      (cavemacs-spike--log 'ext-ui-req obj)
      (let ((id (cdr (assq 'id obj))))
        (cavemacs-spike--write
         `((type . "extension_ui_response") (id . ,id) (cancelled . t)))))
     ;; Anything else is a streamed AgentSessionEvent.
     (t
      (cl-incf cavemacs-spike--event-count)
      (cavemacs-spike--log 'event obj)))))

(defun cavemacs-spike--on-output (_proc chunk)
  "Process stdout CHUNK: split on \\n only (strict JSONL per caveman spec)."
  (setq cavemacs-spike--buffer (concat cavemacs-spike--buffer chunk))
  (let (lines)
    (while (string-match "\n" cavemacs-spike--buffer)
      (push (substring cavemacs-spike--buffer 0 (match-beginning 0)) lines)
      (setq cavemacs-spike--buffer
            (substring cavemacs-spike--buffer (match-end 0))))
    (dolist (line (nreverse lines))
      (when (> (length line) 0)
        (condition-case err
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (json-key-type 'symbol)
                   (json-false :json-false)
                   (json-null nil)
                   (obj (json-read-from-string line)))
              (cavemacs-spike--dispatch obj))
          (error
           (cavemacs-spike--log 'parse-error
                                (list :error (error-message-string err)
                                      :line line))))))))

(defun cavemacs-spike--on-stderr (_proc chunk)
  (cavemacs-spike--log 'stderr (string-trim-right chunk)))

(defun cavemacs-spike--make-id ()
  (format "req-%s" (random 1000000)))

(defun cavemacs-spike--request (type &rest extra)
  "Send a command of TYPE with EXTRA fields; return id."
  (let* ((id (cavemacs-spike--make-id))
         (cmd (append `((id . ,id) (type . ,type)) extra)))
    (puthash id (lambda (resp)
                  (cavemacs-spike--log 'resolved
                                       (list :id id :success
                                             (cdr (assq 'success resp)))))
             cavemacs-spike--pending)
    (cavemacs-spike--write cmd)
    id))

(defun cavemacs-spike--await (predicate &optional timeout-secs)
  "Block until PREDICATE returns non-nil or timeout."
  (let ((deadline (+ (float-time) (or timeout-secs 10))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output cavemacs-spike--proc 0.1))
    (funcall predicate)))

(defun cavemacs-spike-run ()
  "Run the spike."
  (interactive)
  ;; Locate caveman via the nvm shim.
  (let ((caveman (or (executable-find "caveman")
                     (expand-file-name "~/.nvm/versions/node/v22.22.3/bin/caveman"))))
    (unless (file-executable-p caveman)
      (error "caveman binary not found at %s" caveman))
    (message "Using caveman: %s" caveman)

    (setq cavemacs-spike--buffer ""
          cavemacs-spike--pending (make-hash-table :test 'equal)
          cavemacs-spike--event-count 0
          cavemacs-spike--log nil)

    ;; --no-session: ephemeral; --no-extension: skip user extensions for a clean test.
    (setq cavemacs-spike--proc
          (make-process
           :name "cavemacs-spike"
           :command (list caveman "--mode" "rpc" "--no-session")
           :coding 'utf-8
           :connection-type 'pipe
           :noquery t
           :filter #'cavemacs-spike--on-output
           :stderr (make-pipe-process
                    :name "cavemacs-spike-stderr"
                    :buffer " *cavemacs-spike-stderr*"
                    :noquery t
                    :filter #'cavemacs-spike--on-stderr)))

    ;; Give caveman a moment to boot. It emits some initial events (agent_start,
    ;; message_start for system prompts, etc.) — we just want to capture them.
    (cavemacs-spike--await
     (lambda () (not (process-live-p cavemacs-spike--proc))) 1.0)

    (when (process-live-p cavemacs-spike--proc)
      (message "--- caveman is up, sending get_state ---")
      (let ((state-id (cavemacs-spike--request "get_state")))
        (cavemacs-spike--await
         (lambda () (not (gethash state-id cavemacs-spike--pending))) 10))

      (message "--- sending get_commands ---")
      (let ((cmds-id (cavemacs-spike--request "get_commands")))
        (cavemacs-spike--await
         (lambda () (not (gethash cmds-id cavemacs-spike--pending))) 10))

      (message "--- sending abort (no-op when idle) ---")
      (let ((abort-id (cavemacs-spike--request "abort")))
        (cavemacs-spike--await
         (lambda () (not (gethash abort-id cavemacs-spike--pending))) 5))

      (message "--- closing stdin to shut down cleanly ---")
      (process-send-eof cavemacs-spike--proc)
      (cavemacs-spike--await
       (lambda () (not (process-live-p cavemacs-spike--proc))) 5))

    (message "===== SPIKE SUMMARY =====")
    (message "Process exit status: %s" (process-status cavemacs-spike--proc))
    (message "Process exit code:   %s" (process-exit-status cavemacs-spike--proc))
    (message "Events received:     %d" cavemacs-spike--event-count)
    (message "Pending requests left: %d" (hash-table-count cavemacs-spike--pending))
    (message "Total log entries:   %d" (length cavemacs-spike--log))
    ;; Print a tag tally.
    (let ((tally (make-hash-table :test 'equal)))
      (dolist (entry cavemacs-spike--log)
        (puthash (car entry) (1+ (gethash (car entry) tally 0)) tally))
      (maphash (lambda (k v) (message "  %-12s %d" k v)) tally))))

;;; spike.el ends here
