;;; ecco.el --- a port of docco
;;; **ecco** is a port of docco. It renders
;;;
;;; * comments through [markdown][markdown]
;;;
;;; * code through emacs's built-int `htmlfontify' library, or
;;;   [pygments][pygments] if the user sets `ecco-use-pygments' to `t'.
;;;
;;; [pygments]: http://pygments.org/
;;; [markdown]: http://daringfireball.net/projects/markdown/
(require 'newcomment)
(require 'htmlfontify)


;;; Parsing
;;; -------
;;;
;;; The idea is to find comment regions and gather code snippets between
;;; them. We call each of these pairs a "section".
;;;
;;; We resort to `newcomment.el' comment-navigating functions, place overlays
;;; over the comments and return comments and code as pairs of strings.
;;;
(defun ecco--place-overlays ()
  (save-excursion
    (goto-char (point-min))
    (loop while (comment-search-forward (point-max) t)
          do
          (let ((overlay (make-overlay (goto-char (nth 8 (syntax-ppss)))
                                       (progn (forward-comment (point-max))
                                              (line-beginning-position)))))
            ;; The "background color" is for bling and debug purposes, user
            ;; should never actually after the command finishes
            ;;
            (overlay-put overlay 'face '(:background  "lavender"))
            (overlay-put overlay 'ecco t)))))

(defun ecco--gather-sections ()
  (let ((mode major-mode)
        (overlays (sort (ecco--overlays)
                        #'(lambda (ov1 ov2)
                            (< (overlay-start ov1) (overlay-start ov2))))))
    ;; In case our file does not start with a comment, insert a dummy one of 0
    ;; length.
    ;;
    (unless (= 1 (overlay-start (first overlays)))
      (let ((ov (make-overlay 1 1)))
        (overlay-put ov 'ecco t)
        (push ov overlays)))
    ;; Be sure to refontify the whole buffer if we're not using pygments, since
    ;; `htmlfontify-string' is going to need the next properties later
    ;;
    (unless ecco-use-pygments
      (jit-lock-fontify-now))
    ;; Now loop on the overlays, collect comments and code snippets
    ;;
    (loop for (overlay next) on overlays
          for comment =
          (let ((comment-text (buffer-substring-no-properties
                               (overlay-start overlay)
                               (overlay-end overlay))))

            ;; Place the comment text in a temp buffer with the
            ;; original major mode, strip all leading whitespace
            ;; and call `uncomment-region'
            (with-temp-buffer
              (insert comment-text)
              (goto-char (point-min))
              (while (re-search-forward "^\\([[:blank:]]+\\)[^[:blank:]]" nil t)
                (replace-match "" nil nil nil 1))
              (funcall mode)
              (uncomment-region (point-min) (point-max))
              ;; User-settable `ecco-comment-cleanup-functions',
              ;; can further be used to cleanup the comment of any
              ;; artifacts.
              (mapc #'(lambda (fn)
                        (save-excursion
                          (goto-char (point-min))
                          (funcall fn)))
                    ecco-comment-cleanup-functions)
              (buffer-substring-no-properties (point-min) (point-max))))
          for (from . to) = (cons (overlay-end overlay)
                                  (or (and next
                                           (overlay-start next))
                                      (point-max)))
          for snippet = (replace-regexp-in-string "\\`\n+\\|\\s-+$\\|\n+\\'"
                                                  ""
                                                  (buffer-substring from to))
          collect (cons comment snippet))))


