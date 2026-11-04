;;; foxmacs.el --- Query and drive Firefox from Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 adisbladis

;; Author: adisbladis <adisbladis@gmail.com>
;; URL: https://github.com/adisbladis/foxmacs
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: hypermedia, convenience
;; SPDX-License-Identifier: GPL-3.0-only

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License version 3, as published
;; by the Free Software Foundation.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
;; Public License for more details.

;;; Commentary:

;; Control Firefox from Emacs, through the foxmacs Firefox extension.  The
;; extension reaches Emacs via a native messaging host (socat) and uses
;; Firefox's framing: a 4-byte little-endian length followed by JSON.
;;
;; The extension prefixes window titles with "[ff:ID] ", which is how EWM
;; surface buffers are mapped to Firefox windows.
;;
;; Prompts use `completing-read'.  For a Helm interface see foxmacs-helm.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dom)

(defgroup foxmacs nil
  "Query and drive Firefox from Emacs."
  :group 'external)

(defcustom foxmacs-socket
  (expand-file-name "foxmacs.sock"
                    (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
  "Socket the Firefox extension connects to."
  :type 'file)

(defcustom foxmacs-timeout 5
  "Seconds to wait for Firefox to answer."
  :type 'number)

(defcustom foxmacs-history-max 10000
  "How many recent history entries `foxmacs-open-url' offers."
  :type 'natnum)

(defcustom foxmacs-capture-file nil
  "File `foxmacs-org-capture' files into.
nil means `org-default-notes-file'."
  :type '(choice (const nil) file))

(defcustom foxmacs-capture-template
  "* %a\n:PROPERTIES:\n:CAPTURED: %U\n:END:\n%i%?"
  "Org capture template for Firefox pages.
%a is the page link and %i the selected text as a quote block."
  :type 'string)

(defcustom foxmacs-edit-modes
  '(("\\`https://github\\.com/" . gfm-mode)
    ("\\`https://\\(gitlab\\.com\\|\\(www\\|old\\)\\.reddit\\.com\\)/" . markdown-mode))
  "Major modes for editing text fields, by page URL regexp.
Other pages, or modes that aren't installed, use `text-mode'."
  :type '(alist :key-type regexp :value-type function))

(defcustom foxmacs-hint-keys "asdfghjkl"
  "Characters for hint labels."
  :type 'string)

(defcustom foxmacs-hint-actions
  '((nil "Follow" foxmacs-hint-action-follow)
    (?n "Open in new window" foxmacs-hint-action-new-window)
    (?c "Copy URL" foxmacs-hint-action-copy-url)
    (?o "Org link" foxmacs-hint-action-org-link)
    (?e "Edit in Emacs" foxmacs-hint-action-edit))
  "What can be done with hinted elements, as (KEY NAME FUNCTION) entries.
FUNCTION is called with the Firefox window and a list of hints.  The
first entry is what `foxmacs-hint' does by default.  Typing KEY before a
label does that entry instead, unless KEY is one of `foxmacs-hint-keys'.
Helm offers every entry as an action."
  :type '(repeat (list (choice (const :tag "No key" nil) character) string function)))

(defcustom foxmacs-fallbacks
  '((foxmacs-jump-to-heading . imenu)
    (foxmacs-search-page . occur)
    (foxmacs-org-capture . org-capture))
  "Commands to run when a foxmacs command is used outside Firefox buffers.
Each entry is (COMMAND . FALLBACK).  Commands without an entry signal
an error there instead."
  :type '(alist :key-type symbol :value-type function))

(defface foxmacs-hint-label '((t :inherit match :weight bold))
  "Face for hint labels in prompts.")

(defconst foxmacs--title-regexp "\\`\\[ff:\\([0-9]+\\)\\] ")

(defvar foxmacs--server nil)
(defvar foxmacs--client nil "The latest Firefox connection.")
(defvar foxmacs--next-id 0)
(defvar foxmacs--replies (make-hash-table)
  "Replies by request id; `:pending' until one arrives.")

(defvar-local foxmacs-window nil
  "Firefox window id of this surface buffer.")

(defvar-local foxmacs-article-url nil
  "URL of the page this article buffer shows.")

(defvar-local foxmacs-article-title nil
  "Title of the page this article buffer shows.")

(defvar ewm-surface-title)
(declare-function org-link-store-props "ol" (&rest plist))
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function org-link-make-string "ol" (link &optional description))
(declare-function bookmark-prop-get "bookmark" (bookmark prop))
(declare-function org-capture "org-capture" (&optional goto keys))
(defvar org-capture-initial)
(defvar org-capture-templates)
(defvar org-default-notes-file)
(defvar org-stored-links)
(declare-function shr-insert-document "shr" (dom))
(declare-function shr-next-link "shr" ())
(declare-function shr-previous-link "shr" ())
(defvar shr-external-rendering-functions)
(declare-function dom-inner-text "dom" (dom))

