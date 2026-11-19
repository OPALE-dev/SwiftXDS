# Security Policy

SwiftXDS reads untrusted input: SOAP envelopes, MTOM/XOP multipart streams,
and ebRIM metadata received from registries and repositories, over TLS or not.
Security reports are welcome and are handled privately until a fix is
available.

## Supported versions

| Version | Supported |
| --- | --- |
| `main` and the latest release | ✓ |
| Earlier releases | ✗ |

## Reporting a vulnerability

Do not open a public issue. Use one of these private channels:

- GitHub: **Security → Report a vulnerability** on
  [OPALE-dev/SwiftXDS](https://github.com/OPALE-dev/SwiftXDS/security/advisories/new);
- email: rw@opale.pro.

Please include the affected revision, the platform, and a minimal reproducer.
Do not attach messages or documents that contain patient data: reduce the
input to a synthetic case, or describe how to build one.

You can expect an acknowledgement within five working days. Once a fix is
available, it is released with a GitHub Security Advisory that credits the
reporter, unless you prefer to stay anonymous.

## Scope

In scope:

- crashes, hangs, or unbounded memory or disk use when reading malformed XML,
  SOAP, or MTOM input, including bypasses of `XMLReader.Limits` and
  `MultipartLimits`;
- DTD or entity processing in the XML reader;
- header or MIME injection in written requests;
- path traversal when MTOM parts are written to files;
- TLS configuration defects in the HTTP transport.

Out of scope: `SwiftXDSTestRegistry` and its HTTP server, which are made for
tests and simulators, not for production use.

SwiftXDS is not a medical device. It claims no IHE conformance until it has
been tested against third-party actors.
