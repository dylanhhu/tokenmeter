# Security

## Reporting

Open a private security advisory on the repository (Security → Report a
vulnerability) rather than a public issue. Include reproduction steps and the
affected version from Settings → About.

## Credential handling

TokenMeter handles provider API keys, which are bearer secrets for billing-adjacent
APIs. The rules the code enforces:

- Keys are stored in the **login Keychain** with `kSecAttrAccessibleAfterFirstUnlock`,
  as generic passwords under the service `com.dylanhu.TokenMeter.credentials`,
  keyed by provider id. They are never written to `settings.json`, `UserDefaults`,
  or any log stream.
- Keys are read only when constructing a provider client, and live in memory for
  the duration of a refresh.
- Error messages from the network layer pass through the provider's own message
  text; they never echo the credential. `SecretRedactor` handles the case where a
  key must be shown back to the user (truncated to a recognisable prefix).
- Requests go only to the configured provider's API host over HTTPS. There is no
  telemetry, analytics, or crash reporting.

The SwiftLint configuration includes a custom rule (`no_credentials_in_logs`)
that fails the build if a log call interpolates a credential-like identifier.

## Recommended credentials

Use a **management key**, not a provisioning or inference key. Management keys
cannot make model requests at all, so a leak limits an attacker to reading usage
data. Create one at <https://openrouter.ai/settings/management-keys> and revoke it
there if it is ever exposed.

## Things this app deliberately cannot do

- Make inference requests
- Create, modify, or delete API keys
- Change budgets or credit limits
- Persist your spend history locally

The management endpoints it uses are `GET /api/v1/key`, `GET /api/v1/credits`,
`GET /api/v1/analytics/meta`, and `POST /api/v1/analytics/query`. See
`docs/ARCHITECTURE.md`.
