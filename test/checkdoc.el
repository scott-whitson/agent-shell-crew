;;; checkdoc.el --- Fail on any checkdoc message -*- lexical-binding: t; -*-
;;; Commentary:
;; Usage: emacs -Q --batch -l test/checkdoc.el FILE...
;;; Code:
(require 'checkdoc)
(let ((failed nil))
  (dolist (file command-line-args-left)
    (let ((checkdoc-diagnostic-buffer "*checkdoc*"))
      (with-current-buffer (get-buffer-create "*checkdoc*") (erase-buffer))
      (checkdoc-file file)
      (with-current-buffer "*checkdoc*"
        (goto-char (point-min))
        (when (re-search-forward "^[^ \n].*:[0-9]+:" nil t)
          (setq failed t)
          (princ (buffer-string))))))
  (setq command-line-args-left nil)
  (kill-emacs (if failed 1 0)))
;;; checkdoc.el ends here