;;; We need some overlay-handling code, it'll be important when implementing
;;; `ecco-comment-skip-regexps' (which doesn't really work for now)
;;;
(defun ecco--overlays ()
  (loop for overlay in (overlays-in (point-min) (point-max))
        when (overlay-get overlay 'ecco)
        collect overlay))

(defun ecco--cleanup-overlays ()
  (loop for overlay in (ecco--overlays)
        when (overlay-buffer overlay)
        do (delete-overlay overlay)))

(defun ecco--refine-overlays ()
  (loop for regexp in ecco-comment-skip-regexps
        do (loop for overlay in (ecco--overlays)
                 do
                 (goto-char (overlay-start overlay))
                 (while (re-search-forward regexp (overlay-end overlay) t)
                   (let ((saved-end (overlay-end overlay)))
                     ;; the unrefined overlay is reused and shortened at the
                     ;; end, or deleted if its length would become 0.
                     ;;
                     (if (= (overlay-start overlay) (match-beginning 0))
                         (delete-overlay overlay)
                       (move-overlay overlay (overlay-start overlay)
                                     (match-beginning 0)))
                     (unless (= (match-end 0) saved-end)
                       (let ((new-overlay (make-overlay (match-end 0)
                                                        saved-end)))
                         (overlay-put new-overlay 'face '(:background  "pink"))
                         (overlay-put new-overlay 'ecco t)
                         (setq overlay new-overlay))))))))



;;; Rendering
;;; ---------
;;;
;;; There are two types of rendering:
;;;
;;; * a "blob" render is an optimization used for markdown and pygments (if
;;;   that is in use). It consists of joining strings using a divider,
;;;   rendering and splitting them using another divider, and should
;;;   effectively be equivalent to piping each string through the external
;;;   process, which is very slow.
;;;
;;; * if pygments is not in use, `htmlfontify-string' will take care of the
;;;   job, and we don't use blob rendering here.
;;;
(defun ecco--render-sections (sections)
  (let ((comments
         (ecco--blob-render (mapcar #'car sections)
                            (ecco--markdown-dividers)
                            #'(lambda (text)
                                (ecco--pipe-text-through-program
                                 text
                                 (executable-find ecco-markdown-program)))))
        (snippets
         (cond (ecco-use-pygments
                (ecco--blob-render
                 (mapcar #'cdr sections)
                 (ecco--pygments-dividers)
                 #'(lambda (text)
                     (let ((render (ecco--pipe-text-through-program
                                    text
                                    (format "%s %s -f html"
                                            ecco-pygmentize-program
                                            (ecco--lexer-args)))))
                       (setq render
                             (replace-regexp-in-string
                              "^<div class=\"highlight\"><pre>" "" render))
                       (replace-regexp-in-string "</pre></div>$" "" render)))))
               (t
                (let ((hfy-optimisations (list 'keep-overlays
                                               'merge-adjacent-tags
                                               'body-text-only))
                      (hfy-user-sheet-assoc
                       '((font-lock-string-face "hljs-string" . "dummy")
                         (font-lock-keyword-face "hljs-keyword" . "dummy")
                         (font-lock-function-name-face "hljs-title" . "dummy")
                         (font-lock-comment-face "hljs-comment" . "dummy")
                         (font-lock-constant-face "hljs-constant" . "dummy")
                         (font-lock-warning-face "hljs-warning" . "dummy"))))
                  (mapcar #'htmlfontify-string (mapcar #'cdr sections)))))))
    (map 'list #'cons comments snippets)))


(defun ecco--blob-render (strings dividers renderer)
  (split-string (funcall renderer
                         (mapconcat #'identity strings (car dividers)))
                (cdr dividers)))

;;; **ecco** uses `shell-command-on-region' to pipe to external processes
;;;
(defun ecco--pipe-text-through-program (text program)
  (with-temp-buffer
    (insert text)
    (shell-command-on-region (point-min) (point-max) program
                             (current-buffer) 'replace)
    (buffer-string)))

;;; We also need these two to make blob rendering work with pygments
;;;
(defun ecco--lexer-args ()
  (cond
   ((eq ecco-pygments-lexer 'guess)
    (let ((lexer (cdr (assoc major-mode ecco-pygments-lexer-table))))
      (if lexer
          (format "-l %s" lexer)
        "-g")))
   (ecco-pygments-lexer
    (format "-l %s" ecco-pygments-lexer))
   (t
    "-g")))

(defun ecco--pygments-dividers ()
  (let* ((mode major-mode)
         (snippet-divider (with-temp-buffer
                            (funcall mode)
                            (insert "ECCO-SNIPPET-DIVIDER")
                            (comment-region (point-min) (point-max))
                            (buffer-string))))
    (cons (format "\n\n%s\n\n" snippet-divider)
          (format "\n*<span class=\"c.?\">%s</span>\n*" snippet-divider))))

;;; To output the final HTML code, we design a quick'n'dirty XML output
;;; library. this function will take a list like
;;;
;;;     (:html
;;;      (:head
;;;       (:title ,title))
;;;      (:body
;;;       (:div :class "container"
;;;             (:p "some paragraph text"))))
;;;
;;; and output the corresponding HTML. It's not as fantastic as
;;; [cl-who][cl-who], but gets the job done!
;;;
;;; [cl-who]: http://weitz.de/cl-who/
;;;
(defun ecco--output-xml-from-list (content)
  (labels ((format-thing (thing)
                         (cond ((keywordp thing)
                                (substring (symbol-name thing) 1))
                               ((stringp thing)
                                (format "\"%s\"" thing))
                               (t
                                (format "%s" thing))))
           (princ-format (format-string &rest format-args)
                         (princ (apply #'format format-string format-args)))
           (output-xml (content depth)
                       (let ((elem (pop content)))
                         (princ-format "<%s" (format-thing elem))
                         (loop for (key value . rest) on content by #'cddr
                               while (and (keywordp key) value (atom value))
                               do (princ-format " %s=%s"
                                                (format-thing key)
                                                (format-thing value))
                               (setq content rest))
                         (princ-format ">")
                         (loop with conses.in.content =
                               (loop for elem in content
                                     when (consp elem)
                                     return t)
                               for next in content
                               do
                               (when conses.in.content
                                 (princ-format "\n%s"
                                               (make-string (* 2
                                                               (1+ depth))
                                                            ? )))
                               (cond ((atom next)
                                      (princ-format "%s" next))
                                     ((consp next)
                                      (output-xml next (1+ depth))))
                               finally (when conses.in.content
                                         (princ-format "\n%s"
                                                       (make-string
                                                        (* 2 depth) ? )))
                               (princ-format "</%s>" (format-thing elem))))))
    (with-output-to-string
      (output-xml content 0))))

;;; These two functions return different styles of templates that can be fed to
;;; `ecco--output-xml-from-list'
;;;
(defun ecco--parallel-template (title rendered-sections)
  `(:html
    (:head
     (:title ,title)
     (:meta :http-equiv "content-type" :content "text/html charset=UTF-8")
     ,@(mapcar
        #'(lambda (file)
            `(:link :rel "stylesheet" :type "text/css" :media "all"
                    :href ,(format "%s/%s" ecco--docco-stylesheets-url file)))
        '("parallel/public/stylesheets/normalize.css" "parallel/docco.css"))
     ,@(when ecco-use-pygments
         `((:style :type "text/css"
                   ,(shell-command-to-string
                     (format "%s -f html -S monokai -a .highlight"
                             ecco-pygmentize-program)))
           (:style :type "text/css"
                   "pre, tt, code { background: none; border: none;}")))
     ,@ecco-extra-meta-html)
    (:body
     (:div :class "container"
           (:div :id "background")
           (:ul :class "sections"
                (:li :id "title"
                     (:div :class "annotation"
                           (:h1 ,title)))
                ,@(loop
                   for section in rendered-sections
                   for i from 0
                   for heading-p = (string-match
                                    "^[[:blank:]]*<\\(h[[:digit:]]\\)>"
                                    (car section))
                   collect
                   `(:li :id ,(format "section-%s" (1+ i))
                         (:div :class "annotation"
                               (:div :class
                                     ,(format "pilwrap %s"
                                              (if heading-p
                                                  (format "for-%s"
                                                          (match-string
                                                           1
                                                           (car section)))
                                                ""))
                                     (:a :class "pilcrow"
                                         :href ,(format "#section-%s" (1+ i))
                                         "&#182;"))
                               ,(car section))
                         (:div :class "content"
                               (:div :class "highlight"
                                     (:pre ,(cdr section)))))))))))

(defvar ecco--docco-stylesheets-url
  "http://jashkenas.github.io/docco/resources")

(defun ecco--linear-template (title rendered-sections)
  `(:html
    (:head
     (:title ,title)
     (:meta :http-equiv "content-type" :content "text/html charset=UTF-8")
     ,@(mapcar
        #'(lambda (file)
            `(:link :rel "stylesheet" :type "text/css" :media "all"
                    :href ,(format "%s/%s" ecco--docco-stylesheets-url file)))
        '("linear/public/stylesheets/normalize.css" "linear/docco.css"))
     ,@(when ecco-use-pygments
         `((:style :type "text/css"
                   ,(shell-command-to-string
                     (format "%s -f html -S monokai -a .highlight"
                                                     ecco-pygmentize-program)))
           (:style :type "text/css"
                   "pre, tt, code { background: none; border: none;}")))
     ,@ecco-extra-meta-html)
    (:body
     (:div :class "container"
           (:div :class "page"
                 (:div :class "header" (:h1 ,title))
                 ,@(loop for section in rendered-sections
                         append
                         (list `(:div :class "annotation" ,(car section))
                               `(:div :class "content"
                                      (:div :class "highlight"
                                            (:pre ,(cdr section)))))))))))


;;; Postprocessing comment regions
;;; -----------------------------
;;;
;;; This variable contains a list of functions that are called with comment
;;; annotations gathered by `ecco--gather-sections', just before sending them to
;;; the markdown interpreter.
;;;
(defvar ecco-comment-cleanup-functions
  '(ecco-backtick-and-quote-to-double-backtick
    ecco-make-autolinks
    ecco-fix-links
    ecco-ignore-elisp-headers))

;;; This little function replaces emacs "backtick-and-quote"-style comments with
;;; markdown's "double-backtick", in case you use which the former be converted
;;; to the latter.
;;;
(defun ecco-backtick-and-quote-to-double-backtick ()
  (while (re-search-forward "`\\([^\n]+?\\)'" nil t)
    (replace-match "`\\1`" nil nil)))

;;; `ecco-make-autolinks' replaces links to existing files with guessed .html
;;; versions.  If you invoke `ecco' on a file "a.something" and it mentions
;;; "b.something" and "b.something" exists relative to "a.something"'s path,
;;; then "a.html" will contain a link to "b.html"
;;;
(defun ecco-make-autolinks ()
  (while (and (re-search-forward
               (concat "[[:blank:]\n]\\(\\([-_/[:word:]]+\\)"
                       "\\.[[:word:]]+\\)[[:blank:]\n]")
                                 nil t)
              (file-exists-p (match-string 1)))
    (cond (ecco-output-directory
           (replace-match (format "[%s](%s/%s.html)"
                                  (match-string 1)
                                  ecco-output-directory
                                  (file-name-sans-extension
                                   (file-name-nondirectory (match-string 1))))
                          nil nil nil 1))
          (t
           (replace-match (format "[%s](%s)"
                                  (match-string 1)
                                  (match-string 1))
                          nil nil nil 1)))))

;;; The `ecco' command creates a temporary buffer and file and so needs absolute
;;; links. The `ecco-files' command, on the other hand, place files in a
;;; directory chosen by the user. This cleanup function makes the links be
;;; relative again if necessary.
;;;
(defvar ecco-output-directory nil)
(defun ecco-fix-links ()
  "Guess if  markdown link should be relative or absolute.

If you do M-x ecco, links should be absolute, but when
you call M-x ecco-files, you tipically want them to be relative."
  (loop while (re-search-forward "\(\\([-_\./:[:word:]]+\\.[[:word:]]+\\)\)"
                                 nil t)
        for relative-name = (match-string 1)
        when (file-exists-p relative-name)
        do
        (cond (ecco-output-directory
               (replace-match (file-relative-name relative-name
                                                  ecco-output-directory)
                              nil nil nil 1))
              (t
               (replace-match (format "%s%s"
                                      (expand-file-name default-directory)
                                      relative-name)
                              nil nil nil 1)))))

;;; Ignore some meta-information in other markup schemes.
;;;
(defun ecco-ignore-elisp-headers ()
  (when (and (eq major-mode 'emacs-lisp-mode)
             (search-forward-regexp " --- .*$" (line-end-position) t))
    (delete-region (line-beginning-position) (line-end-position))))


;;; User options
;;; ------------
;;;
;;; This section controls the use of markdown
;;;
(defvar ecco-markdown-program "markdown")
(defun ecco--markdown-dividers ()
  (cons "\n\n##### ECCO-COMMENT-DIVIDER\n\n"
        "\n*<h5.*>ECCO-COMMENT-DIVIDER</h5>\n*"))

;;; This section controls the use of pygments. Pygments is turned off by
;;; default, I've noticed emacs's `htmlfontify' works quite nicely most of the
;;; time.
;;;
(defvar ecco-use-pygments nil)
(defvar ecco-pygmentize-program "pygmentize")
(defvar ecco-pygments-lexer 'guess)
(defvar ecco-pygments-lexer-table
  '((lisp-mode . "cl")
    (emacs-lisp-mode . "cl")
    (sh-mode . "sh")
    (c-mode . "c")))

;;; Here are a bunch of user options that I haven't bothered to document
;;; yet. Sorry.
;;;
(defvar ecco-comment-skip-regexps '())
(defvar ecco-template-function 'ecco--linear-template)
(defvar ecco-extra-meta-html
  `((:style :type "text/css"
            ".annotation img { width: 100%; height: auto;}")))


;;; Main entry point
;;; ----------------
;;;
;;; The main command `ecco' that the user invokes makes use everything defined
;;; before.
;;;
;;;###autoload
(defun ecco (buffer &optional interactive)
  (interactive (list (current-buffer) t))
  (with-current-buffer buffer
    (unwind-protect
        (progn
          (ecco--place-overlays)
          (ecco--refine-overlays)
          (let* ((sections (ecco--gather-sections))
                 (rendered-sections (ecco--render-sections sections))
                 (title (buffer-name (current-buffer))))
            (with-current-buffer (get-buffer-create
                                  (format "*ecco for %s*" title))
              (let (standard-output (current-buffer))
                (erase-buffer)
                (insert "<!DOCTYPE html>\n")
                (insert
                 (ecco--output-xml-from-list
                  (funcall ecco-template-function title rendered-sections))))
              (goto-char (point-min))
              (if interactive
                  (if (y-or-n-p "Launch browse-url-of-buffer?")
                      (browse-url-of-buffer)
                    (pop-to-buffer (current-buffer)))
                (current-buffer)))))
      (ecco--cleanup-overlays))))

;;;###autoload
(defun ecco-files (input-spec ecco-output-directory &optional interactive)
  (interactive
   (let* ((input-spec (read-file-name "File or wildcard: "))
          (input-directory (file-name-directory input-spec ))
          (ecco-output-directory (read-directory-name "Output directory: "
                                                      input-directory
                                                      input-directory
                                                      t)))

     (list input-spec ecco-output-directory t)))
  (let* ((new-file-buffers '())
         (kill-buffer-query-functions nil))
    (loop for file in (file-expand-wildcards input-spec)
          for buffer = (or (find-buffer-visiting file)
                           (car (push (find-file-noselect file)
                                      new-file-buffers)))
          for resulting-buffer = (ecco buffer)
          do
          (with-current-buffer resulting-buffer
            (let* ((output-name (format "%s/%s.html" ecco-output-directory
                                        (file-name-sans-extension
                                         (file-name-nondirectory
                                          (buffer-file-name buffer))))))
              (write-file output-name)
              (kill-buffer))))
    (when (and interactive
               new-file-buffers
               (y-or-n-p (format "Close extra buffers opened %s?"
                                 new-file-buffers)))
      (let ((kill-buffer-query-functions nil))
        (mapc #'kill-buffer new-file-buffers)))))


;;; Debug functions
;;; ---------------
;;;
;;; for now, the only debug function is `ecco--gather-sections-debug`
(defun ecco--gather-sections-debug ()
  (interactive)
  (let ((sections (ecco--gather-sections)))
    (with-current-buffer
        (get-buffer-create (format "*ecco--debug for %s*"
                                   (buffer-name (current-buffer))))
      (erase-buffer)
      (dolist (section sections)
        (insert "\n-**- COMMENT -**-\n")
        (insert (car section))
        (insert "\n-**- SNIPPET -**-\n")
        (insert (cdr section)))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

;;; This little command provides the `ecco' feature.
;;;
(provide 'ecco)
