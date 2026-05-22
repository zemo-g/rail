"""Source fetchers for the citation verifier.

Each fetcher exposes:
    get_section(identifier, section) -> str | None

`identifier` shape is per-fetcher (an RFC number, a function name, etc).
`section` is a free-form section reference (e.g. "4", "4.3.4", "1.3").

Returns None if the source can't be fetched or the section can't be located.
"""
