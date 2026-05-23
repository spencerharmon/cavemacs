;;; cavemacs-cavemem.el --- cavemem integration helpers  -*- lexical-binding: t; -*-
;;; Commentary:
;;
;; Cavemem (https://github.com/JuliusBrussee/cavemem) is the persistent
;; memory backend for caveman.  cavemacs treats it as an external tool
;; and provides:
;;
;;   `cavemacs-cavemem-search'  -- in-session /memory search
;;   `cavemacs-cavemem-save'    -- in-session /memory save
;;   `cavemacs-cavemem-viewer'  -- launch the local memory viewer
;;   `cavemacs-cavemem-status'  -- shell out to cavemem status
;;
;;; Code:

(require 'cavemacs-shell)
(require 'cavemacs-commands)

(defcustom cavemacs-cavemem-binary "cavemem"
  "Path to the cavemem CLI."
  :type 'string
  :group 'cavemacs)

(defcustom cavemacs-cavemem-viewer-url "http://127.0.0.1:37777"
  "URL of the cavemem viewer."
  :type 'string
  :group 'cavemacs)

(defun cavemacs-cavemem-search (query)
  "Send `/memory search QUERY' to the active cavemacs session."
  (interactive "sMemory search: ")
  (cavemacs-commands-run (format "/memory search %s" query)))

(defun cavemacs-cavemem-save (text)
  "Send `/memory save TEXT' to the active cavemacs session."
  (interactive "sSave to memory: ")
  (cavemacs-commands-run (format "/memory save %s" text)))

(defun cavemacs-cavemem-viewer ()
  "Open the local cavemem viewer in a browser.
If cavemem is installed, attempts to start the worker first."
  (interactive)
  (when (executable-find cavemacs-cavemem-binary)
    (ignore-errors
      (call-process cavemacs-cavemem-binary nil nil nil "start")))
  (browse-url cavemacs-cavemem-viewer-url))

(defun cavemacs-cavemem-status ()
  "Display `cavemem status' output in a help buffer."
  (interactive)
  (unless (executable-find cavemacs-cavemem-binary)
    (user-error "cavemem binary not found"))
  (with-help-window "*cavemem-status*"
    (call-process cavemacs-cavemem-binary nil standard-output nil "status")))

(provide 'cavemacs-cavemem)
;;; cavemacs-cavemem.el ends here
