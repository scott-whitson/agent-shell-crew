;;; agent-shell-crew-rpc.el --- The entry point for the crew MCP program -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Whitson

;; Author: Scott Whitson <scott@scottwhitson.com>
;; URL: https://github.com/scott-whitson/agent-shell-crew
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of agent-shell-crew.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `agent-shell-crew-rpc' is the only function the MCP program calls.  Its
;; single argument is a base64-encoded JSON request, so no Lisp is ever
;; built from text; it always returns base64-encoded JSON and never signals.

;;; Code:

(require 'json)
(require 'agent-shell-crew-queue)

(defvar agent-shell-crew-rpc-notify-function nil
  "Function called with MEMBER, ROOT and TEXT to tell a member about work.
Nil means nobody is told; items still wait in the queue.")

(defvar agent-shell-crew-rpc-members-function nil
  "Function called with ROOT that returns the names allowed as owners.
Nil accepts any name.")

(defvar agent-shell-crew-rpc-closed-function nil
  "Function called with ACTOR, ROOT and ID after ACTOR closes or hands off ID.
Nil does nothing.  The session side records what the item cost and gives
the member a fresh context; see `agent-shell-crew--item-closed'.")

(defun agent-shell-crew--rpc-closed (actor root id)
  "Run `agent-shell-crew-rpc-closed-function' for ACTOR, ROOT and ID.
Never signals."
  (when agent-shell-crew-rpc-closed-function
    (condition-case nil (funcall agent-shell-crew-rpc-closed-function actor root id)
      (error nil))))

