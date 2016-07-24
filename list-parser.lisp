(ql:quickload :utils)
(use-package :utils)

(defparameter *list-parse-rule-table* (make-hash-table))

(defun parse-list (expression list &optional (pos 0))
  (cond
    ;; Expression is nil
    ((null expression) (null list))
    ;; Expression is a named rule (without args)
    ((symbolp expression) (let ((fun (gethash expression *list-parse-rule-table*)))
                      (if fun
                          (funcall fun list pos)
                          (error (format nil "Unknown rule `~a'." expression)))))
    ((listp expression) (let ((fun (gethash (first expression) *list-parse-rule-table*)))
                    (if fun
                        (apply fun list pos (rest expression))
                        (error "Unknown rule."))))
    ))

(defun quoted-symbol-p (x)
  (and (listp x) (l= x 2) (eql (first x) 'quote) (symbolp (second x))))

(defmacro test-and-advance (test expr pos &optional (inc 1))
  `(with-gensyms (result ret)
     `(let ((,result ,,test) (,ret ,,expr))
        (when ,result
          (incf ,,pos ,,inc)
          ,ret))))

(defmacro try-and-advance (test pos)
  `(with-gensyms (result success newpos)
     `(multiple-value-bind (,result ,success ,newpos) ,,test
        (when ,success
          (setf ,,pos ,newpos)
          ,result))))

;; Expansion functions -----------------------------------------------

;; These are helper functions for the defrule macro.
;; Therefore, the functions contain macro code and need to be treated as such.
;; All take the list that should be parsed as `expr', the parsing `rule',
;; the current `pos'ition in the list as well as the `arg'uments to the defrule.
;; The intent is to generate lisp code for parsing.
;; They return two values: The portion of the `expr' that was parsed, and a success value

(defun expand-atom (expr rule pos args)
  (cond
    ;; Is a quoted symbol
    ((quoted-symbol-p rule) (test-and-advance `(eql (nth ,pos ,expr) ,rule) `(nth ,pos ,expr) pos))
    ;; Is a lambda variable
    ((and (symbolp rule) (have rule args)) (test-and-advance `(eql (nth ,pos ,expr) (second ,rule)) `(nth ,pos ,expr) pos))
    ;; Is a call to another rule (without args)
    ((symbolp rule) (try-and-advance `(parse-list ',rule ,expr ,pos) pos))
    ))

