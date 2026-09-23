<#
.SYNOPSIS
    AutoUpdate-Vhdx GUI - Grafisches Tool für das vollautomatische Update
    einer syspreppten VHDX über echtes Windows Update.
.DESCRIPTION
    GUI-Version von AutoUpdate-Vhdx.ps1. Bootet die VHDX automatisch in
    einer temporären, unsichtbaren Hyper-V-VM, lässt Windows Update
    vollständig durchlaufen (mehrere Runden, inkl. automatischer Neustarts),
    sysprepped danach automatisch neu und ersetzt das Original erst nach
    Erfolg. Alles ohne dass der Nutzer in der VM etwas klicken muss.
    Rechtsklick -> "Mit PowerShell ausführen" genuegt: Ohne Adminrechte
    startet sich das Skript selbst neu und fordert sie per UAC an. Oder:
    powershell.exe -ExecutionPolicy Bypass -File .\AutoUpdateVhdxGui.ps1
.PARAMETER SelfTest
    Führt den Selbsttest ohne GUI in der Konsole aus.
.PARAMETER Unattended
    Führt den Auto-Update-Lauf ohne GUI in der Konsole aus - für die
    zeitgesteuerte/automatisierte Ausführung (z.B. über eine geplante
    Aufgabe). Benötigt -VhdxPath mit mindestens einer Datei.
.PARAMETER VhdxPath
    Eine oder mehrere VHDX-Dateien, die im Unattended-Modus nacheinander
    bearbeitet werden.
.PARAMETER VhdxListFile
    Textdatei mit einem VHDX-Pfad pro Zeile (wird vom GUI-Zeitplan fuer
    die komplette Warteschlange genutzt, weil sich Arrays ueber
    "powershell.exe -File" nicht zuverlaessig uebergeben lassen).
.PARAMETER RemoveAllLocalUsers
    Entfernt vor Sysprep ALLE nicht eingebauten lokalen Benutzer samt
    Profil sowie alle verwaisten Profile ohne Konto (sauberes Image). Ohne diesen Schalter wird nur das temporaere
    Konto "AutoUpdate" entfernt.
.PARAMETER KeepBackup
    Behaelt nach einem erfolgreichen Lauf das alte Image als "<Name>.bak".
    Ohne diesen Schalter wird das alte Image nach Erfolg geloescht.
.PARAMETER Language
    Sprache der Oberflaeche und der Protokolle: "de" oder "en". Ohne Angabe
    gilt die in der GUI gewaehlte Sprache (gespeichert unter
    %ProgramData%\AutoUpdateVhdx\einstellungen.json), sonst die Windows-Sprache.
.PARAMETER MaxRounds
    Maximale Anzahl an Installationsrunden. Bestaetigungs-Suchlaeufe
    zaehlen NICHT mit.
.PARAMETER LogPath
    Zielordner für Protokolldateien im Unattended-Modus. Standard: ein
    "Protokolle"-Unterordner neben dem Skript.
#>
param(
    [switch]$SelfTest,
    [switch]$Unattended,
    [string[]]$VhdxPath,
    [string]$VhdxListFile,
    [string]$LogPath,
    [int]$MemoryGB = 8,
    [int]$MaxRounds = 5,
    [switch]$NoSafeCopy,
    [switch]$RemoveAllLocalUsers,
    [switch]$KeepBackup,
    [ValidateSet("de", "en")][string]$Language
)

# ===========================================================================
# Sprache (Deutsch / Englisch)
# Alle Texte im Code sind deutsch. Beim ANZEIGEN (GUI, Protokoll, Meldungen,
# Ereignisprotokoll) werden sie ueber die Tabelle unten ins Englische
# uebersetzt, wenn Englisch gewaehlt ist. Die Update-Logik selbst bleibt
# dadurch unveraendert. Platzhalter {0}, {1}, ... stehen fuer variable Teile.
# ===========================================================================
$script:EinstellungenDatei = Join-Path $env:ProgramData "AutoUpdateVhdx\einstellungen.json"
$script:UiSprache = $null
if ($Language) {
    $script:UiSprache = $Language
} else {
    try {
        if (Test-Path -LiteralPath $script:EinstellungenDatei) {
            $gespeichert = Get-Content -LiteralPath $script:EinstellungenDatei -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@("de", "en") -contains $gespeichert.Sprache) { $script:UiSprache = [string]$gespeichert.Sprache }
        }
    } catch { }
}
if (-not $script:UiSprache) {
    $script:UiSprache = if ((Get-UICulture).TwoLetterISOLanguageName -eq "de") { "de" } else { "en" }
}

$UebersetzungRoh = @'
# Deutsch ¦ English  (\n = Zeilenumbruch, {0} {1} ... = Platzhalter)
FEHLER: Dieses Tool benoetigt Administratorrechte. ¦ ERROR: This tool requires administrator rights.
Das Tool benoetigt Administratorrechte (Hyper-V, VHDX mounten, Registry offline bearbeiten).\n\nDie UAC-Abfrage wurde abgelehnt - das Tool wird beendet. ¦ The tool requires administrator rights (Hyper-V, mounting VHDX files, offline registry editing).\n\nThe UAC prompt was declined - the tool will exit.
Administratorrechte erforderlich ¦ Administrator rights required
Administratorrechte wurden nicht erteilt - Abbruch. ¦ Administrator rights were not granted - aborting.
Administrator-Rechte ¦ Administrator rights
Hyper-V-Modul (New-VM) verfügbar ¦ Hyper-V module (New-VM) available
Hyper-V-Verwaltungsdienst (vmms) läuft ¦ Hyper-V management service (vmms) running
Virtueller Switch vorhanden ¦ Virtual switch present
Freier Speicherplatz > 15 GB ¦ Free disk space > 15 GB
{0} GB frei auf {1}: (TEMP-Laufwerk; der Platz im VHDX-Ordner wird beim Start separat geprueft) ¦ {0} GB free on {1}: (TEMP drive; space in the VHDX folder is checked separately at start)
Konnte nicht geprüft werden ¦ Could not be checked
SYSTEM- oder SOFTWARE-Hive nicht gefunden unter {0}\Windows\System32\config ¦ SYSTEM or SOFTWARE hive not found under {0}\Windows\System32\config
Konnte SYSTEM-Hive nicht laden. ¦ Could not load SYSTEM hive.
Konnte SOFTWARE-Hive nicht laden. ¦ Could not load SOFTWARE hive.
SysprepStatus zurueckgesetzt (CleanupState=2, GeneralizationState=7). ¦ SysprepStatus reset (CleanupState=2, GeneralizationState=7).
SysprepStatus-Key nicht gefunden - evtl. noch nie syspreppt, kein Reset noetig. ¦ SysprepStatus key not found - probably never sysprepped, no reset needed.
SkipRearm in SoftwareProtectionPlatform gesetzt. ¦ SkipRearm set in SoftwareProtectionPlatform.
WARNUNG: SYSTEM-Hive ({0}) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern. ¦ WARNING: SYSTEM hive ({0}) could not be unloaded - dismounting the VHDX may fail.
WARNUNG: SOFTWARE-Hive ({0}) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern. ¦ WARNING: SOFTWARE hive ({0}) could not be unloaded - dismounting the VHDX may fail.
Verbindungstest fehlgeschlagen: {0} ¦ Connection test failed: {0}
Geplante Aufgabe konnte nicht erstellt werden: {0} ¦ Scheduled task could not be created: {0}
Geplante Aufgabe konnte nicht gestartet werden: {0} ¦ Scheduled task could not be started: {0}
Neustart der VM erkannt (vermutlich von Windows selbst ausgeloest) - baue Verbindung neu auf... ¦ VM restart detected (probably triggered by Windows itself) - reconnecting...
Verbindung zur VM ging waehrend des Update-Laufs verloren und liess sich nicht wiederherstellen. ¦ Connection to the VM was lost during the update run and could not be restored.
Verbindung zur VM wiederhergestellt. ¦ Connection to the VM restored.
Verbindung zur VM antwortet nicht mehr - baue sie neu auf... ¦ Connection to the VM no longer responds - reconnecting...
Ergebnisdatei des Update-Helfers war unlesbar: {0} ¦ Result file of the update helper was unreadable: {0}
Die VM wurde waehrend des Update-Helfers neu gestartet (Modus: {0}). ¦ The VM was restarted while the update helper was running (mode: {0}).
Die geplante Aufgabe in der VM ist beendet, hat aber kein Ergebnis hinterlassen (Modus: {0}). ¦ The scheduled task in the VM has ended but left no result (mode: {0}).
Der Windows-Update-Helfer hat innerhalb von {0} Sekunden kein Ergebnis geliefert (Modus: {1}). ¦ The Windows Update helper returned no result within {0} seconds (mode: {1}).
Starte VM neu... ¦ Restarting VM...
Die VM kam nach dem Neustart nicht wieder online (nach 900 s, letzter Fehler: {0}). ¦ The VM did not come back online after the restart (after 900 s, last error: {0}).
VM wieder online nach Neustart (nach {0} s). ¦ VM back online after restart (after {0} s).
Warte, bis Windows die Update-Nachbereitung abgeschlossen hat... ¦ Waiting for Windows to finish update post-processing...
Update-Nachbereitung abgeschlossen (nach {0} s). ¦ Update post-processing finished (after {0} s).
    ...noch beschaeftigt: {0} ({1} s) ¦ ...still busy: {0} ({1} s)
Windows raeumt noch im Hintergrund auf - die Suche laeuft parallel weiter. ¦ Windows is still cleaning up in the background - the search continues in parallel.
Die Update-Nachbereitung laeuft laenger als {0} s - fahre trotzdem fort. ¦ Update post-processing is taking longer than {0} s - continuing anyway.
Vorbereitung ¦ Preparation
=== Vorbereitung === ¦ === Preparation ===
Der Hyper-V-Verwaltungsdienst (vmms) läuft nicht. Ist Hyper-V aktiviert? ¦ The Hyper-V management service (vmms) is not running. Is Hyper-V enabled?
Nur VHDX-Dateien werden unterstuetzt (die temporaere VM ist Generation 2). '{0}' bitte vorher mit Convert-VHD in eine .vhdx umwandeln. ¦ Only VHDX files are supported (the temporary VM is Generation 2). Please convert '{0}' to a .vhdx with Convert-VHD first.
Freier Speicherplatz im VHDX-Ordner konnte nicht geprueft werden (z.B. Netzwerkpfad) - fahre fort. ¦ Free space in the VHDX folder could not be checked (e.g. network path) - continuing.
Zu wenig Speicherplatz im VHDX-Ordner: {0} GB frei, benoetigt ca. {1} GB (Kopie + Puffer fuer Updates). ¦ Not enough space in the VHDX folder: {0} GB free, approx. {1} GB required (copy + buffer for updates).
Sicherheitskopie wird erstellt ({0} GB - das kann bei großen Dateien mehrere Minuten dauern): {1} ¦ Creating safety copy ({0} GB - this may take several minutes for large files): {1}
Kopiere... {0}% ({1} von {2} GB) ¦ Copying... {0}% ({1} of {2} GB)
Kopieren der VHDX ist fehlgeschlagen: {0} ¦ Copying the VHDX failed: {0}
Kopieren der VHDX ist fehlgeschlagen (Zieldatei fehlt nach Abschluss). ¦ Copying the VHDX failed (target file missing after completion).
Kopie erstellt (100%, {0} GB). ¦ Copy created (100%, {0} GB).
Sicherheitskopie deaktiviert - arbeite DIREKT an der Original-Datei. ¦ Safety copy disabled - working DIRECTLY on the original file.
OOBE-Automatisierung vorbereiten ¦ Prepare OOBE automation
=== Bereite automatisches Ueberspringen von OOBE vor === ¦ === Preparing automatic OOBE skip ===
(Ohne diesen Schritt wuerde die VM beim ersten Boot an der Sprachauswahl haengen bleiben und auf manuelle Eingabe warten.) ¦ (Without this step the VM would get stuck at language selection on first boot, waiting for manual input.)
Konnte DiskNumber der gemounteten VHDX nicht ermitteln (nach {0}s). ¦ Could not determine the DiskNumber of the mounted VHDX (after {0}s).
Windows-Partition noch nicht gefunden, Versuch {0} von 8 - warte und pruefe erneut... ¦ Windows partition not found yet, attempt {0} of 8 - waiting and checking again...
--- Diagnose: gefundene Partitionen auf Disk {0} --- ¦ --- Diagnostics: partitions found on disk {0} ---
  Keine Partitionen gefunden (Get-Partition lieferte ein leeres Ergebnis). ¦ No partitions found (Get-Partition returned an empty result).
  Partition {0}: Typ={1}, Groesse={2}GB, Laufwerk={3} ¦ Partition {0}: type={1}, size={2}GB, drive={3}
Keine Windows-Partition in der Kopie gefunden - kann OOBE-Automatisierung nicht vorbereiten. ¦ No Windows partition found in the copy - cannot prepare OOBE automation.
Altlast einer frueheren Tool-Version entfernt (verursacht Haenger am Anmeldebildschirm): {0} ¦ Leftover from an older tool version removed (causes hang at the sign-in screen): {0}
Vorhandene Antwortdatei gesichert (wird vor Sysprep wiederhergestellt): {0} ¦ Existing answer file backed up (will be restored before Sysprep): {0}
unattend.xml abgelegt unter: {0} ¦ unattend.xml placed at: {0}
HINWEIS: Dies erstellt ein temporaeres lokales Konto 'AutoUpdate' NUR in der Arbeitskopie, um OOBE zu automatisieren. Konto, Antwortdatei und Autologon werden vor dem finalen Sysprep wieder entfernt. ¦ NOTE: This creates a temporary local account 'AutoUpdate' ONLY in the working copy to automate OOBE. Account, answer file and autologon are removed again before the final Sysprep.
Setze Sysprep-Rearm-Zaehler zurueck (falls Limit erreicht war)... ¦ Resetting Sysprep rearm counter (in case the limit was reached)...
Rearm-Zaehler-Reset abgeschlossen. ¦ Rearm counter reset completed.
WARNUNG: Rearm-Zaehler-Reset fehlgeschlagen: {0} - fahre trotzdem fort. ¦ WARNING: Rearm counter reset failed: {0} - continuing anyway.
WARNUNG: OOBE-Automatisierung konnte nicht vorbereitet werden: {0} ¦ WARNING: OOBE automation could not be prepared: {0}
Falls die VHDX bereits syspreppt/im OOBE-Zustand ist, muss ggf. manuell durch die Sprachauswahl geklickt werden. ¦ If the VHDX is already sysprepped/in OOBE state, you may have to click through the language selection manually.
WARNUNG: Konnte Arbeitskopie nach OOBE-Vorbereitung nicht sauber aushaengen. Fahre trotzdem fort. ¦ WARNING: Could not cleanly dismount the working copy after OOBE preparation. Continuing anyway.
Die VHDX hat eine MBR-Partitionstabelle (BIOS/Generation 1). Die temporaere VM ist Generation 2 (UEFI) und kann dieses Abbild nicht booten. ¦ The VHDX has an MBR partition table (BIOS/Generation 1). The temporary VM is Generation 2 (UEFI) and cannot boot this image.
Temporäre VM erstellen ¦ Create temporary VM
=== Erstelle temporäre VM '{0}' === ¦ === Creating temporary VM '{0}' ===
Kein virtueller Switch gefunden. Siehe Selbsttest für den Einrichtungsbefehl. ¦ No virtual switch found. See the self-test for the setup command.
Nutze virtuellen Switch: {0} ¦ Using virtual switch: {0}
Virtuelle Prozessoren: {0} (Host hat {1}) ¦ Virtual processors: {0} (host has {1})
VM erstellt (Generation 2, {0} GB RAM). ¦ VM created (Generation 2, {0} GB RAM).
VM starten ¦ Start VM
=== Starte VM === ¦ === Starting VM ===
VM gestartet - warte auf Windows-Bereitschaft (PowerShell Direct)... ¦ VM started - waiting for Windows to be ready (PowerShell Direct)...
Warte weiter auf Windows-Start... ({0} s) - letzter Fehler: {1} ¦ Still waiting for Windows to start... ({0} s) - last error: {1}
Konnte nach {0} Sekunden keine PowerShell-Direct-Verbindung herstellen (letzter Fehler: {1}). Läuft die VM evtl. im OOBE-Setup fest, oder stimmen die Zugangsdaten fuer den Autologon-Account nicht? ¦ Could not establish a PowerShell Direct connection after {0} seconds (last error: {1}). Is the VM stuck in OOBE setup, or are the credentials for the autologon account wrong?
Verbindung zur VM hergestellt (nach {0} s). ¦ Connected to the VM (after {0} s).
=== Pruefe Internetzugang der VM (Switch '{0}') === ¦ === Checking internet access of the VM (switch '{0}') ===
Internetzugang bestaetigt. ¦ Internet access confirmed.
Kein Internetzugang ueber Switch '{0}' - versuche automatisch andere verfuegbare Switches... ¦ No internet access via switch '{0}' - automatically trying other available switches...
Teste Switch: {0}... ¦ Testing switch: {0}...
Konnte VM nicht mit Switch '{0}' verbinden: {1} ¦ Could not connect VM to switch '{0}': {1}
Internetzugang ueber Switch '{0}' erfolgreich - VM bleibt auf diesem Switch. ¦ Internet access via switch '{0}' successful - VM stays on this switch.
Die temporaere VM hat auf KEINEM verfuegbaren virtuellen Switch Internetzugang (probiert: {0}). Bitte einen virtuellen Switch mit echtem Internetzugang einrichten (siehe Selbsttest-Hinweis zu New-VMSwitch). ¦ The temporary VM has internet access on NONE of the available virtual switches (tried: {0}). Please set up a virtual switch with real internet access (see the self-test hint about New-VMSwitch).
Windows Update vorbereiten ¦ Prepare Windows Update
=== Bereite Windows Update in der VM vor === ¦ === Preparing Windows Update in the VM ===
(Nutzt die in Windows fest eingebaute Windows-Update-COM-API - es wird KEIN Modul aus dem Internet nachgeladen.) ¦ (Uses the Windows Update COM API built into Windows - NO module is downloaded from the internet.)
Helfer-Skript konnte nicht geschrieben werden. ¦ Helper script could not be written.
Konnte den Windows-Update-Helfer nicht in der VM einrichten: {0} ¦ Could not set up the Windows Update helper in the VM: {0}
Windows-Update-Helfer in der VM eingerichtet (keine Internet-Downloads noetig). ¦ Windows Update helper set up in the VM (no internet downloads needed).
Updates installieren ¦ Install updates
=== Update-Suche {0} (Installationsrunden bisher: {1} von max. {2}) === ¦ === Update search {0} (install rounds so far: {1} of max. {2}) ===
Updates installieren (Runde {0}/{1}) ¦ Install updates (round {0}/{1})
Sitzung nicht mehr offen, baue neu auf... ¦ Session no longer open, reconnecting...
Konnte Sitzung nach Neustart nicht wiederherstellen (letzter Fehler: {0}). ¦ Could not restore the session after restart (last error: {0}).
Die Update-Suche in der VM wurde unterbrochen - die geplante Aufgabe endete ohne Ergebnis. Bitte pruefen, ob die VM waehrenddessen neu gestartet wurde. ¦ The update search in the VM was interrupted - the scheduled task ended without a result. Please check whether the VM restarted in the meantime.
Die Update-Suche in der VM ist fehlgeschlagen: {0} ¦ The update search in the VM failed: {0}
Gefundene ausstehende Updates: {0} ¦ Pending updates found: {0}
Auch der Bestaetigungsdurchlauf hat nichts mehr gefunden - Windows ist wirklich aktuell. ¦ The confirmation pass found nothing either - Windows is really up to date.
Aktuell nichts gefunden - Windows gibt Folge-Updates aber oft erst nach einem Neustart frei. ¦ Nothing found right now - but Windows often releases follow-up updates only after a restart.
Starte zur Sicherheit neu und pruefe noch einmal (Bestaetigungsdurchlauf). ¦ Restarting to be safe and checking once more (confirmation pass).
Maximale Anzahl an Installationsrunden ({0}) erreicht - {1} Update(s) bleiben offen. ¦ Maximum number of install rounds ({0}) reached - {1} update(s) remain pending.
Zwei Runden in Folge wurde nichts erfolgreich installiert - diese {0} Update(s) scheitern offenbar dauerhaft und werden uebersprungen: ¦ Nothing was installed successfully in two rounds in a row - these {0} update(s) apparently fail permanently and will be skipped:
    ... und {0} weitere ¦ ... and {0} more
Installationsrunde {0} von {1}: installiere {2} Update(s) - das kann mehrere Minuten dauern... ¦ Install round {0} of {1}: installing {2} update(s) - this may take several minutes...
Die Installation wurde in der VM unterbrochen (vermutlich hat Windows selbst neu gestartet). Setze nach dem Neustart fort. ¦ The installation in the VM was interrupted (Windows probably restarted by itself). Continuing after the restart.
Die Update-Installation in der VM ist fehlgeschlagen: {0} ¦ The update installation in the VM failed: {0}
Installiert: {0}, fehlgeschlagen/uebersprungen: {1}. ¦ Installed: {0}, failed/skipped: {1}.
Windows konnte nicht als vollstaendig aktuell bestaetigt werden - es koennten noch Updates offen sein. Bei Bedarf die Rundenzahl erhoehen und erneut laufen lassen. ¦ Windows could not be confirmed as fully up to date - updates may still be pending. If needed, increase the number of rounds and run again.
Insgesamt installierte Updates: {0} ¦ Total updates installed: {0}
Sysprep ausführen ¦ Run Sysprep
=== Führe Sysprep aus === ¦ === Running Sysprep ===
Konnte vor Sysprep keine Sitzung zur VM aufbauen (letzter Fehler: {0}). ¦ Could not establish a session to the VM before Sysprep (last error: {0}).
Entferne bekannte Sysprep-Blocker (Copilot/Widgets u.a.)... ¦ Removing known Sysprep blockers (Copilot/Widgets etc.)...
(Diese Apps werden oft durch Windows Update nur fuer den aktuellen Nutzer installiert und lassen Sysprep dann mit einem BCD-Firmware-Fehler scheitern.) ¦ (Windows Update often installs these apps only for the current user, which makes Sysprep fail with a BCD firmware error.)
Bereinigung abgeschlossen. ¦ Cleanup completed.
WARNUNG: Bereinigung teilweise fehlgeschlagen: {0} - fahre trotzdem fort. ¦ WARNING: Cleanup partially failed: {0} - continuing anyway.
=== Entferne das temporaere Konto '{0}' === ¦ === Removing the temporary account '{0}' ===
(Ein angemeldetes Konto kann sich nicht selbst loeschen - daher wird kurz auf das eingebaute Administrator-Konto gewechselt.) ¦ (A signed-in account cannot delete itself - so the tool briefly switches to the built-in Administrator account.)
Eingebautes Administrator-Konto (RID 500) nicht gefunden. ¦ Built-in Administrator account (RID 500) not found.
HINWEIS: Das eingebaute Konto '{0}' war im Image aktiv. Sein Passwort wird auf das Standard-Passwort des Tools gesetzt - bitte nach dem Deployment aendern. ¦ NOTE: The built-in account '{0}' was enabled in the image. Its password is set to the tool's default password - please change it after deployment.
Konnte keine Administrator-Sitzung aufbauen. ¦ Could not establish an Administrator session.
Modus 'Sauberes Image': ALLE nicht eingebauten lokalen Benutzer werden samt Profil entfernt. ¦ 'Clean image' mode: ALL non-built-in local users are removed including their profiles.
Weitere (verwaiste) Profile entfernt: {0} ¦ Additional (orphaned) profiles removed: {0}
Entfernte Konten: {0} ¦ Removed accounts: {0}
Keine zu entfernenden Konten gefunden. ¦ No accounts to remove found.
WARNUNG: Konto konnte nicht entfernt werden: {0} ¦ WARNING: Account could not be removed: {0}
Das temporaere Konto ist nach der Bereinigung noch vorhanden. ¦ The temporary account still exists after cleanup.
Arbeite ab hier ueber die Administrator-Sitzung weiter. ¦ Continuing via the Administrator session from here on.
Das temporaere Konto '{0}' konnte nicht entfernt werden ({1}). Abbruch vor Sysprep, damit kein Image mit Temp-Administrator entsteht. ¦ The temporary account '{0}' could not be removed ({1}). Aborting before Sysprep so that no image with a temporary administrator is created.
=== Entferne Rueckstaende des Update-Laufs aus dem Image === ¦ === Removing leftovers of the update run from the image ===
Temporaere Antwortdatei entfernt: {0} ¦ Temporary answer file removed: {0}
Urspruengliche Antwortdatei wiederhergestellt: {0} ¦ Original answer file restored: {0}
Windows-Update-Richtlinien einer frueheren Tool-Version erkannt und entfernt. ¦ Windows Update policies from an older tool version detected and removed.
Windows-Update-Richtlinien auf den Ursprungszustand zurueckgesetzt. ¦ Windows Update policies restored to their original state.
Autologon des Temp-Kontos entfernt. ¦ Autologon of the temporary account removed.
Update-Helfer und geplante Aufgabe entfernt. ¦ Update helper and scheduled task removed.
Eingebautes Konto '{0}' wieder deaktiviert (wie im Original). ¦ Built-in account '{0}' disabled again (as in the original).
Rueckstaende des Update-Laufs konnten nicht vollstaendig entfernt werden: {0}. Abbruch vor Sysprep. ¦ Leftovers of the update run could not be removed completely: {0}. Aborting before Sysprep.
=== Sysprep-Versuch {0} von {1} (nach BCD-Reparatur) === ¦ === Sysprep attempt {0} of {1} (after BCD repair) ===
Die Sitzung zur VM ist nicht mehr offen - Sysprep kann nicht (erneut) gestartet werden. ¦ The session to the VM is no longer open - Sysprep cannot be started (again).
sysprep.exe nicht gefunden unter {0} ¦ sysprep.exe not found at {0}
Sysprep laeuft in der VM bereits. ¦ Sysprep is already running in the VM.
Sitzung beim Start von Sysprep beendet (beim Herunterfahren normal): {0} ¦ Session ended while starting Sysprep (normal during shutdown): {0}
Sysprep gestartet, warte auf Herunterfahren (max. {0} s)... ¦ Sysprep started, waiting for shutdown (max. {0} s)...
    ...Sysprep laeuft noch ({0} s) ¦ ...Sysprep still running ({0} s)
