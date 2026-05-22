# Curated v0.d topic list: ~250 RFC sections selected for strong quotable clauses.
# Each (rfc_num, section_id, polarity) tuple feeds draft_and_verify.py.
# Polarity is "keep" for now; "invert" variants will be added later.
#
# Excludes the 43 v0.c topics (RFCs 1034/7540/8259/8446) entirely - this file
# spans 10 different RFCs.
#
# Selection criteria (verified by reading each section in the cache):
#   - contains at least one strong quotable clause (MUST/SHOULD/MAY/MUST NOT,
#     "is defined", "is not", "shall", or a sharp definitional sentence)
#   - bounded (short paragraph(s), not whole-chapter)
#   - admits a clean yes/no or is-X-Y question
#   - not pure prose / not tables / not ABNF-only / not references
#
# Seed list and what happened: all 10 seed RFCs (791, 793, 9110, 9112, 6749,
# 5321, 3986, 6455, 7519, 2119) fetched cleanly with no 404s; no substitutions
# were needed. RFC 2119 is short by design (only ~7 in-scope sections), so it
# contributes fewer than 25 topics; RFC 791 has only ~12 numbered sections in
# the strict scheme the fetcher recognises, so it is also under quota.

TOPICS: list[tuple[int, str, str]] = [
    # ---------- RFC 791 (Internet Protocol) ----------
    # 1.1 Motivation -- "The Internet Protocol is designed for use in
    # interconnected systems of packet-switched computer communication networks"
    (791, "1.1", "keep"),
    # 1.2 Scope -- "no mechanisms to augment end-to-end data reliability,
    # flow control, sequencing, or other services"
    (791, "1.2", "keep"),
    # 1.3 Interfaces -- IP is called on by host-to-host protocols; calls on
    # local network protocols
    (791, "1.3", "keep"),
    # 1.4 Operation -- "The internet protocol implements two basic functions:
    # addressing and fragmentation"
    (791, "1.4", "keep"),
    # 2.1 Relation to Other Protocols -- IP between host-to-host and local
    # network layers
    (791, "2.1", "keep"),
    # 2.2 Model of Operation -- internet module sits between TCP and local net;
    # source/destination addresses
    (791, "2.2", "keep"),
    # 2.3 Function Description -- defines addressing + fragmentation; TTL bound
    (791, "2.3", "keep"),
    # 2.4 Gateways -- gateways implement IP to forward datagrams between
    # networks; do not maintain connection state
    (791, "2.4", "keep"),
    # 3.1 Internet Header Format -- header fields; "the minimum value for a
    # correct header is 5"; TTL semantics; 576-octet floor
    (791, "3.1", "keep"),
    # 3.2 Discussion -- fragmentation, reassembly, TTL-zero discard rules
    (791, "3.2", "keep"),
    # 3.3 Interfaces -- conceptual TCP->IP call (SEND) and IP->TCP call (RECV)
    (791, "3.3", "keep"),

    # ---------- RFC 793 (TCP) ----------
    # 1.5 Operation -- "TCP is a connection-oriented, end-to-end reliable
    # protocol"; basic services list
    (793, "1.5", "keep"),
    # 2.6 Reliable Communication -- "delivered reliably and in order"; sequence
    # numbers + acknowledgments + retransmission
    (793, "2.6", "keep"),
    # 2.7 Connection Establishment and Clearing -- 3-way handshake; "a
    # connection is fully specified by the pair of sockets at the ends"
    (793, "2.7", "keep"),
    # 2.8 Data Communication -- octet stream; PUSH flag semantics
    (793, "2.8", "keep"),
    # 2.10 Robustness Principle -- "be conservative in what you do, be liberal
    # in what you accept from others"
    (793, "2.10", "keep"),
    # 3.1 Header Format -- header field widths; "A TCP must implement all
    # options"; pseudo-header definition; reserved-must-be-zero
    (793, "3.1", "keep"),
    # 3.2 Terminology -- defines TCB, send/recv sequence variables; SEG.SEQ /
    # SEG.ACK / SEG.LEN / SEG.WND
    (793, "3.2", "keep"),
    # 3.3 Sequence Numbers -- "every octet of data sent over a TCP connection
    # has a sequence number"; modulo 2**32 arithmetic; MSL = 2 minutes
    (793, "3.3", "keep"),
    # 3.4 Establishing a connection -- SYN exchange; three-way handshake;
    # passive vs active OPEN
    (793, "3.4", "keep"),
    # 3.5 Closing a Connection -- FIN exchange; three close cases; CLOSE-WAIT
    # and TIME-WAIT
    (793, "3.5", "keep"),
    # 3.6 Precedence and Security -- TCP uses IP type-of-service + security
    # option per connection
    (793, "3.6", "keep"),
    # 3.7 Data Communication -- sequencing, retransmission timer behaviour
    (793, "3.7", "keep"),
    # 3.8 Interfaces -- OPEN/SEND/RECEIVE/CLOSE/STATUS/ABORT calls defined
    (793, "3.8", "keep"),
    # 3.9 Event Processing -- segment arrival processing, RST handling
    (793, "3.9", "keep"),

    # ---------- RFC 9110 (HTTP Semantics) ----------
    # 1.3 Core Semantics -- defines what HTTP is generic about
    (9110, "1.3", "keep"),
    # 2.2 Requirements Notation -- conformance levels; "MUST" requirement;
    # ABNF terminology
    (9110, "2.2", "keep"),
    # 2.4 Error Handling -- recipient MAY perform implementation-specific
    # recovery but MUST treat ambiguous as error
    (9110, "2.4", "keep"),
    # 3.1 Resources -- defines "resource" as the target of any HTTP request
    (9110, "3.1", "keep"),
    # 3.2 Representations -- representation = metadata + data describing state
    # of a resource
    (9110, "3.2", "keep"),
    # 3.4 Messages -- request/response structure; control data
    (9110, "3.4", "keep"),
    # 5.1 Field Names -- "field names are case-insensitive"
    (9110, "5.1", "keep"),
    # 5.5 Field Values -- "Field values containing CR, LF, or NUL characters
    # are invalid and dangerous"
    (9110, "5.5", "keep"),
    # 6.1 Framing and Completeness -- recipient MUST detect incomplete message
    # and treat as failure
    (9110, "6.1", "keep"),
    # 7.2 Host and :authority -- "A client MUST send a Host header field"
    # rule and 400 (Bad Request) error
    (9110, "7.2", "keep"),
    # 8.3 Content-Type -- defines Content-Type field; media type semantics
    (9110, "8.3", "keep"),
    # 8.6 Content-Length -- decimal-octet rule; "A sender MUST NOT send a
    # Content-Length header field in any message that contains a
    # Transfer-Encoding"
    (9110, "8.6", "keep"),
    # 9.2.1 Safe Methods -- "GET, HEAD, OPTIONS, and TRACE methods are
    # defined to be safe"
    (9110, "9.2.1", "keep"),
    # 9.2.2 Idempotent Methods -- "PUT, DELETE, and safe request methods are
    # idempotent"; "A proxy MUST NOT automatically retry non-idempotent
    # requests"
    (9110, "9.2.2", "keep"),
    # 9.3.1 GET -- request transfer of current selected representation;
    # SHOULD NOT generate content
    (9110, "9.3.1", "keep"),
    # 9.3.2 HEAD -- "The HEAD method is identical to GET except that the
    # server MUST NOT send content in the response"
    (9110, "9.3.2", "keep"),
    # 9.3.4 PUT -- create-or-replace target with the enclosed representation;
    # 201/200/204 response rules
    (9110, "9.3.4", "keep"),
    # 9.3.5 DELETE -- "The DELETE method requests that the origin server
    # remove the association between the target resource and its current
    # functionality"
    (9110, "9.3.5", "keep"),
    # 9.3.6 CONNECT -- requests a tunnel; "intended only for use in requests
    # to a proxy"
    (9110, "9.3.6", "keep"),
    # 9.3.7 OPTIONS -- describes communication options for the target
    # resource; "*" form
    (9110, "9.3.7", "keep"),
    # 9.3.8 TRACE -- loopback of the request; "A client MUST NOT generate
    # content in a TRACE request"
    (9110, "9.3.8", "keep"),
    # 11.1 Authentication Scheme -- defined as case-insensitive token + auth
    # parameters
    (9110, "11.1", "keep"),
    # 15.3.1 200 OK -- request has succeeded; payload semantics by method
    (9110, "15.3.1", "keep"),
    # 15.3.2 201 Created -- "indicates that the request has been fulfilled
    # and has resulted in one or more new resources being created"
    (9110, "15.3.2", "keep"),
    # 15.4.2 301 Moved Permanently -- target has been assigned a new
    # permanent URI; future references SHOULD use that URI
    (9110, "15.4.2", "keep"),
    # 15.5.1 400 Bad Request -- server cannot or will not process due to
    # something perceived as a client error
    (9110, "15.5.1", "keep"),
    # 15.5.5 404 Not Found -- origin server did not find a current
    # representation for the target resource
    (9110, "15.5.5", "keep"),

    # ---------- RFC 9112 (HTTP/1.1 Messaging) ----------
    # 2.1 Message Format -- start-line CRLF *(field-line CRLF) CRLF
    # [message-body]
    (9112, "2.1", "keep"),
    # 2.2 Message Parsing -- "A recipient MUST parse an HTTP message as a
    # sequence of octets in an encoding that is a superset of US-ASCII";
    # bare-CR + extra-CRLF rules
    (9112, "2.2", "keep"),
    # 2.3 HTTP Version -- HTTP-version is case-sensitive; "HTTP-name = %s
    # \"HTTP\""
    (9112, "2.3", "keep"),
    # 3.2 Request Target -- four request-target forms; "No whitespace is
    # allowed in the request-target"; mandatory Host
    (9112, "3.2", "keep"),
    # 3.2.1 origin-form -- "client MUST send only the absolute path and
    # query components of the target URI as the request-target"
    (9112, "3.2.1", "keep"),
    # 3.2.2 absolute-form -- proxy MUST send target URI in absolute-form;
    # proxy MUST ignore received Host
    (9112, "3.2.2", "keep"),
    # 3.2.3 authority-form -- only used for CONNECT requests
    (9112, "3.2.3", "keep"),
    # 3.2.4 asterisk-form -- only used for server-wide OPTIONS request
    (9112, "3.2.4", "keep"),
    # 4 Status Line -- "status-code = 3DIGIT"; reason-phrase optional
    (9112, "4", "keep"),
    # 5 Field Syntax -- "Each field line consists of a case-insensitive
    # field name followed by a colon"
    (9112, "5", "keep"),
    # 5.1 Field Line Parsing -- "No whitespace is allowed between the field
    # name and colon"
    (9112, "5.1", "keep"),
    # 5.2 Obsolete Line Folding -- "A sender MUST NOT generate a message
    # that includes line folding"
    (9112, "5.2", "keep"),
    # 6.1 Transfer-Encoding -- "A recipient MUST be able to parse the
    # chunked transfer coding"; "A sender MUST NOT apply the chunked
    # transfer coding more than once to a message body"
    (9112, "6.1", "keep"),
    # 6.2 Content-Length -- "A sender MUST NOT send a Content-Length header
    # field in any message that contains a Transfer-Encoding header field"
    (9112, "6.2", "keep"),
    # 6.3 Message Body Length -- ordered precedence rules; "the
    # Transfer-Encoding overrides the Content-Length"
    (9112, "6.3", "keep"),
    # 7.1 Chunked Transfer Coding -- "A recipient MUST be able to parse and
    # decode the chunked transfer coding"
    (9112, "7.1", "keep"),
    # 7.1.1 Chunk Extensions -- "A recipient MUST ignore unrecognized chunk
    # extensions"
    (9112, "7.1.1", "keep"),
    # 7.1.2 Chunked Trailer Section -- "A recipient MUST NOT merge a
    # received trailer field into the header section unless its
    # corresponding header field definition explicitly permits"
    (9112, "7.1.2", "keep"),
    # 7.3 Transfer Coding Registry -- "Names of transfer codings MUST NOT
    # overlap with names of content codings"
    (9112, "7.3", "keep"),
    # 7.4 Negotiating Transfer Codings -- "A client MUST NOT send the
    # chunked transfer coding name in TE"
    (9112, "7.4", "keep"),
    # 9.3 Persistence -- HTTP/1.1 connections persistent by default
    (9112, "9.3", "keep"),
    # 9.3.1 Retrying Requests -- non-idempotent request MUST NOT retry;
    # exception for idempotent
    (9112, "9.3.1", "keep"),
    # 9.3.2 Pipelining -- client that supports persistent connections MAY
    # pipeline; server MUST send responses to those requests in the same
    # order
    (9112, "9.3.2", "keep"),
    # 9.6 Tear-down -- server SHOULD send Connection: close before closing
    # connection
    (9112, "9.6", "keep"),
    # 9.8 TLS Connection Closure -- close_notify semantics; truncation
    # attack guards
    (9112, "9.8", "keep"),
    # 11.2 Request Smuggling -- definitions, sender MUST NOT generate
    # ambiguous framing
    (9112, "11.2", "keep"),

    # ---------- RFC 6749 (OAuth 2.0) ----------
    # 1.1 Roles -- defines resource owner, resource server, client,
    # authorization server
    (6749, "1.1", "keep"),
    # 1.3 Authorization Grant -- "four grant types -- authorization code,
    # implicit, resource owner password credentials, and client credentials"
    (6749, "1.3", "keep"),
    # 1.3.1 Authorization Code -- obtained by using authorization server as
    # intermediary; "resource owner's credentials are never shared with the
    # client"
    (6749, "1.3.1", "keep"),
    # 1.3.3 Resource Owner Password Credentials -- "should only be used when
    # there is a high degree of trust"
    (6749, "1.3.3", "keep"),
    # 1.4 Access Token -- "Access tokens are credentials used to access
    # protected resources"
    (6749, "1.4", "keep"),
    # 1.5 Refresh Token -- "Unlike access tokens, refresh tokens are
    # intended for use only with authorization servers and are never sent
    # to resource servers"
    (6749, "1.5", "keep"),
    # 2 Client Registration -- "Before initiating the protocol, the client
    # registers with the authorization server"
    (6749, "2", "keep"),
    # 2.1 Client Types -- confidential vs public; based on ability to
    # maintain credential confidentiality
    (6749, "2.1", "keep"),
    # 2.2 Client Identifier -- "is not a secret"; "MUST NOT be used alone
    # for client authentication"
    (6749, "2.2", "keep"),
    # 2.3 Client Authentication -- "The client MUST NOT use more than one
    # authentication method in each request"
    (6749, "2.3", "keep"),
    # 2.3.1 Client Password -- "The authorization server MUST support the
    # HTTP Basic authentication scheme"; "MUST require the use of TLS"
    (6749, "2.3.1", "keep"),
    # 3.1 Authorization Endpoint -- "endpoint URI MUST NOT include a
    # fragment component"; MUST require TLS
    (6749, "3.1", "keep"),
    # 3.1.1 Response Type -- value MUST be "code" or "token" or registered
    # extension
    (6749, "3.1.1", "keep"),
    # 3.1.2 Redirection Endpoint -- "The redirection endpoint URI MUST be
    # an absolute URI"; MUST NOT include a fragment
    (6749, "3.1.2", "keep"),
    # 3.1.2.3 Dynamic Configuration -- "the authorization server MUST
    # compare and match the value received against at least one of the
    # registered redirection URIs"
    (6749, "3.1.2.3", "keep"),
    # 3.1.2.4 Invalid Endpoint -- "MUST NOT automatically redirect the
    # user-agent to the invalid redirection URI"
    (6749, "3.1.2.4", "keep"),
    # 3.2 Token Endpoint -- "The client MUST use the HTTP \"POST\" method
    # when making access token requests"
    (6749, "3.2", "keep"),
    # 3.3 Access Token Scope -- "value of the scope parameter is expressed
    # as a list of space-delimited, case-sensitive strings"
    (6749, "3.3", "keep"),
    # 4.1 Authorization Code Grant -- flow steps + optimized for
    # confidential clients
    (6749, "4.1", "keep"),
    # 4.1.1 Authorization Request -- response_type REQUIRED = "code";
    # client_id REQUIRED
    (6749, "4.1.1", "keep"),
    # 4.1.2 Authorization Response -- authorization code MUST expire
    # shortly after issued; MUST NOT be used more than once
    (6749, "4.1.2", "keep"),
    # 4.2 Implicit Grant -- access token issued directly in fragment of
    # redirect URI
    (6749, "4.2", "keep"),
    # 4.4 Client Credentials Grant -- "The client credentials grant type
    # MUST only be used by confidential clients"
    (6749, "4.4", "keep"),
    # 5.1 Successful Response -- token_type REQUIRED; expires_in RECOMMENDED
    (6749, "5.1", "keep"),
    # 5.2 Error Response -- error parameter values list; MUST include "error"
    (6749, "5.2", "keep"),
    # 6 Refreshing an Access Token -- grant_type=refresh_token; scope MUST
    # NOT include any scope not originally granted
    (6749, "6", "keep"),
    # 10.1 Client Authentication -- "authorization servers SHOULD NOT issue
    # client credentials to applications incapable of keeping their secrets
    # confidential"
    (6749, "10.1", "keep"),
    # 10.3 Access Tokens -- MUST be kept confidential in transit and
    # storage
    (6749, "10.3", "keep"),

    # ---------- RFC 5321 (SMTP) ----------
    # 2.2.1 Background -- SMTP extension model
    (5321, "2.2.1", "keep"),
    # 2.3.1 Mail Objects -- envelope + content; "Content consists of header
    # section and body"
    (5321, "2.3.1", "keep"),
    # 2.3.10 Originator, Delivery, Relay, and Gateway Systems -- defines
    # the four system types
    (5321, "2.3.10", "keep"),
    # 2.3.11 Mailbox and Address -- "the local-part MUST be interpreted and
    # assigned semantics only by the host specified in the domain part of
    # the address"
    (5321, "2.3.11", "keep"),
    # 2.4 General Syntax Principles -- "verbs and argument values ... are
    # not case sensitive"; "The local-part of a mailbox MUST BE treated as
    # case sensitive"
    (5321, "2.4", "keep"),
    # 3.1 Session Initiation -- server responds with 220 opening message;
    # 554 to reject session
    (5321, "3.1", "keep"),
    # 3.2 Client Initiation -- client sends EHLO; "Servers MUST NOT return
    # the extended EHLO-style response to a HELO command"
    (5321, "3.2", "keep"),
    # 3.3 Mail Transactions -- MAIL FROM, RCPT TO, DATA sequence; "Mail
    # transaction commands MUST be used in the order discussed above"
    (5321, "3.3", "keep"),
    # 3.5.3 Meaning of VRFY or EXPN Success Response -- "A server MUST NOT
    # return a 250 code in response to a VRFY or EXPN command unless it
    # has actually verified the address"
    (5321, "3.5.3", "keep"),
    # 3.6.1 Source Routes and Relaying -- "SMTP clients SHOULD NOT generate
    # explicit source routes except under unusual circumstances"
    (5321, "3.6.1", "keep"),
    # 3.7.2 Received Lines in Gatewaying -- "a gateway MUST prepend a
    # Received: line, but it MUST NOT alter in any way a Received: line
    # that is already in the header section"
    (5321, "3.7.2", "keep"),
    # 4.1.1.1 Extended HELLO (EHLO or HELO) -- restart of SMTP session;
    # 250 reply lists capabilities
    (5321, "4.1.1.1", "keep"),
    # 4.1.1.2 MAIL (MAIL) -- "This command tells the SMTP-receiver that a
    # new mail transaction is starting"
    (5321, "4.1.1.2", "keep"),
    # 4.1.1.3 RCPT -- "The forward-path normally consists of the required
    # destination mailbox"; source-route handling
    (5321, "4.1.1.3", "keep"),
    # 4.1.1.4 DATA -- end-of-mail "<CRLF>.<CRLF>"; "SMTP server systems
    # MUST NOT" treat <LF>.<LF> as equivalent
    (5321, "4.1.1.4", "keep"),
    # 4.1.1.5 RSET -- "An SMTP server MUST NOT close the connection as the
    # result of receiving a RSET"
    (5321, "4.1.1.5", "keep"),
    # 4.1.1.10 QUIT -- "the receiver MUST send a \"221 OK\" reply, and
    # then close the transmission channel"
    (5321, "4.1.1.10", "keep"),
    # 4.2 SMTP Replies -- 3-digit reply codes; first digit class
    (5321, "4.2", "keep"),
    # 4.2.1 Reply Code Severities and Theory -- defines reply classes by
    # first digit (positive completion, transient, permanent failure)
    (5321, "4.2.1", "keep"),
    # 4.3.1 Sequencing Overview -- discusses pipelining + sequencing
    # constraints
    (5321, "4.3.1", "keep"),
    # 4.4 Trace Information -- "When the SMTP server accepts a message
    # either for relaying or for final delivery, it inserts a trace record
    # ... at the top of the mail data"
    (5321, "4.4", "keep"),
    # 4.5.1 Minimum Implementation -- "the following commands MUST be
    # supported"; list of mandatory commands
    (5321, "4.5.1", "keep"),
    # 4.5.3.1.1 Local-part -- "The maximum total length of a user name or
    # other local-part is 64 octets"
    (5321, "4.5.3.1.1", "keep"),
    # 4.5.3.1.2 Domain -- "The maximum total length of a domain name or
    # number is 255 octets"
    (5321, "4.5.3.1.2", "keep"),
    # 4.5.3.1.6 Text Line -- "The maximum total length of a text line
    # including the <CRLF> is 1000 octets"
    (5321, "4.5.3.1.6", "keep"),
    # 6.1 Reliable Delivery and Replies by Email -- "the receiver takes
    # full responsibility for the message" once 250 reply sent
    (5321, "6.1", "keep"),

    # ---------- RFC 3986 (URI Generic Syntax) ----------
    # 1.1 Overview of URIs -- definition; URI as identifier of a resource
    (3986, "1.1", "keep"),
    # 1.1.1 Generic Syntax -- scheme + hier-part + query + fragment;
    # required vs optional components
    (3986, "1.1.1", "keep"),
    # 1.1.3 URI, URL, and URN -- "A URI can be further classified as a
    # locator, a name, or both"
    (3986, "1.1.3", "keep"),
    # 1.2.1 Transcription -- URIs are restricted to "a fairly small,
    # selected set of characters"
    (3986, "1.2.1", "keep"),
    # 2.1 Percent-Encoding -- "pct-encoded = \"%\" HEXDIG HEXDIG"; "If two
    # URIs differ only in the case of hexadecimal digits used in
    # percent-encoded octets, they are equivalent"
    (3986, "2.1", "keep"),
    # 2.2 Reserved Characters -- gen-delims + sub-delims; "URIs that
    # differ in the replacement of a reserved character with its
    # corresponding percent-encoded octet are not equivalent"
    (3986, "2.2", "keep"),
    # 2.3 Unreserved Characters -- "unreserved = ALPHA / DIGIT / \"-\" /
    # \".\" / \"_\" / \"~\""; equivalence under percent-encoding
    (3986, "2.3", "keep"),
    # 2.4 When to Encode or Decode -- "Implementations must not
    # percent-encode or decode the same string more than once"
    (3986, "2.4", "keep"),
    # 3 Syntax Components -- "URI = scheme \":\" hier-part [ \"?\" query
    # ] [ \"#\" fragment ]"
    (3986, "3", "keep"),
    # 3.1 Scheme -- "scheme = ALPHA *( ALPHA / DIGIT / \"+\" / \"-\" /
    # \".\" )"; case-insensitive but canonical form is lowercase
    (3986, "3.1", "keep"),
    # 3.2 Authority -- "authority = [ userinfo \"@\" ] host [ \":\" port
    # ]"; preceded by "//"
    (3986, "3.2", "keep"),
    # 3.2.1 User Information -- "Use of the format \"user:password\" in
    # the userinfo field is deprecated"
    (3986, "3.2.1", "keep"),
    # 3.2.2 Host -- IP-literal / IPv4address / reg-name; "The host
    # subcomponent is case-insensitive"
    (3986, "3.2.2", "keep"),
    # 3.2.3 Port -- "port = *DIGIT"; "URI producers and normalizers should
    # omit the port component and its \":\" delimiter if port is empty or
    # if its value would be the same as that of the scheme's default"
    (3986, "3.2.3", "keep"),
    # 3.3 Path -- "If a URI contains an authority component, then the
    # path component must either be empty or begin with a slash"
    (3986, "3.3", "keep"),
    # 3.4 Query -- "query = *( pchar / \"/\" / \"?\" )"; indicated by
    # first "?"
    (3986, "3.4", "keep"),
    # 3.5 Fragment -- "fragment = *( pchar / \"/\" / \"?\" )";
    # client-side identification of a secondary resource
    (3986, "3.5", "keep"),
    # 4.1 URI Reference -- "URI-reference = URI / relative-ref"
    (3986, "4.1", "keep"),
    # 4.2 Relative Reference -- defines relative-ref syntax + no scheme
    (3986, "4.2", "keep"),
    # 4.3 Absolute URI -- "absolute-URI = scheme \":\" hier-part [
    # \"?\" query ]"; no fragment allowed
    (3986, "4.3", "keep"),
    # 5.2.3 Merge Paths -- algorithm for merging base + reference paths
    (3986, "5.2.3", "keep"),
    # 5.2.4 Remove Dot Segments -- algorithm to remove "." and ".."
    # segments from a path
    (3986, "5.2.4", "keep"),
    # 6.1 Equivalence -- "URI comparison is performed for some particular
    # purpose"; equivalence not implication of same-resource
    (3986, "6.1", "keep"),
    # 6.2.2.1 Case Normalization -- "the hexadecimal digits within a
    # percent-encoding triplet (e.g., \"%3a\" versus \"%3A\") are
    # case-insensitive"
    (3986, "6.2.2.1", "keep"),
    # 6.2.2.2 Percent-Encoding Normalization -- decode unreserved
    # percent-encoded octets to produce a normalized URI
    (3986, "6.2.2.2", "keep"),
    # 7.6 Identifying Endpoints -- DNS lookup risks; visual confusion
    # warnings
    (3986, "7.6", "keep"),

    # ---------- RFC 6455 (The WebSocket Protocol) ----------
    # 1.2 Protocol Overview -- opening handshake on top of HTTP; "the
    # connection is then upgraded to use the WebSocket framing"
    (6455, "1.2", "keep"),
    # 1.3 Opening Handshake -- client GET with Upgrade: websocket; server
    # 101 Switching Protocols; Sec-WebSocket-Key + Accept
    (6455, "1.3", "keep"),
    # 1.4 Closing Handshake -- close control frame; "After both sending
    # and receiving a Close message, an endpoint considers the WebSocket
    # connection closed"
    (6455, "1.4", "keep"),
    # 1.5 Design Philosophy -- minimal framing; "to provide for as little
    # framing as possible"
    (6455, "1.5", "keep"),
    # 1.6 Security Model -- origin model; client masking
    (6455, "1.6", "keep"),
    # 3 WebSocket URIs -- "ws-URI = \"ws:\" \"//\" authority path-abempty
    # [ \"?\" query ]"; default ports 80/443
    (6455, "3", "keep"),
    # 4.1 Client Requirements -- mandatory request fields; "Sec-WebSocket-
    # Key MUST be a randomly selected 16-byte value"
    (6455, "4.1", "keep"),
    # 4.2.1 Reading the Client's Opening Handshake -- minimal validation
    # the server MUST perform
    (6455, "4.2.1", "keep"),
    # 4.2.2 Sending the Server's Opening Handshake -- status 101;
    # Sec-WebSocket-Accept derivation from key + magic GUID
    (6455, "4.2.2", "keep"),
    # 5.1 Overview -- "a client MUST mask all frames that it sends to the
    # server"; "A server MUST NOT mask any frames that it sends to the
    # client"
    (6455, "5.1", "keep"),
    # 5.2 Base Framing Protocol -- FIN + RSV + opcode + MASK + payload
    # len; opcodes 0x0/0x1/0x2/0x8/0x9/0xA defined
    (6455, "5.2", "keep"),
    # 5.3 Client-to-Server Masking -- "The masking key is a 32-bit value
    # chosen at random by the client"; XOR-with-modulo-4 algorithm
    (6455, "5.3", "keep"),
    # 5.4 Fragmentation -- continuation opcode 0x0; "Control frames
    # themselves MUST NOT be fragmented"
    (6455, "5.4", "keep"),
    # 5.5 Control Frames -- "All control frames MUST have a payload length
    # of 125 bytes or less and MUST NOT be fragmented"
    (6455, "5.5", "keep"),
    # 5.5.1 Close -- opcode 0x8; status code in first 2 bytes of payload;
    # MUST close underlying TCP after Close exchange
    (6455, "5.5.1", "keep"),
    # 5.5.2 Ping -- opcode 0x9; "Upon receipt of a Ping frame, an
    # endpoint MUST send a Pong frame in response"
    (6455, "5.5.2", "keep"),
    # 5.5.3 Pong -- opcode 0xA; identical Application data in Pong as in
    # Ping
    (6455, "5.5.3", "keep"),
    # 5.6 Data Frames -- text frame is UTF-8 encoded; binary frame
    # interpretation by application
    (6455, "5.6", "keep"),
    # 5.8 Extensibility -- reserved bits + opcodes for future extensions
    (6455, "5.8", "keep"),
    # 6.1 Sending Data -- endpoint MUST be in OPEN state; UTF-8 required
    # for text frame data
    (6455, "6.1", "keep"),
    # 6.2 Receiving Data -- "If the data is text, the data is delivered
    # ... as UTF-8"
    (6455, "6.2", "keep"),
    # 7.1.1 Close the WebSocket Connection -- "MUST close the underlying
    # TCP connection"; client cleanup expectations
    (6455, "7.1.1", "keep"),
    # 7.1.7 Fail the WebSocket Connection -- abnormal close; SHOULD log
    # the failure
    (6455, "7.1.7", "keep"),
    # 7.4.1 Defined Status Codes -- 1000 normal, 1001 going away, 1002
    # protocol error, etc.
    (6455, "7.4.1", "keep"),
    # 7.4.2 Reserved Status Code Ranges -- 0-999 not used; 1000-2999 IETF
    # range; 3000-3999 registered; 4000-4999 private
    (6455, "7.4.2", "keep"),
    # 10.3 Attacks On Infrastructure (Masking) -- justification for
    # masking; cache-poisoning risk without it
    (6455, "10.3", "keep"),

    # ---------- RFC 7519 (JSON Web Token) ----------
    # 1 Introduction -- "JWTs are always represented using the JWS Compact
    # Serialization or the JWE Compact Serialization"
    (7519, "1", "keep"),
    # 3 JSON Web Token (JWT) Overview -- "A JWT is represented as a
    # sequence of URL-safe parts separated by period ('.') characters"
    (7519, "3", "keep"),
    # 4 JWT Claims -- "The Claim Names within a JWT Claims Set MUST be
    # unique"
    (7519, "4", "keep"),
    # 4.1.1 "iss" -- identifies the principal that issued the JWT;
    # case-sensitive StringOrURI
    (7519, "4.1.1", "keep"),
    # 4.1.2 "sub" -- identifies the principal that is the subject of the
    # JWT; "MUST either be scoped to be locally unique in the context of
    # the issuer or be globally unique"
    (7519, "4.1.2", "keep"),
    # 4.1.3 "aud" -- "Each principal intended to process the JWT MUST
    # identify itself with a value in the audience claim"
    (7519, "4.1.3", "keep"),
    # 4.1.4 "exp" -- "identifies the expiration time on or after which the
    # JWT MUST NOT be accepted for processing"
    (7519, "4.1.4", "keep"),
    # 4.1.5 "nbf" -- "identifies the time before which the JWT MUST NOT be
    # accepted for processing"
    (7519, "4.1.5", "keep"),
    # 4.1.6 "iat" -- identifies the time at which the JWT was issued;
    # value MUST be NumericDate
    (7519, "4.1.6", "keep"),
    # 4.1.7 "jti" -- "provides a unique identifier for the JWT"; collision
    # prevention rule
    (7519, "4.1.7", "keep"),
    # 4.2 Public Claim Names -- "any new Claim Name should either be
    # registered ... or be a Public Name: a value that contains a
    # Collision-Resistant Name"
    (7519, "4.2", "keep"),
    # 4.3 Private Claim Names -- "Private Claim Names are subject to
    # collision and should be used with caution"
    (7519, "4.3", "keep"),
    # 5.1 "typ" -- "RECOMMENDED that its value be \"JWT\""
    (7519, "5.1", "keep"),
    # 5.2 "cty" -- nested JWT signal; "MUST be present" for Nested JWT
    (7519, "5.2", "keep"),
    # 5.3 Replicating Claims as Header Parameters -- "application receiving
    # them SHOULD verify that their values are identical"
    (7519, "5.3", "keep"),
    # 6 Unsecured JWTs -- "alg" Header Parameter value "none"; empty
    # signature
    (7519, "6", "keep"),
    # 7.1 Creating a JWT -- 6-step creation procedure
    (7519, "7.1", "keep"),
    # 7.2 Validating a JWT -- 10-step validation procedure; "If any of
    # the listed steps fail, then the JWT MUST be rejected"
    (7519, "7.2", "keep"),
    # 7.3 String Comparison Rules -- comparison rules from JSON; "These
    # comparison rules MUST be used for all JSON string comparisons except
    # in cases where the definition of the member explicitly calls out"
    (7519, "7.3", "keep"),
    # 8 Implementation Requirements -- "only HMAC SHA-256 (\"HS256\") and
    # \"none\" MUST be implemented by conforming JWT implementations"
    (7519, "8", "keep"),
    # 9 URI for Declaring that Content is a JWT -- registers
    # urn:ietf:params:oauth:token-type:jwt
    (7519, "9", "keep"),
    # 10.3 Media Type Registration -- "application/jwt" media type
    (7519, "10.3", "keep"),
    # 11.1 Trust Decisions -- "contents of a JWT cannot be relied upon in
    # a trust decision unless its contents have been cryptographically
    # secured and bound to the context necessary for the trust decision"
    (7519, "11.1", "keep"),
    # 11.2 Signing and Encryption Order -- order matters; sign then
    # encrypt vs encrypt then sign
    (7519, "11.2", "keep"),
    # 12 Privacy Considerations -- "a JWT may contain privacy-sensitive
    # information and, when this is the case, measures MUST be taken"
    (7519, "12", "keep"),

    # ---------- RFC 2119 (RFC Key Words) ----------
    # (RFC 2119 is intentionally short; ~7 in-scope sections.)
    # 1 MUST -- "absolute requirement of the specification"
    (2119, "1", "keep"),
    # 2 MUST NOT -- "absolute prohibition of the specification"
    (2119, "2", "keep"),
    # 3 SHOULD -- "there may exist valid reasons in particular
    # circumstances to ignore a particular item, but the full
    # implications must be understood and carefully weighed before
    # choosing a different course"
    (2119, "3", "keep"),
    # 4 SHOULD NOT -- "valid reasons in particular circumstances when the
    # particular behavior is acceptable or even useful"
    (2119, "4", "keep"),
    # 5 MAY -- "An implementation which does not include a particular
    # option MUST be prepared to interoperate with another implementation
    # which does include the option, though perhaps with reduced
    # functionality"
    (2119, "5", "keep"),
    # 6 Guidance in the use of these Imperatives -- "MUST only be used
    # where it is actually required for interoperation or to limit
    # behavior which has potential for causing harm"
    (2119, "6", "keep"),
    # 7 Security Considerations -- effects of not implementing a MUST/
    # SHOULD may be very subtle
    (2119, "7", "keep"),
]
