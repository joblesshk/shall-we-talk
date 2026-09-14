# Security policy

## Reporting

For this private repository, use GitHub private vulnerability reporting when available, or contact the repository owner privately through an existing authorized channel. Do not put credentials, private URLs, user audio or diagnostic exports in public issues. If no private reporting route is available, open an issue containing only a request for secure contact, without exploit details or sensitive data.

No response SLA or independently audited security claim is made. The current main branch is the supported development line.

## Secrets

Provider credentials are entered by the user and persisted using Keychain. Never commit keys, tokens, enrollment grants, signing files, `.env` contents or private endpoints. CI requires no production credentials. Public vendor API URLs and fake test tokens are not production credentials.

If a real credential is exposed, revoke/rotate it with its provider, investigate access and then remove it from all affected history/artifacts. A later deletion commit alone is insufficient. This repository starts with sanitized history; the original private history was not pushed.

## Boundaries

Network relay placeholders use reserved `.invalid` hosts and are nonfunctional. Direct API calls use your configured provider and may incur charges. Review permissions, provider data policies, diagnostic logging and optional iCloud sync before using sensitive recordings. See PRIVACY.md.