VM ist heruntergefahren - Sysprep war erfolgreich (nach {0} s). ¦ VM has shut down - Sysprep was successful (after {0} s).
Sysprep hat sich beendet, ohne die VM herunterzufahren - Sysprep ist fehlgeschlagen. ¦ Sysprep exited without shutting down the VM - Sysprep failed.
VM ist nach {0}s noch nicht heruntergefahren - Sysprep haengt vermutlich. ¦ VM has not shut down after {0}s - Sysprep is probably hanging.
--- Inhalt von setuperr.log (letzte 15 Zeilen) --- ¦ --- Contents of setuperr.log (last 15 lines) ---
Konnte setuperr.log nicht auslesen: {0} ¦ Could not read setuperr.log: {0}
Sysprep laeuft moeglicherweise noch - kein zweiter Versuch, um das Image nicht zu beschaedigen. ¦ Sysprep may still be running - no second attempt, to avoid damaging the image.
Versuche Workaround: BCD neu schreiben (bcdboot)... ¦ Trying workaround: rewriting BCD (bcdboot)...
bcdboot erfolgreich: {0} - versuche Sysprep erneut. ¦ bcdboot successful: {0} - retrying Sysprep.
bcdboot meldete Fehlercode {0}: {1} - versuche Sysprep trotzdem erneut. ¦ bcdboot reported error code {0}: {1} - retrying Sysprep anyway.
BCD-Reparatur fehlgeschlagen: {0} - versuche Sysprep trotzdem erneut. ¦ BCD repair failed: {0} - retrying Sysprep anyway.
Sysprep ist fehlgeschlagen (siehe setuperr.log oben). Die temporaere VM wird jetzt entfernt. ¦ Sysprep failed (see setuperr.log above). The temporary VM will be removed now.
VM ist heruntergefahren. ¦ VM has shut down.
=== Bereinige verbliebene Profilordner (offline) === ¦ === Cleaning up remaining profile folders (offline) ===
(Jetzt gefahrlos moeglich, da niemand mehr angemeldet ist.) ¦ (Now safe, because nobody is signed in anymore.)
Konnte DiskNumber nicht ermitteln. ¦ Could not determine DiskNumber.
Keine Windows-Partition gefunden. ¦ No Windows partition found.
Keine verbliebenen Profilordner gefunden. ¦ No remaining profile folders found.
WARNUNG: Profilordner '{0}' konnte nicht vollstaendig entfernt werden - nicht kritisch, fahre fort. ¦ WARNING: Profile folder '{0}' could not be removed completely - not critical, continuing.
Profilordner '{0}' entfernt. ¦ Profile folder '{0}' removed.
ProfileList-Eintrag entfernt: {0} ¦ ProfileList entry removed: {0}
WARNUNG: SOFTWARE-Hive konnte nicht geladen werden - ProfileList nicht bereinigt. ¦ WARNING: SOFTWARE hive could not be loaded - ProfileList not cleaned up.
WARNUNG: Bereinigung der Profildateien fehlgeschlagen: {0} - nicht kritisch, fahre fort. ¦ WARNING: Cleanup of profile files failed: {0} - not critical, continuing.
WARNUNG: Konnte Arbeitskopie nach Profil-Bereinigung nicht sauber aushaengen. ¦ WARNING: Could not cleanly dismount the working copy after profile cleanup.
=== Richte automatischen Login fuer naechsten Boot ein === ¦ === Setting up automatic login for next boot ===
(Dies gilt fuer JEDEN zukuenftigen Boot der fertigen VHDX, nicht nur die Tool-interne Vorbereitung.) ¦ (This applies to EVERY future boot of the finished VHDX, not only the tool's internal preparation.)
HINWEIS: Die bereits vorhandene Panther\unattend.xml des Images wird durch die Autologon-Antwortdatei ersetzt. ¦ NOTE: The existing Panther\unattend.xml of the image is replaced by the autologon answer file.
Kein Passwort angegeben - richte Autologon fuer leeres Passwort ein... ¦ No password given - setting up autologon with an empty password...
Aktiver ControlSet laut Select\Current: {0} ¦ Active ControlSet according to Select\Current: {0}
WARNUNG: Konnte Kennwort-Richtlinie nicht anpassen: {0} ¦ WARNING: Could not adjust the password policy: {0}
Winlogon-Autologon (Registry) zusaetzlich eingerichtet. ¦ Winlogon autologon (registry) additionally set up.
WARNUNG: Winlogon-Autologon konnte nicht zusaetzlich eingerichtet werden: {0} ¦ WARNING: Winlogon autologon could not be additionally set up: {0}
HINWEIS: Falls du ueber Hyper-V per 'Enhanced Session' verbindest (das ist technisch RDP), kann ein leeres Passwort trotzdem abgelehnt werden - das ist eine Windows-Sicherheitsrichtlinie fuer Remote-Anmeldungen. Verbinde stattdessen ohne 'Enhanced Session' (Basissitzung) fuer die Konsolenansicht. ¦ NOTE: If you connect via Hyper-V 'Enhanced Session' (technically RDP), an empty password may still be rejected - this is a Windows security policy for remote logons. Connect without 'Enhanced Session' (basic session) for the console view instead.
Automatischer Login eingerichtet fuer Benutzer '{0}'. ¦ Automatic login set up for user '{0}'.
HINWEIS: Das Passwort liegt dabei nur leicht verschleiert (Base64-artig, kein echter Schutz) in der VHDX - nur fuer Test-/Referenz-Images geeignet. ¦ NOTE: The password is stored only lightly obfuscated (Base64-like, no real protection) in the VHDX - suitable for test/reference images only.
HINWEIS: Konto wurde OHNE Passwort eingerichtet - jeder mit Zugriff auf die VHDX kann sich als '{0}' anmelden. ¦ NOTE: The account was set up WITHOUT a password - anyone with access to the VHDX can sign in as '{0}'.
WARNUNG: Automatischer Login konnte nicht eingerichtet werden: {0} ¦ WARNING: Automatic login could not be set up: {0}
WARNUNG: Konnte Arbeitskopie nach Autologon-Einrichtung nicht sauber aushaengen. ¦ WARNING: Could not cleanly dismount the working copy after autologon setup.
Aufräumen & Original ersetzen ¦ Clean up & replace original
=== Räume temporäre VM auf === ¦ === Cleaning up temporary VM ===
Temporäre VM entfernt. ¦ Temporary VM removed.
=== Ersetze Original durch aktualisierte Kopie === ¦ === Replacing original with updated copy ===
Sichere ursprüngliches Original nach: {0} ¦ Backing up original to: {0}
Das Original wurde an seinen urspruenglichen Platz zurueckgelegt. ¦ The original was moved back to its original location.
ACHTUNG: Das Original liegt unter '{0}', die aktualisierte Kopie unter '{1}' - bitte manuell umbenennen! ¦ ATTENTION: The original is at '{0}', the updated copy at '{1}' - please rename manually!
Das Original konnte nicht durch die aktualisierte Kopie ersetzt werden: {0} ¦ The original could not be replaced by the updated copy: {0}
Original aktualisiert. Alte Version liegt als Backup unter: {0} ¦ Original updated. The old version is kept as a backup at: {0}
Original aktualisiert. Das alte Image wurde geloescht (Backup ist abgeschaltet). ¦ Original updated. The old image was deleted (backup is turned off).
Original aktualisiert. Das alte Image konnte nicht geloescht werden und liegt noch unter: {0} ({1}) ¦ Original updated. The old image could not be deleted and is still at: {0} ({1})
=== Fertig: VHDX wurde automatisch aktualisiert und neu syspreppt === ¦ === Done: VHDX was updated automatically and sysprepped again ===
=== Abgebrochen auf Nutzerwunsch === ¦ === Cancelled at user's request ===
FEHLER: {0} ¦ ERROR: {0}
Räume auf, soweit möglich... ¦ Cleaning up as far as possible...
Temporäre VM wurde entfernt. ¦ Temporary VM was removed.
Temporäre VM '{0}' konnte nicht automatisch entfernt werden - bitte manuell im Hyper-V-Manager prüfen. ¦ Temporary VM '{0}' could not be removed automatically - please check manually in Hyper-V Manager.
Dein Original unter {0} wurde NICHT verändert (Sicherheitskopie-Modus). ¦ Your original at {0} was NOT changed (safety copy mode).
Die (evtl. teilweise aktualisierte) Kopie liegt noch unter: {0} ¦ The (possibly partially updated) copy is still at: {0}
Fehlgeschlagene Arbeitskopie geloescht: {0} ¦ Failed working copy deleted: {0}
Arbeitskopie konnte nicht geloescht werden: {0} ¦ Working copy could not be deleted: {0}
ACHTUNG: Unter {0} liegt keine Datei mehr - siehe Meldungen oben (Sicherung: {1}.bak, Kopie: {2}). ¦ ATTENTION: There is no file at {0} anymore - see messages above (backup: {1}.bak, copy: {2}).
Sicherheitskopie war deaktiviert - bitte den Zustand von {0} manuell prüfen (ggf. liegen in Windows\Panther noch *.autoupdate-bak-Dateien). ¦ Safety copy was disabled - please check the state of {0} manually (*.autoupdate-bak files may remain in Windows\Panther).
PowerShell-Direct-Sitzung geschlossen. ¦ PowerShell Direct session closed.
WARNUNG: Sitzung konnte nicht sauber geschlossen werden: {0} ¦ WARNING: Session could not be closed cleanly: {0}
\n=== AutoUpdate-Vhdx GUI - Selbsttest ===\n ¦ === AutoUpdate-Vhdx GUI - Self-test ===
ERGEBNIS: Bereit für den automatischen Update-Lauf. ¦ RESULT: Ready for the automatic update run.
ERGEBNIS: Mindestens eine kritische Voraussetzung fehlt (rot markiert). ¦ RESULT: At least one critical prerequisite is missing (marked red).
FEHLER: Listendatei nicht gefunden: {0} ¦ ERROR: List file not found: {0}
FEHLER: -Unattended benoetigt -VhdxPath oder -VhdxListFile mit mindestens einem Abbild. ¦ ERROR: -Unattended requires -VhdxPath or -VhdxListFile with at least one image.
Protokoll konnte nicht angelegt werden: {0} ¦ Log could not be created: {0}
AutoUpdate VHDX {0} - unbeaufsichtigter Lauf ¦ AutoUpdate VHDX {0} - unattended run
########## Abbild {0} von {1}: {2} ########## ¦ ########## Image {0} of {1}: {2} ##########
Abbild nicht gefunden - wird uebersprungen. ¦ Image not found - skipping.
Datei nicht gefunden ¦ File not found
========== Gesamtbilanz: {0} erfolgreich, {1} fehlgeschlagen ========== ¦ ========== Summary: {0} successful, {1} failed ==========
Protokoll: {0} ¦ Log: {0}
Protokoll konnte nicht geschrieben werden: {0} ¦ Log could not be written: {0}
AutoUpdate VHDX {0} (Zeitplan): {1} erfolgreich, {2} fehlgeschlagen. ¦ AutoUpdate VHDX {0} (schedule): {1} successful, {2} failed.
Ein Auto-Update läuft noch. Wenn du jetzt schließt, bleibt evtl. eine temporäre VM zurück, die du manuell im Hyper-V-Manager entfernen musst. Trotzdem schließen? ¦ An auto-update is still running. If you close now, a temporary VM may remain that you have to remove manually in Hyper-V Manager. Close anyway?
Update läuft noch ¦ Update still running
Laeuft ¦ Running
Erfolg ¦ Success
Fehler ¦ Error
Abbruch ¦ Cancelled
Bereit ¦ Ready
Nur .vhdx-Dateien werden unterstuetzt (die temporaere VM ist Generation 2).\n\n{0} ¦ Only .vhdx files are supported (the temporary VM is Generation 2).\n\n{0}
Nicht unterstuetzt ¦ Not supported
Bitte zuerst eine gültige VHDX-Datei auswählen oder der Warteschlange hinzufügen. ¦ Please select a valid VHDX file or add one to the queue first.
Keine VHDX ¦ No VHDX
Die Uhrzeit muss im Format HH:MM angegeben werden, zum Beispiel 02:00. ¦ The time must be in HH:MM format, for example 02:00.
Ungültige Uhrzeit ¦ Invalid time
Bitte mindestens einen Wochentag auswählen. ¦ Please select at least one weekday.
Kein Wochentag ¦ No weekday
Der Pfad des Skripts konnte nicht ermittelt werden. Ein Zeitplan lässt sich nur einrichten, wenn das Skript als Datei gestartet wurde. ¦ The script path could not be determined. A schedule can only be created if the script was started as a file.
Pfad unbekannt ¦ Unknown path
Rechte von '{0}' konnten nicht gesetzt werden: {1} ¦ Permissions of '{0}' could not be set: {1}
Zeitplan eingerichtet: {0} um {1} Uhr für {2} Abbild(er): ¦ Schedule created: {0} at {1} for {2} image(s):
Abbild-Liste: {0} ¦ Image list: {0}
Startdatei: {0} ¦ Start file: {0}
Protokolle werden abgelegt unter: {0} ¦ Logs are stored in: {0}
Die Aufgabe 'AutoUpdate-VHDX' wurde eingerichtet.\n\nSie läuft {0} um {1} Uhr.\n\nProtokolle: {2}\n\nEntfernen mit dem Button 'Zeitplan entfernen' oder:\nschtasks /Delete /TN AutoUpdate-VHDX /F ¦ The task 'AutoUpdate-VHDX' was created.\n\nIt runs {0} at {1}.\n\nLogs: {2}\n\nRemove it with the 'Remove schedule' button or:\nschtasks /Delete /TN AutoUpdate-VHDX /F
Zeitplan eingerichtet ¦ Schedule created
Zeitplan konnte nicht eingerichtet werden:\n{0} ¦ Schedule could not be created:\n{0}
Die geplante Aufgabe 'AutoUpdate-VHDX' wird entfernt. Fortfahren? ¦ The scheduled task 'AutoUpdate-VHDX' will be removed. Continue?
Zeitplan entfernen ¦ Remove schedule
Zeitplan 'AutoUpdate-VHDX' entfernt. ¦ Schedule 'AutoUpdate-VHDX' removed.
Der Zeitplan wurde entfernt. ¦ The schedule was removed.
Fertig ¦ Done
Konnte Zeitplan nicht entfernen: {0} ¦ Could not remove schedule: {0}
Der Zeitplan konnte nicht entfernt werden (evtl. war keiner eingerichtet). ¦ The schedule could not be removed (maybe none was set up).
Hinweis ¦ Note
Bitte zuerst eine VHDX-Datei auswählen. ¦ Please select a VHDX file first.
Fehlende Angabe ¦ Missing input
Die angegebene VHDX-Datei existiert nicht. ¦ The specified VHDX file does not exist.
Der Sysprep-Rearm-Zaehler dieser VHDX wird zurueckgesetzt (Registry-Eingriff, offline, ohne die VHDX zu booten). Fortfahren? ¦ The Sysprep rearm counter of this VHDX will be reset (registry change, offline, without booting the VHDX). Continue?
Rearm-Zaehler zuruecksetzen ¦ Reset rearm counter
=== Rearm-Zaehler-Reset (offline, ohne zu booten) === ¦ === Rearm counter reset (offline, without booting) ===
Mounte VHDX... ¦ Mounting VHDX...
Windows-Partition gefunden: {0}:\ ¦ Windows partition found: {0}:\
=== Rearm-Zaehler erfolgreich zurueckgesetzt === ¦ === Rearm counter reset successfully ===
Der Rearm-Zaehler wurde zurueckgesetzt. ¦ The rearm counter was reset.
Fehler beim Zuruecksetzen: {0} ¦ Error while resetting: {0}
VHDX ausgehaengt. ¦ VHDX dismounted.
WARNUNG: VHDX konnte nicht sauber ausgehaengt werden - bitte manuell pruefen (Get-VHD / Dismount-VHD). ¦ WARNING: VHDX could not be dismounted cleanly - please check manually (Get-VHD / Dismount-VHD).
=== Selbsttest wird ausgeführt === ¦ === Running self-test ===
Alle kritischen Voraussetzungen erfüllt. Bereit für den Auto-Update-Lauf. ¦ All critical prerequisites met. Ready for the auto-update run.
Mindestens eine kritische Voraussetzung fehlt (rot markiert) - siehe oben. ¦ At least one critical prerequisite is missing (marked red) - see above.
Bitte zuerst eine VHDX-Datei auswählen oder der Warteschlange hinzufügen. ¦ Please select a VHDX file or add one to the queue first.
Bitte einen Benutzernamen für den automatischen Login angeben, oder das Häkchen entfernen. ¦ Please enter a username for the automatic login, or uncheck the box.
Diese VHDX ist bereits gemountet (evtl. Rest eines vorherigen, abgebrochenen Laufs). Jetzt automatisch aushaengen und fortfahren? ¦ This VHDX is already mounted (possibly left over from a previous, cancelled run). Dismount it automatically now and continue?
VHDX bereits gemountet ¦ VHDX already mounted
Konnte die VHDX nicht aushaengen: {0} ¦ Could not dismount the VHDX: {0}
\n\nFortfahren? ¦ Continue?
Auto-Update bestätigen ¦ Confirm auto-update
Hintergrund-Task gestartet, warte auf Fortschritt... ¦ Background task started, waiting for progress...
WARNUNG: asyncResult ist NULL im Timer-Tick - breche Polling ab. ¦ WARNING: asyncResult is NULL in timer tick - stopping polling.
WARNUNG: powershell-Objekt ist NULL beim Abschluss - Ergebnis kann nicht gelesen werden. ¦ WARNING: powershell object is NULL on completion - result cannot be read.
Unerwarteter Fehler beim Lesen des Ergebnisses (EndInvoke): {0} ¦ Unexpected error while reading the result (EndInvoke): {0}
(Hinweis: Hintergrund-Task lieferte mehrere Werte zurueck, verwende den letzten.) ¦ (Note: background task returned multiple values, using the last one.)
=== Vorgang wurde abgebrochen ({0} von {1} Abbildern erfolgreich abgeschlossen) === ¦ === Operation cancelled ({0} of {1} images completed successfully) ===
=== ERFOLGREICH ABGESCHLOSSEN === ¦ === COMPLETED SUCCESSFULLY ===
Die VHDX wurde erfolgreich aktualisiert und neu syspreppt. ¦ The VHDX was successfully updated and sysprepped again.
{0} von {1} Abbildern wurden erfolgreich aktualisiert und neu syspreppt. ¦ {0} of {1} images were successfully updated and sysprepped again.
=== Teilweise abgeschlossen: {0} von {1} Abbildern erfolgreich, {2} fehlgeschlagen === ¦ === Partially completed: {0} of {1} images successful, {2} failed ===
{0} von {1} Abbildern wurden erfolgreich aktualisiert. {2} fehlgeschlagen - siehe Protokoll oben. ¦ {0} of {1} images were successfully updated. {2} failed - see log above.
Teilweise abgeschlossen ¦ Partially completed
=== Vorgang mit Fehler beendet - siehe Protokoll oben === ¦ === Operation ended with an error - see log above ===
--- Zusaetzliche Fehler im Error-Stream des Hintergrund-Tasks --- ¦ --- Additional errors in the error stream of the background task ---
KRITISCHER FEHLER im Timer-Handler: {0} ¦ CRITICAL ERROR in timer handler: {0}
Stack: {0} ¦ Stack: {0}
Wirklich abbrechen? Die temporäre VM wird automatisch aufgeräumt. Bei aktiver Sicherheitskopie bleibt dein Original unangetastet. ¦ Really cancel? The temporary VM will be cleaned up automatically. With the safety copy enabled, your original stays untouched.
Abbrechen bestätigen ¦ Confirm cancel
Abbruch angefordert - wird nach dem aktuellen Schritt wirksam... ¦ Cancel requested - takes effect after the current step...
Vorhandener Zeitplan: {0} um {1} Uhr. ¦ Existing schedule: {0} at {1}.
AutoUpdate VHDX {0} gestartet (interaktiver Modus). ¦ AutoUpdate VHDX {0} started (interactive mode).
Bereit. Tipp: Klicke zuerst auf 'Selbsttest', um zu prüfen, ob Hyper-V korrekt eingerichtet ist. ¦ Ready. Tip: click 'Self-test' first to check whether Hyper-V is set up correctly.
Verbinde mit dem Windows-Update-Dienst... ¦ Connecting to the Windows Update service...
Suche nach verfuegbaren Updates (kann einige Minuten dauern)... ¦ Searching for available updates (may take a few minutes)...
Suche abgeschlossen: {0} Update(s) gefunden. ¦ Search completed: {0} update(s) found.
[{0}%] Lade herunter ({1}/{2}): {3} ¦ [{0}%] Downloading ({1}/{2}): {3}
[{0}%] Download-Phase abgeschlossen ({1} von {2} Update(s) verarbeitet). ¦ [{0}%] Download phase completed ({1} of {2} update(s) processed).
[{0}%] Ueberspringe ({1}/{2}): {3} - {4} ¦ [{0}%] Skipping ({1}/{2}): {3} - {4}
[{0}%] Installiere ({1}/{2}): {3} ¦ [{0}%] Installing ({1}/{2}): {3}
Installation abgeschlossen: {0} erfolgreich, {1} fehlgeschlagen. ¦ Installation completed: {0} successful, {1} failed.
nicht heruntergeladen ¦ not downloaded
Download fehlgeschlagen: {0} ¦ Download failed: {0}
war zwischenzeitlich bereits installiert ¦ was already installed in the meantime
{0} -> uebersprungen ({1}) ¦ {0} -> skipped ({1})
{0} -> Installation meldete Ergebniscode {1} ¦ {0} -> installation returned result code {1}
{0} -> Installationsfehler: {1} ¦ {0} -> installation error: {1}
! {0} ¦ ! {0}
[OK] {0} ¦ [OK] {0}
[FEHLT] {0} ¦ [MISSING] {0}
[WARN] {0} ¦ [WARN] {0}
[OK]     {0} ¦ [OK]     {0}
[FEHLER] {0} - {1} ¦ [ERROR] {0} - {1}
Aktivieren: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All (Neustart nötig) ¦ Enable: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All (restart required)
Erstellen: New-VMSwitch -Name 'AutoUpdateSwitch' -NetAdapterName <DeinAdapter> -AllowManagementOS $true ¦ Create: New-VMSwitch -Name 'AutoUpdateSwitch' -NetAdapterName <YourAdapter> -AllowManagementOS $true
{0} Switch(es) gefunden ¦ {0} switch(es) found
AutoUpdate VHDX {0} (unbeaufsichtigt) ¦ AutoUpdate VHDX {0} (unattended)
Protokoll erzeugt: {0} ¦ Log created: {0}
Rechner: {0}   Benutzer: {1} ¦ Computer: {0}   User: {1}
Abbild {0}/{1} - {2} ¦ Image {0}/{1} - {2}
Starte... ¦ Starting...
Es werden {0} VHDX-Abbilder nacheinander automatisch gebootet, aktualisiert und neu syspreppt. ¦ {0} VHDX images will be booted, updated and sysprepped again automatically, one after another.
Das kann insgesamt deutlich laenger als 10-45 Minuten dauern (abhaengig von Anzahl und Groesse der Abbilder). ¦ In total this can take considerably longer than 10-45 minutes (depending on number and size of the images).
Es wird jeweils eine Sicherheitskopie verwendet - deine Originale bleiben bis zum Erfolg unangetastet. ¦ A safety copy is used for each image - your originals stay untouched until success.
SICHERHEITSKOPIE IST DEAKTIVIERT - es wird direkt an den Originalen gearbeitet! ¦ SAFETY COPY IS DISABLED - working directly on the originals!
Die VHDX wird jetzt automatisch gebootet, aktualisiert und neu syspreppt. ¦ The VHDX will now be booted, updated and sysprepped again automatically.
Das kann 10-45+ Minuten dauern. ¦ This can take 10-45+ minutes.
Es wird eine Sicherheitskopie verwendet - dein Original bleibt bis zum Erfolg unangetastet. ¦ A safety copy is used - your original stays untouched until success.
SICHERHEITSKOPIE IST DEAKTIVIERT - es wird direkt am Original gearbeitet! ¦ SAFETY COPY IS DISABLED - working directly on the original!
Automatischer Login wird fuer den Benutzer '{0}' eingerichtet. ¦ Automatic login will be set up for user '{0}'.
Nach Erfolg wird das alte Image geloescht (kein .bak-Backup). ¦ After success the old image will be deleted (no .bak backup).
ALLE lokalen Benutzer (ausser den eingebauten) und alle Benutzerprofile werden aus dem Image entfernt - auch verwaiste Profile ohne Konto. ¦ ALL local users (except the built-in ones) and all user profiles will be removed from the image - including orphaned profiles without an account.
Windows Update vollautomatisch in einer syspreppten VHDX ¦ Fully automated Windows Update inside a sysprepped VHDX
Abbild & Zeitplan ¦ Image & schedule
VHDX-Datei ¦ VHDX file
Durchsuchen ¦ Browse
Zeitplan (Uhrzeit) ¦ Schedule (time)
Zeitplan einrichten ¦ Create schedule
Wochentage (alle = täglich) ¦ Weekdays (all = daily)
Warteschlange (mehrere Abbilder nacheinander) ¦ Queue (several images one after another)
Hinzufügen ¦ Add
Entfernen ¦ Remove
Einstellungen ¦ Settings
RAM für VM (GB) ¦ VM RAM (GB)
Max. Update-Runden ¦ Max. update rounds
Nach jeder Runde wird neu gestartet und erneut geprüft, bis zwei\nPrüfungen nacheinander nichts mehr finden. ¦ After each round the VM restarts and checks again until two\nchecks in a row find nothing.
Sicherheitskopie verwenden (Original bleibt geschützt) ¦ Use safety copy (original stays protected)
Alle lokalen Benutzer entfernen (sauberes Image) ¦ Remove all local users (clean image)
Entfernt vor Sysprep alle nicht eingebauten lokalen Benutzer samt Profil\nund alle verwaisten Profilordner (Konten, die es nicht mehr gibt).\nDie Konten Administrator, Gast usw. bleiben erhalten. Ohne Haken wird nur das Temp-Konto 'AutoUpdate' entfernt. ¦ Removes all non-built-in local users including their profiles before Sysprep\nand all orphaned profile folders (accounts that no longer exist).\nThe Administrator, Guest etc. accounts are kept. Unchecked, only the temporary account 'AutoUpdate' is removed.
Ein Switch mit Internetzugang wird automatisch gewählt. ¦ A switch with internet access is selected automatically.
Altes Image nach Erfolg als .bak behalten ¦ Keep old image as .bak after success
Ohne Haken wird das alte Image nach einem ERFOLGREICHEN Lauf geloescht.\nWaehrend des Laufs bleibt das Original trotzdem geschuetzt (Sicherheitskopie). ¦ Unchecked, the old image is deleted after a SUCCESSFUL run.\nDuring the run the original is still protected (safety copy).
Automatischer Login (fertiges Abbild) ¦ Automatic login (finished image)
Nach Sysprep automatischen Login einrichten - überspringt Sprachauswahl/OOBE beim nächsten Boot ¦ Set up automatic login after Sysprep - skips language selection/OOBE on next boot
Benutzername ¦ Username
Passwort ¦ Password
Nur für Test-/Referenz-Images: Passwort liegt danach nur leicht verschleiert in der VHDX. ¦ Test/reference images only: the password is stored only lightly obfuscated in the VHDX.
Bereit. ¦ Ready.
Abbild ¦ Image
Laufzeit ¦ Runtime
Protokoll ¦ Log
Auto-Update starten ¦ Start auto-update
Abbrechen ¦ Cancel
Rearm-Zähler zurücksetzen ¦ Reset rearm counter
Selbsttest ¦ Self-test
Schließen ¦ Close
Sprache: Deutsch / Englisch ¦ Language: German / English
Wartet ¦ Waiting
Läuft ¦ Running
Abgebrochen ¦ Cancelled
'@
$script:UebersetzungExakt = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$uebersetzungListe = New-Object System.Collections.Generic.List[object]
foreach ($zeile in ($UebersetzungRoh -split "`r?`n")) {
    if (-not $zeile.Trim() -or $zeile.StartsWith("#")) { continue }
    $teile = $zeile -split " ¦ ", 2
    if ($teile.Count -ne 2) { continue }
    $deText = $teile[0].Replace('\n', "`n").Trim()
    $enText = $teile[1].Replace('\n', "`n").Trim()
    if ($deText -match '\{\d+\}') {
        $muster = '^' + ([regex]::Escape($deText) -replace '\\\{\d+}', '(.*?)') + '$'
        $uebersetzungListe.Add([pscustomobject]@{
            Regex  = New-Object System.Text.RegularExpressions.Regex($muster, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            En     = $enText
            Laenge = ($deText -replace '\{\d+\}', '').Length
        })
    } else {
        $script:UebersetzungExakt[$deText] = $enText
    }
}
# Spezifischere Muster (mehr fester Text) zuerst pruefen.
$script:UebersetzungMuster = @($uebersetzungListe | Sort-Object Laenge -Descending)
Remove-Variable UebersetzungRoh, uebersetzungListe -ErrorAction SilentlyContinue

function Convert-Sprache {
    <#
        Uebersetzt einen (deutschen) Anzeigetext ins Englische, wenn Englisch
        gewaehlt ist. Unbekannte Texte (Dateinamen, Update-Titel, Fehlertexte
        von Windows) bleiben unveraendert. Variable Teile werden rekursiv
        mituebersetzt (z.B. "FEHLER: <bekannte Meldung>").
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Tiefe = 0)
    $sprache = $UiSprache
    if ($sharedState -and $sharedState.Sprache) { $sprache = $sharedState.Sprache }
    if ($sprache -ne "en" -or [string]::IsNullOrEmpty($Text) -or -not $UebersetzungExakt) { return $Text }
    $teil = [regex]::Match($Text, '^(\s*)(.*?)(\s*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $vor = $teil.Groups[1].Value
    $kern = $teil.Groups[2].Value
    $nach = $teil.Groups[3].Value
    if ($kern.Length -eq 0) { return $Text }
    if ($UebersetzungExakt.ContainsKey($kern)) { return $vor + $UebersetzungExakt[$kern] + $nach }
    foreach ($eintrag in $UebersetzungMuster) {
        $treffer = $eintrag.Regex.Match($kern)
        if (-not $treffer.Success) { continue }
        $werte = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -lt $treffer.Groups.Count; $i++) {
            $wert = $treffer.Groups[$i].Value
            if ($Tiefe -lt 2) { $wert = Convert-Sprache -Text $wert -Tiefe ($Tiefe + 1) }
            $werte.Add([string]$wert)
        }
        return $vor + ($eintrag.En -f $werte.ToArray()) + $nach
    }
    # Mehrteilige Meldungen (Absaetze) einzeln uebersetzen.
    if ($kern.Contains("`n`n") -and $Tiefe -lt 2) {
        $absaetze = foreach ($absatz in ($kern -split "`n`n")) { Convert-Sprache -Text $absatz -Tiefe ($Tiefe + 1) }
        return $vor + ($absaetze -join "`n`n") + $nach
    }
    return $Text
}

function T {
    # Kurzform fuer Texte, die direkt im Code zweisprachig stehen.
    param([string]$De, [string]$En)
    $sprache = $UiSprache
    if ($sharedState -and $sharedState.Sprache) { $sprache = $sharedState.Sprache }
    if ($sprache -eq "en") { return $En } else { return $De }
}

function Save-Sprache {
    param([ValidateSet("de", "en")][string]$Sprache)
    try {
        $ordner = Split-Path $script:EinstellungenDatei -Parent
        if (-not (Test-Path -LiteralPath $ordner)) { New-Item -ItemType Directory -Path $ordner -Force | Out-Null }
        $daten = [ordered]@{}
        if (Test-Path -LiteralPath $script:EinstellungenDatei) {
            try {
                $alt = Get-Content -LiteralPath $script:EinstellungenDatei -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $alt.PSObject.Properties) { $daten[$p.Name] = $p.Value }
            } catch { }
        }
        $daten["Sprache"] = $Sprache
        ($daten | ConvertTo-Json) | Set-Content -LiteralPath $script:EinstellungenDatei -Encoding UTF8 -Force
    } catch { }
}

# ===========================================================================
# Selbst-Erhoehung: Ohne Administratorrechte startet sich das Skript mit
# UAC-Abfrage selbst neu. (Ersetzt "#Requires -RunAsAdministrator", das nur
# mit einer Fehlermeldung abbricht.) Die Rechte werden dabei NICHT umgangen,
# sondern ganz normal ueber die UAC-Abfrage angefordert.
# ===========================================================================
$istAdmin = $false
try {
    $istAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $istAdmin) {
    $skriptDatei = $PSCommandPath
    if (-not $skriptDatei) { $skriptDatei = $MyInvocation.MyCommand.Path }
    if ($Unattended -or -not $skriptDatei) {
        # Geplante Aufgaben koennen keine UAC-Abfrage anzeigen.
        Write-Host (Convert-Sprache "FEHLER: Dieses Tool benoetigt Administratorrechte.") -ForegroundColor Red
        exit 5
    }
    $argListe = @("-NoProfile", "-ExecutionPolicy", "Bypass")
    if ($SelfTest) { $argListe += "-NoExit" }   # Konsolenfenster offen lassen
    $argListe += @("-File", "`"$skriptDatei`"")
    foreach ($eintrag in $PSBoundParameters.GetEnumerator()) {
        if ($eintrag.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($eintrag.Value.IsPresent) { $argListe += "-$($eintrag.Key)" }
        } elseif ($eintrag.Value -is [array]) {
            continue   # Arrays nur im Unattended-Modus - der laeuft ohnehin als Admin
        } else {
            $argListe += "-$($eintrag.Key)"
            $argListe += "`"$($eintrag.Value)`""
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList ($argListe -join " ") -ErrorAction Stop | Out-Null
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                (Convert-Sprache "Das Tool benoetigt Administratorrechte (Hyper-V, VHDX mounten, Registry offline bearbeiten).`n`nDie UAC-Abfrage wurde abgelehnt - das Tool wird beendet."),
                (Convert-Sprache "Administratorrechte erforderlich"), "OK", "Warning") | Out-Null
        } catch {
            Write-Host (Convert-Sprache "Administratorrechte wurden nicht erteilt - Abbruch.") -ForegroundColor Red
        }
    }
    exit
}

# Versionskennung: wird ins Protokoll geschrieben, damit sich im
# Nachhinein feststellen laesst, welcher Programmstand gelaufen ist.
$ToolVersion = "1.2"

$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }

# ===========================================================================
# Kernlogik (von GUI-Runspace UND Konsolen-Selbsttest genutzt)
# ===========================================================================
function Test-Prerequisites {
    <#
        Liefert eine Liste von PSCustomObjects mit Name/Pass/Detail/IsCritical.
        Wird sowohl vom "Selbsttest"-Button als auch vom -SelfTest
        Kommandozeilen-Modus genutzt, damit beide garantiert dasselbe prüfen.
    #>
    $checks = @()
    $isAdmin = $false
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        # Falls diese Pruefung aus irgendeinem Grund scheitert (z.B. stark
        # eingeschraenkter Sicherheitskontext), soll nur dieser eine Punkt
        # als fehlgeschlagen markiert werden statt den kompletten Selbsttest
        # abstuerzen zu lassen.
    }
    $checks += [PSCustomObject]@{ Name = "Administrator-Rechte"; Pass = $isAdmin; Detail = ""; IsCritical = $true }
    Import-Module Hyper-V -ErrorAction SilentlyContinue
    $hyperv = [bool](Get-Command New-VM -ErrorAction SilentlyContinue)
    $checks += [PSCustomObject]@{
        Name = "Hyper-V-Modul (New-VM) verfügbar"; Pass = $hyperv; IsCritical = $true
        Detail = $(if (-not $hyperv) { "Aktivieren: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All (Neustart nötig)" } else { "" })
    }
    $vmmsRunning = $false
    try { $vmmsRunning = (Get-Service -Name vmms -ErrorAction Stop).Status -eq "Running" } catch {}
    $checks += [PSCustomObject]@{ Name = "Hyper-V-Verwaltungsdienst (vmms) läuft"; Pass = $vmmsRunning; Detail = ""; IsCritical = $true }
    $switchCount = 0
    try { $switchCount = (Get-VMSwitch -ErrorAction SilentlyContinue).Count } catch {}
    $checks += [PSCustomObject]@{
        Name = "Virtueller Switch vorhanden"; Pass = ($switchCount -gt 0); IsCritical = $true
        Detail = $(if ($switchCount -eq 0) { "Erstellen: New-VMSwitch -Name 'AutoUpdateSwitch' -NetAdapterName <DeinAdapter> -AllowManagementOS `$true" } else { "$switchCount Switch(es) gefunden" })
    }
    try {
        $qualifier = (Split-Path $env:TEMP -Qualifier).TrimEnd(':')
        $freeSpace = (Get-PSDrive -Name $qualifier -ErrorAction Stop).Free / 1GB
        $spaceOk = $freeSpace -gt 15
        $checks += [PSCustomObject]@{
            Name = "Freier Speicherplatz > 15 GB"; Pass = $spaceOk; IsCritical = $false
            Detail = "$([math]::Round($freeSpace,1)) GB frei auf ${qualifier}: (TEMP-Laufwerk; der Platz im VHDX-Ordner wird beim Start separat geprueft)"
        }
    } catch {
        $checks += [PSCustomObject]@{ Name = "Freier Speicherplatz > 15 GB"; Pass = $false; Detail = "Konnte nicht geprüft werden"; IsCritical = $false }
    }
    return $checks
}

