;;; foxmacs-helm.el --- Helm interface for foxmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 adisbladis

;; Author: adisbladis <adisbladis@gmail.com>
;; URL: https://github.com/adisbladis/foxmacs
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (foxmacs "0.1") (helm-core "3.9"))
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

;; Helm interface for foxmacs, with per-source actions, live preview and
;; marking.  Enable `foxmacs-helm-mode' to use it in place of the plain
;; commands.

;;; Code:

(require 'foxmacs)
(require 'helm)

(defun foxmacs-helm--pick (name candidates reveal &rest source-args)
  "Pick from CANDIDATES, (DISPLAY . ID), with Helm source NAME.
REVEAL shows an id in the page as the selection moves; quitting scrolls
the page back.  SOURCE-ARGS go to `helm-make-source'."
  (let ((start (foxmacs-page "position"))
        done)
    (unwind-protect
        (let ((helm-truncate-lines t))
          (helm :sources (apply #'helm-make-source name 'helm-source-sync
                                :candidates candidates
                                :follow 1
                                :persistent-action reveal
                                :action (lambda (id) (setq done t) (funcall reveal id))
                                source-args)
                :buffer "*helm foxmacs page*"))
      (unless done
        (ignore-errors
          (foxmacs-page "restore" (plist-get start :x) (plist-get start :y)))))))

;;;###autoload
(defun foxmacs-helm-jump-to-heading ()
  "Scroll this buffer's page to a heading, following the selection."
  (interactive)
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-jump-to-heading)
    (let ((candidates (mapcar (lambda (heading)
                                (cons (concat (foxmacs--indent (plist-get heading :level))
                                              (plist-get heading :text))
                                      (plist-get heading :id)))
                              (foxmacs-headings))))
      (unless candidates
        (user-error "No headings on this page"))
      (foxmacs-helm--pick "Headings" candidates
                          (lambda (id) (foxmacs-page "scrollTo" id))))))

(defun foxmacs-helm--term ()
  "The first plain word of the Helm pattern."
  (when-let* ((term (seq-find (lambda (term) (not (string-prefix-p "!" term)))
                              (split-string helm-pattern nil t))))
    (string-remove-prefix "^" term)))

(defun foxmacs-helm--snippets (candidates _source)
  "Start long CANDIDATES just before their first match, so it shows."
  (let ((term (foxmacs-helm--term))
        (case-fold-search t))
    (if (not term)
        candidates
      (mapcar (lambda (candidate)
                (let ((pos (ignore-errors (string-match term (car candidate)))))
                  (if (and pos (> pos 40))
                      (cons (concat "…" (substring (car candidate) (- pos 30)))
                            (cdr candidate))
                    candidate)))
              candidates))))

