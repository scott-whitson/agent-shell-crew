;;; checkdoc.el --- Fail on any checkdoc message -*- lexical-binding: t; -*-
;;; Commentary:
;; Usage: emacs -Q --batch -l test/checkdoc.el FILE...
;; Every message checkdoc would report is collected through
;; `checkdoc-create-error-function' and printed; any at all fails the run.
;;; Code:
(require 'checkdoc)
(let ((failed nil))
  (dolist (file command-line-args-left)
    (let* ((found nil)
           (checkdoc-create-error-function
            (lambda (text start _end &optional _unfixable)
              (push (format "%s:%d: %s" file
                            (with-current-buffer (find-file-noselect file)
                              (line-number-at-pos start))
                            text)
                    found)
              nil)))
      (checkdoc-file file)
      (when found
        (setq failed t)
        (dolist (line (nreverse found)) (princ (concat line "\n"))))))
  (setq command-line-args-left nil)
  (kill-emacs (if failed 1 0)))
;;; checkdoc.el ends here
