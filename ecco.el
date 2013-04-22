;;; **ecco** is a port of docco. It renders
;;;
;;; * comments through markdown
;;;
;;; * code through pygments or through emacs's built-int
;;;   `htmlfontify', in case pygments isn't available or the user
;;;   set `ecco-use-pygments' to `nil'
;;;
(require 'newcomment)
(require 'htmlfontify)


;;; Parsing
;;; -------
;;;
;;; The idea is to find comment regions and gather code snippets between
;;; them. We resort to `newcomment.el' comment-navigating functions, place
;;; overlays over the comments and return comments and code as pairs of strings.
;;;
(defun ecco--place-overlays ()
  (ecco--cleanup-overlays)
  (save-excursion
    (goto-char (point-min))
    (loop while (comment-search-forward (point-max) t)
          do
          (let ((overlay (make-overlay (goto-char (nth 8 (syntax-ppss)))
                                       (progn (forward-comment (point-max))
                                              (line-beginning-position)))))
            ;; The "green" is for debug purposes, user should never actually see
            ;; this as the overlays are cleaned up afterwards.
            (overlay-put overlay 'face '(:background  "green"))
            (overlay-put overlay 'ecco t)))))

(defun ecco--gather-groups ()
  (ecco--place-overlays)
  (ecco--refine-overlays)
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
    (loop for (overlay next) on overlays
          for comment = (let ((comment-text (buffer-substring-no-properties (overlay-start overlay)
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
          for snippet = (buffer-substring (overlay-end overlay)
                                          (or (and next
                                                   (overlay-start next))
                                              (point-max)))
          collect (cons comment snippet))))


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
                         (move-overlay overlay (overlay-start overlay) (match-beginning 0)))
                     (unless (= (match-end 0) saved-end)
                       (let ((new-overlay (make-overlay (match-end 0) saved-end)))
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
(defun ecco--render-groups (groups)
  (let ((comments
         (ecco--blob-render (mapcar #'car groups)
                            (ecco--markdown-dividers)
                            #'(lambda (text)
                                (ecco--pipe-text-through-program text ecco-markdown-program))))
        (snippets
         (cond (ecco-use-pygments
                (ecco--blob-render
                 (mapcar #'cdr groups)
                 (ecco--pygments-dividers)
                 #'(lambda (text)
                     (let ((render (ecco--pipe-text-through-program text
                                                                    (format "%s %s -f html"
                                                                            ecco-pygmentize-program
                                                                            (ecco--lexer-args)))))
                       (setq render (replace-regexp-in-string
                                     "^<div class=\"highlight\"><pre>" "" render))
                       (replace-regexp-in-string "</pre></div>$" "" render)))))
               (t
                (let ((hfy-optimisations (list 'keep-overlays
                                               'merge-adjacent-tags
                                               'body-text-only)))
                  (mapcar #'htmlfontify-string (mapcar #'cdr groups)))))))
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
    (shell-command-on-region (point-min) (point-max) program (current-buffer) 'replace)
    (buffer-string)))


;;; User options
;;; ------------
;;;
(defvar ecco-comment-cleanup-functions '(ecco-backtick-and-quote-to-double-backtick
                                         ecco-make-file-link-maybe))

(defun ecco-backtick-and-quote-to-double-backtick ()
  (while (re-search-forward "`\\([^\n]+?\\)'" nil t)
    (replace-match "`\\1`" nil nil)))

(defun ecco-make-file-link-maybe ()
  (let ((files-in-dir (directory-files default-directory nil)))
    (while (and (re-search-forward "[-_[:word:]]+\\.[[:word:]]+" nil t)
                (member (match-string 0) files-in-dir))
      (replace-match (format "[%s](%s.html)"
                             (match-string 0)
                             (match-string 0))))))
(defvar ecco-comment-skip-regexps '())

;;; This group controls the use of pygments.
;;;
(defvar ecco-use-pygments t)
(defvar ecco-pygmentize-program "pygmentize")
(defvar ecco-pygments-lexer 'guess)
(defvar ecco-pygments-lexer-table
  '((lisp-mode . "cl")
    (emacs-lisp-mode . "cl")
    (sh-mode . "sh")
    (c-mode . "c")))

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


;;; This group controls the use of markdown
;;;
(defvar ecco-markdown-program "markdown")

(defun ecco--markdown-dividers ()
  (cons "\n\n##### ECCO-COMMENT-DIVIDER\n\n"
        "\n*<h5>ECCO-COMMENT-DIVIDER</h5>\n*"))



;;; Main entry point
;;; ----------------
;;;
(defun ecco ()
  (interactive)
  (let* ((groups (ecco--gather-groups))
         (rendered-groups (ecco--render-groups groups))
         (title (buffer-name (current-buffer))))
    (with-current-buffer
        (get-buffer-create (format "*ecco for %s*" title))
      (erase-buffer)
      (insert (format "
<!DOCTYPE html>
<html>
<head>
    <meta http-eqiv='content-type' content='text/html;charset=utf-8'>
    <title>%s</title>
    <link rel=stylesheet href=\"http://jashkenas.github.com/docco/resources/docco.css\">
</head>
<body>
<div id=container>
    <div id=background></div>
    <table cellspacing=0 cellpadding=0>
    <thead>
      <tr>
        <th class=docs><h1>%s</h1></th>
        <th class=code></th>
      </tr>
    </thead>
    <tbody> " title title))
      ;; iterate the groups collected before
      ;;
      (dolist (group rendered-groups)
        (insert "<tr><td class='docs'>")
        (insert (car group))
        (insert "</td><td class='code'><div class='highlight'><pre>")
        (insert (cdr group))
        (insert "</pre></div></td></tr>"))
      (insert "</tbody>
    </table>
</div>
</body>
</html>")
      (goto-char (point-min))
      (if (y-or-n-p "Launch browse-url-of-buffer?")
          (browse-url-of-buffer)
          (pop-to-buffer (current-buffer)))))
  (ecco--cleanup-overlays))


;;; Debug functions
;;; ---------------
;;;
;;; for now, the only debug function is `ecco--gather-groups-debug`
(defun ecco--gather-groups-debug ()
  (interactive)
  (let ((groups (ecco--gather-groups)))
    (with-current-buffer
        (get-buffer-create (format "*ecco--debug for %s*" (buffer-name (current-buffer))))
      (erase-buffer)
      (dolist (group groups)
        (insert "\n-**- COMMENT -**-\n")
        (insert (car group))
        (insert "\n-**- SNIPPET -**-\n")
        (insert (cdr group)))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

;;ends here
