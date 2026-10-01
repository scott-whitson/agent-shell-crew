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

(ert-deftest crew-board-bookkeeping-is-not-the-latest-event ()
  (crew-board-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-done root "owner@my-app" id "gated in bundle 2200")
      (agent-shell-crew-queue-set-branch root "human" id "crew/t")
      (should (equal (plist-get (car (agent-shell-crew-board--rows root)) :fallback)
                     "gated in bundle 2200")))))

(ert-deftest crew-board-a-piece-without-a-branch-shows-no-stage-marks ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (let ((stages '((:name "deployed" :check "echo x") (:name "accepted"))))
      (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app" :ref "29")
      (should (equal (agent-shell-crew-board--progress
                      root (car (agent-shell-crew-board--rows root)) "main" stages)
                     '(none none none))))))

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

;;; Stages

(defun crew-board-test--merged-piece (root ref)
  "Create piece REF on branch crew/REF, merged --no-ff into main; return its item id."
  (crew-board-test--git root "switch" "-q" "-c" (concat "crew/" ref))
  (crew-board-test--git root "commit" "-q" "--allow-empty" "-m" ref)
  (crew-board-test--git root "switch" "-q" "main")
  (crew-board-test--git root "merge" "-q" "--no-ff" "-m" (format "Merge branch 'crew/%s'" ref)
                        (concat "crew/" ref))
  (agent-shell-crew-queue-create root "human" :title ref :owner "owner@my-app" :ref ref
                                 :branch (concat "crew/" ref)))

(ert-deftest crew-board-a-recorded-stage-shows-reached ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (let* ((agent-shell-crew-stages '((:name "live-checked")))
           (id (crew-board-test--merged-piece root "40")))
      (should (equal (cdr (agent-shell-crew-board--progress
                           root (car (agent-shell-crew-board--rows root)) "main"
                           agent-shell-crew-stages))
                     '(no)))
      (agent-shell-crew-queue-stage root "human" id "live-checked" "card used the lesson on the test tenant")
      (should (equal (agent-shell-crew-board--progress
                      root (car (agent-shell-crew-board--rows root)) "main" agent-shell-crew-stages)
                     '(yes yes))))))

(ert-deftest crew-board-a-stage-records-on-a-closed-item-by-owner-or-human ()
  (crew-board-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-done root "owner@my-app" id "built")
      (agent-shell-crew-queue-stage root "owner@my-app" id "deployed" "playground 1a2b")
      (should-error (agent-shell-crew-queue-stage root "check@my-app" id "deployed" "x")
                    :type 'agent-shell-crew-error)
      (should-error (agent-shell-crew-queue-stage root "human" id "deployed" "  ")
                    :type 'agent-shell-crew-error))))

(ert-deftest crew-board-a-check-stage-compares-commits-in-the-background ()
  "The check names a commit; a piece is there when its merge is an ancestor."
  (crew-board-test--with root
    (crew-board-test--repo root)
    (crew-board-test--merged-piece root "38")
    (let ((deployed (agent-shell-crew-board--git-out root "rev-parse" "HEAD")))
      (crew-board-test--merged-piece root "40")
      (let* ((agent-shell-crew-board--checks nil)
             (agent-shell-crew-board--running nil)
             (stages `((:name "deployed" :check ,(format "echo %s" deployed))))
             (agent-shell-crew-stages stages)
             (progress (lambda (ref)
                         (cdr (agent-shell-crew-board--progress
                               root (seq-find (lambda (r) (equal (plist-get r :ref) ref))
                                              (agent-shell-crew-board--rows root))
                               "main" stages)))))
        (should (equal (funcall progress "38") '(pending)))
        (with-timeout (10 (ert-fail "the check never answered"))
          (while agent-shell-crew-board--running (accept-process-output nil 0.05)))
        (should (equal (funcall progress "38") '(yes)))
        (should (equal (funcall progress "40") '(no)))))))

(ert-deftest crew-board-merged-work-at-a-human-stage-waits-on-the-human ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (let ((agent-shell-crew-stages '((:name "deployed") (:name "accepted"))))
      (crew-board-test--merged-piece root "37")
      (let ((id (crew-board-test--merged-piece root "39")))
        (agent-shell-crew-queue-stage root "human" id "deployed" "prod d3457"))
      (should (equal (sort (mapcar (lambda (w) (format "%s %s" (car w) (cdr w)))
                                   (cdr (cdr (progn (agent-shell-crew-board--recompute root)
                                                    (assoc root agent-shell-crew-board--waiting)))))
                           #'string<)
                     '("37 deployed" "39 accepted"))))))

(ert-deftest crew-board-a-stage-a-member-owns-does-not-wait-on-the-human ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (let ((agent-shell-crew-stages '((:name "deployed" :owner "gate@my-app"))))
      (crew-board-test--merged-piece root "37")
      (agent-shell-crew-board--recompute root)
      (should-not (cddr (assoc root agent-shell-crew-board--waiting))))))

(ert-deftest crew-board-hides-closed-rows-without-a-ref-until-asked ()
  (crew-board-test--with root
    (crew-board-test--repo root)
    (let ((slate (agent-shell-crew-queue-create root "human" :title "Slate" :owner "lead@my-app")))
      (agent-shell-crew-queue-claim root "lead@my-app" slate)
      (agent-shell-crew-queue-done root "lead@my-app" slate "approved"))
    (agent-shell-crew-queue-create root "human" :title "Real work" :owner "owner@my-app" :ref "41")
    (with-current-buffer (agent-shell-crew-board root)
      (should (string-match-p "Real work" (buffer-string)))
      (should-not (string-match-p "Slate" (buffer-string)))
      (agent-shell-crew-board-toggle-all)
      (should (string-match-p "Slate" (buffer-string))))))

(ert-deftest crew-board-columns-include-each-stage ()
  (should (equal (mapcar #'car (agent-shell-crew-board--format '((:name "deployed") (:name "accepted"))))
                 '("Ref" "State" "Merged" "deployed" "accepted" "Title" "Status"))))

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
