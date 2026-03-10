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
(require 'json)

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

(defcustom lexdb-multi-dict-mode t
  "If non-nil, search all dictionaries and show with tabs.
If nil, search only the current/default dictionary."
  :type 'boolean
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
      (when-let* ((first-enabled (cl-find-if
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
      (when-let* ((pair (assq cap (cdr group))))
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
;;;; Generic Database Connection Module
;;;; ============================================================

(defvar lexdb--database-connections (make-hash-table :test 'eq)
  "Hash table of database connections keyed by adapter ID.")

(defvar lexdb--query-caches (make-hash-table :test 'eq)
  "Hash table of query caches keyed by adapter ID.")

(defvar lexdb--active-adapter nil
  "Adapter currently executing an adapter callback.")

(defun lexdb-db-ensure (adapter-id db-file)
  "Ensure database connection for ADAPTER-ID using DB-FILE.
Returns the database connection."
  (unless db-file
    (error "No database file configured for %s" adapter-id))
  (unless (file-exists-p db-file)
    (error "Database file not found: %s" db-file))
  (let ((db (gethash adapter-id lexdb--database-connections)))
    (unless (and db (sqlitep db))
      (setq db (sqlite-open db-file))
      (puthash adapter-id db lexdb--database-connections)
      ;; Initialize cache for this adapter if needed
      (unless (gethash adapter-id lexdb--query-caches)
        (puthash adapter-id (make-hash-table :test 'eql) lexdb--query-caches)))
    db))

(defun lexdb-db-get (adapter-id)
  "Get database connection for ADAPTER-ID.
Returns nil if not connected."
  (gethash adapter-id lexdb--database-connections))

(defun lexdb-db-close (adapter-id)
  "Close database connection and clear cache for ADAPTER-ID."
  (when-let* ((db (gethash adapter-id lexdb--database-connections)))
    (when (sqlitep db)
      (sqlite-close db))
    (remhash adapter-id lexdb--database-connections))
  (when-let* ((cache (gethash adapter-id lexdb--query-caches)))
    (clrhash cache)))

(defun lexdb-db-cache-get (adapter-id key)
  "Get VALUE for KEY from ADAPTER-ID's cache."
  (when-let* ((cache (gethash adapter-id lexdb--query-caches)))
    (gethash key cache)))

(defun lexdb-db-cache-put (adapter-id key value)
  "Store VALUE for KEY in ADAPTER-ID's cache."
  (let ((cache (or (gethash adapter-id lexdb--query-caches)
                   (let ((new-cache (make-hash-table :test 'eql)))
                     (puthash adapter-id new-cache lexdb--query-caches)
                     new-cache))))
    (puthash key value cache)
    value))

;;;; ============================================================
;;;; Shared Data Processing Functions
;;;; ============================================================

(defun lexdb--decompress-json-value (compressed-data)
  "Decompress zlib-compressed JSON COMPRESSED-DATA and parse it.
Returns nil on error or if data is empty."
  (when (and compressed-data (not (string-empty-p compressed-data)))
    (condition-case nil
        (let ((decompressed
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert compressed-data)
                 (zlib-decompress-region (point-min) (point-max))
                 (buffer-string))))
          (json-read-from-string (decode-coding-string decompressed 'utf-8)))
      (error nil))))

(defun lexdb--build-pronunciations-from-db (entry-id db)
  "Build pronunciation list for ENTRY-ID from DB.
Uses standard pronunciations table schema.
Returns pronunciations that have either IPA or audio path."
  (let ((rows (sqlite-select db
               "SELECT variant, ipa, audio_path FROM pronunciations WHERE entry_id = ? ORDER BY sort_order"
               (list entry-id))))
    (delq nil
          (mapcar (lambda (row)
                    (pcase-let ((`(,variant ,ipa ,audio) row))
                      (when (or (lexdb--non-empty-string-p ipa)
                                (lexdb--non-empty-string-p audio))
                        (lexdb-pronunciation-create
                         :ipa ipa
                         :variant (when variant (intern variant))
                         :audio (when (lexdb--non-empty-string-p audio) audio)))))
                  rows))))

;;;; ============================================================
;;;; Common Lemmatization
;;;; ============================================================

(defconst lexdb-lemma-rules
  '(;; -ing forms (progressive/gerund)
    ("ing" . "")        ; running -> runn -> run
    ("ing" . "e")       ; making -> mak -> make
    ("ning" . "n")      ; running -> run
    ("ting" . "t")      ; hitting -> hit
    ("ping" . "p")      ; stopping -> stop
    ("bing" . "b")      ; robbing -> rob
    ("ging" . "g")      ; hugging -> hug
    ("ming" . "m")      ; swimming -> swim
    ("ding" . "d")      ; bidding -> bid

    ;; -ed forms (past tense/past participle)
    ("ed" . "")         ; walked -> walk
    ("ed" . "e")        ; liked -> lik -> like
    ("ied" . "y")       ; tried -> tri -> try
    ("ned" . "n")       ; tanned -> tan
    ("ted" . "t")       ; patted -> pat
    ("ped" . "p")       ; stopped -> stop
    ("bed" . "b")       ; robbed -> rob
    ("ged" . "g")       ; hugged -> hug
    ("med" . "m")       ; trimmed -> trim
    ("ded" . "d")       ; padded -> pad

    ;; Plural/third person singular
    ("s" . "")          ; cats -> cat
    ("es" . "")         ; boxes -> box
    ("ies" . "y")       ; tries -> tr -> try

    ;; Comparative/superlative
    ("er" . "")         ; taller -> tall
    ("er" . "e")        ; nicer -> nic -> nice
    ("ier" . "y")       ; happier -> happi -> happy
    ("est" . "")        ; tallest -> tall
    ("est" . "e")       ; nicest -> nic -> nice
    ("iest" . "y")      ; happiest -> happi -> happy

    ;; Adverbs
    ("ly" . "")         ; quickly -> quick
    ("ily" . "y")       ; happily -> happ -> happy

    ;; Possessive
    ("'s" . ""))        ; John's -> John
  "Common English lemmatization rules.
Each element is (SUFFIX . REPLACEMENT) pair.")

(defun lexdb--try-lemma (word suffix replacement lookup-fn)
  "Try removing SUFFIX from WORD and adding REPLACEMENT.
LOOKUP-FN is called to check if the candidate exists in dictionary.
Returns the candidate if found, nil otherwise."
  (when (and (> (length word) (length suffix))
             (string-suffix-p suffix word))
    (let ((candidate (concat (substring word 0 (- (length word) (length suffix)))
                             replacement)))
      (when (and (> (length candidate) 1)
                 (funcall lookup-fn candidate))
        candidate))))

(defun lexdb--find-lemma-with-lookup (word lookup-fn)
  "Find base form of WORD using LOOKUP-FN to check candidates.
LOOKUP-FN should be a function that returns non-nil if a word exists.
Returns the lemma if found, WORD otherwise."
  (let ((w (downcase word)))
    (if (funcall lookup-fn w)
        w
      (or (cl-loop for (suffix . replacement) in lexdb-lemma-rules
                   thereis (lexdb--try-lemma w suffix replacement lookup-fn))
          w))))

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
          :documentation "Non-clickable prefix (e.g., `see THESAURUS at `)")
  (clickable nil
             :type string
             :documentation "Clickable part (required)")
  (suffix nil
          :type (or string null)
          :documentation "Non-clickable suffix (e.g., ` (v.)`)")
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

(defvar lexdb-display-entry-function nil
  "Function used to display a single dictionary result buffer.")

(defvar lexdb-display-multi-function nil
  "Function used to display multi-dictionary search results.")

(defvar lexdb-play-audio-function nil
  "Function used to play audio from the UI layer.")

(defun lexdb-register-ui-handlers (&rest plist)
  "Register UI callback functions from PLIST.
Supported keys are `:display-entry', `:display-multi', and `:play-audio'."
  (setq lexdb-display-entry-function
        (plist-get plist :display-entry)
        lexdb-display-multi-function
        (plist-get plist :display-multi)
        lexdb-play-audio-function
        (plist-get plist :play-audio)))

(defun lexdb--call-with-adapter (adapter fn &rest args)
  "Call FN with ARGS while binding ADAPTER as the active adapter."
  (let ((lexdb--active-adapter adapter))
    (apply fn args)))

(defun lexdb--active-adapter-id (&optional fallback-id)
  "Return the active adapter ID, or FALLBACK-ID when no adapter is bound."
  (or (and lexdb--active-adapter
           (lexdb-adapter-id lexdb--active-adapter))
      fallback-id))

(defun lexdb--active-adapter-db-file (&optional fallback-file)
  "Return the active adapter DB file, or FALLBACK-FILE when not bound."
  (or (and lexdb--active-adapter
           (lexdb-adapter-db-file lexdb--active-adapter))
      fallback-file))

(defun lexdb--active-adapter-audio-dir (&optional fallback-dir)
  "Return the active adapter audio dir, or FALLBACK-DIR when not bound."
  (or (and lexdb--active-adapter
           (lexdb-adapter-audio-dir lexdb--active-adapter))
      fallback-dir))

(defun lexdb--display-entry (word entries adapter &optional no-lemma-hint)
  "Display WORD ENTRIES for ADAPTER, optionally skipping lemma hints."
  (unless (functionp lexdb-display-entry-function)
    (user-error "No lexdb UI registered. Load `lexdb-ui' before searching"))
  (funcall lexdb-display-entry-function word entries adapter no-lemma-hint))

(defun lexdb--display-multi (word)
  "Display WORD across all enabled dictionaries."
  (unless (functionp lexdb-display-multi-function)
    (user-error "No lexdb UI registered. Load `lexdb-ui' before searching"))
  (funcall lexdb-display-multi-function word))

(defun lexdb--play-audio (path &optional audio-dir)
  "Play PATH using AUDIO-DIR through the registered UI audio handler."
  (unless (functionp lexdb-play-audio-function)
    (user-error "No lexdb UI registered. Load `lexdb-ui' before playing audio"))
  (funcall lexdb-play-audio-function path audio-dir))

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
  (when-let* ((adapter (gethash id lexdb-adapters)))
    (when (lexdb-adapter-close-fn adapter)
      (lexdb--call-with-adapter adapter (lexdb-adapter-close-fn adapter)))
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
    (lexdb--call-with-adapter adapter (lexdb-adapter-lookup-fn adapter) word)))

(defun lexdb-get-pronunciations (entry-id &optional adapter-id)
  "Get pronunciations for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'pronunciation)
               (lexdb-adapter-pronunciations-fn adapter))
      (lexdb--call-with-adapter adapter
                                (lexdb-adapter-pronunciations-fn adapter)
                                entry-id))))

(defun lexdb-get-collocations (entry-id &optional adapter-id)
  "Get collocations for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'collocations)
               (lexdb-adapter-collocations-fn adapter))
      (lexdb--call-with-adapter adapter
                                (lexdb-adapter-collocations-fn adapter)
                                entry-id))))

(defun lexdb-get-relations (entry-id type &optional adapter-id)
  "Get relations of TYPE for ENTRY-ID."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter (lexdb-adapter-relations-fn adapter))
      (lexdb--call-with-adapter adapter
                                (lexdb-adapter-relations-fn adapter)
                                entry-id type))))

(defun lexdb-find-lemma (word &optional adapter-id)
  "Find lemma/base form of WORD."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter
               (lexdb-adapter-has-capability-p adapter 'lemmatization)
               (lexdb-adapter-lemma-fn adapter))
      (lexdb--call-with-adapter adapter (lexdb-adapter-lemma-fn adapter) word))))

(defun lexdb-prefetch (entry-ids &optional adapter-id)
  "Prefetch data for ENTRY-IDS to avoid N+1 queries."
  (let* ((id (or adapter-id lexdb-current-adapter))
         (adapter (lexdb-get-adapter id)))
    (when (and adapter (lexdb-adapter-prefetch-fn adapter))
      (lexdb--call-with-adapter adapter
                                (lexdb-adapter-prefetch-fn adapter)
                                entry-ids))))

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
      (when-let* ((label (lexdb-entry-get-label entry 'pos)))
        (lexdb-label-value label))))

(defun lexdb-sense-grammar (sense)
  "Get grammar annotation from SENSE."
  (when-let* ((label (seq-find (lambda (l) (eq (lexdb-label-type l) 'grammar))
                              (lexdb-sense-labels sense))))
    (lexdb-label-value label)))

;;;; ============================================================
;;;; State Management
;;;; ============================================================

(defvar lexdb--last-word nil
  "Last searched word.")

(defvar lexdb--search-history nil
  "Minibuffer history for `lexdb-search'.")

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
  (if lexdb-multi-dict-mode
      ;; Multi-dictionary mode: use the same buffer, update all dicts
      (lexdb--display-multi word)
    ;; Single dictionary mode
    (let* ((adapter-id (lexdb--ensure-adapter))
           (adapter (lexdb-get-adapter adapter-id))
           (entries (lexdb-lookup word adapter-id)))
      (unless entries
        (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
          (when-let* ((lemma (lexdb-find-lemma word adapter-id)))
            (unless (equal lemma (downcase word))
              (setq entries (lexdb-lookup lemma adapter-id))))))
      (lexdb--display-entry word entries adapter))))

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

;;;###autoload
(defun lexdb-search (word)
  "Search for WORD in dictionaries.
If `lexdb-multi-dict-mode' is non-nil, search all enabled dictionaries.
Otherwise, search only the current/default dictionary."
  (interactive (list (read-string "Lexdb: " (thing-at-point 'word t) 'lexdb--search-history)))
  (when (or (null word) (not (stringp word)) (string-empty-p word))
    (user-error "No word specified"))
  (setq lexdb--last-word word)
  (lexdb--history-push word)
  (if lexdb-multi-dict-mode
      ;; Multi-dictionary mode
      (lexdb--display-multi word)
    ;; Single dictionary mode
    (let* ((adapter-id (lexdb--ensure-adapter))
           (adapter (lexdb-get-adapter adapter-id))
           (entries (lexdb-lookup word adapter-id)))
      ;; Try lemmatization if no results
      (unless entries
        (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
          (when-let* ((lemma (lexdb-find-lemma word adapter-id)))
            (unless (equal lemma (downcase word))
              (setq entries (lexdb-lookup lemma adapter-id))
              (when entries
                (setq word lemma))))))
      (lexdb--display-entry word entries adapter))))

;;;###autoload
(defun lexdb-search-single (word)
  "Search for WORD in current dictionary only (single-dict mode)."
  (interactive
   (let* ((default (thing-at-point 'word t))
          (prompt (format "Lexdb [%s]: "
                          (or lexdb-current-adapter lexdb-default-adapter "?")))
          (input (read-string prompt nil 'lexdb--search-history default)))
     (list (if (string-empty-p input) default input))))
  (when (or (null word) (not (stringp word)) (string-empty-p word))
    (user-error "No word specified"))
  (setq lexdb--last-word word)
  (lexdb--history-push word)
  (let* ((adapter-id (lexdb--ensure-adapter))
         (adapter (lexdb-get-adapter adapter-id))
         (entries (lexdb-lookup word adapter-id)))
    (unless entries
      (when (lexdb-adapter-has-capability-p adapter 'lemmatization)
        (when-let* ((lemma (lexdb-find-lemma word adapter-id)))
          (unless (equal lemma (downcase word))
            (setq entries (lexdb-lookup lemma adapter-id))
            (when entries
              (setq word lemma))))))
    (lexdb--display-entry word entries adapter)))

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
        (let* ((group-name (car group))
               (enabled-caps (seq-filter (lambda (cap-pair) (memq (car cap-pair) caps))
                                         (cdr group))))
          (when enabled-caps
            (princ (format "  %s:\n" (upcase (symbol-name group-name))))
            (dolist (cap-pair enabled-caps)
              (princ (format "    ✓ %s - %s\n" (car cap-pair) (cdr cap-pair))))
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

;;;###autoload
(defun lexdb-play-pronunciation (&optional variant)
  "Play pronunciation of the last searched word.
VARIANT can be \\='uk or \\='us (default: \\='uk)."
  (interactive)
  (unless lexdb--last-word
    (user-error "No word searched yet"))
  (let* ((adapter-id (lexdb--ensure-adapter))
         (adapter (lexdb-get-adapter adapter-id))
         (entries (lexdb-lookup lexdb--last-word adapter-id))
         (variant (or variant 'uk)))
    (if (null entries)
        (message "No entry found for: %s" lexdb--last-word)
      (if-let* ((entry (car entries))
                (prons (lexdb-entry-pronunciations entry))
                (pron (seq-find (lambda (p) (eq (lexdb-pronunciation-variant p) variant))
                                prons))
                (audio (lexdb-pronunciation-audio pron)))
          (lexdb--play-audio audio (lexdb-adapter-audio-dir adapter))
        (message "No %s audio for: %s" variant lexdb--last-word)))))

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
  (when-let* ((entry (lexdb-get-entry word adapter-id)))
    (mapcar #'lexdb-sense-definition (lexdb-entry-senses entry))))

(provide 'lexdb)
;;; lexdb.el ends here
