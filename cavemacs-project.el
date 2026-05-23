;;; cavemacs-project.el --- Project root + per-repo paths  -*- lexical-binding: t; -*-
;;; Commentary:
;; Project root detection (project.el / projectile / git toplevel / default-directory)
;; and per-repository paths for sessions.
;;; Code:

(require 'project)
(require 'subr-x)

(defun cavemacs-project-root ()
  "Return the absolute, slash-terminated root directory for the current project."
  (file-name-as-directory
   (expand-file-name
    (or (and (fboundp 'projectile-project-root)
             (bound-and-true-p projectile-mode)
             (ignore-errors (projectile-project-root)))
        (when-let* ((proj (project-current nil)))
          (project-root proj))
        (cavemacs-project--git-toplevel default-directory)
        default-directory))))

(defun cavemacs-project--git-toplevel (dir)
  "Return DIR's git toplevel, or nil if not in a git checkout."
  (let ((default-directory (file-name-as-directory (expand-file-name dir))))
    (let* ((output (with-output-to-string
                     (with-current-buffer standard-output
                       (call-process "git" nil t nil
                                     "rev-parse" "--show-toplevel"))))
           (line (string-trim output)))
      (when (and (not (string-empty-p line))
                 (file-directory-p line))
        (file-name-as-directory line)))))

(defun cavemacs-project-name (&optional root)
  "Return a short display name for ROOT (defaults to current project)."
  (let ((root (or root (cavemacs-project-root))))
    (or (and (fboundp 'project-name)
             (when-let* ((proj (project-current nil))
                         ((equal (file-name-as-directory
                                  (expand-file-name (project-root proj)))
                                 root)))
               (project-name proj)))
        (file-name-nondirectory (directory-file-name root)))))

(provide 'cavemacs-project)
;;; cavemacs-project.el ends here
