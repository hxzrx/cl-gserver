(in-package :sento.queue)

;; ----------------------------------------
;; - unbounded queue using locks
;; ----------------------------------------

#|
The queue is a simple queue that is not thread-safe.
It is based on 2 stacks, one for the head and one for the tail.
When the tail is empty, the head is reversed and pushed to the tail.
This is from the book "Programming Algorithms in Lisp" by Vsevolod Domkin.

This queue is fast, but requires a lot of memory. Roughly 1/3 more
than the 'queue' implementation of lparallel.
|#

(defstruct queue
  (head '() :type list)
  (tail '() :type list))

(defun enqueue (item queue)
  (push item (queue-head queue)))

(defun dequeue (queue)
  (declare (optimize
            (speed 3)
            (safety 0)
            (debug 0)
            (compilation-speed 0)))
  (unless (queue-tail queue)
    (do ()
        ((null (queue-head queue)))
      (push (pop (queue-head queue))
            (queue-tail queue))))
  (when (queue-tail queue)
    (values (pop (queue-tail queue))
            t)))

(defun emptyp (queue)
  (not (or (queue-head queue)
           (queue-tail queue))))


#|
queue implementation from lparallel.
Copyright (c) 2011-2012, James M. Lawrence. All rights reserved.

|#

;; (defstruct queue
;;   (head '() :type list)
;;   (tail '() :type list))

;; (defun enqueue (item queue)
;;   (declare (optimize
;;             (speed 3) (safety 0) (debug 0)
;;             (compilation-speed 0)))
;;   (let ((new (cons item nil)))
;;     (if (queue-head queue)
;;         (setf (cdr (queue-tail queue)) new)
;;         (setf (queue-head queue) new))
;;     (setf (queue-tail queue) new)))

;; (defun dequeue (queue)
;;   (declare (optimize
;;             (speed 3) (safety 0) (debug 0)
;;             (compilation-speed 0)))
;;   (let ((item (queue-head queue)))
;;     (if item
;;         (multiple-value-prog1 (values (car item) t)
;;           (when (null (setf (queue-head queue) (cdr item)))
;;             (setf (queue-tail queue) nil))
;;           ;; clear item for conservative gcs
;;           (setf (car item) nil
;;                 (cdr item) nil))
;;         (values nil nil))))

;; (defun emptyp (queue)
;;   (not (queue-head queue)))

;; ------- thread-safe queue --------

(defclass queue-unbounded (queue-base)
  ((queue :initform (make-queue))
   (lock :initform (bt:make-lock))
   (cvar :initform (bt:make-condition-variable)))
  (:documentation "Unbounded queue."))

(defmethod pushq ((self queue-unbounded) element)
  (with-slots (queue lock cvar) self
    (bt:with-lock-held (lock)
      (enqueue element queue)
      (bt:condition-notify cvar))))

(defmethod popq ((self queue-unbounded))
  (with-slots (queue lock cvar) self
    (bt:with-lock-held (lock)
      (loop (multiple-value-bind (value presentp)
                (dequeue queue)
              (if presentp
                  (return value)
                  (bt:condition-wait cvar lock)))))))

(defmethod emptyq-p ((self queue-unbounded))
  (with-slots (queue) self
    (emptyp queue)))
