<#
    .SYNOPSIS
    Invoke-TwoTierOrCaConfig.ps1

    .DESCRIPTION
    This script makes the instance an Offline Root CA.  
    
    .EXAMPLE
    .\Invoke-TwoTierOrCaConfig -DomainDNSName 'example.com' -OrCaCommonName 'CA01' -OrCaKeyLength '2048' -OrCaHashAlgorithm 'SHA256' -OrCaValidityPeriodUnits '5' -$ADAdminSecParam 'arn:aws:secretsmanager:us-west-2:############:secret:example-VX5fcW'

#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $true)]
    [string]$OrCaCommonName,

    [Parameter(Mandatory = $true)]
    [string]$OrCaKeyLength,

    [Parameter(Mandatory = $true)]
    [string]$OrCaHashAlgorithm,
    
    [Parameter(Mandatory = $true)]
    [string]$OrCaValidityPeriodUnits,

    [Parameter(Mandatory = $true)]
    [string]$ADAdminSecParam
)

$CompName = $env:COMPUTERNAME

Write-Output "Getting $ADAdminSecParam Secret"
Try {
    $AdminSecret = Get-SECSecretValue -SecretId $ADAdminSecParam -ErrorAction Stop | Select-Object -ExpandProperty 'SecretString'
} Catch [System.Exception] {
    Write-Output "Failed to get $ADAdminSecParam Secret $_"
    Exit 1
}

Write-Output "Converting $ADAdminSecParam Secret from JSON"
Try {
    $ADAdminPassword = ConvertFrom-Json -InputObject $AdminSecret -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to convert AdminSecret from JSON $_"
    Exit 1
}

Write-Output 'Creating Credential Object for Administrator'
$AdminUserName = $ADAdminPassword.UserName
$AdminUserPW = ConvertTo-SecureString ($ADAdminPassword.Password) -AsPlainText -Force
$Credentials = New-Object -TypeName 'System.Management.Automation.PSCredential' ("$DomainDNSName\$AdminUserName", $AdminUserPW)

Write-Output 'Creating PKI folders'
$Folders = @(
    'D:\Pki\SubCA',
    'D:\ADCS\DB',
    'D:\ADCS\Log'
)
Foreach ($Folder in $Folders) {
    $PathPresent = Test-Path -Path $Folder
    If (-not $PathPresent) {
        Try {
            $Null = New-Item -Path $Folder -Type 'Directory' -ErrorAction Stop
        } Catch [System.Exception] {
            Write-Output "Failed to create $Folder Directory $_"
            Exit 1
        }
    } 
}

Write-Output 'Example CPS statement' | Out-File 'D:\Pki\cps.txt'

$Inf = @(
    '[Version]',
    'Signature="$Windows NT$"',
    '[PolicyStatementExtension]',
    'Policies=InternalPolicy',
    '[InternalPolicy]',
    'OID=1.2.3.4.1455.67.89.5', 
    'Notice="Legal Policy Statement"',
    "URL=http://pki.$DomainDNSName/pki/cps.txt",
    '[Certsrv_Server]',
    "RenewalKeyLength=$OrCaKeyLength",
    'RenewalValidityPeriod=Years',
    "RenewalValidityPeriodUnits=$OrCaValidityPeriodUnits",
    'CRLPeriod=Weeks',
    'CRLPeriodUnits=26',
    'CRLDeltaPeriod=Days',  
    'CRLDeltaPeriodUnits=0',
    'LoadDefaultTemplates=0',
    'AlternateSignatureAlgorithm=0',
    '[CRLDistributionPoint]',
    '[AuthorityInformationAccess]'
)

Write-Output 'Creating CAPolicy.inf'
Try {
    $Inf | Out-File -FilePath 'C:\Windows\CAPolicy.inf' -Encoding 'ascii'
} Catch [System.Exception] {
    Write-Output "Failed to create CAPolicy.inf $_"
    Exit 1
}

Write-Output 'Installing Offline Root CA'
Try {
    $Null = Install-AdcsCertificationAuthority -CAType 'StandaloneRootCA' -CACommonName $OrCaCommonName -KeyLength $OrCaKeyLength -HashAlgorithm $OrCaHashAlgorithm -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' -ValidityPeriod 'Years' -ValidityPeriodUnits $OrCaValidityPeriodUnits -DatabaseDirectory 'D:\ADCS\DB' -LogDirectory 'D:\ADCS\Log' -Force -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to install CA $_"
    Exit 1
}

Write-Output 'Configuring CRL distro points'
Try {
    $Null = Get-CACRLDistributionPoint | Where-Object { $_.Uri -like '*ldap*' -or $_.Uri -like '*http*' -or $_.Uri -like '*file*' } -ErrorAction Stop | Remove-CACRLDistributionPoint -Force -ErrorAction Stop
    $Null = Add-CACRLDistributionPoint -Uri "http://pki.$DomainDNSName/pki/<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl" -AddToCertificateCDP -Force -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed set CRL Distro $_"
    Exit 1
}

