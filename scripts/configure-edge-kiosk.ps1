
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
    'https://.edclub.devforce.pl'
    'https://www.edclub.com'

    # Dodatkowe strony:
    # 'https://.typinggameskids.com'
)

# Konto Windows przypisane do kiosku
$KioskUser = 'kioskUser0'

# Nazwa konta widoczna na ekranie logowania
$KioskDisplayName = 'Umiem'

# Strona otwierana w kiosku (musi pasowac do AllowedUrls)
$KioskStartUrl = 'https://start.devforce.pl/'

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

# Sort-Object -Unique ignoruje wielkosc liter, tak jak Edge.
if ($AllowedUrls.Count -ne @($AllowedUrls | Sort-Object -Unique).Count) {
    throw "Lista AllowedUrls zawiera duplikaty."
}

# ------------------------------------------------------------
# 2. Kontrola globalnych polityk Edge
# ------------------------------------------------------------

# Polityki HKLM moga miec pierwszenstwo przed HKCU.
# Nie zmieniamy konfiguracji innych uzytkownikow.

$machineEdge = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SOFTWARE\Policies\Microsoft\Edge'
)

if ($null -ne $machineEdge) {
    try {
        foreach ($policy in @(
            'URLBlocklist'
            'URLAllowlist'
            'AudioCaptureAllowedUrls'
        )) {
            $machineKey = $machineEdge.OpenSubKey($policy)

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

        foreach ($policy in @(
            'AudioCaptureAllowed'
            'AutoplayAllowed'
            'DefaultSearchProviderContextMenuAccessAllowed'
            'SearchInSidebarEnabled'
        )) {
            if ($null -ne $machineEdge.GetValue($policy)) {
                throw "Istnieje globalna polityka $policy. " +
                      "Sprawdz HKLM przed kontynuowaniem."
            }
        }
    }
    finally {
        $machineEdge.Close()
    }
}

# ------------------------------------------------------------
# 3. Znajdz profil konta kiosku
# ------------------------------------------------------------

$user = Get-LocalUser -Name $KioskUser -ErrorAction SilentlyContinue

if (-not $user) {
    # Konto kiosku nie ma hasla - logowanie jednym kliknieciem.
    $user = New-LocalUser -Name $KioskUser -NoPassword -AccountNeverExpires

    # SID grupy Uzytkownicy - dziala w kazdej wersji jezykowej Windows.
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user

    Write-Host "Utworzono konto: $KioskUser" -ForegroundColor Green
}

Set-LocalUser -InputObject $user -FullName $KioskDisplayName

$userProfile = Get-CimInstance Win32_UserProfile |
    Where-Object { $_.SID -eq $user.SID.Value }

if (-not $userProfile) {
    # Profil (i NTUSER.DAT) powstaje normalnie przy pierwszym logowaniu.
    Add-Type -Namespace Win32 -Name UserEnv -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode)]
public static extern int CreateProfile(
    string pszUserSid, string pszUserName,
    System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@

    $profilePath = New-Object System.Text.StringBuilder 260
    $hr = [Win32.UserEnv]::CreateProfile(
        $user.SID.Value, $KioskUser, $profilePath, 260
    )

    if ($hr -ne 0) {
        throw ("Nie udalo sie utworzyc profilu konta $KioskUser " +
               "(HRESULT 0x{0:X8})." -f $hr)
    }

    Write-Host "Utworzono profil: $profilePath" -ForegroundColor Green

    $userProfile = Get-CimInstance Win32_UserProfile |
        Where-Object { $_.SID -eq $user.SID.Value }
}

if (-not $userProfile) {
    throw "Nie znaleziono profilu konta $KioskUser."
}

if ($userProfile.Loaded) {
    throw "Wyloguj konto $KioskUser przed uruchomieniem."
}

$ntuser = Join-Path $userProfile.LocalPath 'NTUSER.DAT'

if (-not (Test-Path $ntuser)) {
    throw "Nie znaleziono pliku NTUSER.DAT."
}

