# Konfiguracja Edge Kiosk

Uruchom PowerShell **jako administrator**, przy **wylogowanym** koncie kiosku (`kioskUser0`), w katalogu `scripts`:

```powershell
powershell -ExecutionPolicy Bypass -File .\configure-edge-kiosk.ps1
```

Jesli konto kiosku nie istnieje, skrypt tworzy je (bez hasla, grupa Uzytkownicy) razem z profilem. Istniejace konto jest uzywane bez zmian, poza nazwa wyswietlana (`$KioskDisplayName`, domyslnie `Umiem`).

Skrypt ustawia tez tryb kiosku (Assigned Access): po zalogowaniu na konto kiosku otwiera sie Edge na pelnym ekranie ze strona `$KioskStartUrl`. Wyjscie z kiosku: Ctrl+Alt+Del -> Wyloguj.

Liste dozwolonych stron edytuj w sekcji `KONFIGURACJA` na poczatku skryptu.
