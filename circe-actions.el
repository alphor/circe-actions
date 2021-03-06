;;; -*- lexical-binding: t -*-

;;; circe-actions.el --- Callback primitives for circe events


;; Author: alphor
;; Version: 0.0.5
;; Keywords: circe callback handler

;; Utility functions for interfacing with circe-irc-handler-table

(require 'irc)
(require 'circe)

(defgroup circe-actions nil
  "Convenient interface to circe events"
  :group 'convenience)


(defcustom circe-actions-maximum-handlers 3
  "Do not allow more than this many active handlers. This number is
   compared against circe-actions-handlers-alist's length. Once it is
   greater than or equal to the length of the alist, ignore any
   requests to add more to the queue, instead alert the user with a
   message."
  :group 'circe-actions
  :type 'integer)

(defvar circe-actions-handlers-alist '()
  "Store all the symbols of the generated event handlers here. The
  symbols assigned to any circe-action should be uninterned so that
  they do not pollute the function namespace (as an arbitrary number
  are generated)

  The values corresponding to the symbols are the handlers they are on.")

;; circe-actions-generate-handler-function returns functions that are
;; primarily designed to deal with irc.message-like events (irc.ctcp
;; is also included). Later on it may be necessary to change this.

(defconst circe-actions-default-event-signature
  (list :server-proc :event :fq-username :target :contents)
  "Default list of symbols obtained if there is no match in circe-actions-event-plists for the event.")

;; should be set to nil and populated on circe-actions-enable?
;; isn't that what autoload does?
(defvar circe-actions-event-plists
  (let ((hash-table (make-hash-table :test 'equal)))
    (puthash "irc.message" circe-actions-default-event-signature hash-table)
    hash-table))
    

(defun circe-actions-generate-handler-function
    (condition-p-function action-function symbol event &optional persist)
  "Produce (and return) a procedure aliased to a SYMBOL that executes
  ACTION-FUNCTION when CONDITION-P-FUNCTION

SYMBOL should be uninterned, but doesn't have to be. This is not the
same symbol passed to circe-actions-register.
EVENT is a string key, like irc.message obtained from circe-irc-handler-table

if PERSIST is non-nil, do not remove the symbol from the handler
obtained from circe-actions-handlers-alist, do not remove the handler
from (circe-irc-handler-table), do not pass go.

PERSIST is a dangerous flag to set. If you pass in an expensive
condition or action, paired with a high occurence rate event, your
emacs system will slow to a crawl, and the only way to deactivate it
is through an interactive circe-actions-deactivate-function call, or
by calling circe-actions-panic, which deactivates all handlers
indiscriminately.

CONDITION-P-FUNCTION and ACTION-FUNCTION must be procedures that have
the same event signature as the event it handles, as described in
circe-actions-event-plists. In the case of \"irc.message\", it should
take in a list of arguments (to be optionally processed by
`circe-actions-plistify')

server-proc - usually the result of (circe-server-process)
event - the event, ie irc.message or a ctcp ping
fq-username - the username followed by cloak in whois format
channel - channel or, if channel is your nick, a query
contents - text payload of the event"
  (defalias symbol
    (lambda (server-proc event &rest rest-args)
      (let ((args (cons server-proc (cons event rest-args))))
        (condition-case-unless-debug err
            (when (apply condition-p-function args)
              (unless persist
                (circe-actions-deactivate-function symbol event))
              (apply action-function args))
          (error
           (circe-actions-deactivate-function symbol event)
           (error "Callback failed with error: %s"
                    (error-message-string err))))))))

(defun circe-actions-deactivate-function (handler-function event)
  "Remove HANDLER-FUNCTION from EVENT bucket in circe-irc-handler-table, and remove it from the alist, in that order."
  ;; the order of these are significant, for reasons similar but opposite
  ;; see the comments in circe-actions-activate-function
  (irc-handler-remove (circe-irc-handler-table)
		      event
		      handler-function)
  (setq circe-actions-handlers-alist
	(delete (assoc handler-function circe-actions-handlers-alist)
		circe-actions-handlers-alist)))
	
(defun circe-actions-activate-function (handler-function event)
  "Given a HANDLER-FUNCTION created by
  circe-actions-generate-handler-function, get the symbol associated
  with it. If the length of circe-actions-handlers-alist exceeds
  circe-actions-maximum-handlers, message the user the length of the
  list and the symbol of the handler-function that was attempted to be
  activated.

Otherwise, add the HANDLER-FUNCTION to the
circe-actions-handlers-alist (with a key of symbol and EVENT), then
place it at event in the hash-table obtained from circe's irc handler table."
  (let ((alist-len (length circe-actions-handlers-alist)))
    (if (>= alist-len circe-actions-maximum-handlers)
	(warn "circe-actions: Handler tolerance of %s exceeded, nothing added to %s! Clear active handlers or increase circe-actions-maximum-handlers to continue."
              circe-actions-maximum-handlers
              event)
      (progn
        ;; the order of these are significant, especially when considering
        ;; that if you put it on the handler table first, the event may fire
        ;; before the event is actually added to the handler alist, which
        ;; means the handler will probably error during deactivation
        
	;; add the handler-function to the list
	(setq circe-actions-handlers-alist
	      (cons (list handler-function event) circe-actions-handlers-alist))
	;; add the handler-function to the event table. The function
	;; is now called everytime event occurs.
	(irc-handler-add (circe-irc-handler-table)
			 event
			 handler-function)))))

(defun circe-actions--gensym ()
  (gensym "circe-actions-gensym-"))

(defun circe-actions-register (event condition-p-function action-function &optional persist)
  "Given a CONDITION-P-FUNCTION and ACTION-FUNCTION that takes args
  consistent with the EVENT passed (as shown in the README.):

1) generate a procedure that executes ACTION-FUNCTION when CONDITION-P-FUNCTION
2) place it and its associated event on circe-actions-handlers-alist
3) place it on the bucket corresponding to event in (circe-irc-handler-table)

If persist is set, the procedure does not remove itself after being
called once. This is potentially very dangerous if your condition
function is computationally expensive (or, y'know, monetarily
expensive). Be careful!"
  (let* ((arg-list (append (list condition-p-function
				 action-function
				 (circe-actions--gensym)
				 event)
			   (list persist))) ; if unset, persist is nil, the empty list
	 (handler-function (apply 'circe-actions-generate-handler-function
				  arg-list)))
    ;; to gain introspection, pass in condition function, activate function.
    ;; then this allows us to add in the prin1-to-string forms to allow printing
    ;; of the expressions so that we can inspect them while they are active.
    ;; we can use this to deactivate them by symbol quickly
    ;; possibly with completing-read, and a default value of our gensym.
    ;; this complicates the activate-function interface, if implemented
    ;; could  be implemented as an optional two arguments.
    (circe-actions-activate-function handler-function event)))

(defun circe-actions-is-active-p (handler-function event)
  "Check if the handler function is on the handler table, and on the
internal alist using equal.
   Error if exclusively one of these are true"
  (let ((on-handler-table
         (circe-actions-handler-is-on-handler-table-p handler-function event))
        (on-alist
         (circe-actions-handler-is-on-alist-p handler-function event)))
    (when (circe-actions--xor on-handler-table on-alist)
        (error "Exceptional event! ht: %s al: %s hf: %s ev: %s"
               on-handler-table
               on-alist
               handler-function
               event))
    (and on-handler-table on-alist)))

(defun circe-actions-handler-is-on-alist-p (handler-function event)
  (member (list handler-function event)
	  circe-actions-handlers-alist))

(defun circe-actions-handler-is-on-handler-table-p (handler-function event)
  (member handler-function
	(gethash event (circe-irc-handler-table))))

(defun circe-actions-panic ()
  "Iterate through circe-actions-handlers-alist, deactivating all the
functions stored in the alist. This is the function you want to run if
something is causing errors constantly"
  (interactive)
  (mapc (lambda (handler-list)
	    (let ((handler (car handler-list))
		  (event (cadr handler-list)))
	      (circe-actions-deactivate-function handler event)))
	  circe-actions-handlers-alist)
  (message "All handlers cleared!"))

;; -------------------- generalized plistify function --------------------

(defun circe-actions-plistify (arglist &optional event)
  "Given an event, obtain the event signature list from
  `circe-actions-event-plists', interleave the arglist with whatever
  was obtained, and return it. The result is a plist. If no event
  given, attempt to get the event from the arglist. Example:

  ;; calling
  (circe-actions-plistify '((circe-server-process)
                             \"irc.message\"
                             \"alphor!@~...\"
                             \"#freenode\"
                             \"Meow!\")
                             \"irc.message\")

  ;; yields this
  '(:server-proc (circe-server-process)
    :event \"irc.message\"
    :fq-username \"alphor!@~...\"
    :channel \"#freenode\"
    :contents \"Meow!\"))

"
  (unless event
    (setq event (nth 1 arglist))) ; if event is not set, obtain it from the arglist.
  (circe-actions--interleave (gethash event
                                      circe-actions-event-plists
                                      circe-actions-default-event-signature)
                             arglist))

(defun circe-actions--xor (bool-1 bool-2)
  (or (and bool-1 (not bool-2))
      (and (not bool-1) bool-2)))
           
(defun circe-actions--interleave (list-1 list-2)
  "-interleave from dash.el does exactly this, but expanding the
  dependency graph just for this one use is a cost I'm not willing to
  pay. Error message reflects usage in circe-actions-plistify."
  (let ((xor-func (lambda (bool-1 bool-2)
                    (or (and bool-1 (not bool-2))
                        (and (not bool-1) bool-2))))
        (list-1-null (null list-1))
        (list-2-null (null list-2)))
    (cond ((circe-actions--xor list-1-null list-2-null)
           (error "circe-actions-plistify didn't plistify this event correctly! plist-keys: %s \n arglist: %s" list-1 list-2))
          ((null list-1) nil)
          (t
           (cons (car list-1)
                 (cons (car list-2)
                       (circe-actions--interleave (cdr list-1)
                                                  (cdr list-2))))))))

(defvar circe-actions--symbol-regexp
  "^%s\\(.+\\)"
  "To be formatted with prefix. Captures whatever's beyond the prefix")

;; this is a little hackish. 
;; I would've split this up into a predicate and function were it not
;; for the implicit state carried around here. Emacs is weird.
(defun circe-actions--replace-prefixed-string (str prefix)
  "If SYMBOL is prefixed by PREFIX, return a new string fit for use in a plist. "
  (let ((reg (format circe-actions--symbol-regexp prefix)))
    (when (string-match reg str)
      (format ":%s" (match-string 1 str)))))

(defvar circe-actions-default-prefix
  ":"
  "Default prefix that transforms symbols in a sexp contained in a
  with-circe-actions-closure call. Either set this or set PREFIX during a call to with-circe-actions-closure")

(defun circe-actions--deep-map-kw (func tree)
  "Trawl tree, applying func to each keyword. Keywords are symbols
starting with ':'."
  (cond ((null tree) nil)
        ((listp tree) (cons (circe-actions--deep-map-kw func (car tree))
                            (circe-actions--deep-map-kw func (cdr tree))))
        ((keywordp tree) (funcall func tree))
        ;; if it's none of these it's just a constant. No biggie.
        (t tree)))

;; this is also hack-ish. In order to share state between the macro to
;; generate the lambda we got to name easy-args _something_. Maybe
;; namespace symbol as circe-actions--reserved
(defun circe-actions--transform-kw (keyword prefix)
  "If (circe-actions--replace-prefixed-string SYMBOL prefix) returns non-nil, wrap the result with a plist-get call on the symbol easy-args. This symbol is populated in the closure. Otherwise just return the symbol."
  (let ((result-str (circe-actions--replace-prefixed-string (symbol-name keyword)
                                                            prefix)))
    (if result-str
        `(plist-get circe-actions--plistified-args ,(intern result-str))
      keyword)))

;;   "If first arg is a string, use string as prefix to transform callbacks. Otherwise, use `circe-actions-default-prefix'. 

;;   Given a sexp, traverse the sexp looking for symbols that match the given PREFIX, replacing it with a form that pulls out the needed argument.

;; An example:
;; (with-circe-actions-closure
;;   (string-prefix-p \"fsbot\" :fq-username))

;; returns:
;; (lambda (&rest args)
;;   (let ((easy-args (circe-actions-plistify args)))
;;     (string-prefix-p \"fsbot\" (plist-get easy-args :fq-username))))

;; This is a function that is fit for registering on circe's handler table."
(defmacro with-circe-actions-closure (&rest args)
  (let* ((args (circe-actions--normalize-args args))
         (prefix (or (plist-get args :prefix)
                     circe-actions-default-prefix))
         (event (plist-get args :signature))
         (expr (plist-get args :expr))
         (transform-curry (lambda (keyword)
                            (circe-actions--transform-kw keyword prefix))))
    `(lambda (&rest circe-actions--args)
       (let ((circe-actions--plistified-args
              (circe-actions-plistify circe-actions--args ,event)))
         ,(circe-actions--deep-map-kw transform-curry expr)))))

  

(defun circe-actions--normalize-args (args)
  (let ((head (car args)))
    (cond ((null head) nil)
          ;; check for reserved keywords
          ((or (equal head :prefix)
               (equal head :signature)
               (equal head :expr))
           ;; parse them specially
           (cond ((< (length args) 2)
                  (error "Keyword %s with no value!" head))
                 ((keywordp (cadr args))
                  (error "Keyword %s followed by other keyword %s"
                         head
                         (cadr args)))
                 ((equal head :expr)
                  ;; hm. issue here is :expr can be followed by just :contents
                  ;; or even an atom! Not going to validate the contents.
                  
                  ;; although evaluating atoms doesn't really
                  ;; constitute a valid handler in the sense that
                  ;; nothing is done on the event, evaluating symbols
                  ;; doesn't even push them to the message queue.
                  ;; the tradeoff here is between program correctness
                  ;; and flexibility
                  (cons head
                        (cons (cadr args)
                              (circe-actions--normalize-args (cddr args)))))
                  ;; all other options should be strings
                  (t
                   (if (stringp (cadr args))
                       (cons head
                             (cons (cadr args)
                                   (circe-actions--normalize-args (cddr args))))
                     (error "%s not followed by string!" head)))))
          ;; this is the body, as it wasn't preceded by a keyword.
          ;; no need to validate. We've already checked if it's nil
          (t
           (cons :expr
                 (cons head
                       (circe-actions--normalize-args (cdr args))))))))
         
;;;###autoload
(defun enable-circe-actions ()
  "load in circe-actions.el. do nothing else."
  (interactive)
  nil)

;;;###autoload
(defun disable-circe-actions ()
  "remove all active handlers, persistent or otherwise. Essentially a defalias to circe-actions-panic with a worse docstring."
  (interactive)
  ;; there really isn't anything else to do besides killing the handlers
  ;; unload functions from function namespace?
  (circe-actions-panic))

(provide 'circe-actions)
;;; circe-actions.el ends here
