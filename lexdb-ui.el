;;; lexdb-ui.el --- Dictionary UI rendering -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Universal dictionary UI rendering for lexdb.
;; Capability-aware: only renders features the current adapter supports.
;; Adapters can provide optional hooks for dictionary-specific rendering.

;;; Code:

(require 'lexdb)

;;;; ============================================================
;;;; Utility Functions
;;;; ============================================================

(defsubst lexdb-ui--non-empty-string-p (s)
  "Return t if S is a non-empty string."
  (and s (stringp s) (not (string-empty-p s))))

;;;; ============================================================
;;;; Faces - Universal
;;;; ============================================================

;; Headword and pronunciation
(defface lexdb-headword-face
  '((((background dark))  :foreground "#04cecd" :weight bold)
    (((background light)) :foreground "#fe0000" :weight bold))
  "Face for headword display."
  :group 'lexdb)

(defface lexdb-phonetic-face
  '((((background dark))  :foreground "#04cecd")
    (((background light)) :foreground "#fe0000"))
  "Face for phonetic transcription."
  :group 'lexdb)

;; Lexical information
(defface lexdb-pos-face
  '((((background dark))  :foreground "#FF69B4")
    (((background light)) :foreground "#C71585"))
  "Face for part of speech (hot pink/medium violet red)."
  :group 'lexdb)

(defface lexdb-inflection-face
  '((((background dark))  :foreground "#A0A0A0" :slant italic)
    (((background light)) :foreground "#555555" :slant italic))
  "Face for inflections (past tense, plural, etc.)."
  :group 'lexdb)

(defface lexdb-inflection-link-face
  '((((background dark))  :foreground "#7CB8FF" :slant italic :underline t)
    (((background light)) :foreground "#0066CC" :slant italic :underline t))
  "Face for clickable inflection words."
  :group 'lexdb)

(defface lexdb-grammar-face
  '((((background dark))  :foreground "#6B8E23")
    (((background light)) :foreground "#6B8E23"))
  "Face for grammar annotations [countable] etc."
  :group 'lexdb)

(defface lexdb-register-face
  '((((background dark))  :foreground "#A9A9A9" :slant italic)
    (((background light)) :foreground "#666666" :slant italic))
  "Face for register labels (formal, informal, etc)."
  :group 'lexdb)

;; Frequency and levels
(defface lexdb-frequency-face
  '((((background dark))  :foreground "#4A90D9" :weight bold)
    (((background light)) :foreground "#4A90D9" :weight bold))
  "Face for frequency markers."
  :group 'lexdb)

(defface lexdb-frequency-dots-face
  '((((background dark))  :foreground "#04cecd")
    (((background light)) :foreground "#fe0000"))
  "Face for frequency dots ●●●."
  :group 'lexdb)

(defface lexdb-cefr-face
  '((((background dark))  :foreground "#32CD32" :weight bold)
    (((background light)) :foreground "#228B22" :weight bold))
  "Face for CEFR level markers."
  :group 'lexdb)

;; Definitions and examples
(defface lexdb-sense-num-face
  '((((background dark))  :foreground "#FFFFFF" :weight bold)
    (((background light)) :foreground "#000000" :weight bold))
  "Face for sense numbers."
  :group 'lexdb)

(defface lexdb-signpost-face
  '((((background dark))  :foreground "#E0A040" :weight bold)
    (((background light)) :foreground "#996600" :weight bold))
  "Face for signpost/guide words (e.g., MOVE FROM A FIXED POINT)."
  :group 'lexdb)

(defface lexdb-definition-face
  '((((background dark))  :foreground "#B8B8B8")
    (((background light)) :foreground "#333333"))
  "Face for definitions."
  :group 'lexdb)

(defface lexdb-example-face
  '((((background dark))  :foreground "#8B7355" :slant italic)
    (((background light)) :foreground "#666655" :slant italic))
  "Face for examples."
  :group 'lexdb)

(defface lexdb-example-highlight-face
  '((((background dark))  :foreground "#E0A040" :weight bold :slant italic)
    (((background light)) :foreground "#996600" :weight bold :slant italic))
  "Face for highlighted words in examples (nodeword)."
  :group 'lexdb)

(defface lexdb-collocation-highlight-face
  '((((background dark))  :foreground "#7CB8FF" :weight bold :slant italic)
    (((background light)) :foreground "#0066CC" :weight bold :slant italic))
  "Face for highlighted collocations in examples (colloinexa)."
  :group 'lexdb)

(defface lexdb-chinese-face
  '((((background dark))  :foreground "#E0B050")
    (((background light)) :foreground "#806030"))
  "Face for Chinese definitions and examples."
  :group 'lexdb)

(defface lexdb-grammar-pattern-face
  '((((background dark))  :foreground "#7CB8FF" :weight bold)
    (((background light)) :foreground "#0066CC" :weight bold))
  "Face for grammar patterns (e.g., 'be required to do something')."
  :group 'lexdb)

;; Relations
(defface lexdb-crossref-face
  '((((background dark))  :foreground "#6B8E23")
    (((background light)) :foreground "#6B8E23"))
  "Face for cross references."
  :group 'lexdb)

(defface lexdb-phrase-face
  '((((background dark))  :foreground "#C8C8C8")
    (((background light)) :foreground "#333333"))
  "Face for phrases."
  :group 'lexdb)

;; Phrasal Verbs
(defface lexdb-phrasal-verb-headword-face
  '((((background dark))  :foreground "#FFD700" :weight bold)
    (((background light)) :foreground "#B8860B" :weight bold))
  "Face for phrasal verb headword (e.g., 'call back')."
  :group 'lexdb)

(defface lexdb-phrasal-verb-pos-face
  '((((background dark))  :foreground "#E9967A")
    (((background light)) :foreground "#CD5C5C"))
  "Face for phrasal verb POS marker."
  :group 'lexdb)

(defface lexdb-phrasal-verb-lexunit-face
  '((((background dark))  :foreground "#87CEEB" :weight bold)
    (((background light)) :foreground "#4682B4" :weight bold))
  "Face for phrasal verb lexical unit (e.g., 'call (somebody) back')."
  :group 'lexdb)

(defface lexdb-synonym-face
  '((((background dark))  :foreground "#6B8E23")
    (((background light)) :foreground "#6B8E23"))
  "Face for synonyms."
  :group 'lexdb)

;; Collocations
(defface lexdb-collocation-header-face
  '((((background dark))  :foreground "#B8B8B8" :weight bold :underline t)
    (((background light)) :foreground "#333333" :weight bold :underline t))
  "Face for COLLOCATIONS header."
  :group 'lexdb)

(defface lexdb-collocation-category-face
  '((((background dark))  :foreground "#E0E0E0" :weight bold :background "#3a3a4a" :extend t :underline t)
    (((background light)) :foreground "#333333" :weight bold :background "#d8d8e8" :extend t :underline t))
  "Face for collocation category headers (ADJECTIVES, VERBS, etc.)."
  :group 'lexdb)

(defface lexdb-collocation-word-face
  '((((background dark))  :foreground "#7CB8FF")
    (((background light)) :foreground "#0066CC"))
  "Face for collocation words."
  :group 'lexdb)

(defface lexdb-collocation-gloss-face
  '((((background dark))  :foreground "#B8B8B8")
    (((background light)) :foreground "#333333"))
  "Face for collocation explanations."
  :group 'lexdb)

(defface lexdb-collocation-example-face
  '((((background dark))  :foreground "#8B7355" :slant italic)
    (((background light)) :foreground "#666655" :slant italic))
  "Face for collocation examples."
  :group 'lexdb)

;; Tab bar
(defface lexdb-tab-active-face
  '((((background dark))  :foreground "#FFFFFF" :background "#4A90D9" :weight bold :box (:line-width 1 :style released-button))
    (((background light)) :foreground "#FFFFFF" :background "#2060A0" :weight bold :box (:line-width 1 :style released-button)))
  "Face for active tab."
  :group 'lexdb)

(defface lexdb-tab-inactive-face
  '((((background dark))  :foreground "#888888" :background "#333333" :box (:line-width 1 :style released-button))
    (((background light)) :foreground "#666666" :background "#E0E0E0" :box (:line-width 1 :style released-button)))
  "Face for inactive tab."
  :group 'lexdb)

(defface lexdb-audio-indicator-face
  '((((background dark))  :foreground "#4A90D9")
    (((background light)) :foreground "#2060A0"))
  "Face for audio indicators (🔊)."
  :group 'lexdb)

(defface lexdb-collocation-background-face
  '((((background dark))  :background "#1e1c1a" :extend t)
    (((background light)) :background "#f8f5f0" :extend t))
  "Face for collocations section background."
  :group 'lexdb)

;; Etymology
(defface lexdb-origin-face
  '((((background dark))  :foreground "#A9A9A9")
    (((background light)) :foreground "#666666"))
  "Face for word origin."
  :group 'lexdb)

;; UI elements
(defface lexdb-button-face
  '((((background dark))  :foreground "#B8B8B8")
    (((background light)) :foreground "#333333"))
  "Face for buttons."
  :group 'lexdb)

(defface lexdb-fold-header-face
  '((((background dark))  :foreground "#B8B8B8" :box (:line-width -1 :color "#555555"))
    (((background light)) :foreground "#333333" :box (:line-width -1 :color "#AAAAAA")))
  "Face for foldable section headers."
  :group 'lexdb)

(defface lexdb-separator-face
  '((((background dark))  :foreground "#555555")
    (((background light)) :foreground "#CCCCCC"))
  "Face for separators."
  :group 'lexdb)

(defface lexdb-label-face
  '((((background dark))  :foreground "#A9A9A9" :weight bold)
    (((background light)) :foreground "#666666" :weight bold))
  "Face for section labels."
  :group 'lexdb)

;;;; ============================================================
;;;; ============================================================
;;;; Audio Playback
;;;; ============================================================

(defun lexdb-ui--play-audio (path &optional audio-dir)
  "Play audio file at PATH, optionally relative to AUDIO-DIR."
  (when path
    (let ((full-path (if audio-dir
                         (expand-file-name path audio-dir)
                       path)))
      (if (file-exists-p full-path)
          (start-process "lexdb-audio" nil lexdb-audio-player full-path)
        (message "Audio file not found: %s" full-path)))))

;;;; ============================================================
;;;; Foldable Sections
;;;; ============================================================

(defun lexdb-ui--toggle-section (section-id)
  "Toggle visibility of SECTION-ID."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (equal (overlay-get ov 'lexdb-section) section-id)
      (overlay-put ov 'invisible (not (overlay-get ov 'invisible))))))

