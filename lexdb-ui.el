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
  '((((background dark))  :foreground "#04cecd")
    (((background light)) :foreground "#fe0000"))
  "Face for part of speech."
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

(defun lexdb-ui--render-headword (entry)
  "Render headword for ENTRY."
  (let ((display (or (lexdb-entry-headword-display entry)
                     (lexdb-entry-headword entry))))
    (when (lexdb-ui--non-empty-string-p display)
      (insert (propertize display 'face 'lexdb-headword-face)))))

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
    ;; Render in format: /uk-ipa/ $ /us-ipa/ or /uk-ipa $ us-ipa/
    (when (or uk-ipa us-ipa)
      (insert " ")
      (cond
       ;; Both UK and US
       ((and uk-ipa us-ipa)
        (insert (propertize (format "/%s/" uk-ipa) 'face 'lexdb-phonetic-face))
        (insert (propertize " $ " 'face 'lexdb-phonetic-face))
        (insert (propertize (format "%s/" us-ipa) 'face 'lexdb-phonetic-face)))
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
  "Render audio playback buttons for ENTRY."
  (let* ((caps (lexdb-adapter-capabilities adapter))
         (audio-dir (lexdb-adapter-audio-dir adapter))
         (ns (symbol-name (lexdb-adapter-id adapter)))
         (meta (lexdb-entry-metadata entry))
         (has-buttons nil))
    (when audio-dir
      ;; UK audio
      (when (memq 'audio-uk caps)
        (when-let ((path (lexdb-meta-get meta ns "audio-uk")))
          (when (lexdb-ui--non-empty-string-p path)
            (setq has-buttons t)
            (insert-text-button "[🔊 UK]"
                                'face 'lexdb-button-face
                                'action (lambda (_) (lexdb-ui--play-audio path audio-dir))
                                'help-echo "Play UK pronunciation"))))
      ;; US audio
      (when (memq 'audio-us caps)
        (when-let ((path (lexdb-meta-get meta ns "audio-us")))
          (when (lexdb-ui--non-empty-string-p path)
            (when has-buttons (insert " "))
            (setq has-buttons t)
            (insert-text-button "[🔊 US]"
                                'face 'lexdb-button-face
                                'action (lambda (_) (lexdb-ui--play-audio path audio-dir))
                                'help-echo "Play US pronunciation")))))
    (when has-buttons (insert "\n"))))

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
        (audio-dir (lexdb-adapter-audio-dir adapter)))
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
    ;; Definition
    (let ((def (lexdb-sense-definition sense)))
      (when (lexdb-ui--non-empty-string-p def)
        (insert (propertize def 'face 'lexdb-definition-face))))
    (insert "\n")
    ;; Grammar patterns (e.g., "be required to do something")
    (dolist (gp (lexdb-sense-grammar-patterns sense))
      (let ((pattern (lexdb-grammar-pattern-pattern gp)))
        (when (lexdb-ui--non-empty-string-p pattern)
          (insert "  " (propertize pattern 'face 'lexdb-grammar-pattern-face) "\n")
          ;; Grammar pattern examples
          (dolist (ex (lexdb-grammar-pattern-examples gp))
            (let ((ex-text (lexdb-example-text ex)))
              (when (lexdb-ui--non-empty-string-p ex-text)
                (insert "    " (propertize ex-text 'face 'lexdb-example-face))
                ;; Example audio
                (when-let ((audio-path (lexdb-example-audio ex)))
                  (when (lexdb-ui--non-empty-string-p audio-path)
                    (insert " ")
                    (insert-text-button "[🔊]"
                                        'face 'lexdb-button-face
                                        'action (lambda (_) (lexdb-ui--play-audio audio-path audio-dir))
                                        'help-echo "Play example")))
                (insert "\n")))))))
    ;; Regular examples
    (when (memq 'examples caps)
      (dolist (ex (lexdb-sense-examples sense))
        (let ((ex-text (lexdb-example-text ex)))
          (when (lexdb-ui--non-empty-string-p ex-text)
            (insert "    " (propertize ex-text 'face 'lexdb-example-face))
            ;; Example audio
            (when (and (memq 'audio-example caps) (lexdb-example-audio ex))
              (let ((audio-path (lexdb-example-audio ex)))
                (when (lexdb-ui--non-empty-string-p audio-path)
                  (insert " ")
                  (insert-text-button "[🔊]"
                                      'face 'lexdb-button-face
                                      'action (lambda (_) (lexdb-ui--play-audio audio-path audio-dir))
                                      'help-echo "Play example"))))
            (insert "\n")))))
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
             (link (when raw-link
                     (if (string-match "\\`\\([^#]+\\)" raw-link)
                         (match-string 1 raw-link)
                       raw-link))))
        (if link
            ;; Clickable link
            (insert-text-button target
                                'face face
                                'action (lambda (_) (lexdb-search link))
                                'help-echo (format "Look up: %s" link))
          ;; Plain text
          (insert (propertize target 'face face)))))))

(defun lexdb-ui--build-phrases-content (phrases)
  "Build content string for PHRASES tab."
  (with-temp-buffer
    (dolist (phrase phrases)
      (insert "  • " (propertize (lexdb-relation-target phrase)
                                  'face 'lexdb-phrase-face) "\n"))
    (buffer-string)))

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

    ;; Senses/definitions
    (dolist (sense (lexdb-entry-senses entry))
      (lexdb-ui--render-sense sense adapter))
    (insert "\n")

    ;; Synonyms and cross-refs (inline, not in tabs)
    (lexdb-ui--render-synonyms-and-crossrefs entry adapter)

    ;; Build tabs for PHRASES, COLLOCATIONS, WORD ORIGIN
    (let ((tabs nil)
          (tab-group (format "lexdb-tabs-%d-%d" entry-id (random 10000))))
      ;; PHRASES tab
      (when (memq 'phrases caps)
        (let* ((relations (lexdb-entry-relations entry))
               (phrases (seq-filter (lambda (r) (eq (lexdb-relation-type r) 'phrase)) relations)))
          (when phrases
            (push (list 'phrases
                        (format "PHRASES (%d)" (length phrases))
                        (lexdb-ui--build-phrases-content phrases))
                  tabs))))
      ;; COLLOCATIONS tab
      (when (memq 'collocations caps)
        (let ((colls (or (lexdb-meta-get (lexdb-entry-metadata entry)
                                         (symbol-name (lexdb-adapter-id adapter))
                                         "collocations-cache")
                         (when (lexdb-adapter-collocations-fn adapter)
                           (funcall (lexdb-adapter-collocations-fn adapter) entry-id)))))
          (when colls
            (push (list 'collocations
                        (format "COLLOCATIONS (%d)" (length colls))
                        (lexdb-ui--build-collocations-content colls))
                  tabs))))
      ;; WORD ORIGIN tab
      (when (lexdb-adapter-has-capability-p adapter 'origin)
        (let* ((ns (symbol-name (lexdb-adapter-id adapter)))
               (origin (lexdb-meta-get (lexdb-entry-metadata entry) ns "origin-full")))
          (when (lexdb-ui--non-empty-string-p origin)
            (push (list 'origin
                        "WORD ORIGIN"
                        (concat "  " (propertize origin 'face 'lexdb-origin-face) "\n"))
                  tabs))))
      ;; Insert tab bar if we have any tabs
      (when tabs
        (lexdb-ui--insert-tab-bar (nreverse tabs) tab-group)))

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
    (define-key map "q" #'quit-window)
    (define-key map "s" #'lexdb-search)
    (define-key map "n" #'forward-button)
    (define-key map "p" #'backward-button)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keymap for `lexdb-mode'.")

(define-derived-mode lexdb-mode special-mode "Lexdb"
  "Major mode for viewing dictionary entries."
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;; Legacy aliases
(defalias 'ldoce-mode 'lexdb-mode)
(defalias 'dict-mode 'lexdb-mode)

(defun lexdb-ui--get-buffer (adapter-id)
  "Get or create buffer for ADAPTER-ID."
  (get-buffer-create (format "*Lexdb:%s*" adapter-id)))

(defun lexdb-ui-display (word entries adapter &optional no-lemma-hint)
  "Display ENTRIES for WORD using ADAPTER.
If NO-LEMMA-HINT is nil and no entries found, offer lemma suggestion."
  (let ((buf (lexdb-ui--get-buffer (lexdb-adapter-id adapter))))
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
    (display-buffer buf)))

(provide 'lexdb-ui)
;;; lexdb-ui.el ends here