function Write-AutoUpdateEvent {
    <#
        Schreibt einen Eintrag ins Windows-Anwendungsprotokoll, damit
        vorhandene Ueberwachungssysteme einen naechtlichen Lauf erkennen
        koennen, ohne dass jemand ins Text-Log schauen muss.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("Information", "Warning", "Error")][string]$Level = "Information",
        [int]$EventId = 1000
    )
    $Message = Convert-Sprache $Message
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("AutoUpdateVHDX")) {
            New-EventLog -LogName Application -Source "AutoUpdateVHDX" -ErrorAction Stop
        }
        Write-EventLog -LogName Application -Source "AutoUpdateVHDX" `
            -EntryType $Level -EventId $EventId -Message $Message -ErrorAction Stop
    } catch {
        # Kein Abbruchgrund - das Ereignisprotokoll ist eine Zusatzmeldung.
    }
}

function Remove-AlteProtokolle {
    <#
        Haelt den Protokollordner klein, indem nur die letzten $Behalten
        Log-Dateien aufbewahrt werden. Ohne diese Regel waechst der Ordner
        bei taeglichem Lauf unbegrenzt.
    #>
    param([Parameter(Mandatory)][string]$Ordner, [int]$Behalten = 60)
    try {
        $dateien = @(Get-ChildItem -Path $Ordner -Filter "AutoUpdateVHDX_*.log" -File -ErrorAction Stop |
                     Sort-Object LastWriteTime -Descending)
        if ($dateien.Count -gt $Behalten) {
            $dateien | Select-Object -Skip $Behalten | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Invoke-HiveUnload {
    <#
        Entlaedt eine offline geladene Registry-Hive mit mehreren Versuchen
        und PRUEFT das Ergebnis. Bleibt eine Hive geladen, laesst sich die
        VHDX nicht mehr aushaengen und das Ersetzen des Originals scheitert
        spaeter - deshalb wird das hier nicht mehr stillschweigend ignoriert.
        Gibt $true bei Erfolg zurueck.
    #>
    param([Parameter(Mandatory)][string]$HiveName)
    for ($versuch = 1; $versuch -le 5; $versuch++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds (300 * $versuch)
        reg unload "HKLM\$HiveName" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

function Find-WindowsDriveLetter {
    <#
        Sucht auf einer gemounteten Disk die Windows-Partition und gibt deren
        Laufwerksbuchstaben zurueck ($null, wenn keine gefunden). Vergibt
        Buchstaben NUR an Daten-Partitionen (GPT "Basic" / MBR "IFS") - EFI-,
        MSR- und Recovery-Partitionen bekommen keinen Buchstaben mehr.
    #>
    param([Parameter(Mandatory)][int]$DiskNumber)
    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    foreach ($p in $partitions) {
        if ($p.DriveLetter -and (Test-Path -LiteralPath "$($p.DriveLetter):\Windows\System32\config")) { return [string]$p.DriveLetter }
    }
    foreach ($p in $partitions) {
        if ($p.DriveLetter) { continue }
        if (@("Basic", "IFS") -notcontains [string]$p.Type) { continue }
        try {
            Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -ErrorAction Stop
        } catch { continue }
        if ($p.DriveLetter -and (Test-Path -LiteralPath "$($p.DriveLetter):\Windows\System32\config")) { return [string]$p.DriveLetter }
    }
    return $null
}

function Reset-SysprepRearmCounter {
    <#
        Setzt den Sysprep-Generalisierungs-/Rearm-Status einer VHDX zurueck,
        falls das (bei Windows 7/Server-Systemen relevante) 3x-Rearm-Limit
        erreicht wurde. Basiert auf dem mehrfach in der Praxis bestaetigten
        Community-Workaround: CleanupState=2, GeneralizationState=7 im
        Sysprep-Status-Key, sowie SkipRearm=1 in der SoftwareProtectionPlatform.
        Hinweis: Bei Windows 8/10/11 kann der Lizenzierungsstatus laut
        Microsoft-Dokumentation ohnehin wiederholt zurueckgesetzt werden -
        dieser Reset ist daher vor allem fuer aeltere Images oder als
        zusaetzliche Absicherung relevant.
        Gibt $true bei Erfolg zurueck, wirft bei Fehlern eine Exception.
    #>
    param(
        [Parameter(Mandatory)][string]$OfflineWindowsPath,
        [scriptblock]$LogFunc = { param($m, $c) Write-Host $m }
    )

    $systemHive = Join-Path $OfflineWindowsPath "Windows\System32\config\SYSTEM"
    $softwareHive = Join-Path $OfflineWindowsPath "Windows\System32\config\SOFTWARE"

    if (-not (Test-Path $systemHive) -or -not (Test-Path $softwareHive)) {
        throw "SYSTEM- oder SOFTWARE-Hive nicht gefunden unter $OfflineWindowsPath\Windows\System32\config"
    }

    $sysHiveName = "RESET_SYSTEM_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $swHiveName = "RESET_SOFTWARE_$([guid]::NewGuid().ToString('N').Substring(0,8))"

    reg load "HKLM\$sysHiveName" $systemHive 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Konnte SYSTEM-Hive nicht laden." }
    reg load "HKLM\$swHiveName" $softwareHive 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        reg unload "HKLM\$sysHiveName" 2>&1 | Out-Null
        throw "Konnte SOFTWARE-Hive nicht laden."
    }

    try {
        $statusKey = "HKLM:\$sysHiveName\Setup\Status\SysprepStatus"
        if (Test-Path $statusKey) {
            Set-ItemProperty -Path $statusKey -Name "CleanupState" -Value 2 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $statusKey -Name "GeneralizationState" -Value 7 -Type DWord -ErrorAction SilentlyContinue
            & $LogFunc "SysprepStatus zurueckgesetzt (CleanupState=2, GeneralizationState=7)." "Gray"
        } else {
            & $LogFunc "SysprepStatus-Key nicht gefunden - evtl. noch nie syspreppt, kein Reset noetig." "Gray"
        }

        $sppKey = "HKLM:\$swHiveName\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform"
        if (-not (Test-Path $sppKey)) {
            New-Item -Path $sppKey -Force | Out-Null
        }
        Set-ItemProperty -Path $sppKey -Name "SkipRearm" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        & $LogFunc "SkipRearm in SoftwareProtectionPlatform gesetzt." "Gray"

        return $true
    } finally {
        if (-not (Invoke-HiveUnload -HiveName $sysHiveName)) {
            & $LogFunc "WARNUNG: SYSTEM-Hive ($sysHiveName) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern." "Red"
        }
        if (-not (Invoke-HiveUnload -HiveName $swHiveName)) {
            & $LogFunc "WARNUNG: SOFTWARE-Hive ($swHiveName) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern." "Red"
        }
    }
}

function Start-AutoUpdate {
    <#
        Führt den kompletten automatischen Update-Prozess aus.
        LogFunc: scriptblock { param($message, $color) ... } für Log-Ausgabe
        PhaseFunc: scriptblock { param($phaseName, $phaseIndex, $totalPhases) ... } für Fortschrittsanzeige
    #>
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [int]$MemoryGB = 8,
        [int]$MaxUpdateRounds = 5,
        [bool]$UseSafeCopy = $true,
        [bool]$SetupFinalAutoLogon = $false,
        [string]$FinalAutoLogonUser = "",
        [string]$FinalAutoLogonPassword = "",
        [scriptblock]$LogFunc = { param($m, $c) Write-Host $m },
        [scriptblock]$PhaseFunc = { param($name, $idx, $total) },
        [scriptblock]$ShouldCancel = { return $false },
        # $false = bei einem Fehlschlag wird die Arbeitskopie geloescht
        # (Zeitplan-Betrieb, damit die Platte nicht voll laeuft).
        [bool]$KeepFailedCopy = $true,
        # $true = ALLE nicht eingebauten lokalen Benutzer samt Profil
        # entfernen (sauberes Image). $false = nur das Temp-Konto.
        [bool]$RemoveAllLocalUsers = $false,
        # $true = altes Image nach Erfolg als .bak behalten,
        # $false = nach Erfolg loeschen (kein taegliches Backup).
        [bool]$KeepBackup = $true
    )
    $VMName = "AutoUpdate-Temp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $workingVhdxPath = $VhdxPath
    $vmCreated = $false
    $usingCopy = $UseSafeCopy
    $totalPhases = 8
    # Zugangsdaten für den Autologon-Account, den die unattend.xml weiter
    # unten in der VM anlegt (siehe OOBE-Automatisierung). OHNE dieses
    # Credential kann sich New-PSSession -VMName bei einem lokalen, nicht
    # domänenverbundenen Konto NIE authentifizieren - das war die
    # eigentliche Ursache dafür, dass die Verbindung nach 600s trotz
    # sichtbarem Desktop in der VM immer wieder mit Timeout fehlschlug.
    # Standard-Passwort des Tools - an EINER Stelle definiert und von
    # Credential UND unattend.xml gemeinsam genutzt, damit beide nie
    # auseinanderlaufen koennen.
    $vmUser = "AutoUpdate"
    $vmPlainPass = "Passw0rd"
    $vmSecurePass = ConvertTo-SecureString $vmPlainPass -AsPlainText -Force
    $vmCred = New-Object System.Management.Automation.PSCredential($vmUser, $vmSecurePass)
    # Geschuetzte/eingebaute Konten, die von der Kontobereinigung vor Sysprep
    # (online weiter unten UND im offline-Sicherheitsnetz nach dem
    # Herunterfahren) NIEMALS geloescht, deaktiviert oder deren Profil
    # entfernt werden darf - egal was sonst noch in der VM angelegt wurde.
    # Gilt fuer denselben Zweck, mit dem hier bereits an anderer Stelle sehr
    # bewusst mit dem eingebauten Administrator-Konto umgegangen wird (nur
    # temporaer aktivieren, danach wieder in den Ursprungszustand bringen -
    # nie einfach loeschen). Diese eine Liste ist die einzige Quelle der
    # Wahrheit dafuer und wird ueber die Session-Grenze hinweg per $using:
    # an die entfernten Scriptblocks weitergereicht (siehe unten).
    $protectedLocalAccounts = @("Administrator", "Guest", "DefaultAccount", "WDAGUtilityAccount", "defaultuser0")
    # NUR diese vom Tool selbst angelegten Konten werden am Ende entfernt.
    # Frueher wurden ALLE nicht eingebauten lokalen Konten samt Profil
    # geloescht - also auch absichtlich im Image angelegte Konten.
    $toolAccounts = @($vmUser)
    function CheckCancel {
        if (& $ShouldCancel) { throw "ABGEBROCHEN_VOM_NUTZER" }
    }
    function Test-VMInternetAccess {
        <#
            Prueft aus der laufenden VM heraus, ob die PowerShell Gallery
            erreichbar ist. Muss als VERSCHACHTELTE Funktion hier drin
            stehen (nicht als eigenstaendige Top-Level-Funktion), weil nur
            der Code von Start-AutoUpdate selbst in den GUI-Runspace kopiert
            wird (siehe $allFuncText weiter unten im Skript) - eine separate
            Funktion waere dort schlicht nicht bekannt.
        #>
        param(
            [Parameter(Mandatory)]$Session,
            [switch]$Quiet
        )
        try {
            $result = Invoke-Command -Session $Session -ScriptBlock {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                try {
                    if (Test-Connection -ComputerName "www.powershellgallery.com" -Count 1 -Quiet -ErrorAction Stop) { return $true }
                } catch {}
                try {
                    $null = Invoke-WebRequest -Uri "https://www.powershellgallery.com" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                    return $true
                } catch { return $false }
            } -ErrorAction Stop
            return [bool]$result
        } catch {
            if (-not $Quiet) { & $LogFunc "Verbindungstest fehlgeschlagen: $($_.Exception.Message)" "Orange" }
            return $false
        }
    }
    function Invoke-WUJobInVM {
        <#
            Fuehrt den Windows-Update-Helfer IN der VM als lokal geplante
            Aufgabe (als SYSTEM) aus und wartet auf dessen JSON-Ergebnis.

            Hintergrund: Microsoft erlaubt Download und Installation ueber
            die Windows-Update-Agent-COM-API AUSDRUECKLICH NICHT aus einer
            Remote-Sitzung heraus - CreateUpdateDownloader und
            CreateUpdateInstaller sind remote gesperrt. Der offiziell
            empfohlene Weg ist eine lokal laufende geplante Aufgabe, genau
            das macht diese Funktion. Muss eine VERSCHACHTELTE Funktion
            sein, weil nur der Code von Start-AutoUpdate in den GUI-
            Runspace kopiert wird.
        #>
        param(
            [Parameter(Mandatory)][ref]$SessionRef,
            [Parameter(Mandatory)][ValidateSet("search", "install")][string]$Mode,
            [int]$TimeoutSeconds = 5400
        )
        $resultPath = "C:\Windows\Temp\autoupdate_wu_result.json"
        $statusPath = "C:\Windows\Temp\autoupdate_wu_status.txt"
        $jobStartInfo = Invoke-Command -Session $SessionRef.Value -ScriptBlock {
            param($m, $rp, $sp)
            if (Test-Path $rp) { Remove-Item $rp -Force -ErrorAction SilentlyContinue }
            if (Test-Path $sp) { Remove-Item $sp -Force -ErrorAction SilentlyContinue }
            $null = & schtasks.exe /Delete /TN "AutoUpdateWU" /F 2>&1
            $taskCmd = "powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File C:\Windows\Temp\autoupdate_wu_helper.ps1 -Mode $m"
            $createOut = & schtasks.exe /Create /TN "AutoUpdateWU" /TR $taskCmd /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Geplante Aufgabe konnte nicht erstellt werden: $createOut" }
            $runOut = & schtasks.exe /Run /TN "AutoUpdateWU" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Geplante Aufgabe konnte nicht gestartet werden: $runOut" }
            # Startzeit des laufenden Windows zurueckgeben - daran wird
            # spaeter ein Neustart zweifelsfrei erkannt.
            (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        } -ArgumentList $Mode, $resultPath, $statusPath -ErrorAction Stop
        $bootAtStart = $null
        try { if ($jobStartInfo) { $bootAtStart = [datetime](@($jobStartInfo)[-1]) } } catch { }

        $waitedLocal = 0
        $pollInterval = 5
        $lastStatusText = $null
        $missingResultPolls = 0
        $probeFailures = 0
        $lastUptime = $null
        try { $lastUptime = (Get-VM -Name $VMName -ErrorAction Stop).Uptime } catch { }
        while ($waitedLocal -lt $TimeoutSeconds) {
            CheckCancel
            Start-Sleep -Seconds $pollInterval
            $waitedLocal += $pollInterval

            # Neustart von der HOST-Seite erkennen (ohne die evtl. tote
            # Sitzung anzufassen): Laufzeit der VM ist kleiner geworden.
            try {
                $uptimeNow = (Get-VM -Name $VMName -ErrorAction Stop).Uptime
                if ($lastUptime -and $uptimeNow -lt $lastUptime -and $SessionRef.Value) {
                    & $LogFunc "Neustart der VM erkannt (vermutlich von Windows selbst ausgeloest) - baue Verbindung neu auf..." "Orange"
                    try { Remove-PSSession $SessionRef.Value -ErrorAction SilentlyContinue } catch { }
                    $SessionRef.Value = $null
                }
                $lastUptime = $uptimeNow
            } catch { }

            # Sitzung ggf. neu aufbauen - waehrend langer Installationen
            # kann die VM zwischendurch neu starten.
            if (-not $SessionRef.Value -or $SessionRef.Value.State -ne "Opened") {
                $rebuilt = $null
                $reWait = 0
                while ($reWait -lt 600 -and -not $rebuilt) {
                    CheckCancel
                    try { $rebuilt = New-PSSession -VMName $VMName -Credential $vmCred -ErrorAction Stop }
                    catch { Start-Sleep -Seconds 10; $reWait += 10 }
                }
                if (-not $rebuilt) { throw "Verbindung zur VM ging waehrend des Update-Laufs verloren und liess sich nicht wiederherstellen." }
                $SessionRef.Value = $rebuilt
                $probeFailures = 0
                & $LogFunc "Verbindung zur VM wiederhergestellt." "Gray"
            }
            $probe = $null
            try {
                $probe = Invoke-Command -Session $SessionRef.Value -ScriptBlock {
                    param($rp, $sp)
                    $r = $null
                    $s = $null
                    if (Test-Path $rp) { $r = Get-Content -Path $rp -Raw }
                    if (Test-Path $sp) { $s = Get-Content -Path $sp -Raw }
                    $q = ""
                    try { $q = (& schtasks.exe /Query /TN "AutoUpdateWU" /FO LIST 2>&1 | Out-String) } catch { }
                    $bt = $null
                    try { $bt = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime } catch { }
                    New-Object PSObject -Property @{ ResultJson = $r; StatusText = $s; TaskQuery = $q; BootTime = $bt }
                } -ArgumentList $resultPath, $statusPath -ErrorAction Stop
                $probeFailures = 0
            } catch {
                # Frueher: einfach "continue" - bei einer toten Sitzung, die
                # sich weiter als "Opened" meldete, wartete das Tool dadurch
                # bis zum 2-Stunden-Timeout, ohne etwas zu melden. Jetzt wird
                # die Sitzung nach 3 Fehlschlaegen verworfen und neu aufgebaut.
                $probeFailures++
                if ($probeFailures -ge 3) {
                    & $LogFunc "Verbindung zur VM antwortet nicht mehr - baue sie neu auf..." "Orange"
                    try { Remove-PSSession $SessionRef.Value -ErrorAction SilentlyContinue } catch { }
                    $SessionRef.Value = $null
                    $probeFailures = 0
                }
                continue
            }

            # Fertig? -> Ergebnis zurueckgeben
            if ($probe.ResultJson) {
                try { return ($probe.ResultJson | ConvertFrom-Json) }
                catch { throw "Ergebnisdatei des Update-Helfers war unlesbar: $($_.Exception.Message)" }
            }

            # Fortschrittsmeldung des Helfers anzeigen, sobald sie sich aendert
            if ($probe.StatusText) {
                $clean = ($probe.StatusText -replace "`r", "").Trim()
                if ($clean -and $clean -ne $lastStatusText) {
                    $lastStatusText = $clean
                    $parts = $clean -split "\|", 2
                    $textOnly = if ($parts.Count -eq 2) { $parts[1] } else { $clean }
                    & $LogFunc "    $textOnly" "DarkGray"
                }
            }

            # Ist Windows seit dem Start des Helfers neu gestartet und es gibt
            # kein Ergebnis, wurde der Helfer abgewuergt - sofort melden,
            # statt auf den Aufgabenstatus zu warten.
            if ($bootAtStart -and $probe.BootTime -and ([datetime]$probe.BootTime -ne $bootAtStart)) {
                return (New-Object PSObject -Property @{
                    Success        = $false
                    Interrupted    = $true
                    UpdateCount    = 0
                    RebootRequired = $false
                    Installed      = 0
                    Failed         = 0
                    ErrorText      = "Die VM wurde waehrend des Update-Helfers neu gestartet (Modus: $Mode)."
                    Titles         = @()
                })
            }

            # Haenger-Erkennung: Laeuft die geplante Aufgabe ueberhaupt noch?
            # Wenn sie beendet ist, aber keine Ergebnisdatei existiert, wurde
            # der Helfer abgewuergt - typischerweise durch einen von Windows
            # Update erzwungenen Neustart mitten in der Installation.
            $taskLooksRunning = $true
            if ($probe.TaskQuery) {
                if ($probe.TaskQuery -match "(?im)^\s*(Status|Zustand)\s*:\s*(Running|Wird ausgef)") {
                    $taskLooksRunning = $true
                } elseif ($probe.TaskQuery -match "(?im)^\s*(Status|Zustand)\s*:\s*(Ready|Bereit|Disabled|Deaktiviert)") {
                    $taskLooksRunning = $false
                }
            }
            if (-not $taskLooksRunning) {
                $missingResultPolls++
                # 3 Durchlaeufe Kulanz, falls die Ergebnisdatei gerade
                # geschrieben wird, waehrend die Aufgabe schon endet.
                if ($missingResultPolls -ge 3) {
                    return (New-Object PSObject -Property @{
                        Success        = $false
                        Interrupted    = $true
                        UpdateCount    = 0
                        RebootRequired = $false
                        Installed      = 0
                        Failed         = 0
                        ErrorText      = "Die geplante Aufgabe in der VM ist beendet, hat aber kein Ergebnis hinterlassen (Modus: $Mode)."
                        Titles         = @()
                    })
                }
            } else {
                $missingResultPolls = 0
            }
        }
        throw "Der Windows-Update-Helfer hat innerhalb von $TimeoutSeconds Sekunden kein Ergebnis geliefert (Modus: $Mode)."
    }
    function Restart-VMAndReconnect {
        <#
            Startet die VM kontrolliert neu und wartet, bis PowerShell
            Direct wieder erreichbar ist. Nach einem grossen kumulativen
            Update kann der Bootvorgang ("Updates werden konfiguriert...")
            sehr lange dauern, deshalb hier ein grosszuegigeres Zeitlimit
            als beim Erststart.
        #>
        param([Parameter(Mandatory)][ref]$SessionRef)
        # Startzeitpunkt des laufenden Windows merken. Damit laesst sich
        # spaeter zweifelsfrei erkennen, dass der Neustart wirklich passiert
        # ist - eine Verbindung zum noch herunterfahrenden System wuerde
        # sonst faelschlich als "wieder online" durchgehen. Genau diese
        # Absicherung erlaubt es, auf die frueher noetige blinde Wartezeit
        # zu verzichten und stattdessen sofort und engmaschig zu pruefen.
        $bootBefore = $null
        try {
            $bootBefore = Invoke-Command -Session $SessionRef.Value -ScriptBlock {
                (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
            } -ErrorAction Stop
        } catch { }
        & $LogFunc "Starte VM neu..." "Gray"
        try { Invoke-Command -Session $SessionRef.Value -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue } catch { }
        try { Remove-PSSession $SessionRef.Value -ErrorAction SilentlyContinue } catch { }
        $SessionRef.Value = $null
        # Nur wenn die Boot-Zeit nicht ermittelt werden konnte, ist eine
        # kurze Schonfrist noetig - sonst uebernimmt die Verifikation.
        if (-not $bootBefore) { Start-Sleep -Seconds 20 }
        $waitedR = 0
        $lastErrR = $null
        $intervalR = 5
        while ($waitedR -lt 900) {
            CheckCancel
            Start-Sleep -Seconds $intervalR
            $waitedR += $intervalR
            $candidate = $null
            try { $candidate = New-PSSession -VMName $VMName -Credential $vmCred -ErrorAction Stop }
            catch { $lastErrR = $_.Exception.Message; continue }
            if ($bootBefore) {
                $bootNow = $null
                try {
                    $bootNow = Invoke-Command -Session $candidate -ScriptBlock {
                        (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
                    } -ErrorAction Stop
                } catch { }
                if ($bootNow -and ([datetime]$bootNow -eq [datetime]$bootBefore)) {
                    # Noch das alte System - faehrt gerade erst herunter.
                    try { Remove-PSSession $candidate -ErrorAction SilentlyContinue } catch { }
                    continue
                }
            }
            $SessionRef.Value = $candidate
            break
        }
        if (-not $SessionRef.Value) { throw "Die VM kam nach dem Neustart nicht wieder online (nach 900 s, letzter Fehler: $lastErrR)." }
        & $LogFunc "VM wieder online nach Neustart (nach $waitedR s)." "Lime"
    }
    function Wait-VMUpdateStackIdle {
        <#
            Wartet, bis Windows seine Update-Nachbereitung abgeschlossen hat.
            Ohne diese Wartezeit meldet eine sofort danach gestartete Suche
            haeufig faelschlich "keine Updates", weil der Update-Stack noch
            mit dem Aufraeumen beschaeftigt ist - genau der Effekt, durch den
            beim manuellen Nachschauen ploetzlich doch wieder Updates
            auftauchen.
        #>
        param([Parameter(Mandatory)][ref]$SessionRef, [int]$MaxWaitSeconds = 420)
        & $LogFunc "Warte, bis Windows die Update-Nachbereitung abgeschlossen hat..." "Gray"
        $waitedI = 0
        $idleStreak = 0
        $lastBusyLog = 0
        while ($waitedI -lt $MaxWaitSeconds) {
            CheckCancel
            $busy = $null
            try {
                $busy = Invoke-Command -Session $SessionRef.Value -ScriptBlock {
                    # NUR die Prozesse, die tatsaechlich Update-Arbeit
                    # verrichten. Frueher standen hier auch UsoClient und
                    # MoUsoCoreWorker - letzterer laeuft auf Windows 10/11
                    # aber praktisch dauerhaft, wodurch "ruhig" nie eintrat
                    # und immer bis zum Zeitlimit gewartet wurde.
                    $names = @("TiWorker", "TrustedInstaller")
                    $before = @{}
                    foreach ($n in $names) {
                        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
                        if ($p) {
                            $cpu = 0
                            foreach ($one in @($p)) { if ($one.CPU) { $cpu += $one.CPU } }
                            $before[$n] = $cpu
                        }
                    }
                    if ($before.Count -eq 0) { return ,@() }
                    # Zweite Messung: entscheidend ist nicht, ob ein Prozess
                    # existiert, sondern ob er wirklich rechnet. TiWorker
                    # bleibt nach getaner Arbeit noch eine Weile im Leerlauf
                    # bestehen.
                    Start-Sleep -Seconds 3
                    $active = @()
                    foreach ($n in @($before.Keys)) {
                        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
                        if (-not $p) { continue }
                        $cpu = 0
                        foreach ($one in @($p)) { if ($one.CPU) { $cpu += $one.CPU } }
                        if (($cpu - $before[$n]) -gt 0.4) { $active += $n }
                    }
                    ,$active
                } -ErrorAction Stop
            } catch {
                Start-Sleep -Seconds 5
                $waitedI += 5
                continue
            }
            if (@($busy).Count -eq 0) {
                $idleStreak++
                # Drei ruhige Messungen hintereinander, damit ein kurzes
                # Luftholen zwischen zwei Arbeitsschritten nicht schon als
                # "fertig" durchgeht.
                if ($idleStreak -ge 3) {
                    & $LogFunc "Update-Nachbereitung abgeschlossen (nach $waitedI s)." "Gray"
                    return
                }
            } else {
                $idleStreak = 0
                if (($waitedI - $lastBusyLog) -ge 60) {
                    $lastBusyLog = $waitedI
                    & $LogFunc "    ...noch beschaeftigt: $(@($busy) -join ', ') ($waitedI s)" "DarkGray"
                }
            }
            Start-Sleep -Seconds 5
            $waitedI += 5
        }
        if ($MaxWaitSeconds -le 120) {
            # Kurzes Zeitlimit zwischen den Runden: Windows raeumt im
            # Hintergrund weiter auf, die anschliessende Update-Suche
            # laeuft problemlos parallel dazu. Ein leeres Suchergebnis
            # faengt der Bestaetigungsdurchlauf ohnehin ab.
            & $LogFunc "Windows raeumt noch im Hintergrund auf - die Suche laeuft parallel weiter." "Gray"
        } else {
            & $LogFunc "Die Update-Nachbereitung laeuft laenger als $MaxWaitSeconds s - fahre trotzdem fort." "Orange"
        }
    }
    try {
        & $PhaseFunc "Vorbereitung" 1 $totalPhases
        & $LogFunc "=== Vorbereitung ===" "Cyan"
        Import-Module Hyper-V -ErrorAction Stop
        if (-not (Get-Service -Name vmms -ErrorAction SilentlyContinue) -or (Get-Service -Name vmms).Status -ne "Running") {
            throw "Der Hyper-V-Verwaltungsdienst (vmms) läuft nicht. Ist Hyper-V aktiviert?"
        }
        if ([IO.Path]::GetExtension($VhdxPath) -ne ".vhdx") {
            throw "Nur VHDX-Dateien werden unterstuetzt (die temporaere VM ist Generation 2). '$VhdxPath' bitte vorher mit Convert-VHD in eine .vhdx umwandeln."
        }
        # Speicherplatz dort pruefen, wo wirklich geschrieben wird: im
        # Ordner der VHDX (Kopie + Wachstum der dynamischen Disk durch die
        # Updates), nicht auf dem TEMP-Laufwerk.
        $sourceSizeBytes = (Get-Item -LiteralPath $VhdxPath).Length
        $requiredBytes = 15GB
        if ($usingCopy) { $requiredBytes += $sourceSizeBytes }
        $freeBytes = $null
        try {
            $driveRoot = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $VhdxPath).ProviderPath)
            $freeBytes = (New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace
        } catch {
            & $LogFunc "Freier Speicherplatz im VHDX-Ordner konnte nicht geprueft werden (z.B. Netzwerkpfad) - fahre fort." "Orange"
        }
        if ($null -ne $freeBytes -and $freeBytes -lt $requiredBytes) {
            throw "Zu wenig Speicherplatz im VHDX-Ordner: $([math]::Round($freeBytes/1GB,1)) GB frei, benoetigt ca. $([math]::Round($requiredBytes/1GB,1)) GB (Kopie + Puffer fuer Updates)."
        }
        if ($usingCopy) {
            $copyPath = Join-Path (Split-Path $VhdxPath -Parent) ("$([IO.Path]::GetFileNameWithoutExtension($VhdxPath))_autoupdate_$([guid]::NewGuid().ToString('N').Substring(0,6)).vhdx")
            $sourceSizeGB = [math]::Round($sourceSizeBytes / 1GB, 1)
            & $LogFunc "Sicherheitskopie wird erstellt ($sourceSizeGB GB - das kann bei großen Dateien mehrere Minuten dauern): $copyPath" "Gray"
            # Direktes Stream-Kopieren statt Start-Job: läuft im selben Thread,
            # ohne einen separaten Prozess zu starten (der auf manchen Systemen
            # durch Sicherheitssoftware/Richtlinien blockiert oder verzögert
            # werden kann). Meldet echten Fortschritt in Prozent, alle paar
            # hundert MB, und bleibt dabei jederzeit abbrechbar.
            $bufferSize = 4MB
            $buffer = New-Object byte[] $bufferSize
            $totalRead = 0L
            $lastLoggedPercent = -1
            $sourceStream = $null
            $destStream = $null
            try {
                $sourceStream = [System.IO.File]::Open($VhdxPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $destStream = [System.IO.File]::Open($copyPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
                while ($true) {
                    if (& $ShouldCancel) {
                        throw "ABGEBROCHEN_VOM_NUTZER"
                    }
                    $bytesRead = $sourceStream.Read($buffer, 0, $bufferSize)
                    if ($bytesRead -eq 0) { break }
                    $destStream.Write($buffer, 0, $bytesRead)
                    $totalRead += $bytesRead
                    if ($sourceSizeBytes -gt 0) {
                        $percent = [math]::Floor(($totalRead / $sourceSizeBytes) * 100)
                        if ($percent -ge ($lastLoggedPercent + 5)) {
                            $currentGB = [math]::Round($totalRead / 1GB, 1)
                            & $LogFunc "Kopiere... $percent% ($currentGB von $sourceSizeGB GB)" "Gray"
                            $lastLoggedPercent = $percent
                        }
                    }
                }
            } catch {
                if ($sourceStream) { $sourceStream.Dispose() }
                if ($destStream) { $destStream.Dispose() }
                if (Test-Path -LiteralPath $copyPath) { Remove-Item -LiteralPath $copyPath -Force -ErrorAction SilentlyContinue }
                if ($_.Exception.Message -eq "ABGEBROCHEN_VOM_NUTZER") { throw "ABGEBROCHEN_VOM_NUTZER" }
                throw "Kopieren der VHDX ist fehlgeschlagen: $($_.Exception.Message)"
            } finally {
                if ($sourceStream) { $sourceStream.Dispose() }
                if ($destStream) { $destStream.Dispose() }
            }
            if (-not (Test-Path -LiteralPath $copyPath)) {
                throw "Kopieren der VHDX ist fehlgeschlagen (Zieldatei fehlt nach Abschluss)."
            }
            $workingVhdxPath = $copyPath
            & $LogFunc "Kopie erstellt (100%, $sourceSizeGB GB)." "Lime"
        } else {
            & $LogFunc "Sicherheitskopie deaktiviert - arbeite DIREKT an der Original-Datei." "Orange"
        }
        CheckCancel
        # -------------------------------------------------------------
        & $PhaseFunc "OOBE-Automatisierung vorbereiten" 2 $totalPhases
        & $LogFunc "=== Bereite automatisches Ueberspringen von OOBE vor ===" "Cyan"
        & $LogFunc "(Ohne diesen Schritt wuerde die VM beim ersten Boot an der Sprachauswahl haengen bleiben und auf manuelle Eingabe warten.)" "Gray"
        $unattendMounted = $false
        $partitionStyle = $null
        try {
            Import-Module Storage -ErrorAction SilentlyContinue
            Mount-VHD -Path $workingVhdxPath -ErrorAction Stop | Out-Null
            $unattendMounted = $true

            $diskNum = $null
            $diskNumWaited = 0
            while ($diskNumWaited -lt 10 -and -not $diskNum) {
                Start-Sleep -Seconds 1
                $diskNumWaited++
                $diskNum = (Get-VHD -Path $workingVhdxPath -ErrorAction SilentlyContinue).DiskNumber
            }
            if ($null -eq $diskNum) { throw "Konnte DiskNumber der gemounteten VHDX nicht ermitteln (nach ${diskNumWaited}s)." }
            $partitionStyle = [string](Get-Disk -Number $diskNum -ErrorAction SilentlyContinue).PartitionStyle

            # Statt einer einzelnen fixen Wartezeit: mehrere Versuche ueber
            # bis zu ~20 Sekunden. Windows braucht nach dem Mounten manchmal
            # laenger, um Partitionen vollstaendig zu enumerieren - besonders
            # bei langsameren Datentraegern oder wenn der Host unter Last
            # steht. Ein einzelner Versuch nach nur 2 Sekunden ist zu knapp
            # bemessen und war vermutlich die Ursache eines gemeldeten
            # Fehlschlags.
            $winDriveLetter = $null
            $partitionAttempt = 0
            $lastPartitionsSeen = @()
            while ($partitionAttempt -lt 8 -and -not $winDriveLetter) {
                $partitionAttempt++
                Start-Sleep -Seconds 2
                $lastPartitionsSeen = @(Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue)
                $winDriveLetter = Find-WindowsDriveLetter -DiskNumber $diskNum
                if (-not $winDriveLetter -and $partitionAttempt -lt 8) {
                    & $LogFunc "Windows-Partition noch nicht gefunden, Versuch $partitionAttempt von 8 - warte und pruefe erneut..." "Gray"
                }
            }
            if (-not $winDriveLetter) {
                # Ausfuehrliche Diagnose: zeigt genau, was auf der Disk
                # gefunden wurde, damit sich ein Timing-Problem von einer
                # tatsaechlich fehlenden/unerwarteten Partitionsstruktur
                # unterscheiden laesst.
                & $LogFunc "--- Diagnose: gefundene Partitionen auf Disk $diskNum ---" "Orange"
                if ($lastPartitionsSeen.Count -eq 0) {
                    & $LogFunc "  Keine Partitionen gefunden (Get-Partition lieferte ein leeres Ergebnis)." "Orange"
                } else {
                    foreach ($p in $lastPartitionsSeen) {
                        $letterInfo = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "(kein Laufwerksbuchstabe)" }
                        & $LogFunc "  Partition $($p.PartitionNumber): Typ=$($p.Type), Groesse=$([Math]::Round($p.Size/1GB,1))GB, Laufwerk=$letterInfo" "Orange"
                    }
                }
                throw "Keine Windows-Partition in der Kopie gefunden - kann OOBE-Automatisierung nicht vorbereiten."
            }
            $pantherPath = "${winDriveLetter}:\Windows\Panther"
            if (-not (Test-Path $pantherPath)) {
                New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
            }
            # Vorhandene Antwortdateien sichern: Panther\Unattend\ hat bei der
            # Suche Vorrang vor Panther\ und wuerde die OOBE-Automatisierung
            # sonst aushebeln. Eine vorhandene Panther\unattend.xml wurde
            # frueher kommentarlos ueberschrieben. Die Sicherungen werden vor
            # dem finalen Sysprep wiederhergestellt - das Image bleibt so, wie
            # es vorher war.
            $bakSuffix = ".autoupdate-bak"
            $vorhandeneAntwortdateien = @(
                (Join-Path $pantherPath "unattend.xml"),
                (Join-Path $pantherPath "autounattend.xml"),
                (Join-Path $pantherPath "Unattend\unattend.xml"),
                (Join-Path $pantherPath "Unattend\autounattend.xml")
            )
            foreach ($af in $vorhandeneAntwortdateien) {
                if (-not (Test-Path -LiteralPath $af)) { continue }
                # Altlast einer AELTEREN Tool-Version erkennen: Die hat ihre
                # unattend.xml (Konto "AutoUpdate") im Image liegen lassen.
                # Windows ersetzt darin nach der Verarbeitung das Passwort durch
                # einen Platzhalter - beim naechsten Deployment wird das Konto
                # dann mit falschem Passwort angelegt und der Autologon bleibt
                # am Anmeldebildschirm haengen. So eine Datei wird GELOESCHT
                # statt gesichert, sonst wuerde sie vor Sysprep wieder
                # hergestellt und der Fehler bliebe im Image.
                $istAltlast = $false
                try { $istAltlast = [bool](Select-String -LiteralPath $af -SimpleMatch -Pattern "<Username>$vmUser</Username>" -Quiet) } catch { }
                if ($istAltlast) {
                    Remove-Item -LiteralPath $af -Force -ErrorAction Stop
                    & $LogFunc "Altlast einer frueheren Tool-Version entfernt (verursacht Haenger am Anmeldebildschirm): $af" "Orange"
                    continue
                }
                if (-not (Test-Path -LiteralPath ($af + $bakSuffix))) {
                    Move-Item -LiteralPath $af -Destination ($af + $bakSuffix) -Force -ErrorAction Stop
                    & $LogFunc "Vorhandene Antwortdatei gesichert (wird vor Sysprep wiederhergestellt): $af" "Gray"
                }
            }
            $unattendTargetPath = Join-Path $pantherPath "unattend.xml"
            $unattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>__VMPASS__</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Group>Administrators</Group>
                        <Name>AutoUpdate</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>__VMPASS__</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <Username>AutoUpdate</Username>
                <LogonCount>999</LogonCount>
            </AutoLogon>
            <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>de-DE</InputLocale>
            <SystemLocale>de-DE</SystemLocale>
            <UILanguage>de-DE</UILanguage>
            <UserLocale>de-DE</UserLocale>
        </component>
    </settings>
</unattend>
'@
            $unattendXml = $unattendXml.Replace("__VMPASS__", [System.Security.SecurityElement]::Escape($vmPlainPass))
            Set-Content -Path $unattendTargetPath -Value $unattendXml -Encoding UTF8 -Force
            & $LogFunc "unattend.xml abgelegt unter: $unattendTargetPath" "Lime"
            & $LogFunc "HINWEIS: Dies erstellt ein temporaeres lokales Konto 'AutoUpdate' NUR in der Arbeitskopie, um OOBE zu automatisieren. Konto, Antwortdatei und Autologon werden vor dem finalen Sysprep wieder entfernt." "Gray"

            & $LogFunc "Setze Sysprep-Rearm-Zaehler zurueck (falls Limit erreicht war)..." "Gray"
            try {
                Reset-SysprepRearmCounter -OfflineWindowsPath "${winDriveLetter}:\" -LogFunc $LogFunc | Out-Null
                & $LogFunc "Rearm-Zaehler-Reset abgeschlossen." "Lime"
            } catch {
                & $LogFunc "WARNUNG: Rearm-Zaehler-Reset fehlgeschlagen: $($_.Exception.Message) - fahre trotzdem fort." "Orange"
            }
        } catch {
            & $LogFunc "WARNUNG: OOBE-Automatisierung konnte nicht vorbereitet werden: $($_.Exception.Message)" "Orange"
            & $LogFunc "Falls die VHDX bereits syspreppt/im OOBE-Zustand ist, muss ggf. manuell durch die Sprachauswahl geklickt werden." "Orange"
        } finally {
            if ($unattendMounted) {
                try {
                    Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop
                } catch {
                    Start-Sleep -Seconds 3
                    try { Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop } catch {
                        & $LogFunc "WARNUNG: Konnte Arbeitskopie nach OOBE-Vorbereitung nicht sauber aushaengen. Fahre trotzdem fort." "Orange"
                    }
                }
            }
        }
        if ($partitionStyle -eq "MBR") {
            throw "Die VHDX hat eine MBR-Partitionstabelle (BIOS/Generation 1). Die temporaere VM ist Generation 2 (UEFI) und kann dieses Abbild nicht booten."
        }
        CheckCancel
        # -------------------------------------------------------------
        & $PhaseFunc "Temporäre VM erstellen" 3 $totalPhases
        & $LogFunc "=== Erstelle temporäre VM '$VMName' ===" "Cyan"
        $vmSwitch = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" } | Select-Object -First 1
        if (-not $vmSwitch) { $vmSwitch = Get-VMSwitch | Select-Object -First 1 }
        if (-not $vmSwitch) { throw "Kein virtueller Switch gefunden. Siehe Selbsttest für den Einrichtungsbefehl." }
        & $LogFunc "Nutze virtuellen Switch: $($vmSwitch.Name)" "Gray"
        New-VM -Name $VMName -MemoryStartupBytes ($MemoryGB * 1GB) -VHDPath $workingVhdxPath -Generation 2 -SwitchName $vmSwitch.Name -ErrorAction Stop | Out-Null
        $vmCreated = $true
        # Bewusst 10 vCPUs, aber nie mehr als der Host tatsaechlich hat -
        # Hyper-V lehnt eine VM mit mehr vCPUs als logischen Prozessoren ab.
        $vmCpuCount = [Math]::Min(10, [Environment]::ProcessorCount)
        Set-VMProcessor -VMName $VMName -Count $vmCpuCount
        & $LogFunc "Virtuelle Prozessoren: $vmCpuCount (Host hat $([Environment]::ProcessorCount))" "Gray"
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction SilentlyContinue
        Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -ErrorAction SilentlyContinue
        & $LogFunc "VM erstellt (Generation 2, $MemoryGB GB RAM)." "Lime"
        CheckCancel
        # -------------------------------------------------------------
        & $PhaseFunc "VM starten" 4 $totalPhases
        & $LogFunc "=== Starte VM ===" "Cyan"
        Start-VM -Name $VMName -ErrorAction Stop
        & $LogFunc "VM gestartet - warte auf Windows-Bereitschaft (PowerShell Direct)..." "Gray"
        $maxWaitSeconds = 600
        $waited = 0
        $session = $null
        $lastConnectError = $null
        while ($waited -lt $maxWaitSeconds) {
            CheckCancel
            try {
                $session = New-PSSession -VMName $VMName -Credential $vmCred -ErrorAction Stop
                break
            } catch {
                $lastConnectError = $_.Exception.Message
                Start-Sleep -Seconds 5
                $waited += 5
                if ($waited % 60 -eq 0) { & $LogFunc "Warte weiter auf Windows-Start... ($waited s) - letzter Fehler: $lastConnectError" "Gray" }
            }
        }
        if (-not $session) {
            throw "Konnte nach $maxWaitSeconds Sekunden keine PowerShell-Direct-Verbindung herstellen (letzter Fehler: $lastConnectError). Läuft die VM evtl. im OOBE-Setup fest, oder stimmen die Zugangsdaten fuer den Autologon-Account nicht?"
        }
        & $LogFunc "Verbindung zur VM hergestellt (nach $waited s)." "Lime"
        CheckCancel
        # -------------------------------------------------------------
        & $LogFunc "=== Pruefe Internetzugang der VM (Switch '$($vmSwitch.Name)') ===" "Cyan"
        if (Test-VMInternetAccess -Session $session) {
            & $LogFunc "Internetzugang bestaetigt." "Lime"
        } else {
            & $LogFunc "Kein Internetzugang ueber Switch '$($vmSwitch.Name)' - versuche automatisch andere verfuegbare Switches..." "Orange"
            $candidateSwitches = Get-VMSwitch | Where-Object { $_.Name -ne $vmSwitch.Name }
            $fixed = $false
            foreach ($altSwitch in $candidateSwitches) {
                CheckCancel
                & $LogFunc "Teste Switch: $($altSwitch.Name)..." "Gray"
                try {
                    Connect-VMNetworkAdapter -VMName $VMName -SwitchName $altSwitch.Name -ErrorAction Stop
                } catch {
                    & $LogFunc "Konnte VM nicht mit Switch '$($altSwitch.Name)' verbinden: $($_.Exception.Message)" "Orange"
                    continue
                }
                # PowerShell Direct laeuft ueber VMBus, nicht ueber das
                # virtuelle Netzwerk - die Sitzung bleibt beim Switch-
                # wechsel bestehen, aber die VM braucht kurz eine neue IP.
                Start-Sleep -Seconds 8
                try { Invoke-Command -Session $session -ScriptBlock { ipconfig /renew | Out-Null } -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 5
                if (Test-VMInternetAccess -Session $session -Quiet) {
                    & $LogFunc "Internetzugang ueber Switch '$($altSwitch.Name)' erfolgreich - VM bleibt auf diesem Switch." "Lime"
                    $vmSwitch = $altSwitch
                    $fixed = $true
                    break
                }
            }
            if (-not $fixed) {
                $triedNames = @($vmSwitch.Name) + @($candidateSwitches | ForEach-Object { $_.Name })
                throw "Die temporaere VM hat auf KEINEM verfuegbaren virtuellen Switch Internetzugang (probiert: $($triedNames -join ', ')). Bitte einen virtuellen Switch mit echtem Internetzugang einrichten (siehe Selbsttest-Hinweis zu New-VMSwitch)."
            }
        }
        CheckCancel
        # -------------------------------------------------------------
        & $PhaseFunc "Windows Update vorbereiten" 5 $totalPhases
        & $LogFunc "=== Bereite Windows Update in der VM vor ===" "Cyan"
        & $LogFunc "(Nutzt die in Windows fest eingebaute Windows-Update-COM-API - es wird KEIN Modul aus dem Internet nachgeladen.)" "Gray"
        $wuHelperScript = @'
param([ValidateSet("search","install")][string]$Mode = "search")
$resultPath = "C:\Windows\Temp\autoupdate_wu_result.json"
$statusPath = "C:\Windows\Temp\autoupdate_wu_status.txt"
function Write-Status {
    param([string]$Text)
    try { "$((Get-Date).ToString('HH:mm:ss'))|$Text" | Set-Content -Path $statusPath -Encoding UTF8 -Force } catch { }
}
$out = @{}
$out['Mode'] = $Mode
$out['Success'] = $false
$out['UpdateCount'] = 0
$out['RebootRequired'] = $false
$out['Installed'] = 0
$out['Failed'] = 0
$out['ErrorText'] = $null
$out['Titles'] = @()
$out['Problems'] = @()
try {
    Write-Status "Verbinde mit dem Windows-Update-Dienst..."
    $wuSession = New-Object -ComObject Microsoft.Update.Session
    $searcher = $wuSession.CreateUpdateSearcher()
    # Microsoft Update (statt nur Windows Update) registrieren, damit auch
    # Treiber- und Office-Updates gefunden werden. Schlaegt das fehl, wird
    # still auf reines Windows Update zurueckgefallen.
    #
    # WICHTIG: Diese Funktion laeuft mehrfach pro Runde (Suche + Installation)
    # ueber mehrere Update-Runden hinweg. AddService2 registriert den Dienst
    # dauerhaft fuer die gesamte Windows-Instanz - ein erneuter Registrierungs-
    # versuch, obwohl der Dienst schon registriert ist, erzeugt "The requested
    # access path is already in use"-Fehler im Error-Stream (harmlos, aber
    # unnoetig). Daher wird zuerst geprueft, ob der Dienst bereits registriert
    # ist, bevor ueberhaupt versucht wird, ihn erneut hinzuzufuegen.
    try {
        $muServiceId = "7971f918-a847-4430-9279-4a52d1efe18d"
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $bereitsRegistriert = $false
        try {
            foreach ($dienst in $sm.Services) {
                if ($dienst.ServiceID -eq $muServiceId) { $bereitsRegistriert = $true; break }
            }
        } catch { }
        if (-not $bereitsRegistriert) {
            $null = $sm.AddService2($muServiceId, 7, "")
        }
        $searcher.ServerSelection = 3
        $searcher.ServiceID = $muServiceId
    } catch { }
    Write-Status "Suche nach verfuegbaren Updates (kann einige Minuten dauern)..."
    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $updates = @()
    for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) { $updates += $searchResult.Updates.Item($i) }
    $total = $updates.Count
    $out['UpdateCount'] = $total
    $out['Titles'] = @($updates | ForEach-Object { $_.Title })
    Write-Status "Suche abgeschlossen: $total Update(s) gefunden."
    if ($Mode -eq "install" -and $total -gt 0) {
        # Einzeln herunterladen und installieren - dadurch kann pro Update
        # ein Fortschritt gemeldet werden. Ein Sammel-Download waere zwar
        # minimal schneller, wuerde aber minutenlang gar nichts melden.
        $problems = @()
        $downloadErrors = @{}
        $idx = 0
        foreach ($u in $updates) {
            $idx = $idx + 1
            $pct = [Math]::Round(($idx / $total) * 100)
            $sizeInfo = ""
            try {
                if ($u.MaxDownloadSize -gt 0) {
                    $sizeMB = [Math]::Round($u.MaxDownloadSize / 1MB, 1)
                    $sizeInfo = " ($sizeMB MB)"
                }
            } catch {}
            Write-Status "[$pct%] Lade herunter ($idx/$total): $($u.Title)$sizeInfo"
            try { if (-not $u.EulaAccepted) { $null = $u.AcceptEula() } } catch { }
            try {
                $single = New-Object -ComObject Microsoft.Update.UpdateColl
                $null = $single.Add($u)
                $dl = $wuSession.CreateUpdateDownloader()
                $dl.Updates = $single
                $null = $dl.Download()
            } catch {
                # Fehler NICHT verschlucken - der Grund wird unten gemeldet.
                $downloadErrors[$idx] = $_.Exception.Message
            }
        }
        Write-Status "[100%] Download-Phase abgeschlossen ($total von $total Update(s) verarbeitet)."
        $okCount = 0
        $failCount = 0
        $rebootNeeded = $false
        $idx = 0
        foreach ($u in $updates) {
            $idx = $idx + 1
            $pct = [Math]::Round(($idx / $total) * 100)
            if (-not $u.IsDownloaded) {
                # Frueher wurde hier kommentarlos uebersprungen - im
                # Protokoll fehlte dann einfach eine Nummer. Jetzt wird
                # Grund und Titel sichtbar gemacht.
                $reason = "nicht heruntergeladen"
                if ($downloadErrors.ContainsKey($idx)) {
                    $reason = "Download fehlgeschlagen: " + $downloadErrors[$idx]
                } else {
                    $alreadyIn = $false
                    try { $alreadyIn = [bool]$u.IsInstalled } catch { }
                    if ($alreadyIn) { $reason = "war zwischenzeitlich bereits installiert" }
                }
                Write-Status "[$pct%] Ueberspringe ($idx/$total): $($u.Title) - $reason"
                $problems += "$($u.Title) -> uebersprungen ($reason)"
                $failCount = $failCount + 1
                continue
            }
            Write-Status "[$pct%] Installiere ($idx/$total): $($u.Title)"
            try {
                $single = New-Object -ComObject Microsoft.Update.UpdateColl
                $null = $single.Add($u)
                $inst = $wuSession.CreateUpdateInstaller()
                $inst.Updates = $single
                $ir = $inst.Install()
                $rc = $ir.ResultCode
                if ($rc -eq 2 -or $rc -eq 3) {
                    $okCount = $okCount + 1
                } else {
                    $failCount = $failCount + 1
                    $problems += "$($u.Title) -> Installation meldete Ergebniscode $rc"
                }
                if ($ir.RebootRequired) { $rebootNeeded = $true }
            } catch {
                $failCount = $failCount + 1
                $problems += "$($u.Title) -> Installationsfehler: $($_.Exception.Message)"
            }
        }
        $out['Installed'] = $okCount
        $out['Failed'] = $failCount
        $out['RebootRequired'] = $rebootNeeded
        $out['Problems'] = $problems
        Write-Status "Installation abgeschlossen: $okCount erfolgreich, $failCount fehlgeschlagen."
    }
    $out['Success'] = $true
} catch {
    $out['ErrorText'] = $_.Exception.Message
    Write-Status "FEHLER: $($_.Exception.Message)"
}
($out | ConvertTo-Json -Depth 3) | Set-Content -Path $resultPath -Encoding UTF8 -Force
'@
        try {
            Invoke-Command -Session $session -ScriptBlock {
                param($content)
                $helperPath = "C:\Windows\Temp\autoupdate_wu_helper.ps1"
                Set-Content -Path $helperPath -Value $content -Encoding UTF8 -Force
                if (-not (Test-Path $helperPath)) { throw "Helfer-Skript konnte nicht geschrieben werden." }
                # Windows-Update-Dienst muss laufen, sonst schlaegt die
                # COM-Suche mit einem wenig aussagekraeftigen Fehler fehl.
                try { Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue } catch { }
                try { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } catch { }
                # Verhindert, dass Windows Update mitten in der Installation
                # selbstaendig neu startet und dabei unsere geplante Aufgabe
                # abwuergt - der Neustart wird stattdessen von diesem Skript
                # kontrolliert ausgeloest.
                try {
                    $auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
                    $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                    # Urspruengliche Werte sichern - sie werden vor Sysprep
                    # exakt wiederhergestellt, damit die Richtlinien nicht
                    # dauerhaft im Golden Image landen.
                    $auBackupFile = "C:\Windows\Temp\autoupdate_au_backup.json"
                    if (-not (Test-Path $auBackupFile)) {
                        $auBackup = @{ WUExisted = [bool](Test-Path $wuKey); AUExisted = [bool](Test-Path $auKey); AUValueCount = 0 }
                        if (Test-Path $auKey) { $auBackup["AUValueCount"] = [int](Get-Item -Path $auKey).ValueCount }
                        foreach ($auName in @("NoAutoRebootWithLoggedOnUsers", "AUOptions", "NoAutoUpdate")) {
                            $auBackup[$auName] = $null
                            if (Test-Path $auKey) { $auBackup[$auName] = (Get-ItemProperty -Path $auKey -Name $auName -ErrorAction SilentlyContinue).$auName }
                        }
                        ($auBackup | ConvertTo-Json) | Set-Content -Path $auBackupFile -Encoding UTF8 -Force
                    }
                    if (-not (Test-Path $auKey)) { New-Item -Path $auKey -Force | Out-Null }
                    New-ItemProperty -Path $auKey -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -PropertyType DWord -Force | Out-Null
                    New-ItemProperty -Path $auKey -Name "AUOptions" -Value 3 -PropertyType DWord -Force | Out-Null
                    # NoAutoRebootWithLoggedOnUsers greift NUR, wenn jemand
                    # angemeldet ist - die VM steht aber meist am Anmelde-
                    # bildschirm, und Windows startete dann einfach selbst neu.
                    # NoAutoUpdate=1 stoppt Windows' eigene Update-Automatik;
                    # die Such-/Installations-API dieses Tools funktioniert
                    # davon unabhaengig weiter.
                    New-ItemProperty -Path $auKey -Name "NoAutoUpdate" -Value 1 -PropertyType DWord -Force | Out-Null
                } catch { }
            } -ArgumentList $wuHelperScript -ErrorAction Stop
        } catch {
            throw "Konnte den Windows-Update-Helfer nicht in der VM einrichten: $($_.Exception.Message)"
        }
        & $LogFunc "Windows-Update-Helfer in der VM eingerichtet (keine Internet-Downloads noetig)." "Lime"
        # -------------------------------------------------------------
        & $PhaseFunc "Updates installieren" 6 $totalPhases
        $consecutiveEmptySearches = 0
        $requiredEmptySearches = 2
        $totalInstalled = 0
        $updatesDone = $false
        $installRound = 0
        $noProgressRounds = 0
        # Bestaetigungs-Suchlaeufe zaehlen NICHT als Installationsrunde -
        # frueher verbrauchten sie Runden, sodass bei 3 Runden praktisch
        # nie "bestaetigt aktuell" erreicht wurde. Die Obergrenze der
        # Suchlaeufe schuetzt vor Endlosschleifen.
        $maxSearchPasses = $MaxUpdateRounds + $requiredEmptySearches + 2
        for ($searchPass = 1; $searchPass -le $maxSearchPasses; $searchPass++) {
            CheckCancel
            & $LogFunc "=== Update-Suche $searchPass (Installationsrunden bisher: $installRound von max. $MaxUpdateRounds) ===" "Cyan"
            & $PhaseFunc "Updates installieren (Runde $installRound/$MaxUpdateRounds)" 6 $totalPhases
            if ($session.State -ne "Opened") {
                & $LogFunc "Sitzung nicht mehr offen, baue neu auf..." "Gray"
                $session = $null
                $waited = 0
                $lastConnectError = $null
                while ($waited -lt $maxWaitSeconds -and -not $session) {
                    CheckCancel
                    try { $session = New-PSSession -VMName $VMName -Credential $vmCred -ErrorAction Stop }
                    catch { $lastConnectError = $_.Exception.Message; Start-Sleep -Seconds 5; $waited += 5 }
                }
                if (-not $session) { throw "Konnte Sitzung nach Neustart nicht wiederherstellen (letzter Fehler: $lastConnectError)." }
            }
            $searchOutcome = Invoke-WUJobInVM -SessionRef ([ref]$session) -Mode "search" -TimeoutSeconds 2400
            if ($searchOutcome.Interrupted) {
                throw "Die Update-Suche in der VM wurde unterbrochen - die geplante Aufgabe endete ohne Ergebnis. Bitte pruefen, ob die VM waehrenddessen neu gestartet wurde."
            }
            if (-not $searchOutcome.Success) {
                throw "Die Update-Suche in der VM ist fehlgeschlagen: $($searchOutcome.ErrorText)"
            }
            $pending = [int]$searchOutcome.UpdateCount
            & $LogFunc "Gefundene ausstehende Updates: $pending" "Gray"

            if ($pending -eq 0) {
                $consecutiveEmptySearches++
                if ($consecutiveEmptySearches -ge $requiredEmptySearches) {
                    & $LogFunc "Auch der Bestaetigungsdurchlauf hat nichts mehr gefunden - Windows ist wirklich aktuell." "Lime"
                    $updatesDone = $true
                    break
                }
                # Eine einzelne leere Suche reicht NICHT: Windows gibt
                # Folge-Updates oft erst nach einem Neustart frei.
                & $LogFunc "Aktuell nichts gefunden - Windows gibt Folge-Updates aber oft erst nach einem Neustart frei." "Gray"
                & $LogFunc "Starte zur Sicherheit neu und pruefe noch einmal (Bestaetigungsdurchlauf)." "Gray"
                Restart-VMAndReconnect -SessionRef ([ref]$session)
                Wait-VMUpdateStackIdle -SessionRef ([ref]$session) -MaxWaitSeconds 90
                continue
            }

            $consecutiveEmptySearches = 0
            if ($installRound -ge $MaxUpdateRounds) {
                & $LogFunc "Maximale Anzahl an Installationsrunden ($MaxUpdateRounds) erreicht - $pending Update(s) bleiben offen." "Orange"
                break
            }
            if ($noProgressRounds -ge 2) {
                # Ein dauerhaft scheiterndes Update wuerde sonst jede Runde
                # erneut versucht und die Schleife nie "leer" werden.
                & $LogFunc "Zwei Runden in Folge wurde nichts erfolgreich installiert - diese $pending Update(s) scheitern offenbar dauerhaft und werden uebersprungen:" "Orange"
                foreach ($t in @($searchOutcome.Titles | Select-Object -First 10)) { & $LogFunc "    - $t" "Orange" }
                break
            }
            $installRound++
            & $PhaseFunc "Updates installieren (Runde $installRound/$MaxUpdateRounds)" 6 $totalPhases
            foreach ($t in @($searchOutcome.Titles | Select-Object -First 10)) {
                & $LogFunc "    - $t" "DarkGray"
            }
            if ($pending -gt 10) { & $LogFunc "    ... und $($pending - 10) weitere" "DarkGray" }
            & $LogFunc "Installationsrunde $installRound von ${MaxUpdateRounds}: installiere $pending Update(s) - das kann mehrere Minuten dauern..." "Gray"
            $installOutcome = Invoke-WUJobInVM -SessionRef ([ref]$session) -Mode "install" -TimeoutSeconds 7200
            if ($installOutcome.Interrupted) {
                & $LogFunc "Die Installation wurde in der VM unterbrochen (vermutlich hat Windows selbst neu gestartet). Setze nach dem Neustart fort." "Orange"
            } elseif (-not $installOutcome.Success) {
                throw "Die Update-Installation in der VM ist fehlgeschlagen: $($installOutcome.ErrorText)"
            } else {
                & $LogFunc "Installiert: $($installOutcome.Installed), fehlgeschlagen/uebersprungen: $($installOutcome.Failed)." "Gray"
                foreach ($p in @($installOutcome.Problems)) {
                    if ($p) { & $LogFunc "    ! $p" "Orange" }
                }
                $totalInstalled += [int]$installOutcome.Installed
                if ([int]$installOutcome.Installed -eq 0) { $noProgressRounds++ } else { $noProgressRounds = 0 }
            }
            # Nach einer Installation IMMER neu starten - erst danach gibt
            # der Update-Stack die naechste Welle zuverlaessig frei.
            Restart-VMAndReconnect -SessionRef ([ref]$session)
            Wait-VMUpdateStackIdle -SessionRef ([ref]$session) -MaxWaitSeconds 90
        }
        if (-not $updatesDone) {
            & $LogFunc "Windows konnte nicht als vollstaendig aktuell bestaetigt werden - es koennten noch Updates offen sein. Bei Bedarf die Rundenzahl erhoehen und erneut laufen lassen." "Orange"
        }
        & $LogFunc "Insgesamt installierte Updates: $totalInstalled" "Lime"
        CheckCancel
        # -------------------------------------------------------------
        & $PhaseFunc "Sysprep ausführen" 7 $totalPhases
        & $LogFunc "=== Führe Sysprep aus ===" "Cyan"
        if ($session.State -ne "Opened") {
            $session = $null
            $reconnectWaited = 0
            $lastConnectError = $null
            while ($reconnectWaited -lt 300 -and -not $session) {
                CheckCancel
                try { $session = New-PSSession -VMName $VMName -Credential $vmCred -ErrorAction Stop }
                catch { $lastConnectError = $_.Exception.Message; Start-Sleep -Seconds 5; $reconnectWaited += 5 }
            }
            if (-not $session) { throw "Konnte vor Sysprep keine Sitzung zur VM aufbauen (letzter Fehler: $lastConnectError)." }
        }
        # Hier ist die Wartezeit im Gegensatz zu den Zwischenrunden wirklich
        # notwendig: Sysprep bricht ab, wenn im Hintergrund noch eine
        # Servicing-Operation laeuft ("Sysprep konnte nicht ausgefuehrt
        # werden"). Deshalb an dieser einen Stelle ein grosszuegiges Limit.
        Wait-VMUpdateStackIdle -SessionRef ([ref]$session) -MaxWaitSeconds 900

        & $LogFunc "Entferne bekannte Sysprep-Blocker (Copilot/Widgets u.a.)..." "Gray"
        & $LogFunc "(Diese Apps werden oft durch Windows Update nur fuer den aktuellen Nutzer installiert und lassen Sysprep dann mit einem BCD-Firmware-Fehler scheitern.)" "Gray"
        try {
            Invoke-Command -Session $session -ScriptBlock {
                $problematicPatterns = @("*copilot*", "*WidgetsPlatformRuntime*", "*Windows.Ai.Copilot*", "*MicrosoftWindows.Client.WebExperience*")
                foreach ($pattern in $problematicPatterns) {
                    try {
                        Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                    } catch {}
                }
            } -ErrorAction Stop
            & $LogFunc "Bereinigung abgeschlossen." "Gray"
        } catch {
            & $LogFunc "WARNUNG: Bereinigung teilweise fehlgeschlagen: $($_.Exception.Message) - fahre trotzdem fort." "Orange"
        }

        & $LogFunc "=== Entferne das temporaere Konto '$vmUser' ===" "Cyan"
        & $LogFunc "(Ein angemeldetes Konto kann sich nicht selbst loeschen - daher wird kurz auf das eingebaute Administrator-Konto gewechselt.)" "Gray"
        $cleanupSession = $null
        $removedAccountNames = @()
        $removedProfileFolders = @()
        $adminName = $null
        $wasAlreadyEnabledLocal = $null
        try {
            $adminInfo = Invoke-Command -Session $session -ScriptBlock {
                # Ueber die SID (RID 500) statt ueber den Namen - das Konto
                # kann umbenannt sein.
                $a = Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-21-*-500" } | Select-Object -First 1
                if (-not $a) { throw "Eingebautes Administrator-Konto (RID 500) nicht gefunden." }
                New-Object PSObject -Property @{ Name = [string]$a.Name; Enabled = [bool]$a.Enabled }
            } -ErrorAction Stop
            $adminName = [string]$adminInfo.Name
            $wasAlreadyEnabledLocal = [bool]$adminInfo.Enabled

            if ($wasAlreadyEnabledLocal) {
                # Frueher: ein zufaelliges Passwort, das nirgends festgehalten
                # wurde - danach kannte niemand mehr das Admin-Passwort des
                # Images. Jetzt: das bekannte Standard-Passwort des Tools.
                $adminPlainPass = $vmPlainPass
                & $LogFunc "HINWEIS: Das eingebaute Konto '$adminName' war im Image aktiv. Sein Passwort wird auf das Standard-Passwort des Tools gesetzt - bitte nach dem Deployment aendern." "Orange"
            } else {
                # Das Konto wird vor Sysprep wieder deaktiviert - ein
                # einmaliges Zufallspasswort genuegt.
                $adminPlainPass = "Au!" + [guid]::NewGuid().ToString("N").Substring(0, 12) + "x9"
            }
            $adminSecurePass = ConvertTo-SecureString $adminPlainPass -AsPlainText -Force
            Invoke-Command -Session $session -ScriptBlock {
                param($Name, $SecurePass)
                Set-LocalUser -Name $Name -Password $SecurePass -ErrorAction Stop
                Enable-LocalUser -Name $Name -ErrorAction Stop
            } -ArgumentList $adminName, $adminSecurePass -ErrorAction Stop

            $adminCred = New-Object System.Management.Automation.PSCredential(".\$adminName", $adminSecurePass)
            $cleanupWaited = 0
            while ($cleanupWaited -lt 60 -and -not $cleanupSession) {
                try { $cleanupSession = New-PSSession -VMName $VMName -Credential $adminCred -ErrorAction Stop }
                catch { Start-Sleep -Seconds 5; $cleanupWaited += 5 }
            }
            if (-not $cleanupSession) { throw "Konnte keine Administrator-Sitzung aufbauen." }

            if ($RemoveAllLocalUsers) {
                & $LogFunc "Modus 'Sauberes Image': ALLE nicht eingebauten lokalen Benutzer werden samt Profil entfernt." "Orange"
            }
            $entfernung = Invoke-Command -Session $cleanupSession -ScriptBlock {
                param($ToolAccounts, $Protected, $RemoveAll)
                # Eingebaute Konten ueber die RID schuetzen - die Namen sind
                # sprachabhaengig ("Guest" heisst auf Deutsch "Gast").
                # 500 Administrator, 501 Gast, 503 DefaultAccount,
                # 504 WDAGUtilityAccount.
                $builtinRids = @(500, 501, 503, 504)
                $kandidaten = @()
                foreach ($u in @(Get-LocalUser)) {
                    $rid = [int]($u.SID.Value.Split('-')[-1])
                    if ($builtinRids -contains $rid) { continue }
                    if (@($Protected) -contains $u.Name) { continue }
                    if ($RemoveAll -or (@($ToolAccounts) -contains $u.Name)) { $kandidaten += $u }
                }
                $entfernt = @()
                $ordner = @()
                $fehler = @()
                foreach ($u in $kandidaten) {
                    $name = $u.Name
                    $sid = $u.SID.Value
                    # Profilordner VOR dem Loeschen merken - er heisst nicht
                    # immer wie das Konto (z.B. "benutzer.PC01").
                    $profil = $null
                    try { $profil = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object { $_.SID -eq $sid } } catch { }
                    if ($profil -and $profil.LocalPath) { $ordner += (Split-Path $profil.LocalPath -Leaf) }
                    try {
                        Remove-LocalUser -SID $u.SID -ErrorAction Stop
                        $entfernt += $name
                    } catch {
                        $fehler += "$name ($($_.Exception.Message))"
                        continue
                    }
                    # Profil entfernen (Ordner + ProfileList). Ist es noch
                    # geladen (Autologon-Desktop), klappt das erst offline
                    # nach dem Herunterfahren - dort wird erneut geprueft.
                    if ($profil) { try { $profil | Remove-CimInstance -ErrorAction Stop } catch { } }
                }
                # Sauberes Image: auch Profile OHNE zugehoeriges Konto
                # (verwaist, von frueher geloeschten Benutzern) entfernen -
                # und zwar VOR Sysprep, weil liegengebliebene Profile mit
                # App-Paketen Sysprep sonst scheitern lassen koennen.
                # Geladene Profile (z.B. die laufende Admin-Sitzung) und
                # Systemprofile bleiben hier stehen; die Ordner werden nach
                # dem Herunterfahren offline entfernt.
                $verwaist = @()
                if ($RemoveAll) {
                    foreach ($p in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue)) {
                        if ($p.Special -or $p.Loaded) { continue }
                        if (-not $p.LocalPath -or $p.LocalPath -notmatch '\\Users\\[^\\]+$') { continue }
                        $leaf = Split-Path $p.LocalPath -Leaf
                        try {
                            $p | Remove-CimInstance -ErrorAction Stop
                            $verwaist += $leaf
                        } catch { }
                    }
                }
                New-Object PSObject -Property @{ Entfernt = $entfernt; Ordner = $ordner; Fehler = $fehler; Verwaist = $verwaist }
            } -ArgumentList @($toolAccounts), @($protectedLocalAccounts), [bool]$RemoveAllLocalUsers -ErrorAction Stop

            $removedAccountNames = @($entfernung.Entfernt | Where-Object { $_ })
            $removedProfileFolders = @($entfernung.Ordner | Where-Object { $_ })
            $fehlgeschlagen = @($entfernung.Fehler | Where-Object { $_ })
            $verwaisteProfile = @($entfernung.Verwaist | Where-Object { $_ })
            if ($verwaisteProfile.Count -gt 0) {
                & $LogFunc "Weitere (verwaiste) Profile entfernt: $($verwaisteProfile -join ', ')" "Lime"
            }
            if ($removedAccountNames.Count -gt 0) {
                & $LogFunc "Entfernte Konten: $($removedAccountNames -join ', ')" "Lime"
            } else {
                & $LogFunc "Keine zu entfernenden Konten gefunden." "Gray"
            }
            foreach ($f in $fehlgeschlagen) {
                & $LogFunc "WARNUNG: Konto konnte nicht entfernt werden: $f" "Orange"
            }
            # Das Temp-Konto MUSS weg sein - sonst entsteht ein Image mit
            # Temp-Administrator.
            $tempNochDa = Invoke-Command -Session $cleanupSession -ScriptBlock {
                param($ToolAccounts)
                @($ToolAccounts | Where-Object { Get-LocalUser -Name $_ -ErrorAction SilentlyContinue }).Count -gt 0
            } -ArgumentList @($toolAccounts) -ErrorAction Stop
            if ($tempNochDa) { throw "Das temporaere Konto ist nach der Bereinigung noch vorhanden." }

            # Die alte Sitzung gehoert zum soeben geloeschten Konto - ab hier
            # wird ueber die Administrator-Sitzung weitergearbeitet.
            try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch {}
            $session = $cleanupSession
            $cleanupSession = $null
            & $LogFunc "Arbeite ab hier ueber die Administrator-Sitzung weiter." "Gray"
        } catch {
            $cleanupFehler = $_.Exception.Message
            # Administrator nur dann wieder deaktivieren, wenn er vorher
            # NACHWEISLICH deaktiviert war.
            if ($adminName -and $wasAlreadyEnabledLocal -eq $false) {
                try {
                    Invoke-Command -Session $session -ScriptBlock {
                        param($n)
                        Disable-LocalUser -Name $n -ErrorAction SilentlyContinue
                    } -ArgumentList $adminName -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }
            # Frueher lief Sysprep hier trotzdem weiter - Ergebnis waere ein
            # Golden Image MIT Temp-Administrator. Deshalb jetzt Abbruch.
            throw "Das temporaere Konto '$vmUser' konnte nicht entfernt werden ($cleanupFehler). Abbruch vor Sysprep, damit kein Image mit Temp-Administrator entsteht."
        } finally {
            if ($cleanupSession) {
                try { Remove-PSSession -Session $cleanupSession -ErrorAction SilentlyContinue } catch {}
            }
        }

        & $LogFunc "=== Entferne Rueckstaende des Update-Laufs aus dem Image ===" "Cyan"
        try {
            $restLog = Invoke-Command -Session $session -ScriptBlock {
                param($AdminName, $DisableAdmin, $ToolAccounts)
                $meldungen = @()
                $bakSuffix = ".autoupdate-bak"

                # 1) Temporaere Antwortdatei (mit Konto + Passwort) entfernen
                #    und vorher gesicherte Original-Antwortdateien zurueck.
                $panther = "$env:WINDIR\Panther"
                $unsere = Join-Path $panther "unattend.xml"
                if (Test-Path -LiteralPath $unsere) {
                    Remove-Item -LiteralPath $unsere -Force -ErrorAction Stop
                    $meldungen += "Temporaere Antwortdatei entfernt: $unsere"
                }
                foreach ($ordner in @($panther, (Join-Path $panther "Unattend"))) {
                    if (-not (Test-Path -LiteralPath $ordner)) { continue }
                    foreach ($bak in @(Get-ChildItem -LiteralPath $ordner -Filter "*$bakSuffix" -File -ErrorAction SilentlyContinue)) {
                        $ziel = $bak.FullName.Substring(0, $bak.FullName.Length - $bakSuffix.Length)
                        Move-Item -LiteralPath $bak.FullName -Destination $ziel -Force -ErrorAction Stop
                        $meldungen += "Urspruengliche Antwortdatei wiederhergestellt: $ziel"
                    }
                }

                # 2) Windows-Update-Richtlinien in den Ursprungszustand.
                $auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
                $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                $auBackupFile = "$env:WINDIR\Temp\autoupdate_au_backup.json"
                if (Test-Path -LiteralPath $auBackupFile) {
                    $b = Get-Content -LiteralPath $auBackupFile -Raw | ConvertFrom-Json
                    # Altlast einer aelteren Tool-Version: genau unsere beiden
                    # Werte (1 / 3) und sonst nichts im AU-Schluessel. Dann
                    # NICHT wiederherstellen, sondern entfernen. Leere
                    # Schluessel werden unten nur geloescht, wenn wirklich
                    # nichts anderes darin steht.
                    if ($b.NoAutoRebootWithLoggedOnUsers -eq 1 -and $b.AUOptions -eq 3 -and [int]$b.AUValueCount -eq 2) {
                        $b.NoAutoRebootWithLoggedOnUsers = $null
                        $b.AUOptions = $null
                        $b.AUExisted = $false
                        $b.WUExisted = $false
                        $meldungen += "Windows-Update-Richtlinien einer frueheren Tool-Version erkannt und entfernt."
                    }
                    foreach ($n in @("NoAutoRebootWithLoggedOnUsers", "AUOptions", "NoAutoUpdate")) {
                        if ($null -ne $b.$n) {
                            if (-not (Test-Path $auKey)) { New-Item -Path $auKey -Force | Out-Null }
                            Set-ItemProperty -Path $auKey -Name $n -Value ([int]$b.$n) -Type DWord -ErrorAction Stop
                        } elseif (Test-Path $auKey) {
                            Remove-ItemProperty -Path $auKey -Name $n -ErrorAction SilentlyContinue
                        }
                    }
                    if (-not $b.AUExisted -and (Test-Path $auKey)) {
                        $k = Get-Item -Path $auKey
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -Path $auKey -Force }
                    }
                    if (-not $b.WUExisted -and (Test-Path $wuKey)) {
                        $k = Get-Item -Path $wuKey
                        if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -Path $wuKey -Force }
                    }
                    $meldungen += "Windows-Update-Richtlinien auf den Ursprungszustand zurueckgesetzt."
                }

                # 3) Autologon des Temp-Kontos (von der unattend.xml gesetzt)
                $wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
                $du = (Get-ItemProperty -Path $wl -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
                if ($du -and (@($ToolAccounts) -contains $du)) {
                    Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value "0" -Type String -ErrorAction Stop
                    foreach ($n in @("DefaultUserName", "DefaultPassword", "AutoLogonCount")) {
                        Remove-ItemProperty -Path $wl -Name $n -ErrorAction SilentlyContinue
                    }
                    $meldungen += "Autologon des Temp-Kontos entfernt."
                }

                # 4) Update-Helfer und geplante Aufgabe
                $null = & schtasks.exe /Delete /TN "AutoUpdateWU" /F 2>&1
                Remove-Item -Path "$env:WINDIR\Temp\autoupdate_*" -Force -ErrorAction SilentlyContinue
                $meldungen += "Update-Helfer und geplante Aufgabe entfernt."

                # 5) Administrator wieder in den Ursprungszustand. Die
                #    laufende Sitzung bleibt dabei bestehen (Token ist bereits
                #    ausgestellt) - Sysprep laeuft also trotzdem.
                if ($DisableAdmin) {
                    Disable-LocalUser -Name $AdminName -ErrorAction Stop
                    $meldungen += "Eingebautes Konto '$AdminName' wieder deaktiviert (wie im Original)."
                }
                ,$meldungen
            } -ArgumentList $adminName, (-not $wasAlreadyEnabledLocal), @($toolAccounts) -ErrorAction Stop
            foreach ($m in @($restLog)) { & $LogFunc $m "Gray" }
        } catch {
            throw "Rueckstaende des Update-Laufs konnten nicht vollstaendig entfernt werden: $($_.Exception.Message). Abbruch vor Sysprep."
        }

        $sysprepSucceeded = $false
        $maxSysprepAttempts = 2
        # Grosszuegig: /generalize braucht nach vielen Updates oft 5-15 min.
        $sysprepTimeout = 2700
        for ($attempt = 1; $attempt -le $maxSysprepAttempts -and -not $sysprepSucceeded; $attempt++) {
            if ($attempt -gt 1) { & $LogFunc "=== Sysprep-Versuch $attempt von $maxSysprepAttempts (nach BCD-Reparatur) ===" "Cyan" }
            if ($session.State -ne "Opened") {
                throw "Die Sitzung zur VM ist nicht mehr offen - Sysprep kann nicht (erneut) gestartet werden."
            }
            Invoke-Command -Session $session -ScriptBlock {
                $sysprepExe = "$env:WINDIR\System32\Sysprep\sysprep.exe"
                if (-not (Test-Path $sysprepExe)) { throw "sysprep.exe nicht gefunden unter $sysprepExe" }
                if (Get-Process -Name sysprep -ErrorAction SilentlyContinue) { throw "Sysprep laeuft in der VM bereits." }
            } -ErrorAction Stop

            # OHNE -Wait starten: Sysprep faehrt die VM herunter und reisst
            # dabei die Sitzung ab. Mit -Wait warf Invoke-Command dann einen
            # Transportfehler und der Lauf galt trotz Erfolg als gescheitert.
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    Start-Process -FilePath "$env:WINDIR\System32\Sysprep\sysprep.exe" -ArgumentList "/generalize /oobe /shutdown /quiet"
                } -ErrorAction Stop
            } catch {
                & $LogFunc "Sitzung beim Start von Sysprep beendet (beim Herunterfahren normal): $($_.Exception.Message)" "DarkGray"
            }
            & $LogFunc "Sysprep gestartet, warte auf Herunterfahren (max. $sysprepTimeout s)..." "Gray"

            # Die VM faehrt bei Erfolg selbst herunter (/shutdown) - das ist
            # der zuverlaessigste Erfolgsindikator. Zusaetzlich wird geprueft,
            # ob sysprep.exe ueberhaupt noch laeuft: Ist es beendet und die
            # VM laeuft weiter, ist Sysprep gescheitert.
            $shutdownWaited = 0
            $sysprepGoneProbes = 0
            $lastProbeAt = 0
            $sysprepEndedWithoutShutdown = $false
            while ($shutdownWaited -lt $sysprepTimeout) {
                if ((Get-VM -Name $VMName).State -eq "Off") { break }
                CheckCancel
                Start-Sleep -Seconds 10
                $shutdownWaited += 10
                if ($shutdownWaited % 300 -eq 0) { & $LogFunc "    ...Sysprep laeuft noch ($shutdownWaited s)" "DarkGray" }
                if ($shutdownWaited -ge 60 -and ($shutdownWaited - $lastProbeAt) -ge 30 -and $session.State -eq "Opened") {
                    $lastProbeAt = $shutdownWaited
                    $stillRunning = $null
                    try {
                        $stillRunning = Invoke-Command -Session $session -ScriptBlock {
                            [bool](Get-Process -Name sysprep -ErrorAction SilentlyContinue)
                        } -ErrorAction Stop
                    } catch { $stillRunning = $null }
                    if ($stillRunning -eq $false) { $sysprepGoneProbes++ } else { $sysprepGoneProbes = 0 }
                    # 4 Proben x 30 s: genug Zeit, falls das Herunterfahren
                    # gerade erst anlaeuft.
                    if ($sysprepGoneProbes -ge 4 -and (Get-VM -Name $VMName).State -ne "Off") {
                        $sysprepEndedWithoutShutdown = $true
                        break
                    }
                }
            }

            if ((Get-VM -Name $VMName).State -eq "Off") {
                & $LogFunc "VM ist heruntergefahren - Sysprep war erfolgreich (nach $shutdownWaited s)." "Lime"
                $sysprepSucceeded = $true
                break
            }

            if ($sysprepEndedWithoutShutdown) {
                & $LogFunc "Sysprep hat sich beendet, ohne die VM herunterzufahren - Sysprep ist fehlgeschlagen." "Orange"
            } else {
                & $LogFunc "VM ist nach ${shutdownWaited}s noch nicht heruntergefahren - Sysprep haengt vermutlich." "Orange"
            }
            try {
                $setupErrContent = Invoke-Command -Session $session -ScriptBlock {
                    $logPath = "$env:WINDIR\System32\Sysprep\Panther\setuperr.log"
                    if (Test-Path $logPath) { Get-Content $logPath -Tail 15 } else { "setuperr.log nicht gefunden unter $logPath" }
                } -ErrorAction Stop
                & $LogFunc "--- Inhalt von setuperr.log (letzte 15 Zeilen) ---" "Red"
                foreach ($line in $setupErrContent) { & $LogFunc "  $line" "Red" }
            } catch {
                & $LogFunc "Konnte setuperr.log nicht auslesen: $($_.Exception.Message)" "Red"
            }

            if ($attempt -lt $maxSysprepAttempts) {
                if (-not $sysprepEndedWithoutShutdown) {
                    # Laeuft Sysprep evtl. noch, wuerde ein zweiter Start das
                    # Image beschaedigen - also KEIN zweiter Versuch.
                    & $LogFunc "Sysprep laeuft moeglicherweise noch - kein zweiter Versuch, um das Image nicht zu beschaedigen." "Orange"
                    break
                }
                # bootrec gibt es nur in WinRE und /fixmbr ist bei UEFI
                # sinnlos. bcdboot schreibt die Boot-Dateien und den BCD-
                # Speicher auf der EFI-Partition neu.
                & $LogFunc "Versuche Workaround: BCD neu schreiben (bcdboot)..." "Orange"
                try {
                    $bcd = Invoke-Command -Session $session -ScriptBlock {
                        $o = & bcdboot.exe "$env:WINDIR" /f UEFI 2>&1 | Out-String
                        New-Object PSObject -Property @{ Code = $LASTEXITCODE; Text = $o.Trim() }
                    } -ErrorAction Stop
                    if ($bcd.Code -eq 0) {
                        & $LogFunc "bcdboot erfolgreich: $($bcd.Text) - versuche Sysprep erneut." "Gray"
                    } else {
                        & $LogFunc "bcdboot meldete Fehlercode $($bcd.Code): $($bcd.Text) - versuche Sysprep trotzdem erneut." "Orange"
                    }
                } catch {
                    & $LogFunc "BCD-Reparatur fehlgeschlagen: $($_.Exception.Message) - versuche Sysprep trotzdem erneut." "Orange"
                }
                Start-Sleep -Seconds 5
            }
        }

        if (-not $sysprepSucceeded) {
            throw "Sysprep ist fehlgeschlagen (siehe setuperr.log oben). Die temporaere VM wird jetzt entfernt."
        }

        & $LogFunc "VM ist heruntergefahren." "Lime"

        & $LogFunc "=== Bereinige verbliebene Profilordner (offline) ===" "Cyan"
        & $LogFunc "(Jetzt gefahrlos moeglich, da niemand mehr angemeldet ist.)" "Gray"
        $cleanupMounted = $false
        try {
            Mount-VHD -Path $workingVhdxPath -ErrorAction Stop | Out-Null
            $cleanupMounted = $true
            Start-Sleep -Seconds 2

            $cleanupDiskNum = (Get-VHD -Path $workingVhdxPath).DiskNumber
            if ($null -eq $cleanupDiskNum) { throw "Konnte DiskNumber nicht ermitteln." }
            $cleanupDriveLetter = Find-WindowsDriveLetter -DiskNumber $cleanupDiskNum
            if (-not $cleanupDriveLetter) { throw "Keine Windows-Partition gefunden." }

            $usersRootPath = "${cleanupDriveLetter}:\Users"
            # Standard-Ordner unter \Users, die KEINE Benutzerprofile sind -
            # werden nie angefasst.
            $systemOrdner = @("Public", "Default", "Default User", "All Users")
            $offlineNamen = @(@($toolAccounts) + @($removedAccountNames) | Where-Object { $_ } | Select-Object -Unique)
            $foldersToClean = @()
            if (Test-Path -LiteralPath $usersRootPath) {
                $alleOrdner = @(Get-ChildItem -LiteralPath $usersRootPath -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { ($systemOrdner -notcontains $_.Name) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
                if ($RemoveAllLocalUsers) {
                    # Sauberes Image: JEDER Profilordner wird entfernt - auch
                    # verwaiste Ordner von laengst geloeschten Konten und das
                    # Profil, das die Administrator-Sitzung dieses Tools
                    # angelegt hat. Windows legt Profile bei der naechsten
                    # Anmeldung automatisch neu an.
                    $foldersToClean = $alleOrdner
                } else {
                    # Nur Profilordner der Konten, die in diesem Lauf entfernt
                    # wurden (z.B. "AutoUpdate" oder "AutoUpdate.PC01").
                    $foldersToClean = @($alleOrdner | Where-Object {
                        $ordnerName = $_.Name
                        ($protectedLocalAccounts -notcontains $ordnerName) -and (
                            ($removedProfileFolders -contains $ordnerName) -or
                            (@($offlineNamen | Where-Object { $ordnerName -eq $_ -or $ordnerName -like "$_.*" }).Count -gt 0))
                    })
                }
            }

            if ($foldersToClean.Count -eq 0) {
                & $LogFunc "Keine verbliebenen Profilordner gefunden." "Gray"
            } else {
                foreach ($folder in $foldersToClean) {
                    # rd statt Remove-Item: rd folgt den Kompatibilitaets-
                    # Junctions im Profil ("Anwendungsdaten" usw.) nicht.
                    & cmd.exe /c "rd /s /q `"$($folder.FullName)`"" 2>&1 | Out-Null
                    if (Test-Path -LiteralPath $folder.FullName) {
                        & $LogFunc "WARNUNG: Profilordner '$($folder.Name)' konnte nicht vollstaendig entfernt werden - nicht kritisch, fahre fort." "Orange"
                    } else {
                        & $LogFunc "Profilordner '$($folder.Name)' entfernt." "Lime"
                    }
                }
            }

            # ProfileList-Eintraege entfernen (sonst meldet Windows spaeter
            # ein "temporaeres Profil"). Im sauberen Modus ALLE Eintraege, die
            # auf \Users\<Name> zeigen - auch solche, deren Ordner schon lange
            # fehlt. Systemprofile (systemprofile, LocalService, ...) liegen
            # nicht unter \Users und bleiben daher immer erhalten.
            if ($foldersToClean.Count -gt 0 -or $RemoveAllLocalUsers) {
                $profileListHive = "${cleanupDriveLetter}:\Windows\System32\config\SOFTWARE"
                $hiveName = "CLEANUP_SOFTWARE_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                reg load "HKLM\$hiveName" $profileListHive 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $profileListKey = "HKLM:\$hiveName\Microsoft\Windows NT\CurrentVersion\ProfileList"
                        if (Test-Path $profileListKey) {
                            $cleanNames = @($foldersToClean | ForEach-Object { $_.Name })
                            $alleEntfernen = [bool]$RemoveAllLocalUsers
                            # Erst sammeln, dann loeschen - nicht waehrend der
                            # Aufzaehlung loeschen.
                            $zuLoeschen = @(Get-ChildItem -Path $profileListKey -ErrorAction SilentlyContinue | Where-Object {
                                $pip = (Get-ItemProperty -Path $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
                                if (-not $pip) { return $false }
                                if ($pip -notmatch '\\Users\\([^\\]+)\\?$') { return $false }
                                $leaf = $Matches[1]
                                if ($systemOrdner -contains $leaf) { return $false }
                                if ($alleEntfernen) { return $true }
                                return ($cleanNames -contains $leaf)
                            } | ForEach-Object { $_.PSPath })
                            foreach ($pp in $zuLoeschen) {
                                Remove-Item -LiteralPath $pp -Recurse -Force -ErrorAction SilentlyContinue
                                & $LogFunc "ProfileList-Eintrag entfernt: $(Split-Path $pp -Leaf)" "Gray"
                            }
                            $zuLoeschen = $null
                        }
                    } finally {
                        if (-not (Invoke-HiveUnload -HiveName $hiveName)) {
                            & $LogFunc "WARNUNG: SOFTWARE-Hive ($hiveName) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern." "Red"
                        }
                    }
                } else {
                    & $LogFunc "WARNUNG: SOFTWARE-Hive konnte nicht geladen werden - ProfileList nicht bereinigt." "Orange"
                }
            }
        } catch {
            & $LogFunc "WARNUNG: Bereinigung der Profildateien fehlgeschlagen: $($_.Exception.Message) - nicht kritisch, fahre fort." "Orange"
        } finally {
            if ($cleanupMounted) {
                try {
                    Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop
                } catch {
                    Start-Sleep -Seconds 3
                    try { Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop } catch {
                        & $LogFunc "WARNUNG: Konnte Arbeitskopie nach Profil-Bereinigung nicht sauber aushaengen." "Orange"
                    }
                }
            }
        }

        if ($SetupFinalAutoLogon -and $FinalAutoLogonUser) {
            & $LogFunc "=== Richte automatischen Login fuer naechsten Boot ein ===" "Cyan"
            & $LogFunc "(Dies gilt fuer JEDEN zukuenftigen Boot der fertigen VHDX, nicht nur die Tool-interne Vorbereitung.)" "Gray"
            $finalMounted = $false
            try {
                Mount-VHD -Path $workingVhdxPath -ErrorAction Stop | Out-Null
                $finalMounted = $true
                Start-Sleep -Seconds 2

                $finalDiskNum = (Get-VHD -Path $workingVhdxPath).DiskNumber
                if ($null -eq $finalDiskNum) { throw "Konnte DiskNumber nicht ermitteln." }

                $finalDriveLetter = Find-WindowsDriveLetter -DiskNumber $finalDiskNum
                if (-not $finalDriveLetter) { throw "Keine Windows-Partition gefunden." }

                $finalPantherPath = "${finalDriveLetter}:\Windows\Panther"
                if (-not (Test-Path $finalPantherPath)) {
                    New-Item -ItemType Directory -Path $finalPantherPath -Force | Out-Null
                }
                $finalUnattendPath = Join-Path $finalPantherPath "unattend.xml"
                if (Test-Path -LiteralPath $finalUnattendPath) {
                    & $LogFunc "HINWEIS: Die bereits vorhandene Panther\unattend.xml des Images wird durch die Autologon-Antwortdatei ersetzt." "Orange"
                }

                # XML-Sonderzeichen im Nutzernamen/Passwort escapen, damit ein
                # "&" oder "<" im Passwort nicht die Antwortdatei zerstoert.
                $escUser = [System.Security.SecurityElement]::Escape($FinalAutoLogonUser)
                $escPass = [System.Security.SecurityElement]::Escape($FinalAutoLogonPassword)
                $hasPassword = -not [string]::IsNullOrEmpty($FinalAutoLogonPassword)

                # WICHTIG (korrigiert nach Recherche zu Microsoft-Dokumentation):
                # Bei leerem Passwort darf der <Password>-Block NICHT weggelassen
                # werden - das wird von Windows Setup schlicht IGNORIERT, wodurch
                # kein Passwort (auch kein leeres) angewendet wird und Autologon
                # nie scharf geschaltet wird. Der dokumentierte, korrekte Weg fuer
                # ein leeres Passwort ist ein PRAESENTES <Password>-Element mit
                # explizit leerem <Value></Value> und <PlainText>true</PlainText> -
                # in BEIDEN Stellen (LocalAccount und AutoLogon). Das gilt
                # unabhaengig davon, ob ein Passwort gesetzt ist oder nicht.
                $accountPasswordBlock = "<Password><Value>$escPass</Value><PlainText>true</PlainText></Password>"
                $autoLogonPasswordBlock = "<Password><Value>$escPass</Value><PlainText>true</PlainText></Password>"

                $finalUnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        $accountPasswordBlock
                        <Group>Administrators</Group>
                        <Name>$escUser</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                $autoLogonPasswordBlock
                <Enabled>true</Enabled>
                <Username>$escUser</Username>
                <LogonCount>999</LogonCount>
            </AutoLogon>
            <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>de-DE</InputLocale>
            <SystemLocale>de-DE</SystemLocale>
            <UILanguage>de-DE</UILanguage>
            <UserLocale>de-DE</UserLocale>
        </component>
    </settings>
</unattend>
"@
                Set-Content -Path $finalUnattendPath -Value $finalUnattendXml -Encoding UTF8 -Force

                # Zusaetzlich noetig: ein lokales Konto ohne Passwort wird von
                # Windows' Standard-Kontorichtlinie normalerweise blockiert
                # ("Konten: Lokale Kontenverwendung von leeren Kennwoertern
                # nur bei Konsolenanmeldung zulassen", LimitBlankPasswordUse).
                # Die Richtlinie wird offline in der SYSTEM-Hive auf "erlaubt"
                # gesetzt - dabei wird NICHT blind ControlSet001 angenommen,
                # sondern zuerst Select\Current gelesen, um den tatsaechlich
                # aktiven ControlSet zu treffen. Ein falscher ControlSet macht
                # die Aenderung wirkungslos, ohne dass ein Fehler auftritt.
                if (-not $hasPassword) {
                    & $LogFunc "Kein Passwort angegeben - richte Autologon fuer leeres Passwort ein..." "Gray"
                    try {
                        $sysHivePath = "${finalDriveLetter}:\Windows\System32\config\SYSTEM"
                        $sysHiveName = "FINALPWD_SYSTEM_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                        reg load "HKLM\$sysHiveName" $sysHivePath 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            try {
                                $currentCtrlSet = 1
                                try {
                                    $selectKey = "HKLM:\$sysHiveName\Select"
                                    if (Test-Path $selectKey) {
                                        $currentCtrlSet = (Get-ItemProperty -Path $selectKey -Name "Current" -ErrorAction Stop).Current
                                    }
                                } catch {}
                                $ctrlSetName = "ControlSet{0:D3}" -f $currentCtrlSet
                                & $LogFunc "Aktiver ControlSet laut Select\Current: $ctrlSetName" "Gray"

                                # Auf den ermittelten ControlSet setzen, UND
                                # sicherheitshalber zusaetzlich auf ControlSet001/002,
                                # falls die Ermittlung selbst danebenliegt.
                                $targetSets = @($ctrlSetName, "ControlSet001", "ControlSet002") | Select-Object -Unique
                                foreach ($csName in $targetSets) {
                                    $lsaKey = "HKLM:\$sysHiveName\$csName\Control\Lsa"
                                    if (Test-Path $lsaKey) {
                                        Set-ItemProperty -Path $lsaKey -Name "LimitBlankPasswordUse" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                                    }
                                }
                            } finally {
                                if (-not (Invoke-HiveUnload -HiveName $sysHiveName)) {
                                    & $LogFunc "WARNUNG: SYSTEM-Hive ($sysHiveName) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern." "Red"
                                }
                            }
                        }
                    } catch {
                        & $LogFunc "WARNUNG: Konnte Kennwort-Richtlinie nicht anpassen: $($_.Exception.Message)" "Orange"
                    }

                    # Zusaetzliche, robustere Absicherung: die klassische
                    # Winlogon-Registry-Autologon-Methode in der SOFTWARE-Hive.
                    # Diese fuehrt eine echte Konsolen-Anmeldung durch (nicht
                    # ueber Remote/RDP), wodurch sie von der oben gesetzten
                    # Richtlinie unabhaengig zuverlaessig funktioniert - auch
                    # wenn eine Hyper-V-Verbindung im Enhanced Session Mode
                    # (das ist technisch RDP) geoeffnet wird. WICHTIG:
                    # DefaultPassword muss als PRAESENTER leerer String gesetzt
                    # werden - fehlt der Wert komplett, deaktiviert Windows
                    # AutoAdminLogon beim naechsten Start automatisch wieder.
                    try {
                        $swHivePath = "${finalDriveLetter}:\Windows\System32\config\SOFTWARE"
                        $swHiveName = "FINALPWD_SOFTWARE_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                        reg load "HKLM\$swHiveName" $swHivePath 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            try {
                                $winlogonKey = "HKLM:\$swHiveName\Microsoft\Windows NT\CurrentVersion\Winlogon"
                                if (Test-Path $winlogonKey) {
                                    Set-ItemProperty -Path $winlogonKey -Name "AutoAdminLogon" -Value "1" -Type String -ErrorAction SilentlyContinue
                                    Set-ItemProperty -Path $winlogonKey -Name "DefaultUserName" -Value $FinalAutoLogonUser -Type String -ErrorAction SilentlyContinue
                                    Set-ItemProperty -Path $winlogonKey -Name "DefaultPassword" -Value "" -Type String -ErrorAction SilentlyContinue
                                    # DefaultDomainName bewusst NICHT gesetzt: der
                                    # Computername steht zum jetzigen Zeitpunkt
                                    # (offline, vor dem naechsten Boot) noch nicht
                                    # zuverlaessig fest. Fuer ein lokales Konto
                                    # sucht Windows ohne DefaultDomainName zuerst
                                    # lokal, das reicht hier aus.
                                    Remove-ItemProperty -Path $winlogonKey -Name "DefaultDomainName" -ErrorAction SilentlyContinue
                                    & $LogFunc "Winlogon-Autologon (Registry) zusaetzlich eingerichtet." "Gray"
                                }
                            } finally {
                                if (-not (Invoke-HiveUnload -HiveName $swHiveName)) {
                                    & $LogFunc "WARNUNG: SOFTWARE-Hive ($swHiveName) konnte nicht entladen werden - Aushaengen der VHDX kann scheitern." "Red"
                                }
                            }
                        }
                    } catch {
                        & $LogFunc "WARNUNG: Winlogon-Autologon konnte nicht zusaetzlich eingerichtet werden: $($_.Exception.Message)" "Orange"
                    }

                    & $LogFunc "HINWEIS: Falls du ueber Hyper-V per 'Enhanced Session' verbindest (das ist technisch RDP), kann ein leeres Passwort trotzdem abgelehnt werden - das ist eine Windows-Sicherheitsrichtlinie fuer Remote-Anmeldungen. Verbinde stattdessen ohne 'Enhanced Session' (Basissitzung) fuer die Konsolenansicht." "Orange"
                }

                & $LogFunc "Automatischer Login eingerichtet fuer Benutzer '$FinalAutoLogonUser'." "Lime"
                if ($hasPassword) {
                    & $LogFunc "HINWEIS: Das Passwort liegt dabei nur leicht verschleiert (Base64-artig, kein echter Schutz) in der VHDX - nur fuer Test-/Referenz-Images geeignet." "Orange"
                } else {
                    & $LogFunc "HINWEIS: Konto wurde OHNE Passwort eingerichtet - jeder mit Zugriff auf die VHDX kann sich als '$FinalAutoLogonUser' anmelden." "Orange"
                }
            } catch {
                & $LogFunc "WARNUNG: Automatischer Login konnte nicht eingerichtet werden: $($_.Exception.Message)" "Orange"
            } finally {
                if ($finalMounted) {
                    try {
                        Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop
                    } catch {
                        Start-Sleep -Seconds 3
                        try { Dismount-VHD -Path $workingVhdxPath -ErrorAction Stop } catch {
                            & $LogFunc "WARNUNG: Konnte Arbeitskopie nach Autologon-Einrichtung nicht sauber aushaengen." "Orange"
                        }
                    }
                }
            }
        }

        # -------------------------------------------------------------
        & $PhaseFunc "Aufräumen & Original ersetzen" 8 $totalPhases
        & $LogFunc "=== Räume temporäre VM auf ===" "Cyan"
        Remove-VM -Name $VMName -Force
        $vmCreated = $false
        & $LogFunc "Temporäre VM entfernt." "Lime"
        if ($usingCopy) {
            & $LogFunc "=== Ersetze Original durch aktualisierte Kopie ===" "Cyan"
            $backupPath = "$VhdxPath.bak"
            & $LogFunc "Sichere ursprüngliches Original nach: $backupPath" "Gray"
            $originalMoved = $false
            try {
                if (Test-Path -LiteralPath $backupPath) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                }
                $moveAttempts = 0
                while (-not $originalMoved) {
                    try {
                        Move-Item -LiteralPath $VhdxPath -Destination $backupPath -ErrorAction Stop
                        $originalMoved = $true
                    } catch {
                        $moveAttempts++
                        if ($moveAttempts -ge 6) { throw }
                        Start-Sleep -Seconds 5
                    }
                }
                $moveAttempts = 0
                $moved = $false
                while (-not $moved) {
                    try {
                        Move-Item -LiteralPath $workingVhdxPath -Destination $VhdxPath -ErrorAction Stop
                        $moved = $true
                    } catch {
                        $moveAttempts++
                        if ($moveAttempts -ge 6) { throw }
                        Start-Sleep -Seconds 5
                    }
                }
            } catch {
                $ersetzFehler = $_.Exception.Message
                # Rollback: Frueher lag das Original danach nur noch als
                # .bak vor - ohne jede Meldung.
                if ($originalMoved -and -not (Test-Path -LiteralPath $VhdxPath)) {
                    try {
                        Move-Item -LiteralPath $backupPath -Destination $VhdxPath -ErrorAction Stop
                        & $LogFunc "Das Original wurde an seinen urspruenglichen Platz zurueckgelegt." "Orange"
                    } catch {
                        & $LogFunc "ACHTUNG: Das Original liegt unter '$backupPath', die aktualisierte Kopie unter '$workingVhdxPath' - bitte manuell umbenennen!" "Red"
                    }
                }
                throw "Das Original konnte nicht durch die aktualisierte Kopie ersetzt werden: $ersetzFehler"
            }
            if ($KeepBackup) {
                & $LogFunc "Original aktualisiert. Alte Version liegt als Backup unter: $backupPath" "Lime"
            } else {
                try {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                    & $LogFunc "Original aktualisiert. Das alte Image wurde geloescht (Backup ist abgeschaltet)." "Lime"
                } catch {
                    & $LogFunc "Original aktualisiert. Das alte Image konnte nicht geloescht werden und liegt noch unter: $backupPath ($($_.Exception.Message))" "Orange"
                }
            }
        }
        & $LogFunc "=== Fertig: VHDX wurde automatisch aktualisiert und neu syspreppt ===" "Cyan"
        return @{ Success = $true; Cancelled = $false }
    } catch {
        $wasCancelled = $_.Exception.Message -eq "ABGEBROCHEN_VOM_NUTZER"
        if ($wasCancelled) {
            & $LogFunc "=== Abgebrochen auf Nutzerwunsch ===" "Orange"
        } else {
            & $LogFunc "FEHLER: $($_.Exception.Message)" "Red"
        }
        & $LogFunc "Räume auf, soweit möglich..." "Orange"
        if ($vmCreated) {
            try {
                if ((Get-VM -Name $VMName -ErrorAction SilentlyContinue).State -ne "Off") {
                    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
                }
                Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue
                & $LogFunc "Temporäre VM wurde entfernt." "Gray"
            } catch {
                & $LogFunc "Temporäre VM '$VMName' konnte nicht automatisch entfernt werden - bitte manuell im Hyper-V-Manager prüfen." "Red"
            }
        }
        if ($usingCopy -and (Test-Path -LiteralPath $VhdxPath)) {
            & $LogFunc "Dein Original unter $VhdxPath wurde NICHT verändert (Sicherheitskopie-Modus)." "Lime"
            if ($workingVhdxPath -ne $VhdxPath -and (Test-Path -LiteralPath $workingVhdxPath)) {
                if ($KeepFailedCopy) {
                    & $LogFunc "Die (evtl. teilweise aktualisierte) Kopie liegt noch unter: $workingVhdxPath" "Gray"
                } else {
                    # Zeitplan-Betrieb: fehlgeschlagene Kopien nicht Nacht fuer
                    # Nacht anhaeufen.
                    try { Dismount-VHD -Path $workingVhdxPath -ErrorAction SilentlyContinue } catch { }
                    try {
                        Remove-Item -LiteralPath $workingVhdxPath -Force -ErrorAction Stop
                        & $LogFunc "Fehlgeschlagene Arbeitskopie geloescht: $workingVhdxPath" "Gray"
                    } catch {
                        & $LogFunc "Arbeitskopie konnte nicht geloescht werden: $($_.Exception.Message)" "Orange"
                    }
                }
            }
        } elseif ($usingCopy) {
            & $LogFunc "ACHTUNG: Unter $VhdxPath liegt keine Datei mehr - siehe Meldungen oben (Sicherung: $VhdxPath.bak, Kopie: $workingVhdxPath)." "Red"
        } else {
            & $LogFunc "Sicherheitskopie war deaktiviert - bitte den Zustand von $VhdxPath manuell prüfen (ggf. liegen in Windows\Panther noch *.autoupdate-bak-Dateien)." "Red"
        }
        return @{ Success = $false; Cancelled = $wasCancelled; Error = $_.Exception.Message }
    } finally {
        # Garantiertes Session-Cleanup, unabhaengig vom Ausgang. Ohne dies
        # kann eine offene PowerShell-Direct-Sitzung zurueckbleiben, was
        # spaetere Operationen (Remove-VM, Datei-Zugriff) verzoegern oder
        # blockieren kann.
        if ($session -and $session.State -eq "Opened") {
            try {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                & $LogFunc "PowerShell-Direct-Sitzung geschlossen." "Gray"
            } catch {
                & $LogFunc "WARNUNG: Sitzung konnte nicht sauber geschlossen werden: $($_.Exception.Message)" "Orange"
            }
        }
    }
}
# ===========================================================================
# Konsolen-Selbsttest (ohne GUI)
# ===========================================================================
if ($SelfTest) {
    Write-Host (Convert-Sprache "`n=== AutoUpdate-Vhdx GUI - Selbsttest ===`n") -ForegroundColor Cyan
    $checks = Test-Prerequisites
    $allCriticalOk = $true
    foreach ($c in $checks) {
        $color = if ($c.Pass) { "Green" } elseif ($c.IsCritical) { "Red" } else { "Yellow" }
        $symbol = if ($c.Pass) { "[OK]" } elseif ($c.IsCritical) { "[FEHLT]" } else { "[WARN]" }
        Write-Host (Convert-Sprache "$symbol $($c.Name)") -ForegroundColor $color
        if ($c.Detail) { Write-Host (Convert-Sprache "       $($c.Detail)") -ForegroundColor DarkGray }
        if (-not $c.Pass -and $c.IsCritical) { $allCriticalOk = $false }
    }
    Write-Host ""
    if ($allCriticalOk) {
        Write-Host (Convert-Sprache "ERGEBNIS: Bereit für den automatischen Update-Lauf.") -ForegroundColor Green
    } else {
        Write-Host (Convert-Sprache "ERGEBNIS: Mindestens eine kritische Voraussetzung fehlt (rot markiert).") -ForegroundColor Red
    }
    Write-Host ""
    return
}

# ===========================================================================
# Unbeaufsichtigter Betrieb (-Unattended) - fuer die zeitgesteuerte
# Ausfuehrung ueber eine geplante Aufgabe, ohne dass jemand am PC sitzt.
# ===========================================================================
if ($Unattended) {
    $alleVhdx = @()
    if ($VhdxPath) { $alleVhdx += @($VhdxPath) }
    if ($VhdxListFile) {
        if (-not (Test-Path -LiteralPath $VhdxListFile)) {
            Write-Host (Convert-Sprache "FEHLER: Listendatei nicht gefunden: $VhdxListFile") -ForegroundColor Red
            exit 2
        }
        $alleVhdx += @(Get-Content -LiteralPath $VhdxListFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") })
    }
    if ($alleVhdx.Count -eq 0) {
        Write-Host (Convert-Sprache "FEHLER: -Unattended benoetigt -VhdxPath oder -VhdxListFile mit mindestens einem Abbild.") -ForegroundColor Red
        exit 2
    }

    $zeilen = New-Object System.Collections.Generic.List[string]

    $ordner = if ($LogPath) { $LogPath } elseif ($script:ScriptPath) { Join-Path (Split-Path $script:ScriptPath -Parent) "Protokolle" } else { Join-Path $env:TEMP "AutoUpdateVhdx-Protokolle" }
    $datei = Join-Path $ordner "AutoUpdateVHDX_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    $kopf = @(
        (Convert-Sprache "AutoUpdate VHDX $ToolVersion (unbeaufsichtigt)"),
        (Convert-Sprache "Protokoll erzeugt: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"),
        (Convert-Sprache "Rechner: $env:COMPUTERNAME   Benutzer: $env:USERNAME"),
        ("-" * 78)
    )
    try {
        if (-not (Test-Path $ordner)) { New-Item -ItemType Directory -Path $ordner -Force | Out-Null }
        Set-Content -Path $datei -Value $kopf -Encoding UTF8 -Force
    } catch {
        Write-Host (Convert-Sprache "Protokoll konnte nicht angelegt werden: $($_.Exception.Message)") -ForegroundColor Yellow
    }

    $konsolenLog = {
        param($m, $c)
        $m = Convert-Sprache $m
        $zeile = "[$(Get-Date -Format 'HH:mm:ss')] $m"
        $zeilen.Add($zeile)
        try {
            Add-Content -Path $datei -Value $zeile -Encoding UTF8 -ErrorAction Stop
        } catch {
        }
        $farbe = switch ($c) {
            "Lime"   { "Green" }
            "Red"    { "Red" }
            "Orange" { "Yellow" }
            "Cyan"   { "Cyan" }
            default  { "Gray" }
        }
        Write-Host $zeile -ForegroundColor $farbe
    }

    & $konsolenLog "AutoUpdate VHDX $ToolVersion - unbeaufsichtigter Lauf" "Cyan"
    $ergebnisse = @()
    $nr = 0
    foreach ($pfad in $alleVhdx) {
        $nr++
        & $konsolenLog "########## Abbild $nr von $($alleVhdx.Count): $pfad ##########" "Cyan"
        if (-not (Test-Path -LiteralPath $pfad)) {
            & $konsolenLog "Abbild nicht gefunden - wird uebersprungen." "Red"
            $ergebnisse += [PSCustomObject]@{ Pfad = $pfad; Success = $false; Cancelled = $false; Error = "Datei nicht gefunden" }
            continue
        }
        $r = Start-AutoUpdate -VhdxPath $pfad -MemoryGB $MemoryGB -MaxUpdateRounds $MaxRounds `
                -UseSafeCopy (-not $NoSafeCopy) -KeepFailedCopy $false -RemoveAllLocalUsers ([bool]$RemoveAllLocalUsers) -KeepBackup ([bool]$KeepBackup) `
                -LogFunc $konsolenLog -PhaseFunc { param($n, $i, $t) } -ShouldCancel { $false }
        $ergebnisse += [PSCustomObject]@{
            Pfad = $pfad; Success = [bool]$r.Success; Cancelled = [bool]$r.Cancelled; Error = $r.Error
        }
    }

    $anzOk  = @($ergebnisse | Where-Object { $_.Success }).Count
    $anzErr = @($ergebnisse | Where-Object { -not $_.Success }).Count
    & $konsolenLog "========== Gesamtbilanz: $anzOk erfolgreich, $anzErr fehlgeschlagen ==========" "Cyan"
    foreach ($e in $ergebnisse) {
        if ($e.Success) { & $konsolenLog "  [OK]     $($e.Pfad)" "Lime" }
        else            { & $konsolenLog "  [FEHLER] $($e.Pfad) - $($e.Error)" "Red" }
    }

    try {
        Remove-AlteProtokolle -Ordner $ordner
        Write-Host (Convert-Sprache "Protokoll: $datei") -ForegroundColor Gray
    } catch {
        Write-Host (Convert-Sprache "Protokoll konnte nicht geschrieben werden: $($_.Exception.Message)") -ForegroundColor Yellow
    }

    Write-AutoUpdateEvent -Message "AutoUpdate VHDX $ToolVersion (Zeitplan): $anzOk erfolgreich, $anzErr fehlgeschlagen." `
        -Level $(if ($anzErr -gt 0) { "Error" } else { "Information" }) `
        -EventId $(if ($anzErr -gt 0) { 1002 } else { 1001 })

    exit $(if ($anzErr -gt 0) { 1 } else { 0 })
}
# ===========================================================================
# GUI Aufbau - WinForms (bewaehrt, zuverlaessig getestet)
# ===========================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Meldungsfenster mit automatischer Uebersetzung. Aufruf wie
# MessageBox::Show: $Meldung.Show(Text, Titel, Knoepfe, Symbol)
$Meldung = New-Object PSObject
$Meldung | Add-Member -MemberType ScriptMethod -Name Show -Value {
    param($Text, $Titel, $Knoepfe, $Symbol)
    if (-not $Knoepfe) { $Knoepfe = "OK" }
    if (-not $Symbol) { $Symbol = "None" }
    return [System.Windows.Forms.MessageBox]::Show(
        (Convert-Sprache ([string]$Text)), (Convert-Sprache ([string]$Titel)),
        [System.Windows.Forms.MessageBoxButtons]$Knoepfe, [System.Windows.Forms.MessageBoxIcon]$Symbol)
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class GradientButton : Button
{
    public Color GradientStart { get; set; }
    public Color GradientEnd { get; set; }

    public GradientButton()
    {
        GradientStart = Color.Gray;
        GradientEnd = Color.LightGray;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        this.FlatStyle = FlatStyle.Flat;
        this.FlatAppearance.BorderSize = 0;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        Rectangle rect = this.ClientRectangle;
        using (LinearGradientBrush brush = new LinearGradientBrush(rect, GradientStart, GradientEnd, 45f))
        {
            e.Graphics.FillRectangle(brush, rect);
        }
        TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
        TextRenderer.DrawText(e.Graphics, this.Text, this.Font, rect, this.ForeColor, flags);
    }
}
"@

# Hinweis: Application.SetHighDpiMode gibt es nur unter .NET Core/.NET 5+,
# nicht unter Windows PowerShell 5.1 (.NET Framework) - der fruehere Aufruf
# schlug dort immer still fehl und wurde daher entfernt.
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Design-Tokens: dunkles macOS-inspiriertes Theme, Petrol/Teal-Akzent -
$ColorWindowBg   = [System.Drawing.Color]::FromArgb(244, 246, 247)
$ColorCardBg     = [System.Drawing.Color]::FromArgb(255, 255, 255)
$ColorCardBorder = [System.Drawing.Color]::FromArgb(222, 227, 230)
$ColorAccent     = [System.Drawing.Color]::FromArgb(26, 134, 146)
$ColorAccentSoft = [System.Drawing.Color]::FromArgb(222, 241, 243)
$ColorDanger     = [System.Drawing.Color]::FromArgb(217, 45, 45)
$ColorDangerSoft = [System.Drawing.Color]::FromArgb(253, 231, 231)
$ColorGood       = [System.Drawing.Color]::FromArgb(21, 150, 68)
$ColorWarn       = [System.Drawing.Color]::FromArgb(194, 120, 6)
$ColorTextHi     = [System.Drawing.Color]::FromArgb(26, 30, 34)
$ColorTextMid    = [System.Drawing.Color]::FromArgb(96, 106, 114)
$ColorTextLow    = [System.Drawing.Color]::FromArgb(105, 115, 123)
$ColorConsoleBg  = [System.Drawing.Color]::FromArgb(248, 249, 250)
$ColorTitleBarBg = [System.Drawing.Color]::FromArgb(255, 255, 255)

$FontDisplay = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$FontClock   = New-Object System.Drawing.Font("Segoe UI Light", 16)
$FontSection = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
$FontBody    = New-Object System.Drawing.Font("Segoe UI", 9.25)
$FontCaption = New-Object System.Drawing.Font("Segoe UI", 8.25)
$FontButton  = New-Object System.Drawing.Font("Segoe UI Semibold", 9.25)
$FontMood    = New-Object System.Drawing.Font("Segoe UI Emoji", 14)
$FontMono    = New-Object System.Drawing.Font("Consolas", 9)

function Get-BlendColor {
    <# Mischt eine Farbe um den angegebenen Anteil (0.0-1.0) in Richtung
       einer Zielfarbe. Grundlage fuer alle Verlaufs-/Hell-Dunkel-Varianten
       im Theme, damit diese IMMER programmatisch aus den Design-Tokens
       abgeleitet werden statt als neue, vom Theme losgeloeste Hex-Werte
       hart codiert zu sein. #>
    param(
        [System.Drawing.Color]$Von,
        [System.Drawing.Color]$Nach,
        [double]$Anteil = 0.18
    )
    $r = [int]($Von.R + ($Nach.R - $Von.R) * $Anteil)
    $g = [int]($Von.G + ($Nach.G - $Von.G) * $Anteil)
    $b = [int]($Von.B + ($Nach.B - $Von.B) * $Anteil)
    return [System.Drawing.Color]::FromArgb(
        [Math]::Max(0, [Math]::Min(255, $r)),
        [Math]::Max(0, [Math]::Min(255, $g)),
        [Math]::Max(0, [Math]::Min(255, $b)))
}

function Get-LighterColor {
    <# Hellt eine Farbe um den angegebenen Anteil Richtung Weiss auf. #>
    param([System.Drawing.Color]$Farbe, [double]$Anteil = 0.18)
    return Get-BlendColor -Von $Farbe -Nach ([System.Drawing.Color]::White) -Anteil $Anteil
}

function Get-DarkerColor {
    <# Dunkelt eine Farbe um den angegebenen Anteil Richtung Schwarz ab. #>
    param([System.Drawing.Color]$Farbe, [double]$Anteil = 0.18)
    return Get-BlendColor -Von $Farbe -Nach ([System.Drawing.Color]::Black) -Anteil $Anteil
}

function Get-RundPfad {
    <# Erzeugt einen GraphicsPath mit echten abgerundeten Ecken fuer ein
       Rechteck der angegebenen Groesse. #>
    param([int]$B, [int]$H, [int]$R = 10)
    $pfad = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    if ($B -lt $d) { $d = [Math]::Max(2, $B - 2) }
    if ($H -lt $d) { $d = [Math]::Max(2, $H - 2) }
    $pfad.AddArc(0, 0, $d, $d, 180, 90)
    $pfad.AddArc(([Math]::Max(0, $B - $d - 1)), 0, $d, $d, 270, 90)
    $pfad.AddArc(([Math]::Max(0, $B - $d - 1)), ([Math]::Max(0, $H - $d - 1)), $d, $d, 0, 90)
    $pfad.AddArc(0, ([Math]::Max(0, $H - $d - 1)), $d, $d, 90, 90)
    $pfad.CloseFigure()
    return $pfad
}

function Set-RundeEcken {
    <# Setzt eine Region mit abgerundeten Ecken auf ein Control - macht aus
       einem rechteckigen Panel eine echte abgerundete Karte (nicht nur
       simuliert). Wird bei Resize erneut aufgerufen (siehe Add_Resize
       weiter unten bei jeder Karte), da die Region sich bei Groessenaen-
       derung sonst nicht automatisch anpasst. #>
    param($Control, [int]$Radius = 10)
    try {
        if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
        $pfad = Get-RundPfad -B $Control.Width -H $Control.Height -R $Radius
        $Control.Region = New-Object System.Drawing.Region($pfad)
    } catch { }
}

function New-Card {
    <# Karte mit ECHTEN abgerundeten Ecken (Region) und Akzent-Streifen.
       Farbwerte werden als Literale direkt im Paint-Handler eingebettet
       (nicht als Closure-Variablen) - bewaehrtes, zuverlaessiges Muster. #>
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title = "")
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y)
    $p.Size = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $p.Add_Paint({
        param($s, $e)
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            # Rahmenfarbe bewusst etwas weicher/kontrastaermer als der reine
            # Token-Wert (Richtung Karten-Hintergrund gemischt) - soll die
            # Karte noch abgrenzen, aber nicht mehr so hart wirken.
            $borderColor = [System.Drawing.Color]::FromArgb(226, 231, 234)
            $accentColor = [System.Drawing.Color]::FromArgb(26, 134, 146)
            $accentBrush = New-Object System.Drawing.SolidBrush($accentColor)
            $e.Graphics.FillRectangle($accentBrush, 0, 0, $s.Width, 3)
            $accentBrush.Dispose()
            $borderPen = New-Object System.Drawing.Pen($borderColor, 1)
            $e.Graphics.DrawRectangle($borderPen, 0, 3, $s.Width - 1, $s.Height - 4)
            $borderPen.Dispose()
        } catch { }
    })
    Set-RundeEcken -Control $p -Radius 18
    $p.Add_Resize({ param($s, $e) Set-RundeEcken -Control $s -Radius 18 })
    if ($Title) {
        $t = New-Object System.Windows.Forms.Label
        $t.Text = $Title.ToUpper()
        $t.Location = New-Object System.Drawing.Point(16, 12)
        $t.Size = New-Object System.Drawing.Size(($W - 32), 16)
        $t.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 7.5)
        $t.ForeColor = [System.Drawing.Color]::FromArgb(96, 106, 114)
        $t.BackColor = [System.Drawing.Color]::Transparent
        $p.Controls.Add($t)
        $p.Tag = $t   # Titel-Label fuer die Sprachumschaltung
    }
    return $p
}

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 34,
          [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [System.Drawing.Color]$Border)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.Font = $FontButton
    $b.FlatStyle = "Flat"
    # Rahmenfarbe leicht Richtung Button-Hintergrund gemischt - weicherer,
    # weniger harter Kontrast als der reine uebergebene Rahmen-Farbwert.
    $b.FlatAppearance.BorderColor = (Get-BlendColor -Von $Border -Nach $Back -Anteil 0.25)
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RundeEcken -Control $b -Radius 11
    return $b
}

function New-TrafficLight {
    <# Kleiner, rund gezeichneter macOS-Ampel-Knopf (Schliessen/Minimieren/
       Maximieren). Farbe wird als Literal im Paint-Handler eingebettet. #>
    param([int]$X, [int]$Y, [string]$HexFarbe)
    $farbe = [System.Drawing.ColorTranslator]::FromHtml($HexFarbe)
    $btn = New-Object System.Windows.Forms.Panel
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size(13, 13)
    $btn.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Add_Paint({
        param($s, $e)
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $kreisFarbe = $s.Tag
            $pinsel = New-Object System.Drawing.SolidBrush($kreisFarbe)
            $e.Graphics.FillEllipse($pinsel, 0, 0, ($s.Width - 1), ($s.Height - 1))
            $pinsel.Dispose()
        } catch { }
    })
    $btn.Tag = $farbe
    return $btn
}

function New-EingabeWrapper {
    <# Native Eingabefelder (TextBox/NumericUpDown) koennen ihre eigenen
       Ecken nicht abrunden (OS-gezeichneter Rahmen). Workaround: das Feld
       bekommt hier ein kleines, rund abgerundetes "Pillen"-Panel in der
       gleichen Hintergrundfarbe als Wrapper spendiert - das Panel uebernimmt
       Position/Groesse, die das Feld vorher hatte (plus ein paar Pixel
       Innenabstand), das Feld selbst wird mit etwas Randabstand hineingehaengt.
       Aufrufer fuegt danach den WRAPPER (nicht mehr das Feld direkt) dem
       Eltern-Control hinzu. #>
    param($Feld, [int]$Radius = 9, [int]$Pad = 3)
    $wrapper = New-Object System.Windows.Forms.Panel
    $wrapper.Location = New-Object System.Drawing.Point($Feld.Location.X, $Feld.Location.Y)
    $wrapper.Size = New-Object System.Drawing.Size(($Feld.Width + $Pad * 2), ($Feld.Height + $Pad * 2))
    $wrapper.BackColor = $Feld.BackColor
    Set-RundeEcken -Control $wrapper -Radius $Radius
    $Feld.Location = New-Object System.Drawing.Point($Pad, $Pad)
    $wrapper.Controls.Add($Feld)
    return $wrapper
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "AutoUpdate VHDX"
$form.ClientSize = New-Object System.Drawing.Size(920, 1002)
$form.MinimumSize = New-Object System.Drawing.Size(880, 852)
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorWindowBg
$form.ForeColor = $ColorTextHi
$form.Font = $FontBody
$form.FormBorderStyle = "None"
$form.MaximizeBox = $true

# Abgerundete Ecken fuers gesamte Fenster - nur im NICHT maximierten
# Zustand, da eine abgerundete Region bei Vollbild unschoen wirkt (Ecken
# wuerden dann sichtbar "abgeschnitten" aussehen, statt buendig mit dem
# Bildschirmrand abzuschliessen).
$form.Add_Resize({
    try {
        if ($form.WindowState -eq "Maximized") {
            $form.Region = $null
        } else {
            Set-RundeEcken -Control $form -Radius 14
        }
    } catch { }
})
$form.Add_Paint({
    param($s, $e)
    try {
        if ($s.WindowState -ne "Maximized") {
            $borderColor = [System.Drawing.Color]::FromArgb(222, 227, 230)
            $borderPen = New-Object System.Drawing.Pen($borderColor, 1)
            $e.Graphics.DrawRectangle($borderPen, 0, 0, $s.Width - 1, $s.Height - 1)
            $borderPen.Dispose()
        }
    } catch { }
})

# --- Eigene Titelleiste (macOS-Ampel-Knoepfe, ziehbar) --------------------
$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Location = New-Object System.Drawing.Point(0, 0)
$titleBar.Size = New-Object System.Drawing.Size(920, 42)
$titleBar.BackColor = $ColorTitleBarBg
$titleBar.Anchor = "Top,Left,Right"
$form.Controls.Add($titleBar)

$btnTLClose = New-TrafficLight -X 16 -Y 15 -HexFarbe "#FF5F57"
$titleBar.Controls.Add($btnTLClose)
$btnTLMin = New-TrafficLight -X 36 -Y 15 -HexFarbe "#FEBC2E"
$titleBar.Controls.Add($btnTLMin)
$btnTLMax = New-TrafficLight -X 56 -Y 15 -HexFarbe "#28C840"
$titleBar.Controls.Add($btnTLMax)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "AutoUpdate VHDX"
$lblTitle.Font = $FontDisplay
$lblTitle.ForeColor = $ColorTextMid
$lblTitle.TextAlign = "MiddleCenter"
$lblTitle.Location = New-Object System.Drawing.Point(360, 10)
$lblTitle.Size = New-Object System.Drawing.Size(200, 22)
$lblTitle.Anchor = "Top"
$titleBar.Controls.Add($lblTitle)

$lblClock = New-Object System.Windows.Forms.Label
$lblClock.Text = (Get-Date).ToString("HH:mm:ss")
$lblClock.Font = $FontClock
$lblClock.ForeColor = [System.Drawing.Color]::FromArgb(24, 128, 140)
$lblClock.TextAlign = "MiddleRight"
$lblClock.Location = New-Object System.Drawing.Point(660, 8)
$lblClock.Size = New-Object System.Drawing.Size(110, 26)
$lblClock.Anchor = "Top,Right"
$titleBar.Controls.Add($lblClock)

$lblMood = New-Object System.Windows.Forms.Label
$lblMood.Text = [char]::ConvertFromUtf32(0x1F634)
$lblMood.Font = $FontMood
$lblMood.TextAlign = "MiddleCenter"
$lblMood.Location = New-Object System.Drawing.Point(780, 6)
$lblMood.Size = New-Object System.Drawing.Size(32, 30)
$lblMood.Anchor = "Top,Right"
$toolTipMood = New-Object System.Windows.Forms.ToolTip
$toolTipMood.SetToolTip($lblMood, "Bereit")
$titleBar.Controls.Add($lblMood)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Bereit"
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5)
$lblStatus.ForeColor = $ColorTextMid
$lblStatus.TextAlign = "MiddleRight"
$lblStatus.Location = New-Object System.Drawing.Point(818, 13)
$lblStatus.Size = New-Object System.Drawing.Size(86, 18)
$lblStatus.Anchor = "Top,Right"
$titleBar.Controls.Add($lblStatus)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = "Windows Update vollautomatisch in einer syspreppten VHDX"
$lblSubtitle.Font = $FontCaption
$lblSubtitle.ForeColor = $ColorTextLow
$lblSubtitle.AutoSize = $true
$lblSubtitle.Location = New-Object System.Drawing.Point(20, 50)
$form.Controls.Add($lblSubtitle)

# --- Fenster ziehbar machen (kein nativer Rahmen mehr vorhanden) ---------
$script:dragging = $false
$script:dragStart = New-Object System.Drawing.Point(0, 0)
$titleBarDragHandler = {
    param($s, $e)
    $script:dragging = $true
    $script:dragStart = New-Object System.Drawing.Point($e.X, $e.Y)
}
$titleBar.Add_MouseDown($titleBarDragHandler)
$lblTitle.Add_MouseDown($titleBarDragHandler)
$titleBar.Add_MouseMove({
    param($s, $e)
    if ($script:dragging) {
        try {
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $e.X - $script:dragStart.X),
                ($form.Location.Y + $e.Y - $script:dragStart.Y))
        } catch { }
    }
})
$titleBar.Add_MouseUp({ $script:dragging = $false })
$titleBar.Add_MouseDoubleClick({
    $form.WindowState = if ($form.WindowState -eq "Maximized") { "Normal" } else { "Maximized" }
})

$btnTLClose.Add_Click({
    $reallyRunning = $script:isRunning
    if ($reallyRunning -and $script:asyncResult -and $script:asyncResult.IsCompleted) {
        $reallyRunning = $false
    }
    if ($reallyRunning) {
        $result = $Meldung.Show(
            "Ein Auto-Update läuft noch. Wenn du jetzt schließt, bleibt evtl. eine temporäre VM zurück, die du manuell im Hyper-V-Manager entfernen musst. Trotzdem schließen?",
            "Update läuft noch", "YesNo", "Warning")
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:sharedState.CancelRequested = $true
    }
    $script:closeConfirmed = $true
    $form.Close()
})
$btnTLMin.Add_Click({ $form.WindowState = "Minimized" })
$btnTLMax.Add_Click({
    $form.WindowState = if ($form.WindowState -eq "Maximized") { "Normal" } else { "Maximized" }
})

function Set-Mood {
    param([ValidateSet("Idle", "Running", "Success", "Error", "Cancelled")][string]$State)
    try {
        $emoji = switch ($State) {
            "Running"   { [char]::ConvertFromUtf32(0x1F680) }
            "Success"   { [char]::ConvertFromUtf32(0x1F389) }
            "Error"     { [char]::ConvertFromUtf32(0x1F625) }
            "Cancelled" { [char]::ConvertFromUtf32(0x1F6D1) }
            default     { [char]::ConvertFromUtf32(0x1F634) }
        }
        $statusText = switch ($State) {
            "Running"   { "Laeuft" }
            "Success"   { "Erfolg" }
            "Error"     { "Fehler" }
            "Cancelled" { "Abbruch" }
            default     { "Bereit" }
        }
        $statusColor = switch ($State) {
            "Running"   { $ColorAccent }
            "Success"   { $ColorGood }
            "Error"     { $ColorDanger }
            "Cancelled" { $ColorWarn }
            default     { $ColorTextMid }
        }
        if ($lblMood -and -not $lblMood.IsDisposed) { $lblMood.Text = $emoji }
        $script:letzterMood = $State
        if ($lblStatus -and -not $lblStatus.IsDisposed) {
            $lblStatus.Text = Convert-Sprache $statusText
            $lblStatus.ForeColor = $statusColor
        }
    } catch { }
}

# --- Karte: Abbild & Zeitplan ---------------------------------------------
$cardSource = New-Card -X 20 -Y 84 -W 880 -H 242 -Title "Abbild & Zeitplan"
$cardSource.Anchor = "Top,Left,Right"
$form.Controls.Add($cardSource)

$lblVhdxSub = New-Object System.Windows.Forms.Label
$lblVhdxSub.Text = "VHDX-Datei"
$lblVhdxSub.Location = New-Object System.Drawing.Point(20, 38)
$lblVhdxSub.Size = New-Object System.Drawing.Size(200, 16)
$lblVhdxSub.Font = $FontCaption
$lblVhdxSub.ForeColor = $ColorTextMid
$cardSource.Controls.Add($lblVhdxSub)

$txtVhdx = New-Object System.Windows.Forms.TextBox
$txtVhdx.Location = New-Object System.Drawing.Point(20, 56)
$txtVhdx.Size = New-Object System.Drawing.Size(620, 26)
$txtVhdx.Font = $FontBody
$txtVhdx.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$txtVhdx.ForeColor = $ColorTextHi
$txtVhdx.BorderStyle = "None"
$txtVhdxWrap = New-EingabeWrapper -Feld $txtVhdx -Radius 9
$txtVhdxWrap.Anchor = "Top,Left,Right"
$txtVhdx.Anchor = "Top,Left,Right"
$txtVhdxWrap.Add_Resize({ param($s, $e) Set-RundeEcken -Control $s -Radius 9 })
$cardSource.Controls.Add($txtVhdxWrap)

$btnBrowseVhdx = New-FlatButton -Text "Durchsuchen" -X 652 -Y 55 -W 130 -H 28 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextHi -Border $ColorCardBorder
$btnBrowseVhdx.Anchor = "Top,Right"
$cardSource.Controls.Add($btnBrowseVhdx)
$btnBrowseVhdx.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "VHDX-Datei(en) auswählen"
    $dlg.Filter = "VHDX-Dateien (*.vhdx)|*.vhdx"
    $dlg.CheckFileExists = $true
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtVhdx.Text = $dlg.FileNames[0]
        foreach ($ausgewaehlteDatei in $dlg.FileNames) {
            Add-VhdxPathToQueue -Liste $lstVhdxQueue -Pfad $ausgewaehlteDatei
        }
    }
})

$lblTime = New-Object System.Windows.Forms.Label
$lblTime.Text = "Zeitplan (Uhrzeit)"
$lblTime.Location = New-Object System.Drawing.Point(20, 92)
$lblTime.Size = New-Object System.Drawing.Size(150, 16)
$lblTime.Font = $FontCaption
$lblTime.ForeColor = $ColorTextMid
$cardSource.Controls.Add($lblTime)

$txtTime = New-Object System.Windows.Forms.TextBox
$txtTime.Text = "02:00"
$txtTime.Location = New-Object System.Drawing.Point(20, 110)
$txtTime.Size = New-Object System.Drawing.Size(70, 26)
$txtTime.Font = $FontBody
$txtTime.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$txtTime.ForeColor = $ColorTextHi
$txtTime.BorderStyle = "None"
$txtTime.TextAlign = "Center"
$txtTimeWrap = New-EingabeWrapper -Feld $txtTime -Radius 9
$cardSource.Controls.Add($txtTimeWrap)

$btnSchedule = New-FlatButton -Text "Zeitplan einrichten" -X 100 -Y 109 -W 160 -H 28 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextHi -Border $ColorCardBorder
$cardSource.Controls.Add($btnSchedule)

$btnScheduleRemove = New-FlatButton -Text "Zeitplan entfernen" -X 270 -Y 109 -W 160 -H 28 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextMid -Border $ColorCardBorder
$cardSource.Controls.Add($btnScheduleRemove)

# Wochentage fuer den Zeitplan. Alle 7 angehakt = taeglich.
$lblTage = New-Object System.Windows.Forms.Label
$lblTage.Text = "Wochentage (alle = täglich)"
$lblTage.Location = New-Object System.Drawing.Point(445, 92)
$lblTage.Size = New-Object System.Drawing.Size(320, 16)
$lblTage.Font = $FontCaption
$lblTage.ForeColor = $ColorTextMid
$cardSource.Controls.Add($lblTage)
$wochentage = @(
    @{ Kurz = "Mo"; En = "Mon"; Schtasks = "MON"; Xml = "Monday" },
    @{ Kurz = "Di"; En = "Tue"; Schtasks = "TUE"; Xml = "Tuesday" },
    @{ Kurz = "Mi"; En = "Wed"; Schtasks = "WED"; Xml = "Wednesday" },
    @{ Kurz = "Do"; En = "Thu"; Schtasks = "THU"; Xml = "Thursday" },
    @{ Kurz = "Fr"; En = "Fri"; Schtasks = "FRI"; Xml = "Friday" },
    @{ Kurz = "Sa"; En = "Sat"; Schtasks = "SAT"; Xml = "Saturday" },
    @{ Kurz = "So"; En = "Sun"; Schtasks = "SUN"; Xml = "Sunday" }
)
$chkTage = @()
$tagX = 445
foreach ($tag in $wochentage) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = T $tag.Kurz $tag.En
    $cb.Tag = $tag
    $cb.Location = New-Object System.Drawing.Point($tagX, 112)
    $cb.Size = New-Object System.Drawing.Size(46, 22)
    $cb.Font = $FontBody
    $cb.ForeColor = $ColorTextHi
    $cb.Checked = $true
    $cardSource.Controls.Add($cb)
    $chkTage += $cb
    $tagX += 46
}

$lblVhdxQueue = New-Object System.Windows.Forms.Label
$lblVhdxQueue.Text = "Warteschlange (mehrere Abbilder nacheinander)"
$lblVhdxQueue.Location = New-Object System.Drawing.Point(20, 144)
$lblVhdxQueue.Size = New-Object System.Drawing.Size(400, 16)
$lblVhdxQueue.Font = $FontCaption
$lblVhdxQueue.ForeColor = $ColorTextMid
$cardSource.Controls.Add($lblVhdxQueue)

$lstVhdxQueue = New-Object System.Windows.Forms.ListBox
$lstVhdxQueue.Location = New-Object System.Drawing.Point(20, 162)
$lstVhdxQueue.Size = New-Object System.Drawing.Size(620, 66)
$lstVhdxQueue.Font = $FontBody
$lstVhdxQueue.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$lstVhdxQueue.ForeColor = $ColorTextHi
$lstVhdxQueue.BorderStyle = "FixedSingle"
$lstVhdxQueue.SelectionMode = "MultiExtended"
$lstVhdxQueue.IntegralHeight = $false
$lstVhdxQueue.Anchor = "Top,Left,Right"
# Eintraege selbst zeichnen, damit jedes Abbild seinen Status farbig zeigt:
# gruen = fertig, tuerkis = laeuft, rot = Fehler/abgebrochen, grau = wartet.
# Farben bewusst als Literale im Handler (keine Closure-Variablen) - das
# bewaehrte Muster aus den Paint-Handlern dieses Skripts.
$lstVhdxQueue.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$lstVhdxQueue.ItemHeight = 20
$lstVhdxQueue.Add_DrawItem({
    param($s, $e)
    try {
        if ($e.Index -lt 0 -or $e.Index -ge $s.Items.Count) { return }
        $pfad = [string]$s.Items[$e.Index]
        $status = $null
        if ($script:sharedState -and $script:sharedState.QueueStatus) { $status = $script:sharedState.QueueStatus[$pfad] }
        $ausgewaehlt = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)

        switch ($status) {
            "Fertig"  { $hinten = [System.Drawing.Color]::FromArgb(226, 244, 232); $punkt = [System.Drawing.Color]::FromArgb(21, 150, 68);  $schrift = [System.Drawing.Color]::FromArgb(20, 110, 52) }
            "Laeuft"  { $hinten = [System.Drawing.Color]::FromArgb(222, 241, 243); $punkt = [System.Drawing.Color]::FromArgb(26, 134, 146); $schrift = [System.Drawing.Color]::FromArgb(18, 100, 110) }
            "Fehler"  { $hinten = [System.Drawing.Color]::FromArgb(253, 231, 231); $punkt = [System.Drawing.Color]::FromArgb(217, 45, 45);  $schrift = [System.Drawing.Color]::FromArgb(170, 30, 30) }
            "Abbruch" { $hinten = [System.Drawing.Color]::FromArgb(253, 243, 224); $punkt = [System.Drawing.Color]::FromArgb(194, 120, 6);  $schrift = [System.Drawing.Color]::FromArgb(150, 90, 4) }
            "Wartet"  { $hinten = [System.Drawing.Color]::FromArgb(255, 255, 255); $punkt = [System.Drawing.Color]::FromArgb(175, 183, 189); $schrift = [System.Drawing.Color]::FromArgb(96, 106, 114) }
            default   { $hinten = [System.Drawing.Color]::FromArgb(255, 255, 255); $punkt = $null;                                              $schrift = [System.Drawing.Color]::FromArgb(26, 30, 34) }
        }
        if ($ausgewaehlt) {
            # Auswahl: etwas dunkler, damit der Status trotzdem erkennbar bleibt
            $hinten = [System.Drawing.Color]::FromArgb(
                [Math]::Max(0, $hinten.R - 22), [Math]::Max(0, $hinten.G - 16), [Math]::Max(0, $hinten.B - 10))
        }

        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pinsel = New-Object System.Drawing.SolidBrush($hinten)
        $g.FillRectangle($pinsel, $e.Bounds)
        $pinsel.Dispose()
        if ($ausgewaehlt) {
            $balken = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 134, 146))
            $g.FillRectangle($balken, $e.Bounds.X, $e.Bounds.Y, 3, $e.Bounds.Height)
            $balken.Dispose()
        }

        $x = $e.Bounds.X + 8
        if ($punkt) {
            $punktPinsel = New-Object System.Drawing.SolidBrush($punkt)
            $g.FillEllipse($punktPinsel, $x, $e.Bounds.Y + [int](($e.Bounds.Height - 8) / 2), 8, 8)
            $punktPinsel.Dispose()
        }
        $x += 16

        # Statuswort rechts (uebersetzt), Pfad links mit "..." bei Platzmangel
        $statusBreite = 0
        if ($status) {
            $statusText = Convert-Sprache $(switch ($status) { "Fertig" { "Fertig" } "Laeuft" { "Läuft" } "Fehler" { "Fehler" } "Abbruch" { "Abgebrochen" } default { "Wartet" } })
            $statusFont = New-Object System.Drawing.Font($s.Font, [System.Drawing.FontStyle]::Bold)
            $statusBreite = 96
            $statusRect = New-Object System.Drawing.Rectangle(($e.Bounds.Right - $statusBreite - 6), $e.Bounds.Y, $statusBreite, $e.Bounds.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $statusText, $statusFont, $statusRect, $punkt,
                ([System.Windows.Forms.TextFormatFlags]::Right -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine))
            $statusFont.Dispose()
        }
        $textRect = New-Object System.Drawing.Rectangle($x, $e.Bounds.Y, [Math]::Max(10, $e.Bounds.Right - $x - $statusBreite - 12), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $pfad, $s.Font, $textRect, $schrift,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::PathEllipsis))
    } catch { }
})
$cardSource.Controls.Add($lstVhdxQueue)

$btnAddQueue = New-FlatButton -Text "Hinzufügen" -X 652 -Y 162 -W 130 -H 28 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextHi -Border $ColorCardBorder
$btnAddQueue.Anchor = "Top,Right"
$cardSource.Controls.Add($btnAddQueue)

$btnRemoveQueue = New-FlatButton -Text "Entfernen" -X 652 -Y 200 -W 130 -H 28 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextMid -Border $ColorCardBorder
$btnRemoveQueue.Anchor = "Top,Right"
$cardSource.Controls.Add($btnRemoveQueue)

function Add-VhdxPathToQueue {
    <# Fuegt einen Pfad der Warteschlangen-ListBox hinzu, sofern er nicht
       leer/ungueltig ist und noch nicht (case-insensitive) enthalten ist. #>
    param(
        [Parameter(Mandatory)][System.Windows.Forms.ListBox]$Liste,
        [string]$Pfad
    )
    if ([string]::IsNullOrWhiteSpace($Pfad)) { return }
    if (-not (Test-Path -LiteralPath $Pfad)) { return }
    if ([IO.Path]::GetExtension($Pfad) -ne ".vhdx") {
        $Meldung.Show("Nur .vhdx-Dateien werden unterstuetzt (die temporaere VM ist Generation 2).`n`n$Pfad", "Nicht unterstuetzt", "OK", "Warning") | Out-Null
        return
    }
    foreach ($vorhanden in $Liste.Items) {
        if ($vorhanden -ieq $Pfad) { return }
    }
    [void]$Liste.Items.Add($Pfad)
}

$btnAddQueue.Add_Click({
    Add-VhdxPathToQueue -Liste $lstVhdxQueue -Pfad $txtVhdx.Text
})

$btnRemoveQueue.Add_Click({
    if ($lstVhdxQueue.SelectedItems.Count -eq 0) { return }
    foreach ($ausgewaehlt in @($lstVhdxQueue.SelectedItems)) {
        $lstVhdxQueue.Items.Remove($ausgewaehlt)
    }
})

# --- Karte: Einstellungen -----------------------------------------------
$cardSettings = New-Card -X 20 -Y 338 -W 880 -H 156 -Title "Einstellungen"
$cardSettings.Anchor = "Top,Left,Right"
$form.Controls.Add($cardSettings)

$lblRam = New-Object System.Windows.Forms.Label
$lblRam.Text = "RAM für VM (GB)"
$lblRam.Location = New-Object System.Drawing.Point(20, 38)
$lblRam.Size = New-Object System.Drawing.Size(140, 16)
$lblRam.Font = $FontCaption
$lblRam.ForeColor = $ColorTextMid
$cardSettings.Controls.Add($lblRam)

$numRam = New-Object System.Windows.Forms.NumericUpDown
$numRam.Location = New-Object System.Drawing.Point(20, 56)
$numRam.Size = New-Object System.Drawing.Size(90, 26)
$numRam.Font = $FontBody
$numRam.Minimum = 2
$numRam.Maximum = 32
$numRam.Value = 8
$numRam.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$numRam.ForeColor = $ColorTextHi
# NumericUpDown hat keine eigene BorderStyle-Eigenschaft, die sich einfach
# entfernen liesse - Wrapper-Panel gibt ihm trotzdem abgerundete Ecken, das
# native Spinner-Steuerelement selbst bleibt wie gehabt (out of scope).
$numRamWrap = New-EingabeWrapper -Feld $numRam -Radius 8 -Pad 2
$cardSettings.Controls.Add($numRamWrap)

$lblRounds = New-Object System.Windows.Forms.Label
$lblRounds.Text = "Max. Update-Runden"
$lblRounds.Location = New-Object System.Drawing.Point(150, 38)
$lblRounds.Size = New-Object System.Drawing.Size(160, 16)
$lblRounds.Font = $FontCaption
$lblRounds.ForeColor = $ColorTextMid
$cardSettings.Controls.Add($lblRounds)

$numRounds = New-Object System.Windows.Forms.NumericUpDown
$numRounds.Location = New-Object System.Drawing.Point(150, 56)
$numRounds.Size = New-Object System.Drawing.Size(90, 26)
$numRounds.Font = $FontBody
$numRounds.Minimum = 1
$numRounds.Maximum = 15
$numRounds.Value = 5
$numRounds.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$numRounds.ForeColor = $ColorTextHi
$numRoundsWrap = New-EingabeWrapper -Feld $numRounds -Radius 8 -Pad 2
$cardSettings.Controls.Add($numRoundsWrap)

$lblRoundsHint = New-Object System.Windows.Forms.Label
$lblRoundsHint.Text = "Nach jeder Runde wird neu gestartet und erneut geprüft, bis zwei`nPrüfungen nacheinander nichts mehr finden."
$lblRoundsHint.Location = New-Object System.Drawing.Point(270, 38)
$lblRoundsHint.Size = New-Object System.Drawing.Size(580, 44)
$lblRoundsHint.Font = $FontCaption
$lblRoundsHint.ForeColor = $ColorTextLow
$lblRoundsHint.Anchor = "Top,Left,Right"
$cardSettings.Controls.Add($lblRoundsHint)

$chkSafeCopy = New-Object System.Windows.Forms.CheckBox
$chkSafeCopy.Text = "Sicherheitskopie verwenden (Original bleibt geschützt)"
$chkSafeCopy.Location = New-Object System.Drawing.Point(20, 96)
$chkSafeCopy.Size = New-Object System.Drawing.Size(400, 22)
$chkSafeCopy.Font = $FontBody
$chkSafeCopy.ForeColor = $ColorTextHi
$chkSafeCopy.Checked = $true
$cardSettings.Controls.Add($chkSafeCopy)

$chkRemoveUsers = New-Object System.Windows.Forms.CheckBox
$chkRemoveUsers.Text = "Alle lokalen Benutzer entfernen (sauberes Image)"
$chkRemoveUsers.Location = New-Object System.Drawing.Point(440, 96)
$chkRemoveUsers.Size = New-Object System.Drawing.Size(420, 22)
$chkRemoveUsers.Font = $FontBody
$chkRemoveUsers.ForeColor = $ColorTextHi
$chkRemoveUsers.Checked = $true
$cardSettings.Controls.Add($chkRemoveUsers)
$tipRemoveUsers = New-Object System.Windows.Forms.ToolTip
$tipRemoveUsers.SetToolTip($chkRemoveUsers, "Entfernt vor Sysprep alle nicht eingebauten lokalen Benutzer samt Profil`nund alle verwaisten Profilordner (Konten, die es nicht mehr gibt).`nDie Konten Administrator, Gast usw. bleiben erhalten. Ohne Haken wird nur das Temp-Konto 'AutoUpdate' entfernt.")

$lblSwitch = New-Object System.Windows.Forms.Label
$lblSwitch.Text = "Ein Switch mit Internetzugang wird automatisch gewählt."
$lblSwitch.Location = New-Object System.Drawing.Point(440, 124)
$lblSwitch.Size = New-Object System.Drawing.Size(420, 18)
$lblSwitch.Font = $FontCaption
$lblSwitch.ForeColor = $ColorTextLow
$cardSettings.Controls.Add($lblSwitch)

$chkKeepBackup = New-Object System.Windows.Forms.CheckBox
$chkKeepBackup.Text = "Altes Image nach Erfolg als .bak behalten"
$chkKeepBackup.Location = New-Object System.Drawing.Point(20, 120)
$chkKeepBackup.Size = New-Object System.Drawing.Size(400, 22)
$chkKeepBackup.Font = $FontBody
$chkKeepBackup.ForeColor = $ColorTextHi
$chkKeepBackup.Checked = $false
$cardSettings.Controls.Add($chkKeepBackup)
$tipKeepBackup = New-Object System.Windows.Forms.ToolTip
$tipKeepBackup.SetToolTip($chkKeepBackup, "Ohne Haken wird das alte Image nach einem ERFOLGREICHEN Lauf geloescht.`nWaehrend des Laufs bleibt das Original trotzdem geschuetzt (Sicherheitskopie).")
# Ohne Sicherheitskopie gibt es kein altes Image, das man behalten koennte.
$chkSafeCopy.Add_CheckedChanged({
    $chkKeepBackup.Enabled = $chkSafeCopy.Checked
})

# --- Karte: Automatischer Login -------------------------------------------
$cardAutoLogon = New-Card -X 20 -Y 504 -W 880 -H 118 -Title "Automatischer Login (fertiges Abbild)"
$cardAutoLogon.Anchor = "Top,Left,Right"
$form.Controls.Add($cardAutoLogon)

$chkFinalAutoLogon = New-Object System.Windows.Forms.CheckBox
$chkFinalAutoLogon.Text = "Nach Sysprep automatischen Login einrichten - überspringt Sprachauswahl/OOBE beim nächsten Boot"
$chkFinalAutoLogon.Location = New-Object System.Drawing.Point(20, 38)
$chkFinalAutoLogon.Size = New-Object System.Drawing.Size(780, 22)
$chkFinalAutoLogon.Font = $FontBody
$chkFinalAutoLogon.ForeColor = $ColorTextHi
$chkFinalAutoLogon.Checked = $false
$cardAutoLogon.Controls.Add($chkFinalAutoLogon)

$lblFinalUser = New-Object System.Windows.Forms.Label
$lblFinalUser.Text = "Benutzername"
$lblFinalUser.Location = New-Object System.Drawing.Point(20, 66)
$lblFinalUser.Size = New-Object System.Drawing.Size(200, 16)
$lblFinalUser.Font = $FontCaption
$lblFinalUser.ForeColor = $ColorTextMid
$cardAutoLogon.Controls.Add($lblFinalUser)

$txtFinalUser = New-Object System.Windows.Forms.TextBox
$txtFinalUser.Location = New-Object System.Drawing.Point(20, 84)
$txtFinalUser.Size = New-Object System.Drawing.Size(260, 24)
$txtFinalUser.Font = $FontBody
$txtFinalUser.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$txtFinalUser.ForeColor = $ColorTextHi
$txtFinalUser.BorderStyle = "None"
$txtFinalUser.Enabled = $false
$txtFinalUserWrap = New-EingabeWrapper -Feld $txtFinalUser -Radius 8
$cardAutoLogon.Controls.Add($txtFinalUserWrap)

$lblFinalPass = New-Object System.Windows.Forms.Label
$lblFinalPass.Text = "Passwort"
$lblFinalPass.Location = New-Object System.Drawing.Point(300, 66)
$lblFinalPass.Size = New-Object System.Drawing.Size(200, 16)
$lblFinalPass.Font = $FontCaption
$lblFinalPass.ForeColor = $ColorTextMid
$cardAutoLogon.Controls.Add($lblFinalPass)

$txtFinalPass = New-Object System.Windows.Forms.TextBox
$txtFinalPass.Location = New-Object System.Drawing.Point(300, 84)
$txtFinalPass.Size = New-Object System.Drawing.Size(260, 24)
$txtFinalPass.Font = $FontBody
$txtFinalPass.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$txtFinalPass.ForeColor = $ColorTextHi
$txtFinalPass.BorderStyle = "None"
$txtFinalPass.UseSystemPasswordChar = $true
$txtFinalPass.Enabled = $false
$txtFinalPassWrap = New-EingabeWrapper -Feld $txtFinalPass -Radius 8
$cardAutoLogon.Controls.Add($txtFinalPassWrap)

$lblFinalWarn = New-Object System.Windows.Forms.Label
$lblFinalWarn.Text = "Nur für Test-/Referenz-Images: Passwort liegt danach nur leicht verschleiert in der VHDX."
$lblFinalWarn.Location = New-Object System.Drawing.Point(580, 66)
$lblFinalWarn.Size = New-Object System.Drawing.Size(280, 42)
$lblFinalWarn.Font = $FontCaption
$lblFinalWarn.ForeColor = $ColorTextLow
$lblFinalWarn.Anchor = "Top,Right"
$cardAutoLogon.Controls.Add($lblFinalWarn)

$chkFinalAutoLogon.Add_CheckedChanged({
    $txtFinalUser.Enabled = $chkFinalAutoLogon.Checked
    $txtFinalPass.Enabled = $chkFinalAutoLogon.Checked
})

# --- Karte: Fortschritt (mit Statistik-Kacheln) ---------------------------
$cardFort = New-Card -X 20 -Y 638 -W 880 -H 90
$cardFort.Anchor = "Top,Left,Right"
$form.Controls.Add($cardFort)

$lblPhase = New-Object System.Windows.Forms.Label
$lblPhase.Text = "Bereit."
$lblPhase.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$lblPhase.ForeColor = $ColorTextHi
$lblPhase.Location = New-Object System.Drawing.Point(18, 16)
$lblPhase.Size = New-Object System.Drawing.Size(500, 24)
$lblPhase.Anchor = "Top,Left,Right"
$cardFort.Controls.Add($lblPhase)

# Zeigt live, was gerade passiert (z.B. "[45%] Installiere (3/7): KB...")
# plus wie lange dieser Schritt schon laeuft - statt Tick-Meldungen im Log.
$lblAktivitaet = New-Object System.Windows.Forms.Label
$lblAktivitaet.Text = ""
$lblAktivitaet.Font = $FontCaption
$lblAktivitaet.ForeColor = $ColorTextMid
$lblAktivitaet.Location = New-Object System.Drawing.Point(18, 41)
$lblAktivitaet.Size = New-Object System.Drawing.Size(500, 17)
$lblAktivitaet.AutoEllipsis = $true
$lblAktivitaet.Anchor = "Top,Left,Right"
$cardFort.Controls.Add($lblAktivitaet)

$progressPhase = New-Object System.Windows.Forms.ProgressBar
$progressPhase.Location = New-Object System.Drawing.Point(18, 62)
$progressPhase.Size = New-Object System.Drawing.Size(500, 8)
$progressPhase.Minimum = 0
$progressPhase.Maximum = 8
$progressPhase.Value = 0
$progressPhase.Style = "Continuous"
$progressPhase.Anchor = "Top,Left,Right"
$cardFort.Controls.Add($progressPhase)

# Verlaufsfarben fuer die Statistik-Kacheln (Abbild/Updates/Laufzeit) -
# programmatisch aus der bisherigen flachen Kachelfarbe abgeleitet, statt
# neuer, vom Theme losgeloester Hex-Werte.
$ColorStatTileBg     = [System.Drawing.Color]::FromArgb(246, 248, 249)
$ColorStatTileTop    = Get-LighterColor -Farbe $ColorStatTileBg -Anteil 0.14
$ColorStatTileBottom = Get-DarkerColor -Farbe $ColorStatTileBg -Anteil 0.08

function New-StatTile {
    param($Eltern, [int]$X, [string]$Title)
    $k = New-Object System.Windows.Forms.Panel
    $k.Location = New-Object System.Drawing.Point($X, 16)
    $k.Size = New-Object System.Drawing.Size(112, 58)
    $k.BackColor = $ColorStatTileBg
    $k.Anchor = "Top,Right"
    $k.Add_Paint({
        param($s, $e)
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
            $verlauf = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $rect, $ColorStatTileTop, $ColorStatTileBottom, 90)
            $e.Graphics.FillRectangle($verlauf, $rect)
            $verlauf.Dispose()
        } catch { }
    })
    Set-RundeEcken -Control $k -Radius 10
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title.ToUpper()
    $t.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 7)
    $t.ForeColor = $ColorTextLow
    $t.Location = New-Object System.Drawing.Point(10, 8)
    $t.Size = New-Object System.Drawing.Size(96, 14)
    $k.Controls.Add($t)
    $w = New-Object System.Windows.Forms.Label
    $w.Text = "-"
    $w.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
    $w.ForeColor = $ColorTextHi
    $w.Location = New-Object System.Drawing.Point(8, 24)
    $w.Size = New-Object System.Drawing.Size(98, 28)
    $k.Controls.Add($w)
    $Eltern.Controls.Add($k)
    return @{ Panel = $k; Value = $w; Title = $t }
}
$kachelBild    = New-StatTile -Eltern $cardFort -X 540 -Title "Abbild"
$kachelUpdates = New-StatTile -Eltern $cardFort -X 660 -Title "Updates"
$kachelZeit    = New-StatTile -Eltern $cardFort -X 780 -Title "Laufzeit"

# --- Karte: Protokoll -------------------------------------------------
$cardLog = New-Card -X 20 -Y 738 -W 880 -H 202 -Title "Protokoll"
$cardLog.Anchor = "Top,Left,Right,Bottom"
$form.Controls.Add($cardLog)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(14, 32)
$txtLog.Size = New-Object System.Drawing.Size(852, 156)
$txtLog.Anchor = "Top,Left,Right,Bottom"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = "FixedSingle"
$txtLog.Font = $FontMono
$txtLog.BackColor = $ColorConsoleBg
$txtLog.ForeColor = $ColorTextHi
$cardLog.Controls.Add($txtLog)

# --- Aktionsleiste -----------------------------------------------------
# Primaerer Aktionsknopf bekommt statt der reinen Flaechenfarbe einen
# dezenten diagonalen Verlauf (Akzentfarbe -> etwas hellere, aus ihr
# berechnete Variante). Dafuer kommt eine eigene, kompilierte Button-
# Unterklasse (GradientButton, s.o.) zum Einsatz statt eines Paint-Event-
# Hacks auf einem Stock-Button - OnPaint wird dort sauber ueberschrieben,
# ohne die Unklarheiten von Basis-Zeichnung vs. Paint-Event-Reihenfolge.
$ColorAccentHell = Get-LighterColor -Farbe $ColorAccent -Anteil 0.18
$btnStart = New-Object GradientButton
$btnStart.Text = "Auto-Update starten"
$btnStart.Location = New-Object System.Drawing.Point(20, 952)
$btnStart.Size = New-Object System.Drawing.Size(186, 34)
$btnStart.Font = $FontButton
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnStart.GradientStart = $ColorAccent
$btnStart.GradientEnd = $ColorAccentHell
$btnStart.Anchor = "Bottom,Left"
Set-RundeEcken -Control $btnStart -Radius 11
$form.Controls.Add($btnStart)

$btnCancel = New-FlatButton -Text "Abbrechen" -X 216 -Y 952 -W 120 -H 34 -Back $ColorDangerSoft -Fore $ColorDanger -Border $ColorDangerSoft
$btnCancel.Anchor = "Bottom,Left"
$btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$btnResetRearm = New-FlatButton -Text "Rearm-Zähler zurücksetzen" -X 346 -Y 952 -W 210 -H 34 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextHi -Border $ColorCardBorder
$btnResetRearm.Anchor = "Bottom,Left"
$form.Controls.Add($btnResetRearm)

$btnSelfTest = New-FlatButton -Text "Selbsttest" -X 654 -Y 952 -W 108 -H 34 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextHi -Border $ColorCardBorder
$btnSelfTest.Anchor = "Bottom,Right"
$form.Controls.Add($btnSelfTest)

$btnClose = New-FlatButton -Text "Schließen" -X 770 -Y 952 -W 130 -H 34 -Back ([System.Drawing.Color]::FromArgb(238, 241, 243)) -Fore $ColorTextMid -Border $ColorCardBorder
$btnClose.Anchor = "Bottom,Right"
$form.Controls.Add($btnClose)
$btnClose.Add_Click({
    $reallyRunning = $script:isRunning
    if ($reallyRunning -and $script:asyncResult -and $script:asyncResult.IsCompleted) {
        $reallyRunning = $false
    }
    if ($reallyRunning) {
        $result = $Meldung.Show(
            "Ein Auto-Update läuft noch. Wenn du jetzt schließt, bleibt evtl. eine temporäre VM zurück, die du manuell im Hyper-V-Manager entfernen musst. Trotzdem schließen?",
            "Update läuft noch", "YesNo", "Warning")
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:sharedState.CancelRequested = $true
    }
    $script:closeConfirmed = $true
    $form.Close()
})

$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({
    try {
        if ($lblClock -and -not $lblClock.IsDisposed) { $lblClock.Text = (Get-Date).ToString("HH:mm:ss") }
        if ($script:sharedState -and ([int]$script:sharedState.QueueVersion -ne [int]$script:letzteQueueVersion)) {
            $script:letzteQueueVersion = [int]$script:sharedState.QueueVersion
            if ($lstVhdxQueue -and -not $lstVhdxQueue.IsDisposed) { $lstVhdxQueue.Invalidate() }
        }
        if ($script:isRunning -and $script:runStartTime) {
            $elapsed = (Get-Date) - $script:runStartTime
            if ($kachelZeit -and $kachelZeit.Value -and -not $kachelZeit.Value.IsDisposed) {
                # Floor statt [int]: [int] rundet (1,5 min -> "2:30" statt "1:30").
                $kachelZeit.Value.Text = "{0}:{1:D2}" -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
            }
            $akt = Convert-Sprache $script:sharedState.Aktivitaet
            if ($akt -and $lblAktivitaet -and -not $lblAktivitaet.IsDisposed) {
                $seit = ""
                if ($script:sharedState.AktivitaetSeit) {
                    $d = (Get-Date) - $script:sharedState.AktivitaetSeit
                    if ($d.TotalSeconds -ge 5) { $seit = "   ·   {0} {1}:{2:D2}" -f (T "seit" "for"), [int][Math]::Floor($d.TotalMinutes), $d.Seconds }
                }
                $lblAktivitaet.Text = "$akt$seit"
            }
            $upd = $script:sharedState.UpdatesText
            if ($upd -and $kachelUpdates -and $kachelUpdates.Value -and -not $kachelUpdates.Value.IsDisposed -and $kachelUpdates.Value.Text -ne $upd) {
                $kachelUpdates.Value.Text = $upd
            }
        }
    } catch { }
})
$clockTimer.Start()

# ===========================================================================
# Logging & Fortschritt (Hauptthread)
# ===========================================================================
$script:isRunning = $false
$script:sharedState = [hashtable]::Synchronized(@{ CancelRequested = $false })
$LogFarben = @{
    "Lime" = $ColorGood; "Red" = $ColorDanger; "Orange" = $ColorWarn
    "Cyan" = $ColorAccent; "Gray" = $ColorTextMid; "DarkGray" = $ColorTextLow; "LightGray" = $ColorTextHi
}

function Add-Log {
    param([string]$Message, [string]$Color = "LightGray")
    try {
        if ($null -eq $txtLog -or $txtLog.IsDisposed) { return }
        if ($txtLog.InvokeRequired) {
            $txtLog.Invoke([Action]{ Add-Log -Message $Message -Color $Color })
            return
        }
        $Message = Convert-Sprache $Message
        $timestamp = Get-Date -Format "HH:mm:ss"
        $txtLog.SelectionStart = $txtLog.TextLength
        $farbe = $LogFarben[$Color]
        if (-not $farbe) { $farbe = $ColorTextHi }
        $txtLog.SelectionColor = $farbe
        $txtLog.AppendText("[$timestamp] $Message`r`n")
        $txtLog.ScrollToCaret()
    } catch { }
}
function Set-Phase {
    param([string]$Name, [int]$Index, [int]$Total)
    try {
        if ($null -eq $lblPhase -or $lblPhase.IsDisposed) { return }
        if ($lblPhase.InvokeRequired) {
            $lblPhase.Invoke([Action]{ Set-Phase -Name $Name -Index $Index -Total $Total })
            return
        }
        $script:sharedState.PhaseRoh = @($Name, $Index, $Total)
        $lblPhase.Text = "Phase $Index/$Total`: $(Convert-Sprache $Name)"
        if ($progressPhase -and -not $progressPhase.IsDisposed) {
            $progressPhase.Maximum = $Total
            $progressPhase.Value = [Math]::Min($Index, $Total)
        }
    } catch { }
}

# ===========================================================================
# "Zeitplan einrichten" / "Zeitplan entfernen"
# ===========================================================================
$btnSchedule.Add_Click({
    # Warteschlange hat Vorrang (wie beim Start-Button), sonst das Textfeld.
    $zeitplanVhdx = @()
    if ($lstVhdxQueue.Items.Count -gt 0) {
        $zeitplanVhdx = @($lstVhdxQueue.Items | ForEach-Object { [string]$_ })
    } elseif (-not [string]::IsNullOrWhiteSpace($txtVhdx.Text)) {
        $zeitplanVhdx = @($txtVhdx.Text)
    }
    $zeitplanVhdx = @($zeitplanVhdx | Where-Object { Test-Path -LiteralPath $_ })
    if ($zeitplanVhdx.Count -eq 0) {
        $Meldung.Show("Bitte zuerst eine gültige VHDX-Datei auswählen oder der Warteschlange hinzufügen.", "Keine VHDX", "OK", "Warning")
        return
    }
    if ($txtTime.Text -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        $Meldung.Show("Die Uhrzeit muss im Format HH:MM angegeben werden, zum Beispiel 02:00.", "Ungültige Uhrzeit", "OK", "Warning")
        return
    }
    $gewaehlteTage = @($chkTage | Where-Object { $_.Checked })
    if ($gewaehlteTage.Count -eq 0) {
        $Meldung.Show("Bitte mindestens einen Wochentag auswählen.", "Kein Wochentag", "OK", "Warning")
        return
    }
    if ($gewaehlteTage.Count -eq 7) {
        $rhythmusArgs = @("/SC", "DAILY")
        $rhythmusText = T "täglich" "daily"
    } else {
        $rhythmusArgs = @("/SC", "WEEKLY", "/D", (($gewaehlteTage | ForEach-Object { $_.Tag.Schtasks }) -join ","))
        $rhythmusText = (T "jeden " "every ") + (($gewaehlteTage | ForEach-Object { T $_.Tag.Kurz $_.Tag.En }) -join ", ")
    }
    if (-not $script:ScriptPath) {
        $Meldung.Show("Der Pfad des Skripts konnte nicht ermittelt werden. Ein Zeitplan lässt sich nur einrichten, wenn das Skript als Datei gestartet wurde.", "Pfad unbekannt", "OK", "Error")
        return
    }

    $logDir = Join-Path (Split-Path $script:ScriptPath -Parent) "Protokolle"
    $zeitplanOrdner = Join-Path $env:ProgramData "AutoUpdateVhdx"
    if (-not (Test-Path $zeitplanOrdner)) {
        New-Item -ItemType Directory -Path $zeitplanOrdner -Force | Out-Null
    }
    $cmdFile = Join-Path $zeitplanOrdner "AutoUpdate-Zeitplan.cmd"
    # Die Abbilder stehen in einer Listendatei: Arrays lassen sich ueber
    # "powershell.exe -File" nicht zuverlaessig uebergeben.
    $listFile = Join-Path $zeitplanOrdner "AutoUpdate-Zeitplan-Liste.txt"

    $psArgs = "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$($script:ScriptPath)`" " +
              "-Unattended -VhdxListFile `"$listFile`" -LogPath `"$logDir`" " +
              "-MemoryGB $([int]$numRam.Value) -MaxRounds $([int]$numRounds.Value)"
    if (-not $chkSafeCopy.Checked) { $psArgs += " -NoSafeCopy" }
    if ($chkRemoveUsers.Checked) { $psArgs += " -RemoveAllLocalUsers" }
    if ($chkSafeCopy.Checked -and $chkKeepBackup.Checked) { $psArgs += " -KeepBackup" }

    $cmdContent = "@echo off`r`nrem Von AutoUpdate VHDX GUI erzeugt - wird von der geplanten Aufgabe 'AutoUpdate-VHDX' aufgerufen.`r`npowershell.exe $($psArgs -replace '%', '%%')`r`n"

    try {
        Set-Content -Path $cmdFile -Value $cmdContent -Encoding OEM -Force
        Set-Content -LiteralPath $listFile -Value $zeitplanVhdx -Encoding UTF8 -Force
        # Beide Dateien werden von SYSTEM ausgefuehrt bzw. gelesen - nur
        # SYSTEM und Administratoren duerfen sie aendern.
        foreach ($geschuetzteDatei in @($cmdFile, $listFile)) {
            try {
                $acl = Get-Acl -Path $geschuetzteDatei
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($regel in @($acl.Access)) { [void]$acl.RemoveAccessRule($regel) }
                $sidTypes = @(
                    [System.Security.Principal.WellKnownSidType]::LocalSystemSid,
                    [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid
                )
                foreach ($sidType in $sidTypes) {
                    $sid = New-Object System.Security.Principal.SecurityIdentifier($sidType, $null)
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, "FullControl", "Allow")))
                }
                Set-Acl -Path $geschuetzteDatei -AclObject $acl
            } catch {
                Add-Log "Rechte von '$geschuetzteDatei' konnten nicht gesetzt werden: $($_.Exception.Message)" "Orange"
            }
        }

        $out = & schtasks.exe /Create /TN "AutoUpdate-VHDX" /TR "`"$cmdFile`"" @rhythmusArgs /ST $txtTime.Text /RU SYSTEM /RL HIGHEST /F 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out | Out-String) }

        Add-Log "Zeitplan eingerichtet: $rhythmusText um $($txtTime.Text) Uhr für $($zeitplanVhdx.Count) Abbild(er):" "Lime"
        foreach ($zv in $zeitplanVhdx) { Add-Log "    $zv" "Gray" }
        Add-Log "Abbild-Liste: $listFile" "Gray"
        Add-Log "Startdatei: $cmdFile" "Gray"
        Add-Log "Protokolle werden abgelegt unter: $logDir" "Gray"
        $Meldung.Show(
            "Die Aufgabe 'AutoUpdate-VHDX' wurde eingerichtet.`n`nSie läuft $rhythmusText um $($txtTime.Text) Uhr.`n`nProtokolle: $logDir`n`nEntfernen mit dem Button 'Zeitplan entfernen' oder:`nschtasks /Delete /TN AutoUpdate-VHDX /F",
            "Zeitplan eingerichtet", "OK", "Information")
    } catch {
        $Meldung.Show("Zeitplan konnte nicht eingerichtet werden:`n$($_.Exception.Message)", "Fehler", "OK", "Error")
    }
})

