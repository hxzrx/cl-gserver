
(in-package :cl-gserver.dispatcher)

(shadowing-import '(mesgb:message-box/bt
                    act:actor))

(defun make-dispatcher (actor-context &key (num-workers 1) (identifier (gensym "disp-")))
  "Default constructor.
This creates a `disp:shared-dispatcher` with `num-workers` number of workers and the given `identifier` which represents a distinguishable name.
Each worker is based on a `:pinned` actor meaning that it has its own thread.
Specify an `ac:actor-context` where actors needed in the dispatcher are created in."
  (make-instance 'shared-dispatcher
                 :num-workers num-workers
                 :context actor-context
                 :identifier identifier))

(defclass dispatcher-base ()
  ((context :initform nil
            :initarg :context)
   (identifier :initform nil
               :initarg :identifier))
  (:documentation
   "A `dispatcher` contains a pool of `actors` that operate as workers where work is dispatched to.
However, the workers are created in the given `ac:actor-context`."))

;; ---------------------------------
;; Shared dispatcher
;; ---------------------------------

(defclass shared-dispatcher (dispatcher-base)
  ((router :initform (router:make-router :strategy :random)))
  (:documentation
   "A shared dispatcher.
Internally it uses a `router:router` to drive the `dispatch-worker`s.
The default strategy of choosing a worker is `:random`.

A `shared-dispatcher` is automatically setup by an `asys:actor-system`."))

(defmethod initialize-instance :after ((self shared-dispatcher) &key (num-workers 1))
  (with-slots (router context identifier) self
    (loop :for n :from 1 :to num-workers
          :do (router:add-routee router (make-dispatcher-worker n context identifier)))))

(defmethod print-object ((obj shared-dispatcher) stream)
  (print-unreadable-object (obj stream :type t)
    (with-slots (router identifier) obj
      (format stream "ident: ~a, workers: ~a, strategy: ~a"
              identifier
              (length (router:routees router))
              (router:strategy-fun router)))))

(defmethod workers ((self shared-dispatcher))
  (with-slots (router) self
    (router:routees router)))

(defmethod stop ((self shared-dispatcher))
  (with-slots (router) self
    (router:stop router)))

(defmethod dispatch ((self shared-dispatcher) dispatch-exec-fun)
  (with-slots (router) self
    (router:ask-s router (cons :execute dispatch-exec-fun))))

(defmethod dispatch-async ((self shared-dispatcher) dispatch-exec-fun)
  (with-slots (router) self
    (router:tell router (cons :execute dispatch-exec-fun))))


;; ---------------------------------
;; the worker
;; ---------------------------------

(defclass dispatch-worker (actor) ()
  (:documentation
   "Specialized `actor` used as `worker` is the message `dispatcher`."))

(defun make-dispatcher-worker (num actor-context dispatcher-ident)
  "Constructor for creating a worker.
`num` only has the purpose to give the worker a name which includes a number.
`dispatcher-ident is the dispatcher identifier."
  (ac:actor-of actor-context
    (lambda ()
      (act:make-actor #'receive
                      :type 'dispatch-worker
                      :name (format nil "dispatch(~a)-worker-~a" dispatcher-ident num)))
    :dispatch-type :pinned))

(defun receive (self message current-state)
  "The worker receive function."
  (assert (consp message) nil (format t "~a: Message must be a `cons'!" (act-cell:name self)))
  (case (car message)
    (:execute (cons (funcall (cdr message)) current-state))))
