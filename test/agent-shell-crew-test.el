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
      ;; Created with that name, never renamed: shell-maker finds its
      ;; process by the buffer's original name.
      (should (equal (buffer-local-value 'agent-shell-test--created-name owner) "owner@my-app"))
      (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 2))
      ;; Nothing is sent before the session says it is ready.
      (should-not (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'init-finished)
        (agent-shell-test--emit owner 'init-finished))
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

(ert-deftest crew-options-parse ()
  (should (equal (agent-shell-crew--options "Pick: (1) numbers only - raise; (2) accept strings; (3) leave it.")
                 '("1 — numbers only - raise" "2 — accept strings" "3 — leave it")))
  (should (equal (agent-shell-crew--options "(1) yes (2) no") '("1 — yes" "2 — no")))
  (should (null (agent-shell-crew--options "Should it?"))))

(ert-deftest crew-new-creates-and-nudges ()
  (crew-main-test--with root
    (let ((told nil))
      (cl-letf (((symbol-function 'agent-shell-crew--notify)
                 (lambda (m _r tx) (push (list m tx) told))))
        (let* ((id (agent-shell-crew-new root "owner@my-app" "Do it" "brief" "notes/e.md"))
               (item (agent-shell-crew-queue-get root id)))
          (should (equal (plist-get item :from) "human"))
          (should (equal (plist-get item :evidence) "notes/e.md"))
          (should (equal (car (car told)) "owner@my-app")))))))

(ert-deftest crew-decide-records-and-nudges ()
  (crew-main-test--with root
    (let* ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app"))
           (told nil))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "Pick (1) a; (2) b")
      (cl-letf (((symbol-function 'agent-shell-crew--notify) (lambda (m _r tx) (push (list m tx) told)))
                ((symbol-function 'completing-read)
                 (lambda (_p coll &rest _) (if (equal coll '("1 — a" "2 — b")) "1 — a" (car coll)))))
        (agent-shell-crew-decide))
      (let ((item (agent-shell-crew-queue-get root id)))
        (should (equal (plist-get item :state) "ACTIVE"))
        (should (equal (plist-get item :decision) "1 — a")))
      (should (equal (car (car told)) "owner@my-app"))
      (should (string-match-p "1 — a" (nth 1 (car told)))))))

(ert-deftest crew-decide-owner-not-running ()
  (crew-main-test--with root
    (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
      (agent-shell-crew-queue-claim root "owner@my-app" id)
      (agent-shell-crew-queue-park root "owner@my-app" id "OK?")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "yes")))
        (agent-shell-crew-decide))
      (should (equal (plist-get (agent-shell-crew-queue-get root id) :decision) "yes"))
      (should (string-match-p (regexp-quote id)
                              (agent-shell-crew--intro "owner" "owner@my-app" root))))))

(ert-deftest crew-decide-nothing-waiting ()
  (crew-main-test--with root
    (ignore root)
    (should-error (agent-shell-crew-decide) :type 'user-error)))

(ert-deftest crew-mode-line-counts-parked ()
  (crew-main-test--with root
    (let ((global-mode-string nil))
      (agent-shell-crew-mode-line-mode 1)
      (unwind-protect
          (let ((id (agent-shell-crew-queue-create root "human" :title "T" :owner "owner@my-app")))
            (should (= agent-shell-crew--parked-count 0))
            (agent-shell-crew-queue-claim root "owner@my-app" id)
            (agent-shell-crew-queue-park root "owner@my-app" id "Q?")
            (should (= agent-shell-crew--parked-count 1))
            (should (member agent-shell-crew--mode-line global-mode-string)))
        (agent-shell-crew-mode-line-mode -1))
      (should-not (member agent-shell-crew--mode-line global-mode-string)))))

;;; Final-review findings.

(ert-deftest crew-start-asks-for-a-new-session ()
  "Finding 3: every role gets a NEW session, never a picker or a resume."
  (crew-main-test--with root
    (let ((agent-shell-session-strategy 'prompt))
      (agent-shell-crew-start root '("owner" "check")))
    (should (equal (mapcar #'cadr (seq-filter (lambda (c) (eq (car c) 'strategy)) agent-shell-test--calls))
                   '(new new)))))

(ert-deftest crew-nudge-before-ready-waits-for-intro ()
  "Finding 4: nudges sent during bootstrap arrive after the intro, none lost."
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app" root)))
      (agent-shell-crew--notify "owner@my-app" root "first nudge")
      (agent-shell-crew--notify "owner@my-app" root "second nudge")
      (should-not (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'init-finished))
      (let ((texts (mapcar (lambda (c) (nth 1 c))
                           (reverse (seq-filter (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls)))))
        (should (= (length texts) 3))
        (should (string-match-p "You are owner@my-app" (nth 0 texts)))
        (should (equal (cdr texts) '("first nudge" "second nudge")))))))

(ert-deftest crew-intro-lists-items-created-during-bootstrap ()
  "Finding 4: the intro's owned list is taken when the session is ready."
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app" root))
          (id (agent-shell-crew-queue-create root "human" :title "Late" :owner "owner@my-app")))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'init-finished))
      (should (seq-find (lambda (c) (and (eq (car c) 'insert) (string-match-p (regexp-quote id) (nth 1 c))))
                        agent-shell-test--calls)))))

(ert-deftest crew-restarted-session-is-re-adopted ()
  "Finding 5: a restart (same crew identity, no live holder) is tracked again."
  (crew-main-test--with root
    (let ((buf (generate-new-buffer "restarted")))
      (with-current-buffer buf
        (setq-local agent-shell--state
                    (list (cons :agent-config
                                (agent-shell-crew--session-config "owner" root "/tmp/s"))))
        (agent-shell-crew--maybe-adopt))
      (should (eq (agent-shell-crew--member-buffer "owner@my-app" root) buf)))))

(ert-deftest crew-forked-session-is-not-a-second-owner ()
  "Finding 5: a fork while the member is live is not adopted as a twin."
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (let ((live (agent-shell-crew--member-buffer "owner@my-app" root))
          (fork (generate-new-buffer "forked")))
      (with-current-buffer fork
        (setq-local agent-shell--state
                    (list (cons :agent-config
                                (agent-shell-crew--session-config "owner" root "/tmp/s"))))
        (agent-shell-crew--maybe-adopt))
      (should (eq (agent-shell-crew--member-buffer "owner@my-app" root) live))
      (should-not (buffer-local-value 'agent-shell-crew--member fork))
      (kill-buffer fork))))

(ert-deftest crew-same-member-name-two-projects ()
  "Finding 6: owner@app in two folders named app are different sessions."
  (crew-main-test--with root
    (ignore root)
    (let ((a (let ((d (expand-file-name "app/" (make-temp-file "crew-a" t)))) (make-directory d t) d))
          (b (let ((d (expand-file-name "app/" (make-temp-file "crew-b" t)))) (make-directory d t) d)))
      (agent-shell-crew-start a '("owner"))
      (agent-shell-crew-start b '("owner"))
      (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 2))
      (should-not (eq (agent-shell-crew--member-buffer "owner@app" a)
                      (agent-shell-crew--member-buffer "owner@app" b))))))

;;; Live-run findings (2026-09-30).

(ert-deftest crew-start-from-an-agent-shell-buffer-still-new ()
  "A: a buffer-local strategy in the calling buffer must not leak in."
  (crew-main-test--with root
    (with-temp-buffer
      (setq-local agent-shell-session-strategy 'prompt)
      (agent-shell-crew-start root '("owner")))
    (should (equal (mapcar #'cadr (seq-filter (lambda (c) (eq (car c) 'strategy)) agent-shell-test--calls))
                   '(new)))))

(ert-deftest crew-brief-waits-for-init-finished ()
  "B: prompt-ready comes before the session mode is set; the brief must wait."
  (crew-main-test--with root
    (agent-shell-crew-start root '("owner"))
    (let ((owner (agent-shell-crew--member-buffer "owner@my-app" root)))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit owner 'prompt-ready)
        (should-not (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls))
        (agent-shell-test--emit owner 'init-finished))
      (should (seq-find (lambda (c) (eq (car c) 'insert)) agent-shell-test--calls)))))

(ert-deftest crew-owner-candidates-running-first ()
  "C: members with a running session are offered first."
  (crew-main-test--with root
    (agent-shell-crew-start root '("check"))
    (should (equal (car (agent-shell-crew--owner-candidates root)) "check@my-app"))
    (should (member "lead@my-app" (agent-shell-crew--owner-candidates root)))
    (should-not (member "human" (agent-shell-crew--owner-candidates root)))))

;;; Profiles.

(defun crew-profile-test--dir (parent name)
  "Make and return directory NAME under PARENT, without a trailing slash."
  (let ((dir (expand-file-name name parent))) (make-directory dir t) dir))

(defmacro crew-profile-test--with (vars &rest body)
  "Bind VARS (ROOT LANE GATE-BRIEF) around a profile named \"app\" and run BODY."
  (declare (indent 1))
  (let ((root (nth 0 vars)) (lane (nth 1 vars)) (brief (nth 2 vars)))
    `(crew-main-test--with ,root
       (let* ((parent (file-name-directory (directory-file-name ,root)))
              (,lane (crew-profile-test--dir parent "my-app-lane-1"))
              (,brief (let ((f (make-temp-file "gate-brief" nil ".md")))
                        (with-temp-file f (insert "You gate. Bundle and run the full check once."))
                        f))
              (agent-shell-crew-profiles
               `(("app" :root ,,root
                  :members ((:role "owner" :name "owner-1" :directory ,,lane)
                            (:role "check" :name "check-1" :directory ,,lane)
                            (:role "gate" :brief ,,brief))))))
         ,@body))))

(ert-deftest crew-profile-members ()
  (crew-profile-test--with (root lane brief)
    (ignore lane brief)
    (should (equal (agent-shell-crew-members root)
                   '("human" "owner-1@my-app" "check-1@my-app" "gate@my-app")))
    (let ((other (crew-profile-test--dir (make-temp-file "crew-o" t) "other")))
      (should (member "lead@other" (agent-shell-crew-members other))))))

(ert-deftest crew-start-profile-each-member-in-its-directory ()
  (crew-profile-test--with (root lane brief)
    (ignore brief)
    (agent-shell-crew-start-profile "app")
    (let ((starts (reverse (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls))))
      (should (= (length starts) 3))
      (should (equal (mapcar (lambda (c) (nth 2 c)) starts)
                     (list (file-name-as-directory lane) (file-name-as-directory lane) root)))
      (dolist (c starts)
        (let* ((config (nth 1 c))
               (crew (seq-find (lambda (s) (equal (alist-get 'name s) "agent-shell-crew"))
                               (alist-get :mcp-servers config)))
               (env (alist-get 'env crew)))
          (should (seq-find (lambda (e) (and (equal (alist-get 'name e) "CREW_PROJECT")
                                             (equal (alist-get 'value e) root)))
                            env)))))
    (should (buffer-live-p (agent-shell-crew--member-buffer "owner-1@my-app" root)))
    (should (buffer-live-p (agent-shell-crew--member-buffer "gate@my-app" root)))
    (should (equal (buffer-name (agent-shell-crew--member-buffer "check-1@my-app" root))
                   "check-1@my-app"))))

(ert-deftest crew-start-profile-brief-override ()
  (crew-profile-test--with (root lane brief)
    (ignore lane brief)
    (agent-shell-crew-start-profile "app")
    (let ((gate (agent-shell-crew--member-buffer "gate@my-app" root)))
      (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
        (agent-shell-test--emit gate 'init-finished))
      (let ((insert (seq-find (lambda (c) (and (eq (car c) 'insert) (eq (nth 4 c) gate)))
                              agent-shell-test--calls)))
        (should (string-match-p "You are gate@my-app, the gate" (nth 1 insert)))
        (should (string-match-p "Bundle and run the full check once" (nth 1 insert)))))))

(ert-deftest crew-start-profile-skips-running ()
  (crew-profile-test--with (root lane brief)
    (ignore root lane brief)
    (agent-shell-crew-start-profile "app")
    (agent-shell-crew-start-profile "app")
    (should (= (length (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls)) 3))))

(ert-deftest crew-start-profile-refuses-before-starting ()
  (crew-profile-test--with (root lane brief)
    (ignore lane brief)
    (let ((agent-shell-crew-profiles
           `(("bad-dir" :root ,root :members ((:role "owner" :directory "/nonexistent/lane")
                                              (:role "check")))
             ("bad-role" :root ,root :members ((:role "owner")
                                               (:role "nobrief"))))))
      (should-error (agent-shell-crew-start-profile "bad-dir") :type 'user-error)
      (should-error (agent-shell-crew-start-profile "bad-role") :type 'user-error)
      (should-error (agent-shell-crew-start-profile "missing") :type 'user-error)
      (should (null (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls))))))

(ert-deftest crew-profile-members-union-of-profiles-sharing-a-root ()
  (crew-main-test--with root
    (let ((agent-shell-crew-profiles
           `(("small" :root ,root :members ((:role "lead") (:role "owner" :name "owner-1")))
             ("full" :root ,root :members ((:role "lead") (:role "owner" :name "owner-1")
                                           (:role "owner" :name "owner-2"))))))
      (should (equal (agent-shell-crew-members root)
                     '("human" "lead@my-app" "owner-1@my-app" "owner-2@my-app"))))))

(ert-deftest crew-start-briefless-role-still-introduced ()
  (crew-main-test--with root
    (let ((agent-shell-crew-roles
           '(("review" :config-maker agent-shell-anthropic-make-claude-code-config))))
      (let ((buffer (car (agent-shell-crew-start root '("review")))))
        (cl-letf (((symbol-function 'agent-shell-crew--input-empty-p) (lambda (_b) t)))
          (agent-shell-test--emit buffer 'init-finished))
        (should (seq-find (lambda (c) (and (eq (car c) 'insert) (eq (nth 4 c) buffer)
                                           (string-match-p "You are review@my-app" (nth 1 c))))
                          agent-shell-test--calls))))))

(ert-deftest crew-start-profile-refuses-bad-briefs-and-names ()
  (crew-main-test--with root
    (let ((agent-shell-crew-roles
           (cons '("review" :config-maker agent-shell-anthropic-make-claude-code-config)
                 agent-shell-crew-roles))
          (agent-shell-crew-profiles
           `(("briefless" :root ,root :members ((:role "review")))
             ("typo-home" :root ,root :members ((:role "gate" :brief "~/no-such-crew-brief-4c1e.md")))
             ("typo-abs" :root ,root :members ((:role "gate" :brief "/no/such/crew-brief.md")))
             ("twins" :root ,root :members ((:role "owner") (:role "owner"))))))
      (dolist (name '("briefless" "typo-home" "typo-abs" "twins"))
        (should-error (agent-shell-crew-start-profile name) :type 'user-error))
      (should (null (seq-filter (lambda (c) (eq (car c) 'start)) agent-shell-test--calls))))))

(provide 'agent-shell-crew-test)
;;; agent-shell-crew-test.el ends here
