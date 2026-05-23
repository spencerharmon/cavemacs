;;; cavemacs-session-test.el --- Tests for cavemacs-session  -*- lexical-binding: t; -*-
;;; Commentary:
;; Unit tests for the session enumerator / browser metadata parser.
;;; Code:

(require 'ert)
(require 'cavemacs-session)

(defun cavemacs-session-test--write-jsonl (path lines)
  "Write LINES (list of alists) to PATH as JSONL."
  (with-temp-buffer
    (dolist (line lines)
      (insert (json-encode line) "\n"))
    (write-region (point-min) (point-max) path nil 'silent)))

(defmacro cavemacs-session-test--with-temp-session (var lines &rest body)
  "Bind VAR to a temp jsonl file path containing LINES; execute BODY."
  (declare (indent 2))
  `(let ((,var (make-temp-file "cavemacs-session-test-" nil ".jsonl")))
     (unwind-protect
         (progn
           (cavemacs-session-test--write-jsonl ,var ,lines)
           ,@body)
       (when (file-exists-p ,var) (delete-file ,var)))))

(ert-deftest cavemacs-session/meta-parses-session-envelope ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session")
         (id . "sess-1")
         (cwd . "/home/user/proj")
         (timestamp . "2026-05-23T18:00:00Z")
         (version . "1")))
    (let ((m (cavemacs-session--meta path)))
      (should (equal "sess-1" (plist-get m :sessionId)))
      (should (equal "/home/user/proj" (plist-get m :cwd))))))

(ert-deftest cavemacs-session/meta-tracks-model-from-model-change ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session") (id . "s") (cwd . "/x"))
        ((type . "model_change")
         (modelId . "gpt-5")
         (provider . "openai"))
        ((type . "model_change")
         (modelId . "claude-opus-4.7")
         (provider . "github-copilot")))
    (let ((m (cavemacs-session--meta path)))
      ;; Latest model_change wins.
      (should (equal "claude-opus-4.7" (plist-get m :model)))
      (should (equal "github-copilot" (plist-get m :provider))))))

(ert-deftest cavemacs-session/meta-tracks-model-from-assistant-message ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session") (id . "s") (cwd . "/x"))
        ((type . "message")
         (message . ((role . "assistant")
                     (model . "haiku-4.5")
                     (provider . "github-copilot")
                     (content . "hi")))))
    (let ((m (cavemacs-session--meta path)))
      (should (equal "haiku-4.5" (plist-get m :model)))
      (should (equal "github-copilot" (plist-get m :provider))))))

(ert-deftest cavemacs-session/meta-counts-user-turns ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session") (id . "s") (cwd . "/x"))
        ((type . "message")
         (message . ((role . "user") (content . "first"))))
        ((type . "message")
         (message . ((role . "assistant") (content . "ack"))))
        ((type . "message")
         (message . ((role . "user") (content . "second")))))
    (let ((m (cavemacs-session--meta path)))
      (should (equal 2 (plist-get m :turns))))))

(ert-deftest cavemacs-session/meta-name-from-session-name-change ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session") (id . "s") (cwd . "/x"))
        ((type . "session_name_change") (name . "my session"))
        ((type . "message")
         (message . ((role . "user") (content . "first prompt text")))))
    (let ((m (cavemacs-session--meta path)))
      ;; Explicit name beats the first-user-text fallback.
      (should (equal "my session" (plist-get m :name))))))

(ert-deftest cavemacs-session/meta-name-falls-back-to-first-user-prompt ()
  (cavemacs-session-test--with-temp-session path
      '(((type . "session") (id . "s") (cwd . "/x"))
        ((type . "message")
         (message . ((role . "user")
                     (content . "implement the M11 plan please")))))
    (let ((m (cavemacs-session--meta path)))
      (should (string-match-p "implement the M11"
                              (plist-get m :name))))))

(ert-deftest cavemacs-session/meta-name-truncates-long-fallback ()
  (let ((long (make-string 200 ?x)))
    (cavemacs-session-test--with-temp-session path
        `(((type . "session") (id . "s") (cwd . "/x"))
          ((type . "message")
           (message . ((role . "user") (content . ,long)))))
      (let ((m (cavemacs-session--meta path)))
        (should (<= (length (plist-get m :name)) 60))))))

(ert-deftest cavemacs-session/cwd-match-p ()
  (let ((meta '(:cwd "/home/user/proj")))
    (should (cavemacs-session--cwd-match-p meta "/home/user/proj/"))
    (should-not (cavemacs-session--cwd-match-p meta "/home/user/other/"))))

;; -----------------------------------------------------------------------------
;; Browser keymap regression: define-derived-mode autogenerates the map; if we
;; defvar a new one afterwards, define-keys land in the wrong place and RET
;; does nothing.
;; -----------------------------------------------------------------------------

(ert-deftest cavemacs-session/browser-mode-map-has-ret ()
  "RET in the browser must be bound to resume the session at point."
  (should (eq #'cavemacs-session-browser-resume
              (lookup-key cavemacs-session-browser-mode-map (kbd "RET")))))

(ert-deftest cavemacs-session/projects-mode-map-has-ret ()
  "RET in the projects browser must drill into a project."
  (should (eq #'cavemacs-projects-open-at-point
              (lookup-key cavemacs-projects-mode-map (kbd "RET")))))

(provide 'cavemacs-session-test)
;;; cavemacs-session-test.el ends here
