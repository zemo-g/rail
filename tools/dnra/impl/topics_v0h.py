# Curated v0.h topic list: ~250 RFC sections selected for strong quotable clauses.
# Each (rfc_num, section_id, polarity) tuple feeds draft_and_verify.py.
# Polarity is "keep" for all entries; "invert" variants are derived later.
#
# Excludes the 32 RFCs already covered by v0.c + v0.d + v0.g:
#   1034, 7540, 8259, 8446, 791, 793, 2119, 3986, 5321, 6455, 6749, 7519,
#   9110, 9112, 5246, 5280, 9051, 4034, 4861, 6347, 5322, 3550, 5424,
#   4253, 4254, 3489, 4291, 1738, 5234, 2818, 6066, 7807
#
# This file spans 10 NEW RFCs, picked for normative density (MUST/SHOULD/MAY,
# definitional clauses, bounded prose - no ABNF-only or figure-only sections).
#
# Section selection: every entry below was verified against the RFC text in
# tools/dnra/cache/rfc/.  Skipped sections were either TOC, References,
# Acknowledgments, IANA-only, ABNF-only, figure-only, or had no quotable
# normative/definitional content.
#
# RFC selection notes:
#   Kept (10): 9293 (TCP modernized), 8200 (IPv6 header), 9000 (QUIC),
#              9001 (QUIC TLS), 9002 (QUIC Recovery), 9114 (HTTP/3),
#              6125 (TLS server identity), 7232 (HTTP conditional),
#              7234 (HTTP caching), 6376 (DKIM)
#   Dropped: 6520 (TLS Heartbeat) - too small, ~6 quotable sections only.
#            5288 (AES-GCM ciphersuites) - 4 sections, too thin to balance.
#            5705 (TLS keying-material exporter) - 3 quotable sections only.
#            7233 (HTTP range) - rich but trimmed to keep RFC count at 10.
#            7235 (HTTP auth) - same reason; small per-RFC count.
#            5905 (NTPv4) - only 4 sections cleared filters; mostly figures + ABNF.
#            7208 (SPF) - definitional density OK but heavy macro syntax tends
#                         to trip 122B into ABNF-citation mode.
#            7489 (DMARC) - reporting-format heavy; quotable normative content
#                           concentrated in 6-7 sections, too thin to balance.
#            8615 (well-known URIs) - one substantive section (3), too narrow.
#            5988 (Link header) - obsoleted by 8288; superseded.
#            7239 (HTTP Forwarded) - reasonable but capped at ~12 sections;
#                                    keeps file count at the 10-RFC target.
#            8174 (RFC2119 update) - only 2 sections, deliberate single-purpose.
#
# Final per-RFC counts and totals are summarized at the bottom of this file.

