;;; agent-shell-crew-list-test.el --- Crew list view tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Runs against test/stubs, never a real agent.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew-list)

(defmacro crew-list-test--with (root &rest body)
  "Fresh queue dir, project ROOT and clean stub state for BODY."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-l" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-test--calls nil)
          (agent-shell-test--subscriptions nil)
          (agent-shell-test--busy nil))
     (cl-letf (((symbol-function 'agent-shell-crew--server-socket) (lambda () "/tmp/test-socket")))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-live-p b)
                      (or (buffer-local-value 'agent-shell-crew--member b)
                          (string-prefix-p "*crew: " (buffer-name b))
                          (and (buffer-file-name b)
                               (string-prefix-p agent-shell-crew-directory (buffer-file-name b)))))
             (kill-buffer b)))))))

(defun crew-list-test--rows (root)
  "Return ROOT's list rows as (MEMBER STATUS STATE TITLE) lists."
  (mapcar (lambda (row)
            (list (plist-get row :member) (plist-get row :status)
                  (plist-get (plist-get row :item) :state) (plist-get (plist-get row :item) :title)))
          (agent-shell-crew-list--rows root)))

(ert-deftest crew-list-rows-members-with-status-and-items ()
  (crew-list-test--with root
    (agent-shell-crew-start root '("owner" "check"))
    (with-current-buffer (agent-shell-crew--member-buffer "owner@my-app" root)
      (setq agent-shell-test--status 'busy))
    (let ((id (agent-shell-crew-queue-create root "human" :title "Build it" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id))
    (let ((rows (crew-list-test--rows root)))
      (should (member '("owner@my-app" working "ACTIVE" "Build it") rows))
      (should (member '("check@my-app" ready nil nil) rows))
      (should (member '("lead@my-app" not-running nil nil) rows)))))

(ert-deftest crew-list-rows-one-per-open-item-closed-counted ()
  (crew-list-test--with root
    (let ((a (agent-shell-crew-queue-create root "human" :title "A" :owner "owner@my-app"))
          (b (agent-shell-crew-queue-create root "human" :title "B" :owner "owner@my-app")))
      (ignore b)
      (agent-shell-crew-queue-done root "owner@my-app" a "x"))
    (let ((rows (seq-filter (lambda (r) (equal (car r) "owner@my-app")) (crew-list-test--rows root))))
      (should (equal rows '(("owner@my-app" not-running "PENDING" "B")))))
    (should (= (agent-shell-crew-list--closed-count root) 1))))

(ert-deftest crew-list-rows-blocked-and-human-items ()
  (crew-list-test--with root
    (agent-shell-crew-start root '("owner"))
    (with-current-buffer (agent-shell-crew--member-buffer "owner@my-app" root)
      (setq agent-shell-test--status 'blocked))
    (agent-shell-crew-queue-create root "owner@my-app" :title "Your call" :owner "human")
    (let ((rows (crew-list-test--rows root)))
      (should (member '("owner@my-app" blocked nil nil) rows))
      (should (member '("human" nil "PENDING" "Your call") rows)))))

(ert-deftest crew-list-buffer-renders-and-marks-decisions ()
  (crew-list-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "Pick one" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "Which? (1) a; (2) b"))
    (with-current-buffer (agent-shell-crew-list root)
      (should (derived-mode-p 'agent-shell-crew-list-mode))
      (should (string-match-p "Pick one" (buffer-string)))
      (should (string-match-p "decide" (buffer-string)))
      (should (string-match-p "my-app" (buffer-name))))))

(ert-deftest crew-list-ret-goes-to-the-member-session ()
  (crew-list-test--with root
    (agent-shell-crew-start root '("owner"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app" root)) shown)
      (with-current-buffer (agent-shell-crew-list root)
        (goto-char (point-min))
        (re-search-forward "owner@my-app")
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq shown b))))
          (agent-shell-crew-list-goto))
        (should (eq shown owner))))))

(ert-deftest crew-list-d-decides-the-item-at-point ()
  (crew-list-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "Pick one" :owner "owner@my-app")) got)
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "Which? (1) a; (2) b")
      (with-current-buffer (agent-shell-crew-list root)
        (goto-char (point-min))
        (re-search-forward "Pick one")
        (cl-letf (((symbol-function 'agent-shell-crew-decide-item)
                   (lambda (r i) (setq got (list r i)))))
          (agent-shell-crew-list-decide))
        (should (equal got (list root id)))))))

(ert-deftest crew-list-refreshes-on-queue-change ()
  (crew-list-test--with root
    (let ((buffer (agent-shell-crew-list root)))
      (agent-shell-crew-queue-create root "human" :title "Arrived later" :owner "owner@my-app")
      (with-current-buffer buffer
        (should (string-match-p "Arrived later" (buffer-string)))))))

(ert-deftest crew-decide-item-records-and-nudges ()
  (crew-list-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")) told)
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "OK? (1) yes; (2) no")
      (cl-letf (((symbol-function 'agent-shell-crew--notify) (lambda (m _r tx) (push (list m tx) told)))
                ((symbol-function 'completing-read) (lambda (&rest _) "1 — yes")))
        (agent-shell-crew-decide-item root id))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :decision) "1 — yes"))
      (should (equal (car (car told)) "owner@my-app")))))

(provide 'agent-shell-crew-list-test)
;;; agent-shell-crew-list-test.el ends here
