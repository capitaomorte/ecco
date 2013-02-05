(require 'newcomment)
(require 'htmlfontify)

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
      (dolist (group groups)
        (insert "<tr><td class='docs'>")
        (insert (ecco--markdown-docs (car group)))
        (insert "</td><td class=code><div class=highlight><pre>")
        (insert (ecco--htmlize-code (cdr group)))
        (insert "</pre></div></td></tr>"))
      (insert "</tbody> 
    </table> 
</div> 
</body> 
</html>")
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(defvar ecco-markdown-program "z:/holy/bin/common/markdown.pl")

(defun ecco--gather-groups ()
  "Returns a list of conses of strings (COMMENT . CODE)"
  (save-excursion
    (goto-char (point-min))
    (let ((stop nil)
          (comments nil)
          (code-snippets nil)
          (temp-buffer (generate-new-buffer " *ecco-decomment-temp*"))
          (mode major-mode))
      (with-current-buffer temp-buffer
        (funcall mode))
      (while (not stop)
        (let ((start (point)))
          (comment-forward (point-max))
          (let ((comment (buffer-substring-no-properties  start (point))))
            (with-current-buffer temp-buffer
              (erase-buffer)
              (insert comment)
              (uncomment-region (point-min)
                                (point-max))
              (push (buffer-substring-no-properties  (point-min) (point-max)) comments))))
        (let ((start (point)))
          (comment-search-forward (point-max) t)
          (let ((comment-beginning (comment-beginning)))
            (if comment-beginning
                (goto-char comment-beginning)
              (setq stop t)))
          (push (buffer-substring start (point)) code-snippets)))
      (kill-buffer temp-buffer)
      (reverse (map 'list #'(lambda (a b) (cons a b))
                    comments
                    code-snippets)))))

(defun ecco--htmlize-code (text)
  "Return TEXT with span classes based on its fontification"
  (let ((hfy-optimisations (list 'keep-overlays
                                 'merge-adjacent-tags
                                 'body-text-only)))
    (htmlfontify-string text)))

(defun ecco--markdown-docs (text)
  (let ((temp-buffer (generate-new-buffer " *ecco-markdown-temp*")))
    (with-temp-buffer
      (insert text)
      (shell-command-on-region (point-min) (point-max) ecco-markdown-program temp-buffer))
    (with-current-buffer temp-buffer
      (buffer-substring-no-properties (point-min) (point-max))))) 

(defun ecco--gather-groups-debug ()
  (interactive)
  (let ((groups (ecco--gather-groups)))
    (with-current-buffer
        (get-buffer-create (format "*ecco--debug for %s*" (buffer-name (current-buffer))))
      (erase-buffer)
      (dolist (group groups)
        (insert "-**- COMMENT -**-\n")
        (insert (car group))
        (insert "-**- SNIPPET -**-\n")
        (insert (cdr group)))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))
