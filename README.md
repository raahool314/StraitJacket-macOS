# StraitJacket for macOS

A tamper-resistant **parental-control daemon for macOS**, modeled on the Windows
[StraitJacket](https://github.com/raahool314/StraitJacket). It blocks domains and
apps for a child's account from a root `launchd` daemon that auto-restarts and
re-applies its policy on a timer, so a Standard (non-admin) user can't disable it.

This is the **pragmatic port**: pure Swift, no Apple Developer account, no
notarization, no System Extensions. You build it and install it with a script.

## How it works

| Layer | Mechanism |
|-------|-----------|
| **Domain blocking** | A local **DNS sinkhole** on `127.0.0.1:53` (exact-name matching — a `www.` variant is added automatically, but subdomains are not implicitly blocked; answers blocked names with `0.0.0.0`/`::`, forwards everything else upstream) **plus** a managed block in **`/etc/hosts`**. System DNS is repointed to the sinkhole via `networksetup`. |
| **App blocking** | **Filesystem ACLs** denying the child `execute` on blocked app binaries **plus** a **poll-and-kill** loop that `SIGKILL`s blocked processes owned by the child (the backstop for copied/SIP-protected apps). |
| **Feeds** | Remote blocklists (e.g. StevenBlack's ~77k-domain adult list) downloaded at boot and daily, fed into the DNS sinkhole. |
| **Browser policy** | A root-owned **Firefox enterprise policy** at `/Applications/Firefox.app/Contents/Resources/distribution/policies.json` blocks the full `duckduckgo.com` UI at the URL layer (with an exception for `lite.duckduckgo.com`) and locks the address-bar default search engine to a custom DDG Lite entry. Needed because macOS `mDNSResponder` chases CNAME targets, so a DNS-layer block on `duckduckgo.com` would also break `lite.duckduckgo.com` — see [docs/browser-policy.md](docs/browser-policy.md). |
| **Enforcement** | A root `launchd` daemon (`RunAtLoad` + `KeepAlive`) re-asserts every layer on a slow cycle (~30s) and kills blocked apps on a fast cycle (~2s). |

The parent is an **Admin** user; the child is a **Standard** user. Tamper
resistance comes from that split: the child can't unload the daemon, edit the
root-owned policy files, or run `parentctl` (it requires `sudo`).

## Install

Requires the Swift toolchain (Xcode or `xcode-select --install`).

```bash
git clone https://github.com/<you>/straitjacket_for_mac_users.git
cd straitjacket_for_mac_users
sudo ./install.sh        # builds, installs the daemon, prompts for the child account
```

> **macOS 13+ (Ventura/Sonoma) note:** writing the Firefox enterprise policy
> into `Firefox.app` requires **App Management** permission. Before running
> `install.sh`, open *System Settings → Privacy & Security → App Management* and
> toggle on whichever terminal you'll run `sudo` from (Terminal, iTerm, etc.).
> Without it, the daemon still installs, but the URL-layer DDG block won't be
> applied.

Then manage policy with `parentctl` (always via `sudo`):

```bash
sudo parentctl status
sudo parentctl add-domain reddit.com
sudo parentctl block-app com.valvesoftware.steam
sudo parentctl pause 30        # lift blocks for 30 min (e.g. for the parent)
sudo parentctl resume
sudo parentctl list
```

## Configuration

Everything lives under `/Library/Application Support/StraitJacket/` (root-owned):

| File | Purpose |
|------|---------|
| `config.json` | Child account, poll/reassert intervals, upstream DNS |
| `blocklist.txt` | Curated domains (DNS **and** `/etc/hosts`) |
| `hostsonly.txt` | Extra domains for both layers |
| `appblock.txt` | Apps to block (bundle id, `.app` path, or exec name) |
| `feeds.txt` | Remote blocklist URLs |
| `firefox-policies.json` *(in `config/`)* | Firefox `WebsiteFilter` + `SearchEngines` policy; installed into `Firefox.app/Contents/Resources/distribution/` by `install.sh` |

## Uninstall

```bash
sudo ./uninstall.sh           # stops daemon, restores DNS/hosts/ACLs, keeps policy
sudo ./uninstall.sh --purge   # also deletes the policy files
```

## Known limitations

- **DNS-over-HTTPS** bypasses the sinkhole. Browsers with "Secure DNS"/DoH
  enabled (Chrome, Firefox) resolve names themselves. Mitigate by disabling DoH
  in the child's browser and/or adding known DoH endpoints to the blocklist.
- **Connection coalescing** lets Safari (WebKit) and Chromium browsers reach a
  blocked `*.google.com` subdomain over an open connection to an allowed one,
  bypassing per-subdomain DNS blocks. The child account is therefore restricted
  to **Firefox**, which honors the blocks — see [docs/browser-policy.md](docs/browser-policy.md).
- **VPNs / proxies** tunnel around DNS and hosts filtering entirely.
- **SIP-protected system apps** (`/System`) can't be ACL-blocked — they rely on
  the poll-and-kill layer only.
- **Port 53 conflicts** (another resolver already bound) disable the DNS layer;
  the `/etc/hosts` layer still applies.
- A child who obtains the **admin password** can defeat everything — by design.

## Project layout

```
Sources/SJCore      Shared models: Config, DomainBlocklist, AppBlocker, paths, shell
Sources/parentd     The daemon: DNS sinkhole, hosts/network/feed managers, loop
Sources/parentctl   Admin CLI
config/             Default policy templates
com.straitjacket.mac.plist   launchd job
install.sh / uninstall.sh    Scripts
```
