<div align="center">

# 🛡️ Copilot & Agent Readiness für Microsoft 365

### Ist Ihr Microsoft 365 bereit für Microsoft 365 Copilot und KI-Agents?

**Ein Befehl. Eine Anmeldung. Ein Bericht.**
Kostenlos, quelloffen und **ausschließlich lesend**.

**[govnex.de](https://govnex.de)** · von [Rashad Bakirov](https://www.linkedin.com/in/rashadbakirov)

🇩🇪 Deutsch · [🇬🇧 English](README.en.md)

[![Nur lesend](https://img.shields.io/badge/Zugriff-nur%20lesend-2ea44f?style=for-the-badge)](#-warum-sie-diesem-tool-vertrauen-können)
[![Keine App-Registrierung](https://img.shields.io/badge/App--Registrierung-keine-0b7285?style=for-the-badge)](#-warum-sie-diesem-tool-vertrauen-können)
[![Daten bleiben lokal](https://img.shields.io/badge/Daten-bleiben%20auf%20Ihrem%20PC-5f3dc4?style=for-the-badge)](#-warum-sie-diesem-tool-vertrauen-können)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-012456?style=for-the-badge&logo=powershell)](#-loslegen)
[![MIT](https://img.shields.io/badge/Lizenz-MIT-868e96?style=for-the-badge)](LICENSE)

</div>

---

Microsoft 365 Copilot und KI-Agents sehen alles, was der Benutzer sehen darf — und das ist in den meisten
Tenants deutlich mehr als gedacht. Dieses Tool prüft **41 Punkte** in Ihrem Tenant und sagt Ihnen in einem
einzigen Bericht, was Sie **vor** dem Rollout in Ordnung bringen sollten: Oversharing, Labels, DLP für
Copilot, Agent-Verantwortliche, Identität und Nachweisbarkeit.

<div align="center">

### 👉 [Beispielbericht direkt im Browser ansehen](https://www.govnex.de/copilot-check/beispiel.html)

*Ein vollständiger Bericht, bevor Sie irgendetwas ausführen — auf govnex.de, ohne Download.*

</div>

![Übersicht des Berichts](docs/images/01-overview.png)

> 📄 Derselbe Bericht liegt auch im Repository:
> [`docs/beispielbericht-de.html`](docs/beispielbericht-de.html) · [English](docs/example-report-en.html)
> *(„Contoso Maschinenbau GmbH" — ein frei erfundenes Unternehmen. Kein echter Tenant, keine echten Daten.)*

---

## 🚀 Loslegen

Sie brauchen **PowerShell 7.2 oder neuer** und ein Konto mit Leserechten in Ihrem Tenant. Kein Modul, keine
App-Registrierung, kein Client Secret. Nur beim allerersten Lauf in einem Tenant muss einmal ein **Global
Administrator** den Leseberechtigungen zustimmen (siehe [Rollen](#-berechtigungen-im-detail)).

```powershell
git clone https://github.com/rashadbakirov/m365-copilot-readiness.git
cd m365-copilot-readiness

./Invoke-CopilotReadiness.ps1 -TenantId ihre-domain.de
```

Ohne git: auf GitHub **Code → Download ZIP**, entpacken, und einmal `Get-ChildItem -Recurse | Unblock-File`
im entpackten Ordner — Windows markiert heruntergeladene Skripte sonst als „aus dem Internet“.

Das war es. Was dann passiert:

| | Schritt | |
|:--:|---|---|
| 1️⃣ | **Aufklärungsseite** | Das Tool sagt Ihnen zuerst, was es tut, was es liest und was es niemals tut — und wartet auf Ihr Enter. |
| 2️⃣ | **Eine Anmeldung** | Ein Browserfenster, Sie wählen Ihr Konto. Nichts abzutippen. |
| 3️⃣ | **Tenant-Bestätigung** | Name, Domain, Tenant-ID und Konto werden angezeigt, bevor der erste Check läuft. Ohne `-TenantId` wartet das Tool hier auf Ihr Enter; mit `-TenantId` bricht es bei einem anderen Tenant ab. |
| 4️⃣ | **Bericht** | Eine HTML-Datei in `out\`, die sich von selbst öffnet. Offline lesbar, druckbar, auf Deutsch oder Englisch. |

**Eine Anmeldung** genügt für die 28 Graph-Checks. Jeder weitere Lauf im selben Tenant läuft ohne Fenster —
egal, ob Sie den Tenant als Domain oder als ID angeben.

<details>
<summary><b>Bis zu 40 Checks statt 28 (optional)</b></summary>

<br>

Drei Bereiche liegen hinter Microsoft-Modulen, die Sie selbst installieren — sie bleiben sonst auf
*Manuell* und senken nur die Abdeckung, der Lauf schlägt nie fehl:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser                       # Purview
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser         # SharePoint
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser  # Power Platform

./Invoke-CopilotReadiness.ps1 -Deep -Purview -SharePoint
./Invoke-CopilotReadiness.ps1 -Deep -PowerPlatform
```

⚠️ **`-Purview` und `-PowerPlatform` können nicht zusammen laufen.** Die beiden Module bringen
unterschiedliche Versionen von `Microsoft.Identity.Client` mit; nur das Modul, das sich zuerst anmeldet,
funktioniert. Geben Sie beides an, behält Purview die Sitzung und das Tool sagt es Ihnen.

</details>

---

## 🔒 Warum Sie diesem Tool vertrauen können

Sie geben einem fremden Skript Zugriff auf Ihren Tenant. Diese Sorge ist berechtigt — deshalb beginnt
**jeder** Lauf mit dieser Seite, bevor ein einziger Aufruf passiert:

```text
  Vor der Anmeldung — was dieses Tool tut und was nicht
  ----------------------------------------------------------------------------

  Nur lesend. Es werden ausschließlich Leseberechtigungen angefragt ('.Read');
  andere kann der Code nicht aufrufen. In Ihrem Tenant wird nichts geändert,
  aktiviert, gelöscht oder konfiguriert.

  Es handelt ausschließlich in Ihrem Namen. Die Anmeldung ist delegiert: Das
  Tool sieht genau das, was Ihr eigenes Konto sehen darf — nicht mehr. ...

  Berechtigungen, die angefragt werden (11):
    - Organization.Read.All
    - Directory.Read.All
    ...

  Enter zum Anmelden, Strg+C zum Abbrechen.
```

| | |
|---|---|
| 👁️ **Nur lesend** | Es werden nur `.Read`-Berechtigungen angefragt. Die optionalen Leser dürfen im Code ausschließlich `Get-`-Cmdlets aufrufen — das ist erzwungen, nicht versprochen. |
| 👤 **Nur Ihr Konto** | Delegierte Anmeldung über Microsofts eigene App *Graph Command Line Tools*. Keine App-Registrierung, kein Client Secret, kein Dienst, der danach weiterläuft. Ohne angemeldeten Menschen passiert gar nichts. |
| 💻 **Ihre Daten bleiben hier** | Bericht und JSON entstehen in `out\` auf Ihrem PC. Nichts wird hochgeladen, keine Telemetrie, govnex sieht Ihre Ergebnisse nie. |
| ✍️ **Genau ein Objekt** | Angelegt wird nur eine Purview-Audit-Suche (eine gespeicherte Suche) nach Copilot-Interaktionen der letzten 7 Tage, gebraucht von N01/N02. Sonst nichts. Purview zeigt sie unter Audit → Suche und räumt sie nach 30 Tagen selbst auf; jeder Lauf legt eine neue an, es sei denn, Sie geben mit `-AuditQueryId` eine bestehende an. |
| 🔑 **Jederzeit widerrufbar** | Entra → Unternehmensanwendungen → *Microsoft Graph Command Line Tools* → Berechtigungen. `-Logout` löscht die gespeicherte Anmeldung auf Ihrem PC. |
| 📖 **Nachlesbar** | MIT-Lizenz, vollständiger Quellcode, jede Berechtigung unten mit dem Check dokumentiert, der sie braucht. |

> **Zur Zustimmung:** Die Berechtigungen unten brauchen eine Administrator-Zustimmung. Erteilt ein Global
> Administrator sie, gilt sie **tenantweit und dauerhaft, bis sie widerrufen wird** — so funktioniert
> Entra, nicht nur dieses Tool. Sie gilt für Microsofts App *Graph Command Line Tools*, die auch das
> *Microsoft Graph PowerShell SDK* nutzt: Ein Widerruf trifft also auch Ihre Admins, die damit arbeiten.

---

## 📊 Was Sie im Bericht sehen

**Sechs Bereiche, ein Score, eine ehrliche Abdeckung.** Jeder Bereich beantwortet: *Warum zählt das für
Copilot und Agents?*

![Die sechs Bereiche](docs/images/02-areas.png)

**Jeder Check zeigt den Nachweis aus Ihrem Tenant** — keine Behauptung ohne Zahlen: was gefunden wurde,
warum es für Copilot zählt, was zu tun ist, wo im Admin Center, und die passende Microsoft-Learn-Seite.
Hier der Bereich **Agents**: wer die Agents gebaut hat, wem sie gehören, und wer sich darum kümmert,
wenn diese Person das Unternehmen verlässt.

![Der Bereich Agents mit Nachweis aus dem Tenant](docs/images/03-check.png)

**Und am Ende steht kein Problemhaufen, sondern ein Plan** — nach Aufwand und Gewicht sortiert auf
30 / 60 / 90 Tage, plus die Lücken, die Sie zuerst schließen sollten, und die reinen Lizenzentscheidungen.

![Maßnahmenplan 30/60/90](docs/images/04-plan.png)

**Das Tool sagt Ihnen auch, was es *nicht* wusste.** Jeder Lauf beginnt mit einer Vorprüfung: Welche Leser
waren verbunden, welche Lizenzen fehlen, welche Checks konnten deshalb nicht laufen. Ein Check ohne Daten
wird nie grün.

![Vorprüfung: was lief und was nicht](docs/images/05-caps.png)

---

## 🧮 Ergebniszustände und Score

Nur **OK / Prüfen / Handeln** werden bewertet. Alles andere ist grau und zählt nie als bestanden.

| Zustand | Bedeutung | Bewertet | In der Abdeckung |
|---|---|---|---|
| 🟢 **OK** / 🟡 **Prüfen** / 🔴 **Handeln** | geprüft und bewertet | ja | ja |
| ⚪ Nicht lizenziert | die Lizenz fehlt im Tenant | nein | ja (senkt die Abdeckung) |
| ⚪ Keine Berechtigung | das Konto durfte nicht lesen (401/403) | nein | ja |
| ⚪ Manuell | braucht einen optionalen Leser oder das Portal | nein | ja |
| ⚪ Unbekannt | der Lesezugriff schlug fehl oder war unvollständig | nein | ja |
| ⚪ Nicht zutreffend | trifft nicht zu (z. B. keine Gäste) | nein | nein |
| ⚪ Info | nur Kontext (z. B. Copilot-Nutzung) | nein | nein |

**Score** = gewichteter Durchschnitt (Gewicht 1 bis 3) der bewerteten Checks. Der Score eines einzelnen Checks
bleibt im Band seines Zustands (OK ≥ 75, Prüfen 45–74, Handeln < 45), damit Farbe und Zahl nie widersprechen.
**Abdeckung** = bewertetes Gewicht ÷ Gewicht aller zutreffenden Checks.
Ein Gesamturteil gibt es nur ab **70 % Abdeckung** und mindestens 25 % je Bereich — sonst sagt der Bericht
ehrlich **Unvollständig**. Die Schwellen stehen in `src/Manifest.json`.

---

## ✅ Was geprüft wird

<!-- checks:start -->
| ID | Bereich | Check | Leser | Bewertet | Gewicht |
|---|---|---|---|---|---|
| S01 | Oversharing & Zugriff | Copilot-Lizenzen und Zuweisung | Graph | ja | 2 |
| S02 | Oversharing & Zugriff | Copilot-Nutzung (Adoption, nicht bewertet) | Graph | Info | 1 |
| S03 | Oversharing & Zugriff | Externe Freigabe auf Tenant-Ebene | Graph | ja | 3 |
| S04 | Oversharing & Zugriff | Freigabe-Hygiene | Graph | ja | 1 |
| S05 | Oversharing & Zugriff | Öffentliche Microsoft-365-Gruppen und Teams | Graph | ja | 3 |
| S06 | Oversharing & Zugriff | Gruppen ohne Owner | Graph | ja | 2 |
| S07 | Oversharing & Zugriff | Inaktive SharePoint-Sites | Graph | ja | 2 |
| S08 | Oversharing & Zugriff | Externe Freigaben pro Nutzer (Aktivität) | Graph | ja | 1 |
| S09 | Oversharing & Zugriff | Gäste ohne Aktivität | Graph | ja | 2 |
| S11 | Oversharing & Zugriff | Restricted Content Discovery und Restricted Access Control je Site | `-SharePoint` | ja | 2 |
| S12 | Oversharing & Zugriff | Oversharing-Berichte (Data access governance): vorhanden und aktuell | `-SharePoint` | ja | 2 |
| K01 | Daten schützen | Sensitivity Labels im Tenant | Graph | ja | 3 |
| K02 | Daten schützen | Labels für Teams, Gruppen und Sites | Graph | ja | 2 |
| K03 | Daten schützen | Label-Richtlinie: Standard-Label und Pflicht | `-Purview` | ja | 2 |
| K04 | Daten schützen | Automatische Label-Vergabe | `-Purview` | ja | 2 |
| K05 | Daten schützen | Labels auf echten Inhalten (DAG-Label-Bericht) | `-SharePoint` | ja | 2 |
| K06 | Daten schützen | Aufbewahrungs-Labels | Graph | ja | 1 |
| B01 | Daten schützen | DLP für Copilot: sensible Daten in Prompts *(Preview-Felder)* | `-Purview` | ja | 2 |
| B05 | Daten schützen | DLP für Copilot: gelabelte Dateien und Mails | `-Purview` | ja | 2 |
| B02 | Daten schützen | DLP-Abdeckung der Ausgänge | `-Purview` | ja | 2 |
| A01 | Agents | Agent-Identitäten mit Verantwortlichen | Graph | ja | 3 |
| A02 | Agents | Agents: Freigabe, Anmeldung und Maker-Verbindungen *(Preview-Felder)* | `-PowerPlatform -PowerPlatformClientId` | ja | 3 |
| A03 | Agents | Power-Platform-DLP für Agent-Umgebungen | `-PowerPlatform` | ja | 2 |
| Z01 | Identität für KI | MFA für alle Nutzer per Conditional Access | Graph | ja | 3 |
| Z02 | Identität für KI | Legacy-Authentifizierung blockiert | Graph | ja | 2 |
| Z03 | Identität für KI | Verwaltetes Gerät für Microsoft 365 | Graph | ja | 2 |
| Z04 | Identität für KI | MFA-Registrierung | Graph | ja | 2 |
| Z05 | Identität für KI | Globale Administratoren | Graph | ja | 2 |
| Z06 | Identität für KI | Gast-Einladungen und Gastrolle | Graph | ja | 1 |
| Z07 | Identität für KI | Wer Apps und Agents Zugriff geben darf | Graph | ja | 2 |
| I01 | Identität für KI | Risikobasierte Anmeldung (Anmelde- und Benutzerrisiko) | Graph | ja | 2 |
| I02 | Identität für KI | Phishing-resistente MFA für Admins | Graph | ja | 3 |
| I03 | Identität für KI | Apps und Agents mit weitreichenden Rechten | Graph | ja | 2 |
| I04 | Identität für KI | Admin-Rollen: dauerhaft aktiv oder nur berechtigt (PIM) | Graph | ja | 2 |
| S10 | Defender & Schatten-KI | Secure Score: offene Daten- und Identitäts-Maßnahmen | Graph | ja | 1 |
| D01 | Defender & Schatten-KI | Schatten-KI: genutzte KI-Dienste (Prüfung im Portal) | Portal (manuell) | Info | 1 |
| N01 | Audit & Nachweis | Audit-Log durchsuchbar | Graph | ja | 3 |
| N02 | Audit & Nachweis | Copilot-Interaktionen im Audit-Log | Graph | ja | 2 |
| N03 | Audit & Nachweis | Aufbewahrung der Entra-Logs (Info) | Graph | Info | 1 |
| B03 | Audit & Nachweis | Aufbewahrung für Copilot-Interaktionen | `-Purview` | ja | 2 |
| N04 | Audit & Nachweis | Warnungen für DLP und Daten | `-Purview` | ja | 1 |
<!-- checks:end -->

Nicht mehr enthalten: B04 Restricted SharePoint Search (Microsoft stellt es ein, Ersatz ist S11) und
B06 Copilot-Admin-Einstellungen (keine dokumentierte Lese-API).

---

## 🔑 Berechtigungen im Detail

Alle Berechtigungen sind **Leseberechtigungen**. Standardmäßig werden nur die 11 des Kernsatzes angefragt;
`-Deep` fragt zusätzlich die drei neueren an, von denen nur **A01** eine zwingend braucht.

<!-- scopes:start -->
| Berechtigung | Satz | Gebraucht von |
|---|---|---|
| `Organization.Read.All` | core | S01, N03 |
| `Directory.Read.All` | core | S01, S05, S06, S09, Z05, I03 |
| `Policy.Read.All` | core | Z01, Z02, Z03, Z06, Z07, I01, I02 |
| `Reports.Read.All` | core | S02, S07, S08 |
| `AuditLog.Read.All` | core | S09, Z04 |
| `SecurityEvents.Read.All` | core | S10 |
| `SharePointTenantSettings.Read.All` | core | S03, S04 |
| `RoleManagement.Read.Directory` | core | Z05, I04 |
| `AuditLogsQuery.Read.All` | core | N01, N02 |
| `InformationProtectionPolicy.Read` | core | K01, K02 |
| `RecordsManagement.Read.All` | core | K06 |
| `SensitivityLabel.Read` | extended | K01, K02 |
| `ReportSettings.Read.All` | extended | S07 |
| `AgentIdentity.Read.All` | extended | A01 |
<!-- scopes:end -->

**Rollen:** Die erste Anmeldung braucht einmalig einen **Global Administrator** (oder Privileged Role
Administrator) für die Zustimmung. Danach genügt **Global Reader**. Einzelne Lesezugriffe verlangen mehr:
Nutzungsberichte **Reports Reader**, Agent-Identitäten **Agent ID Administrator**, Purview-Cmdlets eine
Purview-Leserolle, SharePoint-Cmdlets **SharePoint Administrator**, Power Platform **Power Platform
Administrator**.

**Agent-Inventar (A02).** Die Power-Platform-Inventory-API akzeptiert nur delegierte Token aus einer
App-Registrierung in Ihrem Tenant. Das Tool legt niemals eine an. Wenn Sie A02 wollen, erstellen Sie sie
einmalig selbst: Public-Client-App, delegierte Berechtigung `ResourceQuery.Resources.Read`
(API-ID `8578e004-a5c6-46e7-913e-12f58912df43`), Admin-Zustimmung — dann
`-PowerPlatformClientId <app id>`. Ohne das bleibt A02 *Manuell*.
[Power Platform API authentication](https://learn.microsoft.com/power-platform/admin/programmability-authentication-v2)

---

## ⚙️ Alle Parameter

| Parameter | Zweck |
|---|---|
| `-TenantId <domain oder id>` | Tenant festnageln (empfohlen). Passt die Anmeldung nicht dazu, bricht der Lauf ab und liest nichts. |
| `-Language en` | englischer Bericht (Standard `de`; im Bericht umschaltbar) |
| `-Deep` | zusätzlich die drei neueren Leseberechtigungen anfragen (nur A01 braucht eine davon) |
| `-Purview` | optional: Security & Compliance PowerShell (Label-Richtlinien, DLP für Copilot, Aufbewahrung, Alerts) |
| `-SharePoint [-SharePointAdminUrl <url>]` | optional: SharePoint Online PowerShell (RCD/RAC je Site, Data-Access-Governance-Berichte) |
| `-PowerPlatform [-PowerPlatformClientId <app id>]` | optional: Power Platform Admin PowerShell (DLP für Agent-Umgebungen); mit App-ID auch das Agent-Inventar |
| `-Only S01,Z01` | nur ausgewählte Checks (dann kein Gesamturteil) |
| `-AuditQueryId <id>` | eine bestehende Audit-Suche wiederverwenden |
| `-Yes` | Aufklärungsseite und Tenant-Bestätigung überspringen (unbeaufsichtigte Läufe). Ohne `-Yes` bricht das Tool in einem Fenster ohne Eingabemöglichkeit ab, statt die Seite stillschweigend zu überspringen. |
| `-DeviceCode` | Anmeldung per Gerätecode statt Browser (SSH, Remote-Shell, Rechner ohne Desktop) |
| `-NoTokenCache` | die Anmeldung nicht für den nächsten Lauf merken |
| `-Logout [-TenantId <domain oder id>]` | gespeicherte Anmeldung löschen und beenden; mit `-TenantId` nur für diesen Tenant |
| `-OutputPath <ordner>` | Bericht und JSON in einen anderen Ordner schreiben (Standard `out\` neben dem Skript) |
| `-NoOpen` | den Bericht nicht automatisch öffnen |

`Get-Help ./Invoke-CopilotReadiness.ps1 -Full` zeigt dieselben Parameter mit Beispielen.

**Gespeicherte Anmeldung.** Gespeichert wird ausschließlich das Refresh Token, in
`%LOCALAPPDATA%\govnex\cr-token.dat`, mit DPAPI auf *CurrentUser* verschlüsselt — lesbar nur für denselben
Windows-Benutzer auf demselben Rechner. Ein Eintrag je Tenant und Berechtigungssatz. Wichtig: Ein Refresh Token
gehört zu Microsofts App *Graph Command Line Tools* und Ihrem Konto. Damit lassen sich Zugriffstoken für **alle**
Berechtigungen ausstellen, denen diese App in Ihrem Tenant zugestimmt wurde — nicht nur für die Leseberechtigungen
dieses Tools. Behandeln Sie die Datei wie eine Anmeldung; `-Logout` löscht sie, `-NoTokenCache` legt sie gar nicht
erst an. Unter Linux und macOS wird nichts gespeichert (DPAPI gibt es dort nicht), dort meldet sich jeder Lauf neu an.

---

## 🧭 Grenzen

- Konfigurationsnachweise, **kein** Datei-Level-Scan und keine Simulation dessen, was Copilot antwortet.
- Preview-Felder (Agent-Freigabe, Anmeldung, Konnektoren) können leer sein. Leer heißt **Unbekannt**, nie sicher.
- Die Lizenzerkennung nutzt Service-Plan-Namen; Trials oder neue SKUs brauchen einen manuellen Blick.
- Shadow-AI-Erkennung (Defender for Cloud Apps) ist in v1 nur ein Hinweis.
- Entra-Log-Export nach Log Analytics / Sentinel wird nicht gelesen (N03 ist reine Info).

---

<div align="center">

**Ergebnis besprechen? 30 Minuten, kostenlos.**

[govnex.de](https://govnex.de)

MIT-Lizenz · nichts in Ihrem Tenant wird verändert

</div>
