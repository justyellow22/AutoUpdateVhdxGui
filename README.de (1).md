# AutoUpdate VHDX

🇬🇧 [English](README.md) · 🇩🇪 **Deutsch**

**Windows Update vollautomatisch in einer syspreppten VHDX** – ohne einen einzigen Klick in der VM.

AutoUpdate VHDX bootet ein Golden Image (VHDX) in einer unsichtbaren, temporären Hyper-V-VM, installiert über mehrere Runden alle verfügbaren Windows-Updates, räumt das Image auf, führt Sysprep erneut aus und ersetzt das Original erst, wenn alles erfolgreich war. Per Zeitplan läuft das Ganze auf Wunsch auch nachts an ausgewählten Wochentagen.


---

## Inhalt

- [Funktionen](#funktionen)
- [Voraussetzungen](#voraussetzungen)
- [Schnellstart](#schnellstart)
- [Die Oberfläche](#die-oberfläche)
- [Zeitplan](#zeitplan)
- [Kommandozeile](#kommandozeile)
- [So funktioniert ein Lauf](#so-funktioniert-ein-lauf)
- [Sicherheit & Hinweise](#sicherheit--hinweise)
- [Protokolle & Überwachung](#protokolle--überwachung)
- [Fehlerbehebung](#fehlerbehebung)
- [Bekannte Einschränkungen](#bekannte-einschränkungen)
- [Änderungen](#änderungen)

---

## Funktionen

- **Vollautomatische Updates** über die in Windows eingebaute Windows-Update-API – es wird kein Modul aus dem Internet nachgeladen
- **Mehrere Update-Runden** mit Neustarts, bis zwei Suchläufe nacheinander nichts mehr finden
- **Neustart-Erkennung**: Startet Windows mitten in der Installation selbst neu, setzt das Tool automatisch fort
- **Sicherheitskopie**: Gearbeitet wird an einer Kopie – das Original wird erst nach Erfolg ersetzt
- **Sauberes Image** (optional): entfernt alle lokalen Benutzer samt Profilen, auch verwaiste Profile
- **Rückstandsfreie Aufräumlogik**: Temp-Konto, Antwortdatei, Autologon und Update-Richtlinien werden vor Sysprep entfernt bzw. in den Originalzustand zurückgesetzt
- **Sysprep-Absicherung**: bekannte Blocker (Copilot/Widgets) werden entfernt, `setuperr.log` wird ausgewertet
- **Automatische Switch-Erkennung**: findet selbst einen virtuellen Switch mit Internetzugang
- **Warteschlange mit Farbstatus**: mehrere Images nacheinander bearbeiten – fertige Abbilder werden grün markiert, laufende türkis, fehlerhafte rot
- **Zeitplan** mit freier Wahl der Wochentage
- **Live-Status**: aktueller Schritt, Fortschritt der Updates und Laufzeit direkt in der GUI
- **Zweisprachig**: Deutsch / Englisch, jederzeit umschaltbar
- **Selbst-Erhöhung**: fordert Administratorrechte automatisch per UAC an

## Voraussetzungen

| Bereich | Anforderung |
|---|---|
| Host | Windows 10/11 Pro/Enterprise oder Windows Server mit aktiviertem **Hyper-V** |
| PowerShell | Windows PowerShell 5.1 (in Windows enthalten) |
| Rechte | Administrator (wird beim Start automatisch per UAC angefordert) |
| Netzwerk | Ein virtueller Hyper-V-Switch mit **Internetzugang** (am einfachsten ein externer Switch) |
| Image | **VHDX** mit Windows, **Generation 2 / UEFI (GPT)** – `.vhd`- und MBR-Images werden nicht unterstützt |
| Speicherplatz | Im Ordner der VHDX: Größe der VHDX + ca. 15 GB Puffer |

Einen fehlenden Switch kannst du so anlegen (Adaptername anpassen):

```powershell
New-VMSwitch -Name "AutoUpdateSwitch" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

## Schnellstart

1. `AutoUpdateVhdxGui.ps1` herunterladen und in einen lokalen Ordner legen, z. B. `C:\Tools\AutoUpdateVHDX\`.
2. Falls die Datei aus dem Internet stammt, einmalig entsperren:
   ```powershell
   Unblock-File -Path "C:\Tools\AutoUpdateVHDX\AutoUpdateVhdxGui.ps1"
   ```
3. Rechtsklick auf die Datei → **Mit PowerShell ausführen** → UAC-Abfrage bestätigen.
4. In der GUI zuerst **Selbsttest** klicken – alle kritischen Punkte müssen grün sein.
5. VHDX über **Durchsuchen** auswählen, Einstellungen prüfen und **Auto-Update starten**.

Ein Lauf dauert je nach Anzahl der Updates meist 20–60 Minuten.

## Die Oberfläche

| Einstellung | Bedeutung |
|---|---|
| **RAM für VM (GB)** | Arbeitsspeicher der temporären VM. Standard: 8 GB – beschleunigt große kumulative und .NET-Updates spürbar. Der Host braucht entsprechend freien Arbeitsspeicher. |
| **Max. Update-Runden** | Maximale Anzahl an Installationsrunden. Bestätigungs-Suchläufe zählen nicht mit. Standard: 5 |
| **Sicherheitskopie verwenden** | Arbeitet an einer Kopie; das Original wird erst nach Erfolg ersetzt. **Dringend empfohlen.** |
| **Alle lokalen Benutzer entfernen** | Entfernt alle nicht eingebauten lokalen Konten samt Profil sowie verwaiste Profile. Administrator, Gast usw. bleiben erhalten. Ohne Haken wird nur das Temp-Konto entfernt. |
| **Altes Image als .bak behalten** | Behält das alte Image nach Erfolg als `<Name>.vhdx.bak`. Ohne Haken wird es gelöscht (kein tägliches Backup). |
| **Automatischer Login** | Richtet für das fertige Image einen automatischen Login ein und überspringt das OOBE. Nur für Test-/Referenz-Images gedacht. |
| **DE \| EN** (Titelleiste) | Sprache von Oberfläche, Meldungen und Protokollen. Die Wahl wird gespeichert. |

### Warteschlange

Über **Hinzufügen** (oder Mehrfachauswahl bei **Durchsuchen**) kommen mehrere Images in die Warteschlange; sie werden nacheinander bearbeitet. Jeder Eintrag zeigt seinen Status farbig an:

| Anzeige | Bedeutung |
|---|---|
| Grün – **Fertig** | erfolgreich aktualisiert und neu syspreppt |
| Türkis – **Läuft** | wird gerade bearbeitet |
| Rot – **Fehler** | fehlgeschlagen oder Datei nicht gefunden |
| Orange – **Abgebrochen** | während dieses Images abgebrochen |
| Grau – **Wartet** | kommt noch an die Reihe |

Die Markierungen bleiben nach dem Lauf stehen und werden beim nächsten Start zurückgesetzt.

Weitere Knöpfe:

- **Selbsttest** – prüft Hyper-V, Dienst, Switch und Speicherplatz
- **Rearm-Zähler zurücksetzen** – setzt offline den Sysprep-Rearm-Status einer VHDX zurück, ohne sie zu booten
- **Abbrechen** – bricht nach dem aktuellen Schritt ab und räumt die temporäre VM auf

## Zeitplan

1. VHDX auswählen oder mehrere Images in die **Warteschlange** legen.
2. Uhrzeit (Format `HH:MM`) eintragen und die gewünschten **Wochentage** anhaken (alle sieben = täglich).
3. **Zeitplan einrichten** klicken.

Die geplante Aufgabe heißt `AutoUpdate-VHDX` und läuft unsichtbar als **SYSTEM**. Sie übernimmt die aktuellen Einstellungen (RAM, Runden, Sicherheitskopie, Benutzer entfernen, Backup). Wenn du Einstellungen änderst, richte den Zeitplan einfach erneut ein – der alte wird ersetzt.

Sofort testen, ohne auf den Termin zu warten:

```powershell
schtasks /Run /TN "AutoUpdate-VHDX"
```

**Wichtig:**

- Das Skript nach dem Einrichten nicht verschieben – die Aufgabe ruft es über seinen Pfad auf.
- Keine verbundenen Netzlaufwerke (`Z:\`) verwenden – die kennt das SYSTEM-Konto nicht. Stattdessen lokale Pfade oder UNC-Pfade (`\\server\freigabe\...`) nutzen.
- Die Dateien der Aufgabe liegen unter `%ProgramData%\AutoUpdateVhdx\`.

## Kommandozeile

```powershell
# Selbsttest in der Konsole
.\AutoUpdateVhdxGui.ps1 -SelfTest

# Unbeaufsichtigter Lauf (ohne GUI), z. B. für eigene Automatisierung
.\AutoUpdateVhdxGui.ps1 -Unattended -VhdxPath "D:\VHDX\Win11-Vorlage.vhdx" -RemoveAllLocalUsers

# Mehrere Images aus einer Listendatei (ein Pfad pro Zeile)
.\AutoUpdateVhdxGui.ps1 -Unattended -VhdxListFile "D:\VHDX\liste.txt" -Language en
```

| Parameter | Beschreibung |
|---|---|
| `-SelfTest` | Führt nur den Selbsttest in der Konsole aus |
| `-Unattended` | Lauf ohne GUI (für Zeitpläne/Automatisierung) |
| `-VhdxPath` | Eine oder mehrere VHDX-Dateien |
| `-VhdxListFile` | Textdatei mit einem VHDX-Pfad pro Zeile |
| `-LogPath` | Ordner für Protokolle (Standard: `Protokolle` neben dem Skript) |
| `-MemoryGB` | RAM der temporären VM (Standard: 8) |
| `-MaxRounds` | Maximale Installationsrunden (Standard: 5) |
| `-NoSafeCopy` | Direkt am Original arbeiten (nicht empfohlen) |
| `-RemoveAllLocalUsers` | Sauberes Image: alle lokalen Benutzer und Profile entfernen |
| `-KeepBackup` | Altes Image nach Erfolg als `.bak` behalten |
| `-Language` | `de` oder `en` (überschreibt die gespeicherte Sprache) |

Exit-Codes im Unattended-Modus: `0` = alles erfolgreich, `1` = mindestens ein Image fehlgeschlagen, `2` = falscher Aufruf, `5` = keine Administratorrechte.

## So funktioniert ein Lauf

| Phase | Was passiert |
|---|---|
| 1. Vorbereitung | Prüfung von Dateityp und Speicherplatz, Anlegen der Sicherheitskopie |
| 2. OOBE-Automatisierung | Offline: Antwortdatei mit temporärem Konto ablegen, vorhandene Antwortdateien sichern, Rearm-Status zurücksetzen |
| 3. Temporäre VM erstellen | Generation-2-VM mit der Arbeitskopie, Secure Boot aus, keine Checkpoints |
| 4. VM starten | Verbindung per PowerShell Direct, Test des Internetzugangs, ggf. automatischer Switch-Wechsel |
| 5. Windows Update vorbereiten | Update-Helfer in der VM einrichten, eigene Update-Automatik von Windows während des Laufs pausieren |
| 6. Updates installieren | Suchen → installieren → neu starten, bis zwei Suchläufe nacheinander nichts mehr finden |
| 7. Sysprep ausführen | Blocker entfernen, Konten bereinigen, alle Rückstände entfernen, `sysprep /generalize /oobe /shutdown` |
| 8. Aufräumen & Original ersetzen | Offline-Profilbereinigung, VM entfernen, Original durch die aktualisierte Kopie ersetzen (mit Rollback bei Fehlern) |

## Sicherheit & Hinweise

- **Temporäres Konto:** Für die Automatisierung legt das Tool in der Arbeitskopie das lokale Administratorkonto `AutoUpdate` mit dem Standardpasswort `Passw0rd` an. Konto, Antwortdatei und Autologon werden **vor** dem finalen Sysprep wieder entfernt. Gelingt das nicht, bricht der Lauf ab, damit kein Image mit Temp-Administrator entsteht.
- **Eingebauter Administrator:** War er im Image aktiv, erhält er während des Laufs das Standardpasswort des Tools. Bitte nach dem Deployment ändern. War er deaktiviert, wird er wieder deaktiviert.
- **Automatischer Login (optional):** Das Passwort liegt im fertigen Image nur leicht verschleiert vor – nur für Test- und Referenz-Images verwenden.
- **Ohne Sicherheitskopie** wird direkt am Original gearbeitet. Bei einem Fehler kann das Image unbrauchbar sein.
- **Nicht gleichzeitig starten:** Keinen GUI-Lauf auf ein Image starten, während der Zeitplan es gerade bearbeitet.

## Protokolle & Überwachung

- **GUI:** Protokoll im Fenster, Statuszeile mit aktuellem Schritt und Laufzeit
- **Zeitplan:** Protokolldateien im Ordner `Protokolle` neben dem Skript (`AutoUpdateVHDX_<Datum>.log`), die letzten 60 werden aufbewahrt
- **Ereignisanzeige:** *Windows-Protokolle → Anwendung*, Quelle `AutoUpdateVHDX`

| Ereignis-ID | Bedeutung |
|---|---|
| 1000 | Tool im interaktiven Modus gestartet |
| 1001 | Zeitplan-Lauf erfolgreich |
| 1002 | Zeitplan-Lauf mit Fehlern |

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| VM steht am **Anmeldebildschirm** | Während eines Laufs normal – das Tool arbeitet über PowerShell Direct und braucht keinen Desktop-Login. |
| Ein Update (z. B. **.NET**) dauert sehr lange | Normal: Windows kompiliert danach alle .NET-Assemblies neu. Mehr RAM hilft. |
| VM startet nicht („nicht genügend Arbeitsspeicher“) | Der Host hat keine 8 GB frei – in der GUI den RAM-Wert senken (z. B. 4 GB) oder `-MemoryGB 4` verwenden. |
| Fertiges Image bleibt mit Konto `AutoUpdate` am Anmeldebildschirm hängen | Altlast einer früheren Version: das Image einmal mit der aktuellen Version durchlaufen lassen. |
| „Kein Internetzugang“ | Einen virtuellen Switch mit echtem Internetzugang einrichten (siehe Voraussetzungen). |
| „MBR-Partitionstabelle“ / „Nur VHDX“ | Das Image ist Generation 1 bzw. eine `.vhd` – wird nicht unterstützt. |
| Sysprep schlägt fehl | Die letzten Zeilen von `setuperr.log` stehen im Protokoll. Das Original bleibt im Sicherheitskopie-Modus unverändert. |
| Neben dem Image liegt eine `.bak` | Das ist das alte Image (nur mit „Altes Image behalten“). Nach Prüfung des neuen Images löschbar. |
| VHDX ist noch „gemountet“ | Das Tool bietet beim Start das Aushängen an, alternativ: `Dismount-VHD -Path <Pfad>` |

## Bekannte Einschränkungen

- Nur **VHDX**-Images mit **Generation 2 / UEFI**.
- Die temporäre Antwortdatei verwendet deutsche Regions- und Spracheinstellungen (`de-DE`).
- Update-Titel und Fehlermeldungen von Windows erscheinen in der Sprache der VM bzw. des Hosts.
- Updates, die zwei Runden in Folge fehlschlagen, werden übersprungen und im Protokoll aufgeführt.

## Änderungen

Alle Änderungen je Version stehen im [CHANGELOG](CHANGELOG.md).

---

**Version:** 1.2 · Entwickelt für Windows PowerShell 5.1 und Hyper-V
