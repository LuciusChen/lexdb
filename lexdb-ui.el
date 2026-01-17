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

;; Note: Uses lexdb--non-empty-string-p from lexdb.el

;;;; ============================================================
;;;; Slot-based Rendering System (插槽渲染系统)
;;;; ============================================================

;; 插槽系统允许：
;; 1. 用户自定义渲染顺序
;; 2. 启用/禁用特定插槽
;; 3. 不同词典使用不同模板
;; 4. 未来支持多词典融合

(defvar lexdb-ui-slot-functions
  '((header          . lexdb-ui--slot-header)
    (tabs            . lexdb-ui--slot-tabs)
    (senses          . lexdb-ui--slot-senses)
    (entry-grammar-box   . lexdb-ui--slot-entry-grammar-box)
    (idioms          . lexdb-ui--slot-idioms)
    (phrasal-verbs   . lexdb-ui--slot-phrasal-verbs)
    (synonyms        . lexdb-ui--slot-synonyms)
    (separator       . lexdb-ui--slot-separator))
  "Alist mapping slot names to rendering functions.
Each function takes (entry adapter) and renders content at point.")

(defcustom lexdb-ui-default-template
  '(header tabs senses entry-grammar-box idioms phrasal-verbs synonyms separator)
  "Default slot order for rendering entries.
This is a list of slot names from `lexdb-ui-slot-functions'."
  :type '(repeat symbol)
  :group 'lexdb)

(defcustom lexdb-ui-adapter-templates nil
  "Alist of adapter-specific templates.
Each element is (ADAPTER-ID . SLOT-LIST).
If an adapter is not listed, `lexdb-ui-default-template' is used.

Example:
  ((oald . (header senses idioms separator))
   (ldoce . (header tabs senses phrasal-verbs synonyms separator)))"
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'lexdb)

(defcustom lexdb-ui-disabled-slots nil
  "List of slot names to globally disable.
These slots will be skipped regardless of template."
  :type '(repeat symbol)
  :group 'lexdb)

(defun lexdb-ui--get-template (adapter)
  "Get the rendering template for ADAPTER.
Returns adapter-specific template or default template."
  (let ((adapter-id (lexdb-adapter-id adapter)))
    (or (cdr (assq adapter-id lexdb-ui-adapter-templates))
        lexdb-ui-default-template)))

(defun lexdb-ui--slot-enabled-p (slot-name)
  "Check if SLOT-NAME is enabled (not in disabled list)."
  (not (memq slot-name lexdb-ui-disabled-slots)))

;;;; ============================================================
;;;; Multi-Dictionary Tab System
;;;; ============================================================

(defvar-local lexdb-ui--dict-results nil
  "Alist of (adapter-id . (entries . adapter)) for all queried dictionaries.")

(defvar-local lexdb-ui--active-dict nil
  "Currently active dictionary adapter-id.")

(defvar-local lexdb-ui--current-word nil
  "Current word being displayed.")

(defcustom lexdb-enabled-adapters nil
  "List of adapter IDs to query. If nil, query all registered adapters."
  :type '(repeat symbol)
  :group 'lexdb)

(defcustom lexdb-dict-tab-position 'header
  "Where to display dictionary tabs.
`header' uses header-line, `inline' puts tabs in buffer."
  :type '(choice (const :tag "Header line" header)
                 (const :tag "Inline in buffer" inline))
  :group 'lexdb)

(defun lexdb-ui--get-enabled-adapters ()
  "Return list of enabled adapter IDs."
  (or lexdb-enabled-adapters
      (mapcar #'car (lexdb-list-adapters))))

(defun lexdb-ui--query-all-dicts (word)
  "Query WORD in all enabled dictionaries.
Returns alist of (adapter-id . (entries . adapter))."
  (let ((results nil))
    (dolist (adapter-id (lexdb-ui--get-enabled-adapters))
      (when-let ((adapter (lexdb-get-adapter adapter-id)))
        (let ((entries (condition-case nil
                           (lexdb-lookup word adapter-id)
                         (error nil))))
          ;; Try lemmatization if no results
          (unless entries
            (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
              (when-let ((lemma (lexdb-find-lemma word adapter-id)))
                (unless (equal lemma (downcase word))
                  (setq entries (condition-case nil
                                    (lexdb-lookup lemma adapter-id)
                                  (error nil)))))))
          (push (cons adapter-id (cons entries adapter)) results))))
    (nreverse results)))

(defun lexdb-ui--render-dict-tabs ()
  "Render dictionary tab bar for header-line."
  (when lexdb-ui--dict-results
    (let ((tabs nil))
      (dolist (item lexdb-ui--dict-results)
        (let* ((adapter-id (car item))
               (entries (cadr item))
               (adapter (cddr item))
               (name (lexdb-adapter-name adapter))
               (is-active (eq adapter-id lexdb-ui--active-dict))
               (has-results (and entries (> (length entries) 0)))
               (face (cond (is-active 'lexdb-dict-tab-active-face)
                           (has-results 'lexdb-dict-tab-has-results-face)
                           (t 'lexdb-dict-tab-no-results-face)))
               (count-str (if has-results
                              (format "(%d)" (length entries))
                            ""))
               (tab-text (format " %s%s " name count-str)))
          (push (propertize tab-text
                            'face face
                            'lexdb-dict-id adapter-id
                            'mouse-face 'highlight
                            'help-echo (format "Switch to %s (click or press %s)"
                                               name
                                               (1+ (length tabs)))
                            'keymap (let ((map (make-sparse-keymap)))
                                      (define-key map [header-line mouse-1]
                                        `(lambda () (interactive)
                                           (lexdb-ui-switch-dict ',adapter-id)))
                                      map))
                tabs)))
      (mapconcat #'identity (nreverse tabs) " "))))

(defun lexdb-ui--render-inline-tabs ()
  "Render dictionary tabs inline in the buffer."
  (when lexdb-ui--dict-results
    (let ((idx 0))
      (dolist (item lexdb-ui--dict-results)
        (let* ((adapter-id (car item))
               (entries (cadr item))
               (adapter (cddr item))
               (name (lexdb-adapter-name adapter))
               (is-active (eq adapter-id lexdb-ui--active-dict))
               (has-results (and entries (> (length entries) 0)))
               (face (cond (is-active 'lexdb-dict-tab-active-face)
                           (has-results 'lexdb-dict-tab-has-results-face)
                           (t 'lexdb-dict-tab-no-results-face)))
               (count-str (if has-results
                              (format "(%d)" (length entries))
                            ""))
               (tab-text (format "%s%s" name count-str)))
          (setq idx (1+ idx))
          (when (> idx 1) (insert " "))
          (insert-text-button (format "[%d:%s]" idx tab-text)
                              'face face
                              'action `(lambda (_) (lexdb-ui-switch-dict ',adapter-id))
                              'help-echo (format "Switch to %s" name)))))
    (insert "\n")
    (insert (propertize (make-string 60 ?─) 'face 'lexdb-separator-face))
    (insert "\n\n")))

(defun lexdb-ui-switch-dict (adapter-id)
  "Switch to dictionary ADAPTER-ID."
  (interactive
   (list (intern
          (completing-read "Switch to dictionary: "
                           (mapcar (lambda (item)
                                     (symbol-name (car item)))
                                   lexdb-ui--dict-results)
                           nil t))))
  (when (and lexdb-ui--dict-results
             (assq adapter-id lexdb-ui--dict-results))
    (setq lexdb-ui--active-dict adapter-id)
    (lexdb-ui--refresh-display)))

(defun lexdb-ui-next-dict ()
  "Switch to next dictionary."
  (interactive)
  (when lexdb-ui--dict-results
    (let* ((ids (mapcar #'car lexdb-ui--dict-results))
           (pos (cl-position lexdb-ui--active-dict ids))
           (next-pos (if pos (mod (1+ pos) (length ids)) 0))
           (next-id (nth next-pos ids)))
      (lexdb-ui-switch-dict next-id))))

(defun lexdb-ui-prev-dict ()
  "Switch to previous dictionary."
  (interactive)
  (when lexdb-ui--dict-results
    (let* ((ids (mapcar #'car lexdb-ui--dict-results))
           (pos (cl-position lexdb-ui--active-dict ids))
           (prev-pos (if pos (mod (1- pos) (length ids)) 0))
           (prev-id (nth prev-pos ids)))
      (lexdb-ui-switch-dict prev-id))))

(defun lexdb-ui-switch-dict-by-number (n)
  "Switch to dictionary at position N (1-indexed)."
  (when lexdb-ui--dict-results
    (let ((ids (mapcar #'car lexdb-ui--dict-results)))
      (when (and (>= n 1) (<= n (length ids)))
        (lexdb-ui-switch-dict (nth (1- n) ids))))))

(defun lexdb-ui--refresh-display ()
  "Refresh the buffer with current dictionary's entries."
  (when (and lexdb-ui--dict-results lexdb-ui--active-dict)
    (let* ((item (assq lexdb-ui--active-dict lexdb-ui--dict-results))
           (entries (cadr item))
           (adapter (cddr item))
           (inhibit-read-only t)
           (pos (point)))
      (erase-buffer)
      ;; Update header line
      (when (eq lexdb-dict-tab-position 'header)
        (setq header-line-format '(:eval (lexdb-ui--render-dict-tabs))))
      ;; Render content
      (if entries
          (progn
            (when (eq lexdb-dict-tab-position 'inline)
              (lexdb-ui--render-inline-tabs))
            (lexdb-ui-render-entries entries adapter))
        ;; No entries
        (when (eq lexdb-dict-tab-position 'inline)
          (lexdb-ui--render-inline-tabs))
        (insert (propertize (format "No entries found for: %s" lexdb-ui--current-word)
                            'face 'lexdb-definition-face))
        ;; Lemma suggestion
        (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
          (when-let ((lemma-fn (lexdb-adapter-lemma-fn adapter)))
            (let ((lemma (funcall lemma-fn lexdb-ui--current-word))
                  (jump-adapter (lexdb-adapter-id adapter)))
              (unless (equal lemma (downcase lexdb-ui--current-word))
                (insert "\n\n")
                (insert (propertize (format "Did you mean: %s?" lemma)
                                    'face 'lexdb-crossref-face))
                (insert "\n")
                (insert-text-button (format "[Look up '%s']" lemma)
                                    'face 'lexdb-button-face
                                    'action (lambda (_)
                                              (lexdb-search-and-goto-sense lemma nil jump-adapter))))))))
      (goto-char (min pos (point-max))))))

;;;; ============================================================
;;;; Faces - Universal
;;;; ============================================================

;; Headword and pronunciation
(defface lexdb-headword-face
  '((((background dark))  :foreground "#04cecd" :weight bold :height 1.3)
    (((background light)) :foreground "#fe0000" :weight bold :height 1.3))
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
  '((((background dark))  :foreground "#6CB4EE" :slant italic)
    (((background light)) :foreground "#0066CC" :slant italic))
  "Face for register labels (formal, informal, especially British English, etc)."
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
  '((((background dark))  :foreground "#000000" :background "#E0A040" :weight bold)
    (((background light)) :foreground "#FFFFFF" :background "#996600" :weight bold))
  "Face for signpost/guide words (e.g., TELEPHONE, DESCRIBE).
Displayed with inverse colors like the original dictionary."
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
  "Face for highlighted words in examples (nodeword).
Different color to make highlights more visible."
  :group 'lexdb)

(defface lexdb-collocation-highlight-face
  '((((background dark))  :foreground "#E0A040" :weight bold :slant italic)
    (((background light)) :foreground "#996600" :weight bold :slant italic))
  "Face for highlighted collocations in examples (colloinexa).
Same color as example-highlight-face for consistency."
  :group 'lexdb)

(defface lexdb-chinese-face
  '((((background dark))  :foreground "#A0A0A0" :slant italic)
    (((background light)) :foreground "#666666" :slant italic))
  "Face for Chinese definitions and examples (comment style)."
  :group 'lexdb)

(defface lexdb-grammar-pattern-face
  '((((background dark))  :foreground "#B8B8B8" :weight bold)
    (((background light)) :foreground "#333333" :weight bold))
  "Face for grammar patterns (e.g., 'take somebody/something to/into etc something').
Same color as definition but bold."
  :group 'lexdb)

(defface lexdb-lexunit-face
  '((((background dark))  :foreground "#B8B8B8" :weight bold)
    (((background light)) :foreground "#333333" :weight bold))
  "Face for lexunit phrases (e.g., 'call a doctor/the police').
Same color as definition but bold."
  :group 'lexdb)

(defface lexdb-grambox-heading-face
  '((((background dark))  :foreground "#87CEEB" :weight bold)
    (((background light)) :foreground "#4682B4" :weight bold))
  "Face for GRAMMAR box heading."
  :group 'lexdb)

(defface lexdb-grambox-background-face
  '((((background dark))  :background "#2a2a2a" :extend t)
    (((background light)) :background "#f0f0e8" :extend t))
  "Face for GRAMMAR box background."
  :group 'lexdb)

(defface lexdb-grambox-expr-face
  '((((background dark))  :foreground "#E0A040" :weight bold :slant italic)
    (((background light)) :foreground "#996600" :weight bold :slant italic))
  "Face for highlighted expression in GRAMMAR/Register box.
Same color as example-highlight-face for consistency."
  :group 'lexdb)

(defface lexdb-bad-example-face
  '((((background dark))  :foreground "#CD5C5C" :strike-through t :slant italic)
    (((background light)) :foreground "#B22222" :strike-through t :slant italic))
  "Face for bad examples (what NOT to say) in GRAMMAR box."
  :group 'lexdb)

;; Relations
(defface lexdb-crossref-face
  '((((background dark))  :foreground "#6B8E23")
    (((background light)) :foreground "#6B8E23"))
  "Face for cross references."
  :group 'lexdb)

;; Dictionary Tab faces
(defface lexdb-dict-tab-face
  '((((background dark))  :foreground "#888888" :background "#2a2a2a" :box (:line-width 1 :color "#444444"))
    (((background light)) :foreground "#666666" :background "#e0e0e0" :box (:line-width 1 :color "#cccccc")))
  "Face for inactive dictionary tab."
  :group 'lexdb)

(defface lexdb-dict-tab-active-face
  '((((background dark))  :foreground "#98FB98" :background "#2a3a2a" :weight bold :box (:line-width 1 :color "#4a6a4a"))
    (((background light)) :foreground "#228B22" :background "#e0f0e0" :weight bold :box (:line-width 1 :color "#90b090")))
  "Face for active dictionary tab (green)."
  :group 'lexdb)

(defface lexdb-dict-tab-has-results-face
  '((((background dark))  :foreground "#888888" :background "#2a2a2a" :box (:line-width 1 :color "#444444"))
    (((background light)) :foreground "#666666" :background "#e0e0e0" :box (:line-width 1 :color "#cccccc")))
  "Face for inactive dictionary tab with results (gray)."
  :group 'lexdb)

(defface lexdb-dict-tab-no-results-face
  '((((background dark))  :foreground "#555555" :background "#2a2a2a" :box (:line-width 1 :color "#333333"))
    (((background light)) :foreground "#aaaaaa" :background "#e0e0e0" :box (:line-width 1 :color "#cccccc")))
  "Face for inactive dictionary tab without results (dimmer gray)."
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
  '((((background dark))  :foreground "#B8B8B8" :weight bold)
    (((background light)) :foreground "#333333" :weight bold))
  "Face for phrasal verb lexical unit (e.g., 'to take away').
Same color as definition but bold."
  :group 'lexdb)

(defface lexdb-synonym-face
  '((((background dark))  :foreground "#E0A040" :weight bold :slant italic)
    (((background light)) :foreground "#996600" :weight bold :slant italic))
  "Face for SYN/OPP labels.
Same color as example-highlight-face for consistency."
  :group 'lexdb)

;; Collocations
(defface lexdb-collocation-header-face
  '((((background dark))  :foreground "#B8B8B8" :weight bold :underline t)
    (((background light)) :foreground "#333333" :weight bold :underline t))
  "Face for COLLOCATIONS header."
  :group 'lexdb)

(defface lexdb-tab-section-header-face
  '((((background dark))  :foreground "#E0E0E0" :weight bold :background "#3a3a4a" :extend t)
    (((background light)) :foreground "#333333" :weight bold :background "#d8d8e8" :extend t))
  "Face for section headers inside tabs."
  :group 'lexdb)

(defface lexdb-collocation-category-face
  '((((background dark))  :foreground "#E0E0E0" :weight bold :background "#3a3a4a" :extend t)
    (((background light)) :foreground "#333333" :weight bold :background "#d8d8e8" :extend t))
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
  '((((background dark))  :foreground "#98FB98" :weight bold)
    (((background light)) :foreground "#228B22" :weight bold))
  "Face for active tab (green)."
  :group 'lexdb)

(defface lexdb-tab-inactive-face
  '((((background dark))  :foreground "#888888")
    (((background light)) :foreground "#999999"))
  "Face for inactive tab (gray text)."
  :group 'lexdb)

(defface lexdb-audio-indicator-face
  '((((background dark))  :foreground "#4A90D9")
    (((background light)) :foreground "#2060A0"))
  "Face for audio indicators (🔊)."
  :group 'lexdb)

(defface lexdb-translation-indicator-face
  '((((background dark))  :foreground "#56B6C2")
    (((background light)) :foreground "#0E7490"))
  "Face for translation indicators (🌐)."
  :group 'lexdb)

(defface lexdb-translation-peek-face
  '((((background dark))  :foreground "#888888" :slant italic)
    (((background light)) :foreground "#666666" :slant italic))
  "Face for peeked translation text."
  :group 'lexdb)

(defcustom lexdb-ui-translation-indicator "🌐"
  "Indicator for available translations.
Set to nil to disable translation indicators."
  :type '(choice string (const nil))
  :group 'lexdb)

(defvar-local lexdb-ui--translation-overlay nil
  "Overlay for displaying peeked translation.")

(defface lexdb-collocation-background-face
  '((((background dark))  :background "#1e1c1a" :extend t)
    (((background light)) :background "#f8f5f0" :extend t))
  "Face for collocations section background."
  :group 'lexdb)

(defface lexdb-tab-content-background-face
  '((((background dark))  :background "#2a2a2a" :extend t)
    (((background light)) :background "#f0f0e8" :extend t))
  "Face for tab content background when expanded."
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

(defcustom lexdb-audio-online-base-url "https://www.ldoceonline.com/media/english/"
  "Base URL for online audio files from LDOCE."
  :type 'string
  :group 'lexdb)

(defcustom lexdb-audio-prefer-online t
  "If non-nil, prefer online audio over local files.
When nil, play local files first, fall back to online if not found."
  :type 'boolean
  :group 'lexdb)

(defun lexdb-ui--audio-path-to-url (path)
  "Convert local audio PATH to online URL.
Handles different audio types:
- hwd/bre/* -> breProns (British pronunciation)
- hwd/ame/* -> ameProns (American pronunciation)
- exa/bre/* or exa/ame/* -> exaProns (example sentences)"
  (when path
    (let ((filename (file-name-nondirectory path)))
      (cond
       ((string-match-p "^hwd/bre/" path)
        (concat lexdb-audio-online-base-url "breProns/" filename))
       ((string-match-p "^hwd/ame/" path)
        (concat lexdb-audio-online-base-url "ameProns/" filename))
       ((string-match-p "^exa/" path)
        (concat lexdb-audio-online-base-url "exaProns/" filename))
       (t nil)))))

(defun lexdb-ui--play-audio (path &optional audio-dir)
  "Play audio file at PATH, optionally relative to AUDIO-DIR.
If local file doesn't exist and PATH can be converted to URL, play online."
  (when path
    (let* ((full-path (if audio-dir
                          (expand-file-name path audio-dir)
                        path))
           (local-exists (file-exists-p full-path))
           (online-url (lexdb-ui--audio-path-to-url path)))
      (cond
       ;; Prefer online if configured
       ((and lexdb-audio-prefer-online online-url)
        (lexdb-ui--play-url online-url))
       ;; Play local if exists
       (local-exists
        (start-process "lexdb-audio" nil lexdb-audio-player full-path))
       ;; Fall back to online
       (online-url
        (lexdb-ui--play-url online-url))
       ;; No option available
       (t
        (message "Audio not available: %s" path))))))

(defun lexdb-ui--play-url (url)
  "Play audio from URL using mpv or similar player."
  (message "Playing: %s" url)
  (start-process "lexdb-audio" nil lexdb-audio-player url))

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
                 (overlay-get ov 'lexdb-tab-content)
                 (not (overlay-get ov 'invisible)))
        (setq is-visible t)))
    ;; Hide all content overlays in this group
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (equal (overlay-get ov 'lexdb-tab-group) tab-group)
                 (overlay-get ov 'lexdb-tab-content))
        (overlay-put ov 'invisible t)
        (overlay-put ov 'face nil)))
    ;; If not previously visible, show selected tab content with background
    (unless is-visible
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (equal (overlay-get ov 'lexdb-tab-group) tab-group)
                   (equal (overlay-get ov 'lexdb-tab-id) tab-id)
                   (overlay-get ov 'lexdb-tab-content))
          (overlay-put ov 'invisible nil)
          (let ((bg-color (face-background 'lexdb-tab-content-background-face nil t)))
            (when bg-color
              (overlay-put ov 'face `(:background ,bg-color :extend t)))))))
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
          (overlay-put content-ov 'lexdb-tab-content t)  ; Mark as tab content
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
  "Convert leading/trailing numbers in STR to superscript Unicode characters.
E.g., 'mother1' -> 'mother¹', 'swing2' -> 'swing²', '1(5)' -> '¹(5)'."
  (let ((superscripts '((?0 . ?⁰) (?1 . ?¹) (?2 . ?²) (?3 . ?³) (?4 . ?⁴)
                        (?5 . ?⁵) (?6 . ?⁶) (?7 . ?⁷) (?8 . ?⁸) (?9 . ?⁹))))
    (cond
     ;; Pattern: "1(5)" - leading number followed by (sense)
     ((string-match "^\\([0-9]+\\)\\((.*)\\)$" str)
      (let ((num (match-string 1 str))
            (rest (match-string 2 str)))
        (concat (mapconcat (lambda (c)
                             (char-to-string (or (cdr (assq c superscripts)) c)))
                           num "")
                rest)))
     ;; Pattern: "word1" - trailing number
     ((string-match "\\([^0-9]+\\)\\([0-9]+\\)$" str)
      (let ((word (match-string 1 str))
            (num (match-string 2 str)))
        (concat word
                (mapconcat (lambda (c)
                             (char-to-string (or (cdr (assq c superscripts)) c)))
                           num ""))))
     ;; No match, return as-is
     (t str))))

(defun lexdb-ui--normalize-search-word (str)
  "Normalize STR for dictionary lookup.
Removes trailing superscript numbers and other non-word characters.
E.g., 'end¹' -> 'end', 'mother²' -> 'mother'."
  (when str
    ;; Remove trailing superscript numbers
    (let ((result (replace-regexp-in-string "[⁰¹²³⁴⁵⁶⁷⁸⁹]+$" "" str)))
      ;; Also remove trailing regular numbers (for consistency)
      (setq result (replace-regexp-in-string "[0-9]+$" "" result))
      ;; Lowercase
      (downcase result))))

(defun lexdb-ui--render-headword (entry)
  "Render headword for ENTRY.
Converts trailing numbers to superscript (e.g., mother1 -> mother¹)."
  (let* ((display (or (lexdb-entry-headword-display entry)
                      (lexdb-entry-headword entry)))
         (formatted (lexdb-ui--number-to-superscript display)))
    (when (lexdb--non-empty-string-p formatted)
      (insert (propertize formatted 'face 'lexdb-headword-face)))))

(defun lexdb-ui--render-pronunciations (entry adapter)
  "Render pronunciations for ENTRY using ADAPTER."
  (let ((prons (lexdb-entry-pronunciations entry))
        (uk-ipa nil)
        (us-ipa nil))
    ;; Collect UK and US pronunciations
    (dolist (pron prons)
      (when-let ((ipa (lexdb-pronunciation-ipa pron)))
        (when (lexdb--non-empty-string-p ipa)
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
        (when (lexdb--non-empty-string-p dots)
          (insert " " (propertize dots 'face 'lexdb-frequency-dots-face)))))
    ;; Frequency level (S1 W2 etc) - use adapter hook if provided
    (when (memq 'frequency-band caps)
      (when-let ((freq (lexdb-meta-get meta ns "frequency")))
        (when (lexdb--non-empty-string-p freq)
          (if-let ((hook (lexdb-adapter-render-frequency-fn adapter)))
              (when-let ((rendered (funcall hook freq)))
                (insert " " rendered))
            (insert " " (propertize freq 'face 'lexdb-frequency-face))))))
    ;; CEFR level
    (when (memq 'cefr caps)
      (when-let ((cefr (lexdb-meta-get meta ns "cefr-level")))
        (when (lexdb--non-empty-string-p cefr)
          (insert " " (propertize (format "[%s]" cefr) 'face 'lexdb-cefr-face)))))))

(defun lexdb-ui--render-pos (entry adapter)
  "Render part of speech for ENTRY."
  (when (lexdb-adapter-has-capability-p adapter 'pos)
    (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
           (pos (lexdb-meta-get (lexdb-entry-metadata entry) ns "pos")))
      (when (lexdb--non-empty-string-p pos)
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
          (when (lexdb--non-empty-string-p path)
            (setq has-audio t)
            (insert (propertize "🔊 UK"
                                'face 'lexdb-audio-indicator-face
                                'lexdb-audio-path path
                                'lexdb-audio-dir audio-dir
                                'help-echo "C-c C-c to play UK pronunciation")))))
      ;; US audio
      (when (memq 'audio-us caps)
        (when-let ((path (lexdb-meta-get meta ns "audio-us")))
          (when (lexdb--non-empty-string-p path)
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
         (adapter-id (lexdb-adapter-id adapter))
         (meta (lexdb-entry-metadata entry))
         (infl-text (lexdb-meta-get meta ns "inflections"))
         (relations (lexdb-entry-relations entry))
         (inflections (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'inflection)) relations)))
    ;; Display full inflection text if available
    (when (lexdb--non-empty-string-p infl-text)
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
                 ;; Normalize search word for lookup
                 (search-word (lexdb-ui--normalize-search-word (or link target)))
                 (pos (string-match (regexp-quote target) text start))
                 ;; Capture adapter-id for closure
                 (jump-adapter adapter-id))
            (when pos
              ;; Insert text before the match
              (when (> pos start)
                (insert (propertize (substring text start pos) 'face 'lexdb-inflection-face)))
              ;; Insert clickable word - use intra-dictionary jump
              (if search-word
                  (insert-text-button target
                                      'face 'lexdb-inflection-link-face
                                      'action (lambda (_)
                                                (lexdb-search-and-goto-sense search-word nil jump-adapter))
                                      'help-echo (format "Look up: %s [%s]" search-word jump-adapter))
                (insert (propertize target 'face 'lexdb-inflection-face)))
              (setq start (+ pos (length target))))))
        ;; Insert remaining text
        (when (< start (length text))
          (insert (propertize (substring text start) 'face 'lexdb-inflection-face)))))))

(defun lexdb-ui--render-sense (sense adapter &optional entry)
  "Render a single SENSE using ADAPTER.
Optional ENTRY provides access to entry-level metadata for lexunits/grambox."
  (let ((caps (lexdb-adapter-capabilities adapter))
        (audio-dir (lexdb-adapter-audio-dir adapter))
        (ns (symbol-name (lexdb-adapter-id adapter)))
        (sense-num-str (or (lexdb-sense-number sense) "0")))
    ;; Sense number
    (when-let ((num (lexdb-sense-number sense)))
      (when (lexdb--non-empty-string-p num)
        (insert (propertize num 'face 'lexdb-sense-num-face) " ")))
    ;; Translation indicator (🌐) - right after sense number
    (when (memq 'chinese-definition caps)
      (when-let ((def-zh (lexdb-meta-get (lexdb-sense-metadata sense) ns "definition-zh")))
        (when (and (lexdb--non-empty-string-p def-zh) lexdb-ui-translation-indicator)
          (insert (propertize lexdb-ui-translation-indicator
                              'face 'lexdb-translation-indicator-face
                              'lexdb-translation def-zh
                              'help-echo "Press t to peek translation")
                  " "))))
    ;; Signpost (guide word) - displayed in uppercase with background
    ;; For OALD: fix parentheses spacing (remove spaces around parentheses)
    (when-let ((signpost (lexdb-sense-signpost sense)))
      (when (lexdb--non-empty-string-p signpost)
        (let ((formatted (upcase signpost)))
          ;; Fix spacing: "CALL (OUT)" -> "CALL(OUT)" for OALD style
          (when (eq (lexdb-adapter-id adapter) 'oald)
            (setq formatted (replace-regexp-in-string " +(" "(" formatted))
            (setq formatted (replace-regexp-in-string ") +" ")" formatted)))
          (insert (propertize formatted 'face 'lexdb-signpost-face) " "))))
    ;; OALD grammar codes inline (e.g., "[Tn] [I]") - before definition
    (when (eq (lexdb-adapter-id adapter) 'oald)
      (let ((gps (lexdb-sense-grammar-patterns sense)))
        (when gps
          (let ((codes (delq nil
                        (mapcar (lambda (gp)
                                  (let ((pattern (lexdb-grammar-pattern-pattern gp)))
                                    ;; Handle various formats:
                                    ;; 1. Already bracketed: "[I]", "[Tn.p]"
                                    ;; 2. Short code: "I", "Tn", "Tn.p", "Dn.n"
                                    ;; 3. Full text with Chinese: "Transitive verb 及物动词" - skip these
                                    ;; 4. English text only: "Intransitive verb" - skip these
                                    (cond
                                     ;; Already bracketed - use as-is
                                     ((string-match "^\\[\\([A-Za-z.]+\\)\\]$" pattern)
                                      pattern)
                                     ;; Short code (all caps/dots, ≤8 chars) - add brackets
                                     ((and (string-match "^[A-Za-z.]+$" pattern)
                                           (<= (length pattern) 8))
                                      (format "[%s]" pattern))
                                     ;; Skip full text (contains space or Chinese)
                                     (t nil))))
                                gps))))
            (when codes
              (insert (propertize (string-join codes " ") 'face 'lexdb-grammar-face) " "))))))
    ;; Grammar label (for non-OALD adapters)
    (when (memq 'grammar caps)
      (when-let ((gram (lexdb-sense-grammar sense)))
        (when (lexdb--non-empty-string-p gram)
          (insert (propertize gram 'face 'lexdb-grammar-face) " "))))
    ;; Lexunit prefix (e.g., "all round British English, all around American English")
    ;; Read from entry-level sense_lexunit_prefixes indexed by sense number
    ;; Now structured: [{'type': 'lexunit'/'geo'/'lexvar', 'text': '...'}, ...]
    (when entry
      (let* ((sense-prefixes (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_lexunit_prefixes"))
             (lexunit-prefix (when sense-prefixes
                               (cdr (assoc sense-num-str sense-prefixes #'string=)))))
        (when lexunit-prefix
          (let ((parts (cond
                        ((vectorp lexunit-prefix) (append lexunit-prefix nil))
                        ((listp lexunit-prefix) lexunit-prefix)
                        ((stringp lexunit-prefix) (list (list (cons 'type "lexunit") (cons 'text lexunit-prefix))))
                        (t nil)))
                (first-part t))
            (dolist (part parts)
              (let ((ptype (cdr (assoc 'type part)))
                    (ptext (cdr (assoc 'text part))))
                (when (and ptext (not (string-empty-p ptext)))
                  ;; Add comma separator before lexvar
                  (when (and (not first-part) (equal ptype "lexvar"))
                    (insert ", "))
                  ;; Add space between parts (except before comma)
                  (when (and (not first-part) (not (equal ptype "lexvar")))
                    (insert " "))
                  ;; Render based on type
                  (cond
                   ((or (equal ptype "lexunit") (equal ptype "lexvar"))
                    (insert (propertize ptext 'face 'lexdb-lexunit-face)))
                   ((equal ptype "geo")
                    (insert (propertize ptext 'face 'lexdb-register-face)))
                   (t
                    (insert (propertize ptext 'face 'lexdb-lexunit-face))))
                  (setq first-part nil))))
            (when parts (insert " "))))))
    ;; Register labels (e.g., "formal", "informal") - after lexunit, before definition
    ;; Also geographic/regional labels (e.g., "especially British English")
    (let ((labels (lexdb-sense-labels sense)))
      (when labels
        (dolist (label labels)
          (let ((ltype (lexdb-label-type label))
                (lvalue (lexdb-label-value label)))
            (when (and lvalue (member ltype '(register geo)))
              (insert (propertize lvalue 'face 'lexdb-register-face) " "))))))
    ;; Definition (English) - this may be just the lexunit for senses with subsenses
    (let ((def (lexdb-sense-definition sense)))
      (when (lexdb--non-empty-string-p def)
        (insert (propertize def 'face 'lexdb-definition-face))))
    ;; SYN/OPP labels after definition (not clickable)
    (let ((labels (lexdb-sense-labels sense)))
      (when labels
        (dolist (label labels)
          (let ((ltype (lexdb-label-type label))
                (lvalue (lexdb-label-value label)))
            (when (and lvalue (member ltype '(syn opp)))
              (insert " " (propertize (upcase (symbol-name ltype)) 'face 'lexdb-synonym-face)
                      " " (propertize lvalue 'face 'lexdb-synonym-face)))))))
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

    ;; Regular examples BEFORE grammar patterns (position=0)
    (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
      (unless subsenses
        (when (memq 'examples caps)
          (dolist (ex (lexdb-sense-examples sense))
            (let* ((ex-text (lexdb-example-text ex))
                   (audio-path (lexdb-example-audio ex))
                   (position (or (cdr (assoc 'position (lexdb-example-metadata ex))) 0))
                   (ex-zh (when (memq 'chinese-example caps)
                            (lexdb-meta-get (lexdb-example-metadata ex) ns "text-zh")))
                   (has-audio (and (memq 'audio-example caps) audio-path (lexdb--non-empty-string-p audio-path)))
                   (has-translation (and ex-zh (lexdb--non-empty-string-p ex-zh) lexdb-ui-translation-indicator)))
              (when (and (lexdb--non-empty-string-p ex-text) (= position 0))
                ;; Build indicator string: [audio][translation]
                (cond
                 ((and has-audio has-translation)
                  (insert (propertize "  🔊"
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play"))
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (has-audio
                  (insert (propertize "  🔊 "
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play")))
                 (has-translation
                  (insert "  ")
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (t
                  (insert "    ")))
                (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                (insert "\n")))))))
    ;; Grammar patterns
    (let ((adapter-id (lexdb-adapter-id adapter)))
      (unless (eq adapter-id 'oald)  ; Skip for OALD - codes shown inline
        (dolist (gp (lexdb-sense-grammar-patterns sense))
          (let ((pattern (lexdb-grammar-pattern-pattern gp))
                (gloss (lexdb-grammar-pattern-gloss gp)))
            (when (lexdb--non-empty-string-p pattern)
              ;; Pattern on its own line
              (insert (propertize pattern 'face 'lexdb-grammar-pattern-face))
              ;; Gloss after pattern (e.g., "(=during a particular day)")
              (when (and gloss (lexdb--non-empty-string-p gloss))
                (insert " " (propertize gloss 'face 'lexdb-definition-face)))
              (insert "\n")
              ;; Grammar pattern examples
              (dolist (ex (lexdb-grammar-pattern-examples gp))
                (let ((ex-text (lexdb-example-text ex))
                      (audio-path (lexdb-example-audio ex)))
                  (when (lexdb--non-empty-string-p ex-text)
                    ;; Audio indicator at start if audio available
                    (if (and audio-path (lexdb--non-empty-string-p audio-path))
                        (insert (propertize "    🔊 "
                                            'face 'lexdb-audio-indicator-face
                                            'lexdb-audio-path audio-path
                                            'lexdb-audio-dir audio-dir
                                            'help-echo "C-c C-c to play"))
                      (insert "    "))
                    (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                    (insert "\n")))))))))
    ;; Regular examples AFTER grammar patterns (position=1)
    (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
      (unless subsenses
        (when (memq 'examples caps)
          (dolist (ex (lexdb-sense-examples sense))
            (let* ((ex-text (lexdb-example-text ex))
                   (audio-path (lexdb-example-audio ex))
                   (position (or (cdr (assoc 'position (lexdb-example-metadata ex))) 0))
                   (ex-zh (when (memq 'chinese-example caps)
                            (lexdb-meta-get (lexdb-example-metadata ex) ns "text-zh")))
                   (has-audio (and (memq 'audio-example caps) audio-path (lexdb--non-empty-string-p audio-path)))
                   (has-translation (and ex-zh (lexdb--non-empty-string-p ex-zh) lexdb-ui-translation-indicator)))
              (when (and (lexdb--non-empty-string-p ex-text) (= position 1))
                ;; Build indicator string: [audio][translation]
                (cond
                 ((and has-audio has-translation)
                  (insert (propertize "  🔊"
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play"))
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (has-audio
                  (insert (propertize "  🔊 "
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play")))
                 (has-translation
                  (insert "  ")
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (t
                  (insert "    ")))
                (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                (insert "\n")))))))
    ;; Lexunits (sub-phrases like "call a doctor/the police")
    ;; Read from entry-level sense_lexunits indexed by sense number
    (when entry
      (let* ((sense-lexunits (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_lexunits"))
             ;; Use string= for proper string key matching in JSON-parsed alist
             (lexunits (when sense-lexunits
                         (cdr (assoc sense-num-str sense-lexunits #'string=))))
             ;; Get definition to check for duplicates
             (sense-def (or (lexdb-sense-definition sense) "")))
        (when lexunits
          (let ((lu-list (if (vectorp lexunits) (append lexunits nil) lexunits)))
            (dolist (lu lu-list)
              (let ((lu-text (cdr (assoc 'text lu)))
                    (lu-def (cdr (assoc 'definition lu)))
                    (lu-examples (cdr (assoc 'examples lu))))
                ;; Skip if lexunit text is already part of the definition
                ;; (e.g., "somebody's day: definition" where "somebody's day" is also a lexunit)
                (when (and lu-text
                           (not (string-prefix-p lu-text sense-def)))
                  ;; Lexunit text (bold)
                  (insert "  " (propertize lu-text 'face 'lexdb-lexunit-face))
                  ;; Definition
                  (when (and lu-def (not (string-empty-p lu-def)))
                    (insert " " (propertize lu-def 'face 'lexdb-definition-face)))
                  (insert "\n")
                  ;; Examples
                  (when lu-examples
                    (let ((ex-list (if (vectorp lu-examples) (append lu-examples nil) lu-examples)))
                      (dolist (ex ex-list)
                        (let ((ex-text (cdr (assoc 'text ex)))
                              (ex-audio (cdr (assoc 'audio_path ex))))
                          (when (and ex-text (not (string-empty-p ex-text)))
                            (if (and ex-audio (not (string-empty-p ex-audio)))
                                (insert (propertize "      🔊 "
                                                    'face 'lexdb-audio-indicator-face
                                                    'lexdb-audio-path ex-audio
                                                    'lexdb-audio-dir audio-dir
                                                    'help-echo "C-c C-c to play"))
                              (insert "      "))
                            (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                            (insert "\n")))))))))))))

    ;; Sense-level cross references (e.g., "→ day-to-day, → live from day to day at live¹(5)")
    ;; Now supports fragment format with prefix, clickable, suffix
    ;; Multiple refs on same line, separated by comma
    (let ((sense-relations (lexdb-sense-relations sense))
          (adapter-id (lexdb-adapter-id adapter)))
      (when sense-relations
        (let ((cross-refs (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'cross_ref)) sense-relations)))
          (when cross-refs
            (insert "  ")
            (let ((first t))
              (dolist (ref cross-refs)
                (unless first (insert ", "))
                (setq first nil)
                (let* ((prefix (lexdb-relation-prefix ref))
                       (clickable (lexdb-relation-clickable ref))
                       (suffix (lexdb-relation-suffix ref))
                       (target-word (lexdb-relation-target-word ref))
                       (target-sense (lexdb-relation-target-sense ref))
                       ;; Legacy format fallback
                       (target (lexdb-relation-target ref))
                       (jump-adapter adapter-id))
                  (if clickable
                      ;; New fragment format
                      (let* ((search-word (lexdb-ui--normalize-search-word
                                           (or target-word clickable)))
                             ;; Convert trailing numbers to superscript for display
                             (display-clickable (lexdb-ui--number-to-superscript clickable))
                             ;; Full display text including suffix
                             (full-display (concat display-clickable (or suffix ""))))
                        ;; Prefix (e.g., "→ live from day to day ") - normal text color
                        (when (and prefix (not (string-empty-p prefix)))
                          (insert (propertize prefix 'face 'lexdb-definition-face)))
                        ;; Clickable part including suffix (e.g., "at care²(8)" - all clickable)
                        (insert-text-button full-display
                                            'face 'lexdb-crossref-face
                                            'action (lambda (_)
                                                      (lexdb-search-and-goto-sense
                                                       search-word target-sense jump-adapter))
                                            'help-echo (format "Look up: %s%s [%s]"
                                                               search-word
                                                               (if target-sense (format " sense %s" target-sense) "")
                                                               jump-adapter)))
                    ;; Legacy format - use target directly
                    (when target
                      (insert (propertize "→ " 'face 'lexdb-crossref-face))
                      (insert-text-button target
                                          'face 'lexdb-crossref-face
                                          'action (lambda (_)
                                                    (lexdb-search-and-goto-sense target nil jump-adapter))
                                          'help-echo (format "Look up: %s [%s]" target jump-adapter)))))))
            (insert "\n")))))

    ;; Grammar box (GRAMMAR usage notes)
    ;; Read from entry-level sense_grammar_boxes indexed by sense number
    (when entry
      (let* ((sense-gramboxes (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_grammar_boxes"))
             ;; Use string= for proper string key matching in JSON-parsed alist
             (grambox (when sense-gramboxes
                        (cdr (assoc sense-num-str sense-gramboxes #'string=)))))
        (when grambox
          (let ((heading (cdr (assoc 'heading grambox)))
                (notes (cdr (assoc 'notes grambox)))
                (grambox-start (point)))  ; Mark start for overlay
            ;; Heading
            (when (and heading (not (string-empty-p heading)))
              (insert "\n  " (propertize heading 'face 'lexdb-grambox-heading-face) "\n"))
            ;; Notes - use separate fields for proper formatting
            (when notes
              (let ((notes-list (if (vectorp notes) (append notes nil) notes)))
                (dolist (note notes-list)
                  (let ((expr (cdr (assoc 'expr note)))
                        (examples (cdr (assoc 'examples note)))  ; Now a list
                        (example (cdr (assoc 'example note)))    ; Legacy single example
                        (bad-example (cdr (assoc 'bad_example note)))
                        (text (cdr (assoc 'text note))))
                    ;; Extract the main explanation from text (before the example marker)
                    ;; text format: "• You call someone on the phone: · Call me tomorrow. ✗Don't say: ..."
                    (let* ((main-text (if (and text (string-match "\\(.*?\\)\\(·\\|✗\\)" text))
                                          (string-trim (match-string 1 text))
                                        text)))
                      (insert "  ")
                      ;; Main text with expr highlighted
                      (if (and expr (not (string-empty-p expr)) main-text)
                          (let ((expr-pos (string-match (regexp-quote expr) main-text)))
                            (if expr-pos
                                (progn
                                  (insert (propertize (substring main-text 0 expr-pos) 'face 'lexdb-definition-face))
                                  (insert (propertize expr 'face 'lexdb-grambox-expr-face))
                                  (insert (propertize (substring main-text (+ expr-pos (length expr))) 'face 'lexdb-definition-face)))
                              (insert (propertize main-text 'face 'lexdb-definition-face))))
                        (when main-text
                          (insert (propertize main-text 'face 'lexdb-definition-face))))
                      (insert "\n")
                      ;; Good examples (multiple) on new lines
                      (let ((ex-list (cond
                                      ((and examples (listp examples)) examples)
                                      ((vectorp examples) (append examples nil))
                                      ((and example (not (string-empty-p example))) (list example))
                                      (t nil))))
                        (dolist (ex ex-list)
                          (when (and ex (not (string-empty-p ex)))
                            (insert "    " (propertize "· " 'face 'lexdb-definition-face)
                                    (propertize ex 'face 'lexdb-example-face) "\n"))))
                      ;; Bad example on new line
                      (when (and bad-example (not (string-empty-p bad-example)))
                        (insert "    " (propertize "✗ Don't say: " 'face 'lexdb-bad-example-face)
                                (propertize bad-example 'face 'lexdb-bad-example-face) "\n")))))))
            ;; Create overlay for background
            (let ((ov (make-overlay grambox-start (point))))
              (overlay-put ov 'face 'lexdb-grambox-background-face)
              (overlay-put ov 'lexdb-grambox t))
            (insert "\n")))))

    ;; Register box (Register usage notes)
    ;; Read from entry-level sense_register_boxes indexed by sense number
    (when entry
      (let* ((sense-registerboxes (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_register_boxes"))
             (registerbox (when sense-registerboxes
                            (cdr (assoc sense-num-str sense-registerboxes #'string=)))))
        (when registerbox
          (let ((heading (cdr (assoc 'heading registerbox)))
                (notes (cdr (assoc 'notes registerbox)))
                (regbox-start (point)))
            ;; Heading
            (when (and heading (not (string-empty-p heading)))
              (insert "\n  " (propertize heading 'face 'lexdb-grambox-heading-face) "\n"))
            ;; Notes
            (when notes
              (let ((notes-list (if (vectorp notes) (append notes nil) notes)))
                (dolist (note notes-list)
                  (let ((expr (cdr (assoc 'expr note)))
                        (examples (cdr (assoc 'examples note)))
                        (example (cdr (assoc 'example note)))
                        (text (cdr (assoc 'text note))))
                    (let* ((main-text (if (and text (string-match "\\(.*?\\)\\(·\\|✗\\)" text))
                                          (string-trim (match-string 1 text))
                                        text)))
                      (insert "  ")
                      (if (and expr (not (string-empty-p expr)) main-text)
                          (let ((expr-list (split-string expr ", " t))
                                (remaining-text main-text))
                            (dolist (ex expr-list)
                              (let ((expr-pos (string-match (regexp-quote ex) remaining-text)))
                                (when expr-pos
                                  (insert (propertize (substring remaining-text 0 expr-pos) 'face 'lexdb-definition-face))
                                  (insert (propertize ex 'face 'lexdb-grambox-expr-face))
                                  (setq remaining-text (substring remaining-text (+ expr-pos (length ex)))))))
                            (insert (propertize remaining-text 'face 'lexdb-definition-face)))
                        (when main-text
                          (insert (propertize main-text 'face 'lexdb-definition-face))))
                      (insert "\n")
                      (let ((ex-list (cond
                                      ((and examples (listp examples)) examples)
                                      ((vectorp examples) (append examples nil))
                                      ((and example (not (string-empty-p example))) (list example))
                                      (t nil))))
                        (dolist (ex ex-list)
                          (when (and ex (not (string-empty-p ex)))
                            (insert "    " (propertize "· " 'face 'lexdb-definition-face)
                                    (propertize ex 'face 'lexdb-example-face) "\n")))))))))
            ;; Create overlay for background
            (let ((ov (make-overlay regbox-start (point))))
              (overlay-put ov 'face 'lexdb-grambox-background-face)
              (overlay-put ov 'lexdb-registerbox t))
            (insert "\n")))))))

(defun lexdb-ui--render-synonyms-and-crossrefs (entry adapter)
  "Render synonyms and cross-refs for ENTRY (inline, not in tabs)."
  (let ((caps (lexdb-adapter-capabilities adapter))
        (relations (lexdb-entry-relations entry))
        (adapter-id (lexdb-adapter-id adapter)))
    (let ((synonyms (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'synonym)) relations))
          (cross-refs (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'cross_ref)) relations)))
      ;; Synonyms
      (when (and (memq 'synonyms caps) synonyms)
        (insert (propertize "SYN " 'face 'lexdb-label-face))
        (lexdb-ui--insert-linked-relations synonyms 'lexdb-synonym-face adapter-id)
        (insert "\n"))
      ;; Cross references
      (when (and (memq 'cross-refs caps) cross-refs)
        (insert (propertize "→ " 'face 'lexdb-crossref-face))
        (lexdb-ui--insert-linked-relations cross-refs 'lexdb-crossref-face adapter-id)
        (insert "\n\n")))))

(defun lexdb-ui--insert-linked-relations (relations face &optional adapter-id)
  "Insert RELATIONS with clickable links using FACE.
Uses fragment storage format: prefix + clickable + suffix.
If ADAPTER-ID is provided, links will jump within the same dictionary.
No regex matching needed - data is pre-parsed."
  (let ((first t))
    (dolist (rel relations)
      (unless first (insert ", "))
      (setq first nil)
      ;; Get fragment fields (new format)
      (let ((prefix (lexdb-relation-prefix rel))
            (clickable (lexdb-relation-clickable rel))
            (suffix (lexdb-relation-suffix rel))
            (target-word (lexdb-relation-target-word rel))
            (target-sense (lexdb-relation-target-sense rel))
            ;; Capture adapter-id in closure for intra-dictionary jump
            (jump-adapter adapter-id))
        (if clickable
            ;; New fragment format - clean rendering
            (progn
              ;; Insert prefix (non-clickable)
              (when (and prefix (not (string-empty-p prefix)))
                (insert (propertize prefix 'face 'lexdb-definition-face)))
              ;; Insert clickable part as button
              ;; Normalize search word: remove superscripts/numbers, lowercase
              (let ((search-word (lexdb-ui--normalize-search-word
                                  (or target-word clickable)))
                    ;; Convert trailing numbers to superscript for display
                    (display-clickable (lexdb-ui--number-to-superscript clickable))
                    ;; Include suffix in clickable area
                    (display-suffix (or suffix "")))
                ;; Combine clickable and suffix for full button
                (insert-text-button (concat display-clickable display-suffix)
                                    'face face
                                    'action (lambda (_)
                                              (lexdb-search-and-goto-sense
                                               search-word
                                               target-sense
                                               jump-adapter))
                                    'help-echo (format "Look up: %s%s%s"
                                                       search-word
                                                       (if target-sense (format " sense %s" target-sense) "")
                                                       (if jump-adapter (format " [%s]" jump-adapter) "")))))
          ;; Fallback: legacy format or no clickable - show target as plain text
          (let ((target (lexdb-relation-target rel)))
            (when target
              (insert (propertize target 'face 'lexdb-definition-face)))))))))

(defun lexdb-search-and-goto-sense (word &optional sense-num adapter-id)
  "Search for WORD and optionally scroll to SENSE-NUM.
If ADAPTER-ID is provided, search within that dictionary only (intra-dictionary jump).
In multi-dict mode, updates current buffer and switches to the target dict tab.
Otherwise, fall back to global search."
  (setq lexdb-ui--pending-sense-num sense-num)
  (if adapter-id
      ;; Intra-dictionary jump
      (let* ((adapter (lexdb-get-adapter adapter-id))
             (entries (lexdb-lookup word adapter-id)))
        ;; Try lemmatization if no direct match
        (unless entries
          (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
            (when-let ((lemma (lexdb-find-lemma word adapter-id)))
              (unless (equal lemma (downcase word))
                (setq entries (lexdb-lookup lemma adapter-id))
                (when entries
                  (setq word lemma))))))
        (if entries
            ;; Found in same dictionary - add to history manually since we're not calling lexdb-search
            (progn
              (lexdb--history-push word)
              (if (and lexdb-multi-dict-mode
                       (eq (current-buffer) (get-buffer "*Lexdb*")))
                  ;; Multi-dict mode: update results and switch tab in current buffer
                  (lexdb-ui--jump-in-multi-buffer word adapter-id)
                ;; Single dict mode or not in multi buffer: update current buffer
                (lexdb-ui-display word entries adapter t)))
          ;; Not found in same dictionary - fallback to global search (which handles history)
          (message "Not found in %s, searching all dictionaries..." adapter-id)
          (lexdb-search word)))
    ;; No adapter specified: global search (which handles history)
    (lexdb-search word)))

(defun lexdb-ui--jump-in-multi-buffer (word adapter-id)
  "Update multi-dict buffer with WORD lookup results, switch to ADAPTER-ID tab."
  (let ((inhibit-read-only t))
    ;; Update the word
    (setq lexdb-ui--current-word word)
    ;; Re-query all dictionaries for the new word
    (setq lexdb-ui--dict-results (lexdb-ui--query-all-dicts word))
    ;; Switch to the target dictionary
    (setq lexdb-ui--active-dict adapter-id)
    ;; Refresh display
    (lexdb-ui--refresh-display)
    ;; Handle pending sense jump
    (when lexdb-ui--pending-sense-num
      (let ((sense-num lexdb-ui--pending-sense-num))
        (setq lexdb-ui--pending-sense-num nil)
        (goto-char (point-min))
        (when (re-search-forward
               (concat "^[[:space:]]*" (regexp-quote sense-num) " ")
               nil t)
          (beginning-of-line)
          (recenter))))))

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
VERB-TABLE is a list or vector of verb form entries.
Displays as proper tables with borders."
  (with-temp-buffer
    (let ((forms (if (vectorp verb-table) (append verb-table nil) verb-table))
          (simple-forms '())
          (continuous-forms '()))
      ;; Separate simple and continuous forms
      (dolist (form forms)
        (let ((verb-form (cdr (assoc 'form form))))
          (if (and verb-form (string-match-p "\\(am\\|is\\|are\\|was\\|were\\|been\\|be\\) " verb-form))
              (push form continuous-forms)
            (push form simple-forms))))
      (setq simple-forms (nreverse simple-forms))
      (setq continuous-forms (nreverse continuous-forms))

      ;; Calculate column widths
      (let ((col1-width 16)   ; Tense column
            (col2-width 26)   ; Subject column
            (col3-width 20))  ; Form column

        ;; Use cl-labels for recursive/mutually referencing local functions
        (cl-labels
            ((pad-string (str width)
               (let ((s (or str "")))
                 (if (> (length s) width)
                     (substring s 0 width)
                   (concat s (make-string (- width (length s)) ?\s)))))
             (draw-top ()
               (insert "  ┌" (make-string col1-width ?─) "┬"
                       (make-string col2-width ?─) "┬"
                       (make-string col3-width ?─) "┐\n"))
             (draw-line ()
               (insert "  ├" (make-string col1-width ?─) "┼"
                       (make-string col2-width ?─) "┼"
                       (make-string col3-width ?─) "┤\n"))
             (draw-bottom ()
               (insert "  └" (make-string col1-width ?─) "┴"
                       (make-string col2-width ?─) "┴"
                       (make-string col3-width ?─) "┘\n"))
             (render-table (title forms-list)
               (when forms-list
                 ;; Table title
                 (draw-top)
                 (insert "  │" (propertize (pad-string title (+ col1-width col2-width col3-width 2))
                                           'face 'lexdb-label-face) "│\n")
                 (draw-line)
                 ;; Table rows
                 (let ((current-tense ""))
                   (dolist (form forms-list)
                     (let ((tense (or (cdr (assoc 'tense form)) ""))
                           (subject (or (cdr (assoc 'subject form)) ""))
                           (verb-form (or (cdr (assoc 'form form)) "")))
                       ;; Only show tense if different from previous
                       (let ((show-tense (if (string= tense current-tense) "" tense)))
                         (setq current-tense tense)
                         (insert "  │"
                                 (propertize (pad-string show-tense col1-width) 'face 'lexdb-label-face) "│"
                                 (propertize (pad-string subject col2-width) 'face 'lexdb-grammar-label-face) "│"
                                 (propertize (pad-string verb-form col3-width) 'face 'lexdb-headword-face) "│\n")))))
                 (draw-bottom)
                 (insert "\n"))))

          ;; Render Simple Form table
          (render-table "SIMPLE FORM" simple-forms)
          ;; Render Continuous Form table
          (render-table "CONTINUOUS FORM" continuous-forms))))
    (buffer-string)))

(defun lexdb-ui--build-corpus-examples-content (examples)
  "Build content string for EXAMPLES tab.
EXAMPLES is a list or vector of sections with header and examples."
  (with-temp-buffer
    (let ((sections (if (vectorp examples) (append examples nil) examples))
          (first-section t))
      (dolist (section sections)
        ;; Check if it's new format (with header) or old format (just strings)
        (if (and (listp section) (assoc 'header section))
            ;; New format with header
            (let ((header (cdr (assoc 'header section)))
                  (exs (cdr (assoc 'examples section))))
              ;; Add blank line before section (except first)
              (unless first-section
                (insert "\n"))
              (setq first-section nil)
              ;; Section header
              (when header
                (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
              ;; Examples (no blank line after header)
              (let ((ex-list (if (vectorp exs) (append exs nil) exs)))
                (dolist (ex ex-list)
                  (when (and ex (not (string-empty-p ex)))
                    (insert "    • ")
                    (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                    (insert "\n")))))
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
          (last-header "")
          (first-section t))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (sec-title (cdr (assoc 'section section)))
              (items (cdr (assoc 'items section))))
          ;; Add blank line before section (except first)
          (unless first-section
            (insert "\n"))
          (setq first-section nil)
          ;; Show header if changed (e.g., "Longman Language Activator", "WORD SETS")
          (when (and header (not (string= header last-header)))
            (setq last-header header)
            (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
          ;; Section title (e.g., "what you say to explain the most basic facts")
          (when (and sec-title (not (string-empty-p sec-title)))
            (insert (propertize (concat "  " (upcase sec-title)) 'face 'lexdb-tab-section-header-face) "\n"))
          ;; Items (no blank line after header)
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
                            (insert "\n")))))
                     ;; Just word/pos - word sets style (no ▶, compact list)
                     (word
                      (insert "      " (propertize word 'face 'lexdb-crossref-face))
                      (when (and pos (not (string-empty-p pos)))
                        (insert " " (propertize pos 'face 'lexdb-pos-face)))
                      (insert "\n")))))))))))
    (buffer-string)))

(defun lexdb-ui--build-word-family-content (word-family adapter-id)
  "Build content string for WORD FAMILY tab.
WORD-FAMILY is a list of sections with header and groups (by POS).
ADAPTER-ID is used for intra-dictionary jumps."
  (with-temp-buffer
    (let ((sections (if (vectorp word-family) (append word-family nil) word-family))
          ;; Use passed adapter-id for intra-dictionary jumps
          (jump-adapter adapter-id))
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
                                            'action (lambda (_)
                                                      (lexdb-search-and-goto-sense word nil jump-adapter))
                                            'help-echo (format "Look up: %s [%s]" word (or jump-adapter "all")))
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
                                        'action (lambda (_)
                                                  (lexdb-search-and-goto-sense word nil jump-adapter))
                                        'help-echo (format "Look up: %s [%s]" word (or jump-adapter "all")))
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
    (let ((sections (if (vectorp entry-menu) (append entry-menu nil) entry-menu))
          (first-section t))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          ;; Check if section has any content
          (let ((item-list (if (vectorp items) (append items nil) items))
                (has-content nil))
            ;; Check if there are valid items
            (dolist (item item-list)
              (let ((num (cdr (assoc 'number item)))
                    (label (cdr (assoc 'label item))))
                (when (or num label)
                  (setq has-content t))))
            ;; Only render if has header or content
            (when (or (and header (not (string-empty-p header))) has-content)
              ;; Add blank line before section (except first)
              (unless first-section
                (insert "\n"))
              (setq first-section nil)
              ;; Section header
              (when (and header (not (string-empty-p header)))
                (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
              ;; Items (no blank line after header)
              (dolist (item item-list)
                (let ((num (cdr (assoc 'number item)))
                      (label (cdr (assoc 'label item))))
                  (when (or num label)
                    (insert (propertize "    " 'face 'lexdb-definition-face))
                    (when num
                      (insert (propertize (concat num " ") 'face 'lexdb-sense-num-face)))
                    (when label
                      (insert (propertize label 'face 'lexdb-definition-face)))
                    (insert "\n")))))))))
    (buffer-string)))

(defun lexdb-ui--build-word-sets-content (word-sets)
  "Build content string for WORD SETS tab.
WORD-SETS is a list of sections with header and items."
  (with-temp-buffer
    (let ((sections (if (vectorp word-sets) (append word-sets nil) word-sets))
          (first-section t))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          ;; Add blank line before section (except first)
          (unless first-section
            (insert "\n"))
          (setq first-section nil)
          ;; Section header
          (when (and header (not (string-empty-p header)))
            (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
          ;; Items (no blank line after header)
          (let ((item-list (if (vectorp items) (append items nil) items)))
            (dolist (item item-list)
              (when (and item (not (string-empty-p item)))
                (insert "    • " (propertize item 'face 'lexdb-crossref-face) "\n")))))))
    (buffer-string)))

(defun lexdb-ui--build-popup-collocations-content (popup-colls)
  "Build content string for popup collocations.
POPUP-COLLS is a list of sections with header and collocation items."
  (with-temp-buffer
    (let ((sections (if (vectorp popup-colls) (append popup-colls nil) popup-colls))
          (first-section t))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          ;; Add blank line before section (except first)
          (unless first-section
            (insert "\n"))
          (setq first-section nil)
          ;; Section header
          (when (and header (not (string-empty-p header)))
            (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
          ;; Items (no blank line after header)
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
    (let ((sections (if (vectorp popup-phrases) (append popup-phrases nil) popup-phrases))
          (first-section t))
      (dolist (section sections)
        (let ((header (cdr (assoc 'header section)))
              (items (cdr (assoc 'items section))))
          ;; Add blank line before section (except first)
          (unless first-section
            (insert "\n"))
          (setq first-section nil)
          ;; Section header
          (when (and header (not (string-empty-p header)))
            (insert (propertize (concat "  " header) 'face 'lexdb-tab-section-header-face) "\n"))
          ;; Items (no blank line after header)
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
                ;; Labels - geo and register BEFORE definition
                (dolist (label labels)
                  (let ((ltype (cdr (assoc 'type label)))
                        (lvalue (cdr (assoc 'value label))))
                    (when lvalue
                      (cond
                       ((string= ltype "geo")
                        (insert (propertize lvalue 'face 'lexdb-geo-face) " "))
                       ((string= ltype "register")
                        (insert (propertize lvalue 'face 'lexdb-register-face) " "))))))
                ;; Definition
                (when definition
                  (insert (propertize definition 'face 'lexdb-definition-face)))
                ;; SYN label AFTER definition
                (dolist (label labels)
                  (let ((ltype (cdr (assoc 'type label)))
                        (lvalue (cdr (assoc 'value label))))
                    (when (and lvalue (string= ltype "syn"))
                      (insert " " (propertize "SYN " 'face 'lexdb-synonym-face)
                              (propertize lvalue 'face 'lexdb-synonym-face)))))
                ;; Related word reference AFTER definition (e.g., "→ call-up")
                (dolist (label labels)
                  (let ((ltype (cdr (assoc 'type label)))
                        (lvalue (cdr (assoc 'value label))))
                    (when (and lvalue (string= ltype "related"))
                      (insert " " (propertize lvalue 'face 'lexdb-crossref-face)))))
                (insert "\n")
                ;; Examples
                (dolist (ex examples)
                  (when (and ex (not (string-empty-p ex)))
                    (insert "    " (propertize ex 'face 'lexdb-example-face) "\n"))))))
          (insert "\n"))))))

(defun lexdb-ui--build-collocations-content (collocations)
  "Build content string for COLLOCATIONS tab."
  (with-temp-buffer
    (let ((current-category nil)
          (first-category t))
      (dolist (coll collocations)
        (let ((category (lexdb-collocation-category coll))
              (text (lexdb-collocation-text coll))
              (gloss (lexdb-collocation-gloss coll))
              (examples (lexdb-collocation-examples coll)))
          ;; Category header - more prominent
          (when (and (lexdb--non-empty-string-p category)
                     (not (equal category current-category)))
            (setq current-category category)
            ;; Add blank line before category (except first)
            (unless first-category
              (insert "\n"))
            (setq first-category nil)
            (insert (propertize (concat "  " (upcase category))
                                'face 'lexdb-tab-section-header-face))
            (insert "\n"))
          ;; Collocation word
          (when (lexdb--non-empty-string-p text)
            (insert "    " (propertize text 'face 'lexdb-collocation-word-face))
            ;; Gloss
            (when (lexdb--non-empty-string-p gloss)
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

;; Old lexdb-ui-render-entry removed - replaced by slot-based version below

;;;; ============================================================
;;;; Slot Rendering Functions (插槽渲染函数)
;;;; ============================================================

(defun lexdb-ui--slot-header (entry adapter)
  "Slot: Render entry header (headword, pronunciation, POS, etc.)."
  (let ((caps (lexdb-adapter-capabilities adapter)))
    (if-let ((header-hook (lexdb-adapter-render-entry-header-fn adapter)))
        (funcall header-hook entry (current-buffer))
      ;; Default header rendering
      (lexdb-ui--render-headword entry)
      (when (memq 'pronunciation caps)
        (lexdb-ui--render-pronunciations entry adapter))
      (lexdb-ui--render-frequency entry adapter)
      (lexdb-ui--render-pos entry adapter)
      (lexdb-ui--render-inflections entry adapter)
      (insert "\n")
      (lexdb-ui--render-audio-buttons entry adapter)
      (insert "\n"))))

(defun lexdb-ui--slot-tabs (entry adapter)
  "Slot: Render tab bar (COLLOCATIONS, THESAURUS, WORD ORIGIN, etc.)."
  (let ((tabs nil)
        (entry-id (lexdb-entry-id entry))
        (tab-group (format "lexdb-tabs-%d-%d" (lexdb-entry-id entry) (random 10000)))
        (ns (symbol-name (lexdb-adapter-id adapter)))
        (caps (lexdb-adapter-capabilities adapter)))
    ;; ENTRY MENU tab
    (let ((entry-menu (lexdb-meta-get (lexdb-entry-metadata entry) ns "entry_menu")))
      (when (and entry-menu (> (length entry-menu) 0))
        (push (list 'entry-menu "ENTRY MENU"
                    (lexdb-ui--build-entry-menu-content entry-menu))
              tabs)))
    ;; WORD ORIGIN tab
    (when (lexdb-adapter-has-capability-p adapter 'origin)
      (let ((origin (lexdb-meta-get (lexdb-entry-metadata entry) ns "origin_full")))
        (when (lexdb--non-empty-string-p origin)
          (push (list 'origin "WORD ORIGIN"
                      (concat "  " (propertize origin 'face 'lexdb-origin-face) "\n"))
                tabs))))
    ;; VERB TABLE tab
    (let ((verb-table (lexdb-meta-get (lexdb-entry-metadata entry) ns "verb_table")))
      (when (and verb-table (> (length verb-table) 0))
        (push (list 'verb-table "VERB TABLE"
                    (lexdb-ui--build-verb-table-content verb-table))
              tabs)))
    ;; EXAMPLES tab
    (let ((corpus-examples (lexdb-meta-get (lexdb-entry-metadata entry) ns "corpus_examples")))
      (when (and corpus-examples (> (length corpus-examples) 0))
        (push (list 'examples "EXAMPLES"
                    (lexdb-ui--build-corpus-examples-content corpus-examples))
              tabs)))
    ;; THESAURUS tab
    (let ((thesaurus (lexdb-meta-get (lexdb-entry-metadata entry) ns "thesaurus")))
      (when (and thesaurus (> (length thesaurus) 0))
        (push (list 'thesaurus "THESAURUS"
                    (lexdb-ui--build-thesaurus-content thesaurus))
              tabs)))
    ;; COLLOCATIONS tab
    (when (memq 'collocations caps)
      (let ((colls (or (lexdb-meta-get (lexdb-entry-metadata entry) ns "collocations-cache")
                       (when (lexdb-adapter-collocations-fn adapter)
                         (funcall (lexdb-adapter-collocations-fn adapter) entry-id))))
            (popup-colls (lexdb-meta-get (lexdb-entry-metadata entry) ns "popup_collocations")))
        (let ((content ""))
          (when colls
            (setq content (lexdb-ui--build-collocations-content colls)))
          (when (and popup-colls (> (length popup-colls) 0))
            (setq content (concat content (lexdb-ui--build-popup-collocations-content popup-colls))))
          (when (not (string-empty-p content))
            (push (list 'collocations "COLLOCATIONS" content) tabs)))))
    ;; PHRASES tab
    (let ((popup-phrases (lexdb-meta-get (lexdb-entry-metadata entry) ns "popup_phrases")))
      (when (and popup-phrases (> (length popup-phrases) 0))
        (push (list 'phrases "PHRASES"
                    (lexdb-ui--build-popup-phrases-content popup-phrases))
              tabs)))
    ;; WORD FAMILY tab
    (let ((word-family (lexdb-meta-get (lexdb-entry-metadata entry) ns "word_family")))
      (when (and word-family (> (length word-family) 0))
        (push (list 'word-family "WORD FAMILY"
                    (lexdb-ui--build-word-family-content word-family (lexdb-adapter-id adapter)))
              tabs)))
    ;; Insert tab bar if we have any tabs
    (when tabs
      (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group))))

(defun lexdb-ui--slot-senses (entry adapter)
  "Slot: Render senses/definitions."
  (dolist (sense (lexdb-entry-senses entry))
    (lexdb-ui--render-sense sense adapter entry))
  (insert "\n"))

(defun lexdb-ui--slot-entry-grammar-box (entry adapter)
  "Slot: Render entry-level grammar box."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (entry-grammar-boxes (lexdb-meta-get (lexdb-entry-metadata entry) ns "entry_grammar_boxes")))
    (when (and entry-grammar-boxes (> (length entry-grammar-boxes) 0))
      (let ((grambox-list (if (vectorp entry-grammar-boxes) (append entry-grammar-boxes nil) entry-grammar-boxes)))
        (dolist (grambox grambox-list)
          (let ((heading (cdr (assoc 'heading grambox)))
                (notes (cdr (assoc 'notes grambox)))
                (grambox-start (point)))
            (when (and heading (not (string-empty-p heading)))
              (insert "  " (propertize heading 'face 'lexdb-grambox-heading-face) "\n"))
            (when notes
              (let ((notes-list (if (vectorp notes) (append notes nil) notes)))
                (dolist (note notes-list)
                  (let ((pattern (cdr (assoc 'pattern note)))
                        (expr (cdr (assoc 'expr note)))
                        (examples (cdr (assoc 'examples note)))  ; List of examples
                        (example (cdr (assoc 'example note)))    ; Legacy single example
                        (bad-example (cdr (assoc 'bad_example note)))
                        (text (cdr (assoc 'text note))))
                    ;; Build examples list from either format
                    (let ((ex-list (cond
                                    ((and examples (listp examples) (not (null examples))) examples)
                                    ((vectorp examples) (append examples nil))
                                    ((and example (stringp example) (not (string-empty-p example))) (list example))
                                    (t nil))))
                      (when (and pattern (not (string-empty-p pattern)))
                        (insert "  " (propertize pattern 'face 'lexdb-lexunit-face) "\n"))
                      (cond
                       ((or ex-list (and bad-example (not (string-empty-p bad-example))))
                        (when text
                          (let* ((main-text (if (string-match "\\(.*?\\)\\( · \\| ✗\\)" text)
                                                (string-trim (match-string 1 text))
                                              text)))
                            (insert "  ")
                            (if (and expr (not (string-empty-p expr)) main-text)
                                ;; Handle multiple expressions separated by comma
                                (let ((expr-list (split-string expr ", " t))
                                      (remaining-text main-text))
                                  (dolist (ex expr-list)
                                    (let ((expr-pos (string-match (regexp-quote ex) remaining-text)))
                                      (when expr-pos
                                        (insert (propertize (substring remaining-text 0 expr-pos) 'face 'lexdb-definition-face))
                                        (insert (propertize ex 'face 'lexdb-grambox-expr-face))
                                        (setq remaining-text (substring remaining-text (+ expr-pos (length ex)))))))
                                  (insert (propertize remaining-text 'face 'lexdb-definition-face)))
                              (insert (propertize main-text 'face 'lexdb-definition-face)))
                            (insert "\n")))
                        ;; Multiple examples, each on new line
                        (dolist (ex ex-list)
                          (when (and ex (stringp ex) (not (string-empty-p ex)))
                            (insert "    " (propertize "· " 'face 'lexdb-definition-face)
                                    (propertize ex 'face 'lexdb-example-face) "\n")))
                        (when (and bad-example (not (string-empty-p bad-example)))
                          (insert "    " (propertize "✗ Don't say: " 'face 'lexdb-bad-example-face)
                                  (propertize bad-example 'face 'lexdb-bad-example-face) "\n")))
                       (text
                        (insert "  " (propertize text 'face 'lexdb-definition-face) "\n"))))))))
            (when (> (point) grambox-start)
              (let ((ov (make-overlay grambox-start (point))))
                (overlay-put ov 'face 'lexdb-grambox-background-face)
                (overlay-put ov 'lexdb-grambox t)))
            (insert "\n")))))))

(defun lexdb-ui--slot-idioms (entry adapter)
  "Slot: Render idioms section."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (adapter-id (lexdb-adapter-id adapter))
         (idioms (lexdb-meta-get (lexdb-entry-metadata entry) ns "idioms")))
    (when idioms
      (let ((idiom-list (cond ((vectorp idioms) (append idioms nil))
                              ((listp idioms) idioms)
                              (t nil))))
        (when idiom-list
          (insert "\n")
          (insert (propertize "IDM " 'face 'lexdb-label-face))
          (insert "\n")
          (dolist (idiom idiom-list)
            (let ((idiom-text (alist-get 'text idiom))
                  (idiom-def (alist-get 'definition idiom))
                  (idiom-def-zh (alist-get 'definition_zh idiom))
                  (idiom-examples (alist-get 'examples idiom))
                  (jump-adapter adapter-id))
              ;; Translation indicator at start of line
              (if (and idiom-def-zh (stringp idiom-def-zh) (not (string-empty-p idiom-def-zh))
                       lexdb-ui-translation-indicator)
                  (insert (propertize lexdb-ui-translation-indicator
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation idiom-def-zh
                                      'help-echo "Press t to peek translation")
                          " ")
                (insert "  "))
              ;; Idiom text
              (when idiom-text
                (insert (propertize idiom-text 'face 'lexdb-phrase-face)))
              ;; Definition - check for pre-parsed crossref first, then fallback to regex
              (when (and idiom-def (stringp idiom-def) (not (string-empty-p idiom-def)))
                (insert " ")
                (let ((crossref (alist-get 'crossref idiom)))
                  (if crossref
                      ;; Pre-parsed crossref from database (new format)
                      (let* ((prefix (alist-get 'prefix crossref))
                             (clickable (alist-get 'clickable crossref))
                             (target-word (alist-get 'target_word crossref))
                             (search-word (lexdb-ui--normalize-search-word
                                           (or target-word clickable))))
                        (when prefix
                          (insert (propertize prefix 'face 'lexdb-crossref-face)))
                        (insert-text-button clickable
                                            'face 'lexdb-crossref-face
                                            'action (lambda (_)
                                                      (lexdb-search-and-goto-sense
                                                       search-word nil jump-adapter))
                                            'help-echo (format "Look up: %s [%s]"
                                                               search-word jump-adapter)))
                    ;; Fallback: regex detection for legacy data (→word.)
                    (if (string-match "^→\\([^.]+\\)\\.$" idiom-def)
                        (let* ((raw-target (match-string 1 idiom-def))
                               (search-word (lexdb-ui--normalize-search-word raw-target)))
                          (insert (propertize "→" 'face 'lexdb-crossref-face))
                          (insert-text-button raw-target
                                              'face 'lexdb-crossref-face
                                              'action (lambda (_)
                                                        (lexdb-search-and-goto-sense
                                                         search-word nil jump-adapter))
                                              'help-echo (format "Look up: %s [%s]" search-word jump-adapter)))
                      ;; Regular definition
                      (insert (propertize idiom-def 'face 'lexdb-definition-face))))))
              (insert "\n")
              (when idiom-examples
                (let ((ex-list (cond ((vectorp idiom-examples) (append idiom-examples nil))
                                     ((listp idiom-examples) idiom-examples)
                                     (t nil))))
                  (dolist (ex ex-list)
                    (let ((ex-text (alist-get 'text ex))
                          (ex-zh (alist-get 'text_zh ex)))
                      (when (and ex-text (stringp ex-text) (not (string-empty-p ex-text)))
                        ;; Indicator for idiom example translation
                        (if (and ex-zh (stringp ex-zh) (not (string-empty-p ex-zh))
                                 lexdb-ui-translation-indicator)
                            (insert "  " (propertize lexdb-ui-translation-indicator
                                                     'face 'lexdb-translation-indicator-face
                                                     'lexdb-translation ex-zh
                                                     'help-echo "Press t to peek translation")
                                    " ")
                          (insert "    "))
                        (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                        (insert "\n")))))))))))))

(defun lexdb-ui--slot-phrasal-verbs (entry adapter)
  "Slot: Render phrasal verbs."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (phrasal-verbs (lexdb-meta-get (lexdb-entry-metadata entry) ns "phrasal-verbs")))
    (when (and phrasal-verbs (> (length phrasal-verbs) 0))
      (lexdb-ui--render-phrasal-verbs phrasal-verbs))))

(defun lexdb-ui--slot-synonyms (entry adapter)
  "Slot: Render synonyms and cross-references."
  (lexdb-ui--render-synonyms-and-crossrefs entry adapter))

(defun lexdb-ui--slot-separator (_entry _adapter)
  "Slot: Render entry separator line."
  (insert (propertize (make-string 60 ?─) 'face 'lexdb-separator-face))
  (insert "\n\n"))

;;;; ============================================================
;;;; Slot-based Entry Rendering
;;;; ============================================================

(defun lexdb-ui-render-entry (entry adapter)
  "Render ENTRY using ADAPTER with slot-based system.
Slots are rendered according to `lexdb-ui-default-template' or
adapter-specific template from `lexdb-ui-adapter-templates'."
  (let ((template (lexdb-ui--get-template adapter)))
    (dolist (slot-name template)
      (when (lexdb-ui--slot-enabled-p slot-name)
        (when-let ((slot-fn (cdr (assq slot-name lexdb-ui-slot-functions))))
          (funcall slot-fn entry adapter))))))

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
;;;; Translation Peek
;;;; ============================================================

(defun lexdb-ui--clear-translation-overlay ()
  "Clear the translation peek overlay."
  (when lexdb-ui--translation-overlay
    (delete-overlay lexdb-ui--translation-overlay)
    (setq lexdb-ui--translation-overlay nil))
  (remove-hook 'pre-command-hook #'lexdb-ui--clear-translation-overlay t))

(defun lexdb-ui--find-translation-at-point ()
  "Find translation text at or near point.
Search current line for `lexdb-translation' text property."
  (save-excursion
    (let ((line-start (line-beginning-position))
          (line-end (line-end-position))
          (result nil))
      ;; Search from line start to find any translation property
      (goto-char line-start)
      (while (and (< (point) line-end) (not result))
        (let ((translation (get-text-property (point) 'lexdb-translation)))
          (if translation
              (setq result (cons (point) translation))
            (goto-char (or (next-single-property-change (point) 'lexdb-translation nil line-end)
                           line-end)))))
      result)))

(defun lexdb-ui-peek-translation ()
  "Temporarily show translation for the current line.
The translation disappears on the next command."
  (interactive)
  ;; Clear any existing overlay first
  (lexdb-ui--clear-translation-overlay)
  ;; Find translation at current line
  (let ((found (lexdb-ui--find-translation-at-point)))
    (if found
        (let* ((pos (car found))
               (translation (cdr found))
               (ov (make-overlay (line-end-position) (line-end-position))))
          (overlay-put ov 'after-string
                       (propertize (concat "\n    " translation)
                                   'face 'lexdb-translation-peek-face))
          (setq lexdb-ui--translation-overlay ov)
          ;; Register hook to clear on next command
          (add-hook 'pre-command-hook #'lexdb-ui--clear-translation-overlay nil t))
      (message "No translation available on this line"))))

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
    ;; Translation peek
    (define-key map "t" #'lexdb-ui-peek-translation)
    ;; History navigation
    (define-key map "l" #'lexdb-history-back)      ; back (like browser)
    (define-key map "r" #'lexdb-history-forward)   ; forward
    (define-key map "[" #'lexdb-history-back)      ; alternative
    (define-key map "]" #'lexdb-history-forward)   ; alternative
    ;; Dictionary switching (multi-dict mode)
    (define-key map "d" #'lexdb-ui-switch-dict)    ; prompt for dict
    (define-key map ">" #'lexdb-ui-next-dict)      ; next dict
    (define-key map "<" #'lexdb-ui-prev-dict)      ; prev dict
    (define-key map (kbd "M-1") (lambda () (interactive) (lexdb-ui-switch-dict-by-number 1)))
    (define-key map (kbd "M-2") (lambda () (interactive) (lexdb-ui-switch-dict-by-number 2)))
    (define-key map (kbd "M-3") (lambda () (interactive) (lexdb-ui-switch-dict-by-number 3)))
    (define-key map (kbd "M-4") (lambda () (interactive) (lexdb-ui-switch-dict-by-number 4)))
    (define-key map (kbd "M-5") (lambda () (interactive) (lexdb-ui-switch-dict-by-number 5)))
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

Dictionary switching (multi-dict mode):
  d       - Switch dictionary (prompt)
  >/<     - Next/previous dictionary
  M-1..5  - Switch to dictionary 1-5

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

(defun lexdb-ui--get-multi-buffer ()
  "Get or create buffer for multi-dictionary display."
  (get-buffer-create "*Lexdb*"))

(defun lexdb-ui-display-multi (word)
  "Display WORD in all enabled dictionaries with tab switching."
  (let* ((results (lexdb-ui--query-all-dicts word))
         (buf (lexdb-ui--get-multi-buffer))
         ;; Find first dict with results, or just first dict
         (first-with-results (or (cl-find-if (lambda (item) (cadr item)) results)
                                 (car results)))
         (initial-dict (car first-with-results)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (lexdb-mode)
        ;; Store state
        (setq lexdb-ui--dict-results results)
        (setq lexdb-ui--current-word word)
        (setq lexdb-ui--active-dict initial-dict)
        ;; Set up header line for tabs
        (when (eq lexdb-dict-tab-position 'header)
          (setq header-line-format '(:eval (lexdb-ui--render-dict-tabs))))
        ;; Render initial content
        (lexdb-ui--refresh-display)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

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
                (let ((lemma (funcall lemma-fn word))
                      (jump-adapter (lexdb-adapter-id adapter)))
                  (unless (equal lemma (downcase word))
                    (insert "\n\n")
                    (insert (propertize (format "Did you mean: %s?" lemma)
                                        'face 'lexdb-crossref-face))
                    (insert "\n")
                    (insert-text-button (format "[Look up '%s']" lemma)
                                        'face 'lexdb-button-face
                                        'action (lambda (_)
                                                  (lexdb-search-and-goto-sense lemma nil jump-adapter)))))))))
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
