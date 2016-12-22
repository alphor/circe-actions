
;; ert
(require 'ert)

(require 'circe-actions)

;; all tests are of the form (should EXPECTED ACTUAL)

(defun circe-actions-mock-table ()
  "There has got to be a better way to do this..."
  (let ((table (irc-handler-table)))
      (irc-handler-add table "irc.registered" #'circe--irc-conn-registered)
      (irc-handler-add table "conn.disconnected" #'circe--irc-conn-disconnected)
      (irc-handler-add table nil #'circe--irc-display-event)
      (irc-handle-registration table)
      (irc-handle-ping-pong table)
      (irc-handle-isupport table)
      (irc-handle-initial-nick-acquisition table)
      (irc-handle-ctcp table)
      (irc-handle-state-tracking table)
      (irc-handle-nickserv table)
      (irc-handle-auto-join table)
      table))


(ert-deftest circe-actions-t-test ()
  "Test circe-actions-t always returns t independent of the arguments"
  (should (circe-actions-t "whatever" 'is "put" "here" 1 nil))
  (should (circe-actions-t)))

(ert-deftest circe-actions-deactivate-function-test ()
  (let ((circe-actions-handlers-alist '()))
    (flet ((circe-irc-handler-table () (circe-actions-mock-table)))

      ;; do what circe-actions-activate-function would have done
      (setq circe-actions-handlers-alist
	    (cons (list 'arb-sym "irc.message") circe-actions-handlers-alist))
      (irc-handler-add (circe-irc-handler-table)
		       "irc.message"
		       'arb-sym)

      (circe-actions-deactivate-function 'arb-sym "irc.message")
      (should (equal 0 (length circe-actions-handlers-alist)))
      (should (equal 0 (length (gethash "irc.message" (circe-irc-handler-table))))))))
      
(ert-deftest circe-actions-activate-function-test ()
  "Given an arbitrary thing and associated event (must be a key of circe-handler-table as generated in circe-actions-mock-table), add it to a mock list, unless it exceeds circe-actions-maximum-handlers (which is also mocked here)"
  (let ((circe-actions-handlers-alist '())
	(circe-actions-maximum-handlers 2))
    ;; changing to cl-flet breaks the test
    ;; for clear reasons: http://stackoverflow.com/a/18895704
    ;; we are intentionally shadowing circe-irc-handler-table here.
    (flet ((circe-irc-handler-table () (circe-actions-mock-table)))
      (unwind-protect
	  (progn
	    (circe-actions-activate-function 'arb-sym1 "irc.message")
	    (should (equal 1 (length circe-actions-handlers-alist)))

	    ;; symbol comparison intended, there aren't any objects behind these
	    (should (equal 'arb-sym1 (car (nth 0 circe-actions-handlers-alist))))

	    (circe-actions-activate-function 'arb-sym2 "irc.message")
	    (should (equal 2 (length circe-actions-handlers-alist)))
	    
	    ;; no errors should occur (it would be kind of obnoxious)
	    ;; instead a message is shown to the user.
	    (circe-actions-activate-function 'arb-sym3 "irc.message")
	    (should (equal 2 (length circe-actions-handlers-alist)))

	    ;; check that sym1 and sym2 are still in the list
	    (should (member '(arb-sym1 "irc.message") circe-actions-handlers-alist))
	    (should (member '(arb-sym2 "irc.message") circe-actions-handlers-alist))

	    ;; check arb-sym3 is not in the list.
	    (should (null (member '(arb-sym3 "irc.message")
				  circe-actions-handlers-alist))))
	(progn
	  (circe-actions-deactivate-function 'arb-sym1 "irc.message")
	  (circe-actions-deactivate-function 'arb-sym2 "irc.message"))))))



;; generate-test should test circe-actions-generate-handler-function
;; can be improved by splitting it and testing each factor of g-h-f

(ert-deftest circe-actions-generate-symbol-test ()
  "Test that internal symbol is preserved"
  (let ((handler-func
	   (circe-actions-generate-handler-function 'circe-actions-t
						    ;; return message
						    (lambda (&rest args)
						      (nth 4 args))

						    'some-sym
						    "irc.message")))
    (should (string-equal "some-sym" (symbol-name handler-func)))))

(ert-deftest circe-actions-generate-condition-test ()
  (let ((handler-func
	 (circe-actions-generate-handler-function 'circe-actions-t
						  ;; return message
						  (lambda (&rest args)
						    (nth 4 args))

						  'some-sym
						  "irc.message")))
    (should (equal "to-be-returned"
	     (funcall handler-func
		      nil
		      nil
		      6
		      'arb-sym
		      "to-be-returned")))))


(ert-deftest circe-actions-sanity-check ()
  (let ((some-lambda
	 (lambda (arg1 arg2)
	   arg2)))
    (let ((arg-list '(1 2)))
      (equal 2
	     (apply some-lambda arg-list)))))

;; not working due to some weird symbol manipulation... circe-actions-sanity-check checks this, so it's something to do with my code.
(ert-deftest circe-actions-generate-joint-cond-action-pass-test ()
  (let ((cond-func
	  (lambda (server-proc event &rest args)
	    "Return true if args is a non-empty list"
	    (if args
		t
	      nil)))
	 (act-func
	  (lambda (server-proc event &rest args)
	    "Return the event passed"
	    event))))
    (let ((handler-func
	   (circe-actions-generate-handler-function cond-func
						    act-func
						    'arb-sym
						    "irc.message")))
      ;; if condition passes, we get the results of our action function
      ;; (in this case, we just get returned the event it was called with)
      (should (equal "nothing"
		     (funcall handler-func
			      'arbitrary-process
			      "irc.ctcp.ping"
			      'non-empty-arg))))))
	    
(ert-deftest circe-actions-generate-joint-cond-action-fail-test ()
  (let* ((cond-func
	  (lambda (server-proc event &rest args)
	    "Return true if args is a non-empty list"
	    (if args
		t
	      nil)))
	 (act-func
	  (lambda (server-proc event &rest args)
	    "Return the event passed"
	    event))
	 (handler-func
	  (circe-actions-generate-handler-function cond-func
						   act-func
						   'arb-sym
						   "irc.message")))
    (should (null (funcall handler-func
			   'arb
			   "irc.ctcp.ping")))))
;; tests need to be written for persistence
