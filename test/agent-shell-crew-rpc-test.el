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

(provide 'agent-shell-crew-rpc-test)
;;; agent-shell-crew-rpc-test.el ends here