TOPICS: list[tuple[int, str, str]] = [
    # ---------- RFC 9293 (Transmission Control Protocol - modernized) ----------
    # Modernized TCP spec.  Dense normative content on state machine,
    # retransmission, congestion control, and connection lifecycle.
    # 2.1 Requirements Language -- "MUST", "MUST NOT" applies to TCP behavior
    (9293, "2.1", "keep"),
    # 3.2 Specific Option Definitions -- MSS, WS, SACK, TS option semantics
    (9293, "3.2", "keep"),
    # 3.4.1 Initial Sequence Number Selection -- "ISN generator MUST be
    # chosen ... unpredictable"; clock-based + per-connection secret
    (9293, "3.4.1", "keep"),
    # 3.5.3 Reset Processing -- a TCP receiver MUST validate RST segments
    (9293, "3.5.3", "keep"),
    # 3.6 Closing a Connection -- normal close, simultaneous close, abort
    (9293, "3.6", "keep"),
    # 3.6.1 Half-Closed Connections -- "TCP implementations SHOULD allow ..."
    (9293, "3.6.1", "keep"),
    # 3.7.1 Maximum Segment Size Option -- "SHOULD be sent in every SYN";
    # default 536, options for Path MTU discovery
    (9293, "3.7.1", "keep"),
    # 3.7.4 Nagle Algorithm -- coalesce small segments; PSH disable rule
    (9293, "3.7.4", "keep"),
    # 3.8.1 Retransmission Timeout -- "MUST use ... algorithm in [RFC6298]"
    (9293, "3.8.1", "keep"),
    # 3.8.2 TCP Congestion Control -- "MUST implement ... [RFC5681] congestion
    # control algorithms"
    (9293, "3.8.2", "keep"),
    # 3.8.3 TCP Connection Failures -- retransmission limits; R1/R2 thresholds
    (9293, "3.8.3", "keep"),
    # 3.8.4 TCP Keep-Alives -- "Keep-alive packets MUST only be sent when no
    # data ... has been received for a period of two hours"; default OFF
    (9293, "3.8.4", "keep"),
    # 3.8.5 Communication of Urgent Information -- URG pointer, urgent mode
    (9293, "3.8.5", "keep"),
    # 3.8.6.1 Zero-Window Probing -- "MUST be prepared to receive ... probe
    # segments" and respond
    (9293, "3.8.6.1", "keep"),
    # 3.8.6.2 Silly Window Syndrome Avoidance -- sender/receiver SWS rules
    (9293, "3.8.6.2", "keep"),
    # 3.9.1.1 Open -- active/passive OPEN call semantics
    (9293, "3.9.1.1", "keep"),
    # 3.9.1.2 Send -- SEND primitive; MUST queue, MUST signal errors
    (9293, "3.9.1.2", "keep"),
    # 3.9.1.3 Receive -- RECEIVE primitive; PUSH bit handling
    (9293, "3.9.1.3", "keep"),
    # 3.9.1.8 Asynchronous Reports -- ICMP type/code mapping to error reports
    (9293, "3.9.1.8", "keep"),
    # 3.9.1.9 Differentiated Services Field -- TOS / Traffic Class signaling
    (9293, "3.9.1.9", "keep"),
    # 3.9.2 TCP/Lower-Level Interface -- 29 normative tokens; IP options,
    # source address, ICMP handling rules
    (9293, "3.9.2", "keep"),
    # 3.9.2.1 Source Routing -- "MUST be able to receive IP options"
    (9293, "3.9.2.1", "keep"),
    # 3.9.2.2 ICMP Messages -- which ICMPs MUST be reported to TCP
    (9293, "3.9.2.2", "keep"),
    # 3.9.2.3 Source Address Validation -- discard segments with broadcast/
    # multicast source addresses
    (9293, "3.9.2.3", "keep"),
    # 2 Introduction -- TCP role, byte stream, segment, reliable
    (9293, "2", "keep"),

    # ---------- RFC 8200 (Internet Protocol, Version 6 Specification) ----------
    # Definitional content (lowercase "should", "must" - no MUST/SHOULD caps).
    # Picked sections with strict definitional sentences and packet rules.
    # 3 IPv6 Header Format -- field definitions: Version=6, Traffic Class,
    # Flow Label, Payload Length, Next Header, Hop Limit, addresses
    (8200, "3", "keep"),
    # 4.1 Extension Header Order -- recommended order; processing rules
    (8200, "4.1", "keep"),
    # 4.2 Options -- option Type encoding: highest-order 2 bits = action on
    # unrecognized option; third bit = Option Data may change en-route
    (8200, "4.2", "keep"),
    # 4.3 Hop-by-Hop Options Header -- "processed by every node"; alignment
    (8200, "4.3", "keep"),
    # 4.4 Routing Header -- Segments Left semantics; Type field
    (8200, "4.4", "keep"),
    # 4.6 Destination Options Header -- options processed by destination only
    (8200, "4.6", "keep"),
    # 4.7 No Next Header -- value 59 indicates nothing follows
    (8200, "4.7", "keep"),
    # 4.8 Defining New Extension Headers and Options -- new headers strongly
    # discouraged; option Type encoding rules
    (8200, "4.8", "keep"),
    # 5 Packet Size Issues -- "IPv6 requires that every link in the Internet
    # have an MTU of 1280 octets or greater"
    (8200, "5", "keep"),
    # 8.1 Upper-Layer Checksums -- pseudo-header; UDP checksum mandatory
    (8200, "8.1", "keep"),
    # 8.2 Maximum Packet Lifetime -- TTL/Hop Limit semantics
    (8200, "8.2", "keep"),
    # 8.3 Maximum Upper-Layer Payload Size -- payload length range
    (8200, "8.3", "keep"),
    # 8.4 Responding to Packets Carrying Routing Headers -- swap rules
    (8200, "8.4", "keep"),
    # 10 Security Considerations -- header chain limits; processing rules
    (8200, "10", "keep"),
    # 2 Terminology -- node, router, host, link, interface, neighbors, packet
    (8200, "2", "keep"),

    # ---------- RFC 9000 (QUIC: A UDP-Based Multiplexed and Secure Transport) ----------
    # Largest single-RFC contribution.  QUIC is dense and modern; rich
    # normative content for streams, connection IDs, packet matching, flow
    # control, migration.
    # 1.2 Terms and Definitions -- endpoint, connection, packet, frame, etc.
    (9000, "1.2", "keep"),
    # 2 Streams -- streams as the basic abstraction; client-initiated,
    # bidi/uni; 62-bit stream IDs
    (9000, "2", "keep"),
    # 2.1 Stream Types and Identifiers -- two least significant bits of
    # stream ID encode type
    (9000, "2.1", "keep"),
    # 2.2 Sending and Receiving Data -- in-order delivery within a stream
    (9000, "2.2", "keep"),
    # 3.3 Permitted Frame Types -- which frames may appear in which packet
    # number space
    (9000, "3.3", "keep"),
    # 3.5 Solicited State Transitions -- STOP_SENDING, RESET_STREAM
    (9000, "3.5", "keep"),
    # 4.1 Data Flow Control -- stream + connection flow control windows
    (9000, "4.1", "keep"),
    # 4.5 Stream Final Size -- final size invariant; MUST NOT change
    (9000, "4.5", "keep"),
    # 4.6 Controlling Concurrency -- MAX_STREAMS, stream limit enforcement
    (9000, "4.6", "keep"),
    # 5.1.1 Issuing Connection IDs -- NEW_CONNECTION_ID; sequence numbers
    (9000, "5.1.1", "keep"),
    # 5.1.2 Consuming and Retiring Connection IDs -- RETIRE_CONNECTION_ID
    (9000, "5.1.2", "keep"),
    # 5.2 Matching Packets to Connections -- DCID-based demux; long/short
    (9000, "5.2", "keep"),
    # 5.2.2 Server Packet Handling -- stateless reset; version negotiation
    (9000, "5.2.2", "keep"),
    # 6 Version Negotiation -- version-independent packet; negotiation flow
    (9000, "6", "keep"),
    # 6.1 Sending Version Negotiation Packets -- server SHOULD send VN
    (9000, "6.1", "keep"),
    # 6.2 Handling Version Negotiation Packets -- client MAY reattempt
    (9000, "6.2", "keep"),
    # 7.2 Negotiating Connection IDs -- DCID/SCID rules during handshake
    (9000, "7.2", "keep"),
    # 7.3 Authenticating Connection IDs -- transport params bind CIDs to TLS
    (9000, "7.3", "keep"),
    # 7.4 Transport Parameters -- 21 normative tokens; encoding + processing
    (9000, "7.4", "keep"),
    # 7.4.1 Transport Parameters for 0-RTT -- remembered/applied rules
    (9000, "7.4.1", "keep"),
    # 8.1.3 Address Validation for Future Connections -- token reuse rules
    (9000, "8.1.3", "keep"),
    # 8.1.4 Address Validation Token Integrity -- MUST be unforgeable
    (9000, "8.1.4", "keep"),
    # 8.2.1 Initiating Path Validation -- PATH_CHALLENGE; 64-bit random
    (9000, "8.2.1", "keep"),
    # 8.2.2 Path Validation Responses -- PATH_RESPONSE echoes challenge
    (9000, "8.2.2", "keep"),
    # 9.3 Responding to Connection Migration -- new path probing; cwnd reset
    (9000, "9.3", "keep"),
    # 9.5 Privacy Implications of Connection Migration -- linkability
    (9000, "9.5", "keep"),
    # 9.6 Server's Preferred Address -- one preferred address per AF
    (9000, "9.6", "keep"),
    # 9.6.2 Migration to a Preferred Address -- client MUST validate path
    (9000, "9.6.2", "keep"),
    # 9.6.3 Interaction of Client Migration and Preferred Address
    (9000, "9.6.3", "keep"),
    # 4.2 Increasing Flow Control Limits -- MAX_DATA, MAX_STREAM_DATA
    (9000, "4.2", "keep"),
    # 3.1 Sending Stream States -- Ready/Send/Data Sent/Data Recvd state machine
    (9000, "3.1", "keep"),
    # 3.2 Receiving Stream States -- Recv/Size Known/Data Recvd/Data Read
    (9000, "3.2", "keep"),
    # 8.2.4 Failed Path Validation -- 600s default abandon timeout
    (9000, "8.2.4", "keep"),
    # 9.4 Loss Detection and Congestion Control -- reset cwnd on migration
    (9000, "9.4", "keep"),
    # 10.1 Idle Timeout -- max_idle_timeout transport parameter; min of peers
    (9000, "10.1", "keep"),
    # 10.2.1 Closing Connection State -- send CONNECTION_CLOSE; drain timer
    (9000, "10.2.1", "keep"),
    # 10.2.2 Draining Connection State -- silently discard; no new state
    (9000, "10.2.2", "keep"),
    # 10.2.3 Immediate Close during the Handshake -- per-level close
    (9000, "10.2.3", "keep"),
    # 10.3.1 Detecting a Stateless Reset -- last 16 bytes match SR token
    (9000, "10.3.1", "keep"),
    # 10.3.2 Calculating a Stateless Reset Token -- HKDF over CID and secret
    (9000, "10.3.2", "keep"),
    # 11 Error Handling -- 10 normative tokens; PROTOCOL_VIOLATION semantics
    (9000, "11", "keep"),
    # 11.1 Connection Errors -- CONNECTION_CLOSE; close+drain timers
    (9000, "11.1", "keep"),
    # 12.2 Coalescing Packets -- multiple packets in single datagram
    (9000, "12.2", "keep"),
    # 12.3 Packet Numbers -- monotonically increasing; separate per space
    (9000, "12.3", "keep"),
    # 12.4 Frames and Frame Types -- 7 normative tokens; frame encoding
    (9000, "12.4", "keep"),
    # 13.2.1 Sending ACK Frames -- 13 normative tokens; max_ack_delay
    (9000, "13.2.1", "keep"),
    # 13.3 Retransmission of Information -- per-frame retransmit policy
    (9000, "13.3", "keep"),
    # 13.4 Explicit Congestion Notification -- ECN marking; counts
    (9000, "13.4", "keep"),
    # 14.1 Initial Datagram Size -- MUST be at least 1200 octets
    (9000, "14.1", "keep"),
    # 14.2 Path Maximum Transmission Unit -- 16 normative tokens; PMTUD
    (9000, "14.2", "keep"),
    # 17.2.5 Retry Packet -- 20 normative tokens; Retry Integrity Tag
    (9000, "17.2.5", "keep"),
    # 17.2.5.2 Handling a Retry Packet -- client MUST verify tag; resend
    (9000, "17.2.5.2", "keep"),
    # 19.3 ACK Frames -- ack delay, ranges, ECN counts
    (9000, "19.3", "keep"),
    # 19.15 NEW_CONNECTION_ID Frames -- 11 normative tokens; CID issuance
    (9000, "19.15", "keep"),
    # 22.1 Registration Policies for QUIC Registries -- 17 normative tokens
    (9000, "22.1", "keep"),

    # ---------- RFC 9001 (Using TLS to Secure QUIC) ----------
    # Specifies TLS handshake mapping into QUIC's encryption levels.
    # 4.1.3 Sending and Receiving Handshake Messages -- CRYPTO frames; one
    # per encryption level
    (9001, "4.1.3", "keep"),
    # 4.1.4 Encryption Level Changes -- when keys are installed; ordering
    (9001, "4.1.4", "keep"),
    # 4.2 TLS Version -- TLS 1.3 (RFC 8446) required; older versions MUST NOT
    (9001, "4.2", "keep"),
    # 4.3 ClientHello Size -- MUST fit in single Initial packet; min 1200
    (9001, "4.3", "keep"),
    # 4.4 Peer Authentication -- client/server certificate handling
    (9001, "4.4", "keep"),
    # 4.5 Session Resumption -- 0-RTT semantics; ticket binding
    (9001, "4.5", "keep"),
    # 4.6 0-RTT -- early data; replay considerations
    (9001, "4.6", "keep"),
    # 4.6.1 Enabling 0-RTT -- server flag; max_early_data_size MUST be 0xFFFFFFFF
    (9001, "4.6.1", "keep"),
    # 4.6.2 Accepting and Rejecting 0-RTT -- decision flow
    (9001, "4.6.2", "keep"),
    # 4.8 TLS Errors -- map to CRYPTO_ERROR with alert offset
    (9001, "4.8", "keep"),
    # 4.9 Discarding Unused Keys -- when each level's keys MUST be discarded
    (9001, "4.9", "keep"),
    # 4.9.1 Discarding Initial Keys -- after handshake key install
    (9001, "4.9.1", "keep"),
    # 4.9.3 Discarding 0-RTT Keys -- after handshake confirmation
    (9001, "4.9.3", "keep"),
    # 5.2 Initial Secrets -- HKDF-Expand-Label with version-specific salt
    (9001, "5.2", "keep"),
    # 5.3 AEAD Usage -- per-packet nonce construction; integrity
    (9001, "5.3", "keep"),
    # 5.5 Receiving Protected Packets -- decryption + AEAD failure handling
    (9001, "5.5", "keep"),
    # 5.6 Use of 0-RTT Keys -- server-side restrictions; replay
    (9001, "5.6", "keep"),
    # 5.7 Receiving Out-of-Order Protected Packets -- buffering rules
    (9001, "5.7", "keep"),
    # 6.1 Initiating a Key Update -- KEY_PHASE bit toggle; rate-limited
    (9001, "6.1", "keep"),
    # 6.2 Responding to a Key Update -- update before sending
    (9001, "6.2", "keep"),
    # 6.5 Receiving with Different Keys -- old vs new key tolerance
    (9001, "6.5", "keep"),
    # 6.6 Limits on AEAD Usage -- confidentiality + integrity limits per CS
    (9001, "6.6", "keep"),
    # 8 QUIC-Specific Adjustments to the TLS Handshake -- 18 normative tokens
    (9001, "8", "keep"),
    # 8.1 Protocol Negotiation -- ALPN; MUST close if no ALPN
    (9001, "8.1", "keep"),
    # 8.2 QUIC Transport Parameters Extension -- TLS extension carrying TPs
    (9001, "8.2", "keep"),

    # ---------- RFC 9002 (QUIC Loss Detection and Congestion Control) ----------
    # Defines QUIC's recovery algorithms (RACK-like loss detection, NewReno CC).
    # 2 Conventions and Definitions -- ACK-eliciting, in-flight, RTT vars
    (9002, "2", "keep"),
    # 5.1 Generating RTT Samples -- latest_rtt from ack delay subtraction
    (9002, "5.1", "keep"),
    # 5.2 Estimating min_rtt -- minimum observed; not adjusted for ack delay
    (9002, "5.2", "keep"),
    # 5.3 Estimating smoothed_rtt and rttvar -- EWMA formula; alpha=1/8, beta=1/4
    (9002, "5.3", "keep"),
    # 6.1.1 Packet Threshold -- kPacketThreshold = 3; reordering detection
    (9002, "6.1.1", "keep"),
    # 6.1.2 Time Threshold -- 9/8 * max(smoothed_rtt, latest_rtt)
    (9002, "6.1.2", "keep"),
    # 6.2.1 Computing PTO -- smoothed_rtt + 4*rttvar + max_ack_delay
    (9002, "6.2.1", "keep"),
    # 6.2.2 Handshakes and New Paths -- separate PTO per packet number space
    (9002, "6.2.2", "keep"),
    # 6.2.2.1 Before Address Validation -- anti-amplification limit
    (9002, "6.2.2.1", "keep"),
    # 6.2.4 Sending Probe Packets -- 1-2 ACK-eliciting probes on PTO fire
    (9002, "6.2.4", "keep"),
    # 6.3 Handling Retry Packets -- reset RTT samples on Retry
    (9002, "6.3", "keep"),
    # 6.4 Discarding Keys and Packet State -- per-level cleanup
    (9002, "6.4", "keep"),
    # 7.2 Initial and Minimum Congestion Window -- 10 * MSS initial; min 2*MSS
    (9002, "7.2", "keep"),
    # 7.3 Congestion Control States -- slow start, recovery, congestion avoid
    (9002, "7.3", "keep"),
    # 7.3.1 Slow Start -- doubles cwnd per RTT until threshold
    (9002, "7.3.1", "keep"),
    # 7.3.2 Recovery -- when entered; ECN-CE, persistent congestion
    (9002, "7.3.2", "keep"),
    # 7.4 Ignoring Loss of Undecryptable Packets -- before keys available
    (9002, "7.4", "keep"),
    # 7.6 Persistent Congestion -- duration condition; cwnd to minimum
    (9002, "7.6", "keep"),
    # 7.6.2 Establishing Persistent Congestion -- two ACK-eliciting lost
    (9002, "7.6.2", "keep"),
    # 7.7 Pacing -- send rate spread across RTT; burst limit
    (9002, "7.7", "keep"),

    # ---------- RFC 9114 (HTTP/3) ----------
    # HTTP semantics over QUIC.  Dense normative content for connection setup,
    # streams, frames, fields, error handling.
    # 2 HTTP/3 Protocol Overview -- transport over QUIC, streams, frames
    (9114, "2", "keep"),
    # 2.2 Conventions and Terminology -- client, server, push, stream, etc.
    (9114, "2.2", "keep"),
    # 3 Connection Setup and Management -- 24 normative tokens; ALPN, version
    (9114, "3", "keep"),
    # 3.1 Discovering an HTTP/3 Endpoint -- Alt-Svc, DNS, port hints
    (9114, "3.1", "keep"),
    # 3.2 Connection Establishment -- ALPN "h3"; QUIC version requirements
    (9114, "3.2", "keep"),
    # 3.3 Connection Reuse -- coalescing rules; cert hostname match
    (9114, "3.3", "keep"),
    # 4.1.1 Request Cancellation and Rejection -- 16 normative tokens
    (9114, "4.1.1", "keep"),
    # 4.1.2 Malformed Requests and Responses -- treat as H3_MESSAGE_ERROR
    (9114, "4.1.2", "keep"),
    # 4.2 HTTP Fields -- field section encoding via QPACK
    (9114, "4.2", "keep"),
    # 4.2.2 Header Size Constraints -- SETTINGS_MAX_FIELD_SECTION_SIZE
    (9114, "4.2.2", "keep"),
    # 4.3 HTTP Control Data -- pseudo-headers; method/scheme/path/status
    (9114, "4.3", "keep"),
    # 4.3.1 Request Pseudo-Header Fields -- :method/:scheme/:authority/:path
    (9114, "4.3.1", "keep"),
    # 4.4 The CONNECT Method -- tunnel via H3 streams
    (9114, "4.4", "keep"),
    # 4.6 Server Push -- PUSH_PROMISE on request stream; MAX_PUSH_ID
    (9114, "4.6", "keep"),
    # 5.1 Idle Connections -- both peers can close on idle
    (9114, "5.1", "keep"),
    # 5.2 Connection Shutdown -- GOAWAY; graceful close; in-flight rules
    (9114, "5.2", "keep"),
    # 6.2 Unidirectional Streams -- 32 normative tokens; stream type byte
    (9114, "6.2", "keep"),
    # 6.2.1 Control Streams -- one per direction; cannot be closed cleanly
    (9114, "6.2.1", "keep"),
    # 6.2.2 Push Streams -- carry server push response
    (9114, "6.2.2", "keep"),
    # 6.2.3 Reserved Stream Types -- grease (0x1f * N + 0x21)
    (9114, "6.2.3", "keep"),
    # 7.1 Frame Layout -- variable-length type + length + payload
    (9114, "7.1", "keep"),
    # 7.2.3 CANCEL_PUSH -- cancel a promised but not-yet-sent push
    (9114, "7.2.3", "keep"),
    # 7.2.4 SETTINGS -- 37 normative tokens; control-stream only; identifier
    # + value encoding
    (9114, "7.2.4", "keep"),
    # 7.2.4.2 SETTINGS Initialization -- first frame on control stream
    (9114, "7.2.4.2", "keep"),
    # 7.2.5 PUSH_PROMISE -- request payload that server is pushing
    (9114, "7.2.5", "keep"),
    # 7.2.6 GOAWAY -- last stream ID; further streams MUST be rejected
    (9114, "7.2.6", "keep"),
    # 7.2.7 MAX_PUSH_ID -- highest push ID server may use
    (9114, "7.2.7", "keep"),
    # 7.2.8 Reserved Frame Types -- grease frames; ignored on receipt
    (9114, "7.2.8", "keep"),
    # 8 Error Handling -- stream vs connection errors; code mapping
    (9114, "8", "keep"),
    # 10.5 Denial-of-Service Considerations -- request limit, push limit
    (9114, "10.5", "keep"),

    # ---------- RFC 6125 (TLS Server Identity Verification) ----------
    # The "DNS-ID / CN-ID / SRV-ID / URI-ID" matching rules for TLS.
    # 4 Representing Server Identity -- subjectAltName types
    (6125, "4", "keep"),
    # 4.1 Rules -- 14 normative tokens; CA SHOULD include DNS-ID; CN-ID rules
    (6125, "4.1", "keep"),
    # 6.2.1 Rules -- 14 normative tokens; client construction of reference IDs
    (6125, "6.2.1", "keep"),
    # 6.3 Preparing to Seek a Match -- normalize labels (LDH); IDN handling
    (6125, "6.3", "keep"),
    # 6.4 Matching the DNS Domain Name Portion -- 18 normative tokens
    (6125, "6.4", "keep"),
    # 6.4.1 Checking of Traditional Domain Names -- case-insensitive ASCII
    (6125, "6.4.1", "keep"),
    # 6.4.2 Checking of Internationalized Domain Names -- A-label compare
    (6125, "6.4.2", "keep"),
    # 6.4.3 Checking of Wildcard Certificates -- single * in left-most label
    (6125, "6.4.3", "keep"),
    # 6.4.4 Checking of Common Names -- only when no SAN; deprecated
    (6125, "6.4.4", "keep"),
    # 6.5 Matching the Application Service Type Portion -- SRV-ID; URI-ID
    (6125, "6.5", "keep"),
    # 6.6 Outcome -- match/no-match procedures; user notification
    (6125, "6.6", "keep"),
    # 6.6.4 Fallback -- when no reference IDs match; user override
    (6125, "6.6.4", "keep"),
    # 7 Security Considerations -- pinning, multiple identifiers, wildcards
    (6125, "7", "keep"),
    # 7.2 Wildcard Certificates -- security pitfalls of wildcards
    (6125, "7.2", "keep"),
    # 7.4 Multiple Identifiers -- handling certs with many SANs
    (6125, "7.4", "keep"),

    # ---------- RFC 7232 (HTTP/1.1 Conditional Requests) ----------
    # Defines preconditions (If-Match, If-None-Match, If-Modified-Since,
    # If-Unmodified-Since) and the 304 / 412 status semantics.
    # 1 Introduction -- conditional requests; validators
    (7232, "1", "keep"),
    # 2.1 Weak versus Strong -- weak prefix W/; bit-for-bit vs equivalence
    (7232, "2.1", "keep"),
    # 2.2 Last-Modified -- HTTP-date; intended granularity
    (7232, "2.2", "keep"),
    # 2.2.1 Generation -- best approximation; clock-monotonic
    (7232, "2.2.1", "keep"),
    # 2.2.2 Comparison -- HTTP-date string compare; equivalence
    (7232, "2.2.2", "keep"),
    # 2.3 ETag -- entity-tag; opaque quoted string
    (7232, "2.3", "keep"),
    # 2.3.1 Generation -- distinct for distinct representations
    (7232, "2.3.1", "keep"),
    # 2.4 When to Use Entity-Tags and Last-Modified Dates -- 8 normative
    (7232, "2.4", "keep"),
    # 3.1 If-Match -- precondition for strong validators
    (7232, "3.1", "keep"),
    # 3.2 If-None-Match -- precondition for negative match
    (7232, "3.2", "keep"),
    # 3.3 If-Modified-Since -- GET/HEAD; ignore for non-safe methods
    (7232, "3.3", "keep"),
    # 3.4 If-Unmodified-Since -- precondition; 9 normative tokens
    (7232, "3.4", "keep"),
    # 4 Status Code Definitions -- 304, 412 meanings
    (7232, "4", "keep"),
    # 4.1 304 Not Modified -- MUST NOT include message body
    (7232, "4.1", "keep"),
    # 5 Evaluation -- order; resource validator state
    (7232, "5", "keep"),
    # 6 Precedence -- order: If-Match, If-Unmodified-Since, If-None-Match,
    # If-Modified-Since, If-Range
    (7232, "6", "keep"),

    # ---------- RFC 7234 (HTTP/1.1 Caching) ----------
    # Caching is the most normative-dense pre-HTTP-Semantics RFC.  All the
    # directive semantics live here.  Largest single contribution.
    # 1 Introduction -- cacheable, freshness, validation
    (7234, "1", "keep"),
    # 1.2.1 Delta Seconds -- non-negative integer; clamping
    (7234, "1.2.1", "keep"),
    # 3 Storing Responses in Caches -- 15 normative tokens; eligibility rules
    (7234, "3", "keep"),
    # 3.1 Storing Incomplete Responses -- partial content; 206 handling
    (7234, "3.1", "keep"),
    # 3.2 Storing Authenticated Requests -- must-revalidate / public override
    (7234, "3.2", "keep"),
    # 3.3 Combining Partial Content -- conditions for stitching
    (7234, "3.3", "keep"),
    # 4.1 Calculating Secondary Keys with Vary -- Vary-aware match
    (7234, "4.1", "keep"),
    # 4.2.2 Calculating Heuristic Freshness -- 10% of Last-Modified age
    (7234, "4.2.2", "keep"),
    # 4.2.3 Calculating Age -- corrected_age_value formula
    (7234, "4.2.3", "keep"),
    # 4.2.4 Serving Stale Responses -- when permitted; Warning header
    (7234, "4.2.4", "keep"),
    # 4.3.2 Handling a Received Validation Request -- 9 normative tokens
    (7234, "4.3.2", "keep"),
    # 4.3.4 Freshening Stored Responses upon Validation -- update headers
    (7234, "4.3.4", "keep"),
    # 4.3.5 Freshening Responses via HEAD -- partial update; etag check
    (7234, "4.3.5", "keep"),
    # 4.4 Invalidation -- POST/PUT/DELETE invalidates the URI and Location
    (7234, "4.4", "keep"),
    # 5.2.1 Request Cache-Control Directives -- 19 normative tokens
    (7234, "5.2.1", "keep"),
    # 5.2.1.5 no-store -- request directive; cache MUST NOT store
    (7234, "5.2.1.5", "keep"),
    # 5.2.2 Response Cache-Control Directives -- 32 normative tokens
    (7234, "5.2.2", "keep"),
    # 5.2.2.1 must-revalidate -- once stale, MUST validate or 504
    (7234, "5.2.2.1", "keep"),
    # 5.2.2.2 no-cache -- MUST validate before reuse; field-list form
    (7234, "5.2.2.2", "keep"),
    # 5.2.2.3 no-store -- response directive; no part stored
    (7234, "5.2.2.3", "keep"),
    # 5.2.2.6 private -- single user; shared cache MUST NOT store
    (7234, "5.2.2.6", "keep"),
    # 5.2.2.8 max-age -- response directive variant
    (7234, "5.2.2.8", "keep"),
    # 5.2.2.9 s-maxage -- overrides max-age for shared caches
    (7234, "5.2.2.9", "keep"),
    # 5.3 Expires -- HTTP-date; max-age overrides
    (7234, "5.3", "keep"),
    # 5.4 Pragma -- legacy; "no-cache" treated as Cache-Control
    (7234, "5.4", "keep"),
    # 5.5 Warning -- 20 normative tokens; warn-code semantics
    (7234, "5.5", "keep"),

    # ---------- RFC 6376 (DKIM Signatures) ----------
    # DomainKeys Identified Mail.  Dense normative content for signing,
    # canonicalization, and verification.
    # 3.2 Tag=Value Lists -- syntax; whitespace; duplicates
    (6376, "3.2", "keep"),
    # 3.3 Signing and Verification Algorithms -- 14 normative tokens
    (6376, "3.3", "keep"),
    # 3.3.2 rsa-sha256 Signing Algorithm -- preferred; MUST implement
    (6376, "3.3.2", "keep"),
    # 3.3.3 Key Sizes -- 512 minimum; SHOULD use at least 1024
    (6376, "3.3.3", "keep"),
    # 3.4 Canonicalization -- 18 normative tokens; simple vs relaxed
    (6376, "3.4", "keep"),
    # 3.4.2 relaxed Header Canonicalization -- lowercase names; WSP fold
    (6376, "3.4.2", "keep"),
    # 3.4.4 relaxed Body Canonicalization -- reduce internal WSP; strip CRLF
    (6376, "3.4.4", "keep"),
    # 3.6.1 Textual Representation -- 22 normative tokens; tag definitions
    (6376, "3.6.1", "keep"),
    # 3.6.2 DNS Binding -- _domainkey selector subdomain
    (6376, "3.6.2", "keep"),
    # 3.7 Computing the Message Hashes -- 18 normative tokens; body + header
    (6376, "3.7", "keep"),
    # 3.8 Input Requirements -- well-formed; CRLF terminated
    (6376, "3.8", "keep"),
    # 3.9 Output Requirements -- DKIM-Signature inserted at top
    (6376, "3.9", "keep"),
    # 3.10 Signing by Parent Domains -- "i=" parameter rules
    (6376, "3.10", "keep"),
    # 3.11 Relationship between SDID and AUID -- d= vs i= semantics
    (6376, "3.11", "keep"),
    # 4 Semantics of Multiple Signatures -- valid + invalid combinations
    (6376, "4", "keep"),
    # 4.2 Interpretation -- "if any signature succeeds, the message is signed"
    (6376, "4.2", "keep"),
    # 5.3 Normalize the Message to Prevent Transport Conversions -- MUST
    # convert to 7-bit if SMTP doesn't support 8BITMIME
    (6376, "5.3", "keep"),
    # 5.4.1 Recommended Signature Content -- which headers SHOULD be signed
    (6376, "5.4.1", "keep"),
    # 5.4.2 Signatures Involving Multiple Instances of a Field -- bottom-up
    (6376, "5.4.2", "keep"),
    # 5.6 Insert the DKIM-Signature Header Field -- before others; "b=" blank
    (6376, "5.6", "keep"),
    # 6.1.1 Validate the Signature Header Field -- 12 normative tokens
    (6376, "6.1.1", "keep"),
    # 6.1.2 Get the Public Key -- TXT lookup; key absence vs revocation
    (6376, "6.1.2", "keep"),
    # 6.1.3 Compute the Verification -- recompute hash; signature compare
    (6376, "6.1.3", "keep"),
    # 6.3 Interpret Results/Apply Local Policy -- 11 normative tokens
    (6376, "6.3", "keep"),
    # 2.11 DKIM-Quoted-Printable -- alphabet; encoding rules
    (6376, "2.11", "keep"),
]

# ---------- Summary ----------
# Per-RFC counts:
#   RFC 9293 (TCP modernized)             :  25 sections
#   RFC 8200 (IPv6 header)                :  15 sections
#   RFC 9000 (QUIC transport)             :  55 sections
#   RFC 9001 (QUIC TLS)                   :  25 sections
#   RFC 9002 (QUIC Recovery)              :  20 sections
#   RFC 9114 (HTTP/3)                     :  30 sections
#   RFC 6125 (TLS server identity)        :  15 sections
#   RFC 7232 (HTTP conditional)           :  16 sections
#   RFC 7234 (HTTP caching)               :  26 sections
#   RFC 6376 (DKIM)                       :  25 sections
#   --------------------------------------:------
#   TOTAL                                 : 252 sections
#
# RFC 9000 got the biggest single-RFC weight (55) because the spec is large
# and dense; the second pass added connection close, error handling, frames,
# ACK semantics, PMTU, Retry packet, and registry policies.