$btnScheduleRemove.Add_Click({
    $confirmResult = $Meldung.Show(
        "Die geplante Aufgabe 'AutoUpdate-VHDX' wird entfernt. Fortfahren?",
        "Zeitplan entfernen", "YesNo", "Question")
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $out = & schtasks.exe /Delete /TN "AutoUpdate-VHDX" /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Add-Log "Zeitplan 'AutoUpdate-VHDX' entfernt." "Lime"
        $Meldung.Show("Der Zeitplan wurde entfernt.", "Fertig", "OK", "Information")
    } else {
        Add-Log "Konnte Zeitplan nicht entfernen: $out" "Orange"
        $Meldung.Show("Der Zeitplan konnte nicht entfernt werden (evtl. war keiner eingerichtet).", "Hinweis", "OK", "Warning")
    }
})

# ===========================================================================
# "Rearm-Zaehler zuruecksetzen"-Button
# ===========================================================================
$btnResetRearm.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtVhdx.Text)) {
        $Meldung.Show("Bitte zuerst eine VHDX-Datei auswählen.", "Fehlende Angabe", "OK", "Warning")
        return
    }
    if (-not (Test-Path -LiteralPath $txtVhdx.Text)) {
        $Meldung.Show("Die angegebene VHDX-Datei existiert nicht.", "Fehler", "OK", "Error")
        return
    }
    $confirmResult = $Meldung.Show(
        "Der Sysprep-Rearm-Zaehler dieser VHDX wird zurueckgesetzt (Registry-Eingriff, offline, ohne die VHDX zu booten). Fortfahren?",
        "Rearm-Zaehler zuruecksetzen", "YesNo", "Question")
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $txtLog.Clear()
    Add-Log "=== Rearm-Zaehler-Reset (offline, ohne zu booten) ===" "Cyan"
    $btnResetRearm.Enabled = $false
    $btnStart.Enabled = $false
    $btnSelfTest.Enabled = $false

    $vhdxToReset = $txtVhdx.Text
    $mountedHere = $false
    try {
        Import-Module Hyper-V -ErrorAction Stop
        Add-Log "Mounte VHDX..." "Gray"
        Mount-VHD -Path $vhdxToReset -ErrorAction Stop | Out-Null
        $mountedHere = $true
        Start-Sleep -Seconds 2

        $diskNum = (Get-VHD -Path $vhdxToReset).DiskNumber
        if ($null -eq $diskNum) { throw "Konnte DiskNumber nicht ermitteln." }

        $driveLetter = Find-WindowsDriveLetter -DiskNumber $diskNum
        if (-not $driveLetter) { throw "Keine Windows-Partition gefunden." }

        Add-Log "Windows-Partition gefunden: ${driveLetter}:\" "Lime"
        Reset-SysprepRearmCounter -OfflineWindowsPath "${driveLetter}:\" -LogFunc { param($m, $c) Add-Log $m $c } | Out-Null
        Add-Log "=== Rearm-Zaehler erfolgreich zurueckgesetzt ===" "Lime"
        $Meldung.Show("Der Rearm-Zaehler wurde zurueckgesetzt.", "Fertig", "OK", "Information")

    } catch {
        Add-Log "FEHLER: $($_.Exception.Message)" "Red"
        $Meldung.Show("Fehler beim Zuruecksetzen: $($_.Exception.Message)", "Fehler", "OK", "Error")
    } finally {
        if ($mountedHere) {
            try {
                Dismount-VHD -Path $vhdxToReset -ErrorAction Stop
                Add-Log "VHDX ausgehaengt." "Gray"
            } catch {
                Start-Sleep -Seconds 3
                try { Dismount-VHD -Path $vhdxToReset -ErrorAction Stop } catch {
                    Add-Log "WARNUNG: VHDX konnte nicht sauber ausgehaengt werden - bitte manuell pruefen (Get-VHD / Dismount-VHD)." "Red"
                }
            }
        }
        $btnResetRearm.Enabled = $true
        $btnStart.Enabled = $true
        $btnSelfTest.Enabled = $true
    }
})

