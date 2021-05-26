
(in-package :cl-gserver.actor-context)

(defun make-actor-context (actor-system &optional (id nil))
  "Creates an `actor-context`. Requires a reference to `actor-system`
`id` is an optional value that can identify the `actor-context`.
Creating an actor-context manually is usually not needed.
An `asys:actor-system` implements the `actor-context` protocol.
An `act:actor` contains an `actor-context`."
  (let ((context (make-instance 'actor-context :id id)))
    (with-slots (system) context
      (setf system actor-system))
    context))

(defun get-shared-dispatcher (system identifier)
  (getf (asys:dispatchers system) identifier))

(defun add-actor (context actor)
  (with-slots (actors) context
    (setf actors
          (hamt:dict-insert actors (act-cell:name actor) actor)))
  actor)

(defun remove-actor (context actor)
  (with-slots (actors) context
    (setf actors
          (hamt:dict-remove actors (act-cell:name actor)))))

(defun message-box-for-dispatch-type (context dispatch-type queue-size)
  (case dispatch-type
    (:pinned (make-instance 'mesgb:message-box/bt))
    (otherwise (let ((dispatcher (get-shared-dispatcher (system context) dispatch-type)))
                 (unless dispatcher
                   (error (format nil "No such dispatcher identifier '~a' exists!" dispatch-type)))
                 (make-instance 'mesgb:message-box/dp
                                :dispatcher dispatcher
                                :max-queue-size queue-size)))))

(defun verify-actor (context actor)
  "Checks certain things on the actor before it is attached to the context."
  (let* ((actor-name (act-cell:name actor))
         (exists-actor-p (find-actor-by-name context actor-name)))
    (when exists-actor-p
      (log:error "Actor with name '~a' already exists!" actor-name)
      (error (make-condition 'actor-name-exists :name actor-name)))))

(defun create-actor (context create-fun dispatch-type queue-size)
  (let ((actor (funcall create-fun)))
    (when actor
      (verify-actor context actor)
      (act::initialize-with actor
       (message-box-for-dispatch-type context dispatch-type queue-size)
       (make-actor-context (system context)
                           (utils:mkstr (id context) "/" (act-cell:name actor)))))
    actor))

(defmethod actor-of ((self actor-context) create-fun &key (dispatch-type :shared) (queue-size 0))
  "See `ac:actor-of`"
  (let ((created (create-actor self create-fun dispatch-type queue-size)))
    (when created
      (act:watch created self)
      (add-actor self created))))

(defmethod find-actors ((self actor-context) test-fun)
  "See `ac:find-actors`"
  (utils:filter test-fun (all-actors self)))

(defmethod find-actor-by-name ((self actor-context) name)
  "See `ac:find-actor-by-name`"
  (hamt:dict-lookup (actors self) name))

(defmethod all-actors ((self actor-context))
  "See `ac:all-actors`"
  (hamt:dict-reduce (lambda (acc key val)
                      (declare (ignore key))
                      (cons val acc))
                    (actors self)
                    '()))

(defmethod stop ((self actor-context) actor)
  "See `ac:stop`"
  (act-cell:stop actor))

(defmethod shutdown ((self actor-context))
  "See `ac:shutdown`"
  (dolist (actor (all-actors self))
    (act-cell:stop actor)))

(defmethod notify ((self actor-context) actor notification)
  (case notification
    (:stopped (remove-actor self actor))))
