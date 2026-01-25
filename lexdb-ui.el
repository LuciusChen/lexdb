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
    (usage           . lexdb-ui--slot-usage)
    (phrasal-verbs   . lexdb-ui--slot-phrasal-verbs)
    (synonyms        . lexdb-ui--slot-synonyms)
    (runons          . lexdb-ui--slot-runons)
    (ode-phrases-origin . lexdb-ui--slot-ode-phrases-origin)
    (separator       . lexdb-ui--slot-separator))
  "Alist mapping slot names to rendering functions.
Each function takes (entry adapter) and renders content at point.")

(defcustom lexdb-ui-default-template
  '(header tabs senses entry-grammar-box idioms usage phrasal-verbs synonyms runons ode-phrases-origin separator)
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

(defun lexdb-ui--lookup-with-lemma (word adapter-id adapter)
  "Lookup WORD in ADAPTER-ID, trying lemmatization if no results.
ADAPTER is the adapter struct.  Returns entries list or nil."
  (or (condition-case nil (lexdb-lookup word adapter-id) (error nil))
      (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
        (when-let* ((lemma (lexdb-find-lemma word adapter-id))
                    ((not (equal lemma (downcase word)))))
          (condition-case nil (lexdb-lookup lemma adapter-id) (error nil))))))

(defun lexdb-ui--query-all-dicts (word)
  "Query WORD in all enabled dictionaries.
Returns alist of (adapter-id . (entries . adapter))."
  (let ((results nil))
    (dolist (adapter-id (lexdb-ui--get-enabled-adapters))
      (when-let* ((adapter (lexdb-get-adapter adapter-id)))
        (push (cons adapter-id
                    (cons (lexdb-ui--lookup-with-lemma word adapter-id adapter)
                          adapter))
              results)))
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
          (when-let* ((lemma-fn (lexdb-adapter-lemma-fn adapter)))
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

(defface lexdb-variant-face
  '((((background dark))  :foreground "#A0A0A0" :slant italic)
    (((background light)) :foreground "#555555" :slant italic))
  "Face for variant spellings (e.g., 'also hi-vis')."
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

;; Links and clickable elements
(defface lexdb-link-face
  '((((background dark))  :foreground "#7CB8FF" :underline t)
    (((background light)) :foreground "#0066CC" :underline t))
  "Face for general clickable links (synonyms, cross-references, etc.).
This is the base face for all clickable text that jumps to another entry."
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

;; Relations - cross references are clickable links
(defface lexdb-crossref-face
  '((((background dark))  :foreground "#7CB8FF" :underline t)
    (((background light)) :foreground "#0066CC" :underline t))
  "Face for cross references (clickable links to other entries).
Uses link-like styling for visual consistency with other clickable elements."
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

(defface lexdb-synonym-descriptive-face
  '((((background dark))  :foreground "#B8B8B8" :weight bold)
    (((background light)) :foreground "#555555" :weight bold))
  "Face for non-clickable descriptive synonyms (e.g., 'twenty-four-hour period').
These are typically more general descriptions rather than dictionary entries."
  :group 'lexdb)

;; Definition inline formatting (for OALD variant words, register labels, etc.)
(defface lexdb-def-variant-face
  '((((background dark))  :foreground "#7CB8FF" :weight bold)
    (((background light)) :foreground "#0066CC" :weight bold))
  "Face for variant words in definitions (e.g., maths, math)."
  :group 'lexdb)

(defface lexdb-def-register-face
  '((((background dark))  :foreground "#E0A040")
    (((background light)) :foreground "#996600"))
  "Face for register labels in definitions (e.g., Brit, US, infml)."
  :group 'lexdb)

(defface lexdb-def-pronunciation-face
  '((((background dark))  :foreground "#A0A0A0")
    (((background light)) :foreground "#666666"))
  "Face for pronunciations in definitions."
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

(defface lexdb-origin-date-face
  '((((background dark))  :foreground "#87CEEB")
    (((background light)) :foreground "#4169E1"))
  "Face for date/era in word origin (e.g., 'Early 17th century')."
  :group 'lexdb)

(defface lexdb-origin-etym-face
  '((((background dark))  :foreground "#DDA0DD" :slant italic)
    (((background light)) :foreground "#8B008B" :slant italic))
  "Face for etymological words in origin (e.g., 'indicat-', 'indicare')."
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
;;;; Common Utility Functions
;;;; ============================================================

(defun lexdb-ui--ensure-list (val)
  "Convert VAL to a list if it's a vector, or return as-is if list, else nil."
  (cond ((vectorp val) (append val nil))
        ((listp val) val)
        (t nil)))

(defun lexdb-ui--valid-string-p (str)
  "Return non-nil if STR is a non-empty string."
  (and str (stringp str) (not (string-empty-p str))))

(defun lexdb-ui--insert-translation-indicator (translation &optional prefix)
  "Insert translation indicator with TRANSLATION as hover text.
Optional PREFIX is inserted before the indicator (e.g., \"  \" for indentation).
Returns t if indicator was inserted, nil otherwise."
  (when (and (lexdb-ui--valid-string-p translation)
             lexdb-ui-translation-indicator)
    (when prefix (insert prefix))
    (insert (propertize lexdb-ui-translation-indicator
                        'face 'lexdb-translation-indicator-face
                        'lexdb-translation translation
                        'help-echo "Press t to peek translation")
            " ")
    t))

(defun lexdb-ui--render-idiom-example (ex &optional indent)
  "Render idiom example EX with optional INDENT prefix.
EX should be an alist with 'text, 'text_zh, and optionally 'label keys."
  (let ((ex-text (alist-get 'text ex))
        (ex-zh (alist-get 'text_zh ex))
        (ex-label (alist-get 'label ex))
        (indent-str (or indent "    ")))
    (when (lexdb-ui--valid-string-p ex-text)
      ;; Translation indicator or plain indent
      (unless (lexdb-ui--insert-translation-indicator ex-zh "  ")
        (insert indent-str))
      ;; Register label (joc, fig, etc.)
      (when (lexdb-ui--valid-string-p ex-label)
        (insert (propertize ex-label 'face 'lexdb-grammar-face) " "))
      (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
      (insert "\n"))))

;;;; ============================================================
;;;; Definition Format Rendering
;;;; ============================================================

(defun lexdb-ui--insert-formatted-definition (text default-face)
  "Insert definition TEXT with format markers, using DEFAULT-FACE for plain text.
Format markers:
  <<l>>...<</l>>     - variant words (blue bold)
  <<reg>>...<</reg>> - register labels (same as grammar codes)
  <<gram>>...<</gram>> - grammar labels (same as grammar codes)
  <<pr>>...<</pr>>   - pronunciations (same as entry pronunciation)
  <<pos>>...<</pos>> - part of speech references (hot pink)
  <<ex>>...<</ex>>   - example words in text (highlighted like examples)"
  (when (and text (not (string-empty-p text)))
    (let ((start 0))
      (while (string-match "<<\\(l\\|reg\\|gram\\|pr\\|pos\\|ex\\)>>\\([^<]*\\)<</\\1>>" text start)
        (let ((before-match (substring text start (match-beginning 0)))
              (marker-type (match-string 1 text))
              (content (match-string 2 text)))
          ;; Insert text before marker with default face
          (when (> (length before-match) 0)
            (insert (propertize before-match 'face default-face)))
          ;; Insert marked content with appropriate face
          (insert (propertize content 'face
                              (pcase marker-type
                                ("l" 'lexdb-def-variant-face)
                                ("reg" 'lexdb-grammar-face)
                                ("gram" 'lexdb-grammar-face)
                                ("pr" 'lexdb-phonetic-face)
                                ("pos" 'lexdb-pos-face)
                                ("ex" 'lexdb-example-highlight-face)
                                (_ default-face))))
          (setq start (match-end 0))))
      ;; Insert remaining text
      (when (< start (length text))
        (insert (propertize (substring text start) 'face default-face))))))

(defun lexdb-ui--insert-formatted-origin (text &optional adapter-id)
  "Insert origin TEXT with format markers for ODE etymology.
Format markers:
  <<date>>...<</date>> - date/era (e.g., 'Early 17th century')
  <<etym>>...<</etym>> - etymological words (e.g., 'indicat-', 'indicare')
  <<link:TARGET>>...<</link>> - cross-reference links (e.g., 'Latin')
If ADAPTER-ID is provided, links will jump within the same dictionary."
  (when (and text (not (string-empty-p text)))
    (let ((start 0)
          ;; Regex matches: date/etym markers OR link markers
          (marker-regex "<<\\(date\\|etym\\)>>\\([^<]*\\)<</\\1>>\\|<<link:\\([^>]+\\)>>\\([^<]*\\)<</link>>"))
      (while (string-match marker-regex text start)
        (let ((before-match (substring text start (match-beginning 0))))
          ;; Insert text before marker with default origin face
          (when (> (length before-match) 0)
            (insert (propertize before-match 'face 'lexdb-origin-face)))
          ;; Check which type of marker matched
          (if (match-string 1 text)
              ;; date/etym marker
              (let ((marker-type (match-string 1 text))
                    (content (match-string 2 text)))
                (insert (propertize content 'face
                                    (pcase marker-type
                                      ("date" 'lexdb-origin-date-face)
                                      ("etym" 'lexdb-origin-etym-face)
                                      (_ 'lexdb-origin-face)))))
            ;; link marker
            (let ((target (match-string 3 text))
                  (content (match-string 4 text))
                  (jump-adapter adapter-id))
              (insert-text-button content
                                  'face 'lexdb-crossref-face
                                  'action (lambda (_)
                                            (lexdb-search-and-goto-sense
                                             (downcase target) nil jump-adapter))
                                  'help-echo (format "Look up: %s%s"
                                                     target
                                                     (if jump-adapter
                                                         (format " [%s]" jump-adapter)
                                                       "")))))
          (setq start (match-end 0))))
      ;; Insert remaining text
      (when (< start (length text))
        (insert (propertize (substring text start) 'face 'lexdb-origin-face))))))

;;;; ============================================================
;;;; Audio Playback
;;;; ============================================================

(defcustom lexdb-audio-online-base-url "https://www.ldoceonline.com/media/english/"
  "Base URL for online audio files from LDOCE."
  :type 'string
  :group 'lexdb)

(defcustom lexdb-audio-ode-base-url "https://s3.amazonaws.com/audio.oxforddictionaries.com"
  "Base URL for online audio files from ODE."
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
- LDOCE: hwd/bre/* -> breProns, hwd/ame/* -> ameProns, exa/* -> exaProns
- ODE: /en/mp3/* -> direct path append"
  (when path
    (let ((filename (file-name-nondirectory path)))
      (cond
       ;; LDOCE paths
       ((string-match-p "^hwd/bre/" path)
        (concat lexdb-audio-online-base-url "breProns/" filename))
       ((string-match-p "^hwd/ame/" path)
        (concat lexdb-audio-online-base-url "ameProns/" filename))
       ((string-match-p "^exa/" path)
        (concat lexdb-audio-online-base-url "exaProns/" filename))
       ;; ODE paths (e.g., /en/mp3/home_gb_1.mp3)
       ((string-match-p "^/en/mp3/" path)
        (concat lexdb-audio-ode-base-url path))
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
             ;; Optional 4th element: background face for special sections
             (bg-face (nth 3 tab))
             (start (point)))
        (insert content)
        (unless (eq (char-before) ?\n) (insert "\n"))
        (let ((content-ov (make-overlay start (point))))
          (overlay-put content-ov 'lexdb-tab-group tab-group)
          (overlay-put content-ov 'lexdb-tab-id tab-id)
          (overlay-put content-ov 'lexdb-tab-content t)  ; Mark as tab content
          (overlay-put content-ov 'invisible t)
          (overlay-put content-ov 'evaporate t)
          ;; Apply optional background face for special tabs like Phrases/Origin
          (when bg-face
            (overlay-put content-ov 'face bg-face)))))
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
Removes superscript numbers, regular numbers, and spaces.
E.g., 'end¹' -> 'end', 'better³ 3' -> 'better'."
  (when str
    ;; Remove all superscript numbers (anywhere in string)
    (let ((result (replace-regexp-in-string "[⁰¹²³⁴⁵⁶⁷⁸⁹]+" "" str)))
      ;; Remove all regular numbers
      (setq result (replace-regexp-in-string "[0-9]+" "" result))
      ;; Remove spaces
      (setq result (replace-regexp-in-string "\\s-+" "" result))
      ;; Lowercase and trim
      (downcase (string-trim result)))))

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
      (when-let* ((ipa (lexdb-pronunciation-ipa pron)))
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
      (when-let* ((dots (lexdb-meta-get meta ns "frequency-dots")))
        (when (lexdb--non-empty-string-p dots)
          (insert " " (propertize dots 'face 'lexdb-frequency-dots-face)))))
    ;; Frequency level (S1 W2 etc) - use adapter hook if provided
    (when (memq 'frequency-band caps)
      (when-let* ((freq (lexdb-meta-get meta ns "frequency")))
        (when (lexdb--non-empty-string-p freq)
          (if-let* ((hook (lexdb-adapter-render-frequency-fn adapter)))
              (when-let* ((rendered (funcall hook freq)))
                (insert " " rendered))
            (insert " " (propertize freq 'face 'lexdb-frequency-face))))))
    ;; CEFR level
    (when (memq 'cefr caps)
      (when-let* ((cefr (lexdb-meta-get meta ns "cefr-level")))
        (when (lexdb--non-empty-string-p cefr)
          (insert " " (propertize (format "[%s]" cefr) 'face 'lexdb-cefr-face)))))))

(defun lexdb-ui--render-pos (entry adapter)
  "Render part of speech for ENTRY."
  (when (lexdb-adapter-has-capability-p adapter 'pos)
    (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
           (pos (lexdb-meta-get (lexdb-entry-metadata entry) ns "pos")))
      (when (lexdb--non-empty-string-p pos)
        (insert " " (propertize pos 'face 'lexdb-pos-face))
        ;; ODE: Add transitivity after POS (e.g., "[with object]")
        (when (eq (lexdb-adapter-id adapter) 'ode)
          (let* ((transitivity-map (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_transitivity"))
                 ;; Get transitivity for first sense (sort_order = 0)
                 (transitivity (when transitivity-map
                                 (cdr (assoc "0" transitivity-map #'string=)))))
            (when (lexdb--non-empty-string-p transitivity)
              (insert " " (propertize (upcase transitivity) 'face 'lexdb-grammar-face)))))))))

(defun lexdb-ui--render-audio-buttons (entry adapter)
  "Render audio indicators for ENTRY. Use C-c C-c to play.
Supports both local audio (with audio-dir) and online audio (path only)."
  (let* ((caps (lexdb-adapter-capabilities adapter))
         (audio-dir (lexdb-adapter-audio-dir adapter))
         (ns (symbol-name (lexdb-adapter-id adapter)))
         (meta (lexdb-entry-metadata entry))
         (has-audio nil))
    ;; UK audio - render if path exists (audio-dir can be nil for online)
    (when (memq 'audio-uk caps)
      (when-let* ((path (lexdb-meta-get meta ns "audio-uk")))
        (when (lexdb--non-empty-string-p path)
          (setq has-audio t)
          (insert (propertize "🔊 UK"
                              'face 'lexdb-audio-indicator-face
                              'lexdb-audio-path path
                              'lexdb-audio-dir audio-dir
                              'help-echo "C-c C-c to play UK pronunciation")))))
    ;; US audio
    (when (memq 'audio-us caps)
      (when-let* ((path (lexdb-meta-get meta ns "audio-us")))
        (when (lexdb--non-empty-string-p path)
          (when has-audio (insert "  "))
          (setq has-audio t)
          (insert (propertize "🔊 US"
                              'face 'lexdb-audio-indicator-face
                              'lexdb-audio-path path
                              'lexdb-audio-dir audio-dir
                              'help-echo "C-c C-c to play US pronunciation")))))
    (when has-audio (insert "\n"))))

(defun lexdb-ui--render-inflections (entry adapter)
  "Render inflections (past tense, plural, comparative/superlative, etc.) for ENTRY."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (adapter-id (lexdb-adapter-id adapter))
         (meta (lexdb-entry-metadata entry))
         (infl-text (lexdb-meta-get meta ns "inflections"))
         (relations (lexdb-entry-relations entry))
         (inflections (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'inflection)) relations)))
    ;; Display full inflection text if available (may contain format markers)
    (when (lexdb--non-empty-string-p infl-text)
      (insert " ")
      ;; Check if text contains format markers
      (if (string-match-p "<<[a-z]+>>" infl-text)
          ;; Use formatted definition renderer for markers like <<l>>, <<pr>>
          (lexdb-ui--insert-formatted-definition infl-text 'lexdb-inflection-face)
        ;; Legacy: make inflection words clickable within the text
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
            (insert (propertize (substring text start) 'face 'lexdb-inflection-face))))))))

;;;; ============================================================
;;;; Sense Rendering Helper Functions
;;;; ============================================================

(defun lexdb-ui--render-sense-subsenses (sense adapter entry caps audio-dir ns)
  "Render subsenses for SENSE using ADAPTER.
ENTRY, CAPS, AUDIO-DIR, NS are passed from the parent context."
  (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
    (when subsenses
      (let ((sub-list (if (vectorp subsenses) (append subsenses nil) subsenses)))
        (dolist (sub sub-list)
          ;; JSON parsing returns symbol keys, not string keys
          (let ((sub-num (cdr (assoc 'number sub)))
                (sub-def (cdr (assoc 'definition sub)))
                (sub-def-zh (cdr (assoc 'definition_zh sub)))
                (sub-grammar (cdr (assoc 'grammar sub)))
                (sub-labels (cdr (assoc 'labels sub)))
                (sub-examples (cdr (assoc 'examples sub)))
                (sub-expanded-examples (cdr (assoc 'expanded_examples sub)))
                (sub-synonyms (cdr (assoc 'synonyms sub)))
                (sub-index (cdr (assoc 'sort_order sub))))
            ;; Subsense number
            (insert "  ")
            (when sub-num
              (insert (propertize sub-num 'face 'lexdb-sense-num-face) " "))
            ;; Translation indicator - after subsense number
            (when (and (memq 'chinese-definition caps)
                       (lexdb--non-empty-string-p sub-def-zh)
                       lexdb-ui-translation-indicator)
              (insert (propertize lexdb-ui-translation-indicator
                                  'face 'lexdb-translation-indicator-face
                                  'lexdb-translation sub-def-zh
                                  'help-echo "Press t to peek translation")
                      " "))
            ;; Grammar (e.g., [attrib], [pred])
            (when sub-grammar
              (let ((gram-list (cond ((vectorp sub-grammar) (append sub-grammar nil))
                                     ((listp sub-grammar) sub-grammar)
                                     ((stringp sub-grammar) (list sub-grammar))
                                     (t nil))))
                (dolist (gram gram-list)
                  (when (and gram (not (string-empty-p gram)))
                    (insert (propertize (if (string-match-p "^\\[" gram) gram (format "[%s]" gram))
                                        'face 'lexdb-grammar-face) " ")))))
            ;; Labels (register, etc.)
            (when sub-labels
              (let ((labels-list (if (vectorp sub-labels) (append sub-labels nil) sub-labels)))
                (dolist (label labels-list)
                  (let ((lvalue (cdr (assoc 'value label))))
                    (when lvalue
                      (insert (propertize lvalue 'face 'lexdb-register-face) " "))))))
            ;; Definition
            (when sub-def
              (lexdb-ui--insert-formatted-definition sub-def 'lexdb-definition-face))
            (insert "\n")
            ;; Examples
            (when sub-examples
              (let ((ex-list (if (vectorp sub-examples) (append sub-examples nil) sub-examples)))
                (dolist (ex ex-list)
                  (let ((ex-text (cdr (assoc 'text ex)))
                        (ex-zh (cdr (assoc 'text_zh ex)))
                        (ex-audio (cdr (assoc 'audio_path ex))))
                    (when (and ex-text (not (string-empty-p ex-text)))
                      (let ((has-audio (and ex-audio (not (string-empty-p ex-audio))))
                            (has-translation (and (memq 'chinese-example caps)
                                                  ex-zh (not (string-empty-p ex-zh))
                                                  lexdb-ui-translation-indicator)))
                        (cond
                         ((and has-audio has-translation)
                          (insert (propertize "      🔊"
                                              'face 'lexdb-audio-indicator-face
                                              'lexdb-audio-path ex-audio
                                              'lexdb-audio-dir audio-dir
                                              'help-echo "C-c C-c to play"))
                          (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                              'face 'lexdb-translation-indicator-face
                                              'lexdb-translation ex-zh
                                              'help-echo "Press t to peek translation")))
                         (has-audio
                          (insert (propertize "      🔊 "
                                              'face 'lexdb-audio-indicator-face
                                              'lexdb-audio-path ex-audio
                                              'lexdb-audio-dir audio-dir
                                              'help-echo "C-c C-c to play")))
                         (has-translation
                          (insert "      ")
                          (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                              'face 'lexdb-translation-indicator-face
                                              'lexdb-translation ex-zh
                                              'help-echo "Press t to peek translation")))
                         (t
                          (insert "      "))))
                      (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                      (insert "\n"))))))
            ;; Subsense tabs: expanded examples and synonyms
            (let ((sub-tabs nil))
              ;; Build expanded examples tab
              (when sub-expanded-examples
                (let ((ex-list (if (vectorp sub-expanded-examples)
                                   (append sub-expanded-examples nil)
                                 sub-expanded-examples)))
                  (push (list 'more-examples (format "Example sentences (%d)" (length ex-list))
                              (with-temp-buffer
                                (dolist (ex ex-list)
                                  (insert "      " (propertize "• " 'face 'lexdb-definition-face))
                                  (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                                  (insert "\n"))
                                (buffer-string)))
                        sub-tabs)))
              ;; Build synonyms tab
              (when sub-synonyms
                (let ((syn-list (if (vectorp sub-synonyms) (append sub-synonyms nil) sub-synonyms)))
                  (push (list 'synonyms "SYNONYMS"
                              (with-temp-buffer
                                (dolist (group syn-list)
                                  (let ((register (cdr (assoc 'register group)))
                                        (words (cdr (assoc 'words group))))
                                    (when words
                                      (insert "      ")
                                      (when (and register (not (string-empty-p register)))
                                        (insert (propertize register 'face 'lexdb-register-face) " "))
                                      (let ((word-list (if (vectorp words) (append words nil) words))
                                            (first t))
                                        (dolist (word-obj word-list)
                                          (unless first (insert ", "))
                                          (setq first nil)
                                          (let* ((word-text (if (stringp word-obj)
                                                                word-obj
                                                              (cdr (assoc 'word word-obj))))
                                                 (clickable (if (stringp word-obj)
                                                                t
                                                              (eq (cdr (assoc 'clickable word-obj)) t))))
                                            (if clickable
                                                (insert-text-button word-text
                                                                    'face 'lexdb-link-face
                                                                    'action (lambda (_)
                                                                              (lexdb-search-and-goto-sense word-text nil 'ode))
                                                                    'help-echo (format "Look up: %s [ode]" word-text))
                                              (insert (propertize word-text 'face 'default))))))
                                      (insert "\n"))))
                                (buffer-string)))
                        sub-tabs)))
              ;; Insert tab bar aligned with subsense examples (6 spaces)
              (when sub-tabs
                (insert "      ")
                (let ((tab-group (format "lexdb-ode-subsense-%d-%s"
                                         (lexdb-entry-id entry)
                                         (or sub-index sub-num "0"))))
                  (lexdb-ui--insert-tab-bar (nreverse sub-tabs) tab-group))))))))))

(defun lexdb-ui--render-sense-examples (sense adapter caps audio-dir ns position is-subsense)
  "Render examples for SENSE at given POSITION (0=before, 1=after grammar patterns).
ADAPTER, CAPS, AUDIO-DIR, NS, IS-SUBSENSE are from parent context."
  (let ((subsenses (lexdb-meta-get (lexdb-sense-metadata sense) ns "subsenses")))
    (unless subsenses
      (when (memq 'examples caps)
        (dolist (ex (lexdb-sense-examples sense))
          (let* ((ex-text (lexdb-example-text ex))
                 (audio-path (lexdb-example-audio ex))
                 (ex-position (or (cdr (assoc 'position (lexdb-example-metadata ex))) 0))
                 (ex-zh (when (memq 'chinese-example caps)
                          (lexdb-meta-get (lexdb-example-metadata ex) ns "text-zh")))
                 (has-audio (and (memq 'audio-example caps) audio-path (lexdb--non-empty-string-p audio-path)))
                 (has-translation (and ex-zh (lexdb--non-empty-string-p ex-zh) lexdb-ui-translation-indicator)))
            (when (and (lexdb--non-empty-string-p ex-text) (= ex-position position))
              ;; ODE: 2-space for main senses, 4-space for subsenses
              (let ((indent (cond
                             ((and (eq (lexdb-adapter-id adapter) 'ode) is-subsense) "    ")
                             ((eq (lexdb-adapter-id adapter) 'ode) "  ")
                             (t "    "))))
                (cond
                 ((and has-audio has-translation)
                  (insert (propertize (concat (substring indent 0 (- (length indent) 1)) "🔊")
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play"))
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (has-audio
                  (insert (propertize (concat indent "🔊 ")
                                      'face 'lexdb-audio-indicator-face
                                      'lexdb-audio-path audio-path
                                      'lexdb-audio-dir audio-dir
                                      'help-echo "C-c C-c to play")))
                 (has-translation
                  (insert indent)
                  (insert (propertize (concat lexdb-ui-translation-indicator " ")
                                      'face 'lexdb-translation-indicator-face
                                      'lexdb-translation ex-zh
                                      'help-echo "Press t to peek translation")))
                 (t
                  (insert indent))))
              (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
              (insert "\n"))))))))

(defun lexdb-ui--render-sense-grammar-patterns (sense adapter audio-dir)
  "Render grammar patterns for SENSE using ADAPTER.
AUDIO-DIR is used for audio playback."
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
                  (insert "\n"))))))))))

(defun lexdb-ui--render-sense-lexunits (entry sense adapter audio-dir ns sense-num-str)
  "Render lexunits for SENSE in ENTRY.
ADAPTER, AUDIO-DIR, NS, SENSE-NUM-STR are from parent context."
  (when entry
    (let* ((sense-lexunits (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_lexunits"))
           (lexunits (when sense-lexunits
                       (cdr (assoc sense-num-str sense-lexunits #'string=))))
           (sense-def (or (lexdb-sense-definition sense) "")))
      (when lexunits
        (let ((lu-list (if (vectorp lexunits) (append lexunits nil) lexunits)))
          (dolist (lu lu-list)
            (let ((lu-text (cdr (assoc 'text lu)))
                  (lu-def (cdr (assoc 'definition lu)))
                  (lu-examples (cdr (assoc 'examples lu))))
              ;; Skip if lexunit text is already part of the definition
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
                          (insert "\n"))))))))))))))

(defun lexdb-ui--render-sense-crossrefs (sense adapter)
  "Render sense-level cross references for SENSE using ADAPTER."
  (let ((sense-relations (lexdb-sense-relations sense))
        (adapter-id (lexdb-adapter-id adapter)))
    (when sense-relations
      (let ((cross-refs (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'cross_ref)) sense-relations)))
        (when cross-refs
          (insert "    ")  ; 4 spaces to align with examples and labels
          (let ((first t))
            (dolist (ref cross-refs)
              (unless first (insert ", "))
              (setq first nil)
              (let* ((prefix (lexdb-relation-prefix ref))
                     (clickable (lexdb-relation-clickable ref))
                     (suffix (lexdb-relation-suffix ref))
                     (target-word (lexdb-relation-target-word ref))
                     (target-sense (lexdb-relation-target-sense ref))
                     (target (lexdb-relation-target ref))
                     (jump-adapter adapter-id))
                (if clickable
                    ;; New fragment format
                    (let* ((search-word (lexdb-ui--normalize-search-word
                                         (or target-word clickable)))
                           (display-clickable (lexdb-ui--number-to-superscript clickable)))
                      (when (and prefix (not (string-empty-p prefix)))
                        (insert (propertize prefix 'face 'lexdb-definition-face)))
                      (insert-text-button display-clickable
                                          'face 'lexdb-crossref-face
                                          'action (lambda (_)
                                                    (lexdb-search-and-goto-sense
                                                     search-word target-sense jump-adapter))
                                          'help-echo (format "Look up: %s%s [%s]"
                                                             search-word
                                                             (if target-sense (format " sense %s" target-sense) "")
                                                             jump-adapter))
                      (when (and suffix (not (string-empty-p suffix)))
                        (insert (propertize suffix 'face 'lexdb-definition-face))))
                  ;; Legacy format
                  (when target
                    (insert (propertize "→ " 'face 'lexdb-crossref-face))
                    (insert-text-button target
                                        'face 'lexdb-crossref-face
                                        'action (lambda (_)
                                                  (lexdb-search-and-goto-sense target nil jump-adapter))
                                        'help-echo (format "Look up: %s [%s]" target jump-adapter)))))))
          (insert "\n"))))))

(defun lexdb-ui--render-sense-grammar-box (entry ns sense-num-str)
  "Render grammar box for sense SENSE-NUM-STR in ENTRY.
NS is the adapter namespace."
  (when entry
    (let* ((sense-gramboxes (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_grammar_boxes"))
           (grambox (when sense-gramboxes
                      (cdr (assoc sense-num-str sense-gramboxes #'string=)))))
      (when grambox
        (let ((heading (cdr (assoc 'heading grambox)))
              (notes (cdr (assoc 'notes grambox)))
              (grambox-start (point)))
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
                      (bad-example (cdr (assoc 'bad_example note)))
                      (text (cdr (assoc 'text note))))
                  (let* ((main-text (if (and text (string-match "\\(.*?\\)\\(·\\|✗\\)" text))
                                        (string-trim (match-string 1 text))
                                      text)))
                    (insert "  ")
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
                    ;; Good examples
                    (let ((ex-list (cond
                                    ((and examples (listp examples)) examples)
                                    ((vectorp examples) (append examples nil))
                                    ((and example (not (string-empty-p example))) (list example))
                                    (t nil))))
                      (dolist (ex ex-list)
                        (when (and ex (not (string-empty-p ex)))
                          (insert "    " (propertize "· " 'face 'lexdb-definition-face)
                                  (propertize ex 'face 'lexdb-example-face) "\n"))))
                    ;; Bad example
                    (when (and bad-example (not (string-empty-p bad-example)))
                      (insert "    " (propertize "✗ Don't say: " 'face 'lexdb-bad-example-face)
                              (propertize bad-example 'face 'lexdb-bad-example-face) "\n")))))))
          ;; Create overlay for background
          (let ((ov (make-overlay grambox-start (point))))
            (overlay-put ov 'face 'lexdb-grambox-background-face)
            (overlay-put ov 'lexdb-grambox t))
          (insert "\n"))))))

(defun lexdb-ui--render-sense-register-box (entry ns sense-num-str)
  "Render register box for sense SENSE-NUM-STR in ENTRY.
NS is the adapter namespace."
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
          (insert "\n"))))))

(defun lexdb-ui--render-sense-ode-tabs (entry adapter sense sense-index)
  "Render ODE sense-level tabs (SYNONYMS, Example sentences).
ENTRY, ADAPTER, SENSE, SENSE-INDEX are from parent context."
  (when (and entry (eq (lexdb-adapter-id adapter) 'ode))
    (let* ((ode-sense-key (intern (if sense-index (number-to-string sense-index) "0")))
           (sense-synonyms (lexdb-meta-get (lexdb-entry-metadata entry) "ode" "sense_synonyms"))
           (synonyms (when sense-synonyms
                       (cdr (assq ode-sense-key sense-synonyms))))
           (sense-expanded (lexdb-meta-get (lexdb-entry-metadata entry) "ode" "sense_expanded_examples"))
           (expanded-examples (when sense-expanded
                                (cdr (assq ode-sense-key sense-expanded))))
           (sense-num-str (or (lexdb-sense-number sense) ""))
           (is-ode-subsense (string-match-p "\\." sense-num-str))
           (has-sense-number (and sense-num-str (not (string-empty-p sense-num-str))))
           (tab-indent (cond (is-ode-subsense "    ")
                             (has-sense-number "  ")
                             (t "")))
           (tabs nil))
      ;; Build SYNONYMS tab content
      (when synonyms
        (let ((syn-list (if (vectorp synonyms) (append synonyms nil) synonyms)))
          (push (list 'synonyms "SYNONYMS"
                      (with-temp-buffer
                        (dolist (group syn-list)
                          (let ((register (cdr (assoc 'register group)))
                                (words (cdr (assoc 'words group))))
                            (when words
                              (insert tab-indent)
                              (when (and register (not (string-empty-p register)))
                                (insert (propertize register 'face 'lexdb-register-face) " "))
                              (let ((word-list (if (vectorp words) (append words nil) words))
                                    (first t))
                                (dolist (word-obj word-list)
                                  (unless first (insert ", "))
                                  (setq first nil)
                                  (let* ((word-text (if (stringp word-obj)
                                                        word-obj
                                                      (cdr (assoc 'word word-obj))))
                                         (clickable (if (stringp word-obj)
                                                        t
                                                      (eq (cdr (assoc 'clickable word-obj)) t))))
                                    (if clickable
                                        (insert-text-button word-text
                                                            'face 'lexdb-link-face
                                                            'action (lambda (_)
                                                                      (lexdb-search-and-goto-sense word-text nil 'ode))
                                                            'help-echo (format "Look up: %s [ode]" word-text))
                                      (insert (propertize word-text 'face 'default))))))
                              (insert "\n"))))
                        (buffer-string)))
                tabs)))
      ;; Build Example sentences tab content
      (when expanded-examples
        (let ((ex-list (if (vectorp expanded-examples) (append expanded-examples nil) expanded-examples)))
          (push (list 'more-examples (format "Example sentences (%d)" (length ex-list))
                      (with-temp-buffer
                        (dolist (ex ex-list)
                          (insert tab-indent (propertize "• " 'face 'lexdb-definition-face))
                          (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                          (insert "\n"))
                        (buffer-string)))
                tabs)))
      ;; Insert tab bar aligned with examples
      (when tabs
        (insert tab-indent)
        (let ((tab-group (format "lexdb-ode-sense-%d-%s" (lexdb-entry-id entry) (symbol-name ode-sense-key))))
          (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group))))))

(defun lexdb-ui--render-sense (sense adapter &optional entry sense-index)
  "Render a single SENSE using ADAPTER.
Optional ENTRY provides access to entry-level metadata for lexunits/grambox.
Optional SENSE-INDEX is the 0-based index of this sense in the entry."
  (let* ((caps (lexdb-adapter-capabilities adapter))
         (audio-dir (lexdb-adapter-audio-dir adapter))
         (ns (symbol-name (lexdb-adapter-id adapter)))
         (sense-num-str (or (lexdb-sense-number sense) "0"))
         ;; Check if this is a subsense (contains ".") for ODE
         (is-subsense (and (eq (lexdb-adapter-id adapter) 'ode)
                           (string-match-p "\\." sense-num-str))))
    ;; Subsense indentation for ODE
    (when is-subsense
      (insert "  "))
    ;; Sense number
    (when-let* ((num (lexdb-sense-number sense)))
      (when (lexdb--non-empty-string-p num)
        (insert (propertize num 'face 'lexdb-sense-num-face) " ")))
    ;; Translation indicator (🌐) - right after sense number
    (when (memq 'chinese-definition caps)
      (when-let* ((def-zh (lexdb-meta-get (lexdb-sense-metadata sense) ns "definition-zh")))
        (when (and (lexdb--non-empty-string-p def-zh) lexdb-ui-translation-indicator)
          (insert (propertize lexdb-ui-translation-indicator
                              'face 'lexdb-translation-indicator-face
                              'lexdb-translation def-zh
                              'help-echo "Press t to peek translation")
                  " "))))
    ;; Signpost (guide word) - displayed in uppercase with background
    ;; For OALD: fix parentheses spacing (remove spaces around parentheses)
    ;; For ODE: skip signpost if it's a POS keyword (displayed as section header instead)
    (when-let* ((signpost (lexdb-sense-signpost sense)))
      (when (lexdb--non-empty-string-p signpost)
        (let ((ode-pos-keywords '("adjective" "noun" "verb" "adverb" "preposition"
                                  "conjunction" "pronoun" "determiner" "exclamation"
                                  "prefix" "suffix" "combining form"
                                  "proper noun" "mass noun" "count noun"
                                  "modal verb" "auxiliary verb" "linking verb"
                                  "abbreviation" "contraction" "symbol"))
              (formatted (upcase signpost)))
          ;; Skip POS signpost for ODE (already shown as section header)
          (unless (and (eq (lexdb-adapter-id adapter) 'ode)
                       (member (downcase signpost) ode-pos-keywords))
            ;; Fix spacing: "CALL (OUT)" -> "CALL(OUT)" for OALD style
            (when (eq (lexdb-adapter-id adapter) 'oald)
              (setq formatted (replace-regexp-in-string " +(" "(" formatted))
              (setq formatted (replace-regexp-in-string ") +" ")" formatted)))
            (insert (propertize formatted 'face 'lexdb-signpost-face) " ")))))
    ;; ODE: Section-level register (e.g., "informal") - on its own line before definition
    ;; Uses sense-index (sort_order) as key
    (when (and entry sense-index (eq (lexdb-adapter-id adapter) 'ode))
      (let* ((section-registers-map (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_section_registers"))
             (sort-key (number-to-string sense-index))
             (section-register (when section-registers-map
                                 (cdr (assoc sort-key section-registers-map #'string=)))))
        (when (lexdb--non-empty-string-p section-register)
          (insert (propertize section-register 'face 'lexdb-register-face) "\n"))))
    ;; ODE: Form groups (e.g., "also days") - after sense number, before definition
    ;; Uses sense-index (sort_order) as key, not sense number (which can repeat across POS)
    (when (and entry sense-index (eq (lexdb-adapter-id adapter) 'ode))
      (let* ((form-groups-map (lexdb-meta-get (lexdb-entry-metadata entry) ns "sense_form_groups"))
             (sort-key (number-to-string sense-index))
             (form-groups (when form-groups-map
                            (cdr (assoc sort-key form-groups-map #'string=)))))
        (when (lexdb--non-empty-string-p form-groups)
          (insert (propertize (concat "(" form-groups ")") 'face 'lexdb-grammar-face) " "))))
    ;; OALD grammar codes inline (e.g., "[Tn] [I]", "[sing or pl v]") - before definition
    (when (eq (lexdb-adapter-id adapter) 'oald)
      (let ((gps (lexdb-sense-grammar-patterns sense)))
        (when gps
          (let ((codes (delq nil
                        (mapcar (lambda (gp)
                                  (let ((pattern (lexdb-grammar-pattern-pattern gp)))
                                    ;; Handle various formats:
                                    ;; 1. Already bracketed: "[I]", "[Tn.p]"
                                    ;; 2. Short code: "C", "U", "I", "Tn", "Tn.p"
                                    ;; 3. OALD4 long format: "sing or pl v", "sing v"
                                    ;; 4. Skip Chinese text
                                    (cond
                                     ;; Already bracketed - use as-is
                                     ((string-match "^\\[.+\\]$" pattern)
                                      pattern)
                                     ;; Contains Chinese - skip
                                     ((string-match "[\u4e00-\u9fff]" pattern)
                                      nil)
                                     ;; Short code (no space, ≤8 chars) - add brackets
                                     ((and (not (string-match " " pattern))
                                           (<= (length pattern) 8))
                                      (format "[%s]" pattern))
                                     ;; OALD4 long format (e.g., "sing or pl v") - add brackets
                                     ((string-match "^[a-z or]+$" pattern)
                                      (format "[%s]" pattern))
                                     ;; Other patterns - skip
                                     (t nil))))
                                gps))))
            (when codes
              (insert (propertize (string-join codes " ") 'face 'lexdb-grammar-face) " "))))))
    ;; Lexunit prefix (e.g., "particulars", "all round British English")
    ;; Read from entry-level sense_lexunit_prefixes indexed by sense number
    ;; Now structured: [{'type': 'lexunit'/'geo'/'lexvar', 'text': '...'}, ...]
    ;; Rendered BEFORE grammar label so "particulars [plural]" not "[plural] particulars"
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
    ;; Grammar label (for non-OALD/ODE adapters) - after lexunit prefix
    ;; ODE handles grammar labels separately with [ATTRIBUTIVE] format
    (when (and (memq 'grammar caps)
               (not (eq (lexdb-adapter-id adapter) 'ode)))
      (when-let* ((gram (lexdb-sense-grammar sense)))
        (when (lexdb--non-empty-string-p gram)
          (insert (propertize gram 'face 'lexdb-grammar-face) " "))))
    ;; Register labels (e.g., "formal", "informal") - after lexunit, before definition
    ;; Also geographic/regional labels and domain labels (e.g., "Astronomy")
    (let ((labels (lexdb-sense-labels sense)))
      (when labels
        (dolist (label labels)
          (let ((ltype (lexdb-label-type label))
                (lvalue (lexdb-label-value label)))
            (cond
             ;; Grammar labels for ODE: format as [ATTRIBUTIVE]
             ((and lvalue (eq ltype 'grammar) (eq (lexdb-adapter-id adapter) 'ode))
              (insert (propertize (format "[%s]" (upcase lvalue)) 'face 'lexdb-grammar-face) " "))
             ;; Register, geo, domain labels
             ((and lvalue (member ltype '(register geo domain)))
              (insert (propertize lvalue 'face 'lexdb-register-face) " ")))))))
    ;; OALD plural forms (e.g., "(pl manifestos or manifestoes)") - before definition
    ;; Uses <<l>>...<</l>> for plural words (blue), <<gram>>...<</gram>> for "pl" (gray)
    ;; Default face is definition-face so "or" and parentheses are plain text
    (when (eq (lexdb-adapter-id adapter) 'oald)
      (when-let* ((plural (lexdb-meta-get (lexdb-sense-metadata sense) ns "plural")))
        (when (lexdb--non-empty-string-p plural)
          (lexdb-ui--insert-formatted-definition plural 'lexdb-definition-face)
          (insert " "))))
    ;; Definition (English) - this may be just the lexunit for senses with subsenses
    (let ((def (lexdb-sense-definition sense)))
      (when (lexdb--non-empty-string-p def)
        (lexdb-ui--insert-formatted-definition def 'lexdb-definition-face)))
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
    ;; Cross-references (Cf) on separate line with clickable links
    ;; Format: Cf <<xr:target>>text<</xr>>suffix
    (let ((labels (lexdb-sense-labels sense))
          (jump-adapter (lexdb-adapter-id adapter)))
      (when labels
        (dolist (label labels)
          (let ((ltype (lexdb-label-type label))
                (lvalue (lexdb-label-value label)))
            (when (and lvalue (eq ltype 'cf))
              (insert "  ")
              ;; Parse and render with clickable links
              (let ((start 0)
                    (text lvalue))
                (while (string-match "<<xr:\\([^>]+\\)>>\\([^<]+\\)<</xr>>" text start)
                  (let ((target (match-string 1 text))
                        (link-text (match-string 2 text))
                        (match-start (match-beginning 0))
                        (match-end (match-end 0)))
                    ;; Insert text before match
                    (when (> match-start start)
                      (insert (propertize (substring text start match-start) 'face 'lexdb-grammar-face)))
                    ;; Insert clickable link
                    (insert-text-button link-text
                                        'face 'lexdb-inflection-link-face
                                        'action (lambda (_)
                                                  (lexdb-search-and-goto-sense target nil jump-adapter))
                                        'help-echo (format "Look up: %s" target))
                    (setq start match-end)))
                ;; Insert remaining text
                (when (< start (length text))
                  (insert (propertize (substring text start) 'face 'lexdb-grammar-face))))
              (insert "\n"))))))

    ;; Subsenses (a, b, c)
    (lexdb-ui--render-sense-subsenses sense adapter entry caps audio-dir ns)

    ;; Regular examples BEFORE grammar patterns (position=0)
    (lexdb-ui--render-sense-examples sense adapter caps audio-dir ns 0 is-subsense)
    ;; Grammar patterns
    (lexdb-ui--render-sense-grammar-patterns sense adapter audio-dir)
    ;; Regular examples AFTER grammar patterns (position=1)
    (lexdb-ui--render-sense-examples sense adapter caps audio-dir ns 1 is-subsense)
    ;; Lexunits (sub-phrases like "call a doctor/the police")
    (lexdb-ui--render-sense-lexunits entry sense adapter audio-dir ns sense-num-str)

    ;; Sense-level cross references
    (lexdb-ui--render-sense-crossrefs sense adapter)

    ;; Grammar box (GRAMMAR usage notes)
    (lexdb-ui--render-sense-grammar-box entry ns sense-num-str)

    ;; Register box (Register usage notes)
    (lexdb-ui--render-sense-register-box entry ns sense-num-str)

    ;; ODE: Sense-level tabs (SYNONYMS, Example sentences)
    (lexdb-ui--render-sense-ode-tabs entry adapter sense sense-index)))

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

(defun lexdb-ui--insert-crossref-fragments (xref adapter-id)
  "Insert cross-reference XREF with clickable links.
Uses fragments if available, otherwise falls back to prefix/clickable/suffix.
ADAPTER-ID is used for navigation."
  (let ((fragments (cdr (assoc 'fragments xref))))
    (if fragments
        ;; New format with fragments
        (let ((frag-list (if (vectorp fragments) (append fragments nil) fragments)))
          (dolist (frag frag-list)
            (let ((frag-type (cdr (assoc 'type frag)))
                  (frag-value (cdr (assoc 'value frag)))
                  (frag-target (cdr (assoc 'target frag))))
              (cond
               ((equal frag-type "link")
                (insert-text-button frag-value
                                    'face 'lexdb-crossref-face
                                    'action (lambda (_)
                                              (lexdb-search-and-goto-sense
                                               (or frag-target frag-value) nil adapter-id))
                                    'help-echo (format "Look up: %s" (or frag-target frag-value))))
               ((equal frag-type "text")
                (insert (propertize frag-value 'face 'lexdb-definition-face)))))))
      ;; Legacy format with prefix/clickable/suffix
      (let ((prefix (cdr (assoc 'prefix xref)))
            (clickable (cdr (assoc 'clickable xref)))
            (suffix (cdr (assoc 'suffix xref)))
            (target-word (cdr (assoc 'target_word xref))))
        (when (lexdb--non-empty-string-p prefix)
          (insert (propertize prefix 'face 'lexdb-definition-face)))
        (when (lexdb--non-empty-string-p clickable)
          (insert-text-button clickable
                              'face 'lexdb-crossref-face
                              'action (lambda (_)
                                        (lexdb-search-and-goto-sense
                                         (or target-word clickable) nil adapter-id))
                              'help-echo (format "Look up: %s" (or target-word clickable))))
        (when (lexdb--non-empty-string-p suffix)
          (insert (propertize suffix 'face 'lexdb-definition-face)))))))

(defun lexdb-ui--render-phrase-synonyms (syn-list &optional indent)
  "Render SYN-LIST as clickable synonyms for PHRASES/PHRASAL VERBS.
INDENT is the prefix string for alignment (default \"    \").
Returns a string with text properties preserved for insertion."
  (let ((indent (or indent "    ")))
    (with-temp-buffer
      (dolist (group (if (vectorp syn-list) (append syn-list nil) syn-list))
        (let ((register (lexdb-ui--alist-get 'register group))
              (words (lexdb-ui--alist-get 'words group)))
          ;; Always start with indent for alignment
          (insert indent)
          (when (lexdb--non-empty-string-p register)
            (insert (propertize register 'face 'lexdb-label-face) " "))
          (let ((word-list (if (vectorp words) (append words nil) words))
                (first t))
            (dolist (w word-list)
              (unless first (insert ", "))
              (setq first nil)
              (let ((word (lexdb-ui--alist-get 'word w))
                    (clickable (lexdb-ui--alist-get 'clickable w)))
                (if clickable
                    (insert-text-button word
                                        'face 'lexdb-link-face
                                        'action (lambda (_)
                                                  (lexdb-search word))
                                        'help-echo (format "Look up: %s" word))
                  ;; Non-clickable: normal text
                  (insert (propertize word 'face 'default))))))
          (insert "\n")))
      ;; Return with text properties preserved
      (buffer-substring (point-min) (point-max)))))

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
            (when-let* ((lemma (lexdb-find-lemma word adapter-id)))
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

(defun lexdb-ui--alist-get (key alist)
  "Get value for KEY from ALIST, trying both symbol and string keys."
  (or (cdr (assoc key alist))
      (cdr (assoc (if (symbolp key) (symbol-name key) (intern key)) alist))))

(defun lexdb-ui--build-ode-phrases-content (phrases)
  "Build content string for ODE PHRASES tab.
PHRASES is a list of alists with 'phrase', 'definition', and 'examples' keys."
  (with-temp-buffer
    (let ((phrase-list (if (vectorp phrases) (append phrases nil) phrases)))
      (dolist (phrase phrase-list)
        (let ((phrase-text (lexdb-ui--alist-get 'phrase phrase))
              (definition (lexdb-ui--alist-get 'definition phrase))
              (examples (lexdb-ui--alist-get 'examples phrase)))
          (when phrase-text
            (insert "  " (propertize phrase-text 'face '(:inherit lexdb-phrase-face :weight bold)) "\n")
            (when (lexdb--non-empty-string-p definition)
              (insert "    " (propertize definition 'face 'lexdb-definition-face) "\n"))
            (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
              (dolist (ex ex-list)
                (let ((ex-text (lexdb-ui--alist-get 'text ex)))
                  (when (lexdb--non-empty-string-p ex-text)
                    (insert "      " (propertize ex-text 'face 'lexdb-example-face) "\n")))))))))
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
                  (definition-zh (cdr (assoc 'definition_zh sense)))
                  (labels-raw (cdr (assoc 'labels sense)))
                  (examples-raw (cdr (assoc 'examples sense))))
              ;; Convert vectors to lists
              (let ((labels (if (vectorp labels-raw) (append labels-raw nil) labels-raw))
                    (examples (if (vectorp examples-raw) (append examples-raw nil) examples-raw)))
                ;; Translation indicator or indent
                (if (lexdb-ui--valid-string-p definition-zh)
                    (lexdb-ui--insert-translation-indicator definition-zh)
                  (insert "  "))
                ;; Sense number and lexunit
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
                  (lexdb-ui--insert-formatted-definition definition 'lexdb-definition-face))
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
                ;; Examples - handle both string and {text, text_zh} formats
                (dolist (ex examples)
                  (let ((ex-text (if (stringp ex) ex (alist-get 'text ex)))
                        (ex-zh (unless (stringp ex) (alist-get 'text_zh ex))))
                    (when (lexdb-ui--valid-string-p ex-text)
                      (unless (lexdb-ui--insert-translation-indicator ex-zh "  ")
                        (insert "    "))
                      (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
                      (insert "\n")))))))
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
  (let ((caps (lexdb-adapter-capabilities adapter))
        (ns (symbol-name (lexdb-adapter-id adapter)))
        (meta (lexdb-entry-metadata entry)))
    (if-let* ((header-hook (lexdb-adapter-render-entry-header-fn adapter)))
        (funcall header-hook entry (current-buffer))
      ;; Default header rendering
      (lexdb-ui--render-headword entry)
      ;; Variant spellings (e.g., "also hi-vis")
      (when-let* ((variant (lexdb-meta-get meta ns "variant")))
        (when (lexdb--non-empty-string-p variant)
          (insert " " (propertize variant 'face 'lexdb-variant-face))))
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
    ;; WORD ORIGIN tab (skip for ODE - rendered inline via ode-phrases-origin slot)
    (when (and (lexdb-adapter-has-capability-p adapter 'origin)
               (not (eq (lexdb-adapter-id adapter) 'ode)))
      (let* ((origin-full (lexdb-meta-get (lexdb-entry-metadata entry) ns "origin_full"))
             (origin-text origin-full))
        (when (lexdb--non-empty-string-p origin-text)
          (push (list 'origin "WORD ORIGIN"
                      (concat "  " (propertize origin-text 'face 'lexdb-origin-face) "\n"))
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
    ;; PHRASES tab (skip for ODE - rendered inline via ode-phrases-origin slot)
    (unless (eq (lexdb-adapter-id adapter) 'ode)
      (let ((popup-phrases (lexdb-meta-get (lexdb-entry-metadata entry) ns "popup_phrases")))
        (when (and popup-phrases (> (length popup-phrases) 0))
          (push (list 'phrases "PHRASES"
                      (lexdb-ui--build-popup-phrases-content popup-phrases))
                tabs))))
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
  (let ((ode-pos-keywords '("adjective" "noun" "verb" "adverb" "preposition"
                            "conjunction" "pronoun" "determiner" "exclamation"
                            "prefix" "suffix" "combining form"))
        (sense-index 0)
        (shown-pos nil))  ; Track which POS headers we've shown
    ;; Count unique POS sections to decide if we need section headers
    (let ((pos-count 0))
      (dolist (sense (lexdb-entry-senses entry))
        (when-let* ((signpost (lexdb-sense-signpost sense)))
          (when (member (downcase signpost) ode-pos-keywords)
            (setq pos-count (1+ pos-count)))))
      ;; Only show POS section headers if there are multiple POS sections
      (dolist (sense (lexdb-entry-senses entry))
        ;; For ODE: Show POS section header when signpost contains a part of speech
        ;; but only if there are multiple POS sections (to avoid duplication with header)
        (when (and (eq (lexdb-adapter-id adapter) 'ode)
                   (> pos-count 1))
          (when-let* ((signpost (lexdb-sense-signpost sense)))
            (when (and (member (downcase signpost) ode-pos-keywords)
                       (not (member signpost shown-pos)))
              ;; Insert POS header as a section divider
              (insert (propertize signpost 'face 'lexdb-pos-face))
              ;; Add transitivity after POS if present (e.g., "[with object]")
              (let* ((transitivity-map (lexdb-meta-get (lexdb-entry-metadata entry) "ode" "sense_transitivity"))
                     (sort-key (number-to-string sense-index))
                     (transitivity (when transitivity-map
                                     (cdr (assoc sort-key transitivity-map #'string=)))))
                (when (lexdb--non-empty-string-p transitivity)
                  (insert " " (propertize (upcase transitivity) 'face 'lexdb-grammar-face))))
              (insert "\n")
              (push signpost shown-pos))))
        (lexdb-ui--render-sense sense adapter entry sense-index)
        (setq sense-index (1+ sense-index)))))
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

(defun lexdb-ui--render-idiom-subsense (subsense)
  "Render a single idiom SUBSENSE with number, definition and examples."
  (let ((sub-num (alist-get 'number subsense))
        (sub-def (alist-get 'definition subsense))
        (sub-def-zh (alist-get 'definition_zh subsense))
        (sub-examples (lexdb-ui--ensure-list (alist-get 'examples subsense))))
    ;; Subsense number and definition
    (when sub-def
      (unless (lexdb-ui--insert-translation-indicator sub-def-zh)
        (insert "  "))
      (insert (propertize (concat sub-num ". ") 'face 'lexdb-sense-number-face))
      (lexdb-ui--insert-formatted-definition sub-def 'lexdb-definition-face)
      (insert "\n"))
    ;; Subsense examples
    (dolist (ex sub-examples)
      (lexdb-ui--render-idiom-example ex))))

(defun lexdb-ui--render-idiom-single-def (idiom adapter-id)
  "Render a single-definition IDIOM with labels, definition and crossrefs.
ADAPTER-ID is used for crossref jumps."
  (let* ((idiom-def (alist-get 'definition idiom))
         (idiom-def-zh (alist-get 'definition_zh idiom))
         (idiom-examples (lexdb-ui--ensure-list (alist-get 'examples idiom)))
         (label-list (lexdb-ui--ensure-list (alist-get 'labels idiom)))
         (has-valid-labels (and label-list
                                (cl-some (lambda (l) (alist-get 'value l)) label-list)))
         (idiom-def-valid (and (lexdb-ui--valid-string-p idiom-def)
                               (string-match-p "[a-zA-Z]" idiom-def))))
    ;; Definition line
    (when (or has-valid-labels idiom-def-valid)
      (unless (lexdb-ui--insert-translation-indicator idiom-def-zh)
        (insert "  "))
      ;; Labels (fml, infml, etc.)
      (dolist (label label-list)
        (let ((lvalue (alist-get 'value label)))
          (when lvalue
            (insert (propertize lvalue 'face 'lexdb-grammar-face) " "))))
      ;; Definition with possible crossref
      (when idiom-def-valid
        (lexdb-ui--render-idiom-definition idiom idiom-def adapter-id))
      (insert "\n"))
    ;; Examples
    (dolist (ex idiom-examples)
      (lexdb-ui--render-idiom-example ex))))

(defun lexdb-ui--render-idiom-definition (idiom idiom-def adapter-id)
  "Render IDIOM-DEF, handling crossrefs if present.
IDIOM is the full idiom alist, ADAPTER-ID for crossref jumps."
  (let ((crossref (alist-get 'crossref idiom)))
    (cond
     ;; Explicit crossref structure
     (crossref
      (let* ((prefix (alist-get 'prefix crossref))
             (clickable (alist-get 'clickable crossref))
             (suffix (alist-get 'suffix crossref))
             (target-word (alist-get 'target_word crossref))
             (search-word (lexdb-ui--normalize-search-word
                           (or target-word clickable))))
        (when prefix
          (insert (propertize prefix 'face 'lexdb-crossref-face)))
        (insert-text-button clickable
                            'face 'lexdb-crossref-face
                            'action (lambda (_)
                                      (lexdb-search-and-goto-sense
                                       search-word nil adapter-id))
                            'help-echo (format "Look up: %s [%s]"
                                               search-word adapter-id))
        ;; Render suffix with format markers (e.g., <<pos>>v<</pos>>)
        (when suffix
          (insert " ")
          (lexdb-ui--insert-formatted-definition suffix 'lexdb-crossref-face))))
     ;; Arrow-style crossref in definition
     ((string-match "^→\\([^.]+\\)\\.$" idiom-def)
      (let* ((raw-target (match-string 1 idiom-def))
             (search-word (lexdb-ui--normalize-search-word raw-target)))
        (insert (propertize "→" 'face 'lexdb-crossref-face))
        (insert-text-button raw-target
                            'face 'lexdb-crossref-face
                            'action (lambda (_)
                                      (lexdb-search-and-goto-sense
                                       search-word nil adapter-id))
                            'help-echo (format "Look up: %s [%s]"
                                               search-word adapter-id))))
     ;; Plain definition
     (t
      (lexdb-ui--insert-formatted-definition idiom-def 'lexdb-definition-face)))))

(defun lexdb-ui--render-idiom (idiom adapter-id)
  "Render a single IDIOM entry.
ADAPTER-ID is used for crossref navigation."
  (let ((idiom-text (alist-get 'text idiom))
        (sense-list (lexdb-ui--ensure-list (alist-get 'senses idiom))))
    ;; Idiom text (bold)
    (insert "  ")
    (when idiom-text
      (insert (propertize idiom-text 'face '(:inherit lexdb-phrase-face :weight bold))))
    (insert "\n")
    ;; Render subsenses or single definition
    (if sense-list
        (dolist (subsense sense-list)
          (lexdb-ui--render-idiom-subsense subsense))
      (lexdb-ui--render-idiom-single-def idiom adapter-id))))

(defun lexdb-ui--slot-idioms (entry adapter)
  "Slot: Render idioms section."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (adapter-id (lexdb-adapter-id adapter))
         (idiom-list (lexdb-ui--ensure-list
                      (lexdb-meta-get (lexdb-entry-metadata entry) ns "idioms"))))
    (when idiom-list
      (insert "\n")
      (let ((idm-start (point)))
        (lexdb-ui--insert-translation-indicator "习语")
        (insert (propertize "IDM" 'face 'lexdb-label-face))
        (insert "\n")
        (dolist (idiom idiom-list)
          (lexdb-ui--render-idiom idiom adapter-id))
        ;; Create overlay for background
        (when (> (point) idm-start)
          (let ((ov (make-overlay idm-start (point))))
            (overlay-put ov 'face 'lexdb-grambox-background-face)
            (overlay-put ov 'lexdb-idioms t)))))))

(defun lexdb-ui--slot-usage (entry adapter)
  "Slot: Render usage notes section."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (usage-list (lexdb-ui--ensure-list
                      (lexdb-meta-get (lexdb-entry-metadata entry) ns "usage"))))
    (when usage-list
      (insert "\n")
      (let ((usage-start (point)))
        (lexdb-ui--insert-translation-indicator "用法")
        (insert (propertize "NOTE OF USAGE" 'face 'lexdb-label-face))
        (insert "\n")
        (lexdb-ui--render-usage-items usage-list 0)
        ;; Create overlay for background
        (when (> (point) usage-start)
          (let ((ov (make-overlay usage-start (point))))
            (overlay-put ov 'face 'lexdb-grambox-background-face)
            (overlay-put ov 'lexdb-usage t)))
        (insert "\n")))))

(defun lexdb-ui--render-usage-items (items indent-level)
  "Render list of usage ITEMS at INDENT-LEVEL."
  (let ((indent (make-string (* indent-level 2) ?\s)))
    (dolist (item items)
      (let ((text (alist-get 'text item))
            (text-zh (alist-get 'text_zh item))
            (ex-list (lexdb-ui--ensure-list (alist-get 'examples item)))
            (child-list (lexdb-ui--ensure-list (alist-get 'children item))))
        ;; Render the text line with translation indicator
        (when (lexdb-ui--valid-string-p text)
          (unless (lexdb-ui--insert-translation-indicator text-zh indent)
            (insert indent "  "))
          (lexdb-ui--insert-formatted-definition text 'lexdb-definition-face)
          (insert "\n"))
        ;; Render examples
        (dolist (ex ex-list)
          (let ((ex-text (alist-get 'text ex))
                (ex-zh (alist-get 'text_zh ex)))
            (when (lexdb-ui--valid-string-p ex-text)
              (unless (lexdb-ui--insert-translation-indicator ex-zh (concat indent "  "))
                (insert indent "    "))
              (lexdb-ui--insert-highlighted-text ex-text 'lexdb-example-face)
              (insert "\n"))))
        ;; Recursively render children
        (when child-list
          (lexdb-ui--render-usage-items child-list (1+ indent-level)))))))

(defun lexdb-ui--slot-phrasal-verbs (entry adapter)
  "Slot: Render phrasal verbs."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (phrasal-verbs (lexdb-meta-get (lexdb-entry-metadata entry) ns "phrasal-verbs")))
    (when (and phrasal-verbs (> (length phrasal-verbs) 0))
      (insert "\n")
      (let ((pv-start (point)))
        (lexdb-ui--insert-translation-indicator "动词短语")
        (insert (propertize "PHR V" 'face 'lexdb-label-face))
        (insert "\n")
        (lexdb-ui--render-phrasal-verbs phrasal-verbs)
        ;; Create overlay for background
        (when (> (point) pv-start)
          (let ((ov (make-overlay pv-start (point))))
            (overlay-put ov 'face 'lexdb-grambox-background-face)
            (overlay-put ov 'lexdb-phrasal-verbs t)))))))

(defun lexdb-ui--slot-synonyms (entry adapter)
  "Slot: Render synonyms and cross-references."
  (lexdb-ui--render-synonyms-and-crossrefs entry adapter))

(defun lexdb-ui--slot-runons (entry adapter)
  "Slot: Render run-on entries (derived words like 'relevantly adverb')."
  (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
         (runons (lexdb-meta-get (lexdb-entry-metadata entry) ns "runons")))
    (when (and runons (> (length runons) 0))
      (let ((runon-list (cond ((vectorp runons) (append runons nil))
                              ((listp runons) runons)
                              (t nil))))
        (when runon-list
          (insert "\n")
          (dolist (runon runon-list)
            (let ((word (cdr (assoc 'word runon)))
                  (pos (cdr (assoc 'pos runon)))
                  (gram (cdr (assoc 'gram runon)))
                  (pron-uk (cdr (assoc 'pron_uk runon)))
                  (pron-us (cdr (assoc 'pron_us runon))))
              (when word
                (insert (propertize "—" 'face 'lexdb-label-face))
                (insert (propertize word 'face 'lexdb-headword-face))
                ;; Pronunciation (format: /UK $ US/ or just /UK/)
                (when (or pron-uk pron-us)
                  (insert " ")
                  (insert (propertize
                           (cond
                            ((and pron-uk pron-us)
                             (format "/%s $ %s/" pron-uk pron-us))
                            (pron-uk (format "/%s/" pron-uk))
                            (pron-us (format "/%s/" pron-us)))
                           'face 'lexdb-pron-face)))
                ;; Part of speech
                (when (and pos (not (string-empty-p pos)))
                  (insert " " (propertize pos 'face 'lexdb-pos-face)))
                ;; Grammar info (e.g., [countable])
                (when (and gram (not (string-empty-p gram)))
                  (insert " " (propertize gram 'face 'lexdb-grammar-face)))
                (insert "\n")))))))))

(defun lexdb-ui--render-ode-phrases (entry phrases)
  "Render ODE PHRASES section for ENTRY."
  (when (and phrases (> (length phrases) 0))
    (let ((section-start (point))
          (phrase-list (if (vectorp phrases) (append phrases nil) phrases))
          (phrase-index 0)
          (current-phrase nil))
      (insert "\n")
      (insert (propertize "PHRASES" 'face 'lexdb-grambox-heading-face) "\n")
      (dolist (phrase phrase-list)
        (let ((phrase-text (lexdb-ui--alist-get 'phrase phrase))
              (sense-number (lexdb-ui--alist-get 'sense_number phrase))
              (labels (lexdb-ui--alist-get 'labels phrase))
              (definition (lexdb-ui--alist-get 'definition phrase))
              (cross-refs (lexdb-ui--alist-get 'cross_refs phrase))
              (examples (lexdb-ui--alist-get 'examples phrase))
              (expanded-examples (lexdb-ui--alist-get 'expanded_examples phrase))
              (synonyms (lexdb-ui--alist-get 'synonyms phrase)))
          (when phrase-text
            ;; Only insert phrase header if it's different from the previous one
            (unless (equal phrase-text current-phrase)
              (insert "  " (propertize phrase-text 'face '(:inherit lexdb-phrase-face :weight bold)) "\n")
              (setq current-phrase phrase-text))
            ;; Calculate indent based on subsense
            (let* ((is-subsense (and sense-number (string-match-p "\\." sense-number)))
                   (def-indent (if is-subsense "      " "    "))
                   (ex-indent (if is-subsense "        " "      ")))
              ;; Insert sense number + labels + definition
              (when (lexdb--non-empty-string-p definition)
                (insert def-indent)
                (when (lexdb--non-empty-string-p sense-number)
                  (insert (propertize sense-number 'face 'lexdb-sense-number-face) " "))
                ;; Labels (proverb, informal, dated, etc.)
                (let ((label-list (if (vectorp labels) (append labels nil) labels)))
                  (dolist (label label-list)
                    (when (lexdb--non-empty-string-p label)
                      (insert (propertize label 'face 'lexdb-register-face) " "))))
                (insert (propertize definition 'face 'lexdb-definition-face) "\n"))
              ;; Inline examples
              (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
                (dolist (ex ex-list)
                  (let ((ex-text (lexdb-ui--alist-get 'text ex)))
                    (when (lexdb--non-empty-string-p ex-text)
                      (insert ex-indent (propertize ex-text 'face 'lexdb-example-face) "\n")))))
              ;; Cross-references (Compare with..., See also..., etc.)
              (let ((xref-list (if (vectorp cross-refs) (append cross-refs nil) cross-refs)))
                (when xref-list
                  (insert ex-indent)
                  (let ((first t))
                    (dolist (xref xref-list)
                      (unless first (insert ", "))
                      (setq first nil)
                      (lexdb-ui--insert-crossref-fragments xref 'ode)))
                  (insert "\n")))
              ;; Example sentences and SYNONYMS tabs
              (let ((tabs nil)
                    (tab-group (format "lexdb-ode-phrase-%d-%d" (lexdb-entry-id entry) phrase-index)))
                ;; Build tabs list
                (when expanded-examples
                  (let ((exp-list (if (vectorp expanded-examples) (append expanded-examples nil) expanded-examples)))
                    (when (> (length exp-list) 0)
                      (push (list 'more-examples
                                  (format "Example sentences (%d)" (length exp-list))
                                  (with-temp-buffer
                                    (dolist (ex exp-list)
                                      (insert ex-indent (propertize "• " 'face 'lexdb-definition-face))
                                      (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                                      (insert "\n"))
                                    (buffer-string)))
                            tabs))))
                (when synonyms
                  (let ((syn-list (if (vectorp synonyms) (append synonyms nil) synonyms)))
                    (when (> (length syn-list) 0)
                      (push (list 'synonyms
                                  "SYNONYMS"
                                  (lexdb-ui--render-phrase-synonyms syn-list ex-indent))
                            tabs))))
                ;; Insert tab bar if we have tabs
                (when tabs
                  (insert ex-indent)
                  (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group))))
            (setq phrase-index (1+ phrase-index)))))
      ;; Create overlay for background
      (when (> (point) section-start)
        (let ((ov (make-overlay section-start (point))))
          (overlay-put ov 'face 'lexdb-grambox-background-face)
          (overlay-put ov 'lexdb-ode-phrases t))))))

(defun lexdb-ui--render-ode-phrasal-verbs (entry phrasal-verbs)
  "Render ODE PHRASAL VERBS section for ENTRY."
  (when (and phrasal-verbs (> (length phrasal-verbs) 0))
    (let ((section-start (point))
          (pv-list (if (vectorp phrasal-verbs) (append phrasal-verbs nil) phrasal-verbs))
          (pv-index 0)
          (current-pv nil))
      (insert "\n")
      (insert (propertize "PHRASAL VERBS" 'face 'lexdb-grambox-heading-face) "\n")
      (dolist (pv pv-list)
        (let ((pv-text (lexdb-ui--alist-get 'phrase pv))
              (sense-number (lexdb-ui--alist-get 'sense_number pv))
              (labels (lexdb-ui--alist-get 'labels pv))
              (definition (lexdb-ui--alist-get 'definition pv))
              (cross-refs (lexdb-ui--alist-get 'cross_refs pv))
              (examples (lexdb-ui--alist-get 'examples pv))
              (expanded-examples (lexdb-ui--alist-get 'expanded_examples pv))
              (synonyms (lexdb-ui--alist-get 'synonyms pv)))
          (when pv-text
            ;; Only insert phrasal verb header if it's different from the previous one
            (unless (equal pv-text current-pv)
              (insert "  " (propertize pv-text 'face 'lexdb-phrase-face) "\n")
              (setq current-pv pv-text))
            ;; Calculate indent based on subsense
            (let* ((is-subsense (and sense-number (string-match-p "\\." sense-number)))
                   (def-indent (if is-subsense "      " "    "))
                   (ex-indent (if is-subsense "        " "      ")))
              ;; Insert sense number + labels + definition
              (when (lexdb--non-empty-string-p definition)
                (insert def-indent)
                (when (lexdb--non-empty-string-p sense-number)
                  (insert (propertize sense-number 'face 'lexdb-sense-number-face) " "))
                ;; Labels (proverb, informal, dated, etc.)
                (let ((label-list (if (vectorp labels) (append labels nil) labels)))
                  (dolist (label label-list)
                    (when (lexdb--non-empty-string-p label)
                      (insert (propertize label 'face 'lexdb-register-face) " "))))
                (insert (propertize definition 'face 'lexdb-definition-face) "\n"))
              ;; Inline examples
              (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
                (dolist (ex ex-list)
                  (let ((ex-text (lexdb-ui--alist-get 'text ex)))
                    (when (lexdb--non-empty-string-p ex-text)
                      (insert ex-indent (propertize ex-text 'face 'lexdb-example-face) "\n")))))
              ;; Cross-references
              (let ((xref-list (if (vectorp cross-refs) (append cross-refs nil) cross-refs)))
                (when xref-list
                  (insert ex-indent)
                  (let ((first t))
                    (dolist (xref xref-list)
                      (unless first (insert ", "))
                      (setq first nil)
                      (lexdb-ui--insert-crossref-fragments xref 'ode)))
                  (insert "\n")))
              ;; Example sentences and SYNONYMS tabs
              (let ((tabs nil)
                    (tab-group (format "lexdb-ode-pv-%d-%d" (lexdb-entry-id entry) pv-index)))
                (when expanded-examples
                  (let ((exp-list (if (vectorp expanded-examples) (append expanded-examples nil) expanded-examples)))
                    (when (> (length exp-list) 0)
                      (push (list 'more-examples
                                  (format "Example sentences (%d)" (length exp-list))
                                  (with-temp-buffer
                                    (dolist (ex exp-list)
                                      (insert ex-indent (propertize "• " 'face 'lexdb-definition-face))
                                      (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                                      (insert "\n"))
                                    (buffer-string)))
                            tabs))))
                (when synonyms
                  (let ((syn-list (if (vectorp synonyms) (append synonyms nil) synonyms)))
                    (when (> (length syn-list) 0)
                      (push (list 'synonyms
                                  "SYNONYMS"
                                  (lexdb-ui--render-phrase-synonyms syn-list ex-indent))
                            tabs))))
                ;; Insert tab bar
                (when tabs
                  (insert ex-indent)
                  (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group))))
            (setq pv-index (1+ pv-index)))))
      ;; Create overlay for background
      (when (> (point) section-start)
        (let ((ov (make-overlay section-start (point))))
          (overlay-put ov 'face 'lexdb-grambox-background-face)
          (overlay-put ov 'lexdb-ode-phrasal-verbs t))))))

(defun lexdb-ui--render-ode-derivatives (entry derivatives)
  "Render ODE DERIVATIVES section for ENTRY."
  (when (and derivatives (> (length derivatives) 0))
    (let ((section-start (point))
          (deriv-list (if (vectorp derivatives) (append derivatives nil) derivatives))
          (deriv-index 0))
      (insert "\n")
      (insert (propertize "DERIVATIVES" 'face 'lexdb-grambox-heading-face) "\n")
      (dolist (deriv deriv-list)
        (let ((headword (lexdb-ui--alist-get 'headword deriv))
              (pos (lexdb-ui--alist-get 'pos deriv))
              (ipa (lexdb-ui--alist-get 'ipa deriv))
              (definition (lexdb-ui--alist-get 'definition deriv))
              (examples (lexdb-ui--alist-get 'examples deriv))
              (expanded-examples (lexdb-ui--alist-get 'expanded_examples deriv)))
          (when headword
            ;; Headword with same color as main headword (no bold/height)
            (insert "  " (propertize headword 'face 'lexdb-phonetic-face))
            (when (lexdb--non-empty-string-p pos)
              (insert " " (propertize pos 'face 'lexdb-pos-face)))
            (when (lexdb--non-empty-string-p ipa)
              (insert " " (propertize (concat "/" ipa "/") 'face 'lexdb-phonetic-face)))
            (insert "\n")
            ;; Definition
            (when (lexdb--non-empty-string-p definition)
              (insert "    " (propertize definition 'face 'lexdb-definition-face) "\n"))
            ;; Inline examples (align with headword - 2 spaces)
            (let ((ex-list (if (vectorp examples) (append examples nil) examples)))
              (dolist (ex ex-list)
                (when (lexdb--non-empty-string-p ex)
                  (insert "  " (propertize ex 'face 'lexdb-example-face) "\n"))))
            ;; Example sentences tab for expanded examples (align with examples - 2 spaces)
            (when expanded-examples
              (let ((exp-list (if (vectorp expanded-examples) (append expanded-examples nil) expanded-examples)))
                (when (> (length exp-list) 0)
                  (insert "  ")
                  (let ((tab-group (format "lexdb-ode-deriv-%d-%d" (lexdb-entry-id entry) deriv-index)))
                    (lexdb-ui--insert-tab-bar
                     (list (list 'more-examples
                                 (format "Example sentences (%d)" (length exp-list))
                                 (with-temp-buffer
                                   (dolist (ex exp-list)
                                     (insert "  " (propertize "• " 'face 'lexdb-definition-face))
                                     (lexdb-ui--insert-highlighted-text ex 'lexdb-example-face)
                                     (insert "\n"))
                                   (buffer-string))))
                     tab-group)))))
            (setq deriv-index (1+ deriv-index)))))
      ;; Create overlay for background
      (when (> (point) section-start)
        (let ((ov (make-overlay section-start (point))))
          (overlay-put ov 'face 'lexdb-grambox-background-face)
          (overlay-put ov 'lexdb-ode-derivatives t))))))

(defun lexdb-ui--render-ode-encyclopedic (enc-note)
  "Render ODE encyclopedic note section."
  (when (lexdb--non-empty-string-p enc-note)
    (let ((section-start (point)))
      (insert "\n")
      (insert "  " (propertize enc-note 'face 'lexdb-origin-face) "\n")
      ;; Create overlay for background
      (let ((ov (make-overlay section-start (point))))
        (overlay-put ov 'face 'lexdb-grambox-background-face)
        (overlay-put ov 'lexdb-ode-encyclopedic t)))))

(defun lexdb-ui--render-ode-usage (usage-text)
  "Render ODE USAGE section."
  (when (lexdb--non-empty-string-p usage-text)
    (let ((section-start (point)))
      (insert "\n")
      (insert (propertize "USAGE" 'face 'lexdb-grambox-heading-face) "\n")
      (insert "  " (propertize usage-text 'face 'lexdb-origin-face) "\n")
      ;; Create overlay for background
      (let ((ov (make-overlay section-start (point))))
        (overlay-put ov 'face 'lexdb-grambox-background-face)
        (overlay-put ov 'lexdb-ode-usage t)))))

(defun lexdb-ui--render-ode-origin (origin-alist adapter)
  "Render ODE ORIGIN section using ADAPTER."
  (when (and origin-alist (listp origin-alist))
    (let ((section-start (point))
          (text (or (cdr (assoc 'text origin-alist))
                    (cdr (assoc "text" origin-alist))))
          (appendix (or (cdr (assoc 'appendix origin-alist))
                        (cdr (assoc "appendix" origin-alist)))))
      (when (lexdb--non-empty-string-p text)
        (insert "\n")
        (insert (propertize "ORIGIN" 'face 'lexdb-grambox-heading-face) "\n")
        (insert "  ")
        (lexdb-ui--insert-formatted-origin text (lexdb-adapter-id adapter))
        (insert "\n")
        (when (and appendix (not (string-empty-p appendix)))
          (insert "  ")
          (lexdb-ui--insert-formatted-origin appendix (lexdb-adapter-id adapter))
          (insert "\n"))
        ;; Create overlay for background
        (let ((ov (make-overlay section-start (point))))
          (overlay-put ov 'face 'lexdb-grambox-background-face)
          (overlay-put ov 'lexdb-ode-origin t))))))

(defun lexdb-ui--slot-ode-phrases-origin (entry adapter)
  "Slot: Render ODE Phrases, Phrasal Verbs, Derivatives, Usage, and Origin sections."
  (when (eq (lexdb-adapter-id adapter) 'ode)
    (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
           (phrases (lexdb-meta-get (lexdb-entry-metadata entry) ns "phrases"))
           (phrasal-verbs (lexdb-meta-get (lexdb-entry-metadata entry) ns "phrasal_verbs"))
           (derivatives (lexdb-meta-get (lexdb-entry-metadata entry) ns "derivatives"))
           (enc-note (lexdb-meta-get (lexdb-entry-metadata entry) ns "encyclopedic_note"))
           (usage-text (lexdb-meta-get (lexdb-entry-metadata entry) ns "usage"))
           (origin-alist (lexdb-meta-get (lexdb-entry-metadata entry) ns "origin")))
      (lexdb-ui--render-ode-phrases entry phrases)
      (lexdb-ui--render-ode-phrasal-verbs entry phrasal-verbs)
      (lexdb-ui--render-ode-derivatives entry derivatives)
      (lexdb-ui--render-ode-encyclopedic enc-note)
      (lexdb-ui--render-ode-usage usage-text)
      (lexdb-ui--render-ode-origin origin-alist adapter))))

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
        (when-let* ((slot-fn (cdr (assq slot-name lexdb-ui-slot-functions))))
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

(defun lexdb-imenu--pos-abbrev (pos)
  "Return abbreviation for part of speech POS."
  (pcase (downcase pos)
    ("noun" "n.")
    ("verb" "v.")
    ("adjective" "adj.")
    ("adverb" "adv.")
    ("preposition" "prep.")
    ("conjunction" "conj.")
    ("pronoun" "pron.")
    ("determiner" "det.")
    ("interjection" "interj.")
    (_ pos)))

(defun lexdb-imenu--format-entry (pos-abbrev num signpost definition headword)
  "Format imenu entry with gray headword suffix.
Format: \"POS NUM SIGNPOST definition (headword)\"."
  (let ((main-part (concat (if pos-abbrev (concat pos-abbrev " ") "")
                           num
                           (if (and signpost (not (string-empty-p signpost)))
                               (concat " " (string-trim signpost))
                             "")
                           (if (and definition (not (string-empty-p definition)))
                               (concat " " (string-trim definition))
                             "")))
        (headword-part (when headword
                         (propertize (concat " (" headword ")")
                                     'face '(:foreground "#888888")))))
    (concat main-part (or headword-part ""))))

(defun lexdb-imenu-create-index ()
  "Create imenu index for lexdb buffer.
Index format: \"pos. number SIGNPOST (headword)\" (e.g., \"n. 1 PARENT (mother)\")."
  (let ((index nil)
        (current-headword nil)
        (current-headword-pos nil)  ; position of current headword
        (current-pos nil)
        (has-senses nil))           ; track if current headword has senses
    (save-excursion
      (goto-char (point-min))
      ;; Single pass: find headwords, POS headers, and senses
      (while (not (eobp))
        (cond
         ;; Headword line: word followed by space and /
         ;; e.g., "mother¹ /ˈmʌðə..." or "CALL /kɔːl/"
         ((looking-at "^\\([a-zA-Z][-a-zA-Z']*[⁰¹²³⁴⁵⁶⁷⁸⁹0-9]*\\) +/")
          ;; Before switching to new headword, check if previous had no senses
          (when (and current-headword (not has-senses))
            (push (cons (lexdb-imenu--format-entry
                         (when current-pos (lexdb-imenu--pos-abbrev current-pos))
                         "-" nil nil current-headword)
                        current-headword-pos)
                  index))
          ;; Set new headword
          (setq current-headword (match-string 1))
          (setq current-headword-pos (point))
          (setq has-senses nil)
          ;; Try to get POS from same line
          (let ((line-end (line-end-position)))
            (save-excursion
              (if (re-search-forward "\\b\\(noun\\|verb\\|adjective\\|adverb\\|preposition\\|conjunction\\|pronoun\\|determiner\\|interjection\\)\\b" line-end t)
                  (setq current-pos (match-string 1))
                (setq current-pos nil)))))
         ;; POS header line: standalone part of speech (possibly with transitivity)
         ;; e.g., "noun", "verb", "adjective", "verb [WITH OBJECT]"
         ((looking-at "^\\(noun\\|verb\\|adjective\\|adverb\\|preposition\\|conjunction\\|pronoun\\|determiner\\|interjection\\)\\b")
          (setq current-pos (match-string 1)))
         ;; Sense line: starts with number
         ;; e.g., "1 PARENT" or "1 [WITH OBJECT] Give..." or "2 "
         ((looking-at "^\\([0-9]+\\) +\\(\\[.*?\\] *\\|[A-Z][A-Z /]* *\\)?\\(.*\\)?$")
          (let ((num (match-string 1))
                (signpost (match-string 2))
                (definition (match-string 3))
                (pos (point)))
            (setq has-senses t)
            (push (cons (lexdb-imenu--format-entry
                         (when current-pos (lexdb-imenu--pos-abbrev current-pos))
                         num signpost definition current-headword)
                        pos)
                  index))))
        (forward-line 1))
      ;; Handle last headword if it had no senses
      (when (and current-headword (not has-senses))
        (push (cons (lexdb-imenu--format-entry
                     (when current-pos (lexdb-imenu--pos-abbrev current-pos))
                     "-" nil nil current-headword)
                    current-headword-pos)
              index)))
    (nreverse index)))

(defun lexdb-ui-play-audio-at-point ()
  "Play audio at point if available.
Only searches within the current line to avoid playing wrong audio.
Supports both local audio (with audio-dir) and online audio (path only)."
  (interactive)
  (let ((audio-path (get-text-property (point) 'lexdb-audio-path))
        (audio-dir (get-text-property (point) 'lexdb-audio-dir)))
    (if audio-path
        ;; Found audio at point - play it (audio-dir can be nil for online)
        (lexdb-ui--play-audio audio-path audio-dir)
      ;; Try to find audio on current line only
      (let ((found-path nil)
            (found-dir nil)
            (line-start (line-beginning-position))
            (line-end (line-end-position)))
        ;; Search backward to line start
        (save-excursion
          (while (and (not found-path) (>= (point) line-start))
            (when-let* ((path (get-text-property (point) 'lexdb-audio-path)))
              (setq found-path path)
              (setq found-dir (get-text-property (point) 'lexdb-audio-dir)))
            (unless found-path (backward-char))))
        ;; Search forward to line end if not found
        (unless found-path
          (save-excursion
            (while (and (not found-path) (<= (point) line-end))
              (when-let* ((path (get-text-property (point) 'lexdb-audio-path)))
                (setq found-path path)
                (setq found-dir (get-text-property (point) 'lexdb-audio-dir)))
              (unless found-path (forward-char)))))
        (if found-path
            (lexdb-ui--play-audio found-path found-dir)
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
              (when-let* ((lemma-fn (lexdb-adapter-lemma-fn adapter)))
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
