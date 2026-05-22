# Small invert-polarity smoke list.  Each section has known SHOULD/MAY
# language that the invert template should anchor on.
TOPICS: list[tuple[int, str, str]] = [
    (8259, "4", "invert"),    # JSON: "names within an object SHOULD be unique" (not MUST)
    (8259, "6", "invert"),    # JSON: numbers -- interop recommendation (not requirement)
    (8446, "1.3", "invert"),  # TLS 1.3: removed static RSA; people assume RSA-KEX still works
]
