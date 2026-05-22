# INVERT-polarity variant of topics_v0d: same 216 RFC sections, flipped
# polarity so the runner uses build_user_msg_invert.
from tools.dnra.impl.topics_v0d import TOPICS as _KEEP

TOPICS: list[tuple[int, str, str]] = [(r, s, "invert") for (r, s, _p) in _KEEP]