# ===========================================================================
# Selbsttest-Button
# ===========================================================================
$btnSelfTest.Add_Click({
    $txtLog.Clear()
    Add-Log "=== Selbsttest wird ausgeführt ===" "Cyan"
    $checks = Test-Prerequisites
    $allCriticalOk = $true
    foreach ($c in $checks) {
        $color = if ($c.Pass) { "Lime" } elseif ($c.IsCritical) { "Red" } else { "Orange" }
        $symbol = if ($c.Pass) { "[OK]" } elseif ($c.IsCritical) { "[FEHLT]" } else { "[WARN]" }
        Add-Log "$symbol $($c.Name)" $color
        if ($c.Detail) { Add-Log "      $($c.Detail)" "Gray" }
        if (-not $c.Pass -and $c.IsCritical) { $allCriticalOk = $false }
    }
    if ($allCriticalOk) {
        Add-Log "Alle kritischen Voraussetzungen erfüllt. Bereit für den Auto-Update-Lauf." "Lime"
    } else {
        Add-Log "Mindestens eine kritische Voraussetzung fehlt (rot markiert) - siehe oben." "Red"
    }
})

# ===========================================================================
# Start-Button: laeuft in eigenem Runspace, damit die GUI responsiv bleibt
# ===========================================================================
$script:runspace = $null
$script:powershell = $null
$script:tickHandled = $false

