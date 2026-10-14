
# ============================================================
# STREFA NAUKI - MICROSOFT EDGE KIOSK
# Windows 11 Pro
#
# Uruchom jako administrator przy WYLOGOWANYM kiosku.
# ============================================================


# ============================================================
# KONFIGURACJA - EDYTUJ TYLKO TUTAJ
# ============================================================

# Dozwolone strony internetowe.
# https://.host = dokladny host, bez subdomen.
# Wszystko spoza tej listy bedzie blokowane.

$AllowedUrls = @(
    'https://.start.devforce.pl'
    'https://.umiem.devforce.pl'
    'https://.agilefingers.com'
    'https://www.edclub.com'

    # Dodatkowe strony:
    # 'https://.typinggameskids.com'
)

# Konto Windows przypisane do kiosku
$KioskUser = 'kioskUser0'

# Strony z automatycznym dostepem do mikrofonu
$MicrophoneUrls = @(
    'https://umiem.devforce.pl/'
)


# ============================================================
# IMPLEMENTACJA - NIE WYMAGA ZMIAN
# ============================================================

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 1. Weryfikacja uprawnien
# ------------------------------------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "Uruchom PowerShell jako administrator."
}

if ($AllowedUrls.Count -eq 0) {
    throw "Lista AllowedUrls nie moze byc pusta."
}

if ($AllowedUrls.Count -ne @($AllowedUrls | Select-Object -Unique).Count) {
    throw "Lista AllowedUrls zawiera duplikaty."
}

# ------------------------------------------------------------
# 2. Kontrola globalnych polityk Edge
# ------------------------------------------------------------

# Polityki HKLM moga miec pierwszenstwo przed HKCU.
# Nie zmieniamy konfiguracji innych uzytkownikow.

foreach ($policy in @('URLBlocklist', 'URLAllowlist')) {

    $machineKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SOFTWARE\Policies\Microsoft\Edge\$policy"
    )

    if ($null -ne $machineKey) {
        try {
            if ($machineKey.ValueCount -gt 0) {
                throw "Istnieje globalna polityka $policy. " +
                      "Sprawdz HKLM przed kontynuowaniem."
            }
        }
        finally {
            $machineKey.Close()
        }
    }
}

# ------------------------------------------------------------
# 3. Znajdz profil konta kiosku
# ------------------------------------------------------------

$user = Get-LocalUser -Name $KioskUser -ErrorAction Stop

$profile = Get-CimInstance Win32_UserProfile |
    Where-Object { $_.SID -eq $user.SID.Value }

if (-not $profile) {
    throw "Nie znaleziono profilu konta $KioskUser."
}

if ($profile.Loaded) {
    throw "Wyloguj konto $KioskUser przed uruchomieniem."
}

$ntuser = Join-Path $profile.LocalPath 'NTUSER.DAT'

if (-not (Test-Path $ntuser)) {
    throw "Nie znaleziono pliku NTUSER.DAT."
}

Write-Host "Profil kiosku: $($profile.LocalPath)"

# ------------------------------------------------------------
# 4. Zaladuj rejestr konta kiosku
# ------------------------------------------------------------

$hiveName = 'StrefaNaukiKiosk'
$hivePath = "HKU\$hiveName"

& reg.exe load $hivePath $ntuser | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Nie udalo sie zaladowac rejestru kiosku."
}

