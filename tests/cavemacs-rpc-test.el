;;; cavemacs-rpc-test.el --- Unit tests for cavemacs-rpc (no LLM)  -*- lexical-binding: t; -*-
;;; Commentary:
;; Pure-Elisp unit tests for the JSONL framing + dispatch logic in
;; cavemacs-rpc.el.  Run:
;;
;;   emacs --batch -L . -l tests/cavemacs-rpc-test.el \
;;         -f ert-run-tests-batch-and-exit
;;; Code:

(require 'ert)
(require 'cavemacs-rpc)

;; --- JSON encode round-trip ---

(ert-deftest cavemacs-rpc/encode-roundtrip ()
  (let* ((obj '((id . "x") (type . "prompt") (message . "hi")))
         (encoded (cavemacs-rpc--encode obj))
         (parsed (cavemacs-rpc--parse-line
                  (substring encoded 0 -1))))
    (should (string-suffix-p "\n" encoded))
    (should (equal (alist-get 'id parsed) "x"))
    (should (equal (alist-get 'type parsed) "prompt"))
    (should (equal (alist-get 'message parsed) "hi"))))

;; --- plist->alist helper ---

(ert-deftest cavemacs-rpc/plist-to-alist ()
  (should (equal (cavemacs-rpc--plist-to-alist '(:foo "x" :bar 1))
                 '((foo . "x") (bar . 1))))
  (should (equal (cavemacs-rpc--plist-to-alist nil) nil)))

;; --- JSONL framing: simulate filter with split chunks ---
;; We bypass real process creation by hand-rolling a fake conn and
;; driving its read-buffer manually through the filter.

(defun cavemacs-rpc-test--fake-conn ()
  (let* ((conn (cavemacs-rpc-conn--make
                :process nil
                :stderr-buffer nil
                :event-hooks nil
                :ui-handlers nil)))
    conn))

(defun cavemacs-rpc-test--feed (conn chunks)
  "Feed CHUNKS (a list of strings) through CONN's filter logic.

We can't use the real process filter without a process, so we
inline its body: appending to read-buffer and slicing on LF."
  (dolist (chunk chunks)
    (setf (cavemacs-rpc-conn-read-buffer conn)
          (concat (cavemacs-rpc-conn-read-buffer conn) chunk))
    (let ((buf (cavemacs-rpc-conn-read-buffer conn))
          (start 0)
          (idx nil))
      (setq idx (string-search "\n" buf start))
      (while idx
        (let ((line (substring buf start idx)))
          (when (and (> (length line) 0)
                     (eq (aref line (1- (length line))) ?\r))
            (setq line (substring line 0 -1)))
          (when (> (length line) 0)
            (cavemacs-rpc--dispatch
             conn (cavemacs-rpc--parse-line line))))
        (setq start (1+ idx)
              idx (string-search "\n" buf start)))
      (setf (cavemacs-rpc-conn-read-buffer conn)
            (substring buf start)))))

(ert-deftest cavemacs-rpc/framing-single-line ()
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (events nil))
    (cavemacs-rpc-add-event-hook
     conn (lambda (e) (push e events)))
    (cavemacs-rpc-test--feed conn '("{\"type\":\"agent_start\"}\n"))
    (should (= 1 (length events)))
    (should (equal (alist-get 'type (car events)) "agent_start"))))

(ert-deftest cavemacs-rpc/framing-split-across-chunks ()
  "A single JSON object split across many TCP-like chunks must reassemble."
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (events nil))
    (cavemacs-rpc-add-event-hook
     conn (lambda (e) (push e events)))
    (cavemacs-rpc-test--feed
     conn
     (list "{\"type\""
           ":\"turn_"
           "start\"}"
           "\n"))
    (should (= 1 (length events)))
    (should (equal (alist-get 'type (car events)) "turn_start"))))

(ert-deftest cavemacs-rpc/framing-multiple-per-chunk ()
  "A single chunk containing multiple LF-delimited JSON objects yields each."
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (events nil))
    (cavemacs-rpc-add-event-hook
     conn (lambda (e) (push e events)))
    (cavemacs-rpc-test--feed
     conn '("{\"type\":\"agent_start\"}\n{\"type\":\"turn_start\"}\n"))
    (should (= 2 (length events)))
    (should (equal (mapcar (lambda (e) (alist-get 'type e))
                           (nreverse events))
                   '("agent_start" "turn_start")))))

(ert-deftest cavemacs-rpc/framing-trailing-cr-tolerated ()
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (events nil))
    (cavemacs-rpc-add-event-hook
     conn (lambda (e) (push e events)))
    (cavemacs-rpc-test--feed conn '("{\"type\":\"agent_end\"}\r\n"))
    (should (= 1 (length events)))
    (should (equal (alist-get 'type (car events)) "agent_end"))))

(ert-deftest cavemacs-rpc/response-correlation ()
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (resolved nil))
    (puthash "cm-42" (lambda (r) (setq resolved r))
             (cavemacs-rpc-conn-pending conn))
    (cavemacs-rpc-test--feed
     conn
     '("{\"id\":\"cm-42\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"abc\"}}\n"))
    (should resolved)
    (should (equal (alist-get 'command resolved) "get_state"))
    (should (eq (alist-get 'success resolved) t))
    (should (equal (alist-get 'sessionId (alist-get 'data resolved)) "abc"))
    ;; Pending entry should be removed after firing.
    (should (= 0 (hash-table-count (cavemacs-rpc-conn-pending conn))))))

(ert-deftest cavemacs-rpc/response-does-not-trigger-event-hook ()
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (events nil))
    (cavemacs-rpc-add-event-hook
     conn (lambda (e) (push e events)))
    (cavemacs-rpc-test--feed
     conn '("{\"id\":\"x\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n"))
    (should (null events))))

(ert-deftest cavemacs-rpc/ui-handler-claim-flow ()
  "A UI handler returning non-nil claims the request; otherwise auto-cancel."
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (claimed nil)
         (sent nil))
    ;; Stub write-raw to capture replies.
    (cl-letf (((symbol-function 'cavemacs-rpc--write-raw)
               (lambda (_c obj) (push obj sent))))
      ;; Case 1: handler claims -> no auto-reply.
      (cavemacs-rpc-add-ui-handler
       conn (lambda (req) (setq claimed req) t))
      (cavemacs-rpc-test--feed
       conn '("{\"type\":\"extension_ui_request\",\"id\":\"u1\",\"method\":\"confirm\",\"title\":\"OK?\",\"message\":\"yes\"}\n"))
      (should claimed)
      (should (null sent))
      ;; Case 2: replace with a non-claiming handler -> auto-cancel reply sent.
      (setf (cavemacs-rpc-conn-ui-handlers conn) nil)
      (cavemacs-rpc-add-ui-handler conn (lambda (_req) nil))
      (cavemacs-rpc-test--feed
       conn '("{\"type\":\"extension_ui_request\",\"id\":\"u2\",\"method\":\"confirm\"}\n"))
      (should (equal 1 (length sent)))
      (should (equal (alist-get 'type (car sent)) "extension_ui_response"))
      (should (equal (alist-get 'id   (car sent)) "u2"))
      (should (eq (alist-get 'cancelled (car sent)) t)))))

(ert-deftest cavemacs-rpc/ui-fire-and-forget-no-reply ()
  "notify / setStatus etc. must NOT trigger an auto-cancel reply."
  (let* ((conn (cavemacs-rpc-test--fake-conn))
         (sent nil))
    (cl-letf (((symbol-function 'cavemacs-rpc--write-raw)
               (lambda (_c obj) (push obj sent))))
      (cavemacs-rpc-test--feed
       conn '("{\"type\":\"extension_ui_request\",\"id\":\"n1\",\"method\":\"notify\",\"message\":\"hi\"}\n"))
      (should (null sent)))))

(provide 'cavemacs-rpc-test)
;;; cavemacs-rpc-test.el ends here