(defun agent-shell-crew--rpc-encode (object)
  "Return OBJECT as base64-encoded JSON."
  (base64-encode-string (encode-coding-string (json-encode object) 'utf-8) t))

(defun agent-shell-crew--nudge-text (id title)
  "Return the one-line nudge for new item ID titled TITLE."
  (format "New crew item %s for you: %s. Call crew_show with id %s." id title id))

(defun agent-shell-crew--item-json (item)
  "Return ITEM, a plist, as an alist for `json-encode'."
  `((id . ,(plist-get item :id))
    (title . ,(plist-get item :title))
    (state . ,(plist-get item :state))
    (owner . ,(plist-get item :owner))
    (from . ,(plist-get item :from))
    (parent . ,(plist-get item :parent))
    (evidence . ,(plist-get item :evidence))
    (ref . ,(plist-get item :ref))
    (status . ,(plist-get item :status))
    (branch . ,(plist-get item :branch))
    (checkpoint . ,(plist-get item :checkpoint))
    (question . ,(plist-get item :question))
    (decision . ,(plist-get item :decision))
    (brief . ,(plist-get item :brief))
    (log . ,(vconcat (plist-get item :log)))))

(defun agent-shell-crew--rpc-arg (args key &optional required)
  "Return KEY from ARGS, failing when REQUIRED and blank."
  (let ((value (alist-get key args)))
    (when (and required (agent-shell-crew--blank-p value))
      (agent-shell-crew--fail "Missing argument: %s" key))
    value))

(defun agent-shell-crew--rpc-check-member (root name)
  "Fail unless NAME may own items in ROOT."
  (when agent-shell-crew-rpc-members-function
    (let ((members (funcall agent-shell-crew-rpc-members-function root)))
      (unless (member name members)
        (agent-shell-crew--fail "%s is not a member of this crew (members: %s)"
                                name (string-join members ", "))))))

(defun agent-shell-crew--rpc-notify (member root text &optional urgent)
  "Tell MEMBER of ROOT's crew TEXT, unless MEMBER is the human.
URGENT non-nil asks for the text to be steered into a running turn."
  (when (and agent-shell-crew-rpc-notify-function (not (equal member "human")))
    (condition-case nil
        (if urgent
            (funcall agent-shell-crew-rpc-notify-function member root text t)
          (funcall agent-shell-crew-rpc-notify-function member root text))
      (error nil))))

(defun agent-shell-crew--rpc-dispatch (actor root verb args)
  "Run VERB with ARGS in ROOT's queue on behalf of ACTOR."
  (let ((arg (lambda (key &optional required) (agent-shell-crew--rpc-arg args key required))))
    (pcase verb
      ("mine" (vconcat (mapcar #'agent-shell-crew--item-json (agent-shell-crew-queue-list root actor))))
      ("list" (vconcat (mapcar #'agent-shell-crew--item-json (agent-shell-crew-queue-list root))))
      ("show" (agent-shell-crew--item-json (agent-shell-crew-queue-get root (funcall arg 'id t))))
      ("create"
       (let ((owner (funcall arg 'owner t)) (title (funcall arg 'title t))
             (request (funcall arg 'request_id)))
         (if-let* ((old (agent-shell-crew-queue-find-request root actor request)))
             `((id . ,old) (duplicate . t))
           (agent-shell-crew--rpc-check-member root owner)
           (let ((id (agent-shell-crew-queue-create root actor :title title :owner owner
                                                    :brief (funcall arg 'brief)
                                                    :evidence (funcall arg 'evidence)
                                                    :ref (funcall arg 'ref)
                                                    :parent (funcall arg 'parent)
                                                    :status (funcall arg 'status)
                                                    :branch (funcall arg 'branch)
                                                    :request request)))
             (agent-shell-crew--rpc-notify owner root (agent-shell-crew--nudge-text id title)
                                           (eq (funcall arg 'urgent) t))
             `((id . ,id))))))
      ("claim" (agent-shell-crew-queue-claim root actor (funcall arg 'id t)) '((done . t)))
      ("note" (agent-shell-crew-queue-note root actor (funcall arg 'id t) (funcall arg 'text t))
              '((done . t)))
      ("handoff"
       (let ((to (funcall arg 'to t)) (request (funcall arg 'request_id)))
         (if-let* ((old (agent-shell-crew-queue-find-request root actor request)))
             `((id . ,old) (duplicate . t))
           (agent-shell-crew--rpc-check-member root to)
           (let* ((new (agent-shell-crew-queue-handoff root actor (funcall arg 'id t) to
                                                       (funcall arg 'summary t) (funcall arg 'brief)
                                                       (funcall arg 'status) (funcall arg 'branch)
                                                       request))
                  (title (plist-get (agent-shell-crew-queue-get root new) :title)))
             (agent-shell-crew--rpc-notify to root (agent-shell-crew--nudge-text new title))
             (agent-shell-crew--rpc-closed actor root (funcall arg 'id t))
             `((id . ,new))))))
      ("checkpoint" (agent-shell-crew-queue-checkpoint root actor (funcall arg 'id t)
                                                       (funcall arg 'text t))
                    '((done . t)))
      ("stage" (agent-shell-crew-queue-stage root actor (funcall arg 'id t) (funcall arg 'stage t)
                                             (funcall arg 'evidence t) (funcall arg 'status))
               '((done . t)))
      ("park" (agent-shell-crew-queue-park root actor (funcall arg 'id t) (funcall arg 'question t)
                                           (funcall arg 'evidence) (funcall arg 'status))
              '((done . t)))
      ("done"
       (let* ((id (funcall arg 'id t))
              (owner (plist-get (agent-shell-crew-queue-get root id) :owner))
              (cascaded (agent-shell-crew-queue-done root actor id (funcall arg 'reason)
                                                     (eq (funcall arg 'canceled) t)
                                                     (funcall arg 'status) (funcall arg 'branch))))
         ;; Whoever loses work they own is told: the owner, when someone else
         ;; cancelled it, and every owner of an item the cancel cascaded to.
         (dolist (lost (cons (cons id owner) cascaded))
           (unless (equal (cdr lost) actor)
             (agent-shell-crew--rpc-notify
              (cdr lost) root
              (format "Crew item %s was canceled by %s. Stop work on it." (car lost) actor)
              t)))
         (when (equal owner actor) (agent-shell-crew--rpc-closed actor root id))
         `((done . t) (canceled_children . ,(vconcat (mapcar #'car cascaded))))))
      (_ (agent-shell-crew--fail "Unknown verb: %s" verb)))))

;;;###autoload
(defun agent-shell-crew-rpc (payload)
  "Handle one request from the crew MCP program.
PAYLOAD is base64-encoded JSON with keys actor, project, verb and args.
Returns base64-encoded JSON, {\"ok\": true, \"result\": ...} or
{\"ok\": false, \"error\": ...}.  Never signals."
  (agent-shell-crew--rpc-encode
   (condition-case err
       (let* ((request (json-parse-string
                        (decode-coding-string (base64-decode-string payload) 'utf-8)
                        :object-type 'alist :null-object nil :false-object nil))
              (actor (alist-get 'actor request))
              (root (alist-get 'project request))
              (verb (alist-get 'verb request))
              (args (alist-get 'args request)))
         (unless (and (stringp actor) (not (string-empty-p actor)))
           (agent-shell-crew--fail "Request has no actor"))
         (unless (and (stringp root) (file-directory-p root))
           (agent-shell-crew--fail "Request has no valid project"))
         (unless (stringp verb) (agent-shell-crew--fail "Request has no verb"))
         `((ok . t) (result . ,(agent-shell-crew--rpc-dispatch actor root verb args))))
     (agent-shell-crew-error `((ok . :json-false) (error . ,(cadr err))))
     (error `((ok . :json-false)
              (error . ,(format "Malformed request: %s" (error-message-string err))))))))

(provide 'agent-shell-crew-rpc)
;;; agent-shell-crew-rpc.el ends here
