# Secrets policy

A private podcast feed URL carries its authentication token in the URL itself.
This repository is public: a committed URL is compromised the moment it is
pushed, and stays compromised — history is archived by third parties within
minutes.

## Rules

1. **No real feed URL appears anywhere in the repository.** Not in code, not in
   fixtures, not in tests, not in comments, not in commit messages, not in issue
   text.
2. Private feeds are added at runtime through the app UI and live only in the
   on-device SwiftData store.
3. Fixtures use the placeholder
   `https://example.com/feed?token=REDACTED_TEST_TOKEN`. It is allowlisted in
   `.gitleaks.toml` and must be the only token-shaped URL in the tree.
4. If a real URL is ever committed, **treat the token as burned**: regenerate it
   at the provider (Boosty, …) first, then clean the history. Order matters —
   rewriting history first buys nothing.
5. **No feed or enclosure URL reaches the log at `.public` privacy.** An
   enclosure of a private feed is pre-signed, so it is the same class of secret
   as the feed URL, and `os_log` interpolation renders an error's associated
   values — `DownloadManager.Failure.httpStatus(_, enclosureURL)` and
   `FeedService.Failure.httpStatus(_, url)` both carry one. A `.public` entry
   persists in the device log and in any sysdiagnose. Log at the default
   (private) privacy, or log the status and the episode guid instead.
6. **No enclosure URL reaches an on-screen alert either.** A screenshot or a
   support report carries the token just as a log does, so
   `downloadErrorMessage(for:)` renders the address through
   `redactedAddress(_:)`, which keeps the scheme and host and drops the
   userinfo, path, query and fragment — a signature can ride in any of them.
   The HTTP status is what spec §6 requires for diagnosis, and it survives
   redaction; the URL itself is not required and must not be shown.
   `downloadErrorMessage(for:)` also has no pass-through fallback: an
   unrecognised error yields a fixed sentence, never its `localizedDescription`,
   which can embed the failing URL. Feed-*add* errors deliberately still name
   the feed URL — spec §6 requires it for diagnosis — and that asymmetry is
   intentional.
7. **A plain-`http` feed sends its token in the clear.** ATS is disabled
   app-wide (`NSAppTransportSecurity` / `NSAllowsArbitraryLoads` in
   `cue/Support/Info.plist`), because feed addresses are pasted by the user and
   per-domain exceptions cannot be enumerated for them. A pre-signed `http://`
   feed and its enclosures therefore transit unencrypted: prefer `https` for any
   token-bearing feed, and treat an `http`-only private feed's token as exposed
   on any untrusted network. Note that `NSAllowsArbitraryLoads` with no
   `NSExceptionDomains` beside it turns ATS off for *every* connection, not only
   plain-`http` ones: an `https` feed or enclosure also loses the platform's TLS
   floor (minimum TLS 1.2, forward secrecy, certificate transparency), so a
   token-bearing request can be accepted over a weak TLS configuration without
   the app noticing.

8. **An exported diagnostics file is shareable output, and is designed to be.**
   The export exists so the owner can hand a device failure to an agent, so it
   leaves the device through the share sheet and is visible in Files. What it
   may contain: a timestamp, a level, a category, an event name, a scheme and
   host (`DiagnosticsHost`, the same `redactedAddress(_:)` reduction the alerts
   use), a truncated SHA-256 digest of an episode guid, an attempt identifier
   derived from an ownership token, byte counts, a queue position, a decile
   index, an elapsed-milliseconds duration, an HTTP status, a background task
   identifier (`URLSessionTask.taskIdentifier`, reused by iOS and therefore
   never used as the attempt identity), a bridged error domain and code, and —
   once per process on the launch record — the build identifier. What it must never contain: a full feed or enclosure
   URL, any userinfo, path, query or fragment, an unhashed guid, a container
   path, or an error's `localizedDescription` — all of which can carry a token.
   Those are not call-site habits: hosts and guids can only enter a record
   through opaque sanitising types, and the error field reduces to domain and
   code with the domain itself sanitised, so a new call site cannot smuggle text
   through. Adding a diagnostics field means adding it to that list here, or not
   adding it. The header block additionally carries the build, device model and
   system version, which are not secrets. A shared export is still device
   telemetry — treat it as you would a screenshot, not as public data.

## Running gitleaks locally

```sh
brew install gitleaks
```

```sh
gitleaks detect --no-git -v   # working tree, uses .gitleaks.toml
gitleaks git -v .             # full commit history
```

Both must report `no leaks found` before pushing. `.gitleaks.toml` extends the
default ruleset with two feed-specific rules: token-bearing URL query parameters
(`token`, `auth`, `access_token`, `key`, `secret`, … with an 8+ character value)
and long high-entropy path segments on known private-feed hosts.
