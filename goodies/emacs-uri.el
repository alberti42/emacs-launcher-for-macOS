;;; emacs-uri.el --- Copy an emacs:// URL to the current buffer at point  -*- lexical-binding: t; -*-

;; Companion to the Emacs Launcher macOS app.
;;
;; `emacs-uri-copy' copies an
;;     emacs://file/<percent-encoded-path>+LINE:COLUMN
;; URL for the current buffer to the kill ring.  Paste it into Obsidian, Things, a
;; note, a message — anywhere macOS resolves URL schemes — and clicking it reopens
;; the file at exactly this line and column in Emacs (via Emacs Launcher).
;;
;; The path is percent-encoded per segment, so a literal `+' in a file name becomes
;; %2B and is never mistaken for the `+LINE:COLUMN' delimiter.  The position uses
;; Emacs's own `+LINE:COLUMN' syntax (1-based line and column).

;;; Code:

(require 'url-util)   ; `url-hexify-string'

(defgroup emacs-uri nil
  "Copy emacs:// URLs that reopen a file at point."
  :group 'convenience)

(defcustom emacs-uri-scheme "emacs"
  "URL scheme registered by Emacs Launcher, without the \"://\".
Change this if you renamed the scheme in the app's Info.plist."
  :type 'string)

(defun emacs-uri-for-buffer (&optional buffer)
  "Return an emacs:// URL for BUFFER (default current) at point.
Signal a `user-error' if the buffer is not visiting a file."
  (with-current-buffer (or buffer (current-buffer))
    (let ((file (buffer-file-name)))
      (unless file
        (user-error "Buffer %s is not visiting a file" (buffer-name)))
      (let* ((path (expand-file-name file))
             ;; Hexify each path segment but keep "/" as separators.
             (encoded (mapconcat #'url-hexify-string (split-string path "/") "/")))
        (format "%s://file%s+%d:%d"
                emacs-uri-scheme
                encoded
                (line-number-at-pos)
                (1+ (current-column)))))))

;;;###autoload
(defun emacs-uri-copy ()
  "Copy an emacs:// URL for the current buffer at point to the kill ring."
  (interactive)
  (let ((uri (emacs-uri-for-buffer)))
    (kill-new uri)
    (message "Copied: %s" uri)))

(provide 'emacs-uri)
;;; emacs-uri.el ends here
