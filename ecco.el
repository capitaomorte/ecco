;; **ecco** is a port of docco
;;
;; blablabla
;;
;;
(require 'newcomment)
(require 'htmlfontify)


;;; Parsing
;;; -------
;;;
;;; The idea is to gather pairs of comments and code snippets
;;; and render them
;;;
(defun ecco--gather-groups ()
  "Returns a list of conses of strings (COMMENT . SNIPPET)"
  (save-excursion
    (goto-char (point-min))
    (let ((stop nil)
          (comments nil)
          (snippets nil)
          (mode major-mode))
      ;; Maybe this could be turned into a `loop`...
      ;;
      (while (not stop)
        ;; Collect the next comment
        ;;
        (let ((start (point)))
          (comment-forward (point-max))
          (let ((comment (buffer-substring-no-properties  start (point))))
            (with-temp-buffer
              (funcall mode)
              (insert comment)
              (uncomment-region (point-min) (point-max))
              (skip-chars-backward " \t\r\n")
              (push (buffer-substring-no-properties  (point-min) (point)) comments))))
        ;; Collect the next code snippet
        ;;
        (let ((start (line-beginning-position)))
          (comment-search-forward (point-max) t)
          (let ((comment-beginning (comment-beginning)))
            (if comment-beginning
                (goto-char comment-beginning)
              (setq stop t)))
          (push (buffer-substring start
                                  (save-excursion
                                    (skip-chars-backward " \t\r\n")
                                    (point)))
                snippets)))
      ;; Return this a list of conses
      ;;
      (reverse (map 'list #'cons
                    comments
                    snippets)))))

;;; **ecco** renders:
;;;
;;; - comments through markdown
;;;
;;; - code through pygments or through emacs's built-int
;;;   `htmlfontify`, in case pygments isn't available or the user
;;;   set `ecco-use-pygments` to `nil`
;;;
(defun ecco--lexer-args () "-l cl")

(defun ecco--render-snippet (text)
  "Return TEXT with span classes based on its fontification."
  (if ecco-use-pygments
      (ecco--pipe-text-through-program text (format "%s %s -f html"
                                                    ecco-pygmentize-program
                                                    (ecco--lexer-args)))
    (let ((hfy-optimisations (list 'keep-overlays
                                   'merge-adjacent-tags
                                   'body-text-only)))
      (concat
       "<div class=highlight><pre>"
       (htmlfontify-string text)
       "</pre></div>"))))

(defun ecco--render-comment (text)
  "Return markdown output for TEXT."
  (ecco--pipe-text-through-program text ecco-markdown-program))


;;; For now, ecco needs the user to customize these to the paths he
;;; needs using `setq` or similar
;;;
(defvar ecco-markdown-program "markdown")
(defvar ecco-pygmentize-program "pygmentize")
(defvar ecco-use-pygments t)



;;; Piping to external processes
;;; ----------------------------
;;;
;;; ecco uses `shell-command-on-region`
(defun ecco--pipe-text-through-program (text program)
  (with-temp-buffer
    (insert text)
    (shell-command-on-region (point-min) (point-max) program (current-buffer) 'replace)
    (buffer-string)))

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

;;; Main entry point
;;; ----------------
;;;
(defun ecco ()
  (interactive)
  (let ((groups (ecco--gather-groups))
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
      (dolist (group groups)
        (insert "<tr><td class='docs'>")
        (insert (ecco--render-comment (car group)))
        (insert "</td><td class=code>")
        (insert (ecco--render-snippet (cdr group)))
        (insert "</td></tr>"))
      (insert "</tbody>
    </table>
</div>
</body>
</html>")
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))


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
