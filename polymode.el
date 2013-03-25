;;; polymode.el --- support for multiple major modes
;; Author: Vitalie Spinu

(require 'cl)
(require 'font-lock)
;; (require 'imenu)
(require 'eieio)
(require 'eieio-base)
(require 'eieio-custom)
(require 'polymode-classes)
(require 'polymode-methods)

(defgroup polymode nil
  "Object oriented framework for multiple modes based on indirect buffers"
  :link '(emacs-commentary-link "polymode")
  :group 'tools)

(defgroup base-submodes nil
  "Base Submodes"
  :group 'polymode)

(defgroup submodes nil
  "Children Submodes"
  :group 'polymode)

(defvar polymode-select-mode-hook nil
  "Hook run after a different mode is selected.")

(defvar polymode-indirect-buffer-hook nil
  "Hook run by `pm/install-mode' in each indirect buffer.
It is run after all the indirect buffers have been set up.")

(defvar pm/config nil)
(make-variable-buffer-local 'pm/config)

(defvar pm/submode nil)
(make-variable-buffer-local 'pm/submode)

(defvar pm/type nil)
(make-variable-buffer-local 'pm/type)

(defcustom polymode-prefix-key "\M-n"
  "Prefix key for the polymode mode keymap.
Not effective after loading the polymode library."
  :group 'polymode
  :type '(choice string vector))

(defvar polymode-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map polymode-prefix-key
      (let ((map (make-sparse-keymap)))
	(define-key map "\C-n" 'polymode-next-chunk)
	(define-key map "\C-p" 'polymode-previous-chunk)
        (define-key map "\C-\M-n" 'polymode-next-chunk-same-type)
	(define-key map "\C-\M-p" 'polymode-previous-chunk-same-type)
        (define-key map "\M-k" 'polymode-kill-chunk)
        (define-key map "\M-m" 'polymode-mark-or-extend-chunk)
        (define-key map "\C-t" 'polymode-toggle-chunk-narrowing)
	(define-key map "\M-i" 'polymode-insert-new-chunk)
	map))
    (define-key map [menu-bar Polymode]
      (cons "Polymode"
	    (let ((map (make-sparse-keymap "Polymode")))
              (define-key-after map [goto-prev]
		'(menu-item "Next chunk" polymode-next-chunk))
	      (define-key-after map [goto-prev]
		'(menu-item "Previous chunk" polymode-previous-chunk))
              (define-key-after map [goto-prev]
		'(menu-item "Next chunk same type" polymode-next-chunk-same-type))
	      (define-key-after map [goto-prev]
		'(menu-item "Previous chunk same type" polymode-previous-chunk-same-type))
	      (define-key-after map [mark]
		'(menu-item "Mark or extend chunk" polymode-mark-or-extend-chunk))
	      (define-key-after map [kill]
		'(menu-item "Kill chunk" polymode-kill-chunk))
	      (define-key-after map [new]
		'(menu-item "Insert new chunk" polymode-insert-new-chunk))
	      map)))
    map)
  "The default minor mode keymap that is active in all polymode
  modes.")

(defun polymode-next-chunk (&optional N)
  "Go to next COUNT chunk.
Return, how many chucks actually jumped over."
  (interactive "p")
  (let ((sofar 0))
    (condition-case nil
        (pm/map-over-spans
         (lambda ()
           (unless (memq (car *span*) '(head tail))
             (when (>= sofar N)
               (signal 'quit nil))
             (setq sofar (1+ sofar))))
         (point) (point-max))
      (quit (when (looking-at "\\s *$")
              (forward-line))))
    sofar))

;;fixme: problme with long chunks .. point is recentered
;;todo: merge into next-chunk
(defun polymode-previous-chunk (&optional N)
  "Go to next COUNT chunk.
Return, how many chucks actually jumped over."
  (interactive "p")
  (let ((sofar 0))
    (condition-case nil
        (pm/map-over-spans
         (lambda ()
           (unless (memq (car *span*) '(head tail))
             (when (>= sofar N)
               (signal 'quit nil))
             (setq sofar (1+ sofar))))
         (point-min) (point) nil 'back)
      (quit (when (looking-at "\\s *$")
              (forward-line 1))))
    sofar))

(defun polymode-next-chunk-same-type (&optional N)
  "Go to next COUNT chunk.
Return, how many chucks actually jumped over."
  (interactive "p")
  (let ((sofar 0)
        orig-type)
    (condition-case nil
        (pm/map-over-spans
         (lambda ()
           (unless (memq (car *span*) '(head tail))
             (when (equal orig-type (object-name (car (last *span*))))
               (setq sofar (1+ sofar)))
             (unless orig-type
               (setq orig-type (object-name (car (last *span*)))))
             (when (>= sofar N)
               (signal 'quit nil))))
         (point) (point-max))
      (quit (when (looking-at "\\s *$")
              (forward-line))))
    sofar))

(defun polymode-previous-chunk-same-type (&optional N)
  "Go to previus COUNT chunk.
Return, how many chucks actually jumped over."
  (interactive "p")
  (let ((sofar 0)
        orig-type)
    (condition-case nil
        (pm/map-over-spans
         (lambda ()
           (unless (memq (car *span*) '(head tail))
             (when (equal orig-type (object-name (car (last *span*))))
               (setq sofar (1+ sofar)))
             (unless orig-type
               (setq orig-type (object-name (car (last *span*)))))
             (when (>= sofar N)
               (signal 'quit nil))))
         (point-max) (point) nil nil)
      (quit (when (looking-at "\\s *$")
              (forward-line))))
    sofar))

(defsubst pm/base-buffer ()
  ;; fixme: redundant with :base-buffer 
  "Return base buffer of current buffer, or the current buffer if it's direct."
  (or (buffer-base-buffer (current-buffer))
      (current-buffer)))

;; ;; VS[26-08-2012]: Dave's comment:
;; ;; It would be nice to cache the results of this on text properties,
;; ;; but that probably won't work well if chunks can be nested.  In that
;; ;; case, you can't just mark everything between delimiters -- you have
;; ;; to consider other possible regions between them.  For now, we do
;; ;; the calculation each time, scanning outwards from point.
(defun pm/get-innermost-span (&optional pos)
  (pm/get-span pm/config pos))

(defvar pm--can-narrow? t)
(defun pm/map-over-spans (fun beg end &optional count backward?)
  "For all spans between BEG and END, execute FUN.
FUN is a function of no args. It is executed with point at the
beginning of the span and with the buffer narrowed to the
span. If COUNT is non-nil, jump at most that many times. If
BACKWARD? is non-nil, map backwards.
 
During the call of FUN, a dynamically bound variable *span* holds
the current innermost span."
  (goto-char (if backward? end beg))
  (let ((nr 0))
    (save-excursion
      (save-restriction
        (widen)
        (while (and (if backward?
                        (> (point) beg)
                      (< (point) end))
                    (or (null count)
                        (< nr count)))
          (let ((*span* (pm/get-innermost-span)))
            (dbg (point))
            (setq nr (1+ nr))
            (pm/select-buffer (car (last *span*)) *span*) ;; object and type
            ;; (goto-char (nth 1 *span*))
            (funcall fun)))
        (if backward?
            (goto-char (max (point-min)
                            (1- (nth 1 *span*)))) ;; enter previous chunk
          (goto-char (nth 2 *span*)))))))

(defun pm/narrow-to-span (&optional span)
  "Narrow to current chunk."
  (interactive)
  (unless (= (point-min) (point-max))
    (let ((span (or span
                    (pm/get-innermost-span))))
      (if span
          (let ((min (nth 1 span))
                (max (nth 2 span)))
            (when (boundp 'syntax-ppss-last)
              (setq syntax-ppss-last
                    (cons (point-min)
                          (list 0 nil (point-min) nil nil nil 0 nil nil nil))))
            (narrow-to-region min max))
        (error "No span found")))))

(defvar pm--fontify-region-original nil
  "Fontification function normally used by the buffer's major mode.
Used internaly to cahce font-lock-fontify-region-function.  Buffer local.")
(make-variable-buffer-local 'multi-fontify-region-original)

(defun pm/fontify-region (beg end &optional verbose)
  "Polymode font-lock fontification function.
Fontifies chunk-by chunk within the region.
Assigned to `font-lock-fontify-region-function'.

A fontification mechanism should call
`font-lock-fontify-region-function' (`jit-lock-function' does
that). If it does not, the fontification will probably be screwed
in polymode buffers."
  (let* ((modified (buffer-modified-p))
         (buffer-undo-list t)
	 (inhibit-read-only t)
	 (inhibit-point-motion-hooks t)
	 (inhibit-modification-hooks t)
         (font-lock-dont-widen t)
         (buff (current-buffer))
	 deactivate-mark)
    ;; (with-silent-modifications
    (font-lock-unfontify-region beg end)
    (save-excursion
      (save-restriction
        (widen)
        (pm/map-over-spans
         (lambda ()
           (when (and font-lock-mode font-lock-keywords)
             (let ((sbeg (nth 1 *span*))
                   (send (nth 2 *span*)))
               (dbg sbeg send)
               ;; (dbg (point-min) (point-max) (point))
               (pm--adjust-chunk-overlay sbeg send buff) ;; set in original buffer!
               (when parse-sexp-lookup-properties
                 (pm--comment-region 1 sbeg))
               (unwind-protect 
                   (if (oref pm/submode :font-lock-narrow)
                       (save-restriction
                         (narrow-to-region sbeg send)
                         (funcall pm--fontify-region-original
                                  (max sbeg beg) (min send end) verbose))
                     (funcall pm--fontify-region-original
                              (max sbeg beg) (min send end) verbose))
                 (when parse-sexp-lookup-properties
                   (pm--uncomment-region 1 sbeg))
                 ))))
         beg end))
      (put-text-property beg end 'fontified t)
      (unless modified
        (restore-buffer-modified-p nil)))))


;;; internals
(defun pm--get-available-mode (mode)
  "Check if MODE symbol is defined and is a valid function.
If so, return it, otherwise return 'fundamental-mode with a
warnign."
  (if (fboundp mode)
      mode
    (message "Cannot find " mode " function, using 'fundamental-mode instead")
    'fundamental-mode))

(defvar pm--ignore-post-command-hook nil)
(defun pm--restore-ignore ()
  (setq pm--ignore-post-command-hook nil))

(defvar polymode-highlight-chunks t)

(defun polymode-select-buffer ()
  "Select the appropriate (indirect) buffer corresponding to point's context.
This funciton is placed in local post-command hook."
  (condition-case error
      (unless pm--ignore-post-command-hook
        (let ((*span* (pm/get-innermost-span))
              (pm--can-move-overlays t))
          (pm/select-buffer (car (last *span*)) *span*)
          (pm--adjust-chunk-overlay (nth 1 *span*) (nth 2 *span*))))
    (error (message "polymode error: %s"
                    (error-message-string error)))))



(defun pm/transform-color-value (color prop)
  "Darken or lighten a specific COLOR multiplicatively by PROP.

On dark backgrounds, values of PROP > 1 generate lighter colors
than COLOR and < 1, darker. On light backgrounds, do it the other
way around.

Colors are in hex RGB format #RRGGBB

   (pm/transform-color-value (face-background 'default) 1.1)
"
  (let* ((st (substring color 1))
         (RGB (list (substring st 0 2)
                    (substring st 2 4)
                    (substring st 4 6))))
    (when (eq (frame-parameter nil 'background-mode) 'light)
      (setq prop (/ 1 prop)))
    (when (< prop 0)
      (message "background value should be non-negative" )
      (setq prop 1))
    (concat "#"
            (mapconcat (lambda (n)
                         (format "%02x"
                                 (min 255 (max 0 (round (* prop (string-to-number n 16)))))))
                       RGB ""))))

(defun pm--adjust-chunk-overlay (beg end &optional buffer)
  ;; super duper internal function
  ;; should be used only after pm/select-buffer
  (when (eq pm/type 'body)
    (let ((background (oref pm/submode :background))) ;; in Current buffer !!
      (with-current-buffer (or buffer (current-buffer))
        (when background
          (let* ((OS (overlays-in  beg end))
                 (o (some (lambda (o) (and (overlay-get o 'polymode) o))
                          OS)))
            (if o
                (move-overlay o  beg end )
              (let ((o (make-overlay beg end nil nil t))
                    (face (if (numberp background)
                              (cons 'background-color
                                    (pm/transform-color-value (face-background 'default)
                                                              background))
                            background)))
                (overlay-put o 'polymode 'polymode-major-mode)
                (overlay-put o 'face face)
                (overlay-put o 'evaporate t)))))))))

(defun pm--adjust-visual-line-mode (new-vlm)
  (when (not (eq visual-line-mode vlm))
    (if (null vlm)
        (visual-line-mode -1)
      (visual-line-mode 1))))

;; move only in post-command hook, after buffer selection
(defvar pm--can-move-overlays nil)
(defun pm--move-overlays-to (new-buff)
  (when pm--can-move-overlays 
    (mapc (lambda (o)
            (move-overlay o (overlay-start o) (overlay-end o) new-buff))
          (overlays-in 1 (1+ (buffer-size))))))

(defun pm--select-buffer (buffer)
  (when (and (not (eq buffer (current-buffer)))
             (buffer-live-p buffer))
    (let ((point (point))
          (window-start (window-start))
          (visible (pos-visible-in-window-p))
          (oldbuf (current-buffer))
          (vlm visual-line-mode)
          (ractive (region-active-p))
          (mkt (mark t))
          (bis buffer-invisibility-spec))
      (pm--move-overlays-to buffer)
      (switch-to-buffer buffer)
      (setq buffer-invisibility-spec bis)
      (pm--adjust-visual-line-mode vlm)
      (bury-buffer oldbuf)
      ;; fixme: wha tis the right way to do this ... activate-mark-hook?
      (if (not ractive)
          (deactivate-mark)
        (set-mark mkt)
        (activate-mark))
      (goto-char point)
      ;; Avoid the display jumping around.
      (when visible
        (set-window-start (get-buffer-window buffer t) window-start))
      )))


(defun pm--setup-buffer (&optional buffer)
  ;; general buffer setup, should work for indirect and base buffers alike
  ;; assumes pm/config and pm/submode is already in place
  ;; return buffer
  (let ((buff (or buffer (current-buffer))))
    (with-current-buffer buff
      ;; Don't let parse-partial-sexp get fooled by syntax outside
      ;; the chunk being fontified.

      ;; font-lock, forward-sexp etc should see syntactic comments
      ;; (set (make-local-variable 'parse-sexp-lookup-properties) t)

      (set (make-local-variable 'font-lock-dont-widen) t)
      
      (when pm--dbg-fontlock 
        (setq pm--fontify-region-original
              font-lock-fontify-region-function)
        (set (make-local-variable 'font-lock-fontify-region-function)
             #'pm/fontify-region))

      (set (make-local-variable 'polymode-mode) t)

      ;; Indentation should first narrow to the chunk.  Modes
      ;; should normally just bind `indent-line-function' to
      ;; handle indentation.
      (when (and indent-line-function ; not that it should ever be nil...
                 (oref pm/submode :protect-indent-line-function))
        (set (make-local-variable 'indent-line-function)
             `(lambda ()
                (let ((span (pm/get-innermost-span)))
                  (unwind-protect
                      (save-restriction
                        (pm--comment-region  1 (nth 1 span))
                        (pm/narrow-to-span span)
                        (,indent-line-function))
                    (pm--uncomment-region 1 (nth 1 span)))))))

      ;; Kill the base buffer along with the indirect one; careful not
      ;; to infloop.
      ;; (add-hook 'kill-buffer-hook
      ;;           '(lambda ()
      ;;              ;; (setq kill-buffer-hook nil) :emacs 24 bug (killing
      ;;              ;; dead buffer triggers an error)
      ;;              (let ((base (buffer-base-buffer)))
      ;;                (if  base
      ;;                    (unless (buffer-local-value 'pm--killed-once base)
      ;;                      (kill-buffer base))
      ;;                  (setq pm--killed-once t))))
      ;;           t t)
      
      (when pm--dbg-hook
        (add-hook 'post-command-hook
                  'polymode-select-buffer nil t))
      (object-add-to-list pm/config :buffers (current-buffer)))
    buff))

(defvar pm--killed-once nil)
(make-variable-buffer-local 'pm--killed-once)

(defun pm--create-indirect-buffer (mode)
  "Create indirect buffer with major MODE and initialize appropriately.

This is a low lever function which must be called, one way or
another from `pm/install' method. Among other things store
`pm/config' from the base buffer (must always exist!) in
the newly created buffer.

Return newlly created buffer."
  (unless   (buffer-local-value 'pm/config (pm/base-buffer))
    (error "`pm/config' not found in the base buffer %s" (pm/base-buffer)))
  
  (setq mode (pm--get-available-mode mode))

  (with-current-buffer (pm/base-buffer)
    (let* ((config (buffer-local-value 'pm/config (current-buffer)))
           (new-name
            (generate-new-buffer-name 
             (format "%s[%s]" (buffer-name)
                     (replace-regexp-in-string "-mode" "" (symbol-name mode)))))
           (new-buffer (make-indirect-buffer (current-buffer)  new-name))
           ;; (hook pm/indirect-buffer-hook)
           (file (buffer-file-name))
           (base-name (buffer-name))
           (jit-lock-mode nil)
           (coding buffer-file-coding-system)
           (tbf (get-buffer-create "*pm-tmp*")))

      (with-current-buffer new-buffer
        (let ((polymode-mode t)) ;;major-modes might check it
          (funcall mode))
        (setq polymode-major-mode mode)
        
        ;; Avoid the uniqified name for the indirect buffer in the mode line.
        (when pm--dbg-mode-line
          (setq mode-line-buffer-identification
                (propertized-buffer-identification base-name)))
        (setq pm/config config)
        (setq buffer-file-coding-system coding)
        (setq buffer-file-name file)
        (vc-find-file-hook))
      new-buffer)))


(defvar polymode-major-mode nil)
(make-variable-buffer-local 'polymode-major-mode)

(defun pm--get-indirect-buffer-of-mode (mode)
  (loop for bf in (oref pm/config :buffers)
        when (and (buffer-live-p bf)
                  (eq mode (buffer-local-value 'polymode-major-mode bf)))
        return bf))

(defun pm--set-submode-buffer (obj type buff)
  (with-slots (buffer head-mode head-buffer tail-mode tail-buffer) obj
    (pcase (list type head-mode tail-mode)
      (`(body body ,(or `nil `body))
       (setq buffer buff
             head-buffer buff
             tail-buffer buff))
      (`(body ,_ body)
       (setq buffer buff
             tail-buffer buff))
      (`(body ,_ ,_ )
       (setq buffer buff))
      (`(head ,_ ,(or `nil `head))
       (setq head-buffer buff
             tail-buffer buff))
      (`(head ,_ ,_)
       (setq head-buffer buff))
      (`(tail ,_ ,(or `nil `head))
       (setq tail-buffer buff
             head-buffer buff))
      (`(tail ,_ ,_)
       (setq tail-buffer buff))
      (_ (error "type must be one of 'body 'head and 'tail")))))

(defun pm--get-submode-mode (obj type)
  (with-slots (mode head-mode tail-mode) obj
    (cond ((or (eq type 'body)
               (and (eq type 'head)
                    (eq head-mode 'body))
               (and (eq type 'tail)
                    (or (eq tail-mode 'body)
                        (and (null tail-mode)
                             (eq head-mode 'body)))))
           (oref obj :mode))
          ((or (and (eq type 'head)
                    (eq head-mode 'base))
               (and (eq type 'tail)
                    (or (eq tail-mode 'base)
                        (and (null tail-mode)
                             (eq head-mode 'base)))))
           (oref (oref pm/config :base-submode) :mode))
          ((eq type 'head)
           (oref obj :head-mode))
          ((eq type 'tail)
           (oref obj :tail-mode))
          (t (error "type must be one of 'head 'tail 'body")))))

;; (oref pm-submode/noweb-R :tail-mode)
;; (oref pm-submode/noweb-R :buffer)
;; (progn
;;   (pm--set-submode-buffer pm-submode/noweb-R 'tail (current-buffer))
;;   (oref pm-submode/noweb-R :head-buffer))

(define-minor-mode polymode-minor-mode
  "Polymode minor mode, used to make everything work."
  nil " PM" polymode-mode-map)

(defun pm--map-over-spans-highlight ()
  (interactive)
  (pm/map-over-spans (lambda ()
                       (let ((start (nth 1 *span*))
                             (end (nth 2 *span*)))
                         (ess-blink-region start end)
                         (sit-for 1)))
                     (point-min) (point-max)))

(defun pm--highlight-span (&optional hd-matcher tl-matcher)
  (interactive)
  (let* ((hd-matcher (or hd-matcher (oref pm/submode :head-reg)))
         (tl-matcher (or tl-matcher (oref pm/submode :tail-reg)))
         (span (pm--span-at-point hd-matcher tl-matcher)))
    (ess-blink-region (nth 1 span) (nth 2 span))
    (message "%s" span)))

(defun pm--run-over-check ()
  (interactive)
  (goto-char (point-min))
  (let ((start (current-time))
        (count 1))
    (polymode-select-buffer)
    (while (< (point) (point-max))
      (setq count (1+ count))
      (forward-char)
      (polymode-select-buffer))
    (let ((elapsed  (time-to-seconds (time-subtract (current-time) start))))
      (message "elapsed: %s  per-char: %s" elapsed (/ elapsed count)))))


(defun pm--comment-region (beg end)
  ;; mark as syntactic comment
  (when (> end 1)
    (with-silent-modifications
      (let ((beg (or beg (region-beginning)))
            (end (or end (region-end))))
        (let ((ch-beg (char-after beg))
              (ch-end (char-before end)))
          (add-text-properties beg (1+ beg)
                               (list 'syntax-table (cons 11 ch-beg)
                                     'rear-nonsticky t
                                     'polymode-comment 'start))
          (add-text-properties (1- end) end
                               (list 'syntax-table (cons 12 ch-end)
                                     'rear-nonsticky t
                                     'polymode-comment 'end))
          )))))

(defun pm--uncomment-region (beg end)
  ;; remove all syntax-table properties. Should not cause any problem as it is
  ;; always used before font locking
  (when (> end 1)
    (with-silent-modifications
      (let ((props '(syntax-table nil rear-nonsticky nil polymode-comment nil)))
        (remove-text-properties beg end props)
        ;; (remove-text-properties beg (1+ beg) props)
        ;; (remove-text-properties end (1- end) props)
        ))))


(defmacro define-polymode (mode config &optional keymap &rest body)
  "Define a new polymode MODE.
This defines command MODE and (by default) an indicator variable
MODE that is t when MODE is active and nil othervise.

Optional KEYMAP is the default keymap bound to the mode keymap.
  If nil, no new keymap is created and MODE uses `polymode-mode-map'.
  If t, a new keymap is created with name MODE-MAP that inherits
  form `polymode-mode-map'.
  Otherwise it should be a variable name (whose value is a keymap),
  or an alist of binding arguments passed to `easy-mmode-define-keymap'.

BODY contains code to execute each time the mode is enabled. It
  is executed after the complete initialization of the
  polymode (`pm/initialize') and before running MODE-hook. Before
  the actual body code, you can write keyword arguments,
  i.e. alternating keywords and values.  These following special
  keywords are supported:

:lighter SPEC   Optional LIGHTER is displayed in the mode line when
                the mode is on. If omitted, it defaults to
                the :lighter slot of CONFIG object.
:keymap MAP	Same as the KEYMAP argument.

:after-hook     A single lisp form which is evaluated after the mode hooks
                have been run.  It should not be quoted.
"
  (declare 
   (debug (&define name name
                   [&optional [&not keywordp] sexp]
                   [&rest [keywordp sexp]]
                   def-body)))

  (when (keywordp keymap)
    (push keymap body) (setq keymap nil))

  (let* ((last-message (make-symbol "last-message"))
         (mode-name (symbol-name mode))
         (pretty-name (concat
                       (replace-regexp-in-string "poly-\\|-mode" "" mode-name)
                       " polymode"))
	 (group nil)
         (lighter (oref (symbol-value config) :lighter))
	 (extra-keywords nil)
         (modefun mode)          ;The minor mode function name we're defining.
	 (after-hook nil)
	 (hook (intern (concat mode-name "-hook")))
	 keyw keymap-sym tmp)

    ;; Check keys.
    (while (keywordp (setq keyw (car body)))
      (setq body (cdr body))
      (pcase keyw
	(`:lighter (setq lighter (purecopy (pop body))))
	;; (`:group (setq group (nconc group (list :group (pop body)))))
	(`:keymap (setq keymap (pop body)))
	(`:after-hook (setq after-hook (pop body)))
	(_ (push keyw extra-keywords) (push (pop body) extra-keywords))))

    ;; (unless group
    ;;   ;; We might as well provide a best-guess default group.
    ;;   (setq group
    ;;         `(:group ',(intern (replace-regexp-in-string
    ;;     			"-mode\\'" "" mode-name)))))
    (unless keymap
      (setq keymap 'polymode-mode-map))
    (when (or (eq keymap t)
              (listp keymap))
      (if (eq keymap t) (setq keymap nil))
      (let ((map-name (concat mode-name "-map")))
        (setq keymap-sym (intern map-name))))
    

    `(progn
       ;; Define the variable to enable or disable the mode.
       :autoload-end
       (defvar ,mode nil ,(format "Non-nil if %s is enabled." pretty-name))
       (make-variable-buffer-local ',mode)

       ;; The actual function.
       (defun ,mode (&optional arg) ,(format "%s\n\n\\{%s}"
                                             (concat pretty-name ".")
                                             (or keymap-sym
                                                 (and (null keymap)
                                                      'polymode-mode-map)
                                                 (and (symbolp keymap)
                                                      keymap)))
	 (interactive)
         (unless ,mode
           ;; do nothing if already installed
           ;; waf? why is this one called twice.
           (setq ,mode t)
           (let ((,last-message (current-message)))
             (unless pm/config ;; don't reinstall for time being
               (let ((config (clone ,config)))
                 (oset config :minor-mode-name ',mode)
                 (pm/initialize config)))
             ;; (dbg "here" (current-buffer))
             ,@body
             (run-hooks ',hook)
             ;; Avoid overwriting a message shown by the body,
             ;; but do overwrite previous messages.
             (when (and (called-interactively-p 'any)
                        (or (null (current-message))
                            (not (equal ,last-message
                                        (current-message)))))
               (message ,(format "%s enabled" pretty-name)))
             ,@(when after-hook `(,after-hook))
             (force-mode-line-update)))
         ;; Return the new setting.
         ,mode)

       ;; Autoloading a define-minor-mode autoloads everything
       ;; up-to-here.
       :autoload-end
       
       ;; Define the minor-mode keymap.
       ,(when keymap-sym
          `(defvar ,keymap-sym
             (easy-mmode-define-keymap ,keymap nil nil '(:inherit ,polymode-mode-map))
             ,(format "Keymap for %s." pretty-name)))

       (add-minor-mode ',mode ',lighter ,(or keymap-sym keymap)))))

;; indulge elisp font-lock :) 
(dolist (mode '(emacs-lisp-mode lisp-interaction-mode))
  (font-lock-add-keywords
   mode
   '(("(\\(define-polymode\\)\\s +\\(\\(\\w\\|\\s_\\)+\\)"
      (1 font-lock-keyword-face)
      (2 font-lock-variable-name-face)))))

(setq pm--dbg-mode-line t
      pm--dbg-fontlock t
      pm--dbg-hook t)

(provide 'polymode)
