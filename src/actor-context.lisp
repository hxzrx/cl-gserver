(defpackage :cl-gserver.actor-context
  (:use :cl)
  (:nicknames :ac)
  (:export #:actor-context
           #:make-actor-context
           #:actor-of
           #:find-actors
           #:all-actors
           #:system
           #:shutdown))
(in-package :cl-gserver.actor-context)

(defclass actor-context ()
  ((actors :initform (make-array 50 :adjustable t :fill-pointer 0)
           :reader actors
           :documentation "A list of actors.")
   (system :initform nil
           :reader system
           :documentation "A reference to the `actor-system'."))
  (:documentation "Actor context deals with creating and adding actors in classes that inherit `actor-context'."))

(defun make-actor-context (actor-system)
  (let ((context (make-instance 'actor-context)))
    (with-slots (system) context
      (setf system actor-system))
    context))

(defgeneric actor-of (actor-context create-fun &key dispatch-type)
  (:documentation "Creates and adds actors to the given context.
Specify the dispatcher type (`disp-type') as either:
`:shared' to have this actor use the shared message dispatcher of the context
`:pinned' to have this actor run it's own message box thread (faster, but more resource are bound.)"))

(defgeneric find-actors (actor-context find-fun)
  (:documentation "Returns actors where `find-fun' provides 'truth'."))

(defgeneric all-actors (actor-context)
  (:documentation "Retrieves all actors as a list"))

(defgeneric shutdown (actor-context)
  (:documentation "Stops all actors in this context."))

;; --------------------------------------------

(defun get-shared-dispatcher (system)
  (getf (system-api:dispatchers system) :shared))

(defun add-actor (context actor)
  (vector-push-extend actor (actors context))
  actor)

(defun message-box-for-dispatch-type (dispatch-type context)
  (case dispatch-type
    (:pinned (make-instance 'mesgb:message-box-bt))
    (otherwise (make-instance 'mesgb:message-box-dp
                              :dispatcher (get-shared-dispatcher (system context))
                              :max-queue-size 0))))

(defun make-actor (context create-fun dispatch-type)
  (let ((actor (funcall create-fun)))
    (when actor
      (setf (act-cell:msgbox actor) (message-box-for-dispatch-type dispatch-type context)))
    actor))

(defmethod actor-of ((self actor-context) create-fun &key (dispatch-type :shared))
  (let ((created (make-actor self create-fun dispatch-type)))
    (when created
      (add-actor self created))))

(defmethod find-actors ((self actor-context) find-fun)
  (mapcan (lambda (x) (if (funcall find-fun x) (list x))) (all-actors self)))

(defmethod all-actors ((self actor-context))
  (coerce (actors self) 'list))

(defmethod shutdown ((self actor-context))
  (dolist (actor (all-actors self))
    (act-cell:stop actor)))
