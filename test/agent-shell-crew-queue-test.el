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

(defun crew-test--new (root &optional owner)
  "Create a PENDING item in ROOT for OWNER (default owner@x) and return its id."
  (agent-shell-crew-queue-create root "human" :title "T" :owner (or owner "owner@x")))

(ert-deftest crew-queue-claim ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :state) "ACTIVE"))
      (should-error (agent-shell-crew-queue-claim root "owner@x" id) :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-only-owner-acts ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (should-error (agent-shell-crew-queue-claim root "check@x" id) :type 'agent-shell-crew-error)
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-park root "check@x" id "Q?") :type 'agent-shell-crew-error)
      (should-error (agent-shell-crew-queue-done root "check@x" id "r") :type 'agent-shell-crew-error)
      (should-error (agent-shell-crew-queue-handoff root "check@x" id "human" "s")
                    :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-note-appends ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-note root "owner@x" id "looked at it")
      (agent-shell-crew-queue-note root "human" id "fine by me")
      (let ((log (plist-get (agent-shell-crew-queue-get root id) :log)))
        (should (= (length log) 3))
        (should (string-match-p "note by owner@x: looked at it" (nth 1 log)))
        (should (string-match-p "note by human: fine by me" (nth 2 log)))))))

(ert-deftest crew-queue-park-and-decide ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-park root "owner@x" id "  ") :type 'agent-shell-crew-error)
      (agent-shell-crew-queue-park root "owner@x" id "Pick: (1) a; (2) b" "notes/q.md")
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "PARKED"))
        (should (equal (plist-get item :question) "Pick: (1) a; (2) b"))
        (should (equal (plist-get item :evidence) "notes/q.md")))
      (should (equal (agent-shell-crew-queue-decide root id "1 — a") "owner@x"))
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "ACTIVE"))
        (should (equal (plist-get item :decision) "1 — a"))
        (should (string-match-p "decided by human: 1 — a" (car (last (plist-get item :log))))))
      (should-error (agent-shell-crew-queue-decide root id "again") :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-done-and-canceled ()
  (crew-test--with-project root
    (let ((a (crew-test--new root)) (b (crew-test--new root)))
      (agent-shell-crew-queue-claim root "owner@x" a)
      (agent-shell-crew-queue-done root "owner@x" a "shipped")
      (agent-shell-crew-queue-done root "owner@x" b "not needed" t)
      (should (equal (plist-get (agent-shell-crew-queue-get root a) :state) "DONE"))
      (should (equal (plist-get (agent-shell-crew-queue-get root b) :state) "CANCELED"))
      (should-error (agent-shell-crew-queue-done root "owner@x" a "twice") :type 'agent-shell-crew-error))))

(ert-deftest crew-queue-handoff-links ()
  (crew-test--with-project root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "Build it" :owner "owner@x"
                                              :evidence "e.md" :ref "T-2")))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (should-error (agent-shell-crew-queue-handoff root "owner@x" id "owner@x" "self")
                    :type 'agent-shell-crew-error)
      (let* ((new (agent-shell-crew-queue-handoff root "owner@x" id "check@x" "built; please verify"
                                                  "Run the tests."))
             (old (agent-shell-crew-queue-get root id))
             (item (agent-shell-crew-queue-get root new)))
        (should (equal (plist-get old :state) "HANDED"))
        (should (string-match-p "handed to check@x: built; please verify"
                                (car (last (plist-get old :log)))))
        (should (equal (plist-get item :owner) "check@x"))
        (should (equal (plist-get item :from) "owner@x"))
        (should (equal (plist-get item :parent) id))
        (should (equal (plist-get item :title) "Build it"))
        (should (equal (plist-get item :evidence) "e.md"))
        (should (equal (plist-get item :ref) "T-2"))
        (should (string-match-p "built; please verify" (plist-get item :brief)))
        (should (string-match-p "Run the tests." (plist-get item :brief)))))))

(ert-deftest crew-queue-log-only-grows ()
  (crew-test--with-project root
    (let ((id (crew-test--new root)) (counts nil))
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-claim root "owner@x" id)
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-park root "owner@x" id "Q?")
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (agent-shell-crew-queue-decide root id "yes")
      (push (length (plist-get (agent-shell-crew-queue-get root id) :log)) counts)
      (should (equal (nreverse counts) '(1 2 3 4))))))

(ert-deftest crew-queue-parked-across-projects ()
  (crew-test--with-project root
    (let* ((other (let ((d (expand-file-name "other-app/" (make-temp-file "crew-root" t))))
                    (make-directory d t) d))
           (a (crew-test--new root)) (b (crew-test--new other)))
      (dolist (pair (list (cons root a) (cons other b)))
        (agent-shell-crew-queue-claim (car pair) "owner@x" (cdr pair))
        (agent-shell-crew-queue-park (car pair) "owner@x" (cdr pair) "Q?"))
      (let ((parked (agent-shell-crew-parked)))
        (should (= (length parked) 2))
        (should (member root (mapcar #'car parked)))
        (should (member other (mapcar #'car parked)))))))

;;; Final-review findings.

(ert-deftest crew-queue-multiline-evidence-is-cleaned ()
  "Finding 1: a newline in evidence or ref must not break the drawer."
  (crew-test--with-project root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x"
                                             :evidence "x.md\ny.md" :ref "A\nB")))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :evidence) "x.md y.md"))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (agent-shell-crew-queue-park root "owner@x" id "Q?" "one\ntwo")
      (should (= (length (agent-shell-crew-queue-list root)) 1))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :evidence) "one two")))))

(ert-deftest crew-queue-failed-write-rolls-back ()
  "Finding 1: an error inside a write leaves the queue usable."
  (crew-test--with-project root
    (agent-shell-crew-queue-create root "human" :title "A" :owner "owner@x")
    (should-error (agent-shell-crew--with-queue root
                    (goto-char (point-max))
                    (insert "* half-written\n")
                    (error "Boom")))
    (agent-shell-crew-queue-create root "human" :title "B" :owner "owner@x")
    (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list root))
                   '("A" "B")))))

(ert-deftest crew-queue-parked-ignores-lock-and-conflict-files ()
  "Finding 2: lock symlinks and sync-conflict copies are not queues."
  (crew-test--with-project root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x")))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (agent-shell-crew-queue-park root "owner@x" id "Q?")
      (let* ((file (agent-shell-crew-queue-file root))
             (dir (file-name-directory file))
             (base (file-name-nondirectory file)))
        (make-symbolic-link "nobody@host.1234:0" (expand-file-name (concat ".#" base) dir))
        (copy-file file (expand-file-name (concat (file-name-sans-extension base)
                                                  ".sync-conflict-20260930-ABCDEF.org")
                                          dir)))
      (should (= (length (agent-shell-crew-parked)) 1)))))

(ert-deftest crew-queue-parked-survives-unsaved-queue-buffer ()
  "Finding 2: a hand edit in one queue must not break reads of all queues."
  (crew-test--with-project root
    (let* ((other (let ((d (expand-file-name "other-app/" (make-temp-file "crew-root" t))))
                    (make-directory d t) d))
           (id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x")))
      (agent-shell-crew-queue-create other "human" :title "O" :owner "owner@x")
      (with-current-buffer (find-file-noselect (agent-shell-crew-queue-file other))
        (goto-char (point-max)) (insert "unsaved\n"))
      (agent-shell-crew-queue-claim root "owner@x" id)
      (agent-shell-crew-queue-park root "owner@x" id "Q?")
      (should (= (length (agent-shell-crew-parked)) 1)))))

(ert-deftest crew-queue-hook-error-does-not-fail-write ()
  "Finding 2: a failing changed-hook must not turn a saved write into an error."
  (crew-test--with-project root
    (let* ((agent-shell-crew-changed-hook (list (lambda (&rest _) (error "Hook broke"))))
           (id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@x")))
      (should (stringp id))
      (should (= (length (agent-shell-crew-queue-list root)) 1)))))

(ert-deftest crew-queue-same-folder-name-separate-queues ()
  "Finding 6: two projects named app must not share a queue."
  (let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-q" t)))
         (a (let ((d (expand-file-name "app/" (make-temp-file "crew-a" t)))) (make-directory d t) d))
         (b (let ((d (expand-file-name "app/" (make-temp-file "crew-b" t)))) (make-directory d t) d)))
    (unwind-protect
        (progn
          (agent-shell-crew-queue-create a "human" :title "in A" :owner "owner@app")
          (agent-shell-crew-queue-create b "human" :title "in B" :owner "owner@app")
          (should-not (equal (agent-shell-crew-queue-file a) (agent-shell-crew-queue-file b)))
          (should (equal (mapcar (lambda (i) (plist-get i :title)) (agent-shell-crew-queue-list a))
                         '("in A"))))
      (dolist (buf (buffer-list))
        (when (and (buffer-file-name buf)
                   (string-prefix-p agent-shell-crew-directory (buffer-file-name buf)))
          (kill-buffer buf))))))

(ert-deftest crew-queue-active-region-changes-one-item ()
  "Finding 7: an active region must not widen a state change."
  (crew-test--with-project root
    (let ((a (agent-shell-crew-queue-create root "human" :title "A" :owner "owner@x"))
          (b (agent-shell-crew-queue-create root "human" :title "B" :owner "owner@x")))
      (with-current-buffer (find-file-noselect (agent-shell-crew-queue-file root))
        (setq-local org-loop-over-headlines-in-active-region t)
        (transient-mark-mode 1)
        (push-mark (point-min) t t)
        (goto-char (point-max))
        (should (region-active-p))
        (agent-shell-crew-queue-claim root "owner@x" a))
      (should (equal (plist-get (agent-shell-crew-queue-get root b) :state) "PENDING")))))

(provide 'agent-shell-crew-queue-test)
;;; agent-shell-crew-queue-test.el ends here