$btnStart.Add_Click({
    # Warteschlange hat Vorrang, falls sie Eintraege enthaelt - dann ist das
    # Textfeld nur noch die Eingabehilfe zum Hinzufuegen. Ist die Warteschlange
    # leer, verhaelt sich alles EXAKT wie bisher (Einzeldatei aus dem Textfeld).
    $queueHasItems = $lstVhdxQueue.Items.Count -gt 0

    if (-not $queueHasItems) {
        if ([string]::IsNullOrWhiteSpace($txtVhdx.Text)) {
            $Meldung.Show("Bitte zuerst eine VHDX-Datei auswählen oder der Warteschlange hinzufügen.", "Fehlende Angabe", "OK", "Warning")
            return
        }
        if (-not (Test-Path -LiteralPath $txtVhdx.Text)) {
            $Meldung.Show("Die angegebene VHDX-Datei existiert nicht.", "Fehler", "OK", "Error")
            return
        }
    }
    if ($chkFinalAutoLogon.Checked -and [string]::IsNullOrWhiteSpace($txtFinalUser.Text)) {
        $Meldung.Show("Bitte einen Benutzernamen für den automatischen Login angeben, oder das Häkchen entfernen.", "Fehlende Angabe", "OK", "Warning")
        return
    }

    if (-not $queueHasItems) {
        # Dieser Vor-Check auf ein bereits gemountetes Abbild ist nur fuer den
        # klassischen Einzeldatei-Fall sinnvoll (eindeutiges Ziel). Bei der
        # Warteschlange wuerde das je Abbild ohnehin erneut beim eigentlichen
        # Lauf greifen bzw. dort sichtbar werden - kein Verhaltensunterschied
        # fuer den unveraenderten Einzeldatei-Weg.
        try {
            Import-Module Hyper-V -ErrorAction SilentlyContinue
            $existingMount = Get-VHD -Path $txtVhdx.Text -ErrorAction SilentlyContinue
            if ($existingMount -and $existingMount.Attached) {
                $unmountResult = $Meldung.Show(
                    "Diese VHDX ist bereits gemountet (evtl. Rest eines vorherigen, abgebrochenen Laufs). Jetzt automatisch aushaengen und fortfahren?",
                    "VHDX bereits gemountet", "YesNo", "Warning")
                if ($unmountResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                try { Dismount-VHD -Path $txtVhdx.Text -ErrorAction Stop } catch {
                    $Meldung.Show("Konnte die VHDX nicht aushaengen: $($_.Exception.Message)", "Fehler", "OK", "Error")
                    return
                }
            }
        } catch { }
    }

    $vhdxPathList = if ($queueHasItems) { @($lstVhdxQueue.Items) } else { @($txtVhdx.Text) }
    # Farbstatus der Warteschlange fuer diesen Lauf neu aufsetzen
    $script:sharedState.QueueStatus = [hashtable]::Synchronized(@{})
    if ($queueHasItems) {
        foreach ($eintrag in $vhdxPathList) { $script:sharedState.QueueStatus[[string]$eintrag] = "Wartet" }
    }
    $script:sharedState.QueueVersion = [int]$script:sharedState.QueueVersion + 1
    $pendingCount = @($vhdxPathList).Count

    # Aus ganzen Absaetzen aufgebaut, damit jeder Absatz uebersetzt werden kann.
    $absaetze = @()
    if ($pendingCount -gt 1) {
        $absaetze += "Es werden $pendingCount VHDX-Abbilder nacheinander automatisch gebootet, aktualisiert und neu syspreppt."
        $absaetze += "Das kann insgesamt deutlich laenger als 10-45 Minuten dauern (abhaengig von Anzahl und Groesse der Abbilder)."
        $absaetze += $(if ($chkSafeCopy.Checked) { "Es wird jeweils eine Sicherheitskopie verwendet - deine Originale bleiben bis zum Erfolg unangetastet." } else { "SICHERHEITSKOPIE IST DEAKTIVIERT - es wird direkt an den Originalen gearbeitet!" })
    } else {
        $absaetze += "Die VHDX wird jetzt automatisch gebootet, aktualisiert und neu syspreppt."
        $absaetze += "Das kann 10-45+ Minuten dauern."
        $absaetze += $(if ($chkSafeCopy.Checked) { "Es wird eine Sicherheitskopie verwendet - dein Original bleibt bis zum Erfolg unangetastet." } else { "SICHERHEITSKOPIE IST DEAKTIVIERT - es wird direkt am Original gearbeitet!" })
    }
    if ($chkFinalAutoLogon.Checked) { $absaetze += "Automatischer Login wird fuer den Benutzer '$($txtFinalUser.Text.Trim())' eingerichtet." }
    if ($chkSafeCopy.Checked -and -not $chkKeepBackup.Checked) { $absaetze += "Nach Erfolg wird das alte Image geloescht (kein .bak-Backup)." }
    if ($chkRemoveUsers.Checked) { $absaetze += "ALLE lokalen Benutzer (ausser den eingebauten) und alle Benutzerprofile werden aus dem Image entfernt - auch verwaiste Profile ohne Konto." }
    $absaetze += "Fortfahren?"
    $confirmMsg = $absaetze -join "`n`n"
    $confirmResult = $Meldung.Show($confirmMsg, "Auto-Update bestätigen", "YesNo", "Question")
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $txtLog.Clear()
    Set-Mood -State "Running"
    $script:isRunning = $true
    $script:tickHandled = $false
    $script:sharedState.CancelRequested = $false
    $script:sharedState.Aktivitaet = "Starte..."
    $script:sharedState.PhaseRoh = $null
    $script:sharedState.AktivitaetSeit = Get-Date
    $script:sharedState.UpdatesText = $null
    $script:runStartTime = Get-Date
    try {
        if ($pendingCount -gt 1) {
            $kachelBild.Value.Text = "1/$pendingCount"
        } else {
            $vhdxFileName = Split-Path $vhdxPathList[0] -Leaf
            if ($vhdxFileName.Length -gt 12) { $vhdxFileName = $vhdxFileName.Substring(0, 9) + "..." }
            $kachelBild.Value.Text = $vhdxFileName
        }
    } catch { }
    $kachelUpdates.Value.Text = "-"
    $kachelZeit.Value.Text = "0:00"

    $btnStart.Enabled = $false
    $btnCancel.Enabled = $true
    $btnSelfTest.Enabled = $false
    $btnResetRearm.Enabled = $false
    $btnBrowseVhdx.Enabled = $false
    $numRam.Enabled = $false
    $numRounds.Enabled = $false
    $chkSafeCopy.Enabled = $false
    $chkRemoveUsers.Enabled = $false
    $chkKeepBackup.Enabled = $false
    $chkFinalAutoLogon.Enabled = $false
    $txtFinalUser.Enabled = $false
    $txtFinalPass.Enabled = $false
    $lstVhdxQueue.Enabled = $false
    $btnAddQueue.Enabled = $false
    $btnRemoveQueue.Enabled = $false

    $memGb = [int]$numRam.Value
    $maxRounds = [int]$numRounds.Value
    $useSafeCopy = $chkSafeCopy.Checked
    $removeAllUsers = $chkRemoveUsers.Checked
    $keepBackup = $chkKeepBackup.Checked
    $setupFinalAutoLogon = $chkFinalAutoLogon.Checked
    $finalAutoLogonUser = $txtFinalUser.Text.Trim()
    $finalAutoLogonPassword = $txtFinalPass.Text

    $script:runspace = [runspacefactory]::CreateRunspace()
    $script:runspace.ApartmentState = "STA"
    $script:runspace.ThreadOptions = "ReuseThread"
    $script:runspace.Open()
    $script:runspace.SessionStateProxy.SetVariable("txtLog", $txtLog)
    $script:runspace.SessionStateProxy.SetVariable("lblPhase", $lblPhase)
    $script:runspace.SessionStateProxy.SetVariable("progressPhase", $progressPhase)
    $script:runspace.SessionStateProxy.SetVariable("LogFarben", $LogFarben)
    $script:runspace.SessionStateProxy.SetVariable("ColorTextHi", $ColorTextHi)
    $script:runspace.SessionStateProxy.SetVariable("sharedState", $script:sharedState)
    $script:runspace.SessionStateProxy.SetVariable("UiSprache", $script:UiSprache)
    $script:runspace.SessionStateProxy.SetVariable("UebersetzungExakt", $script:UebersetzungExakt)
    $script:runspace.SessionStateProxy.SetVariable("UebersetzungMuster", $script:UebersetzungMuster)

    $allFuncText = New-Object System.Text.StringBuilder
    [void]$allFuncText.AppendLine(@'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Add-Log {
    param([string]$Message, [string]$Color = "LightGray")
    # Original (deutsch) fuer die Auswertung der Statuszeile behalten,
    # angezeigt wird in der gewaehlten Sprache.
    $Original = $Message
    $Message = Convert-Sprache $Message
    try {
        if ($null -eq $txtLog -or $txtLog.IsDisposed) { return }
        $txtLog.Invoke([Action]{
            if ($txtLog.IsDisposed) { return }
            $timestamp = Get-Date -Format "HH:mm:ss"
            $txtLog.SelectionStart = $txtLog.TextLength
            $farbe = $LogFarben[$Color]
            if (-not $farbe) { $farbe = $ColorTextHi }
            $txtLog.SelectionColor = $farbe
            $txtLog.AppendText("[$timestamp] $Message`r`n")
            $txtLog.ScrollToCaret()
        })
    } catch { }
    # Aktuellen Schritt fuer die Statuszeile merken. Die GUI liest das
    # jede Sekunde aus der synchronisierten Hashtable - kein Log-Spam.
    try {
        $kurz = ($Original -replace "^[\s=]+|[\s=]+$", "").Trim()
        if ($kurz) {
            if ($sharedState.Aktivitaet -ne $kurz) {
                $sharedState.Aktivitaet = $kurz
                $sharedState.AktivitaetSeit = Get-Date
            }
            if ($kurz -match "^\[\d+%\] Installiere \((\d+)/(\d+)\)") {
                $sharedState.UpdatesText = "$($Matches[1])/$($Matches[2])"
            } elseif ($kurz -match "^\[\d+%\] Lade herunter \((\d+)/(\d+)\)") {
                $sharedState.UpdatesText = "$([char]0x2193) $($Matches[1])/$($Matches[2])"
            } elseif ($kurz -match "^Gefundene ausstehende Updates: (\d+)") {
                $sharedState.UpdatesText = "0/$($Matches[1])"
            } elseif ($kurz -match "^Insgesamt installierte Updates: (\d+)") {
                $sharedState.UpdatesText = "$($Matches[1]) $([char]0x2713)"
            }
        }
    } catch { }
}
function Set-Phase {
    param([string]$Name, [int]$Index, [int]$Total)
    try {
        if ($null -eq $lblPhase -or $lblPhase.IsDisposed) { return }
        $sharedState.PhaseRoh = @($Name, $Index, $Total)
        $anzeigeName = Convert-Sprache $Name
        $lblPhase.Invoke([Action]{
            if ($lblPhase.IsDisposed) { return }
            $lblPhase.Text = "Phase $Index/$Total`: $anzeigeName"
            if ($progressPhase -and -not $progressPhase.IsDisposed) {
                $progressPhase.Maximum = $Total
                $progressPhase.Value = [Math]::Min($Index, $Total)
            }
        })
    } catch { }
}
'@)
    foreach ($hilfsFunktion in @("Convert-Sprache", "T", "Invoke-HiveUnload", "Find-WindowsDriveLetter")) {
        [void]$allFuncText.AppendLine("function $hilfsFunktion {")
        [void]$allFuncText.AppendLine((Get-Item "function:$hilfsFunktion").ScriptBlock.ToString())
        [void]$allFuncText.AppendLine("}")
    }
    [void]$allFuncText.AppendLine("function Reset-SysprepRearmCounter {")
    [void]$allFuncText.AppendLine((Get-Item "function:Reset-SysprepRearmCounter").ScriptBlock.ToString())
    [void]$allFuncText.AppendLine("}")
    [void]$allFuncText.AppendLine("function Start-AutoUpdate {")
    [void]$allFuncText.AppendLine((Get-Item "function:Start-AutoUpdate").ScriptBlock.ToString())
    [void]$allFuncText.AppendLine("}")

    $script:powershell = [powershell]::Create()
    $script:powershell.Runspace = $script:runspace
    [void]$script:powershell.AddScript($allFuncText.ToString())
    [void]$script:powershell.AddScript('
        param($VhdxPathList, $MemoryGB, $MaxUpdateRounds, $UseSafeCopy, $SetupFinalAutoLogon, $FinalAutoLogonUser, $FinalAutoLogonPassword, $RemoveAllLocalUsers, $KeepBackup)
        $logRef = { param($m, $c) Add-Log -Message $m -Color $c }
        $cancelRef = { return $sharedState.CancelRequested }

        $pfadeGesamt = @($VhdxPathList)
        $gesamtAnzahl = $pfadeGesamt.Count
        $mehrereAbbilder = $gesamtAnzahl -gt 1
        $ergebnisListe = @()
        $nr = 0
        foreach ($einzelPfad in $pfadeGesamt) {
            $nr++
            if ($mehrereAbbilder) {
                & $logRef "########## Abbild $nr von $gesamtAnzahl`: $einzelPfad ##########" "Cyan"
            }
            if ($sharedState.QueueStatus) {
                $sharedState.QueueStatus[[string]$einzelPfad] = "Laeuft"
                $sharedState.QueueVersion = [int]$sharedState.QueueVersion + 1
            }
            if (-not (Test-Path -LiteralPath $einzelPfad)) {
                if ($sharedState.QueueStatus) {
                    $sharedState.QueueStatus[[string]$einzelPfad] = "Fehler"
                    $sharedState.QueueVersion = [int]$sharedState.QueueVersion + 1
                }
                & $logRef "Abbild nicht gefunden - wird uebersprungen." "Red"
                $ergebnisListe += [PSCustomObject]@{ Pfad = $einzelPfad; Success = $false; Cancelled = $false; Error = "Datei nicht gefunden" }
                continue
            }
            # Fuer eine einzelne Datei bleibt die Phasenanzeige exakt wie bisher
            # ("Phase X/8: <Name>"). Erst bei mehreren Abbildern wird ihr ein
            # "Abbild N von M - " vorangestellt, damit klar ist, an welchem
            # Abbild der 7-Phasen-Fortschritt gerade haengt.
            if ($mehrereAbbilder) {
                $einzelPhaseRef = { param($n, $i, $t) Set-Phase -Name "Abbild $nr/$gesamtAnzahl - $n" -Index $i -Total $t }
            } else {
                $einzelPhaseRef = { param($n, $i, $t) Set-Phase -Name $n -Index $i -Total $t }
            }
            $r = Start-AutoUpdate -VhdxPath $einzelPfad -MemoryGB $MemoryGB -MaxUpdateRounds $MaxUpdateRounds -UseSafeCopy $UseSafeCopy -SetupFinalAutoLogon $SetupFinalAutoLogon -FinalAutoLogonUser $FinalAutoLogonUser -FinalAutoLogonPassword $FinalAutoLogonPassword -RemoveAllLocalUsers $RemoveAllLocalUsers -KeepBackup $KeepBackup -LogFunc $logRef -PhaseFunc $einzelPhaseRef -ShouldCancel $cancelRef
            $ergebnisListe += [PSCustomObject]@{ Pfad = $einzelPfad; Success = [bool]$r.Success; Cancelled = [bool]$r.Cancelled; Error = $r.Error }
            if ($sharedState.QueueStatus) {
                $sharedState.QueueStatus[[string]$einzelPfad] = $(if ([bool]$r.Success) { "Fertig" } elseif ([bool]$r.Cancelled) { "Abbruch" } else { "Fehler" })
                $sharedState.QueueVersion = [int]$sharedState.QueueVersion + 1
            }
            # Bei Abbruch durch den Nutzer werden die restlichen Abbilder der
            # Warteschlange NICHT mehr angefasst.
            if ([bool]$r.Cancelled) { break }
        }

        $anzOk = @($ergebnisListe | Where-Object { $_.Success }).Count
        $anzFehler = @($ergebnisListe | Where-Object { -not $_.Success }).Count
        $anzAbgebrochen = @($ergebnisListe | Where-Object { $_.Cancelled }).Count

        [PSCustomObject]@{
            TotalCount   = $gesamtAnzahl
            SuccessCount = $anzOk
            FailureCount = $anzFehler
            Cancelled    = ($anzAbgebrochen -gt 0)
            Results      = $ergebnisListe
        }
    ').AddParameters(@{
        VhdxPathList            = $vhdxPathList
        MemoryGB                = $memGb
        MaxUpdateRounds         = $maxRounds
        UseSafeCopy             = [bool]$useSafeCopy
        SetupFinalAutoLogon     = [bool]$setupFinalAutoLogon
        FinalAutoLogonUser      = $finalAutoLogonUser
        FinalAutoLogonPassword  = $finalAutoLogonPassword
        RemoveAllLocalUsers     = [bool]$removeAllUsers
        KeepBackup              = [bool]$keepBackup
    })

    Add-Log "Hintergrund-Task gestartet, warte auf Fortschritt..." "Gray"
    # WICHTIG: Der Timer liegt im Skript-Scope. Der Tick-Handler laeuft
    # NACH dem Ende dieses Click-Handlers - lokale Variablen von hier sind
    # dort nicht mehr sichtbar (gleiches Problem wie bei Add_Paint).
    # Der Fortschritt steht in der Statuszeile unter der Phase - der Timer
    # schreibt bewusst NICHTS mehr ins Protokoll.
    if ($script:timer) {
        try { $script:timer.Stop(); $script:timer.Dispose() } catch { }
    }
    $script:asyncResult = $script:powershell.BeginInvoke()

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 500
    $script:timer.Add_Tick({
        try {
            if ($script:tickHandled) { return }

            if (-not $script:asyncResult) {
                Add-Log "WARNUNG: asyncResult ist NULL im Timer-Tick - breche Polling ab." "Red"
                $script:tickHandled = $true
                try { $script:timer.Stop() } catch { }
                return
            }

            if ($script:asyncResult.IsCompleted) {
                $script:tickHandled = $true
                try { $script:timer.Stop() } catch { }

                if (-not $script:powershell) {
                    Add-Log "WARNUNG: powershell-Objekt ist NULL beim Abschluss - Ergebnis kann nicht gelesen werden." "Red"
                } else {
                    $runResult = $null
                    try {
                        $runResult = $script:powershell.EndInvoke($script:asyncResult)
                    } catch {
                        Add-Log "Unerwarteter Fehler beim Lesen des Ergebnisses (EndInvoke): $($_.Exception.Message)" "Red"
                    }
                    if ($runResult -is [array]) {
                        Add-Log "(Hinweis: Hintergrund-Task lieferte mehrere Werte zurueck, verwende den letzten.)" "DarkGray"
                        $runResult = $runResult | Select-Object -Last 1
                    }
                    # $runResult ist jetzt ein Aggregat ueber (potenziell) mehrere
                    # Abbilder (siehe Hintergrund-Skript oben): TotalCount,
                    # SuccessCount, FailureCount, Cancelled, Results[].
                    $totalCount = 0
                    $successCount = 0
                    $failureCount = 0
                    $wasCancelled = $false
                    try {
                        if ($runResult) {
                            $totalCount = [int]$runResult.TotalCount
                            $successCount = [int]$runResult.SuccessCount
                            $failureCount = [int]$runResult.FailureCount
                            $wasCancelled = [bool]$runResult.Cancelled
                        }
                    } catch { }

                    if ($wasCancelled) {
                        try { Add-Log "=== Vorgang wurde abgebrochen ($successCount von $totalCount Abbildern erfolgreich abgeschlossen) ===" "Orange" } catch { }
                        try { Set-Mood -State "Cancelled" } catch { }
                    } elseif ($totalCount -gt 0 -and $successCount -eq $totalCount) {
                        try { Add-Log "=== ERFOLGREICH ABGESCHLOSSEN ===" "Lime" } catch { }
                        try { Set-Mood -State "Success" } catch { }
                        try {
                            $erfolgsText = if ($totalCount -le 1) {
                                "Die VHDX wurde erfolgreich aktualisiert und neu syspreppt."
                            } else {
                                "$successCount von $totalCount Abbildern wurden erfolgreich aktualisiert und neu syspreppt."
                            }
                            $Meldung.Show($erfolgsText, "Fertig", "OK", "Information") | Out-Null
                        } catch { }
                    } elseif ($successCount -gt 0) {
                        try { Add-Log "=== Teilweise abgeschlossen: $successCount von $totalCount Abbildern erfolgreich, $failureCount fehlgeschlagen ===" "Orange" } catch { }
                        try { Set-Mood -State "Error" } catch { }
                        try {
                            $Meldung.Show("$successCount von $totalCount Abbildern wurden erfolgreich aktualisiert. $failureCount fehlgeschlagen - siehe Protokoll oben.", "Teilweise abgeschlossen", "OK", "Warning") | Out-Null
                        } catch { }
                    } else {
                        try { Add-Log "=== Vorgang mit Fehler beendet - siehe Protokoll oben ===" "Red" } catch { }
                        try { Set-Mood -State "Error" } catch { }
                    }

                    try {
                        if ($script:powershell.Streams -and $script:powershell.Streams.Error.Count -gt 0) {
                            Add-Log "--- Zusaetzliche Fehler im Error-Stream des Hintergrund-Tasks ---" "Red"
                            foreach ($errItem in $script:powershell.Streams.Error) { Add-Log "  $errItem" "Red" }
                        }
                    } catch { }
                }
                if ($script:powershell) {
                    try { $script:powershell.Dispose() } catch { }
                }
                if ($script:runspace) {
                    try { $script:runspace.Close() } catch { }
                    try { $script:runspace.Dispose() } catch { }
                }
                $script:isRunning = $false
                try { $btnStart.Enabled = $true } catch { }
                try { $btnCancel.Enabled = $false } catch { }
                try { $btnSelfTest.Enabled = $true } catch { }
                try { $btnResetRearm.Enabled = $true } catch { }
                try { $btnBrowseVhdx.Enabled = $true } catch { }
                try { $numRam.Enabled = $true } catch { }
                try { $numRounds.Enabled = $true } catch { }
                try { $chkSafeCopy.Enabled = $true } catch { }
                try { $chkRemoveUsers.Enabled = $true } catch { }
                try { $chkKeepBackup.Enabled = $chkSafeCopy.Checked } catch { }
                try { $chkFinalAutoLogon.Enabled = $true } catch { }
                try { $txtFinalUser.Enabled = $chkFinalAutoLogon.Checked } catch { }
                try { $txtFinalPass.Enabled = $chkFinalAutoLogon.Checked } catch { }
                try { $lstVhdxQueue.Enabled = $true } catch { }
                try { $btnAddQueue.Enabled = $true } catch { }
                try { $btnRemoveQueue.Enabled = $true } catch { }
                try { $lblPhase.Text = "Bereit." } catch { }
                try { $lblAktivitaet.Text = "" } catch { }
                $script:sharedState.Aktivitaet = $null
                try { $progressPhase.Value = 0 } catch { }
            }
        } catch {
            $script:tickHandled = $true
            try {
                Add-Log "KRITISCHER FEHLER im Timer-Handler: $($_.Exception.Message)" "Red"
                Add-Log "Stack: $($_.ScriptStackTrace)" "Red"
            } catch { }
            try { $script:timer.Stop() } catch { }
            $script:isRunning = $false
            try { $btnStart.Enabled = $true } catch { }
            try { $btnCancel.Enabled = $false } catch { }
            try { $btnSelfTest.Enabled = $true } catch { }
            try { $btnResetRearm.Enabled = $true } catch { }
            try { $btnBrowseVhdx.Enabled = $true } catch { }
            try { $numRam.Enabled = $true } catch { }
            try { $numRounds.Enabled = $true } catch { }
            try { $chkSafeCopy.Enabled = $true } catch { }
            try { $chkRemoveUsers.Enabled = $true } catch { }
            try { $chkKeepBackup.Enabled = $chkSafeCopy.Checked } catch { }
            try { $chkFinalAutoLogon.Enabled = $true } catch { }
            try { $txtFinalUser.Enabled = $chkFinalAutoLogon.Checked } catch { }
            try { $txtFinalPass.Enabled = $chkFinalAutoLogon.Checked } catch { }
            try { $lstVhdxQueue.Enabled = $true } catch { }
            try { $btnAddQueue.Enabled = $true } catch { }
            try { $btnRemoveQueue.Enabled = $true } catch { }
        }
    })
    $script:timer.Start()
})

