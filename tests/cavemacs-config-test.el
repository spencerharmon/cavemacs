;;; cavemacs-config-test.el --- Tests for cavemacs-config  -*- lexical-binding: t; -*-
;;; Commentary:
;; CLI argument-list construction tests for `cavemacs--default-process-args'.
;;; Code:

(require 'ert)
(require 'cavemacs-config)

(ert-deftest cavemacs-config/default-includes-rpc-mode ()
  (let (cavemacs-system-prompt
        cavemacs-append-system-prompt
        cavemacs-extra-args)
    (let ((args (cavemacs--default-process-args)))
      (should (equal '("--mode" "rpc") (seq-take args 2))))))

(ert-deftest cavemacs-config/append-system-prompt-default-microprompt ()
  ;; Default value should be wired into the CLI as
  ;; --append-system-prompt <text>.
  (let (cavemacs-system-prompt
        cavemacs-extra-args)
    (let* ((args (cavemacs--default-process-args))
           (idx  (cl-position "--append-system-prompt" args :test #'equal)))
      (should idx)
      (should (stringp (nth (1+ idx) args)))
      (should (string-match-p "Respond like smart caveman"
                              (nth (1+ idx) args))))))

(ert-deftest cavemacs-config/append-system-prompt-nil-suppresses-flag ()
  (let ((cavemacs-append-system-prompt nil)
        cavemacs-system-prompt
        cavemacs-extra-args)
    (let ((args (cavemacs--default-process-args)))
      (should-not (member "--append-system-prompt" args)))))

(ert-deftest cavemacs-config/append-system-prompt-empty-suppresses-flag ()
  (let ((cavemacs-append-system-prompt "")
        cavemacs-system-prompt
        cavemacs-extra-args)
    (let ((args (cavemacs--default-process-args)))
      (should-not (member "--append-system-prompt" args)))))

(ert-deftest cavemacs-config/system-prompt-override ()
  (let ((cavemacs-system-prompt "you are a teapot")
        cavemacs-append-system-prompt
        cavemacs-extra-args)
    (let* ((args (cavemacs--default-process-args))
           (idx  (cl-position "--system-prompt" args :test #'equal)))
      (should idx)
      (should (equal "you are a teapot" (nth (1+ idx) args))))))

(ert-deftest cavemacs-config/extra-args-trail ()
  (let ((cavemacs-extra-args '("--foo" "bar"))
        cavemacs-system-prompt
        cavemacs-append-system-prompt)
    (let ((args (cavemacs--default-process-args)))
      (should (equal '("--foo" "bar") (last args 2))))))

(provide 'cavemacs-config-test)
;;; cavemacs-config-test.el ends here
