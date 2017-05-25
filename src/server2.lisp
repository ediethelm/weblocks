(defpackage #:weblocks.server
  (:use #:cl
        #:f-underscore)
  (:export #:start
           #:stop
           #:get-server-type
           #:get-port
           #:make-server
           #:handle-request
           #:*server*
           #:stop-weblocks
           #:start-weblocks))
(in-package weblocks.server)


(defvar *server* nil
  "If the server is started, bound to a server
  object. Otherwise, nil.")


(defclass server ()
  ((port :type integer
         :initarg :port
         :reader get-port)
   (server-type :initarg :server-type
                :reader get-server-type)
   (handler :initform nil
            :accessor get-handler)))


(defgeneric handle-request (server env)
  (:documentation "Handles HTTP request, passed by Clack"))


(defgeneric start (server &key debug)
  (:documentation "Starts a webserver, returns this server as result.
If server is already started, then logs a warning and does nothing."))


(defgeneric stop (server)
  (:documentation "Stops a webserver if it if running. If it's not - does nothing.
Returns a webserver's instance.")
  )


(defun make-server (&key
                      (port 8080)
                      (server-type :hunchentoot))
  "Makes a webserver instance.
Make instance, then start it with ``start`` method."
  (make-instance 'server
                 :port port
                 :server-type server-type))


(defmethod handle-request ((server server) env)
  "Weblocks HTTP dispatcher.
This function serves all started applications and their static files."
  (declare (ignorable env))
  
  ;; '(200
  ;;   (:content-type "text/plain")
  ;;   ("Hello, Clack!"))

  (log:debug "Serving" env)
  
  (let ((script-name (getf env :script-name))
        (hostname (getf env :server-name)))
    
    (dolist (app weblocks::*active-webapps*)
      (log:debug "Searching file in" app)

      (let ((app-prefix (weblocks:webapp-prefix app))
            (app-pub-prefix (weblocks:compute-webapp-public-files-uri-prefix app))
            weblocks::*default-content-type*)

        (cond
          ((or 
            (find script-name weblocks:*force-files-to-serve* :test #'string=)
            (and (weblocks::webapp-serves-hostname hostname app)
                 (weblocks::list-starts-with (weblocks::tokenize-uri script-name nil)
                                             (weblocks::tokenize-uri app-pub-prefix nil)
                                             :test #'string=)))
           (let* ((virtual-folder (weblocks::maybe-add-trailing-slash app-pub-prefix))
                  (physical-folder (weblocks::compute-webapp-public-files-path app))
                  ;; TODO send-gzip-rules move to this file
                  (content-type (weblocks::send-gzip-rules (weblocks::gzip-dependency-types* app)
                                                           script-name env virtual-folder physical-folder)))
             ;; TODO send-cache-rules
             (weblocks::send-cache-rules (weblocks::weblocks-webapp-public-files-cache-time app))

             ;; This is not optimal, because a new dispatcher created for each request
             ;; TODO: find out how to serve directory in Clack
             (return-from handle-request
               (funcall (weblocks::create-folder-dispatcher-and-handler virtual-folder physical-folder content-type)
                        env))))
          ((and (weblocks::webapp-serves-hostname hostname app)
                (weblocks::list-starts-with (weblocks::tokenize-uri script-name nil)
                                            (weblocks::tokenize-uri app-prefix nil)
                                            :test #'string=))
           ;; TODO это внутри использует hunchentoot
           (weblocks::no-cache)      ; disable caching for dynamic pages

           (return-from handle-request 
             (list 200
                   (list :content-type "text/html")
                   (list (weblocks.request-handler:handle-client-request app))))))))
    
    (log:debug "Application dispatch failed for" script-name)))


(defmethod start ((server server) &key debug)
  (if (get-handler server)
      (log:warn "Webserver already started")
      
      ;; Otherwise, starting a server
      (let ((port (get-port server)))
        (log:info "Starting webserver on" port)
        
        ;; Suppressing output to stdout, because Clack writes message
        ;; about started server and we want to write into a log instead.
        (with-output-to-string (*standard-output*)
          (setf (get-handler server)
                (clack:clackup (lambda (env)
                                 (handle-request server env))
                               :server (get-server-type server)
                               :port port
                               :debug debug)))

        (log:info "Starting webapps flagged as ``autostarted``")
        
        (mapcar (lambda (class)
                  (unless (weblocks:get-webapps-for-class class)
                    (weblocks:start-webapp class :debug debug)))
                weblocks::*autostarting-webapps*)))
  server)


(defmethod stop ((server server))
  (if (get-handler server)
      (progn (log:info "Stopping server" server)
             (clack:stop (get-handler server))
             (setf (get-handler server)
                   nil))
      (log:warn "Server wasn't started"))

  server)


(defmethod print-object ((server server) stream)
  (format stream "#<SERVER port=~S ~A>"
          (get-port server)
          (if (get-handler server)
              "running"
              "stopped")))


(defun start-weblocks (&key (debug t) (port 8080))
  "Starts weblocks framework hooked into Hunchentoot server.

Set DEBUG to true in order for error messages and stack traces to be shown
to the client (note: stack traces are temporarily not available due to changes
in Hunchentoot 1.0.0).

Set ACCEPTOR-CLASS if you want to use a custom acceptor (it must inherit
from WEBLOCKS-ACCEPTOR).

All other keywords will be passed as initargs to the acceptor;
the initargs :PORT and :SESSION-COOKIE-NAME default to
8080 and `weblocks-GENSYM'.

Also opens all stores declared via DEFSTORE and starts webapps
declared AUTOSTART."
  (unless (member :bordeaux-threads *features*)
    (cerror "I know what I'm doing and will stubbornly continue."
            "You're trying to start Weblocks without threading ~
            support. Recompile your Lisp with threads enabled."))
  (if debug
    (weblocks::enable-global-debugging)
    (weblocks::disable-global-debugging))
  (when (null *server*)
    (values
      (start (setf *server*
                   (make-server :port port)))
      (mapcar (lambda (class)
                (unless (weblocks::get-webapps-for-class class)
                  (weblocks::start-webapp class :debug debug)))
              weblocks::*autostarting-webapps*))))


(defun stop-weblocks ()
  "Stops weblocks."

  ;; TODO: Investigate if it closes all stores declared via 'defstore'.
  
  (when (not (null *server*))
    (dolist (app weblocks::*active-webapps*)
      (weblocks::stop-webapp (weblocks::weblocks-webapp-name app)))
    (setf weblocks::*last-session* nil)
    (weblocks::reset-sessions)
    (when *server*
      (stop *server*))
    (setf *server* nil)))