$btnCancel.Add_Click({
    $confirmResult = $Meldung.Show(
        "Wirklich abbrechen? Die temporäre VM wird automatisch aufgeräumt. Bei aktiver Sicherheitskopie bleibt dein Original unangetastet.",
        "Abbrechen bestätigen", "YesNo", "Question")
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $script:sharedState.CancelRequested = $true
    Add-Log "Abbruch angefordert - wird nach dem aktuellen Schritt wirksam..." "Orange"
    $btnCancel.Enabled = $false
})

# --- Schliessen per Alt+F4/Taskleiste waehrend eines Laufs abfangen --------
$script:closeConfirmed = $false
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:closeConfirmed) { return }
    $laeuft = $script:isRunning -and -not ($script:asyncResult -and $script:asyncResult.IsCompleted)
    if (-not $laeuft) { return }
    $antwort = $Meldung.Show(
        "Ein Auto-Update läuft noch. Wenn du jetzt schließt, bleibt evtl. eine temporäre VM zurück, die du manuell im Hyper-V-Manager entfernen musst. Trotzdem schließen?",
        "Update läuft noch", "YesNo", "Warning")
    if ($antwort -ne [System.Windows.Forms.DialogResult]::Yes) {
        $e.Cancel = $true
        return
    }
    $script:sharedState.CancelRequested = $true
})