Write-Output 'Configuring AIA distro points'
Try {
   $Null = Get-CAAuthorityInformationAccess | Where-Object { $_.Uri -like '*ldap*' -or $_.Uri -like '*http*' -or $_.Uri -like '*file*' } -ErrorAction Stop | Remove-CAAuthorityInformationAccess -Force
   $Null = Add-CAAuthorityInformationAccess -AddToCertificateAia -Uri "http://pki.$DomainDNSName/pki/<ServerDNSName>_<CaName><CertificateName>.crt" -Force -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed set AIA Distro $_"
    Exit 1
}

Write-Output 'Configuring Offline Root CA'
& certutil.exe -setreg CA\CRLOverlapPeriodUnits '12' > $null
& certutil.exe -setreg CA\CRLOverlapPeriod 'Hours' > $null
& certutil.exe -setreg CA\ValidityPeriodUnits '5' > $null
& certutil.exe -setreg CA\ValidityPeriod 'Years' > $null
& certutil.exe -setreg CA\AuditFilter '127' > $null
& auditpol.exe /set /subcategory:'Certification Services' /failure:enable /success:enable > $null

Write-Output 'Restarting CA service'
Try {
    Restart-Service -Name 'certsvc' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed restart CA service $_"
    Exit 1
}

Start-Sleep -Seconds 10

Write-Output 'Publishing CRL'
& certutil.exe -crl > $null

Write-Output 'Copying CRL to PKI folder'
Try {
    Copy-Item -Path 'C:\Windows\System32\CertSrv\CertEnroll\*.cr*' -Destination 'D:\Pki\' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to copy CRL to PKI folder  $_"
    Exit 1
}

Write-Output 'Restarting CA service'
Try {
    Restart-Service -Name 'certsvc' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed restart CA service $_"
}

Write-Output 'Removing DSC Configuration'
Try {    
    Remove-DscConfigurationDocument -Stage 'Current' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed build DSC Configuration $_"
}

Write-Output 'Re-enabling Windows Firewall'
Try {
    Get-NetFirewallProfile -ErrorAction Stop | Set-NetFirewallProfile -Enabled 'True' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed re-enable firewall $_"
}

Write-Output 'Removing QuickStart build files'
Try {
    Remove-Item -Path 'C:\AWSQuickstart' -Recurse -Force -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed remove QuickStart build files $_"
}

Write-Output 'Removing self signed cert'
Try {
    $SelfSignedThumb = Get-ChildItem -Path 'cert:\LocalMachine\My\' -ErrorAction Stop | Where-Object { $_.Subject -eq 'CN=AWSQSDscEncryptCert' } | Select-Object -ExpandProperty 'Thumbprint'
    Remove-Item -Path "cert:\LocalMachine\My\$SelfSignedThumb" -DeleteKey -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed remove self signed cert $_"
}

Write-Output 'Creating Update CRL Scheduled Task'
Try {
    $ScheduledTaskAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '& certutil.exe -crl; Copy-Item -Path C:\Windows\System32\CertSrv\CertEnroll\*.cr* -Destination D:\Pki\'
    $ScheduledTaskTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval '25' -DaysOfWeek 'Sunday' -At '12am' -ErrorAction Stop
    $ScheduledTaskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType 'ServiceAccount' -RunLevel 'Highest' -ErrorAction Stop
    $ScheduledTaskSettingsSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -Compatibility 'Win8' -ExecutionTimeLimit (New-TimeSpan -Hours '1') -ErrorAction Stop
    $ScheduledTask = New-ScheduledTask -Action $ScheduledTaskAction -Principal $ScheduledTaskPrincipal -Trigger $ScheduledTaskTrigger -Settings $ScheduledTaskSettingsSet -Description 'Updates CRL to Local Pki Folder' -ErrorAction Stop
    $Null = Register-ScheduledTask 'Update CRL' -InputObject $ScheduledTask -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed register Update CRL Scheduled Task $_"
}

Start-ScheduledTask -TaskName 'Update CRL' -ErrorAction SilentlyContinue

Write-Output 'Restarting CA service'
Try {
    Restart-Service -Name 'certsvc' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed restart CA service $_"
}

Write-Output 'Creating PkiSysvolPSDrive'
Try {
    $Null = New-PSDrive -Name 'PkiSysvolPSDrive' -PSProvider 'FileSystem' -Root "\\$DomainDNSName\SYSVOL\$DomainDNSName" -Credential $Credentials -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to create PkiSysvolPSDrive $_"
    Exit 1
}

Write-Output 'Creating the PkiRootCA SYSVOL folder'
Try {
    $Null =  New-Item -ItemType 'Directory' -Path 'PkiSysvolPSDrive:\PkiRootCA' -Force -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to create PkiRootCA SYSVOL folder $_"
    Exit 1
}

Write-Output 'Copying CertEnroll contents to SYSVOL PkiRootCA folder'
Try {
    Copy-Item -Path 'C:\Windows\System32\CertSrv\CertEnroll\*.cr*' -Destination 'PkiSysvolPSDrive:\PkiRootCA' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to copy CertEnroll contents to SYSVOL PkiRootCA folder $_"
    Exit 1
}

Write-Output 'Removing PkiSysvolPSDrive'
Try {
    Remove-PSDrive -Name 'PkiSysvolPSDrive' -ErrorAction Stop
} Catch [System.Exception] {
    Write-Output "Failed to remove PkiSysvolPSDrive $_"
    Exit 1
}