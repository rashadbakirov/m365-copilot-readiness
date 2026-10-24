# Manuelle Gegenprüfung: stimmt der Bericht?

Zweck: jede Zahl im HTML-Bericht einmal im Portal nachschlagen, bevor Sie Entscheidungen darauf stützen.
Reihenfolge nach Risiko — oben stehen die Checks, bei denen ein Fehler am teuersten wäre.

Spalte **Abweichung** ausfüllen: ✅ stimmt · ⚠️ weicht ab (Zahl notieren) · ❓ nicht prüfbar.

Drei Ergebnisse, die erfahrungsgemäß zuerst eine Nachfrage auslösen:

- **A01 (Agent-Identitäten ohne Owner):** Entra Admin Center → Identität → Anwendungen → **Agent-IDs**. Anzahl
  vergleichen; eine hohe Zahl in einem Tenant ohne Copilot-Lizenz verdient den ersten Blick.
- **S01 „keine Copilot-Lizenz" neben N02 „Copilot-Interaktionen protokolliert":** beides kann gleichzeitig
  stimmen, **Copilot Chat braucht keine Lizenz**. Purview → Audit → Suche nach `copilotInteraction`.
- **S07 (inaktive Sites):** SharePoint Admin Center → Berichte → **Websitenutzung**. Der Bericht nutzt den
  180-Tage-Schnitt aus dem Nutzungsbericht; das Portal zeigt oft 30/90/180 Tage umschaltbar.

---

## 1 · Oversharing & Zugriff

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| S03 | Externe Freigabe auf Tenant-Ebene | SharePoint Admin Center → Richtlinien → **Freigabe** | |
| S04 | Freigabe-Hygiene (Standard-Linktyp, Ablauf) | SharePoint Admin Center → Richtlinien → Freigabe → *Linkstandards* | |
| S05 | Öffentliche M365-Gruppen und Teams | Entra → Gruppen → Filter **Gruppentyp = Microsoft 365**, Spalte Sichtbarkeit; oder Teams Admin Center | |
| S06 | Gruppen ohne Owner | Entra → Gruppen → Filter; M365 Admin Center zeigt ownerlose Gruppen direkt | |
| S08 | Externe Freigaben je Nutzer | M365 Admin → Berichte → Nutzung → **SharePoint-Aktivität** | |
| S09 | Inaktive Gäste | Entra → Benutzer → Filter **Benutzertyp = Gast**, Spalte *Letzte Anmeldung* (braucht Entra P1) | |
| S11 | Restricted Content Discovery / Restricted Access Control | SharePoint Admin Center → Websites → Aktive Websites, Spalten **RCD** und **RAC** | |
| S12 | Oversharing-Berichte (Data Access Governance) | SharePoint Admin Center → Berichte → **Datenzugriffsgovernance** | |

## 2 · Daten schützen

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| K01 / K02 | Sensitivity Labels, Geltungsbereiche | Purview → Information Protection → **Bezeichnungen** (Anzahl, aktiviert, Bereich Dateien/E-Mail vs. Gruppen/Sites) | |
| K03 | Label-Richtlinie: Standard-Label und Pflicht | Purview → Information Protection → **Bezeichnungsrichtlinien** → Richtlinieneinstellungen | |
| K04 | Automatische Label-Vergabe | Purview → Information Protection → **Automatische Bezeichnung** (Simulation vs. aktiv) | |
| K05 | Labels auf echten Inhalten | SharePoint Admin Center → Berichte → Datenzugriffsgovernance → *Sensitivity labels in files* | |
| K06 | Aufbewahrungs-Labels | Purview → Datenlebenszyklus → **Aufbewahrungsbezeichnungen** | |
| B01 / B05 | DLP für Copilot (Prompts, gelabelte Inhalte) | Purview → **Verhinderung von Datenverlust** → Richtlinien → Speicherort *Microsoft 365 Copilot* | |
| B02 | DLP-Abdeckung der Ausgänge | Purview → DLP → Richtlinien, Spalte Speicherorte (Exchange, SharePoint, OneDrive, Teams, Endpunkte) | |

## 3 · Agents

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| A01 | Agent-Identitäten mit Verantwortlichen | Entra → **Agent-IDs** / Unternehmensanwendungen → Besitzer | |
| A02 | Agents: Freigabe, Anmeldung, Maker-Verbindungen | Power Platform Admin Center → **Copilot-Studio-Agents**; Freigabe je Agent | |
| A03 | Power-Platform-DLP für Agent-Umgebungen | Power Platform Admin Center → Richtlinien → **Datenrichtlinien**; Standardumgebung prüfen | |

## 4 · Identität für KI

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| Z01 / Z02 / Z03 | MFA für alle, Legacy blockiert, verwaltetes Gerät | Entra → **Conditional Access** → Richtlinien (Zustand, Nutzer, Ausschlüsse, Apps, Steuerung) | |
| Z04 | MFA-Registrierung | Entra → Schutz → **Authentifizierungsmethoden** → Registrierungsbericht | |
| Z05 | Globale Administratoren | Entra → Rollen → **Globaler Administrator** → Zuweisungen | |
| Z06 | Gast-Einladungen und Gastrolle | Entra → Externe Identitäten → **Einstellungen für externe Zusammenarbeit** | |
| Z07 | Wer darf Apps und Agents zustimmen | Entra → Unternehmensanwendungen → **Einwilligung und Berechtigungen** | |
| I01 | Risikobasierte Anmeldung | Entra → Schutz → **Identity Protection** (Anmelde- und Benutzerrisiko-Richtlinie) | |
| I02 | Phishing-resistente MFA für Admins | Entra → CA → Richtlinie mit **Authentifizierungsstärke** auf Admin-Rollen | |
| I03 | Apps mit weitreichenden Berechtigungen | Entra → Unternehmensanwendungen → je App **Berechtigungen** (delegiert vs. Anwendung) | |
| I04 | Dauerhaft aktive vs. berechtigte Rollen | Entra → **PIM** → Rollen → Zuweisungen (aktiv vs. berechtigt) | |

## 5 · Defender & Schatten-KI

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| S10 | Secure Score, offene Aktionen | Defender Portal → **Secure Score** → Empfohlene Aktionen | |
| D01 | Generative-KI-Apps (manuell) | Defender for Cloud Apps → Cloud Discovery → Kategorie **Generative KI** | |

## 6 · Audit & Nachweis

| Check | Behauptung | Wo nachschauen | Abweichung |
|---|---|---|---|
| N01 | Audit-Log durchsuchbar | Purview → **Audit** → Suche starten | |
| N02 | Copilot-Interaktionen im Audit-Log | Purview → Audit → Aktivität **copilotInteraction**, letzte 7 Tage | |
| N03 | Entra-Log-Aufbewahrung | Ergibt sich aus der Lizenz (30 Tage mit P1/P2). Export nach Sentinel prüft das Tool nicht. | |
| B03 | Aufbewahrung für Copilot-Interaktionen | Purview → Datenlebenszyklus → **Aufbewahrungsrichtlinien**, Speicherort Copilot | |
| N04 | Alerts für DLP und Daten | Purview → **Warnungsrichtlinien** (aktiviert/deaktiviert) | |

---

## Wenn etwas abweicht

1. Im Bericht den Check aufklappen und die Tabelle **„Nachweis aus Ihrem Tenant"** ansehen — dort stehen
   die Rohwerte, auf denen die Zahl beruht.
2. Die `out\*.json` zum selben Lauf öffnen: `results` → der Check → `Evidence` und `Args`.
3. Abweichung mit Check-ID, erwarteter und gemeldeter Zahl notieren und als Issue im Repository melden.