# --- Vorhandenen Zeitplan laden (Uhrzeit + Wochentage vorbelegen) ---------
try {
    $aufgabeXml = & schtasks.exe /Query /TN "AutoUpdate-VHDX" /XML 2>$null
    if ($LASTEXITCODE -eq 0 -and $aufgabeXml) {
        [xml]$aufgabe = ($aufgabeXml -join "`n")
        $ns = New-Object System.Xml.XmlNamespaceManager($aufgabe.NameTable)
        $ns.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        $startKnoten = $aufgabe.SelectSingleNode("//t:CalendarTrigger/t:StartBoundary", $ns)
        if ($startKnoten) { $txtTime.Text = ([datetime]$startKnoten.InnerText).ToString("HH:mm") }
        $tageKnoten = $aufgabe.SelectSingleNode("//t:CalendarTrigger/t:ScheduleByWeek/t:DaysOfWeek", $ns)
        if ($tageKnoten) {
            foreach ($cb in $chkTage) { $cb.Checked = [bool]$tageKnoten.SelectSingleNode("t:$($cb.Tag.Xml)", $ns) }
        }
        $aktiveTage = @($chkTage | Where-Object { $_.Checked } | ForEach-Object { T $_.Tag.Kurz $_.Tag.En })
        $anzeige = if ($aktiveTage.Count -eq 7) { T "täglich" "daily" } else { (T "jeden " "every ") + ($aktiveTage -join ", ") }
        $script:zeitplanHinweis = "Vorhandener Zeitplan: $anzeige um $($txtTime.Text) Uhr."
    }
} catch { }

# --- Sprachumschalter DE / EN neben dem Tool-Namen ------------------------
$script:sharedState.Sprache = $script:UiSprache
function New-SprachKnopf {
    param([string]$Text, [int]$X)
    $k = New-Object System.Windows.Forms.Label
    $k.Text = $Text
    $k.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $k.TextAlign = "MiddleCenter"
    $k.Location = New-Object System.Drawing.Point($X, 12)
    $k.Size = New-Object System.Drawing.Size(30, 20)
    $k.Anchor = "Top"
    $k.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-RundeEcken -Control $k -Radius 8
    $titleBar.Controls.Add($k)
    return $k
}
$btnSpracheDe = New-SprachKnopf -Text "DE" -X 566
$btnSpracheEn = New-SprachKnopf -Text "EN" -X 598
$tipSprache = New-Object System.Windows.Forms.ToolTip

# Alle festen Oberflaechentexte (deutsch) - werden beim Umschalten neu gesetzt.
$script:UiTexte = @(
    @{ C = $lblSubtitle;       T = "Windows Update vollautomatisch in einer syspreppten VHDX" },
    @{ C = $cardSource.Tag;    T = "Abbild & Zeitplan"; Gross = $true },
    @{ C = $lblVhdxSub;        T = "VHDX-Datei" },
    @{ C = $btnBrowseVhdx;     T = "Durchsuchen" },
    @{ C = $lblTime;           T = "Zeitplan (Uhrzeit)" },
    @{ C = $btnSchedule;       T = "Zeitplan einrichten" },
    @{ C = $btnScheduleRemove; T = "Zeitplan entfernen" },
    @{ C = $lblTage;           T = "Wochentage (alle = täglich)" },
    @{ C = $lblVhdxQueue;      T = "Warteschlange (mehrere Abbilder nacheinander)" },
    @{ C = $btnAddQueue;       T = "Hinzufügen" },
    @{ C = $btnRemoveQueue;    T = "Entfernen" },
    @{ C = $cardSettings.Tag;  T = "Einstellungen"; Gross = $true },
    @{ C = $lblRam;            T = "RAM für VM (GB)" },
    @{ C = $lblRounds;         T = "Max. Update-Runden" },
    @{ C = $lblRoundsHint;     T = "Nach jeder Runde wird neu gestartet und erneut geprüft, bis zwei`nPrüfungen nacheinander nichts mehr finden." },
    @{ C = $chkSafeCopy;       T = "Sicherheitskopie verwenden (Original bleibt geschützt)" },
    @{ C = $chkRemoveUsers;    T = "Alle lokalen Benutzer entfernen (sauberes Image)" },
    @{ C = $lblSwitch;         T = "Ein Switch mit Internetzugang wird automatisch gewählt." },
    @{ C = $chkKeepBackup;     T = "Altes Image nach Erfolg als .bak behalten" },
    @{ C = $cardAutoLogon.Tag; T = "Automatischer Login (fertiges Abbild)"; Gross = $true },
    @{ C = $chkFinalAutoLogon; T = "Nach Sysprep automatischen Login einrichten - überspringt Sprachauswahl/OOBE beim nächsten Boot" },
    @{ C = $lblFinalUser;      T = "Benutzername" },
    @{ C = $lblFinalPass;      T = "Passwort" },
    @{ C = $lblFinalWarn;      T = "Nur für Test-/Referenz-Images: Passwort liegt danach nur leicht verschleiert in der VHDX." },
    @{ C = $kachelBild.Title;  T = "Abbild"; Gross = $true },
    @{ C = $kachelUpdates.Title; T = "Updates"; Gross = $true },
    @{ C = $kachelZeit.Title;  T = "Laufzeit"; Gross = $true },
    @{ C = $cardLog.Tag;       T = "Protokoll"; Gross = $true },
    @{ C = $btnStart;          T = "Auto-Update starten" },
    @{ C = $btnCancel;         T = "Abbrechen" },
    @{ C = $btnResetRearm;     T = "Rearm-Zähler zurücksetzen" },
    @{ C = $btnSelfTest;       T = "Selbsttest" },
    @{ C = $btnClose;          T = "Schließen" }
)
$script:UiTooltips = @(
    @{ Tip = $tipRemoveUsers; C = $chkRemoveUsers; T = "Entfernt vor Sysprep alle nicht eingebauten lokalen Benutzer samt Profil`nund alle verwaisten Profilordner (Konten, die es nicht mehr gibt).`nDie Konten Administrator, Gast usw. bleiben erhalten. Ohne Haken wird nur das Temp-Konto 'AutoUpdate' entfernt." },
    @{ Tip = $tipKeepBackup;  C = $chkKeepBackup;  T = "Ohne Haken wird das alte Image nach einem ERFOLGREICHEN Lauf geloescht.`nWaehrend des Laufs bleibt das Original trotzdem geschuetzt (Sicherheitskopie)." },
    @{ Tip = $tipSprache;     C = $btnSpracheDe;   T = "Sprache: Deutsch / Englisch" },
    @{ Tip = $tipSprache;     C = $btnSpracheEn;   T = "Sprache: Deutsch / Englisch" }
)

function Set-UiSprache {
    param([ValidateSet("de", "en")][string]$Sprache)
    $script:UiSprache = $Sprache
    $script:sharedState.Sprache = $Sprache
    foreach ($eintrag in $script:UiTexte) {
        try {
            if (-not $eintrag.C) { continue }
            $text = Convert-Sprache $eintrag.T
            if ($eintrag.Gross) { $text = $text.ToUpper() }
            $eintrag.C.Text = $text
        } catch { }
    }
    foreach ($eintrag in $script:UiTooltips) {
        try { $eintrag.Tip.SetToolTip($eintrag.C, (Convert-Sprache $eintrag.T)) } catch { }
    }
    foreach ($cb in $chkTage) { try { $cb.Text = T $cb.Tag.Kurz $cb.Tag.En } catch { } }
    try { $lstVhdxQueue.Invalidate() } catch { }
    # Statusanzeigen neu setzen
    try { Set-Mood -State $(if ($script:letzterMood) { $script:letzterMood } else { "Idle" }) } catch { }
    try {
        if ($script:isRunning -and $script:sharedState.PhaseRoh) {
            $pr = $script:sharedState.PhaseRoh
            $lblPhase.Text = "Phase $($pr[1])/$($pr[2]): $(Convert-Sprache $pr[0])"
        } elseif (-not $script:isRunning) {
            $lblPhase.Text = Convert-Sprache "Bereit."
        }
    } catch { }
    # Umschalter hervorheben
    $aktiv = @{ $true = $ColorAccent; $false = [System.Drawing.Color]::FromArgb(238, 241, 243) }
    $btnSpracheDe.BackColor = $aktiv[$Sprache -eq "de"]
    $btnSpracheDe.ForeColor = $(if ($Sprache -eq "de") { [System.Drawing.Color]::White } else { $ColorTextMid })
    $btnSpracheEn.BackColor = $aktiv[$Sprache -eq "en"]
    $btnSpracheEn.ForeColor = $(if ($Sprache -eq "en") { [System.Drawing.Color]::White } else { $ColorTextMid })
}
$btnSpracheDe.Add_Click({ if ($script:UiSprache -ne "de") { Set-UiSprache -Sprache "de"; Save-Sprache -Sprache "de" } })
$btnSpracheEn.Add_Click({ if ($script:UiSprache -ne "en") { Set-UiSprache -Sprache "en"; Save-Sprache -Sprache "en" } })
Set-UiSprache -Sprache $script:UiSprache

# --- Initialer Status ------------------------------------------------------
try { Write-AutoUpdateEvent -Message "AutoUpdate VHDX $ToolVersion gestartet (interaktiver Modus)." -Level "Information" -EventId 1000 } catch { }
Add-Log "Bereit. Tipp: Klicke zuerst auf 'Selbsttest', um zu prüfen, ob Hyper-V korrekt eingerichtet ist." "Gray"
if ($script:zeitplanHinweis) { Add-Log $script:zeitplanHinweis "Gray" }

Set-RundeEcken -Control $form -Radius 14
[void]$form.ShowDialog()
