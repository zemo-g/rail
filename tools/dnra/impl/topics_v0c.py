# Curated v0.c topic list: ~40 RFC sections selected for strong quotable clauses.
# Each (rfc_num, section_id, polarity) tuple feeds draft_and_verify.py.
# Polarity is "keep" for now; "invert" variants will be added later.
#
# Excludes the 6 smoke topics already in draft_and_verify.TOPICS:
#   (8259,"3"), (8259,"5"), (7540,"6.5"), (7540,"8.2"),
#   (8446,"4.4.2"), (8446,"5.1")
#
# Selection criteria (verified by reading each section in the cache):
#   - contains at least one strong quotable clause (MUST/SHOULD/MAY/MUST NOT,
#     "is defined", "is not", "shall", or a sharp definitional sentence)
#   - bounded (short paragraph(s), not whole-chapter)
#   - admits a clean yes/no or is-X-Y question
#   - not pure prose / not tables / not ABNF-only / not references

TOPICS: list[tuple[int, str, str]] = [
    # ---------- RFC 8259 (JSON) ----------
    # 1.1 Conventions -- defines normative key-word interpretation
    (8259, "1.1", "keep"),
    # 2 JSON Grammar -- "A JSON text is a sequence of tokens" + structural chars
    (8259, "2", "keep"),
    # 4 Objects -- "names within an object SHOULD be unique"
    (8259, "4", "keep"),
    # 6 Numbers -- "Leading zeros are not allowed"; Infinity/NaN not permitted
    (8259, "6", "keep"),
    # 7 Strings -- characters that MUST be escaped (quote, solidus, controls)
    (8259, "7", "keep"),
    # 8.1 Character Encoding -- "MUST be encoded using UTF-8"; BOM forbidden
    (8259, "8.1", "keep"),
    # 8.2 Unicode Characters -- behavior on unpaired surrogates unpredictable
    (8259, "8.2", "keep"),
    # 8.3 String Comparison -- code-unit comparison interoperability rule
    (8259, "8.3", "keep"),
    # 9 Parsers -- "MUST accept all texts that conform to the JSON grammar"
    (8259, "9", "keep"),
    # 10 Generators -- "resulting text MUST strictly conform to the JSON grammar"
    (8259, "10", "keep"),
    # 12 Security Considerations -- eval() risk; assignment/invocation excluded
    (8259, "12", "keep"),

    # ---------- RFC 7540 (HTTP/2) ----------
    # 3.5 Connection Preface -- 24-octet preface MUST be followed by SETTINGS
    (7540, "3.5", "keep"),
    # 4.1 Frame Format -- length, type, flags; unknown types MUST be ignored
    (7540, "4.1", "keep"),
    # 4.2 Frame Size -- 2^14 minimum capability; FRAME_SIZE_ERROR on overflow
    (7540, "4.2", "keep"),
    # 5.1.1 Stream Identifiers -- client odd / server even MUST; monotonic
    (7540, "5.1.1", "keep"),
    # 5.1.2 Stream Concurrency -- endpoints MUST NOT exceed SETTINGS_MAX_*
    (7540, "5.1.2", "keep"),
    # 5.4.1 Connection Error Handling -- GOAWAY SHOULD + MUST close TCP
    (7540, "5.4.1", "keep"),
    # 5.4.2 Stream Error Handling -- MUST NOT send RST_STREAM in reply to RST
    (7540, "5.4.2", "keep"),
    # 6.7 PING -- 8 octets opaque; non-ACK PING MUST elicit ACK PING
    (7540, "6.7", "keep"),
    # 8.1.2.6 Malformed -- intermediaries MUST NOT forward malformed
    (7540, "8.1.2.6", "keep"),
    # 9.2.1 TLS 1.2 Features -- MUST disable compression + renegotiation
    (7540, "9.2.1", "keep"),

    # ---------- RFC 8446 (TLS 1.3) ----------
    # 1.1 Conventions -- defines client/server/handshake/peer terms + MUST etc.
    (8446, "1.1", "keep"),
    # 3.1 Basic Block Size -- "basic data block size is one byte (i.e., 8 bits)"
    (8446, "3.1", "keep"),
    # 3.3 Numbers -- big-endian network byte order definition
    (8446, "3.3", "keep"),
    # 4.2.1 Supported Versions -- ClientHello MUST send; selected_version rules
    (8446, "4.2.1", "keep"),
    # 4.4.3 Certificate Verify -- SHA-1 MUST NOT be used; RSA MUST use RSASSA-PSS
    (8446, "4.4.3", "keep"),
    # 4.4.4 Finished -- recipients MUST verify contents; MUST terminate on mismatch
    (8446, "4.4.4", "keep"),
    # 5.4 Record Padding -- padding octets MUST be zero; scan-from-end rule
    (8446, "5.4", "keep"),
    # 5.5 Limits on Key Usage -- SHOULD do key update before AEAD limits
    (8446, "5.5", "keep"),
    # 6.1 Closure Alerts -- close_notify MUST precede write-side close
    (8446, "6.1", "keep"),
    # 6.2 Error Alerts -- fatal alert -> both parties MUST immediately close
    (8446, "6.2", "keep"),
    # 9.3 Protocol Invariants -- middlebox/extensible-fields MUST-rules
    (8446, "9.3", "keep"),

    # ---------- RFC 1034 (DNS Concepts) ----------
    # 2.4 Elements of the DNS -- defines name servers, zones, resolvers
    (1034, "2.4", "keep"),
    # 3.5 Preferred name syntax -- labels must start with letter, <=63 chars
    (1034, "3.5", "keep"),
    # 3.6 Resource Records -- defines owner/type/class/TTL/RDATA fields
    (1034, "3.6", "keep"),
    # 3.6.2 Aliases / CNAME -- "If a CNAME RR is present at a node, no other
    # data should be present"
    (1034, "3.6.2", "keep"),
    # 3.7.1 Standard queries -- defines QNAME/QTYPE/QCLASS; QCLASS=* not authoritative
    (1034, "3.7.1", "keep"),
    # 3.7.2 Inverse queries -- "Inverse queries are NOT an acceptable method
    # for mapping host addresses to host names"
    (1034, "3.7.2", "keep"),
    # 4.2.1 Technical considerations -- zone authoritative data definition
    (1034, "4.2.1", "keep"),
    # 4.3.3 Wildcards -- "*" label always matches at least one whole label;
    # wildcards do not apply across zone cuts
    (1034, "4.3.3", "keep"),
    # 4.3.4 Negative response caching -- MINIMUM SOA field controls negative TTL
    (1034, "4.3.4", "keep"),
    # 4.3.5 Zone maintenance -- SERIAL always advances on change; REFRESH/RETRY/EXPIRE
    (1034, "4.3.5", "keep"),
    # 5.2.1 Typical functions -- defines name->addr, addr->name, general lookup
    (1034, "5.2.1", "keep"),
]