(defun lexdb-ui--insert-foldable (header content &optional initially-hidden)
  "Insert a foldable section with HEADER button and CONTENT.
If INITIALLY-HIDDEN is non-nil, content starts collapsed."
  (let ((section-id (format "lexdb-fold-%d" (random 100000))))
    (insert-text-button header
                        'face 'lexdb-fold-header-face
                        'action (lambda (_) (lexdb-ui--toggle-section section-id))
                        'help-echo "Click to expand/collapse")
    (insert "\n")
    (let ((start (point)))
      (insert content)
      (unless (eq (char-before) ?\n) (insert "\n"))
      (let ((ov (make-overlay start (point))))
        (overlay-put ov 'lexdb-section section-id)
        (overlay-put ov 'invisible initially-hidden)
        (overlay-put ov 'evaporate t)))))

;;;; ============================================================
;;;; Tab Bar Component
;;;; ============================================================

(defun lexdb-ui--switch-tab (tab-group tab-id)
  "Switch to TAB-ID within TAB-GROUP, hiding others.
If TAB-ID is already visible, collapse it (toggle behavior)."
  (let ((is-visible nil))
    ;; Check if this tab is currently visible
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (equal (overlay-get ov 'lexdb-tab-group) tab-group)
                 (equal (overlay-get ov 'lexdb-tab-id) tab-id)
                 (not (overlay-get ov 'invisible)))
        (setq is-visible t)))
    ;; Hide all content overlays in this group
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (equal (overlay-get ov 'lexdb-tab-group) tab-group)
        (overlay-put ov 'invisible t)))
    ;; If not previously visible, show selected tab content
    (unless is-visible
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (equal (overlay-get ov 'lexdb-tab-group) tab-group)
                   (equal (overlay-get ov 'lexdb-tab-id) tab-id))
          (overlay-put ov 'invisible nil))))
    ;; Update tab button faces
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (equal (overlay-get ov 'lexdb-tab-button-group) tab-group)
                 (overlay-get ov 'lexdb-tab-button-id))
        (let ((btn-id (overlay-get ov 'lexdb-tab-button-id)))
          (overlay-put ov 'face
                       (if (and (equal btn-id tab-id) (not is-visible))
                           'lexdb-tab-active-face
                         'lexdb-tab-inactive-face)))))))

(defun lexdb-ui--insert-tab-bar (tabs tab-group)
  "Insert a tab bar with TABS in TAB-GROUP.
TABS is a list of (id label content) tuples."
  (when tabs
    ;; Insert tab buttons on one line
    (let ((first t))
      (dolist (tab tabs)
        (let* ((tab-id (nth 0 tab))
               (label (nth 1 tab)))
          (unless first (insert "  "))
          (setq first nil)
          ;; Record start AFTER the spacing
          (let ((btn-start (point)))
            (insert-text-button (format "[ %s ]" label)
                                'action (lambda (_)
                                          (lexdb-ui--switch-tab tab-group tab-id))
                                'help-echo (format "Show %s" label))
            ;; Mark button with overlay for face updates (only covers the button text)
            (let ((btn-ov (make-overlay btn-start (point))))
              (overlay-put btn-ov 'lexdb-tab-button-group tab-group)
              (overlay-put btn-ov 'lexdb-tab-button-id tab-id)
              (overlay-put btn-ov 'face 'lexdb-tab-inactive-face)
              (overlay-put btn-ov 'evaporate t))))))
    (insert "\n")
    ;; Insert all content areas (initially hidden)
    (dolist (tab tabs)
      (let* ((tab-id (nth 0 tab))
             (content (nth 2 tab))
             (start (point)))
        (insert content)
        (unless (eq (char-before) ?\n) (insert "\n"))
        (let ((content-ov (make-overlay start (point))))
          (overlay-put content-ov 'lexdb-tab-group tab-group)
          (overlay-put content-ov 'lexdb-tab-id tab-id)
          (overlay-put content-ov 'invisible t)
          (overlay-put content-ov 'evaporate t))))
    (insert "\n")))

;;;; ============================================================
;;;; Render Helpers
;;;; ============================================================

(defun lexdb-ui--insert-highlighted-text (text base-face)
  "Insert TEXT with highlight markers processed.
BASE-FACE is the default face for non-highlighted text.
Markers: <<hw>>...<</hw>> for highlighted words,
         <<co>>...<</co>> for collocation highlights."
  (let ((pos 0)
        (len (length text)))
    (while (< pos len)
      (cond
       ;; Check for <<hw>> marker
       ((and (< (+ pos 6) len)
             (string= (substring text pos (+ pos 6)) "<<hw>>"))
        (let ((end-pos (string-match "<</hw>>" text pos)))
          (if end-pos
              (progn
                (insert (propertize (substring text (+ pos 6) end-pos)
                                    'face 'lexdb-example-highlight-face))
                (setq pos (+ end-pos 7)))
            ;; No closing tag, insert as-is
            (insert (propertize (substring text pos (+ pos 1)) 'face base-face))
            (setq pos (1+ pos)))))
       ;; Check for <<co>> marker
       ((and (< (+ pos 6) len)
             (string= (substring text pos (+ pos 6)) "<<co>>"))
        (let ((end-pos (string-match "<</co>>" text pos)))
          (if end-pos
              (progn
                (insert (propertize (substring text (+ pos 6) end-pos)
                                    'face 'lexdb-collocation-highlight-face))
                (setq pos (+ end-pos 7)))
            ;; No closing tag, insert as-is
            (insert (propertize (substring text pos (+ pos 1)) 'face base-face))
            (setq pos (1+ pos)))))
       ;; Regular character
       (t
        ;; Find next marker or end
        (let ((next-hw (string-match "<<hw>>" text pos))
              (next-co (string-match "<<co>>" text pos)))
          (let ((next-marker (cond
                              ((and next-hw next-co) (min next-hw next-co))
                              (next-hw next-hw)
                              (next-co next-co)
                              (t len))))
            (when (> next-marker pos)
              (insert (propertize (substring text pos next-marker) 'face base-face)))
            (setq pos next-marker))))))))

(defvar lexdb-ui--fold-counter 0
  "Counter for generating unique fold IDs.")

(defun lexdb-ui--insert-foldable (title content-fn &optional initially-collapsed)
  "Insert a foldable section with TITLE.
CONTENT-FN is a function that inserts the content.
If INITIALLY-COLLAPSED is non-nil, start collapsed."
  (let* ((fold-id (cl-incf lexdb-ui--fold-counter))
         (title-start (point)))
    ;; Insert title with indicator
    (let ((indicator-start (point)))
      (insert "  ")  ; Placeholder for indicator
      (let ((indicator-ov (make-overlay indicator-start (point))))
        (overlay-put indicator-ov 'lexdb-fold-indicator t)
        (overlay-put indicator-ov 'lexdb-fold-id fold-id)
        (overlay-put indicator-ov 'before-string
                     (propertize (if initially-collapsed "▶ " "▼ ")
                                 'face 'lexdb-fold-indicator-face))
        (overlay-put indicator-ov 'evaporate t)))
    ;; Insert title text as button
    (let ((btn-start (point)))
      (insert title)
      (let ((title-ov (make-overlay btn-start (point))))
        (overlay-put title-ov 'lexdb-fold-id fold-id)
        (overlay-put title-ov 'mouse-face 'highlight)
        (overlay-put title-ov 'keymap
                     (let ((map (make-sparse-keymap)))
                       (define-key map (kbd "RET")
                         (lambda () (interactive)
                           (lexdb-ui--toggle-fold-by-id fold-id)))
                       (define-key map [mouse-1]
                         (lambda () (interactive)
                           (lexdb-ui--toggle-fold-by-id fold-id)))
                       map))
        (overlay-put title-ov 'evaporate t)))
    (insert "\n")
    ;; Insert content
    (let ((content-start (point)))
      (funcall content-fn)
      (let ((content-ov (make-overlay content-start (point))))
        (overlay-put content-ov 'lexdb-fold-content t)
        (overlay-put content-ov 'lexdb-fold-id fold-id)
        (overlay-put content-ov 'invisible initially-collapsed)
        (overlay-put content-ov 'evaporate t)))))

(defun lexdb-ui--toggle-fold-by-id (fold-id)
  "Toggle fold by FOLD-ID."
  (let ((content-ov (lexdb-ui--find-fold-content fold-id))
        (indicator-ov (lexdb-ui--find-fold-indicator fold-id)))
    (when content-ov
      (let ((currently-hidden (overlay-get content-ov 'invisible)))
        (overlay-put content-ov 'invisible (not currently-hidden))
        (when indicator-ov
          (overlay-put indicator-ov 'before-string
                       (propertize (if currently-hidden "▼ " "▶ ")
                                   'face 'lexdb-fold-indicator-face)))))))

(defun lexdb-ui--number-to-superscript (str)
  "Convert trailing numbers in STR to superscript Unicode characters.
E.g., 'mother1' -> 'mother¹', 'swing2' -> 'swing²'."
  (let ((superscripts '((?0 . ?⁰) (?1 . ?¹) (?2 . ?²) (?3 . ?³) (?4 . ?⁴)
                        (?5 . ?⁵) (?6 . ?⁶) (?7 . ?⁷) (?8 . ?⁸) (?9 . ?⁹))))
    (if (string-match "\\([^0-9]+\\)\\([0-9]+\\)$" str)
        (let ((word (match-string 1 str))
              (num (match-string 2 str)))
          (concat word
                  (mapconcat (lambda (c)
                               (char-to-string (or (cdr (assq c superscripts)) c)))
                             num "")))
      str)))

(defun lexdb-ui--render-headword (entry)
  "Render headword for ENTRY.
Converts trailing numbers to superscript (e.g., mother1 -> mother¹)."
  (let* ((display (or (lexdb-entry-headword-display entry)
                      (lexdb-entry-headword entry)))
         (formatted (lexdb-ui--number-to-superscript display)))
    (when (lexdb-ui--non-empty-string-p formatted)
      (insert (propertize formatted 'face 'lexdb-headword-face)))))

(defun lexdb-ui--render-pronunciations (entry adapter)
  "Render pronunciations for ENTRY using ADAPTER."
  (let ((prons (lexdb-entry-pronunciations entry))
        (uk-ipa nil)
        (us-ipa nil))
    ;; Collect UK and US pronunciations
    (dolist (pron prons)
      (when-let ((ipa (lexdb-pronunciation-ipa pron)))
        (when (lexdb-ui--non-empty-string-p ipa)
          (pcase (lexdb-pronunciation-variant pron)
            ('uk (setq uk-ipa ipa))
            ('us (setq us-ipa ipa))))))
    ;; Render in format: /uk $ us/ (single pair of slashes)
    (when (or uk-ipa us-ipa)
      (insert " ")
      (cond
       ;; Both UK and US - format: /uk $ us/
       ((and uk-ipa us-ipa)
        (insert (propertize (format "/%s $ %s/" uk-ipa us-ipa) 'face 'lexdb-phonetic-face)))
       ;; UK only
       (uk-ipa
        (insert (propertize (format "/%s/" uk-ipa) 'face 'lexdb-phonetic-face)))
       ;; US only
       (us-ipa
        (insert (propertize (format "/%s/" us-ipa) 'face 'lexdb-phonetic-face)))))))

(defun lexdb-ui--render-frequency (entry adapter)
  "Render frequency information for ENTRY using ADAPTER."
  (let* ((caps (lexdb-adapter-capabilities adapter))
         (ns (symbol-name (lexdb-adapter-id adapter)))
         (meta (lexdb-entry-metadata entry)))
    ;; Frequency dots (●●● etc)
    (when (memq 'frequency-band caps)
      (when-let ((dots (lexdb-meta-get meta ns "frequency-dots")))
        (when (lexdb-ui--non-empty-string-p dots)
          (insert " " (propertize dots 'face 'lexdb-frequency-dots-face)))))
    ;; Frequency level (S1 W2 etc) - use adapter hook if provided
    (when (memq 'frequency-band caps)
      (when-let ((freq (lexdb-meta-get meta ns "frequency")))
        (when (lexdb-ui--non-empty-string-p freq)
          (if-let ((hook (lexdb-adapter-render-frequency-fn adapter)))
              (when-let ((rendered (funcall hook freq)))
                (insert " " rendered))
            (insert " " (propertize freq 'face 'lexdb-frequency-face))))))
    ;; CEFR level
    (when (memq 'cefr caps)
      (when-let ((cefr (lexdb-meta-get meta ns "cefr-level")))
        (when (lexdb-ui--non-empty-string-p cefr)
          (insert " " (propertize (format "[%s]" cefr) 'face 'lexdb-cefr-face)))))))

(defun lexdb-ui--render-pos (entry adapter)
  "Render part of speech for ENTRY."
  (when (lexdb-adapter-has-capability-p adapter 'pos)
    (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
           (pos (lexdb-meta-get (lexdb-entry-metadata entry) ns "pos")))
      (when (lexdb-ui--non-empty-string-p pos)
        (insert " " (propertize pos 'face 'lexdb-pos-face))))))

(defun lexdb-ui--render-audio-buttons (entry adapter)
  "Render audio indicators for ENTRY. Use C-c C-c to play."
  (let* ((caps (lexdb-adapter-capabilities adapter))
         (audio-dir (lexdb-adapter-audio-dir adapter))
         (ns (symbol-name (lexdb-adapter-id adapter)))
         (meta (lexdb-entry-metadata entry))
         (has-audio nil))
    (when audio-dir
      ;; UK audio
      (when (memq 'audio-uk caps)
        (when-let ((path (lexdb-meta-get meta ns "audio-uk")))
          (when (lexdb-ui--non-empty-string-p path)
            (setq has-audio t)
            (insert (propertize "🔊 UK"
                                'face 'lexdb-audio-indicator-face
                                'lexdb-audio-path path
                                'lexdb-audio-dir audio-dir
                                'help-echo "C-c C-c to play UK pronunciation")))))
      ;; US audio
      (when (memq 'audio-us caps)
        (when-let ((path (lexdb-meta-get meta ns "audio-us")))
          (when (lexdb-ui--non-empty-string-p path)
            (when has-audio (insert "  "))
            (setq has-audio t)
            (insert (propertize "🔊 US"
                                'face 'lexdb-audio-indicator-face
                                'lexdb-audio-path path
                                'lexdb-audio-dir audio-dir
                                'help-echo "C-c C-c to play US pronunciation"))))))
    (when has-audio (insert "\n"))))

(defun lexdb-ui--render-inflections (entry adapter)
  "Render inflections (past tense, plural, etc.) for ENTRY."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (meta (lexdb-entry-metadata entry))
         (infl-text (lexdb-meta-get meta ns "inflections"))
         (relations (lexdb-entry-relations entry))
         (inflections (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'inflection)) relations)))
    ;; Display full inflection text if available
    (when (lexdb-ui--non-empty-string-p infl-text)
      (insert " ")
      ;; Make inflection words clickable within the text
      (let ((text (concat "(" infl-text ")"))
            (start 0))
        ;; Try to make each inflection word clickable
        (dolist (infl inflections)
          (let* ((target (lexdb-relation-target infl))
                 (raw-link (lexdb-relation-target-link infl))
                 (link (when raw-link
                         (if (string-match "\\`\\([^#]+\\)" raw-link)
                             (match-string 1 raw-link)
                           raw-link)))
                 (pos (string-match (regexp-quote target) text start)))
            (when pos
              ;; Insert text before the match
              (when (> pos start)
                (insert (propertize (substring text start pos) 'face 'lexdb-inflection-face)))
              ;; Insert clickable word
              (if link
                  (insert-text-button target
                                      'face 'lexdb-inflection-link-face
                                      'action (lambda (_) (lexdb-search link))
                                      'help-echo (format "Look up: %s" link))
                (insert (propertize target 'face 'lexdb-inflection-face)))
              (setq start (+ pos (length target))))))
        ;; Insert remaining text
        (when (< start (length text))
          (insert (propertize (substring text start) 'face 'lexdb-inflection-face)))))))

(defun lexdb-ui--render-sense (sense adapter)
  "Render a single SENSE."
  (let ((caps (lexdb-adapter-capabilities adapter))
        (audio-dir (lexdb-adapter-audio-dir adapter))
        (ns (symbol-name (lexdb-adapter-id adapter))))
    ;; Sense number
    (when-let ((num (lexdb-sense-number sense)))
      (when (lexdb-ui--non-empty-string-p num)
        (insert (propertize num 'face 'lexdb-sense-num-face) " ")))
    ;; Signpost (guide word)
    (when-let ((signpost (lexdb-sense-signpost sense)))
      (when (lexdb-ui--non-empty-string-p signpost)
        (insert (propertize signpost 'face 'lexdb-signpost-face) " ")))
    ;; Grammar label
    (when (memq 'grammar caps)
      (when-let ((gram (lexdb-sense-grammar sense)))
        (when (lexdb-ui--non-empty-string-p gram)
          (insert (propertize gram 'face 'lexdb-grammar-face) " "))))
    ;; Definition (English) - this may be just the lexunit for senses with subsenses
    (let ((def (lexdb-sense-definition sense)))
      (when (lexdb-ui--non-empty-string-p def)
        (insert (propertize def 'face 'lexdb-definition-face))))
    ;; Chinese definition (if capability present)
    (when (memq 'chinese-definition caps)
      (when-let ((def-zh (lexdb-meta-get (lexdb-sense-metadata sense) ns "definition-zh")))
        (when (lexdb-ui--non-empty-string-p def-zh)
          (insert " " (propertize def-zh 'face 'lexdb-chinese-face)))))
    (insert "\n")

    ;; Subsenses (a, b, c)
    (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
      (when subsenses
        (let ((sub-list (if (vectorp subsenses) (append subsenses nil) subsenses)))
          (dolist (sub sub-list)
            (let ((sub-num (cdr (assoc 'number sub)))
                  (sub-def (cdr (assoc 'definition sub)))
                  (sub-labels (cdr (assoc 'labels sub)))
                  (sub-examples (cdr (assoc 'examples sub))))
              ;; Subsense number and labels
              (insert "  ")
              (when sub-num
                (insert (propertize sub-num 'face 'lexdb-sense-num-face) " "))
              ;; Labels (register, etc.)
              (when sub-labels
                (let ((labels-list (if (vectorp sub-labels) (append sub-labels nil) sub-labels)))
                  (dolist (label labels-list)
                    (let ((lvalue (cdr (assoc 'value label))))
                      (when lvalue
                        (insert (propertize lvalue 'face 'lexdb-register-face) " "))))))
              ;; Definition
              (when sub-def
                (insert (propertize sub-def 'face 'lexdb-definition-face)))
              (insert "\n")
              ;; Examples
              (when sub-examples
                (let ((ex-list (if (vectorp sub-examples) (append sub-examples nil) sub-examples)))
                  (dolist (ex ex-list)
                    (let ((ex-text (cdr (assoc 'text ex)))
                          (ex-audio (cdr (assoc 'audio_path ex))))
                      (when (and ex-text (not (string-empty-p ex-text)))
                        ;; Audio indicator at start if audio available
                        (if (and ex-audio (not (string-empty-p ex-audio)))
                            (insert (propertize "    🔊 "
                                                'face 'lexdb-audio-indicator-face
                                                'lexdb-audio-path ex-audio
                                                'lexdb-audio-dir audio-dir
                                                'help-echo "C-c C-c to play"))
                          (insert "    "))
                        (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                        (insert "\n")))))))))))

    ;; Grammar patterns (e.g., "be required to do something")
    (dolist (gp (lexdb-sense-grammar-patterns sense))
      (let ((pattern (lexdb-grammar-pattern-pattern gp)))
        (when (lexdb-ui--non-empty-string-p pattern)
          (insert "  " (propertize pattern 'face 'lexdb-grammar-pattern-face) "\n")
          ;; Grammar pattern examples
          (dolist (ex (lexdb-grammar-pattern-examples gp))
            (let ((ex-text (lexdb-example-text ex))
                  (audio-path (lexdb-example-audio ex)))
              (when (lexdb-ui--non-empty-string-p ex-text)
                ;; Audio indicator at start if audio available
                (if (and audio-path (lexdb-ui--non-empty-string-p audio-path))
                    (insert (propertize "    🔊 "
                                        'face 'lexdb-audio-indicator-face
                                        'lexdb-audio-path audio-path
                                        'lexdb-audio-dir audio-dir
                                        'help-echo "C-c C-c to play"))
                  (insert "    "))
                (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                (insert "\n")))))))
    ;; Regular examples (only if no subsenses)
    (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
      (unless subsenses
        (when (memq 'examples caps)
          (dolist (ex (lexdb-sense-examples sense))
            (let ((ex-text (lexdb-example-text ex))
                  (audio-path (lexdb-example-audio ex)))
              (when (lexdb-ui--non-empty-string-p ex-text)
                ;; Audio indicator at start if audio available
                (if (and (memq 'audio-example caps) audio-path (lexdb-ui--non-empty-string-p audio-path))
                    (insert (propertize "    🔊 "
                                        'face 'lexdb-audio-indicator-face
                                        'lexdb-audio-path audio-path
                                        'lexdb-audio-dir audio-dir
                                        'help-echo "C-c C-c to play"))
                  (insert "    "))
                (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                ;; Chinese translation (if capability present)
                (when (memq 'chinese-example caps)
                  (when-let ((ex-zh (lexdb-meta-get (lexdb-example-metadata ex) ns "text-zh")))
                    (when (lexdb-ui--non-empty-string-p ex-zh)
                      (insert " " (propertize ex-zh 'face 'lexdb-chinese-face)))))
                (insert "\n")))))))
    ;; Sense-level cross references
    (let ((sense-relations (lexdb-sense-relations sense)))
      (when sense-relations
        (let ((cross-refs (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'cross_ref)) sense-relations)))
          (when cross-refs
            (insert "  " (propertize "→ " 'face 'lexdb-crossref-face))
            (lexdb-ui--insert-linked-relations cross-refs 'lexdb-crossref-face)
            (insert "\n")))))))

(defun lexdb-ui--render-synonyms-and-crossrefs (entry adapter)
  "Render synonyms and cross-refs for ENTRY (inline, not in tabs)."
  (let ((caps (lexdb-adapter-capabilities adapter))
        (relations (lexdb-entry-relations entry)))
    (let ((synonyms (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'synonym)) relations))
          (cross-refs (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'cross_ref)) relations)))
      ;; Synonyms
      (when (and (memq 'synonyms caps) synonyms)
        (insert (propertize "SYN " 'face 'lexdb-label-face))
        (lexdb-ui--insert-linked-relations synonyms 'lexdb-synonym-face)
        (insert "\n"))
      ;; Cross references
      (when (and (memq 'cross-refs caps) cross-refs)
        (insert (propertize "→ " 'face 'lexdb-crossref-face))
        (lexdb-ui--insert-linked-relations cross-refs 'lexdb-crossref-face)
        (insert "\n\n")))))

(defun lexdb-ui--insert-linked-relations (relations face)
  "Insert RELATIONS with clickable links using FACE."
  (let ((first t))
    (dolist (rel relations)
      (unless first (insert ", "))
      (setq first nil)
      (let* ((target (lexdb-relation-target rel))
             (raw-link (lexdb-relation-target-link rel))
             ;; Extract word before # (e.g., "plan#hash..." -> "plan")
             (word (when raw-link
                     (if (string-match "\\`\\([^#]+\\)" raw-link)
                         (match-string 1 raw-link)
                       raw-link)))
             ;; Extract sense number from _s followed by digits (e.g., "_s5" -> "5")
             (sense-num (when raw-link
                          (if (string-match "_s\\([0-9]+\\)" raw-link)
                              (match-string 1 raw-link)
                            nil))))
        (if word
            ;; Clickable link
            (insert-text-button (if sense-num
                                    (format "%s(%s)" target sense-num)
                                  target)
                                'face face
                                'action (lambda (_)
                                          (lexdb-search-and-goto-sense word sense-num))
                                'help-echo (format "Look up: %s%s" word
                                                   (if sense-num (format " sense %s" sense-num) "")))
          ;; Plain text
          (insert (propertize target 'face face)))))))

(defun lexdb-search-and-goto-sense (word &optional sense-num)
  "Search for WORD and optionally scroll to SENSE-NUM."
  (setq lexdb-ui--pending-sense-num sense-num)
  (lexdb-search word))

(defvar lexdb-ui--pending-sense-num nil
  "Pending sense number to jump to after search.")

(defun lexdb-ui--goto-pending-sense ()
  "Jump to pending sense number if set. Call this after rendering."
  (when lexdb-ui--pending-sense-num
    (let ((sense-num lexdb-ui--pending-sense-num))
      (setq lexdb-ui--pending-sense-num nil)
      (goto-char (point-min))
      ;; Try multiple patterns to find the sense
      (let ((found nil))
        ;; Pattern 1: "N " at beginning of line (义项编号)
        (unless found
          (when (re-search-forward
                 (concat "^" (regexp-quote sense-num) " ")
                 nil t)
            (setq found t)))
        ;; Pattern 2: "N " with leading spaces
        (unless found
          (goto-char (point-min))
          (when (re-search-forward
                 (concat "^[[:space:]]*" (regexp-quote sense-num) " ")
                 nil t)
            (setq found t)))
        (when found
          (beginning-of-line)
          (set-window-point (selected-window) (point))
          (recenter))))))

(defun lexdb-ui--build-verb-table-content (verb-table)
  "Build content string for VERB TABLE tab.
VERB-TABLE is a list or vector of verb form entries."
  (with-temp-buffer
    (let ((forms (if (vectorp verb-table) (append verb-table nil) verb-table))
          (current-tense ""))
      (dolist (form forms)
        (let ((tense (cdr (assoc 'tense form)))
              (subject (cdr (assoc 'subject form)))
              (verb-form (cdr (assoc 'form form))))
          ;; Show tense header when it changes
          (when (and tense (not (string= tense current-tense)))
            (setq current-tense tense)
            (when (> (point) 1) (insert "\n"))
            (insert "  " (propertize tense 'face 'lexdb-label-face) "\n"))
          ;; Show subject and form
          (when verb-form
            (insert "    ")
            (when subject
              (insert (propertize subject 'face 'lexdb-grammar-label-face) " "))
            (insert (propertize verb-form 'face 'lexdb-headword-face) "\n")))))
    (buffer-string)))

(defun lexdb-ui--build-corpus-examples-content (examples)
  "Build content string for EXAMPLES tab.
EXAMPLES is a list or vector of sections with header and examples."
  (with-temp-buffer
    (let ((sections (if (vectorp examples) (append examples nil) examples)))
      (dolist (section sections)
        ;; Check if it's new format (with header) or old format (just strings)
        (if (and (listp section) (assoc 'header section))
            ;; New format with header
            (let ((header (cdr (assoc 'header section)))
                  (exs (cdr (assoc 'examples section))))
              (when header
                (insert "  " (propertize header 'face 'lexdb-label-face) "\n"))
              (let ((ex-list (if (vectorp exs) (append exs nil) exs)))
                (dolist (ex ex-list)
                  (when (and ex (not (string-empty-p ex)))
                    (insert "    • ")
                    (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                    (insert "\n"))))
              (insert "\n"))
          ;; Old format (just string) - backward compatibility
          (when (and section (stringp section) (not (string-empty-p section)))
            (insert "  • ")
            (lexdb-ui--insert-highlighted-text section 'lexdb-example-face)
            (insert "\n")))))
    (buffer-string)))

(defun lexdb-ui--build-thesaurus-content (thesaurus)
  "Build content string for THESAURUS tab.
THESAURUS is a list of sections with header, section title, and exponent items."
  (with-temp-buffer
    (let ((sections (if (vectorp thesaurus) (append thesaurus nil) thesaurus))
          (last-header ""))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (sec-title (cdr (assoc 'section section)))
              (items (cdr (assoc 'items section))))
          ;; Show header if changed (e.g., "Longman Language Activator", "WORD SETS")
          (when (and header (not (string= header last-header)))
            (setq last-header header)
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n"))
          ;; Section title (e.g., "what you say to explain the most basic facts", "Computers")
          (when (and sec-title (not (string-empty-p sec-title)))
            (insert "  " (propertize (upcase sec-title) 'face 'lexdb-signpost-face) "\n\n"))
          ;; Items - check if they have definitions (thesaurus) or just word/pos (word sets)
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (when (and (listp item) (assoc 'word item))
                (let ((word (cdr (assoc 'word item)))
                      (def (cdr (assoc 'definition item)))
                      (pos (cdr (assoc 'pos item)))
                      (labels-raw (cdr (assoc 'labels item)))
                      (examples-raw (cdr (assoc 'examples item))))
                  (let ((labels (if (vectorp labels-raw) (append labels-raw nil) labels-raw))
                        (examples (if (vectorp examples-raw) (append examples-raw nil) examples-raw)))
                    (cond
                     ;; Has definition/examples - thesaurus style with ▼
                     ((or def examples)
                      (when word
                        (insert "    ▼ " (propertize word 'face 'lexdb-headword-face))
                        (when (and pos (not (string-empty-p pos)))
                          (insert " " (propertize pos 'face 'lexdb-pos-face)))
                        (insert "\n"))
                      (when (or labels def)
                        (insert "      ")
                        (when labels
                          (dolist (label labels)
                            (insert (propertize label 'face 'lexdb-register-face) " ")))
                        (when def
                          (insert (propertize def 'face 'lexdb-definition-face)))
                        (insert "\n"))
                      (when examples
                        (dolist (ex examples)
                          (when (and ex (not (string-empty-p ex)))
                            (insert "      · ")
                            (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                            (insert "\n"))))
                      (insert "\n"))
                     ;; Just word/pos - word sets style (no ▶, compact list)
                     (word
                      (insert "      " (propertize word 'face 'lexdb-crossref-face))
                      (when (and pos (not (string-empty-p pos)))
                        (insert " " (propertize pos 'face 'lexdb-pos-face)))
                      (insert "\n")))))))))))
    (buffer-string)))

(defun lexdb-ui--build-word-family-content (word-family)
  "Build content string for WORD FAMILY tab.
WORD-FAMILY is a list of sections with header and groups (by POS)."
  (with-temp-buffer
    (let ((sections (if (vectorp word-family) (append word-family nil) word-family)))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (groups (cdr (assoc 'groups section)))
              (items (cdr (assoc 'items section))))  ; backward compat
          ;; Header (usually "WORD FAMILY")
          (when (and header (not (string-empty-p header)))
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n\n"))

          (cond
           ;; New format with groups by POS
           (groups
            (let ((group-list (if (vectorp groups) (append groups nil) groups)))
              (dolist (group group-list)
                (let ((pos (cdr (assoc 'pos group)))
                      (words (cdr (assoc 'words group))))
                  ;; POS header
                  (when (and pos (not (string-empty-p pos)))
                    (insert "  " (propertize pos 'face 'lexdb-pos-face) "\n"))
                  ;; Words in this POS group
                  (let ((word-list (if (vectorp words) (append words nil) words)))
                    (dolist (word word-list)
                      (when (and word (not (string-empty-p word)))
                        (insert "    ")
                        (insert-text-button word
                                            'face 'lexdb-crossref-face
                                            'action (lambda (_) (lexdb-search word))
                                            'help-echo (format "Look up: %s" word))
                        (insert "\n"))))
                  (insert "\n")))))
           ;; Old format with items (word/pos pairs) - backward compatibility
           (items
            (let ((item-list (if (vectorp items) (append items nil) items)))
              (dolist (item item-list)
                (let ((word (cdr (assoc 'word item)))
                      (pos (cdr (assoc 'pos item))))
                  (when word
                    (insert "    ")
                    (insert-text-button word
                                        'face 'lexdb-crossref-face
                                        'action (lambda (_) (lexdb-search word))
                                        'help-echo (format "Look up: %s" word))
                    (when (and pos (not (string-empty-p pos)))
                      (insert " " (propertize pos 'face 'lexdb-pos-face)))
                    (insert "\n"))))))))))
    (buffer-string)))

(defun lexdb-ui--build-phrases-content (phrases)
  "Build content string for PHRASES tab."
  (with-temp-buffer
    (dolist (phrase phrases)
      (insert "  • " (propertize (lexdb-relation-target phrase)
                                  'face 'lexdb-phrase-face) "\n"))
    (buffer-string)))

(defun lexdb-ui--build-entry-menu-content (entry-menu)
  "Build content string for ENTRY MENU tab.
ENTRY-MENU is a list of sections with header and menu items."
  (with-temp-buffer
    (let ((sections (if (vectorp entry-menu) (append entry-menu nil) entry-menu)))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          (when (and header (not (string-empty-p header)))
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n"))
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (let ((num (cdr (assoc 'number item)))
                    (label (cdr (assoc 'label item))))
                (insert "    ")
                (when num
                  (insert (propertize num 'face 'lexdb-sense-num-face) " "))
                (when label
                  (insert (propertize label 'face 'lexdb-signpost-face)))
                (insert "\n")))))))
    (buffer-string)))

(defun lexdb-ui--build-word-sets-content (word-sets)
  "Build content string for WORD SETS tab.
WORD-SETS is a list of sections with header and items."
  (with-temp-buffer
    (let ((sections (if (vectorp word-sets) (append word-sets nil) word-sets)))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          (when (and header (not (string-empty-p header)))
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n"))
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (when (and item (not (string-empty-p item)))
                (insert "    • " (propertize item 'face 'lexdb-crossref-face) "\n")))))))
    (buffer-string)))

(defun lexdb-ui--build-popup-collocations-content (popup-colls)
  "Build content string for popup collocations.
POPUP-COLLS is a list of sections with header and collocation items."
  (with-temp-buffer
    (let ((sections (if (vectorp popup-colls) (append popup-colls nil) popup-colls)))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          (when (and header (not (string-empty-p header)))
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n\n"))
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (let ((text (cdr (assoc 'text item)))
                    (examples (cdr (assoc 'examples item))))
                (when text
                  (insert "    " (propertize text 'face 'lexdb-collocation-word-face) "\n")
                  (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
                    (dolist (ex ex-list)
                      (when (and ex (not (string-empty-p ex)))
                        (insert "      " (propertize ex 'face 'lexdb-example-face) "\n")))))))))))
    (buffer-string)))

(defun lexdb-ui--build-popup-phrases-content (popup-phrases)
  "Build content string for popup phrases.
POPUP-PHRASES is a list of sections with header and phrase items."
  (with-temp-buffer
    (let ((sections (if (vectorp popup-phrases) (append popup-phrases nil) popup-phrases)))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          (when (and header (not (string-empty-p header)))
            (insert "  " (propertize header 'face 'lexdb-label-face) "\n\n"))
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (let ((text (cdr (assoc 'text item)))
                    (examples (cdr (assoc 'examples item))))
                (when text
                  (insert "    • " (propertize text 'face 'lexdb-phrase-face) "\n")
                  (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
                    (dolist (ex ex-list)
                      (when (and ex (not (string-empty-p ex)))
                        (insert "        · ")
                        (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                        (insert "\n")))))))))))
    (buffer-string)))

(defun lexdb-ui--build-phrasal-verbs-content (phrasal-verbs)
  "Build content string for PHRASAL VERBS tab.
PHRASAL-VERBS is a list or vector of alists with headword, pos, and senses."
  (with-temp-buffer
    (lexdb-ui--render-phrasal-verbs phrasal-verbs)
    (buffer-string)))

(defun lexdb-ui--render-phrasal-verbs (phrasal-verbs)
  "Render PHRASAL-VERBS directly into current buffer.
PHRASAL-VERBS is a list or vector of alists with headword, pos, and senses."
  ;; Convert vector to list if needed
  (let ((pv-list (if (vectorp phrasal-verbs)
                     (append phrasal-verbs nil)
                   phrasal-verbs)))
    (dolist (pv pv-list)
      (let ((headword (cdr (assoc 'headword pv)))
            (pos (cdr (assoc 'pos pv)))
            (senses-raw (cdr (assoc 'senses pv))))
        ;; Convert senses vector to list if needed
        (let ((senses (if (vectorp senses-raw)
                          (append senses-raw nil)
                        senses-raw)))
          ;; Phrasal verb header with background (like original dictionary)
          (insert (propertize (concat headword " ")
                              'face 'lexdb-phrasal-verb-headword-face))
          (when pos
            (insert (propertize pos 'face 'lexdb-phrasal-verb-pos-face)))
          (insert "\n")
          ;; Senses
          (dolist (sense senses)
            (let ((number (cdr (assoc 'number sense)))
                  (lexunit (cdr (assoc 'lexunit sense)))
                  (definition (cdr (assoc 'definition sense)))
                  (labels-raw (cdr (assoc 'labels sense)))
                  (examples-raw (cdr (assoc 'examples sense))))
              ;; Convert vectors to lists
              (let ((labels (if (vectorp labels-raw) (append labels-raw nil) labels-raw))
                    (examples (if (vectorp examples-raw) (append examples-raw nil) examples-raw)))
                ;; Sense number and lexunit
                (insert "  ")
                (when (and number (not (string-empty-p number)))
                  (insert (propertize number 'face 'lexdb-sense-num-face) " "))
                (when (and lexunit (not (string-empty-p lexunit)))
                  (insert (propertize lexunit 'face 'lexdb-phrasal-verb-lexunit-face) " "))
                ;; Labels (geo, register, syn)
                (dolist (label labels)
                  (let ((ltype (cdr (assoc 'type label)))
                        (lvalue (cdr (assoc 'value label))))
                    (when lvalue
                      (cond
                       ((string= ltype "geo")
                        (insert (propertize lvalue 'face 'lexdb-geo-face) " "))
                       ((string= ltype "register")
                        (insert (propertize lvalue 'face 'lexdb-register-face) " "))
                       ((string= ltype "syn")
                        (insert (propertize "SYN " 'face 'lexdb-label-face)
                                (propertize lvalue 'face 'lexdb-synonym-face) " "))))))
                ;; Definition
                (when definition
                  (insert (propertize definition 'face 'lexdb-definition-face)))
                (insert "\n")
                ;; Examples
                (dolist (ex examples)
                  (when (and ex (not (string-empty-p ex)))
                    (insert "    " (propertize ex 'face 'lexdb-example-face) "\n"))))))
          (insert "\n"))))))

(defun lexdb-ui--build-collocations-content (collocations)
  "Build content string for COLLOCATIONS tab."
  (with-temp-buffer
    (let ((current-category nil))
      (dolist (coll collocations)
        (let ((category (lexdb-collocation-category coll))
              (text (lexdb-collocation-text coll))
              (gloss (lexdb-collocation-gloss coll))
              (examples (lexdb-collocation-examples coll)))
          ;; Category header - more prominent
          (when (and (lexdb-ui--non-empty-string-p category)
                     (not (equal category current-category)))
            (setq current-category category)
            (when (> (point) 1) (insert "\n"))  ; blank line before new category
            (insert (propertize (concat "  ▸ " (upcase category))
                                'face 'lexdb-collocation-category-face))
            (insert "\n"))
          ;; Collocation word
          (when (lexdb-ui--non-empty-string-p text)
            (insert "    " (propertize text 'face 'lexdb-collocation-word-face))
            ;; Gloss
            (when (lexdb-ui--non-empty-string-p gloss)
              (insert " " (propertize gloss 'face 'lexdb-collocation-gloss-face)))
            (insert "\n")
            ;; Examples
            (dolist (ex examples)
              (let ((ex-text (if (stringp ex) (string-trim ex) "")))
                (when (string-prefix-p "·" ex-text)
                  (setq ex-text (string-trim (substring ex-text 1))))
                (when (not (string-empty-p ex-text))
                  (insert (propertize (concat "      " ex-text "\n")
                                      'face 'lexdb-collocation-example-face)))))))))
    (buffer-string)))

;;;; ============================================================
;;;; Main Entry Renderer
;;;; ============================================================

(defun lexdb-ui-render-entry (entry adapter)
  "Render ENTRY using ADAPTER's capabilities.
Adapter can provide optional hooks for custom rendering."
  (let ((caps (lexdb-adapter-capabilities adapter))
        (entry-id (lexdb-entry-id entry)))
    ;; Allow adapter to fully customize header
    (if-let ((header-hook (lexdb-adapter-render-entry-header-fn adapter)))
        (funcall header-hook entry (current-buffer))
      ;; Default header rendering
      ;; Headword
      (lexdb-ui--render-headword entry)
      ;; Pronunciation
      (when (memq 'pronunciation caps)
        (lexdb-ui--render-pronunciations entry adapter))
      ;; Frequency
      (lexdb-ui--render-frequency entry adapter)
      ;; Part of speech
      (lexdb-ui--render-pos entry adapter)
      ;; Inflections (past tense, plural, etc.)
      (lexdb-ui--render-inflections entry adapter)
      (insert "\n")
      ;; Audio buttons
      (lexdb-ui--render-audio-buttons entry adapter)
      (insert "\n"))

    ;; Build tabs (placed after header, before senses)
    (let ((tabs nil)
          (tab-group (format "lexdb-tabs-%d-%d" entry-id (random 10000)))
          (ns (symbol-name (lexdb-adapter-id adapter))))
      ;; ENTRY MENU tab (sense navigation)
      (let ((entry-menu (lexdb-meta-get (lexdb-entry-metadata entry) ns "entry_menu")))
        (when (and entry-menu (> (length entry-menu) 0))
          (push (list 'entry-menu
                      "ENTRY MENU"
                      (lexdb-ui--build-entry-menu-content entry-menu))
                tabs)))
      ;; WORD ORIGIN tab
      (when (lexdb-adapter-has-capability-p adapter 'origin)
        (let ((origin (lexdb-meta-get (lexdb-entry-metadata entry) ns "origin_full")))
          (when (lexdb-ui--non-empty-string-p origin)
            (push (list 'origin
                        "WORD ORIGIN"
                        (concat "  " (propertize origin 'face 'lexdb-origin-face) "\n"))
                  tabs))))
      ;; VERB TABLE tab
      (let ((verb-table (lexdb-meta-get (lexdb-entry-metadata entry) ns "verb_table")))
        (when (and verb-table (> (length verb-table) 0))
          (push (list 'verb-table
                      "VERB TABLE"
                      (lexdb-ui--build-verb-table-content verb-table))
                tabs)))
      ;; EXAMPLES tab (corpus examples)
      (let ((corpus-examples (lexdb-meta-get (lexdb-entry-metadata entry) ns "corpus_examples")))
        (when (and corpus-examples (> (length corpus-examples) 0))
          (push (list 'examples
                      "EXAMPLES"
                      (lexdb-ui--build-corpus-examples-content corpus-examples))
                tabs)))
      ;; THESAURUS tab
      (let ((thesaurus (lexdb-meta-get (lexdb-entry-metadata entry) ns "thesaurus")))
        (when (and thesaurus (> (length thesaurus) 0))
          (push (list 'thesaurus
                      "THESAURUS"
                      (lexdb-ui--build-thesaurus-content thesaurus))
                tabs)))
      ;; COLLOCATIONS tab (from database + popup)
      (when (memq 'collocations caps)
        (let ((colls (or (lexdb-meta-get (lexdb-entry-metadata entry)
                                         (symbol-name (lexdb-adapter-id adapter))
                                         "collocations-cache")
                         (when (lexdb-adapter-collocations-fn adapter)
                           (funcall (lexdb-adapter-collocations-fn adapter) entry-id))))
              (popup-colls (lexdb-meta-get (lexdb-entry-metadata entry) ns "popup_collocations")))
          ;; Build combined content
          (let ((content ""))
            (when colls
              (setq content (lexdb-ui--build-collocations-content colls)))
            (when (and popup-colls (> (length popup-colls) 0))
              (setq content (concat content (lexdb-ui--build-popup-collocations-content popup-colls))))
            (when (not (string-empty-p content))
              (push (list 'collocations
                          "COLLOCATIONS"
                          content)
                    tabs)))))
      ;; PHRASES tab (from popup only)
      (let ((popup-phrases (lexdb-meta-get (lexdb-entry-metadata entry) ns "popup_phrases")))
        (when (and popup-phrases (> (length popup-phrases) 0))
          (push (list 'phrases
                      "PHRASES"
                      (lexdb-ui--build-popup-phrases-content popup-phrases))
                tabs)))
      ;; WORD FAMILY tab
      (let ((word-family (lexdb-meta-get (lexdb-entry-metadata entry) ns "word_family")))
        (when (and word-family (> (length word-family) 0))
          (push (list 'word-family
                      "WORD FAMILY"
                      (lexdb-ui--build-word-family-content word-family))
                tabs)))
      ;; Insert tab bar if we have any tabs
      (when tabs
        (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group)))

    ;; Senses/definitions
    (dolist (sense (lexdb-entry-senses entry))
      (lexdb-ui--render-sense sense adapter))
    (insert "\n")

    ;; Phrasal verbs (displayed inline after senses)
    (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
           (phrasal-verbs (lexdb-meta-get (lexdb-entry-metadata entry) ns "phrasal-verbs")))
      (when (and phrasal-verbs (> (length phrasal-verbs) 0))
        (lexdb-ui--render-phrasal-verbs phrasal-verbs)))

    ;; Synonyms and cross-refs (inline, after senses)
    (lexdb-ui--render-synonyms-and-crossrefs entry adapter)

    ;; Separator
    (insert (propertize (make-string 60 ?─) 'face 'lexdb-separator-face))
    (insert "\n\n")))

(defun lexdb-ui-render-entries (entries adapter)
  "Render list of ENTRIES using ADAPTER."
  ;; Prefetch data if adapter supports it
  (when (lexdb-adapter-prefetch-fn adapter)
    (funcall (lexdb-adapter-prefetch-fn adapter)
             (mapcar #'lexdb-entry-id entries)))
  ;; Render each entry
  (dolist (entry entries)
    (lexdb-ui-render-entry entry adapter)))

;;;; ============================================================
;;;; Buffer Management
;;;; ============================================================

(defvar lexdb-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Basic
    (define-key map "q" #'quit-window)
    (define-key map "s" #'lexdb-search)
    (define-key map (kbd "RET") #'push-button)
    ;; Navigation - senses
    (define-key map "n" #'lexdb-next-sense)
    (define-key map "p" #'lexdb-prev-sense)
    ;; Navigation - entries (homographs)
    (define-key map "N" #'lexdb-next-entry)
    (define-key map "P" #'lexdb-prev-entry)
    ;; Navigation - buttons
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    ;; Direct jump to sense 1-9
    (define-key map "1" (lambda () (interactive) (lexdb-goto-sense "1")))
    (define-key map "2" (lambda () (interactive) (lexdb-goto-sense "2")))
    (define-key map "3" (lambda () (interactive) (lexdb-goto-sense "3")))
    (define-key map "4" (lambda () (interactive) (lexdb-goto-sense "4")))
    (define-key map "5" (lambda () (interactive) (lexdb-goto-sense "5")))
    (define-key map "6" (lambda () (interactive) (lexdb-goto-sense "6")))
    (define-key map "7" (lambda () (interactive) (lexdb-goto-sense "7")))
    (define-key map "8" (lambda () (interactive) (lexdb-goto-sense "8")))
    (define-key map "9" (lambda () (interactive) (lexdb-goto-sense "9")))
    ;; Jump via prompt
    (define-key map "g" #'lexdb-goto-sense-prompt)
    ;; Fold
    (define-key map "+" #'lexdb-ui-expand-all)
    (define-key map "-" #'lexdb-ui-collapse-all)
    ;; Audio
    (define-key map (kbd "C-c C-c") #'lexdb-ui-play-audio-at-point)
    map)
  "Keymap for `lexdb-mode'.")

;;;; ============================================================
;;;; Navigation Functions
;;;; ============================================================

(defun lexdb-next-sense ()
  "Jump to next sense number."
  (interactive)
  (let ((found nil))
    (save-excursion
      (forward-line 1)
      (when (re-search-forward "^[0-9]+ " nil t)
        (setq found (match-beginning 0))))
    (if found
        (progn (goto-char found) (recenter))
      (message "No more senses"))))

(defun lexdb-prev-sense ()
  "Jump to previous sense number."
  (interactive)
  (let ((found nil)
        (orig (point)))
    (save-excursion
      (beginning-of-line)
      (when (re-search-backward "^[0-9]+ " nil t)
        (setq found (match-beginning 0))))
    (if (and found (< found orig))
        (progn (goto-char found) (recenter))
      (message "No previous senses"))))

(defun lexdb-next-entry ()
  "Jump to next dictionary entry (homograph)."
  (interactive)
  (let ((found nil))
    (save-excursion
      (forward-line 1)
      ;; Look for separator line or headword pattern
      (when (re-search-forward "^─\\{20,\\}$" nil t)
        (forward-line 1)
        (when (not (eobp))
          (setq found (point)))))
    (if found
        (progn (goto-char found) (recenter))
      (message "No more entries"))))

(defun lexdb-prev-entry ()
  "Jump to previous dictionary entry (homograph)."
  (interactive)
  (let ((found nil))
    (save-excursion
      (beginning-of-line)
      ;; Find previous separator
      (when (re-search-backward "^─\\{20,\\}$" nil t)
        ;; Find the separator before that
        (when (re-search-backward "^─\\{20,\\}$" nil t)
          (forward-line 1)
          (setq found (point)))))
    (if found
        (progn (goto-char found) (recenter))
      ;; Try going to buffer beginning (first entry)
      (goto-char (point-min))
      (message "At first entry"))))

(defun lexdb-goto-sense (num)
  "Jump to sense number NUM."
  (let ((found nil))
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (format "^%s " (regexp-quote num)) nil t)
        (setq found (match-beginning 0))))
    (if found
        (progn (goto-char found) (recenter))
      (message "Sense %s not found" num))))

(defun lexdb-goto-sense-prompt ()
  "Prompt for sense number and jump to it."
  (interactive)
  (let ((num (read-string "Go to sense: ")))
    (lexdb-goto-sense num)))

;;;; ============================================================
;;;; Imenu Support
;;;; ============================================================

(defun lexdb-imenu-create-index ()
  "Create imenu index for lexdb buffer.
Index includes entries (headwords) and senses."
  (let ((index nil))
    (save-excursion
      (goto-char (point-min))
      ;; Find headwords - lines starting with a word followed by space and /
      ;; e.g., "mother¹ /ˈmʌðə..." (with superscript) or "mother1 /..." (without)
      (while (re-search-forward "^\\([a-zA-Z][-a-zA-Z']*[⁰¹²³⁴⁵⁶⁷⁸⁹0-9]*\\) +/" nil t)
        (let ((headword (match-string 1))
              (pos (match-beginning 0)))
          ;; Try to get POS from same line
          (let ((line-end (line-end-position))
                (entry-pos nil))
            (save-excursion
              (goto-char pos)
              (if (re-search-forward "\\b\\(noun\\|verb\\|adjective\\|adverb\\|preposition\\|conjunction\\|pronoun\\|determiner\\|interjection\\)\\b" line-end t)
                  (setq entry-pos (match-string 1))))
            (push (cons (if entry-pos
                            (format "%s (%s)" headword entry-pos)
                          headword)
                        pos)
                  index))))
      ;; Find senses - lines starting with number
      ;; e.g., "1 PARENT" or "2 "
      (goto-char (point-min))
      (while (re-search-forward "^\\([0-9]+\\) +\\([A-Z][A-Z /]*\\)?" nil t)
        (let ((num (match-string 1))
              (signpost (match-string 2))
              (pos (match-beginning 0)))
          (push (cons (format "  %s%s" num
                              (if (and signpost (not (string-empty-p signpost)))
                                  (concat " " (string-trim signpost))
                                ""))
                      pos)
                index))))
    (nreverse index)))

(defun lexdb-ui-play-audio-at-point ()
  "Play audio at point if available.
Only searches within the current line to avoid playing wrong audio."
  (interactive)
  (let ((audio-path (get-text-property (point) 'lexdb-audio-path))
        (audio-dir (get-text-property (point) 'lexdb-audio-dir)))
    (if (and audio-path audio-dir)
        (lexdb-ui--play-audio audio-path audio-dir)
      ;; Try to find audio on current line only
      (let ((found nil)
            (line-start (line-beginning-position))
            (line-end (line-end-position)))
        ;; Search backward to line start
        (save-excursion
          (while (and (not found) (>= (point) line-start))
            (when-let ((path (get-text-property (point) 'lexdb-audio-path))
                       (dir (get-text-property (point) 'lexdb-audio-dir)))
              (setq found (cons path dir)))
            (unless found (backward-char))))
        ;; Search forward to line end if not found
        (unless found
          (save-excursion
            (while (and (not found) (<= (point) line-end))
              (when-let ((path (get-text-property (point) 'lexdb-audio-path))
                         (dir (get-text-property (point) 'lexdb-audio-dir)))
                (setq found (cons path dir)))
              (unless found (forward-char)))))
        (if found
            (lexdb-ui--play-audio (car found) (cdr found))
          (message "No audio on this line"))))))

(defface lexdb-fold-indicator-face
  '((((background dark))  :foreground "#888888")
    (((background light)) :foreground "#666666"))
  "Face for fold indicators (▶/▼)."
  :group 'lexdb)

(defun lexdb-ui-toggle-fold-at-point ()
  "Toggle fold at point."
  (interactive)
  (let ((ov (lexdb-ui--find-fold-overlay-at-point)))
    (if ov
        (lexdb-ui--toggle-fold ov)
      ;; If not on a fold, try forward-button as fallback
      (forward-button 1))))

(defun lexdb-ui--find-fold-overlay-at-point ()
  "Find fold overlay at current point."
  (let ((ovs (overlays-at (point))))
    (seq-find (lambda (ov) (overlay-get ov 'lexdb-fold-id)) ovs)))

(defun lexdb-ui--toggle-fold (ov)
  "Toggle fold state of overlay OV."
  (let* ((fold-id (overlay-get ov 'lexdb-fold-id))
         (content-ov (lexdb-ui--find-fold-content fold-id))
         (indicator-ov (lexdb-ui--find-fold-indicator fold-id))
         (currently-hidden (and content-ov (overlay-get content-ov 'invisible))))
    (when content-ov
      (overlay-put content-ov 'invisible (not currently-hidden)))
    (when indicator-ov
      (overlay-put indicator-ov 'before-string
                   (propertize (if currently-hidden "▼ " "▶ ")
                               'face 'lexdb-fold-indicator-face)))))

(defun lexdb-ui--find-fold-content (fold-id)
  "Find fold content overlay with FOLD-ID."
  (seq-find (lambda (ov)
              (and (overlay-get ov 'lexdb-fold-content)
                   (equal (overlay-get ov 'lexdb-fold-id) fold-id)))
            (overlays-in (point-min) (point-max))))

(defun lexdb-ui--find-fold-indicator (fold-id)
  "Find fold indicator overlay with FOLD-ID."
  (seq-find (lambda (ov)
              (and (overlay-get ov 'lexdb-fold-indicator)
                   (equal (overlay-get ov 'lexdb-fold-id) fold-id)))
            (overlays-in (point-min) (point-max))))

(defun lexdb-ui-expand-all ()
  "Expand all folds in buffer."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'lexdb-fold-content)
      (overlay-put ov 'invisible nil))
    (when (overlay-get ov 'lexdb-fold-indicator)
      (overlay-put ov 'before-string
                   (propertize "▼ " 'face 'lexdb-fold-indicator-face)))))

(defun lexdb-ui-collapse-all ()
  "Collapse all folds in buffer."
  (interactive)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (overlay-get ov 'lexdb-fold-content)
      (overlay-put ov 'invisible t))
    (when (overlay-get ov 'lexdb-fold-indicator)
      (overlay-put ov 'before-string
                   (propertize "▶ " 'face 'lexdb-fold-indicator-face)))))

(define-derived-mode lexdb-mode special-mode "Lexdb"
  "Major mode for viewing dictionary entries.

Navigation:
  n/p     - Next/previous sense
  N/P     - Next/previous entry (homograph)
  1-9     - Jump to sense N
  g       - Go to sense (prompt)
  TAB     - Next button
  S-TAB   - Previous button
  RET     - Activate button
  s       - Search new word
  q       - Quit

\\{lexdb-mode-map}"
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; imenu support
  (setq-local imenu-create-index-function #'lexdb-imenu-create-index)
  (setq-local imenu-auto-rescan t))

;; Legacy aliases
(defalias 'ldoce-mode 'lexdb-mode)
(defalias 'dict-mode 'lexdb-mode)

(defun lexdb-ui--get-buffer (adapter-id)
  "Get or create buffer for ADAPTER-ID."
  (get-buffer-create (format "*Lexdb:%s*" adapter-id)))

(defun lexdb-ui-display (word entries adapter &optional no-lemma-hint)
  "Display ENTRIES for WORD using ADAPTER.
If NO-LEMMA-HINT is nil and no entries found, offer lemma suggestion."
  (let ((buf (lexdb-ui--get-buffer (lexdb-adapter-id adapter)))
        (pending-sense lexdb-ui--pending-sense-num))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lexdb-mode)
        (if entries
            (lexdb-ui-render-entries entries adapter)
          ;; No entries found
          (insert (propertize (format "No entries found for: %s" word)
                              'face 'lexdb-definition-face))
          ;; Lemma suggestion
          (unless no-lemma-hint
            (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
              (when-let ((lemma-fn (lexdb-adapter-lemma-fn adapter)))
                (let ((lemma (funcall lemma-fn word)))
                  (unless (equal lemma (downcase word))
                    (insert "\n\n")
                    (insert (propertize (format "Did you mean: %s?" lemma)
                                        'face 'lexdb-crossref-face))
                    (insert "\n")
                    (insert-text-button (format "[Look up '%s']" lemma)
                                        'face 'lexdb-button-face
                                        'action (lambda (_)
                                                  (lexdb-search lemma)))))))))
        (goto-char (point-min))))
    ;; Display and select the buffer
    (pop-to-buffer buf)
    ;; Now jump to sense if pending
    (when pending-sense
      (setq lexdb-ui--pending-sense-num nil)
      (goto-char (point-min))
      (let ((found nil))
        ;; Pattern: "N " at beginning of line or with leading spaces
        (when (re-search-forward
               (concat "^[[:space:]]*" (regexp-quote pending-sense) " ")
               nil t)
          (setq found t))
        (when found
          (beginning-of-line)
          (recenter))))))

(provide 'lexdb-ui)
;;; lexdb-ui.el ends here
