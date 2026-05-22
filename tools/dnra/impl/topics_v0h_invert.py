# INVERT-polarity variant of topics_v0h: same 252 RFC sections, flipped
# polarity so the runner uses build_user_msg_invert.
from tools.dnra.impl.topics_v0h import TOPICS as _KEEP

TOPICS: list[tuple[int, str, str]] = [(r, s, "invert") for (r, s, _p) in _KEEP]
