"""POSIX.1-2017 topic list for the citation-verified draft loop (v0.f).

Each topic is (function_name, section_header, polarity).  The draft loop
will repurpose the existing tuple shape (originally (rfc_int, section,
polarity)) by treating the first element as a string when the source
prefix is "POSIX".  The verifier routes any source string matching
"POSIX" + a section field like "<func>" or "<func> / <SECTION>" through
impl/sources/posix.get_section.

All entries are "keep" polarity for v0.f.  INVERT is harder on POSIX
(most clauses use "shall" — a hard-MUST) and not worth the complication
right now.

Curation rule: every (func, section) below was smoke-fetched against
the live Open Group pages before inclusion; sections that 404'd,
returned None, or returned <100 chars were dropped.

Skipped (returned too short / stub-bundled):
    getpid/DESCRIPTION (73 chars — bundled with getppid)
    getppid/DESCRIPTION (81 chars — stub)
    sleep/ERRORS (63 chars)
"""

TOPICS: list[tuple[str, str, str]] = [
    # (function_name, section_header, polarity)

    # --- File I/O ---
    ("open", "DESCRIPTION", "keep"),
    ("open", "ERRORS", "keep"),
    ("close", "DESCRIPTION", "keep"),
    ("close", "ERRORS", "keep"),
    ("read", "DESCRIPTION", "keep"),
    ("read", "ERRORS", "keep"),
    ("write", "DESCRIPTION", "keep"),
    ("write", "ERRORS", "keep"),
    ("lseek", "DESCRIPTION", "keep"),
    ("lseek", "ERRORS", "keep"),
    ("dup", "DESCRIPTION", "keep"),
    ("dup", "ERRORS", "keep"),
    ("dup2", "DESCRIPTION", "keep"),
    ("dup2", "ERRORS", "keep"),
    ("fcntl", "DESCRIPTION", "keep"),
    ("fcntl", "ERRORS", "keep"),
    ("fstat", "DESCRIPTION", "keep"),
    ("fstat", "ERRORS", "keep"),

    # --- Process control ---
    ("fork", "DESCRIPTION", "keep"),
    ("fork", "ERRORS", "keep"),
    ("exec", "DESCRIPTION", "keep"),
    ("exec", "ERRORS", "keep"),
    ("wait", "DESCRIPTION", "keep"),
    ("wait", "ERRORS", "keep"),
    ("waitpid", "DESCRIPTION", "keep"),
    ("_exit", "DESCRIPTION", "keep"),
    ("kill", "DESCRIPTION", "keep"),
    ("kill", "ERRORS", "keep"),

    # --- Threads ---
    ("pthread_create", "DESCRIPTION", "keep"),
    ("pthread_create", "ERRORS", "keep"),
    ("pthread_join", "DESCRIPTION", "keep"),
    ("pthread_join", "ERRORS", "keep"),
    ("pthread_mutex_lock", "DESCRIPTION", "keep"),
    ("pthread_mutex_lock", "ERRORS", "keep"),

    # --- Signals ---
    ("sigaction", "DESCRIPTION", "keep"),
    ("sigaction", "ERRORS", "keep"),
    ("sigprocmask", "DESCRIPTION", "keep"),
    ("sigprocmask", "ERRORS", "keep"),
    ("signal", "DESCRIPTION", "keep"),

    # --- IO sync / truncation ---
    ("fsync", "DESCRIPTION", "keep"),
    ("fsync", "ERRORS", "keep"),
    ("fdatasync", "DESCRIPTION", "keep"),
    ("fdatasync", "ERRORS", "keep"),
    ("ftruncate", "DESCRIPTION", "keep"),
    ("ftruncate", "ERRORS", "keep"),

    # --- Misc filesystem / memory / system ---
    ("stat", "DESCRIPTION", "keep"),
    ("stat", "ERRORS", "keep"),
    ("unlink", "DESCRIPTION", "keep"),
    ("unlink", "ERRORS", "keep"),
    ("rename", "DESCRIPTION", "keep"),
    ("rename", "ERRORS", "keep"),
    ("mmap", "DESCRIPTION", "keep"),
    ("mmap", "ERRORS", "keep"),
    ("sysconf", "DESCRIPTION", "keep"),
]
