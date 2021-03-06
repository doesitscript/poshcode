[CmdletBinding(DefaultParameterSetName="InstallerOnly")]
param(
  [Parameter()]
  [Version]$Version,

  [Parameter(ParameterSetName="Package")]
  [Switch]$Increment,

  [Parameter(ParameterSetName="Package", Mandatory=$true)]
  [Switch]$Package,

  $OutputPath = $PSScriptRoot
)
if(!$PSScriptRoot) { $PSScriptRoot = $Pwd }
if(!$Version) {
  $Version = Get-Content $PSScriptRoot\PoshCode\PoshCode.psd1 | Select-String ModuleVersion | convertfrom-stringdata | % { [Version]$_.ModuleVersion.Trim("'`"") }
}
if($Version -lt "0.0") { throw "Can't calculate a version!" }
Write-Verbose "Setting Version $Version"
if($Increment) {
  if($Version.Revision -ge 0) {
    $Version = New-Object Version $Version.Major, $Version.Minor, $Version.Build, ($Version.Revision + 1)
  } elseif($Version.Build -ge 0) {
    $Version = New-Object Version $Version.Major, $Version.Minor, ($Version.Build + 1)
  } elseif($Version.Minor -ge 0) {
    $Version = New-Object Version $Version.Major, ($Version.Minor + 1)
  }
}

# Note: in the install script we strip the export command, as well as the signature if it's there, and anything delimited by BEGIN FULL / END FULL 
$InvokeWeb = (Get-Content $PSScriptRoot\PoshCode\InvokeWeb.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>' -replace "# SIG # Begin signature block(?s:.*)# SIG # End signature block"
$Configuration = (Get-Content $PSScriptRoot\PoshCode\Configuration.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>' -replace "# SIG # Begin signature block(?s:.*)# SIG # End signature block" -replace "# FULL # BEGIN FULL(?s:.*)# FULL # END FULL"
$Installation = (Get-Content $PSScriptRoot\PoshCode\Installation.psm1 -Raw) -replace '(Export-ModuleMember.*(?m:;|$))','<#$1#>' -replace "# SIG # Begin signature block(?s:.*)# SIG # End signature block" -replace "# FULL # BEGIN FULL(?s:.*)# FULL # END FULL"

Set-Content $PSScriptRoot\Install.ps1 ((@'
########################################################################
## Copyright (c) 2013 by Joel Bennett, all rights reserved.
## Free for use under MS-PL, MS-RL, GPL 2, or BSD license. Your choice.
########################################################################
#.Synopsis
#   Install a module package to the module repository
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium", DefaultParameterSetName="UserPath")]
param(
  # The package file to be installed
  [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Position=0)]
  [Alias("PSPath","PackagePath")]
  $Package,

  # The PSModulePath to install to
  [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
  [Alias("PSModulePath")]
  $InstallPath,

  # If set, the module is installed to the Common module path (as specified in PoshCode.ini)
  [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
  [Switch]$Common,

  # If set, the module is installed to the User module path (as specified in PoshCode.ini)
  [Parameter(ParameterSetName="UserPath")]
  [Switch]$User,

  # If set, overwrite existing modules without prompting
  [Switch]$Force,

  # If set, the module is imported immediately after install
  [Switch]$Import = $true,

  # If set, output information about the files as well as the module 
  [Switch]$Passthru,

  #  Specifies the client certificate that is used for a secure web request. Enter a variable that contains a certificate or a command or expression that gets the certificate.
  #  To find a certificate, use Get-PfxCertificate or use the Get-ChildItem cmdlet in the Certificate (Cert:) drive. If the certificate is not valid or does not have sufficient authority, the command fails.
  [System.Security.Cryptography.X509Certificates.X509Certificate[]]
  $ClientCertificate,

  #  Pass the default credentials
  [switch]$UseDefaultCredentials,

  #  Specifies a user account that has permission to send the request. The default is the current user.
  #  Type a user name, such as "User01" or "Domain01\User01", or enter a PSCredential object, such as one generated by the Get-Credential cmdlet.
  [System.Management.Automation.PSCredential]
  [System.Management.Automation.Credential()]
  [Alias("")]$Credential = [System.Management.Automation.PSCredential]::Empty,

  # Specifies that Authorization: Basic should always be sent. Requires $Credential to be set, and should only be used with https
  [ValidateScript({{if(!($Credential -or $WebSession)){{ throw "ForceBasicAuth requires the Credential parameter be set"}} else {{ $true }}}})]
  [switch]$ForceBasicAuth,

  # Uses a proxy server for the request, rather than connecting directly to the Internet resource. Enter the URI of a network proxy server.
  # Note: if you have a default proxy configured in your internet settings, there is no need to set it here.
  [Uri]$Proxy,

  #  Pass the default credentials to the Proxy
  [switch]$ProxyUseDefaultCredentials,

  #  Pass specific credentials to the Proxy
  [System.Management.Automation.PSCredential]
  [System.Management.Automation.Credential()]
  $ProxyCredential= [System.Management.Automation.PSCredential]::Empty     
)
end {{
  Write-Progress "Validating PoshCode Module" -Id 0
  if($PSBoundParameters.ContainsKey("Package")) {{
    $TargetModulePackage = $PSBoundParameters["Package"]
  }}

  $Module = Get-Module PoshCode -ListAvailable

  if(!$Module -or $Module.Version -lt "{0}") {{
    Write-Progress "Installing PoshCode Module" -Id 0
    if(!$PSBoundParameters.ContainsKey("InstallPath")) {{
      $PSBoundParameters["InstallPath"] = $InstallPath = Select-ModulePath
      Write-Verbose ("Selected Module Path: " + $PSBoundParameters["InstallPath"])
    }}
    # Use the psdxml now that we can, rather than hard-coding the version ;)    
    $PSBoundParameters["Package"] = "http://PoshCode.org/Modules/PoshCode.psdxml"

    $PoshCodePath = Join-Path $InstallPath PoshCode

    Write-Verbose ("Selected Module Path: '" + $PSBoundParameters["InstallPath"] + "' or '" + $PoshCodePath + "'")

    Install-ModulePackage @PSBoundParameters
    Import-Module $PoshCodePath

    # Now that we've installed the PoshCode module, we will update the config data with the path they picked
    $ConfigData = Get-ConfigData
    if($InstallPath -match ([Regex]::Escape([Environment]::GetFolderPath("UserProfile")) + "*")) {{
      $ConfigData["UserPath"] = $InstallPath
    }} elseif($InstallPath -match ([Regex]::Escape([Environment]::GetFolderPath("CommonDocuments")) + "*")) {{
      $ConfigData["CommonPath"] = $InstallPath
    }} elseif($InstallPath -match ([Regex]::Escape([Environment]::GetFolderPath("CommonProgramFiles")) + "*")) {{
      $ConfigData["CommonPath"] = $InstallPath
    }} else {{
      $ConfigData["Default"] = $InstallPath
    }}
    Set-ConfigData -ConfigData $ConfigData
  }}

  if($TargetModulePackage) {{
    Write-Progress "Installing Package" -Id 0
    $PSBoundParameters["Package"] = $TargetModulePackage
    Install-ModulePackage @PSBoundParameters
  }}
  
  Test-ExecutionPolicy
}}

begin {{

###############################################################################
{1}
###############################################################################
{2}
###############################################################################
{3}
###############################################################################

}}
'@
) -f $Version, $InvokeWeb, $Configuration, $Installation)


Sign $PSScriptRoot\Install.ps1 -WA 0 -EA 0
Sign -Module PoshCode -WA 0 -EA 0

if($Package) {
  Update-ModuleInfo PoshCode -Version $Version
  New-ModulePackage PoshCode $OutputPath | Out-Default
}