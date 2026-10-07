;;; agent-shell-crew-rpc-test.el --- RPC tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Drives `agent-shell-crew-rpc' exactly as the MCP program does.
;;; Code:
(require 'ert)
(require 'json)
(require 'agent-shell-crew-rpc)

(defmacro crew-rpc-test--with (root &rest body)
  "Fresh queue dir and project ROOT; notifications captured in `crew-rpc-test--notified'."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-r" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (crew-rpc-test--notified nil)
          (agent-shell-crew-rpc-notify-function
           (lambda (m r tx) (push (list m r tx) crew-rpc-test--notified)))
          (agent-shell-crew-rpc-members-function
           (lambda (_r) '("human" "owner@my-app" "check@my-app"))))
     (ignore crew-rpc-test--notified)
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p agent-shell-crew-directory (buffer-file-name b)))
           (kill-buffer b))))))

(defvar crew-rpc-test--notified nil)

(defun crew-rpc-test--call (actor root verb &optional args)
  "Call the RPC as ACTOR in ROOT with VERB and ARGS; return the decoded reply."
  (let* ((req `((actor . ,actor) (project . ,root) (verb . ,verb) (args . ,(or args (make-hash-table)))))
         (payload (base64-encode-string (encode-coding-string (json-encode req) 'utf-8) t)))
    (json-parse-string (decode-coding-string (base64-decode-string (agent-shell-crew-rpc payload)) 'utf-8)
                       :object-type 'alist :null-object nil :false-object :false)))

(ert-deftest crew-rpc-create-show-list ()
  (crew-rpc-test--with root
    (let* ((reply (crew-rpc-test--call "owner@my-app" root "create"
                                       '((title . "Check it") (brief . "b") (owner . "check@my-app"))))
           (id (alist-get 'id (alist-get 'result reply))))
      (should (eq (alist-get 'ok reply) t))
      (should (stringp id))
      (should (equal (car (car crew-rpc-test--notified)) "check@my-app"))
      (should (string-match-p (regexp-quote id) (nth 2 (car crew-rpc-test--notified))))
      (let ((shown (alist-get 'result (crew-rpc-test--call "check@my-app" root "show" `((id . ,id))))))
        (should (equal (alist-get 'owner shown) "check@my-app"))
        (should (equal (alist-get 'from shown) "owner@my-app")))
      (should (= (length (alist-get 'result (crew-rpc-test--call "check@my-app" root "mine"))) 1))
      (should (= (length (alist-get 'result (crew-rpc-test--call "owner@my-app" root "mine"))) 0))
      (should (= (length (alist-get 'result (crew-rpc-test--call "owner@my-app" root "list"))) 1)))))

(ert-deftest crew-rpc-actor-is-the-request-actor-not-an-arg ()
  (crew-rpc-test--with root
    (let* ((id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    '((title . "T") (owner . "owner@my-app")))))))
      ;; An `actor' smuggled into args is ignored: check@ still does not own it.
      (let ((reply (crew-rpc-test--call "check@my-app" root "claim" `((id . ,id) (actor . "owner@my-app")))))
        (should (eq (alist-get 'ok reply) :false))
        (should (string-match-p "does not own" (alist-get 'error reply)))))))

(ert-deftest crew-rpc-membership ()
  (crew-rpc-test--with root
    (let ((reply (crew-rpc-test--call "owner@my-app" root "create"
                                      '((title . "T") (owner . "stranger@my-app")))))
      (should (eq (alist-get 'ok reply) :false))
      (should (string-match-p "not a member" (alist-get 'error reply))))))

(ert-deftest crew-rpc-full-cycle ()
  (crew-rpc-test--with root
    (let* ((id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    '((title . "T") (owner . "owner@my-app")))))))
      (crew-rpc-test--call "owner@my-app" root "claim" `((id . ,id)))
      (crew-rpc-test--call "owner@my-app" root "note" `((id . ,id) (text . "started")))
      (let* ((reply (crew-rpc-test--call "owner@my-app" root "handoff"
                                         `((id . ,id) (to . "check@my-app") (summary . "built"))))
             (new (alist-get 'id (alist-get 'result reply))))
        (should (eq (alist-get 'ok reply) t))
        (should (equal (car (car crew-rpc-test--notified)) "check@my-app"))
        (crew-rpc-test--call "check@my-app" root "claim" `((id . ,new)))
        (should (eq (alist-get 'ok (crew-rpc-test--call "check@my-app" root "park"
                                                        `((id . ,new) (question . "OK? (1) yes; (2) no")))) t))
        (should (eq (alist-get 'ok (crew-rpc-test--call "check@my-app" root "done"
                                                        `((id . ,new) (reason . "x"))))
                    :false))))))

(ert-deftest crew-rpc-unknown-verb ()
  (crew-rpc-test--with root
    (let ((reply (crew-rpc-test--call "owner@my-app" root "rm-rf")))
      (should (eq (alist-get 'ok reply) :false))
      (should (string-match-p "Unknown verb" (alist-get 'error reply))))))

(ert-deftest crew-rpc-malformed-input-never-signals ()
  (dolist (payload (list "!!!not base64!!!"
                         (base64-encode-string "not json" t)
                         (base64-encode-string "{\"verb\":\"list\"}" t)))
    (let ((reply (json-parse-string (base64-decode-string (agent-shell-crew-rpc payload))
                                    :object-type 'alist :false-object :false)))
      (should (eq (alist-get 'ok reply) :false))
      (should (stringp (alist-get 'error reply))))))

(ert-deftest crew-rpc-unicode-round-trip ()
  (crew-rpc-test--with root
    (let* ((title "Fix “quotes” and \"these\" and \\ and 日本 and 🚀")
           (id (alist-get 'id (alist-get 'result (crew-rpc-test--call "human" root "create"
                                                                    `((title . ,title) (owner . "owner@my-app")))))))
      (should (equal (alist-get 'title (alist-get 'result (crew-rpc-test--call "owner@my-app" root "show" `((id . ,id)))))
                     title)))))

;;; Durable ideas (2026-10-07): request ids, cancel cascade, checkpoints

(defun crew-rpc-test--create (actor root owner &rest more)
  "Create an item as ACTOR for OWNER in ROOT, with MORE args; return its id."
  (alist-get 'id (alist-get 'result
                            (crew-rpc-test--call actor root "create"
                                                 (append `((title . "T") (brief . "b") (owner . ,owner))
                                                         more)))))

(ert-deftest crew-rpc-a-repeated-request-id-returns-the-first-item ()
  (crew-rpc-test--with root
    (let* ((first (crew-rpc-test--call "owner@my-app" root "create"
                                       '((title . "T") (brief . "b") (owner . "check@my-app")
                                         (request_id . "r-1"))))
           (again (crew-rpc-test--call "owner@my-app" root "create"
                                       '((title . "T") (brief . "b") (owner . "check@my-app")
                                         (request_id . "r-1")))))
      (should (equal (alist-get 'id (alist-get 'result again))
                     (alist-get 'id (alist-get 'result first))))
      (should (eq (alist-get 'duplicate (alist-get 'result again)) t))
      (should (= (length (agent-shell-crew-queue-list root)) 1))
      (should (= (length crew-rpc-test--notified) 1)))))

(ert-deftest crew-rpc-the-same-request-id-from-another-actor-is-a-new-item ()
  (crew-rpc-test--with root
    (crew-rpc-test--create "owner@my-app" root "check@my-app" '(request_id . "r-1"))
    (crew-rpc-test--create "check@my-app" root "owner@my-app" '(request_id . "r-1"))
    (should (= (length (agent-shell-crew-queue-list root)) 2))))

(ert-deftest crew-rpc-a-repeated-handoff-is-not-handed-twice ()
  (crew-rpc-test--with root
    (let ((id (crew-rpc-test--create "human" root "owner@my-app")))
      (crew-rpc-test--call "owner@my-app" root "claim" `((id . ,id)))
      (let* ((args `((id . ,id) (to . "check@my-app") (summary . "s") (request_id . "h-1")))
             (one (crew-rpc-test--call "owner@my-app" root "handoff" args))
             (two (crew-rpc-test--call "owner@my-app" root "handoff" args)))
        (should (eq (alist-get 'ok two) t))
        (should (equal (alist-get 'id (alist-get 'result two))
                       (alist-get 'id (alist-get 'result one))))
        (should (= (length (agent-shell-crew-queue-list root)) 2))))))

(ert-deftest crew-rpc-the-creator-may-cancel-and-the-owner-is-told ()
  (crew-rpc-test--with root
    (let ((id (crew-rpc-test--create "owner@my-app" root "check@my-app")))
      (setq crew-rpc-test--notified nil)
      (let ((reply (crew-rpc-test--call "owner@my-app" root "done"
                                        `((id . ,id) (reason . "withdrawn") (canceled . t)))))
        (should (eq (alist-get 'ok reply) t)))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :state) "CANCELED"))
      (should (equal (car (car crew-rpc-test--notified)) "check@my-app"))
      (should (string-match-p "canceled by owner@my-app" (nth 2 (car crew-rpc-test--notified)))))))

(ert-deftest crew-rpc-a-stranger-may-not-cancel ()
  (crew-rpc-test--with root
    (let ((id (crew-rpc-test--create "owner@my-app" root "owner@my-app")))
      (let ((reply (crew-rpc-test--call "check@my-app" root "done"
                                        `((id . ,id) (reason . "x") (canceled . t)))))
        (should-not (eq (alist-get 'ok reply) t))
        (should (string-match-p "does not own" (alist-get 'error reply)))))))

(ert-deftest crew-rpc-the-creator-may-not-close-as-done ()
  (crew-rpc-test--with root
    (let ((id (crew-rpc-test--create "owner@my-app" root "check@my-app")))
      (should-not (eq (alist-get 'ok (crew-rpc-test--call "owner@my-app" root "done"
                                                          `((id . ,id) (reason . "x"))))
                      t)))))

(ert-deftest crew-rpc-cancel-cascades-to-open-children-deepest-first ()
  (crew-rpc-test--with root
    (let* ((top (crew-rpc-test--create "human" root "owner@my-app"))
           (child (crew-rpc-test--create "owner@my-app" root "check@my-app" `(parent . ,top)))
           (grandchild (crew-rpc-test--create "check@my-app" root "owner@my-app" `(parent . ,child)))
           (closed (crew-rpc-test--create "owner@my-app" root "owner@my-app" `(parent . ,top))))
      (crew-rpc-test--call "owner@my-app" root "done" `((id . ,closed) (reason . "built")))
      (let* ((reply (crew-rpc-test--call "human" root "done"
                                         `((id . ,top) (reason . "dropped") (canceled . t))))
             (children (append (alist-get 'canceled_children (alist-get 'result reply)) nil)))
        (should (equal children (list grandchild child))))
      (dolist (id (list top child grandchild))
        (should (equal (plist-get (agent-shell-crew-queue-get root id) :state) "CANCELED")))
      (should (equal (plist-get (agent-shell-crew-queue-get root closed) :state) "DONE"))
      (should (seq-find (lambda (line) (string-match-p (format "canceled with parent %s" top) line))
                        (plist-get (agent-shell-crew-queue-get root child) :log))))))

(ert-deftest crew-rpc-checkpoint-replaces-and-is-shown ()
  (crew-rpc-test--with root
    (let ((id (crew-rpc-test--create "human" root "owner@my-app")))
      (crew-rpc-test--call "owner@my-app" root "checkpoint" `((id . ,id) (text . "phase 1")))
      (crew-rpc-test--call "owner@my-app" root "checkpoint" `((id . ,id) (text . "phase 2 next: tests")))
      (let ((shown (alist-get 'result (crew-rpc-test--call "owner@my-app" root "show" `((id . ,id))))))
        (should (equal (alist-get 'checkpoint shown) "phase 2 next: tests")))
      (should-not (eq (alist-get 'ok (crew-rpc-test--call "check@my-app" root "checkpoint"
                                                          `((id . ,id) (text . "x"))))
                      t)))))

(ert-deftest crew-rpc-closing-tells-the-session-side ()
  (crew-rpc-test--with root
    (let* ((closed nil)
           (agent-shell-crew-rpc-closed-function (lambda (a r) (push (list a r) closed)))
           (id (crew-rpc-test--create "human" root "owner@my-app")))
      (crew-rpc-test--call "owner@my-app" root "done" `((id . ,id) (reason . "built")))
      (should (equal closed (list (list "owner@my-app" root)))))))

(provide 'agent-shell-crew-rpc-test)
;;; agent-shell-crew-rpc-test.el ends here