Write-Host "Profil kiosku: $($userProfile.LocalPath)"

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

        # Usun poprzednie wpisy blokady.
        $edge.DeleteSubKeyTree('URLBlocklist', $false)

        $blocklist = $edge.CreateSubKey('URLBlocklist')

        try {
            $blocklist.SetValue(
                '1',
                '*',
                [Microsoft.Win32.RegistryValueKind]::String
            )
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

# ------------------------------------------------------------
# 12. TRYB KIOSKU (ASSIGNED ACCESS): EDGE NA PELNYM EKRANIE
# ------------------------------------------------------------

$edgeExe = Join-Path ${env:ProgramFiles(x86)} `
    'Microsoft\Edge\Application\msedge.exe'

if (-not (Test-Path $edgeExe)) {
    throw "Nie znaleziono Microsoft Edge: $edgeExe"
}

$edgeArgs = [Security.SecurityElement]::Escape(
    "--kiosk $KioskStartUrl --edge-kiosk-type=fullscreen"
)
$xmlUser = [Security.SecurityElement]::Escape($KioskUser)

# Format wg learn.microsoft.com/windows/configuration/assigned-access/examples
$assignedAccessXml = @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config" xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config" xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="{6E9B0E8B-6C1A-4C1E-9E33-5B7C2B1D4A10}">
      <KioskModeApp v4:ClassicAppPath="%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" v4:ClassicAppArguments="$edgeArgs" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <Account>$xmlUser</Account>
      <DefaultProfile Id="{6E9B0E8B-6C1A-4C1E-9E33-5B7C2B1D4A10}" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@

# Mostek WMI MDM dziala tylko jako SYSTEM, wiec uruchamiamy go
# jednorazowym zadaniem harmonogramu (bez psexec).
# Losowa nazwa - uzytkownik nie moze przygotowac pliku wczesniej.
$aaLog = "$env:windir\Temp\StrefaNauki-AA-$([guid]::NewGuid()).log"
$aaScript = @'
$ErrorActionPreference = 'Stop'
try {
    $obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess'
    $obj.Configuration = '__CONFIG__'
    Set-CimInstance -CimInstance $obj
}
catch {
    $_ | Out-File -FilePath '__LOG__' -Encoding utf8
    exit 1
}
'@.Replace(
    '__CONFIG__', [Net.WebUtility]::HtmlEncode($assignedAccessXml)
).Replace('__LOG__', $aaLog)

$taskName = 'StrefaNauki-AssignedAccess'
$encoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($aaScript)
)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded"

Register-ScheduledTask -TaskName $taskName -Action $action `
    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

try {
    Start-ScheduledTask -TaskName $taskName

    # 267009 = zadanie trwa, 267011 = jeszcze nie wystartowalo
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 1
        $result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
    } while (($result -in 267009, 267011) -and (Get-Date) -lt $deadline)
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if ($result -ne 0) {
    $detail = Get-Content $aaLog -Raw -ErrorAction SilentlyContinue
    throw "Nie udalo sie ustawic trybu kiosku (kod $result). $detail"
}

Write-Host "`nTryb kiosku: Edge na pelnym ekranie ($KioskStartUrl)" `
    -ForegroundColor Green

Write-Host "`n========================================"
Write-Host " STREFA NAUKI - KONFIGURACJA ZAPISANA"
Write-Host "========================================"
Write-Host "Konto: $KioskUser ($KioskDisplayName)"
Write-Host "Kiosk: Edge pelny ekran, $KioskStartUrl"
Write-Host "Dozwolone strony: $($AllowedUrls.Count)"
Write-Host "Pozostale strony: ZABLOKOWANE"
Write-Host "Strony z mikrofonem: $($MicrophoneUrls.Count)"
Write-Host "Autoplay: skonfigurowany"
Write-Host "========================================"
Write-Host "Zaloguj sie na konto $KioskDisplayName - Edge wystartuje sam." `
    -ForegroundColor Cyan
Write-Host "Wyjscie z kiosku: Ctrl+Alt+Del -> Wyloguj." `
    -ForegroundColor Cyan
