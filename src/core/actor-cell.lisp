(defpackage :cl-gserver.actor-cell
  (:use :cl :cl-gserver.utils)
  (:nicknames :act-cell)
  (:export #:actor-cell
           #:cell
           #:name
           #:msgbox
           #:state
           ;; API
           #:handle-call
           #:handle-cast
           #:pre-start
           #:after-stop
           #:stop
           #:call
           #:cast
           #:running-p))

(in-package :cl-gserver.actor-cell)

(defstruct actor-cell-state (running t :type boolean))

(defclass actor-cell ()
   ((name :initarg :name
          :initform (string (gensym "actor-"))
          :reader name
          :documentation
          "The name of the actor/actor-cell. If no name is specified a default one is applied.")
    (state :initarg :state
           :initform nil
           :documentation
           "The encapsulated state.")
    (internal-state :initform (make-actor-cell-state)
                    :documentation
                    "The internal state of the server.")
    (msgbox :initform nil
            :accessor msgbox
            :documentation
            "The `message-box'. By default the `actor'/`actor-cell' has no message-box.
When the actor is created through the `actor-context' of an actor, or the `actor-system'
then it will be populated with a message-box."))
  (:documentation
   "`actor-cell' is the base of the `actor'.
It is meant to encapsulate state, but also to execute async operations.
State can be changed by calling into the server via `call' or `cast'.
Where `call' is waiting for a result and `cast' does not.
For each `call' and `cast' handlers must be implemented by subclasses.

It uses a `message-box' to processes the received messages.
When the `actor'/`actor-cell' was created ad-hoc (out of the `actor-system'/`actor-context'),
it will not have a message-box and can't process messages.
When the `actor' is created through the `actor-system' or `actor-context',
one can decide what kind of message-box/dispatcher should be used for the new `actor'.

See `actor-context' `actor-of' method for more information on this.

To stop an `actor' message handling and you can send the `:stop' message 
either via `call' (which will respond with `:stopped') or `cast'.
This is to cleanup thread resources when the Gserver is not needed anymore.

Note: the `actor-cell' uses `call' and `cast' functions which translate to `ask' and `tell' on the `actor'."))

(defmethod print-object ((obj actor-cell) stream)
  (print-unreadable-object (obj stream :type t)
    (with-slots (name state internal-state msgbox) obj
      (format stream "~a, running: ~a, state: ~a, message-box: ~a"
              name
              (slot-value internal-state 'running)
              state
              msgbox))))

(defmethod initialize-instance :after ((obj actor-cell) &key)
  (pre-start obj (slot-value obj 'state)))

;; -----------------------------------------------
;; public functions / API
;; -----------------------------------------------

(defgeneric pre-start (actor-cell state)
  (:documentation
   "Generic function definition that called from `initialize-instance'."))

(defgeneric after-stop (actor-cell)
  (:documentation
   "Generic function definition that is called after the actor cell has stopped."))

(defgeneric handle-call (actor-cell message current-state)
  (:documentation
   "Handles calls to the server. Must be implemented by subclasses.
The convention here is to return a `cons' with values to be returned to caller as `car', and the new state as `cdr'.
`handle-call' is executed in the default message dispatcher thread."))

(defgeneric handle-cast (actor-cell message current-state)
  (:documentation
   "Handles casts to the server. Must be implemented by subclasses.
Same convention as for 'handle-call' except that no return is sent to the caller. This function returns immediately."))

(defgeneric stop (actor-cell)
  (:documentation "Stops the actor-cell."))

;; ---------------------------------
;; Impl
;; ---------------------------------

(defmethod pre-start ((self actor-cell) state)
  "Empty implementation so that we can call it anyway even if there are no other implementations."
  (declare (ignore state))
  nil)

(defmethod after-stop ((self actor-cell))
  "Empty implementation so that we can call it anyway even if there are no other implementations."
  nil)

(defun call (actor-cell message &key (time-out nil))
  "Send a message to a actor-cell instance and wait for a result.
Specify a timeout in seconds if you require a result within a certain period of time.
Be aware though that this is a resource intensive wait based on a waiting thread.
The result can be of different types.
Success result: <returned-state>
Unhandled result: `:unhandled'
Error result: `(cons :handler-error <condition>)'
In case of time-out the error condition is a bt:timeout."
  (when message
    (let ((result (submit-message actor-cell message t nil time-out)))
      (log:debug "Message process result:" result)
      result)))

(defun cast (actor-cell message)
  "Sends a message to a actor-cell asynchronously. There is no result."
  (when message
    (let ((result (submit-message actor-cell message nil nil nil)))
      (log:debug "Message process result: ~a" result)
      result)))  

(defun running-p (actor-cell)
  "Returns true if this server is running. `nil' otherwise."
  (with-slots (internal-state) actor-cell
    (slot-value internal-state 'running)))

(defmethod stop ((self actor-cell))
  (log:debug "Stopping on actor-cell: ~a" self)
  (with-slots (msgbox internal-state) self
    (when (slot-value internal-state 'running)
      (mesgb:stop msgbox)
      (setf (slot-value internal-state 'running) nil)
      (after-stop self))))

;; -----------------------------------------------    
;; internal functions
;; -----------------------------------------------

(defun submit-message (actor-cell message withreply-p sender time-out)
  "Submitting a message.
In case of `withreply-p', the `response' is filled because submitting to the message-box is synchronous.
Otherwise submitting is asynchronous and `response' is just `t'.
In case the actor-cell was stopped it will respond with just `:stopped'.
In case no messge-box is configured this function respnds with `:no-message-handling'."
  (log:debug "Submitting message: ~a" message)
  (log:debug "Withreply: ~a" withreply-p)
  (log:debug "Sender: ~a" sender)
  (log:debug "Timeout: ~a" time-out)

  (with-slots (internal-state msgbox) actor-cell
    (unless (actor-cell-state-running internal-state)
      (return-from submit-message :stopped))
    (unless msgbox
      (return-from submit-message :no-message-handling)))

  (handler-case
      (mesgb:with-submit-handler
          ((slot-value actor-cell 'msgbox)
           message
           withreply-p
           time-out)
          (process-response actor-cell
                            (handle-message actor-cell message withreply-p)
                            sender))
    (t (c)
      (log:error "Condition raised: " c)
      (process-response actor-cell
                        (cons :handler-error c)
                        sender))))

(defun process-response (actor-cell handle-result sender)
  (log:debug "Processing handle-result: ~a" handle-result)
  (case handle-result
    (:stopping (progn
                 (stop actor-cell)
                 :stopped))
    (t (progn
         (when sender
           (progn
             (log:debug "We have a sender. Send the response back to: ~a" sender)
             (cast sender handle-result)))
         handle-result))))

;; ------------------------------------------------
;; message handling ---------------------
;; ------------------------------------------------

(defun handle-message (actor-cell message withreply-p)
  "This function is submitted as `handler-fun' to message-box"
  (log:debug "Handling message: ~a" message)
  (when message
    (handler-case
        (let ((internal-handle-result (handle-message-internal message)))
          (case internal-handle-result
            (:resume (handle-message-user actor-cell message withreply-p))
            (t internal-handle-result)))
      (t (c)
        (log:warn "Error condition was raised: " c)
        (cons :handler-error c)))))

(defun handle-message-internal (msg)
  "A `:stop' message will response with `:stopping' and the user handlers are not called.
Otherwise the result is `:resume' to resume user message handling."
  (log:debug "Internal handle-call: ~a" msg)
  (case msg
    (:stop :stopping)
    (t :resume)))

(defun handle-message-user (actor-cell message withreply-p)
  "This will call the method 'handle-call' with the message."
  (log:debug "User handle message: " message)
  (let* ((current-state (slot-value actor-cell 'state))
         (handle-result
           (if withreply-p
               (progn
                 (log:trace "Calling handle-call on: ~a" actor-cell)
                 (handle-call actor-cell message current-state))
               (progn
                 (log:trace "Calling handle-cast on: ~a" actor-cell)
                 (handle-cast actor-cell message current-state)))))
    (log:debug "Current-state: ~a" (slot-value actor-cell 'state))
    (cond
      (handle-result
       (process-handler-result handle-result actor-cell))
      (t
       (process-not-handled)))))

(defun process-handler-result (handle-result actor-cell)
  (log:debug "Message handled, result: ~a" handle-result)
  (cond
    ((consp handle-result)
     (progn
       (update-state actor-cell handle-result)
       (reply-value handle-result)))
    (t
     (progn
       (log:warn "handle-call result is no cons.")
       (cons :handler-error "handle-call result is no cons!")))))

(defun process-not-handled ()
  (log:debug "Message not handled.")
  :unhandled)

(defun update-state (actor-cell cons-result)
  (let ((new-state (cdr cons-result)))
    (setf (slot-value actor-cell 'state) new-state)
    (slot-value actor-cell 'state)))

(defun reply-value (cons-result)
  (car cons-result))
