# Changelog

## 1.0.0-beta.1 — first public release

Copilot & Agent Readiness for Microsoft 365: a free, read-only tenant check for Microsoft 365 Copilot and AI
agents. One command, one browser sign-in, one offline HTML report in German and English.

### Checks
- 41 checks in six areas: Oversharing & access, Protect data, Agents, Identity for AI, Defender & shadow AI,
  Audit & evidence. 28 of them read Microsoft Graph; the rest use the optional Purview, SharePoint and
  Power Platform readers or a portal step.
- Agents: agent identities and their owners (Entra Agent ID), agent sharing, sign-in and maker connections
  (Power Platform inventory, preview fields), Power Platform DLP coverage for agent environments.
- Oversharing: tenant sharing level, sharing hygiene, public groups (Viva Engage system groups excluded),
  ownerless groups, inactive sites, external sharing activity, inactive guests, Restricted Content Discovery
  and Restricted Access Control, data access governance reports.
- Protect data: sensitivity labels and their scopes, label policies, auto-labelling, labels on real content,
  retention labels, DLP for Copilot (prompts and labelled content), DLP coverage of exits.
- Identity for AI: Conditional Access for MFA, legacy authentication and managed devices (state, scope,
  exclusions, authentication strengths), MFA registration, Global Administrators (also through groups),
  guest settings, app consent, risk-based sign-in, phishing-resistant MFA for admins, apps with high-risk
  Graph permissions, permanent versus eligible admin roles.
- Audit & evidence: audit log searchable, Copilot interactions in the audit log, Entra log retention,
  retention for Copilot interactions (old and new retention locations), alerts for DLP and data.

### Honest results
- Only OK / Review / Act are scored. Not licensed, No permission, Manual, Unknown, Not applicable and Info are
  grey and never count as a pass; a failed or incomplete read is always *Unknown*.
- Score of the assessed checks next to coverage, per area and overall. No overall verdict below 70 % coverage
  or when an area is below 25 %.
- 30 / 60 / 90-day action plan, evidence gaps and licence decisions.

### Sign-in and trust
- Delegated sign-in through Microsoft's *Graph Command Line Tools*: no app registration, no client secret.
  11 read permissions by default, 3 more with `-Deep`.
- A disclosure page before the sign-in; the tenant is shown before the first check; with `-TenantId` a sign-in
  to another tenant stops the run.
- Optional saved sign-in (refresh token only, DPAPI, current Windows user); `-Logout`, `-NoTokenCache`.
- Read-only by design and by test: readers may only run `Get-` cmdlets, the code talks to Microsoft endpoints
  only, and no write call exists. The one object created is a Purview audit search.
- Console and report in German or English (`-Language`); the report switches language inside.
