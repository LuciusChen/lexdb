;;; lexdb.el --- Multi-dictionary interface for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Your Name
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: dictionary, multilingual, reference
;; URL: https://github.com/example/lexdb

;;; Commentary:

;; A unified multi-dictionary interface for Emacs.
;;
;; Features:
;; - Support for multiple dictionary sources via adapters
;; - Capability-based rendering (only shows what each dictionary provides)
;; - Extensible architecture for adding new dictionaries
;;
;; Quick start:
;;   (require 'lexdb)
;;   (require 'lexdb-ldoce)  ; LDOCE adapter
;;
;;   ;; Configure LDOCE
;;   (setq lexdb-ldoce-db-file "~/path/to/ldoce.db")
;;   (setq lexdb-ldoce-audio-directory "~/path/to/audio/")
;;   (lexdb-ldoce-register)
;;
;;   ;; Set as default and use
;;   (setq lexdb-default-adapter 'ldoce)
;;   (global-set-key (kbd "C-c d") #'lexdb-search)

;;; Code:

(require 'cl-lib)

;;;; ============================================================
;;;; Customization
;;;; ============================================================

(defgroup lexdb nil
  "Multi-dictionary interface."
  :prefix "lexdb-"
  :group 'applications)

(defcustom lexdb-default-adapter nil
  "Default dictionary adapter ID.
Set this to the ID of your preferred dictionary (e.g., \\='ldoce)."
  :type '(choice (const nil) symbol)
  :group 'lexdb)

(defcustom lexdb-audio-player "mpv"
  "Command to play audio files.
mpv is recommended as it supports both local files and URLs."
  :type 'string
  :group 'lexdb)

(defcustom lexdb-dictionaries nil
  "List of dictionary configurations.
Each element is a plist with the following keys:

  :id        - (required) Symbol identifying the dictionary (e.g., ldoce, oald)
  :type      - (required) Dictionary type, must match a registered adapter type
  :name      - Human-readable name (optional, defaults to type name)
  :db-file   - Path to SQLite database file
  :audio-dir - Path to audio files directory (optional)
  :enabled   - Whether this dictionary is enabled (default t)
  :priority  - Sort order, lower numbers shown first (default 100)

Example:
  (setq lexdb-dictionaries
        \\='((:id ldoce
           :type ldoce
           :name \"Longman Dictionary\"
           :db-file \"~/dicts/LDOCE6.db\"
           :audio-dir \"~/dicts/ldoce-audio/\"
           :priority 1)
          (:id oald
           :type oald
           :name \"Oxford Advanced Learner's\"
           :db-file \"~/dicts/OALD4_EC.db\"
           :priority 2)))"
  :type '(repeat plist)
  :group 'lexdb)

(defvar lexdb--adapter-types (make-hash-table :test 'eq)
  "Hash table of adapter type registration functions.
Key is type symbol, value is (register-fn . unregister-fn).")

(defun lexdb-register-adapter-type (type register-fn &optional unregister-fn)
  "Register adapter TYPE with REGISTER-FN and optional UNREGISTER-FN.
REGISTER-FN takes a plist config and returns an adapter.
This is called by adapter implementations (e.g., lexdb-ldoce.el)."
  (puthash type (cons register-fn unregister-fn) lexdb--adapter-types))

(defun lexdb-init ()
  "Initialize all dictionaries from `lexdb-dictionaries'.
Call this after setting up your dictionary configurations."
  (interactive)
  (unless lexdb-dictionaries
    (user-error "No dictionaries configured. Set `lexdb-dictionaries' first"))
  ;; Sort by priority
  (let ((sorted-dicts (sort (copy-sequence lexdb-dictionaries)
                            (lambda (a b)
                              (< (or (plist-get a :priority) 100)
                                 (or (plist-get b :priority) 100)))))
        (registered 0)
        (errors nil))
    (dolist (config sorted-dicts)
      (let* ((id (plist-get config :id))
             (type (or (plist-get config :type) id))
             (enabled (if (plist-member config :enabled)
                          (plist-get config :enabled)
                        t))
             (type-info (gethash type lexdb--adapter-types)))
        (cond
         ((not enabled)
          (message "Skipping disabled dictionary: %s" id))
         ((not type-info)
          (push (format "Unknown dictionary type: %s (for %s)" type id) errors))
         (t
          (condition-case err
              (progn
                (funcall (car type-info) config)
                (cl-incf registered))
            (error
             (push (format "Failed to register %s: %s" id (error-message-string err))
                   errors)))))))
    ;; Set default adapter to first enabled dictionary
    (unless lexdb-default-adapter
      (when-let ((first-enabled (cl-find-if
                                 (lambda (c)
                                   (if (plist-member c :enabled)
                                       (plist-get c :enabled)
                                     t))
                                 sorted-dicts)))
        (setq lexdb-default-adapter (plist-get first-enabled :id))))
    ;; Report results
    (if errors
        (progn
          (message "Registered %d dictionaries with %d errors:" registered (length errors))
          (dolist (err (nreverse errors))
            (message "  - %s" err)))
      (message "Registered %d dictionaries" registered))))

(defun lexdb-get-dict-config (id)
  "Get configuration plist for dictionary ID."
  (cl-find-if (lambda (c) (eq (plist-get c :id) id))
              lexdb-dictionaries))

;;;; ============================================================
;;;; Capability System
;;;; ============================================================

(defconst lexdb-capability-groups
  '((core
     (lookup      . "Basic word lookup")
     (definition  . "Word definitions"))

    (phonetic
     (pronunciation . "Phonetic transcription")
     (audio-uk      . "UK pronunciation audio")
     (audio-us      . "US pronunciation audio")
     (audio-example . "Example sentence audio"))

    (lexical
     (pos         . "Part of speech")
     (grammar     . "Grammar annotations")
     (register    . "Register/style labels")
     (hyphenation . "Syllable division"))

    (frequency
     (frequency-rank . "Frequency ranking")
     (frequency-band . "Frequency band (e.g., S1 W2)")
     (cefr           . "CEFR level")
     (academic       . "Academic word marker"))

    (relations
     (examples     . "Example sentences")
     (collocations . "Word collocations")
     (phrases      . "Phrases and idioms")
     (synonyms     . "Synonyms")
     (antonyms     . "Antonyms")
     (cross-refs   . "Cross references"))

    (etymology
     (origin      . "Word origin/etymology")
     (word-family . "Word family members"))

    (search
     (lemmatization . "Lemma/base form lookup")
     (fuzzy-search  . "Fuzzy matching")
     (wildcard      . "Wildcard search")))
  "Dictionary capabilities organized by group.
Each group is (GROUP-NAME . ((CAP-SYMBOL . DESCRIPTION) ...)).")

(defun lexdb-capability-list ()
  "Return flat list of all capability symbols."
  (let (caps)
    (dolist (group lexdb-capability-groups)
      (dolist (cap (cdr group))
        (push (car cap) caps)))
    (nreverse caps)))

(defun lexdb-capability-group (cap)
  "Return the group name for capability CAP."
  (catch 'found
    (dolist (group lexdb-capability-groups)
      (when (assq cap (cdr group))
        (throw 'found (car group))))))

(defun lexdb-capability-description (cap)
  "Return description string for capability CAP."
  (catch 'found
    (dolist (group lexdb-capability-groups)
      (when-let ((pair (assq cap (cdr group))))
        (throw 'found (cdr pair))))))

;;;; ============================================================
;;;; Common Utility Functions
;;;; ============================================================

(defsubst lexdb--non-empty-string-p (s)
  "Return non-nil if S is a non-empty string."
  (and (stringp s) (not (string-empty-p s))))

(defsubst lexdb--ensure-string (s &optional default)
  "Ensure S is a string, return DEFAULT if nil or empty."
  (if (lexdb--non-empty-string-p s) s (or default "")))

;;;; ============================================================
;;;; Core Data Structures
;;;; ============================================================

(cl-defstruct (lexdb-entry (:constructor lexdb-entry-create))
  "Universal dictionary entry structure.
All dictionaries must map their data to this structure."
  (id nil
      :type integer
      :documentation "Unique identifier within the dictionary")
  (headword nil
            :type string
            :documentation "The word being defined (required)")
  (headword-display nil
                    :type (or string null)
                    :documentation "Display form (e.g., with syllable dots: ap·ple)")
  (senses nil
          :type list
          :documentation "List of lexdb-sense structs")
  (pronunciations nil
                  :type list
                  :documentation "List of lexdb-pronunciation structs")
  (relations nil
             :type list
             :documentation "List of lexdb-relation structs (phrases, synonyms, etc.)")
  (metadata nil
            :type alist
            :documentation "Dictionary-specific data as namespaced alist.
Keys should use namespace/key format (e.g., ldoce/frequency, oxford/cefr-level)."))

(cl-defstruct (lexdb-sense (:constructor lexdb-sense-create))
  "A single sense/meaning of a word."
  (id nil :type integer)
  (number nil
          :type (or string null)
          :documentation "Sense number (e.g., \"1\", \"2a\")")
  (signpost nil
            :type (or string null)
            :documentation "Guide word (e.g., \"MOVE FROM A FIXED POINT\")")
  (definition nil
              :type string
              :documentation "The definition text (required)")
  (examples nil
            :type list
            :documentation "List of lexdb-example structs")
  (grammar-patterns nil
                    :type list
                    :documentation "List of lexdb-grammar-pattern structs")
  (labels nil
          :type list
          :documentation "List of lexdb-label structs (grammar, register, etc.)")
  (relations nil
             :type list
             :documentation "List of sense-level lexdb-relation structs")
  (metadata nil :type alist))

(cl-defstruct (lexdb-grammar-pattern (:constructor lexdb-grammar-pattern-create))
  "A grammar pattern with examples (e.g., 'be required to do something')."
  (pattern nil :type string :documentation "The pattern text (required)")
  (gloss nil :type (or string null) :documentation "Short explanation (e.g., '=during a particular day')")
  (examples nil :type list :documentation "List of lexdb-example structs"))

(cl-defstruct (lexdb-example (:constructor lexdb-example-create))
  "An example sentence."
  (text nil :type string :documentation "Example text (required)")
  (source nil :type (or string null) :documentation "Source attribution")
  (audio nil :type (or string null) :documentation "Audio file path")
  (metadata nil :type alist))

(cl-defstruct (lexdb-label (:constructor lexdb-label-create))
  "A label/tag attached to entry or sense."
  (type nil
        :type symbol
        :documentation "Label type: pos, grammar, register, domain, region, etc.")
  (value nil
         :type string
         :documentation "Label value (required)")
  (display nil
           :type (or string null)
           :documentation "Custom display text"))

(cl-defstruct (lexdb-pronunciation (:constructor lexdb-pronunciation-create))
  "Pronunciation information."
  (ipa nil :type (or string null) :documentation "IPA transcription")
  (variant nil
           :type (or symbol null)
           :documentation "Variant: uk, us, au, etc.")
  (audio nil :type (or string null) :documentation "Audio file path")
  (metadata nil :type alist))

(cl-defstruct (lexdb-relation (:constructor lexdb-relation-create))
  "A relationship to another word or phrase.
Uses fragment storage for clean rendering: prefix + clickable + suffix."
  (type nil
        :type symbol
        :documentation "Relation type: synonym, antonym, phrase, cross-ref, etc.")
  ;; Fragment fields for rendering
  (prefix nil
          :type (or string null)
          :documentation "Non-clickable prefix (e.g., 'see THESAURUS at ')")
  (clickable nil
             :type string
             :documentation "Clickable part (required)")
  (suffix nil
          :type (or string null)
          :documentation "Non-clickable suffix (e.g., ' (v.)')")
  ;; Navigation fields
  (target-word nil
               :type (or string null)
               :documentation "Target word for navigation (lowercase)")
  (target-sense nil
                :type (or string null)
                :documentation "Target sense number")
  ;; Legacy fields (for backward compatibility)
  (target nil
          :type (or string null)
          :documentation "Legacy: combined display text")
  (target-link nil
               :type (or string null)
               :documentation "Legacy: raw link target")
  (target-entry-id nil
                   :type (or integer null)
                   :documentation "ID of target entry if resolvable")
  (sense-id nil
            :type (or integer null)
            :documentation "Associated sense ID")
  (metadata nil :type alist))

(cl-defstruct (lexdb-collocation (:constructor lexdb-collocation-create))
  "A collocation entry."
  (category nil :type (or string null) :documentation "Category (ADJECTIVES, VERBS, etc.)")
  (text nil :type string :documentation "Collocation text (required)")
  (gloss nil :type (or string null) :documentation "Explanation")
  (examples nil :type list :documentation "List of example strings")
  (metadata nil :type alist))

;;;; ============================================================
;;;; Metadata Helpers
;;;; ============================================================

(defun lexdb-meta-get (metadata namespace key)
  "Get value from METADATA with NAMESPACE/KEY.
Example: (lexdb-meta-get meta \"ldoce\" \"frequency\")"
  (alist-get (intern (format "%s/%s" namespace key)) metadata))

(defun lexdb-meta-put (metadata namespace key value)
  "Return new METADATA with NAMESPACE/KEY set to VALUE.
Does not mutate original metadata."
  (let ((full-key (intern (format "%s/%s" namespace key))))
    (cons (cons full-key value)
          (assq-delete-all full-key metadata))))

(defun lexdb-meta-keys (metadata &optional namespace)
  "List all keys in METADATA, optionally filtered by NAMESPACE."
  (let ((prefix (when namespace (format "%s/" namespace))))
    (delq nil
          (mapcar (lambda (pair)
                    (let ((key-str (symbol-name (car pair))))
                      (if prefix
                          (when (string-prefix-p prefix key-str)
                            (car pair))
                        (car pair))))
                  metadata))))

;;;; ============================================================
;;;; Adapter Structure
;;;; ============================================================

(cl-defstruct (lexdb-adapter (:constructor lexdb-adapter-create))
  "Dictionary adapter - bridges specific dictionary to universal interface."
  ;; Identity
  (id nil :type symbol :documentation "Unique identifier (e.g., ldoce, oxford)")
  (name nil :type string :documentation "Human-readable name")
  (version nil :type (or string null))

  ;; Capabilities
  (capabilities nil
                :type list
                :documentation "List of supported capability symbols")

  ;; Resources
  (db-file nil :type (or string null) :documentation "SQLite database path")
  (audio-dir nil :type (or string null) :documentation "Audio files directory")

  ;; Required functions
  (lookup-fn nil
             :type function
             :documentation "(word) -> list of lexdb-entry")
  (close-fn nil
            :type function
            :documentation "() -> nil, cleanup resources")

  ;; Optional data functions (based on capabilities)
  (pronunciations-fn nil
                     :type (or function null)
                     :documentation "(entry-id) -> list of lexdb-pronunciation")
  (collocations-fn nil
                   :type (or function null)
                   :documentation "(entry-id) -> list of lexdb-collocation")
  (relations-fn nil
                :type (or function null)
                :documentation "(entry-id type) -> list of lexdb-relation")
  (lemma-fn nil
            :type (or function null)
            :documentation "(word) -> lemma string")

  ;; Batch prefetch for performance (optional)
  (prefetch-fn nil
               :type (or function null)
               :documentation "(entry-ids) -> nil, prefetch data into cache")

  ;; Optional UI hooks (for dictionary-specific rendering)
  (render-frequency-fn nil
                       :type (or function null)
                       :documentation "(freq-value) -> propertized string")
  (render-entry-header-fn nil
                          :type (or function null)
                          :documentation "(entry buffer) -> nil, custom header rendering")
  (render-sense-prefix-fn nil
                          :type (or function null)
                          :documentation "(sense buffer) -> nil, custom sense prefix"))

;;;; ============================================================
;;;; Adapter Registry
;;;; ============================================================

(defvar lexdb-adapters (make-hash-table :test 'eq)
  "Hash table of registered adapters. Key is adapter ID symbol.")

(defvar lexdb-current-adapter nil
  "Currently active adapter ID.")

(defun lexdb-register-adapter (adapter)
  "Register ADAPTER in the global registry."
  (unless (lexdb-adapter-p adapter)
    (error "Invalid adapter: %S" adapter))
  (unless (lexdb-adapter-id adapter)
    (error "Adapter must have an ID"))
  (unless (lexdb-adapter-lookup-fn adapter)
    (error "Adapter must have a lookup-fn"))
  (puthash (lexdb-adapter-id adapter) adapter lexdb-adapters)
  (message "Registered dictionary adapter: %s" (lexdb-adapter-name adapter)))

(defun lexdb-unregister-adapter (id)
  "Unregister adapter with ID."
  (when-let ((adapter (gethash id lexdb-adapters)))
    (when (lexdb-adapter-close-fn adapter)
      (funcall (lexdb-adapter-close-fn adapter)))
    (remhash id lexdb-adapters)))

(defun lexdb-get-adapter (id)
  "Get adapter by ID."
  (gethash id lexdb-adapters))

(defun lexdb-list-adapters ()
  "Return alist of (ID . adapter) for all registered adapters."
  (let (result)
    (maphash (lambda (k v) (push (cons k v) result)) lexdb-adapters)
    (nreverse result)))

(defun lexdb-adapter-has-capability-p (adapter cap)
  "Check if ADAPTER supports capability CAP."
  (memq cap (lexdb-adapter-capabilities adapter)))

(defun lexdb-adapter-capabilities-in-group (adapter group)
  "Return list of ADAPTER's capabilities in GROUP."
  (let ((group-caps (cdr (assq group lexdb-capability-groups))))
    (seq-filter (lambda (cap)
                  (and (assq cap group-caps)
                       (lexdb-adapter-has-capability-p adapter cap)))
                (mapcar #'car group-caps))))

;;;; ============================================================
;;;; Query API
;;;; ============================================================

(defun lexdb-lookup (word &optional adapter-id)
  "Look up WORD using specified or current adapter.
Returns list of lexdb-entry structs."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (unless adapter
      (error "No adapter found: %s" id))
    (funcall (lexdb-adapter-lookup-fn adapter) word)))

(defun lexdb-get-pronunciations (entry-id &optional adapter-id)
  "Get pronunciations for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'pronunciation)
               (lexdb-adapter-pronunciations-fn adapter))
      (funcall (lexdb-adapter-pronunciations-fn adapter) entry-id))))

(defun lexdb-get-collocations (entry-id &optional adapter-id)
  "Get collocations for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'collocations)
               (lexdb-adapter-collocations-fn adapter))
      (funcall (lexdb-adapter-collocations-fn adapter) entry-id))))

(defun lexdb-get-relations (entry-id type &optional adapter-id)
  "Get relations of TYPE for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter (lexdb-adapter-relations-fn adapter))
      (funcall (lexdb-adapter-relations-fn adapter) entry-id type))))

(defun lexdb-find-lemma (word &optional adapter-id)
  "Find lemma/base form of WORD."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'lemmatization)
               (lexdb-adapter-lemma-fn adapter))
      (funcall (lexdb-adapter-lemma-fn adapter) word))))

(defun lexdb-prefetch (entry-ids &optional adapter-id)
  "Prefetch data for ENTRY-IDS to avoid N+1 queries."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter (lexdb-adapter-prefetch-fn adapter))
      (funcall (lexdb-adapter-prefetch-fn adapter) entry-ids))))

;;;; ============================================================
;;;; Utility Functions
;;;; ============================================================

(defun lexdb-entry-get-label (entry type)
  "Get first label of TYPE from ENTRY's senses."
  (catch 'found
    (dolist (sense (lexdb-entry-senses entry))
      (dolist (label (lexdb-sense-labels sense))
        (when (eq (lexdb-label-type label) type)
          (throw 'found label))))))

(defun lexdb-entry-pos (entry)
  "Get part of speech from ENTRY metadata or labels."
  (or (lexdb-meta-get (lexdb-entry-metadata entry)
                      (symbol-name lexdb-current-adapter) "pos")
      (when-let ((label (lexdb-entry-get-label entry 'pos)))
        (lexdb-label-value label))))

(defun lexdb-sense-grammar (sense)
  "Get grammar annotation from SENSE."
  (when-let ((label (seq-find (lambda (l) (eq (lexdb-label-type l) 'grammar))
                              (lexdb-sense-labels sense))))
    (lexdb-label-value label)))

;;;; ============================================================
;;;; State Management
;;;; ============================================================

(defvar lexdb--last-word nil
  "Last searched word.")

(defvar lexdb--history nil
  "History of searched words. List of (word . position) pairs.")

(defvar lexdb--history-position -1
  "Current position in history. -1 means at newest.")

(defcustom lexdb-history-max-length 50
  "Maximum number of words to keep in history."
  :type 'integer
  :group 'lexdb)

(defun lexdb--history-push (word)
  "Push WORD onto history stack."
  (when (and word (not (string-empty-p word)))
    ;; If we're in the middle of history, truncate forward history
    (when (> lexdb--history-position -1)
      (setq lexdb--history (nthcdr lexdb--history-position lexdb--history)))
    ;; Don't add if same as last
    (unless (equal word (car lexdb--history))
      (push word lexdb--history)
      ;; Trim to max length
      (when (> (length lexdb--history) lexdb-history-max-length)
        (setcdr (nthcdr (1- lexdb-history-max-length) lexdb--history) nil)))
    ;; Reset position to newest
    (setq lexdb--history-position -1)))

(defun lexdb-history-back ()
  "Go back to previous word in history."
  (interactive)
  (let ((new-pos (1+ lexdb--history-position)))
    (if (< new-pos (length lexdb--history))
        (let ((word (nth new-pos lexdb--history)))
          (setq lexdb--history-position new-pos)
          (lexdb--search-without-history word)
          (message "History: %d/%d - %s"
                   (1+ new-pos) (length lexdb--history) word))
      (message "At oldest entry in history"))))

(defun lexdb-history-forward ()
  "Go forward to next word in history."
  (interactive)
  (if (> lexdb--history-position 0)
      (let ((new-pos (1- lexdb--history-position)))
        (setq lexdb--history-position new-pos)
        (let ((word (nth new-pos lexdb--history)))
          (lexdb--search-without-history word)
          (message "History: %d/%d - %s"
                   (1+ new-pos) (length lexdb--history) word)))
    (if (= lexdb--history-position 0)
        (message "At newest entry in history")
      (message "No history"))))

(defun lexdb--search-without-history (word)
  "Search for WORD without adding to history.
Respects `lexdb-multi-dict-mode' setting."
  (require 'lexdb-ui)
  (if lexdb-multi-dict-mode
      ;; Multi-dictionary mode: use the same buffer, update all dicts
      (lexdb-ui-display-multi word)
    ;; Single dictionary mode
    (let* ((adapter-id (lexdb--ensure-adapter))
           (adapter (lexdb-get-adapter adapter-id))
           (entries (lexdb-lookup word adapter-id)))
      (unless entries
        (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
          (when-let ((lemma (lexdb-find-lemma word adapter-id)))
            (unless (equal lemma (downcase word))
              (setq entries (lexdb-lookup lemma adapter-id))))))
      (lexdb-ui-display word entries adapter))))

(defun lexdb--ensure-adapter ()
  "Ensure an adapter is selected, return its ID."
  (let ((id (or lexdb-current-adapter lexdb-default-adapter)))
    (unless id
      (let ((adapters (lexdb-list-adapters)))
        (if adapters
            (setq id (caar adapters))
          (error "No dictionary adapters registered. Load an adapter first"))))
    (unless (lexdb-get-adapter id)
      (error "Dictionary adapter not found: %s" id))
    (setq lexdb-current-adapter id)
    id))

;;;; ============================================================
;;;; Interactive Commands
;;;; ============================================================

(declare-function lexdb-ui-display "lexdb-ui")
(declare-function lexdb-ui-display-multi "lexdb-ui")

(defcustom lexdb-multi-dict-mode t
  "If non-nil, search all dictionaries and show with tabs.
If nil, search only the current/default dictionary."
  :type 'boolean
  :group 'lexdb)

;;;###autoload
(defun lexdb-search (word)
  "Search for WORD in dictionaries.
If `lexdb-multi-dict-mode' is non-nil, search all enabled dictionaries.
Otherwise, search only the current/default dictionary."
  (interactive
   (let ((default (thing-at-point 'word t)))
     (list (read-string
            (format "Lexdb%s: "
                    (if (and (not lexdb-multi-dict-mode) lexdb-current-adapter)
                        (format " [%s]" lexdb-current-adapter)
                      ""))
            default))))
  (when (or (null word) (not (stringp word)) (string-empty-p word))
    (user-error "No word specified"))
  (setq lexdb--last-word word)
  (lexdb--history-push word)
  (require 'lexdb-ui)
  (if lexdb-multi-dict-mode
      ;; Multi-dictionary mode
      (lexdb-ui-display-multi word)
    ;; Single dictionary mode
    (let* ((adapter-id (lexdb--ensure-adapter))
           (adapter (lexdb-get-adapter adapter-id))
           (entries (lexdb-lookup word adapter-id)))
      ;; Try lemmatization if no results
      (unless entries
        (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
          (when-let ((lemma (lexdb-find-lemma word adapter-id)))
            (unless (equal lemma (downcase word))
              (setq entries (lexdb-lookup lemma adapter-id))
              (when entries
                (setq word lemma))))))
      (lexdb-ui-display word entries adapter))))

;;;###autoload
(defun lexdb-search-single (word)
  "Search for WORD in current dictionary only (single-dict mode)."
  (interactive
   (let ((default (thing-at-point 'word t)))
     (list (read-string
            (format "Lexdb [%s]: "
                    (or lexdb-current-adapter lexdb-default-adapter "?"))
            default))))
  (when (or (null word) (not (stringp word)) (string-empty-p word))
    (user-error "No word specified"))
  (setq lexdb--last-word word)
  (lexdb--history-push word)
  (require 'lexdb-ui)
  (let* ((adapter-id (lexdb--ensure-adapter))
         (adapter (lexdb-get-adapter adapter-id))
         (entries (lexdb-lookup word adapter-id)))
    (unless entries
      (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
        (when-let ((lemma (lexdb-find-lemma word adapter-id)))
          (unless (equal lemma (downcase word))
            (setq entries (lexdb-lookup lemma adapter-id))
            (when entries
              (setq word lemma))))))
    (lexdb-ui-display word entries adapter)))

;;;###autoload
(defun lexdb-search-at-point ()
  "Search for the word at point in the current dictionary."
  (interactive)
  (let ((word (thing-at-point 'word t)))
    (if word
        (lexdb-search word)
      (call-interactively #'lexdb-search))))

;;;###autoload
(defun lexdb-search-again ()
  "Repeat the last dictionary search."
  (interactive)
  (if lexdb--last-word
      (lexdb-search lexdb--last-word)
    (call-interactively #'lexdb-search)))

;;;###autoload
(defun lexdb-switch-adapter (adapter-id)
  "Switch to dictionary ADAPTER-ID."
  (interactive
   (let ((adapters (lexdb-list-adapters)))
     (unless adapters
       (user-error "No dictionary adapters registered"))
     (list (intern
            (completing-read
             "Switch to dictionary: "
             (mapcar (lambda (p)
                       (format "%s" (car p)))
                     adapters)
             nil t)))))
  (if (lexdb-get-adapter adapter-id)
      (progn
        (setq lexdb-current-adapter adapter-id)
        (message "Switched to: %s"
                 (lexdb-adapter-name (lexdb-get-adapter adapter-id))))
    (user-error "Unknown adapter: %s" adapter-id)))

;;;###autoload
(defun lexdb-list-capabilities ()
  "Display capabilities of the current dictionary."
  (interactive)
  (let* ((adapter-id (lexdb--ensure-adapter))
         (adapter (lexdb-get-adapter adapter-id))
         (caps (lexdb-adapter-capabilities adapter)))
    (with-help-window "*Lexdb Capabilities*"
      (princ (format "Dictionary: %s\n" (lexdb-adapter-name adapter)))
      (princ (format "Version: %s\n\n" (or (lexdb-adapter-version adapter) "unknown")))
      (princ "Capabilities:\n\n")
      (dolist (group lexdb-capability-groups)
        (let ((group-name (car group))
              (group-caps (cdr group))
              (has-any nil))
          ;; Check if this group has any enabled caps
          (dolist (cap-pair group-caps)
            (when (memq (car cap-pair) caps)
              (setq has-any t)))
          (when has-any
            (princ (format "  %s:\n" (upcase (symbol-name group-name))))
            (dolist (cap-pair group-caps)
              (let ((cap (car cap-pair))
                    (desc (cdr cap-pair)))
                (when (memq cap caps)
                  (princ (format "    ✓ %s - %s\n" cap desc)))))
            (princ "\n")))))))

;;;###autoload
(defun lexdb-list-adapters-command ()
  "Display all registered dictionary adapters."
  (interactive)
  (let ((adapters (lexdb-list-adapters)))
    (if (null adapters)
        (message "No dictionary adapters registered")
      (with-help-window "*Lexdb Adapters*"
        (princ "Registered Dictionary Adapters:\n\n")
        (dolist (pair adapters)
          (let* ((id (car pair))
                 (adapter (cdr pair))
                 (current (eq id lexdb-current-adapter)))
            (princ (format "%s %s\n"
                           (if current "▶" " ")
                           (lexdb-adapter-name adapter)))
            (princ (format "    ID: %s\n" id))
            (when (lexdb-adapter-version adapter)
              (princ (format "    Version: %s\n" (lexdb-adapter-version adapter))))
            (princ (format "    Capabilities: %d\n"
                           (length (lexdb-adapter-capabilities adapter))))
            (princ "\n")))))))

;;;; ============================================================
;;;; Utility Commands
;;;; ============================================================

(declare-function lexdb-ui--play-audio "lexdb-ui")

;;;###autoload
(defun lexdb-play-pronunciation (&optional variant)
  "Play pronunciation of the last searched word.
VARIANT can be \\='uk or \\='us (default: \\='uk)."
  (interactive)
  (unless lexdb--last-word
    (user-error "No word searched yet"))
  (require 'lexdb-ui)
  (let* ((adapter-id (lexdb--ensure-adapter))
         (adapter (lexdb-get-adapter adapter-id))
         (entries (lexdb-lookup lexdb--last-word adapter-id))
         (variant (or variant 'uk)))
    (if (null entries)
        (message "No entry found for: %s" lexdb--last-word)
      (let* ((entry (car entries))
             (prons (lexdb-entry-pronunciations entry))
             (pron (seq-find (lambda (p) (eq (lexdb-pronunciation-variant p) variant))
                             prons)))
        (if (and pron (lexdb-pronunciation-audio pron))
            (lexdb-ui--play-audio (lexdb-pronunciation-audio pron)
                                  (lexdb-adapter-audio-dir adapter))
          (message "No %s audio for: %s" variant lexdb--last-word))))))

;;;###autoload
(defun lexdb-play-uk ()
  "Play UK pronunciation of the last searched word."
  (interactive)
  (lexdb-play-pronunciation 'uk))

;;;###autoload
(defun lexdb-play-us ()
  "Play US pronunciation of the last searched word."
  (interactive)
  (lexdb-play-pronunciation 'us))

;;;; ============================================================
;;;; Generic Adapter (通用适配器)
;;;; ============================================================

;; Generic adapter for any dictionary that follows the LexDB schema.
;; No need to write a separate .el file - just configure and use.

(defvar lexdb-generic--connections (make-hash-table :test 'equal)
  "Hash table mapping db-file paths to SQLite connections.")

(defvar lexdb-generic--caches (make-hash-table :test 'equal)
  "Hash table mapping adapter-id to data cache.")

(defun lexdb-generic--ensure-db (db-file)
  "Ensure database connection for DB-FILE is open."
  (or (gethash db-file lexdb-generic--connections)
      (let ((db (sqlite-open db-file)))
        (puthash db-file db lexdb-generic--connections)
        db)))

(defun lexdb-generic--close-db (db-file adapter-id)
  "Close database connection for DB-FILE and clear cache for ADAPTER-ID."
  (when-let ((db (gethash db-file lexdb-generic--connections)))
    (when (sqlitep db)
      (sqlite-close db))
    (remhash db-file lexdb-generic--connections))
  (remhash adapter-id lexdb-generic--caches))

(defun lexdb-generic--get-cache (adapter-id)
  "Get or create cache for ADAPTER-ID."
  (or (gethash adapter-id lexdb-generic--caches)
      (let ((cache (make-hash-table :test 'equal)))
        (puthash adapter-id cache lexdb-generic--caches)
        cache)))

(defun lexdb-generic--row-to-sense (sense-row db show-chinese)
  "Convert SENSE-ROW to lexdb-sense using DB.
SHOW-CHINESE controls whether to include Chinese translations."
  (pcase-let ((`(,id ,sense-num ,signpost ,definition ,definition-zh ,_sort) sense-row))
    (let* ((ex-rows (sqlite-select db
                     "SELECT text, text_zh, audio_path FROM examples WHERE sense_id = ? ORDER BY position, sort_order"
                     (list id)))
           (examples (mapcar (lambda (ex)
                               (lexdb-example-create
                                :text (nth 0 ex)
                                :metadata (when (and show-chinese (lexdb--non-empty-string-p (nth 1 ex)))
                                            `((zh . ,(nth 1 ex))))
                                :audio (nth 2 ex)))
                             ex-rows))
           ;; Get grammar patterns
           (gp-rows (sqlite-select db
                     "SELECT id, pattern, gloss FROM grammar_patterns WHERE sense_id = ? ORDER BY sort_order"
                     (list id)))
           (grammar-patterns (mapcar (lambda (gp)
                                       (pcase-let ((`(,gp-id ,pattern ,gloss) gp))
                                         (let ((gp-ex-rows (sqlite-select db
                                                            "SELECT text FROM grammar_pattern_examples WHERE pattern_id = ? ORDER BY sort_order"
                                                            (list gp-id))))
                                           (lexdb-grammar-pattern-create
                                            :pattern pattern
                                            :gloss gloss
                                            :examples (mapcar (lambda (e) (lexdb-example-create :text (car e)))
                                                              gp-ex-rows)))))
                                     gp-rows))
           ;; Get labels
           (label-rows (sqlite-select db
                        "SELECT label_type, label_value FROM labels WHERE sense_id = ? ORDER BY sort_order"
                        (list id)))
           (labels (mapcar (lambda (l)
                             (lexdb-label-create :type (intern (car l)) :value (cadr l)))
                           label-rows)))
      (lexdb-sense-create
       :id id
       :number sense-num
       :signpost signpost
       :definition definition
       :examples examples
       :grammar-patterns grammar-patterns
       :labels labels
       :metadata (when (and show-chinese (lexdb--non-empty-string-p definition-zh))
                   `((zh . ,definition-zh)))))))

(defun lexdb-generic--row-to-entry (entry-row db dict-id show-chinese)
  "Convert ENTRY-ROW to lexdb-entry using DB.
DICT-ID is used for querying related data.
SHOW-CHINESE controls whether to include Chinese translations."
  (pcase-let ((`(,id ,_dict ,headword ,_hw-lower ,hw-display) entry-row))
    (let* (;; Get senses
           (sense-rows (sqlite-select db
                        "SELECT id, sense_number, signpost, definition, definition_zh, sort_order
                         FROM senses WHERE entry_id = ? ORDER BY sort_order"
                        (list id)))
           (senses (mapcar (lambda (s) (lexdb-generic--row-to-sense s db show-chinese))
                           sense-rows))
           ;; Get pronunciations
           (pron-rows (sqlite-select db
                       "SELECT ipa, variant, audio_path FROM pronunciations WHERE entry_id = ? ORDER BY sort_order"
                       (list id)))
           (pronunciations (mapcar (lambda (p)
                                     (lexdb-pronunciation-create
                                      :ipa (nth 0 p)
                                      :variant (when (nth 1 p) (intern (nth 1 p)))
                                      :audio (nth 2 p)))
                                   pron-rows))
           ;; Get entry-level labels (POS etc)
           (entry-labels (sqlite-select db
                          "SELECT label_type, label_value FROM labels WHERE entry_id = ? AND sense_id IS NULL ORDER BY sort_order"
                          (list id)))
           ;; Get metadata from entry_attributes
           (attr-rows (sqlite-select db
                       "SELECT attr_key, attr_value FROM entry_attributes WHERE entry_id = ?"
                       (list id)))
           (metadata (mapcar (lambda (a) (cons (intern (car a)) (cadr a))) attr-rows)))
      ;; Add entry-level labels to metadata
      (dolist (l entry-labels)
        (push (cons (intern (format "label/%s" (car l))) (cadr l)) metadata))
      (lexdb-entry-create
       :id id
       :headword headword
       :headword-display hw-display
       :senses senses
       :pronunciations pronunciations
       :metadata metadata))))

(defun lexdb-generic--lookup (word db-file dict-id show-chinese)
  "Look up WORD in database at DB-FILE with DICT-ID.
SHOW-CHINESE controls whether to include Chinese translations."
  (let* ((db (lexdb-generic--ensure-db db-file))
         (word-lower (downcase word))
         ;; First try exact match
         (rows (sqlite-select db
                "SELECT id, dict_id, headword, headword_lower, headword_display
                 FROM entries WHERE headword_lower = ? AND dict_id = ?"
                (list word-lower dict-id))))
    ;; If no results, try prefix match
    (unless rows
      (setq rows (sqlite-select db
                  "SELECT id, dict_id, headword, headword_lower, headword_display
                   FROM entries WHERE headword_lower LIKE ? AND dict_id = ? LIMIT 20"
                  (list (concat word-lower "%") dict-id))))
    (mapcar (lambda (r) (lexdb-generic--row-to-entry r db dict-id show-chinese)) rows)))

(defun lexdb-generic--find-lemma (word db-file dict-id)
  "Try to find lemma/base form for WORD using DB-FILE with DICT-ID."
  (let ((db (lexdb-generic--ensure-db db-file))
        (word-lower (downcase word)))
    ;; Check lemmas table if exists
    (when-let ((row (car (sqlite-select db
                          "SELECT lemma FROM lemmas WHERE inflected = ? AND dict_id = ?"
                          (list word-lower dict-id)))))
      (car row))))

(defun lexdb-generic--get-collocations (entry-id db-file adapter-id)
  "Get collocations for ENTRY-ID from DB-FILE."
  (let ((cache (lexdb-generic--get-cache adapter-id)))
    (or (gethash (cons entry-id 'collocations) cache)
        (let* ((db (lexdb-generic--ensure-db db-file))
               (rows (sqlite-select db
                      "SELECT id, category, text, gloss FROM collocations WHERE entry_id = ? ORDER BY sort_order"
                      (list entry-id)))
               (colls (mapcar (lambda (row)
                                (pcase-let ((`(,coll-id ,cat ,coll ,gloss) row))
                                  (let ((ex-rows (sqlite-select db
                                                  "SELECT text FROM collocation_examples WHERE collocation_id = ? ORDER BY sort_order"
                                                  (list coll-id))))
                                    (lexdb-collocation-create
                                     :category cat :text coll :gloss gloss
                                     :examples (mapcar #'car ex-rows)))))
                              rows)))
          (puthash (cons entry-id 'collocations) colls cache)
          colls))))

(defun lexdb-generic--get-relations (entry-id type db-file adapter-id)
  "Get relations of TYPE for ENTRY-ID from DB-FILE."
  (let* ((db (lexdb-generic--ensure-db db-file))
         (rows (sqlite-select db
                "SELECT target_text, target_link FROM relations WHERE entry_id = ? AND relation_type = ? ORDER BY sort_order"
                (list entry-id (symbol-name type)))))
    (mapcar (lambda (row)
              (pcase-let ((`(,target ,link) row))
                (lexdb-relation-create
                 :type type
                 :target target
                 :target-link (when (lexdb--non-empty-string-p link) link))))
            rows)))

(defun lexdb-generic--detect-capabilities (db-file dict-id)
  "Detect capabilities by checking database content for DICT-ID in DB-FILE."
  (let ((db (lexdb-generic--ensure-db db-file))
        (caps '(lookup definition)))
    ;; Check for pronunciations
    (when (car (sqlite-select db
                "SELECT 1 FROM pronunciations p JOIN entries e ON p.entry_id = e.id
                 WHERE e.dict_id = ? LIMIT 1" (list dict-id)))
      (push 'pronunciation caps))
    ;; Check for audio
    (when (car (sqlite-select db
                "SELECT 1 FROM pronunciations p JOIN entries e ON p.entry_id = e.id
                 WHERE e.dict_id = ? AND p.audio_path IS NOT NULL AND p.variant = 'uk' LIMIT 1"
                (list dict-id)))
      (push 'audio-uk caps))
    (when (car (sqlite-select db
                "SELECT 1 FROM pronunciations p JOIN entries e ON p.entry_id = e.id
                 WHERE e.dict_id = ? AND p.audio_path IS NOT NULL AND p.variant = 'us' LIMIT 1"
                (list dict-id)))
      (push 'audio-us caps))
    ;; Check for examples
    (when (car (sqlite-select db
                "SELECT 1 FROM examples ex JOIN senses s ON ex.sense_id = s.id
                 JOIN entries e ON s.entry_id = e.id WHERE e.dict_id = ? LIMIT 1"
                (list dict-id)))
      (push 'examples caps))
    ;; Check for collocations
    (when (car (sqlite-select db
                "SELECT 1 FROM collocations c JOIN entries e ON c.entry_id = e.id
                 WHERE e.dict_id = ? LIMIT 1" (list dict-id)))
      (push 'collocations caps))
    ;; Check for lemmas
    (when (car (sqlite-select db
                "SELECT 1 FROM lemmas WHERE dict_id = ? LIMIT 1" (list dict-id)))
      (push 'lemmatization caps))
    ;; Check for Chinese translations
    (when (car (sqlite-select db
                "SELECT 1 FROM senses s JOIN entries e ON s.entry_id = e.id
                 WHERE e.dict_id = ? AND s.definition_zh IS NOT NULL LIMIT 1"
                (list dict-id)))
      (push 'chinese caps))
    (nreverse caps)))

(defun lexdb-generic--register-from-config (config)
  "Register generic adapter from CONFIG plist.
CONFIG should contain:
  :id        - Adapter ID (required)
  :name      - Display name (optional)
  :db-file   - Path to SQLite database (required)
  :dict-id   - Dictionary ID in database (optional, defaults to adapter id)
  :audio-dir - Audio directory (optional)
  :show-chinese - Whether to show Chinese translations (default t)"
  (let* ((id (plist-get config :id))
         (name (or (plist-get config :name) (symbol-name id)))
         (db-file (expand-file-name (plist-get config :db-file)))
         (dict-id (or (plist-get config :dict-id) (symbol-name id)))
         (audio-dir (when-let ((dir (plist-get config :audio-dir)))
                      (expand-file-name dir)))
         (show-chinese (if (plist-member config :show-chinese)
                           (plist-get config :show-chinese)
                         t))
         (caps (lexdb-generic--detect-capabilities db-file dict-id)))
    (unless db-file
      (error "Generic adapter config missing :db-file"))
    (unless (file-exists-p db-file)
      (error "Database file not found: %s" db-file))
    (lexdb-register-adapter
     (lexdb-adapter-create
      :id id
      :name name
      :capabilities caps
      :db-file db-file
      :audio-dir audio-dir
      :lookup-fn (lambda (word)
                   (lexdb-generic--lookup word db-file dict-id show-chinese))
      :close-fn (lambda ()
                  (lexdb-generic--close-db db-file id))
      :collocations-fn (when (memq 'collocations caps)
                         (lambda (entry-id)
                           (lexdb-generic--get-collocations entry-id db-file id)))
      :relations-fn (lambda (entry-id type)
                      (lexdb-generic--get-relations entry-id type db-file id))
      :lemma-fn (when (memq 'lemmatization caps)
                  (lambda (word)
                    (lexdb-generic--find-lemma word db-file dict-id)))))))

;; Register 'generic adapter type
(lexdb-register-adapter-type 'generic #'lexdb-generic--register-from-config)

;;;; ============================================================
;;;; External API (for integration with other packages)
;;;; ============================================================

(defun lexdb-word-exists-p (word &optional adapter-id)
  "Check if WORD exists in the dictionary."
  (not (null (lexdb-lookup word adapter-id))))

(defun lexdb-get-entry (word &optional adapter-id)
  "Get the first entry for WORD, or nil if not found.
Returns a lexdb-entry struct."
  (car (lexdb-lookup word adapter-id)))

(defun lexdb-get-definitions (word &optional adapter-id)
  "Get list of definition strings for WORD."
  (when-let ((entry (lexdb-get-entry word adapter-id)))
    (mapcar #'lexdb-sense-definition (lexdb-entry-senses entry))))

(provide 'lexdb)
;;; lexdb.el ends here
