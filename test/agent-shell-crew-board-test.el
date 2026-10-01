;;; agent-shell-crew-board-test.el --- Crew board tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Hermetic: a fresh queue directory and project root per test; the merge
;; tests build a real git repository there.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew-board)

(defmacro crew-board-test--with (root &rest body)
  "Fresh queue dir and project ROOT for BODY."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-b" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-crew-profiles nil))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (or (string-prefix-p "*crew board: " (buffer-name b))
                   (and (buffer-file-name b)
                        (string-prefix-p agent-shell-crew-directory (buffer-file-name b))))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(defun crew-board-test--git (root &rest args)
  "Run git ARGS in ROOT, failing the test on error."
  (let ((default-directory root))
    (should (eql 0 (apply #'call-process "git" nil nil nil
                          "-c" "user.name=t" "-c" "user.email=t@t" args)))))

(defun crew-board-test--repo (root)
  "Make ROOT a repository on main with one commit."
  (crew-board-test--git root "init" "-q" "-b" "main")
  (crew-board-test--git root "commit" "-q" "--allow-empty" "-m" "start"))

;;; Status and branch on items

(ert-deftest crew-board-status-and-branch-are-recorded-and-carried ()
  (crew-board-test--with root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "Build" :owner "owner@my-app"
                                              :ref "37" :branch "crew/37"))
           (new (progn (agent-shell-crew-queue-claim root "owner@my-app" id)
                       (agent-shell-crew-queue-handoff root "owner@my-app" id "check@my-app" "built"
                                                       nil "Built; tests pass; needs a check."))))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :status)
                     "Built; tests pass; needs a check."))
      (let ((item (agent-shell-crew-queue-get root new)))
        (should (equal (plist-get item :ref) "37"))
        (should (equal (plist-get item :branch) "crew/37"))
        (should (equal (plist-get item :status) "Built; tests pass; needs a check.")))
      (agent-shell-crew-queue-claim root "check@my-app" new)
      (agent-shell-crew-queue-done root "check@my-app" new "checked" nil
                                   "Checked and merged; not deployed.")
      (should (equal (plist-get (agent-shell-crew-queue-get root new) :status)
                     "Checked and merged; not deployed.")))))

(ert-deftest crew-board-only-the-owner-or-human-rewrites-a-status ()
  (crew-board-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (should-error (agent-shell-crew-queue-set-status root "check@my-app" id "x")
                    :type 'agent-shell-crew-error)
      (agent-shell-crew-queue-set-status root "human" id "Abandoned: superseded by 41.")
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :status)
                     "Abandoned: superseded by 41.")))))

(ert-deftest crew-board-rpc-passes-status-and-branch ()
  (crew-board-test--with root
    (let* ((agent-shell-crew-rpc-members-function (lambda (_) '("human" "owner@my-app")))
           (agent-shell-crew-rpc-notify-function #'ignore)
           (id (alist-get 'id (agent-shell-crew--rpc-dispatch
                               "human" root "create"
                               '((title . "T") (owner . "owner@my-app")
                                 (status . "Not started.") (branch . "crew/t"))))))
      (should (equal (alist-get 'status (agent-shell-crew--item-json
                                         (agent-shell-crew-queue-get root id)))
                     "Not started."))
      (should (equal (alist-get 'branch (agent-shell-crew--item-json
                                         (agent-shell-crew-queue-get root id)))
                     "crew/t")))))

;;; Rows

(ert-deftest crew-board-one-row-per-ref-showing-the-latest-item ()
  (crew-board-test--with root
    (let* ((a (agent-shell-crew-queue-create root "human" :title "Order lines" :owner "owner@my-app"
                                             :ref "37"))
           (_b (agent-shell-crew-queue-create root "human" :title "Loose end" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" a)
      (agent-shell-crew-queue-handoff root "owner@my-app" a "check@my-app" "built" nil
                                      "Built; waiting on its check.")
      (let ((rows (agent-shell-crew-board--rows root)))
        (should (= (length rows) 2))
        (let ((row (seq-find (lambda (r) (equal (plist-get r :ref) "37")) rows)))
          (should (equal (plist-get row :state) "PENDING"))
          (should (equal (plist-get row :owner) "check@my-app"))
          (should (equal (plist-get row :status) "Built; waiting on its check.")))))))

(ert-deftest crew-board-without-a-status-shows-the-latest-event ()
  "The package writes no sentence of its own; it shows what last happened."
  (crew-board-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-done root "owner@my-app" id "gated in bundle 2200")
      (let ((row (car (agent-shell-crew-board--rows root))))
        (should-not (plist-get row :status))
        (should (equal (plist-get row :fallback) "gated in bundle 2200"))))))

(ert-deftest crew-board-a-fallback-is-one-sentence ()
  "Members write paragraphs; a row has room for one sentence."
  (crew-board-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-done root "owner@my-app" id
                                   "Merged and pushed, gate PASS 12492p. Branch deleted. Live check not reached.")
      (should (equal (plist-get (car (agent-shell-crew-board--rows root)) :fallback)
                     "Merged and pushed, gate PASS 12492p.")))))

;;; Merged

(ert-deftest crew-board-merged-yes-no-and-unknown ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (crew-board-test--git root "switch" "-q" "-c" "crew/done")
    (crew-board-test--git root "commit" "-q" "--allow-empty" "-m" "work")
    (crew-board-test--git root "switch" "-q" "-c" "crew/open")
    (crew-board-test--git root "commit" "-q" "--allow-empty" "-m" "more")
    (crew-board-test--git root "switch" "-q" "main")
    (crew-board-test--git root "merge" "-q" "--no-ff" "-m" "Merge branch 'crew/done'" "crew/done")
    (should (eq (agent-shell-crew-board--merged root "crew/done" "main") 'yes))
    (should (eq (agent-shell-crew-board--merged root "crew/open" "main") 'no))
    (should (eq (agent-shell-crew-board--merged root "crew/never" "main") 'unknown))))

(ert-deftest crew-board-a-merged-branch-deleted-afterwards-still-reads-merged ()
  "Cleaning up merged branches is the first thing anyone does."
  (crew-board-test--with root
    (crew-board-test--repo root)
    (crew-board-test--git root "switch" "-q" "-c" "crew/37")
    (crew-board-test--git root "commit" "-q" "--allow-empty" "-m" "work")
    (crew-board-test--git root "switch" "-q" "main")
    (crew-board-test--git root "merge" "-q" "--no-ff" "-m" "Merge branch 'crew/37' into main" "crew/37")
    (crew-board-test--git root "branch" "-q" "-D" "crew/37")
    (should (eq (agent-shell-crew-board--merged root "crew/37" "main") 'yes))))

(ert-deftest crew-board-trunk-comes-from-the-profile ()
  (crew-board-test--with root
    (let ((agent-shell-crew-profiles `(("p" :root ,root :trunk "trunk" :members nil))))
      (should (equal (agent-shell-crew-board--trunk root) "trunk")))
    (should (equal (agent-shell-crew-board--trunk root) "main"))))

;;; Buffer

(ert-deftest crew-board-buffer-renders-a-row-with-its-sentence ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (agent-shell-crew-queue-create root "human" :title "Office documents" :owner "owner@my-app"
                                   :ref "38" :status "Merged; not deployed.")
    (with-current-buffer (agent-shell-crew-board root)
      (should (derived-mode-p 'agent-shell-crew-board-mode))
      (should (string-match-p "38" (buffer-string)))
      (should (string-match-p "Merged; not deployed\\." (buffer-string))))))

(provide 'agent-shell-crew-board-test)
;;; agent-shell-crew-board-test.el ends here