;;; Connection

(defun foxmacs--length (bytes)
  "The little-endian length at the start of BYTES."
  (logior (aref bytes 0) (ash (aref bytes 1) 8)
          (ash (aref bytes 2) 16) (ash (aref bytes 3) 24)))

(defun foxmacs--filter (proc string)
  "Read framed messages from PROC, keeping partial ones for later."
  (let ((data (concat (process-get proc 'pending) string)))
    (while (and (>= (length data) 4)
                (>= (length data) (+ 4 (foxmacs--length data))))
      (let* ((end (+ 4 (foxmacs--length data)))
             (msg (json-parse-string
                   (decode-coding-string (substring data 4 end) 'utf-8)
                   :object-type 'plist :null-object nil :false-object nil))
             (id (plist-get msg :id)))
        (when (eq (gethash id foxmacs--replies) :pending)
          (puthash id msg foxmacs--replies))
        (setq data (substring data end))))
    (process-put proc 'pending data)))

(defun foxmacs--send (proc object)
  "Send OBJECT to PROC as a framed message."
  (let* ((json (encode-coding-string (json-serialize object) 'utf-8 t))
         (len (length json)))
    (process-send-string
     proc (concat (unibyte-string (logand len 255) (logand (ash len -8) 255)
                                  (logand (ash len -16) 255) (ash len -24))
                  json))))

(defun foxmacs--accept (_server client _message)
  "Use CLIENT, a new Firefox connection, for requests."
  (set-process-query-on-exit-flag client nil)
  (setq foxmacs--client client))

(defun foxmacs-call (method &rest params)
  "Call METHOD in Firefox with PARAMS, a plist, and return the result."
  (let ((proc foxmacs--client)
        (id (setq foxmacs--next-id (1+ foxmacs--next-id)))
        (deadline (+ (float-time) foxmacs-timeout)))
    (unless (process-live-p proc)
      (user-error "Firefox is not connected"))
    (puthash id :pending foxmacs--replies)
    (unwind-protect
        (progn
          (foxmacs--send proc (list :id id :method method :params params))
          (while (eq (gethash id foxmacs--replies) :pending)
            (when (or (> (float-time) deadline) (not (process-live-p proc)))
              (error "No answer from Firefox"))
            (accept-process-output proc 0.05))
          (let ((reply (gethash id foxmacs--replies)))
            (when-let* ((err (plist-get reply :error)))
              (error "Firefox: %s" err))
            (plist-get reply :result)))
      (remhash id foxmacs--replies))))

;;; Surface buffers

(defun foxmacs-strip-title (title)
  "TITLE without the window id the extension puts in front."
  (replace-regexp-in-string foxmacs--title-regexp "" title t t))

(defun foxmacs--update-title ()
  "Tie this surface buffer to its Firefox window, if it is one."
  (when (and ewm-surface-title
             (string-match foxmacs--title-regexp ewm-surface-title))
    (setq-local foxmacs-window
                (string-to-number (match-string 1 ewm-surface-title)))
    (setq-local bookmark-make-record-function
                #'foxmacs-bookmark-make-record)))

(defun foxmacs--window ()
  "This buffer's Firefox window id."
  (or foxmacs-window (user-error "Not a Firefox buffer")))

(defun foxmacs--fallback (command)
  "Run COMMAND's entry in `foxmacs-fallbacks', or signal that it needs Firefox."
  (if-let* ((fallback (alist-get command foxmacs-fallbacks)))
      (call-interactively fallback)
    (user-error "Not a Firefox buffer")))

(defun foxmacs-info ()
  "The URL and title of this buffer's Firefox window, as a plist."
  (foxmacs-call "window" :window (foxmacs--window)))

(defun foxmacs--link ()
  "This buffer's page as (URL . TITLE), or nil outside Firefox and article buffers."
  (cond (foxmacs-article-url
         (cons foxmacs-article-url foxmacs-article-title))
        (foxmacs-window
         (let ((info (foxmacs-info)))
           (cons (plist-get info :url) (plist-get info :title))))))

(defun foxmacs--frame-call (window frame fn &rest args)
  "Call FN from the extension's page.js with ARGS in FRAME of Firefox WINDOW."
  (foxmacs-call "page" :window window :frame frame :fn fn :args (vconcat args)))

(defun foxmacs--page-in (window fn &rest args)
  "Call FN from page.js with ARGS in the top frame of Firefox WINDOW."
  (apply #'foxmacs--frame-call window 0 fn args))

(defun foxmacs--page-all (window fn &rest args)
  "Call FN from page.js with ARGS in every frame of Firefox WINDOW.
Return (FRAME . RESULT) pairs, top frame first."
  (seq-map (lambda (entry) (cons (plist-get entry :frame) (plist-get entry :result)))
           (foxmacs-call "pageAll" :window window :fn fn :args (vconcat args))))

(defun foxmacs-page (fn &rest args)
  "Call FN from the extension's page.js with ARGS in this buffer's page."
  (apply #'foxmacs--page-in (foxmacs--window) fn args))

;;; Completion

(defun foxmacs--unique (candidates)
  "CANDIDATES, (DISPLAY . VALUE) pairs, with repeated DISPLAYs numbered."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (candidate)
              (let ((n (puthash (car candidate) (1+ (gethash (car candidate) seen 0)) seen)))
                (if (> n 1)
                    (cons (format "%s <%d>" (car candidate) n) (cdr candidate))
                  candidate)))
            candidates)))

(defun foxmacs--read (prompt candidates &optional require-match &rest metadata)
  "Read one of CANDIDATES, (DISPLAY . VALUE) pairs, keeping their order.
Return the chosen pair, or with REQUIRE-MATCH nil, the typed string when
it isn't a candidate.  METADATA is extra completion metadata."
  (let* ((table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity)
                                 ,@metadata)
                    (complete-with-action action candidates string pred))))
         (choice (completing-read prompt table nil require-match)))
    (or (assoc choice candidates) choice)))

;;; Commands

(defun foxmacs-eval (code)
  "Run JavaScript CODE in this buffer's page and return the last value."
  (interactive "sJavaScript: ")
  (let ((result (foxmacs-call "eval" :window (foxmacs--window)
                              :code code)))
    (when (called-interactively-p 'any)
      (message "%S" result))
    result))

(defun foxmacs-copy-url ()
  "Copy this buffer's URL."
  (interactive)
  (let ((url (car (or (foxmacs--link) (user-error "Not a Firefox buffer")))))
    (kill-new url)
    (message "%s" url)))

(defun foxmacs-headings ()
  "This buffer's page headings, as plists with :id, :level and :text."
  (append (foxmacs-page "headings") nil))

(defun foxmacs--indent (level)
  "Indentation for a heading of LEVEL."
  (make-string (* 2 (1- level)) ?\s))

;;;###autoload
(defun foxmacs-jump-to-heading ()
  "Scroll this buffer's page to a heading."
  (interactive)
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-jump-to-heading)
    (let* ((candidates (foxmacs--unique
                        (mapcar (lambda (heading) (cons (plist-get heading :text) heading))
                                (foxmacs-headings))))
           ;; Indent with an affix so prefix completion still matches
           (affix (lambda (displays)
                    (mapcar (lambda (display)
                              (list display
                                    (foxmacs--indent
                                     (plist-get (cdr (assoc display candidates)) :level))
                                    ""))
                            displays))))
      (unless candidates
        (user-error "No headings on this page"))
      (foxmacs-page "scrollTo"
                    (plist-get (cdr (foxmacs--read "Heading: " candidates t
                                                   '(category . foxmacs-heading)
                                                   `(affixation-function . ,affix)))
                               :id)))))

(defun foxmacs-page-text (window)
  "The visible text of every frame of Firefox WINDOW, in page order.
Each block is (TEXT . (FRAME . ID)), for the page's reveal function."
  (cl-loop for (frame . blocks) in (foxmacs--page-all window "blocks")
           nconc (seq-map (lambda (block)
                            (cons (plist-get block :text) (cons frame (plist-get block :id))))
                          blocks)))

(defun foxmacs--sentences (text)
  "TEXT split after each sentence."
  (let ((start 0) sentences)
    (while (string-match "[.!?][\"'”’)]*[[:space:]]+" text start)
      (push (string-trim (substring text start (match-end 0))) sentences)
      (setq start (match-end 0)))
    (unless (string-blank-p (substring text start))
      (push (string-trim (substring text start)) sentences))
    (nreverse sentences)))

;;;###autoload
(defun foxmacs-search-page ()
  "Jump to a sentence of this buffer's page, picked by its text."
  (interactive)
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-search-page)
    (let* ((window foxmacs-window)
           (candidates
            (foxmacs--unique
             (cl-loop for (text . target) in (foxmacs-page-text window)
                      nconc (mapcar (lambda (sentence) (cons sentence (cons sentence target)))
                                    (foxmacs--sentences text))))))
      (unless candidates
        (user-error "No text on this page"))
      (pcase-let ((`(,sentence ,frame . ,id)
                   (cdr (foxmacs--read "Search page: " candidates t
                                       '(category . foxmacs-sentence)))))
        (foxmacs--frame-call window frame "reveal" id sentence)))))

;;; Hints

(defun foxmacs--hint-labels (n)
  "N hint labels from `foxmacs-hint-keys'.
They have equal length, so no label is a prefix of another."
  (let* ((keys foxmacs-hint-keys)
         (base (length keys))
         (width 1))
    (while (< (expt base width) n)
      (setq width (1+ width)))
    (cl-loop for i below n
             collect (cl-loop for place from (1- width) downto 0
                              concat (string (aref keys (% (/ i (expt base place)) base)))))))

(defun foxmacs-hints-show (window)
  "Label the links, buttons and fields in every frame of Firefox WINDOW.
Return the hints as plists with :frame, :id, :label, :kind, :text,
:href and :newWindow."
  (let* ((hints (cl-loop for (frame . found) in (foxmacs--page-all window "hintCollect")
                         nconc (seq-map (lambda (hint) (plist-put hint :frame frame)) found))))
    (unless hints
      (user-error "Nothing to hint on this page"))
    (cl-loop for hint in hints
             for label in (foxmacs--hint-labels (length hints))
             do (plist-put hint :label label))
    (dolist (frame (foxmacs--hint-frames hints))
      (foxmacs--frame-call
       window frame "hintDraw"
       (vconcat (cl-loop for hint in hints
                         when (eql (plist-get hint :frame) frame)
                         collect (plist-get hint :label)))))
    hints))

(defun foxmacs--hint-frames (hints)
  "The frames HINTS are in."
  (delete-dups (mapcar (lambda (hint) (plist-get hint :frame)) hints)))

(defun foxmacs-hints-filter (window hints shown typed)
  "Show only the SHOWN of HINTS in Firefox WINDOW, dimming TYPED in their labels."
  (dolist (frame (foxmacs--hint-frames hints))
    (ignore-errors
      (foxmacs--frame-call
       window frame "hintFilter"
       (vconcat (cl-loop for hint in shown
                         when (eql (plist-get hint :frame) frame)
                         collect (plist-get hint :id)))
       typed))))

(defun foxmacs-hints-select (window hints hint)
  "Highlight HINT, one of HINTS in Firefox WINDOW."
  (dolist (frame (foxmacs--hint-frames hints))
    (ignore-errors
      (foxmacs--frame-call window frame "hintSelect"
                           (if (eql frame (plist-get hint :frame)) (plist-get hint :id) -1)))))

(defun foxmacs-hints-clear (window hints)
  "Remove the labels of HINTS from Firefox WINDOW."
  (dolist (frame (foxmacs--hint-frames hints))
    (ignore-errors (foxmacs--frame-call window frame "hintClear"))))

(defun foxmacs-hint-display (hint)
  "HINT's text, kind and URL, for prompts."
  (concat (plist-get hint :text)
          "  " (propertize (plist-get hint :kind) 'face 'shadow)
          (when-let* ((href (plist-get hint :href)))
            (concat "  " (propertize href 'face 'shadow)))))

(defun foxmacs--hint-search (window hints)
  "Pick one of HINTS by its text, showing only matching labels in WINDOW."
  (let ((candidates (foxmacs--unique (mapcar (lambda (hint) (cons (foxmacs-hint-display hint) hint))
                                             hints))))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'post-command-hook
                    (lambda ()
                      (let ((words (split-string (minibuffer-contents-no-properties) nil t))
                            (case-fold-search t))
                        (foxmacs-hints-filter
                         window hints
                         (cl-loop for (display . hint) in candidates
                                  when (seq-every-p (lambda (word)
                                                      (string-match-p (regexp-quote word) display))
                                                    words)
                                  collect hint)
                         "")))
                    nil t))
      (cdr (foxmacs--read "Hint by text: " candidates t '(category . foxmacs-hint))))))

(defun foxmacs-hint-read (window hints)
  "Read one of HINTS in Firefox WINDOW by typing its label.
The page's labels narrow as you type, and a whole label picks its hint.
Typing / first picks by text instead.  Before the label, a key from
`foxmacs-hint-actions' picks what to do with it.  Return (ACTION . HINT),
where ACTION is nil unless one was picked."
  (let* ((typed "")
         action
         ;; Hint keys take precedence
         (usable (seq-filter (lambda (entry)
                               (and (car entry) (not (seq-contains-p foxmacs-hint-keys (car entry)))))
                             foxmacs-hint-actions))
         (menu (mapconcat (lambda (entry) (format ", %c %s" (car entry) (nth 1 entry)))
                          usable)))
    (catch 'done
      (while t
        (let ((matching (seq-filter (lambda (hint) (string-prefix-p typed (plist-get hint :label)))
                                    hints)))
          (foxmacs-hints-filter window hints matching typed)
          (when (and (length= matching 1) (equal typed (plist-get (car matching) :label)))
            (throw 'done (cons action (car matching))))
          (let ((key (read-key (if action
                                   (format "Hint, %s: %s" (nth 1 action) typed)
                                 (format "Hint (/ text%s): %s" menu typed)))))
            (cond ((eq key ?\C-g)
                   (keyboard-quit))
                  ((and (eq key ?/) (string-empty-p typed))
                   (throw 'done (cons action (foxmacs--hint-search window hints))))
                  ((memq key '(?\d backspace))
                   (setq typed (substring typed 0 (max 0 (1- (length typed))))))
                  ((and (characterp key)
                        (seq-some (lambda (hint)
                                    (string-prefix-p (concat typed (string key))
                                                     (plist-get hint :label)))
                                  hints))
                   (setq typed (concat typed (string key))))
                  ((and (string-empty-p typed) (assq key usable))
                   (setq action (assq key usable)))
                  (t (ding)))))))))

(defun foxmacs-hint-follow (window hint new-window)
  "Follow HINT in Firefox WINDOW, or open its link in a new window with NEW-WINDOW."
  (let ((href (plist-get hint :href)))
    (if (and href (or new-window (plist-get hint :newWindow)))
        (foxmacs-visit href)
      (foxmacs--frame-call window (plist-get hint :frame)
                           "hintAct" (plist-get hint :id) "follow"))))

(defun foxmacs-hint-action-follow (window hints)
  "Follow HINTS in Firefox WINDOW."
  (dolist (hint hints)
    (foxmacs-hint-follow window hint nil)))

(defun foxmacs-hint-action-new-window (window hints)
  "Open the links of HINTS in new windows; follow the rest in Firefox WINDOW."
  (dolist (hint hints)
    (foxmacs-hint-follow window hint t)))

(defun foxmacs--hint-links (hints)
  "The (URL TEXT) of those HINTS that are links."
  (or (cl-loop for hint in hints
               when (plist-get hint :href)
               collect (list (plist-get hint :href) (plist-get hint :text)))
      (user-error "Nothing picked is a link")))

(defun foxmacs-hint-action-copy-url (_window hints)
  "Copy the URLs of HINTS."
  (let ((urls (mapcar #'car (foxmacs--hint-links hints))))
    (kill-new (string-join urls "\n"))
    (message "Copied %s" (string-join urls " "))))

(defun foxmacs-hint-action-org-link (_window hints)
  "Copy HINTS as Org links, and store them for `org-insert-link'."
  (require 'ol)
  (let ((links (foxmacs--hint-links hints)))
    (dolist (link links)
      (push link org-stored-links))
    (kill-new (mapconcat (lambda (link) (org-link-make-string (car link) (cadr link)))
                         links "\n"))
    (message "Copied, and stored for `org-insert-link'")))

(defun foxmacs-hint-action-edit (window hints)
  "Edit the text field of the first of HINTS in Firefox WINDOW."
  (let ((hint (car hints)))
    (foxmacs--frame-call window (plist-get hint :frame) "hintAct" (plist-get hint :id) "focus")
    (foxmacs-edit)))

;;;###autoload
(defun foxmacs-hint (&optional new-window)
  "Label the page's links and fields, then follow the one picked.
Type a label, or / to pick by text.  A key from `foxmacs-hint-actions'
typed before the label does that instead.  With prefix argument
NEW-WINDOW, links open in a new window."
  (interactive "P")
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-hint)
    (let* ((window foxmacs-window)
           hints
           (choice (unwind-protect
                       (progn
                         (setq hints (foxmacs-hints-show window))
                         (foxmacs-hint-read window hints))
                     (foxmacs-hints-clear window hints))))
      (pcase-let ((`(,action . ,hint) choice))
        (funcall (cond (action (nth 2 action))
                       (new-window #'foxmacs-hint-action-new-window)
                       (t (nth 2 (car foxmacs-hint-actions))))
                 window (list hint))))))

;;; Address bar

(defun foxmacs--url (input)
  "INPUT as a URL, or nil when it reads as a search."
  (let ((input (string-trim input)))
    (cond ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" input) input)
          ((string-match-p "\\`\\(about\\|view-source\\):" input) input)
          ((string-match-p "[[:space:]]" input) nil)
          ((string-match-p "\\`\\(localhost\\|[0-9]+\\(\\.[0-9]+\\)\\{3\\}\\)\\([:/?#]\\|\\'\\)"
                           input)
           (concat "http://" input))
          ((string-match-p "\\`[^/:?#]+\\.[[:alpha:]]\\{2,\\}\\([:/?#]\\|\\'\\)" input)
           (concat "https://" input)))))

(defun foxmacs-visit (url &optional window)
  "Open URL in Firefox WINDOW, or in a new window when nil."
  (apply #'foxmacs-call "open" :url url (and window (list :window window))))

(defun foxmacs-go (input &optional window)
  "Open INPUT in Firefox WINDOW, searching when it isn't a URL.
Uses a new window when WINDOW is nil."
  (if-let* ((url (foxmacs--url input)))
      (foxmacs-visit url window)
    (apply #'foxmacs-call "search" :text (string-trim input)
           (and window (list :window window)))))

(defun foxmacs-display (item)
  "ITEM's title and dimmed URL, for prompts."
  (let ((url (plist-get item :url))
        (title (plist-get item :title)))
    (if (member title '(nil ""))
        url
      (concat title "  " (propertize url 'face 'shadow)))))

(defun foxmacs-address-items (current)
  "What the address bar offers, as (GROUP . ITEM), with each URL once.
Open windows other than CURRENT come first, then recently closed ones,
bookmarks and history.  ITEMs are plists with :url and :title, and
windows and closed ones an :id too."
  (let ((seen (make-hash-table :test #'equal))
        items)
    (dolist (group
             ;; These need permissions that might not be granted yet
             `(("Open windows" . ,(seq-remove (lambda (item) (eql (plist-get item :id) current))
                                              (ignore-errors (foxmacs-call "windows"))))
               ("Recently closed" . ,(ignore-errors (foxmacs-call "closed")))
               ("Bookmarks" . ,(foxmacs-call "bookmarks"))
               ("History" . ,(foxmacs-call "history" :max foxmacs-history-max))))
      (seq-doseq (item (cdr group))
        (unless (gethash (plist-get item :url) seen)
          (puthash (plist-get item :url) t seen)
          (push (cons (car group) item) items))))
    (nreverse items)))

(defun foxmacs--window-buffer (window)
  "The buffer showing Firefox WINDOW, or nil."
  (seq-find (lambda (buffer) (eql (buffer-local-value 'foxmacs-window buffer) window))
            (buffer-list)))

(defun foxmacs-switch-to-window (window)
  "Select the buffer showing Firefox WINDOW, where it already shows if anywhere."
  (pop-to-buffer (or (foxmacs--window-buffer window)
                     (user-error "No buffer shows that Firefox window"))
                 '((display-buffer-reuse-window display-buffer-same-window)
                   (reusable-frames . t))))

(defun foxmacs-restore (id)
  "Reopen the closed Firefox window or tab with session ID."
  (foxmacs-call "restore" :id id))

;;;###autoload
(defun foxmacs-open-url (&optional new-window)
  "Open a URL or search, or switch to or restore a Firefox window.
Offers open and recently closed windows, bookmarks and history.  Text
that isn't one of them is opened, or searched for.  In a Firefox buffer
this replaces its page, unless NEW-WINDOW (the prefix argument) is set.
Elsewhere it opens a new window."
  (interactive "P")
  (let* ((window (and (not new-window) foxmacs-window))
         (candidates (mapcar (lambda (entry) (cons (foxmacs-display (cdr entry)) entry))
                             (foxmacs-address-items foxmacs-window)))
         (groups (make-hash-table :test #'equal)))
    (pcase-dolist (`(,display ,group . ,_) candidates)
      (puthash display group groups))
    (pcase (foxmacs--read (if window "Open: " "Open in new window: ") candidates nil
                          '(category . foxmacs-address)
                          `(group-function . ,(lambda (candidate transform)
                                                (if transform candidate
                                                  (gethash candidate groups)))))
      ((and (pred stringp) (pred string-blank-p)) (user-error "Nothing to open"))
      ((and (pred stringp) input) (foxmacs-go input window))
      (`(,_ "Open windows" . ,item) (foxmacs-switch-to-window (plist-get item :id)))
      (`(,_ "Recently closed" . ,item) (foxmacs-restore (plist-get item :id)))
      (`(,_ ,_ . ,item) (foxmacs-visit (plist-get item :url) window)))))

;;; Readable view

(defvar-keymap foxmacs-article-mode-map
  :parent special-mode-map
  "TAB" #'shr-next-link
  "<backtab>" #'shr-previous-link)

(define-derived-mode foxmacs-article-mode special-mode "Article"
  "A Firefox page's article, rendered by shr."
  (setq-local imenu-create-index-function #'foxmacs--article-imenu)
  (setq-local bookmark-make-record-function #'foxmacs-bookmark-make-record))

(defvar-local foxmacs--headings nil
  "The article's headings as (TEXT . POSITION), last first.")

(defun foxmacs--article-imenu ()
  "Index of the article's headings."
  (reverse foxmacs--headings))

(defun foxmacs--dom-text (dom)
  "DOM's text; `dom-texts' became `dom-inner-text' in Emacs 31."
  (if (fboundp 'dom-inner-text)
      (dom-inner-text dom)
    (with-no-warnings (dom-texts dom))))

(defun foxmacs--shr-heading (dom)
  "Render heading DOM as shr does, noting it for imenu."
  (let ((start (point)))
    (funcall (intern (format "shr-tag-%s" (dom-tag dom))) dom)
    (push (cons (string-clean-whitespace (foxmacs--dom-text dom))
                (save-excursion (goto-char start) (skip-chars-forward "\n") (point)))
          foxmacs--headings)))

;;;###autoload
(defun foxmacs-read ()
  "Show this buffer's page as a readable article in an Emacs buffer."
  (interactive)
  (require 'shr)
  (let* ((article (foxmacs-call "article" :window (foxmacs--window)))
         (title (or (plist-get article :title) "Untitled"))
         (byline (string-join (delq nil (list (plist-get article :byline)
                                              (plist-get article :siteName)))
                              " · ")))
    (pop-to-buffer-same-window (get-buffer-create (format "*Article: %s*" title)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (foxmacs-article-mode)
      (setq foxmacs-article-url (plist-get article :url)
            foxmacs-article-title title)
      (setq foxmacs--headings (list (cons title (point-min))))
      (insert (propertize title 'face 'shr-h1) "\n")
      (unless (string-blank-p byline)
        (insert (propertize byline 'face 'shadow) "\n"))
      (insert "\n")
      (let ((shr-external-rendering-functions
             (append (mapcar (lambda (tag) (cons tag #'foxmacs--shr-heading))
                             '(h1 h2 h3 h4 h5 h6))
                     shr-external-rendering-functions)))
        (shr-insert-document
         (with-temp-buffer
           (insert (plist-get article :content))
           (libxml-parse-html-region (point-min) (point-max)))))
      (goto-char (point-min)))))

;;; Text fields

(defvar-local foxmacs--edit nil
  "Where this edit buffer's text goes: (WINDOW FRAME FIELD).")

;; Survive a major-mode change in the edit buffer
(put 'foxmacs--edit 'permanent-local t)

(defvar-keymap foxmacs-edit-mode-map
  "C-c C-c" #'foxmacs-edit-finish
  "C-c C-k" #'foxmacs-edit-cancel)

(define-minor-mode foxmacs-edit-mode
  "Minor mode for buffers editing a Firefox text field."
  :lighter " Edit")

(put 'foxmacs-edit-mode 'permanent-local t)

;;;###autoload
(defun foxmacs-edit ()
  "Edit the page's focused text field in an Emacs buffer."
  (interactive)
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-edit)
    (let* ((window foxmacs-window)
           ;; Each frame has its own activeElement, prefer the focused one
           (fields (seq-filter #'cdr (foxmacs--page-all window "field")))
           (choice (or (seq-find (lambda (entry) (plist-get (cdr entry) :focused)) fields)
                       (assq 0 fields)
                       (car fields)
                       (user-error "No text field is focused")))
           (field (cdr choice))
           (url (plist-get (foxmacs-info) :url))
           (mode (assoc-default url foxmacs-edit-modes #'string-match-p))
           (buffer (generate-new-buffer (format "*Firefox edit: %s*" (buffer-name)))))
      (with-current-buffer buffer
        (insert (plist-get field :text))
        (funcall (if (fboundp mode) mode #'text-mode))
        (goto-char (if-let* ((cursor (plist-get field :cursor)))
                       (min (1+ cursor) (point-max))
                     (point-max)))
        (setq foxmacs--edit (list window (car choice) (plist-get field :id)))
        (foxmacs-edit-mode 1)
        (setq header-line-format
              (substitute-command-keys
               "Edit, then \\[foxmacs-edit-finish] to replace or \\[foxmacs-edit-cancel] to cancel")))
      (pop-to-buffer buffer))))

(defun foxmacs-edit-finish ()
  "Write this buffer's text back into its Firefox text field."
  (interactive)
  (pcase-let ((`(,window ,frame ,field)
               (or foxmacs--edit (user-error "Not a Firefox edit buffer")))
              (text (buffer-substring-no-properties (point-min) (point-max)))
              (cursor (1- (point)))
              (buffer (current-buffer)))
    (quit-windows-on buffer)
    (condition-case err
        (progn
          (foxmacs--frame-call window frame "setField" field text cursor)
          (kill-buffer buffer))
      (error
       (pop-to-buffer buffer)
       (message "%s" (error-message-string err))))))

(defun foxmacs-edit-cancel ()
  "Abandon the edit, leaving the text field untouched."
  (interactive)
  (unless foxmacs--edit
    (user-error "Not a Firefox edit buffer"))
  (quit-windows-on (current-buffer) t))

;;; Bookmarks and Org links

(defun foxmacs-bookmark-make-record ()
  "Bookmark this buffer's URL."
  (let ((link (or (foxmacs--link) (user-error "Not a Firefox buffer"))))
    `(,(cdr link)
      (location . ,(car link))
      (handler . foxmacs-bookmark-jump))))

(defun foxmacs-bookmark-jump (bookmark)
  "Open BOOKMARK's URL."
  (browse-url (bookmark-prop-get bookmark 'location)))

(put 'foxmacs-bookmark-jump 'bookmark-handler-type "Firefox")

(defun foxmacs-org-store-link (&optional _interactive)
  "Store a link to this buffer's URL for `org-store-link'."
  (when-let* ((link (ignore-errors (foxmacs--link))))
    (org-link-store-props :type "https" :link (car link) :description (cdr link))))

(with-eval-after-load 'ol
  (org-link-set-parameters "https" :store #'foxmacs-org-store-link))

(defun foxmacs--quote (text)
  "TEXT as an Org quote block, or nil when blank."
  (unless (string-blank-p text)
    ;; Escape lines Org would read as headings or keywords
    (format "#+begin_quote\n%s\n#+end_quote\n"
            (replace-regexp-in-string "^\\(\\*\\|[ \t]*#\\+\\)" "\u200b\\1"
                                      (string-trim text)))))

;;;###autoload
(defun foxmacs-org-capture ()
  "Capture this buffer's page and selected text with Org.
In article buffers the region is the selection."
  (interactive)
  (require 'org-capture)
  (if (not (or foxmacs-window foxmacs-article-url))
      (foxmacs--fallback 'foxmacs-org-capture)
    (let ((org-capture-initial
           (foxmacs--quote
            (cond (foxmacs-article-url
                   (if (use-region-p)
                       (buffer-substring-no-properties (region-beginning) (region-end))
                     ""))
                  ((ignore-errors
                     (seq-some (lambda (entry)
                                 (and (stringp (cdr entry)) (not (string-empty-p (cdr entry)))
                                      (cdr entry)))
                               (foxmacs--page-all foxmacs-window "selection"))))
                  (t ""))))
          (org-capture-templates
           `(("w" "Firefox page" entry
              (file ,(or foxmacs-capture-file org-default-notes-file))
              ,foxmacs-capture-template :empty-lines 1))))
      (org-capture nil "w"))))

;;; Mode

(defun foxmacs--stop ()
  "Stop the server and remove its socket."
  (when (process-live-p foxmacs--server)
    (delete-process foxmacs--server)
    (ignore-errors (delete-file foxmacs-socket)))
  (setq foxmacs--server nil))

;;;###autoload
(define-minor-mode foxmacs-mode
  "Serve the foxmacs Firefox extension."
  :global t
  (foxmacs--stop)
  (remove-hook 'ewm-update-title-hook #'foxmacs--update-title)
  (when foxmacs-mode
    (ignore-errors (delete-file foxmacs-socket))
    (setq foxmacs--server
          (make-network-process :name "foxmacs" :server t :family 'local
                                :service foxmacs-socket :coding 'binary
                                :filter #'foxmacs--filter
                                :log #'foxmacs--accept
                                :noquery t))
    (add-hook 'ewm-update-title-hook #'foxmacs--update-title)))

(provide 'foxmacs)

;;; foxmacs.el ends here