;;;###autoload
(defun foxmacs-helm-search-page ()
  "Search this buffer's page text, following the selection."
  (interactive)
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-search-page)
    (let* ((window foxmacs-window)
           (candidates (foxmacs-page-text window)))
      (unless candidates
        (user-error "No text on this page"))
      (foxmacs-helm--pick "Page" candidates
                          (lambda (target)
                            (foxmacs--frame-call window (car target) "reveal" (cdr target)
                                                 (or (foxmacs-helm--term) "")))
                          :filtered-candidate-transformer #'foxmacs-helm--snippets))))

;;; Hints

(defun foxmacs-helm--hint-candidate (hint)
  "Helm candidate for HINT: its label, then kind, text and URL."
  (cons (concat (propertize (plist-get hint :label) 'face 'foxmacs-hint-label)
                "  " (propertize (format "%-8s" (plist-get hint :kind)) 'face 'shadow)
                "  " (plist-get hint :text)
                (when-let* ((href (plist-get hint :href)))
                  (concat "  " (propertize href 'face 'shadow))))
        hint))

(defun foxmacs-helm--hint-match (candidate)
  "Whether CANDIDATE's label starts with the pattern.
After a leading /, match its words against the rest of CANDIDATE instead."
  (let ((label (car (split-string candidate " " t))))
    (if (string-prefix-p "/" helm-pattern)
        (let ((case-fold-search t)
              (rest (substring candidate (length label))))
          (seq-every-p (lambda (word) (string-match-p (regexp-quote word) rest))
                       (split-string (substring helm-pattern 1) nil t)))
      (string-prefix-p helm-pattern label))))

(defun foxmacs-helm--hint-auto-follow (label-length)
  "Follow the only hint left once a whole label of LABEL-LENGTH is typed."
  (when (and (= (length helm-pattern) label-length)
             (not (string-prefix-p "/" helm-pattern))
             (= (helm-get-candidate-number) 1))
    (helm-exit-minibuffer)))

(defun foxmacs-helm--hint-actions (window new-window)
  "Helm actions from `foxmacs-hint-actions' on marked hints in Firefox WINDOW.
NEW-WINDOW makes opening in a new window the default."
  (let* ((open (seq-find (lambda (entry) (eq (nth 2 entry) 'foxmacs-hint-action-new-window))
                         foxmacs-hint-actions))
         (entries (if (and new-window open)
                      (cons open (remq open foxmacs-hint-actions))
                    foxmacs-hint-actions)))
    (mapcar (lambda (entry)
              (cons (nth 1 entry)
                    (lambda (_) (funcall (nth 2 entry) window (helm-marked-candidates)))))
            entries)))

;;;###autoload
(defun foxmacs-helm-hint (&optional new-window)
  "Label the page's links and fields, then act on the one picked.
Type a label to follow it, or / and words to search the elements' text.
With prefix argument NEW-WINDOW, links open in a new window."
  (interactive "P")
  (if (not foxmacs-window)
      (foxmacs--fallback 'foxmacs-hint)
    (let ((window foxmacs-window)
          hints)
      (unwind-protect
          (progn
            (setq hints (foxmacs-hints-show window))
            (let ((helm-after-update-hook
                   (cons (let ((label-length (length (plist-get (car hints) :label))))
                           (lambda () (foxmacs-helm--hint-auto-follow label-length)))
                         helm-after-update-hook)))
              (helm :sources
                    (helm-make-source "Hints" 'helm-source-sync
                                      :candidates (mapcar #'foxmacs-helm--hint-candidate hints)
                                      :match-strict #'foxmacs-helm--hint-match
                                      :filtered-candidate-transformer
                                      (lambda (candidates _source)
                                        (foxmacs-hints-filter window hints (mapcar #'cdr candidates)
                                                              (if (string-prefix-p "/" helm-pattern)
                                                                  ""
                                                                helm-pattern))
                                        candidates)
                                      :candidate-number-limit 9999
                                      :nohighlight t
                                      :follow 1
                                      :persistent-action (lambda (hint) (foxmacs-hints-select window hints hint))
                                      :action (foxmacs-helm--hint-actions window new-window))
                    :buffer "*helm foxmacs hints*"
                    :prompt (if new-window "Hint, new window: " "Hint: "))))
        (foxmacs-hints-clear window hints)))))

;;; Address bar

(defun foxmacs-helm--actions (open window)
  "Helm actions that call OPEN with a candidate and WINDOW."
  `((,(if window "Open" "Open in new window") . ,(lambda (c) (funcall open c window)))
    ,@(when window
        `(("Open in new window" . ,(lambda (c) (funcall open c nil)))))
    ("Copy" . kill-new)))

(defun foxmacs-helm--group-source (name items window)
  "Helm source NAME for address bar ITEMS of that group."
  (let ((copy `("Copy URL" . ,(lambda (item) (kill-new (plist-get item :url))))))
    (pcase name
      ("Open windows"
       (helm-make-source name 'helm-source-sync
                         :candidates (mapcar (lambda (item) (cons (foxmacs-display item) item)) items)
                         :action `(("Switch to" . ,(lambda (item) (foxmacs-switch-to-window (plist-get item :id))))
                                   ,copy)))
      ("Recently closed"
       (helm-make-source name 'helm-source-sync
                         :candidates (mapcar (lambda (item) (cons (foxmacs-display item) item)) items)
                         :action `(("Restore" . ,(lambda (item) (foxmacs-restore (plist-get item :id))))
                                   ,copy)))
      (_
       (helm-make-source name 'helm-source-sync
                         :candidates (mapcar (lambda (item) (cons (foxmacs-display item) (plist-get item :url)))
                                             items)
                         :action (foxmacs-helm--actions #'foxmacs-visit window))))))

;;;###autoload
(defun foxmacs-helm-open-url (&optional new-window)
  "Open a URL or search, or switch to or restore a Firefox window.
In a Firefox buffer this replaces its page, unless NEW-WINDOW (the
prefix argument) is set.  Elsewhere it opens a new window."
  (interactive "P")
  (let* ((window (and (not new-window) foxmacs-window))
         (items (foxmacs-address-items foxmacs-window)))
    (helm :sources
          (cons (helm-make-source "Open or search" 'helm-source-dummy
                                  :filtered-candidate-transformer
                                  (lambda (_candidates _source)
                                    (unless (string-blank-p helm-pattern)
                                      (list (cons (format "%s %s"
                                                          (if (foxmacs--url helm-pattern) "Open" "Search")
                                                          helm-pattern)
                                                  helm-pattern))))
                                  :action (foxmacs-helm--actions #'foxmacs-go window))
                (mapcar (lambda (group)
                          (foxmacs-helm--group-source
                           group
                           (cl-loop for (g . item) in items when (equal g group) collect item)
                           window))
                        '("Open windows" "Recently closed" "Bookmarks" "History")))
          :buffer "*helm foxmacs*"
          :prompt (if window "Open: " "Open in new window: "))))

;;; Mode

(defvar-keymap foxmacs-helm-mode-map
  "<remap> <foxmacs-open-url>" #'foxmacs-helm-open-url
  "<remap> <foxmacs-jump-to-heading>" #'foxmacs-helm-jump-to-heading
  "<remap> <foxmacs-search-page>" #'foxmacs-helm-search-page
  "<remap> <foxmacs-hint>" #'foxmacs-helm-hint)

;;;###autoload
(define-minor-mode foxmacs-helm-mode
  "Use Helm for foxmacs, through the keys bound to its commands."
  :global t
  :group 'foxmacs)

(provide 'foxmacs-helm)

;;; foxmacs-helm.el ends here
