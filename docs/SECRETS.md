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