try {

    $registryPath = "$hiveName\SOFTWARE\Policies\Microsoft\Edge"

    $edge = [Microsoft.Win32.Registry]::Users.CreateSubKey(
        $registryPath
    )

    if ($null -eq $edge) {
        throw "Nie udalo sie otworzyc polityk Edge."
    }

    try {

        # ----------------------------------------------------
        # 5. BLOKADA WSZYSTKICH STRON
        # ----------------------------------------------------

        $blocklist = $edge.CreateSubKey('URLBlocklist')

        try {
            # Najpierw ustawiamy blokade.
            $blocklist.SetValue(
                '1',
                '*',
                [Microsoft.Win32.RegistryValueKind]::String
            )

            # Usuwamy dodatkowe stare wpisy blokady.
            foreach ($name in $blocklist.GetValueNames()) {
                if ($name -ne '1') {
                    $blocklist.DeleteValue($name, $false)
                }
            }
        }
        finally {
            $blocklist.Close()
        }

        Write-Host "`nInternet: domyslnie ZABLOKOWANY" `
            -ForegroundColor Yellow

        # ----------------------------------------------------
        # 6. LISTA DOZWOLONYCH STRON
        # ----------------------------------------------------

        # Usun wszystkie poprzednie wyjatki.
        $edge.DeleteSubKeyTree('URLAllowlist', $false)

        $allowlist = $edge.CreateSubKey('URLAllowlist')

        try {

            for ($i = 0; $i -lt $AllowedUrls.Count; $i++) {

                $url = $AllowedUrls[$i]

                $allowlist.SetValue(
                    [string]($i + 1),
                    $url,
                    [Microsoft.Win32.RegistryValueKind]::String
                )

                Write-Host "DOZWOLONO: $url" `
                    -ForegroundColor Green
            }

        }
        finally {
            $allowlist.Close()
        }

        # ----------------------------------------------------
        # 7. AUTOMATYCZNY DOSTEP DO MIKROFONU
        # ----------------------------------------------------

        $edge.DeleteSubKeyTree(
            'AudioCaptureAllowedUrls',
            $false
        )

        $audioUrls = $edge.CreateSubKey(
            'AudioCaptureAllowedUrls'
        )

        try {

            for ($i = 0; $i -lt $MicrophoneUrls.Count; $i++) {

                $audioUrls.SetValue(
                    [string]($i + 1),
                    $MicrophoneUrls[$i],
                    [Microsoft.Win32.RegistryValueKind]::String
                )
            }

        }
        finally {
            $audioUrls.Close()
        }

        # Zezwol na uzycie mikrofonu.
        $edge.SetValue(
            'AudioCaptureAllowed',
            1,
            [Microsoft.Win32.RegistryValueKind]::DWord
        )

        # ----------------------------------------------------
        # 8. AUTOPLAY
        # ----------------------------------------------------

        $edge.SetValue(
            'AutoplayAllowed',
            1,
            [Microsoft.Win32.RegistryValueKind]::DWord
        )

        # ----------------------------------------------------
        # 9. ZABEZPIECZENIA WYSZUKIWANIA
        # ----------------------------------------------------

        # Wylacz "Wyszukaj w sieci" z menu kontekstowego,
        # jesli polityka jest stosowana przez Edge.
        $edge.SetValue(
            'DefaultSearchProviderContextMenuAccessAllowed',
            0,
            [Microsoft.Win32.RegistryValueKind]::DWord
        )

        # Wylacz wyszukiwanie w panelu bocznym Edge.
        $edge.SetValue(
            'SearchInSidebarEnabled',
            2,
            [Microsoft.Win32.RegistryValueKind]::DWord
        )

        # ----------------------------------------------------
        # 10. PODSUMOWANIE
        # ----------------------------------------------------

        Write-Host "`nZapisano konfiguracje Edge." `
            -ForegroundColor Green

        Write-Host "AudioCaptureAllowed: 1"
        Write-Host "AutoplayAllowed: 1"
        Write-Host "ContextMenuSearch: 0"
        Write-Host "SearchInSidebarEnabled: 2"

        Write-Host "`nMikrofon dozwolony dla:"
        foreach ($url in $MicrophoneUrls) {
            Write-Host "  $url"
        }

    }
    finally {
        $edge.Close()
    }

}
finally {

    # --------------------------------------------------------
    # 11. Zwolnij rejestr kiosku
    # --------------------------------------------------------

    & reg.exe unload $hivePath | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Nie udalo sie zwolnic rejestru!"
        Write-Warning "Zrestartuj Windows przed ponowna proba."
    }
}

Write-Host "`n========================================"
Write-Host " STREFA NAUKI - KONFIGURACJA ZAPISANA"
Write-Host "========================================"
Write-Host "Konto: $KioskUser"
Write-Host "Dozwolone strony: $($AllowedUrls.Count)"
Write-Host "Pozostale strony: ZABLOKOWANE"
Write-Host "Mikrofon Umiem!: skonfigurowany"
Write-Host "Autoplay: skonfigurowany"
Write-Host "========================================"
Write-Host "Uruchom kiosk i sprawdz dzialanie polityk." `
    -ForegroundColor Cyan
