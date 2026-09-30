;;; agent-shell-crew-test.el --- Session and command tests -*- lexical-binding: t; -*-
;;; Commentary:
;; Runs against test/stubs, never a real agent.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-crew)

(defmacro crew-main-test--with (root &rest body)
  "Fresh queue dir, project ROOT, and clean stub state for BODY."
  (declare (indent 1))
  `(let* ((agent-shell-crew-directory (file-name-as-directory (make-temp-file "crew-m" t)))
          (,root (let ((d (expand-file-name "my-app/" (make-temp-file "crew-root" t))))
                   (make-directory d t) d))
          (agent-shell-test--calls nil)
          (agent-shell-test--subscriptions nil)
          (agent-shell-test--busy nil))
     (cl-letf (((symbol-function 'agent-shell-crew--server-socket) (lambda () "/tmp/test-socket")))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (or (buffer-local-value 'agent-shell-crew--member b)
                     (and (buffer-file-name b)
                          (string-prefix-p agent-shell-crew-directory (buffer-file-name b))))
             (kill-buffer b)))))))

(ert-deftest crew-member-names ()
  (should (equal (agent-shell-crew-member-name "owner" "/x/my-app/") "owner@my-app"))
  (should (equal (agent-shell-crew-members "/x/my-app/")
                 '("human" "lead@my-app" "owner@my-app" "check@my-app"))))

(ert-deftest crew-session-config-attaches-mcp-with-identity ()
  (let* ((agent-shell-mcp-servers '(((name . "user-server") (command . "x"))))
         (config (agent-shell-crew--session-config "owner" "/x/my-app/" "/tmp/sock"))
         (servers (alist-get :mcp-servers config))
         (crew (seq-find (lambda (s) (equal (alist-get 'name s) "agent-shell-crew")) servers))
         (env (alist-get 'env crew)))
    (should (equal (alist-get :buffer-name config) "owner@my-app"))
    (should (seq-find (lambda (s) (equal (alist-get 'name s) "user-server")) servers))
    (should (equal (alist-get 'command crew) agent-shell-crew-python))
    (should (equal (alist-get 'args crew) (list agent-shell-crew-mcp-program)))
    (should (seq-find (lambda (e) (and (equal (alist-get 'name e) "CREW_AGENT")
                                       (equal (alist-get 'value e) "owner@my-app")))
                      env))
    (should (seq-find (lambda (e) (and (equal (alist-get 'name e) "CREW_PROJECT")
                                       (equal (alist-get 'value e) "/x/my-app/")))
                      env))
    (should (seq-find (lambda (e) (equal (alist-get 'value e) "/tmp/sock")) env))))

(ert-deftest crew-start-names-buffers-and-sends-brief-when-ready ()
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner" "check"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app"))
          (check (agent-shell-crew--member-buffer "check@my-app")))
      (should (buffer-live-p owner))
      (should (buffer-live-p check))
      (should (equal (buffer-name owner) "owner@my-app"))
      (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 2))
      ;; Nothing is sent before the session says it is ready.
      (should-not (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'prompt-ready)
        (agent-shell-test--emit owner 'prompt-ready))
      (let ((inserts (seq-filter (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls)))
        (should (= (length inserts) 1))
        (should (string-match-p "You are owner@my-app" (nth 1 (car inserts))))
        (should (string-match-p "You build" (nth 1 (car inserts))))))))

(ert-deftest crew-start-skips-running-member ()
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (agent-shell-crew-start root '("owner"))
    (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 1))))

(ert-deftest crew-deliver-busy-queues ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy t))
      (agent-shell-crew--deliver (current-buffer) "hello")
      (should (equal (car agent-shell-test--calls) (list 'queue "hello" (current-buffer)))))))

(ert-deftest crew-deliver-idle-empty-submits ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy nil))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-crew--deliver (current-buffer) "hello"))
      (should (equal (car agent-shell-test--calls)
                     (list 'insert "hello" t t (current-buffer)))))))

(ert-deftest crew-deliver-never-submits-a-draft ()
  (with-temp-buffer
    (let ((agent-shell-test--calls nil) (agent-shell-test--busy nil) (buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) nil)))
        (agent-shell-crew--deliver buffer "hello"))
      (should (null agent-shell-test--calls))
      (should (equal agent-shell-crew--pending '("hello")))
      ;; Once the human submits and the turn runs, it is queued, not typed.
      (setq agent-shell-test--busy t)
      (agent-shell-crew--flush buffer)
      (should (equal (car agent-shell-test--calls) (list 'queue "hello" buffer)))
      (should (null agent-shell-crew--pending)))))

(ert-deftest crew-input-empty-without-process-is-not-empty ()
  (with-temp-buffer
    (should-not (agent-shell-crew--input-empty-p (current-buffer)))))

(ert-deftest crew-notify-unknown-member-is-quiet ()
  (let ((agent-shell-test--calls nil))
    (agent-shell-crew--notify "nobody@my-app" "/x/my-app/" "hello")
    (should (null agent-shell-test--calls))))

(ert-deftest crew-rpc-wired-to-members-and-notify ()
  (should (eq agent-shell-crew-rpc-members-function #'agent-shell-crew-members))
  (should (eq agent-shell-crew-rpc-notify-function #'agent-shell-crew--notify)))

(provide 'agent-shell-crew-test)
;;; agent-shell-crew-test.el ends here
