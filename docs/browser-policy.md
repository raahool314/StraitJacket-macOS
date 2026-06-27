# Browser policy: why the child is restricted to Firefox

## TL;DR

StraitJacket blocks **every web browser except Firefox** for the child account
(see [`config/appblock.txt`](../config/appblock.txt)). This is deliberate.
Per-subdomain DNS/hosts blocking — the core of how StraitJacket filters the web —
is silently bypassed by Safari and all Chromium browsers due to **HTTP/2/3
connection coalescing**. Firefox does not exhibit the bypass, so it is the one
allowed browser.

## The problem: connection coalescing defeats DNS blocking

StraitJacket blocks sites by sinkholing their domains (answering `0.0.0.0` / `::`
from the local DNS server and `/etc/hosts`). This works only if the browser
actually performs a DNS lookup for the blocked hostname before connecting.

Modern browsers don't always do that. Under HTTP/2 (and HTTP/3), a browser may
**reuse an existing TLS connection for a different hostname** if:

1. the server's TLS certificate is valid for the new hostname, and
2. (depending on the browser) the new hostname's IP overlaps the connection's IP.

Google is the worst case. Almost all of `*.google.com` is served from a shared
set of front-end IPs under a single wildcard certificate. So when the browser
already has a connection open to an **allowed** Google host — e.g.
`play.google.com`, `mail.google.com`, `www.gstatic.com` — it can fetch a
**blocked** one — e.g. `news.google.com` — over that same socket, **without ever
doing a DNS lookup**. The sinkhole and `/etc/hosts` are never consulted.

### Observed evidence

From a Safari HAR captured on this machine, with `news.google.com` sinkholed:

```
news.google.com  -> 2404:6800:4007:802::200e
play.google.com  -> 2404:6800:4007:802::200e   # identical IP — same connection
```

`dig news.google.com @127.0.0.1` correctly returned `0.0.0.0`, yet Safari loaded
the page from a real Google IP — because it coalesced onto the `play.google.com`
connection.

## Why this can't be fixed at the DNS layer

You cannot selectively block one `*.google.com` host while allowing others
(Gmail, Drive, Maps, Play). They share IPs **and** one certificate, so any open
connection to an allowed Google service is a usable path to a blocked one. The
only DNS-level "fix" is to block **all** of Google, which also breaks Gmail,
Drive, Maps, and Play — unacceptable collateral. IP-level (`pf`) and SNI-based
filtering fail for the same reasons (shared anycast IPs; the real hostname lives
in the encrypted HTTP/2 `:authority` header, not in a new TLS ClientHello).

## Browser behavior

| Browser | Engine | Honors per-subdomain DNS block? |
|---------|--------|----------------------------------|
| **Firefox** | Gecko | **Yes** — re-checks DNS, does not coalesce across the block |
| Safari | WebKit | No — coalesces aggressively on the certificate |
| Chrome / Edge / Brave / Opera / Vivaldi / Arc / … | Chromium | No — coalesces onto shared-IP connections |

## The decision

- **Allowed:** Firefox (`org.mozilla.firefox`).
- **Blocked for the child:** Safari and all Chromium/WebKit browsers, by bundle
  id, via the app-block layer (poll-and-kill within ~2s; deny-execute ACL where
  the app isn't SIP-protected).

Notes:
- Safari is SIP-protected, so it can't be ACL-blocked; the poll-and-kill layer
  terminates it for the child UID instead.
- Tor Browser and other Firefox forks run an executable literally named
  `firefox`, so they are blocked by **bundle id** — never by a bare `firefox`
  exec-name rule, which would also kill the allowed Firefox.
- This only affects the child account (`childUsername`); the parent's browsers
  are untouched.
- A newly installed browser not in the list won't be blocked until its bundle id
  is added (`sudo parentctl block-app <bundleid>`).

## Defense in depth (optional)

For the most stubborn cases you can additionally enable macOS **Screen Time →
Content & Privacy → Web Content** restrictions, which filter inside Safari/WebKit
at the URL level and are not subject to connection coalescing.