(defun expand-or (expr rule pos args)
  `(cond
     ,@(loop for r in rule collect (list (expand-rule expr r pos args)))))

(defun expand-and (expr rule pos args)
  ;; Create gensyms for the list of results, the individual result and the block to return from when short-circuiting
  (with-gensyms (list result block oldpos)
    ;; Block to return from when short-circuiting
    `(block ,block
       ;; Initialize the list of results
       (let (,list (,oldpos ,pos))
         ;; Loop over the rules
         ,@(loop for r in rule for n upfrom 0 collect
                ;; Bind a variable to the result of the rule expansion
                `(let ((,result ,(expand-rule expr r pos args)))
                   ;; If the result is nil, return nil
                   (unless ,result
                     (setf ,pos ,oldpos)
                     (return-from ,block))
                   ;; Otherwise append the result
                   (appendf ,list ,result)))))))

(defun expand-not (expr rule pos args)
  (with-gensyms (oldpos result)
    ;; Save the current position
    `(let ((,oldpos ,pos))
       ;; If the rule ...
       (if ,(expand-rule expr rule pos args)
           ;; is successful
           (progn
             ;; Roll back the position
             (setf ,pos ,oldpos)
             ;; Return nil
             nil)
           ;; fails
           (let ((,result (nth ,pos ,expr)))
             ;; Advance the position by one
             (incf ,pos)
             ,result)))))

(defun expand-* (expr rule pos args)
  (with-gensyms (ret)
       `(loop for ,ret = ,(expand-rule expr rule pos args) while ,ret collect ,ret)))

(defun expand-parse-call (expr rule pos args)
  ;; Makes a call to `parse-list' with or without quoting the rule arguments depending on whether they are arguments to the current rule
  `(parse-list `(,,@(loop for r in rule for n upfrom 0 collect (if (and (plusp n) (have r args)) r `(quote ,r)))) ,expr ,pos))

(defun expand-list-expr (expr rule pos args)
  ;; Rule is ...
  (case (first rule)
    ;; an OR expression
    (or (expand-or expr (rest rule) pos args))
    ;; an AND expression
    (and (expand-and expr (rest rule) pos args))
    ;; a NOT expression
    (not (expand-not expr (second rule) pos args))
    ;; a * expression
    (* (expand-* expr (second rule) pos args))
    ;; a call to another rule (with args)
    (t (try-and-advance (expand-parse-call expr rule pos args) pos))))

(defun expand-rule (expr rule pos args)
  ;; Rule is
  (cond
    ;; ... nil
    ((null rule) (expand-atom expr nil pos nil))
    ;; ... an atom
    ((atom rule) (expand-atom expr rule pos args))
    ;; ... a quoted symbol
    ((quoted-symbol-p rule) (expand-atom expr rule pos args))
    ;; ... a list expression
    (t (expand-list-expr expr rule pos args))))

;; defrule macro --------------------------------------------------------------

(defmacro defrule (name lambda-list expr)
  ;; Creates a lambda function that parses the given grammar rules.
  ;; It then stores the lambda function in the global list *list-parse-rule-table*,
  ;; therefore the rule functions use a namespace separate from everything
  (with-gensyms (x pos oldpos result)
    ;; Save the lambda function in the namespace table
    `(setf (gethash ',name *list-parse-rule-table*)
           ;; The lambda function that parses according to the given grammar rules
           #'(lambda (,x ,pos ,@lambda-list)
               ;; Save the previous parsing position and get the parsing result
               (let ((,oldpos ,pos) (,result ,(expand-rule x expr pos lambda-list)))
                 ;; If parsing was successful ...
                 (if ,result
                     ;; Return the parsing result, the success and the new position
                     (values ,result t ,pos)
                     ;; Return nil as parsing result, failure and the old position
                     (values nil nil ,oldpos)))))))

;; Tryout area ----------------------------------------------------------------

(defrule hello-world () (and 'hello 'world))
(defrule hey-you () (and 'hey 'you))
(defrule hey-x (x) (and 'hey x))
(defrule test () (or hey-you hello-world))
(defrule test-x (x) (or (hey-x x) hello-world))
(defrule test-y () (or (hey-x 'y) hello-world))
(defrule test-or-and () (or (and 'hello 'you) (and 'hello 'world)))
(defrule test* () (* 'a))

(parse-list 'test* '())
(parse-list 'test* '(a a a a))
(parse-list 'test '(hello you))
(parse-list 'test '(hello world))
(parse-list '(hey-x 'yo) '(hey yo))
(parse-list '(test-x 'w) '(hey w))
(parse-list '(test-x 'w) '(hello world))
(parse-list 'test-y '(hey y))
(parse-list 'test-y '(hello world))
(parse-list 'test-or-and '(hello you))
(parse-list 'test-or-and '(hello world))

;; Test area ------------------------------------------------------------------

(defrule sym () 'a)
(defrule and () (and 'a 'b 'c))
(defrule or () (or 'a 'b 'c))
(defrule not () (not 'a))
(defrule var (x) x)
(defrule nest () sym)

(defun test-parse-list (expression list success)
  (multiple-value-bind (result success-p pos) (parse-list expression list)
    (declare (ignore result pos))
    (xnor success success-p)))

(define-test symbol-test ()
  (check
    (test-parse-list 'sym '(a) t)
    (test-parse-list 'sym '(b) nil)))

(define-test and-test ()
  (check
    (test-parse-list 'and '(a b c) t)
    (test-parse-list 'and '(a b) nil)
    (test-parse-list 'and '(a c) nil)
    (test-parse-list 'and '(a) nil)))

(define-test or-test ()
  (check
    (test-parse-list 'or '(a) t)
    (test-parse-list 'or '(b) t)
    (test-parse-list 'or '(c) t)
    (test-parse-list 'or '(d) nil)))

(define-test not-test ()
  (check
    (test-parse-list 'not '(a) nil)
    (test-parse-list 'not '(b) t)
    (test-parse-list 'not '(c) t)
    (test-parse-list 'not '(d) t)))

(define-test var-test ()
  (check
    (test-parse-list '(var 'a) '(a) t)
    (test-parse-list '(var 'a) '(b) nil)))

(define-test nesting-test ()
  (check
    (test-parse-list 'nest '(a) t)
    (test-parse-list 'nest '(b) nil)))

(define-test parse-list-test ()
  (check
    (symbol-test)
    (and-test)
    (or-test)
    (not-test)
    (var-test)
    (nesting-test)
))

(parse-list-test)
