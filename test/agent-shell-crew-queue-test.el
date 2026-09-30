;;; agent-shell-crew-queue-test.el --- Queue tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Hermetic: every test gets its own queue directory and project root.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew-queue)

(defmacro crew-test--with-project (root &rest body)
  "Bind ROOT to a fresh project directory and run BODY with a fresh queue directory."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-q" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-crew-changed-hook nil))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p agent-shell-crew-directory (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(ert-deftest crew-queue-create-then-get ()
  (crew-test--with-project root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "Do the thing"
                                              :brief "Details here." :owner "owner@x"
                                              :evidence "notes/a.md" :ref "T-1"))
           (item (agent-shell-crew-queue-get root id)))
      (should (string-match-p "\\`c-[0-9]\\{4\\}-[0-9]\\{6\\}-[0-9a-f]\\{4\\}\\'" id))
      (should (equal (plist-get item :title) "Do the thing"))
      (should (equal (plist-get item :state) "PENDING"))
      (should (equal (plist-get item :owner) "owner@x"))
      (should (equal (plist-get item :from) "human"))
      (should (equal (plist-get item :evidence) "notes/a.md"))
      (should (equal (plist-get item :ref) "T-1"))
      (should (equal (plist-get item :brief) "Details here."))
      (should (= (length (plist-get item :log)) 1))
      (should (string-match-p "created by human for owner@x" (car (plist-get item :log)))))))

(ert-deftest crew-queue-file-header ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x")
    (let ((text (with-temp-buffer (insert-file-contents (agent-shell-crew-queue-file root))
                                  (buffer-string))))
      (should (string-match-p "^#\\+TODO: PENDING ACTIVE PARKED | DONE HANDED CANCELED$" text))
      (should (string-match-p (concat "^#\\+CREW_ROOT: " (regexp-quote root) "$") text))
      (should (string-match-p "^\\* PENDING T +:crew:$" text)))))

(ert-deftest crew-queue-list-and-filter ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "owner@x")
    (agent-shell-crew-queue-create root "human" :title "B" :owner "check@x")
    (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list root))
                   '("A" "B")))
    (should (equal (mapcar (lambda (i) (plist-get i :title))
                           (agent-shell-crew-queue-list root "check@x"))
                   '("B")))))

(ert-deftest crew-queue-requires-title-and-owner ()
  (crew-test--with-project root
    (should-error (agent-shell-crew-queue-create root "human" :title " " :owner "o@x")
                  :type 'agent-shell-crew-error)
    (should-error (agent-shell-crew-queue-create root "human" :title "T" :owner "")
                  :type 'agent-shell-crew-error)))

(ert-deftest crew-queue-unknown-id ()
  (crew-test--with-project root
    (should-error (agent-shell-crew-queue-get root "c-0000-000000-0000")
                  :type 'agent-shell-crew-error)))

(ert-deftest crew-queue-ids-distinct ()
  (crew-test--with-project root
    (let ((ids (cl-loop repeat 50 collect
                        (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x"))))
      (should (= (length (delete-dups (copy-sequence ids))) 50)))))

(ert-deftest crew-queue-brief-stars-stay-inside ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x"
                                   :brief "first\n* not a heading\n** nor this")
    (should (= (length (agent-shell-crew-queue-list root)) 1))))

(ert-deftest crew-queue-title-newlines-collapse ()
  (crew-test--with-project root
    (let ((id (agent-shell-crew-queue-create root "human" :title "one\ntwo" :owner "o@x")))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :title) "one two")))))

(ert-deftest crew-queue-hook-runs ()
  (crew-test--with-project root
    (let* ((seen nil)
           (agent-shell-crew-changed-hook (list (lambda (r i v) (push (list r i v) seen))))
           (id (agent-shell-crew-queue-create root "human" :title "T" :owner "o@x")))
      (should (equal seen (list (list root id 'create)))))))

(ert-deftest crew-queue-keeps-external-edits ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "o@x")
    (let ((file (agent-shell-crew-queue-file root)))
      (write-region "\n* PENDING Added elsewhere :crew:\n:PROPERTIES:\n:CREW_ID: c-9999-999999-ffff\n:OWNER: o@x\n:END:\n** Log\n"
                    nil file t)
      (set-file-times file (time-add nil 5))
      (agent-shell-crew-queue-create root "human" :title "B" :owner "o@x")
      (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list root))
                     '("A" "Added elsewhere" "B"))))))

(ert-deftest crew-queue-refuses-unsaved-buffer ()
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "o@x")
    (with-current-buffer (find-file-noselect (agent-shell-crew-queue-file root))
      (goto-char (point-max))
      (insert "hand edit, not saved\n"))
    (should-error (agent-shell-crew-queue-create root "human" :title "B" :owner "o@x")
                  :type 'agent-shell-crew-error)))

(provide 'agent-shell-crew-queue-test)
;;; agent-shell-crew-queue-test.el ends here
