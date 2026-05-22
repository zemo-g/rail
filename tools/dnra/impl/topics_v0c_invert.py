# INVERT-polarity variant of topics_v0c: same 43 RFC sections, but each
# fed through the build_user_msg_invert template so the corpus also
# trains the SHOULD-vs-MUST / MAY-vs-MUST distinction.
#
# Sections whose strongest modal is itself MUST/SHALL will yield empty
# pairs (the invert template includes a sentinel for this); those count
# as SKIP_EMPTY in the run summary, not FAIL.

from tools.dnra.impl.topics_v0c import TOPICS as _KEEP

TOPICS: list[tuple[int, str, str]] = [(r, s, "invert") for (r, s, _p) in _KEEP]
