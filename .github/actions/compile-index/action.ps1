#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

Import-Module $PSScriptRoot/lib/GitHubActionsCore
Import-Module $PSScriptRoot/lib/powershell-yaml

$registryPath = Get-ActionInput 'registry-path'
$indexPath = Get-ActionInput 'index-path'
$token = Get-ActionInput 'token'

# function to select truthy value: if not left, then right
function val {
  param ($left, $right, $errmsg)
  if ($left) {
    $left
  }
  elseif ($right -or !$errmsg) {
    $right
  }
  else {
    $errmsg
  }
}

# function to build hashtable from pipeline, selecting string keys for objects
function ConvertTo-HashTable {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param (
    [Parameter(ValueFromPipeline)]
    [object] $InputObject,
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [string] $Key,
    [Parameter()]
    [switch] $Ordered
  )
  begin {
    $out = if ($Ordered) { [ordered]@{ } } else { @{ } }
  }
  process {
    $out[$Key] = $InputObject
  }
  end {
    $out
  }
}

# get latest release info as a ready-to-save hashtable
function Get-LatestReleaseInfo {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, Position = 0)]
    [string] $Repository,
    [Parameter()]
    [hashtable] $SavedRelease = [ordered]@{ },
    [Parameter()]
    [string] $Token
  )
  $owner, $repoName = $Repository -split '/'
  $requestHeaders = @{ }
  if ($Token) {
    $requestHeaders['Authorization'] = "token $Token"
  }
  $savedHeaders = $SavedRelease.'api-response-headers'
  if ($savedHeaders.'Last-Modified') {
    $requestHeaders['If-Modified-Since'] = $savedHeaders.'Last-Modified'
  }
  if ($savedHeaders.'ETag') {
    $requestHeaders['If-None-Match'] = $savedHeaders.'ETag'
  }
  $latestParams = @{
    Uri                     = "https://api.github.com/repos/$Repository/releases/latest"
    Headers                 = $requestHeaders
    ResponseHeadersVariable = 'resHeaders'
  }
  Write-Host $requestHeaders.Values
  $latestRelease = Invoke-RestMethod @latestParams -ErrorAction Ignore -Verbose
  # check status header
  # TODO should use ResponseStatusCodeVariable when pwsh 7 is available,
  # but we're 'happy' as is, since GitHub sends a 'Status' header as well
  if ($resHeaders.Status -match "^304") {
    # not modified
    Write-Host "Up to date: $Repository"
    return $SavedRelease
  }
  elseif (-not $resHeaders.Status -match "^200") {
    # error received
    Write-Error $latestRelease
    return $null
  }
  Write-Host "Update found: $Repository"
  # new content
  $indexJson = Invoke-RestMethod "https://github.com/$Repository/releases/latest/download/$repoName.catpkg.json"
  $headers = [ordered]@{}
  if ($resHeaders.ETag) {
    $headers.'ETag' = $resHeaders.ETag -as [string]
  }
  if ($resHeaders.'Last-Modified') {
    $headers.'Last-Modified' = $resHeaders.'Last-Modified' -as [string]
  }
  $NewRelease = [ordered]@{
    'api-response-headers' = $headers
    'api-response-content' = $latestRelease | Select-Object 'tag_name', 'name', 'published_at'
    'index'                = $indexJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
  }
  if ($headers.Count -eq 0) {
    $NewRelease.Remove('api-response-headers') | Out-Null
  }
  # currently needed because of a couple of fields like battleScribeVersion
  return $NewRelease
}

# read settings
[string]$regSettingsPath = Join-Path $registryPath settings.yml
$regSettings = Get-Content $regSettingsPath -Raw | ConvertFrom-Yaml

# read registry entries
$registrationsPath = Join-Path $registryPath $regSettings.registrations.path
$registry = Get-ChildItem $registrationsPath -Filter *.catpkg.yml | ForEach-Object {
  return @{
    name         = $_.name
    registryFile = $_
  }
} | ConvertTo-HashTable -Key { $_.name }
# zip entries with existing index entries
Get-ChildItem $indexPath *.catpkg.yml | ForEach-Object {
  $entry = $registry[$_.Name]
  if (-not $entry) {
    $entry = @{ name = $_.Name }
    $registry[$_.Name] = $entry
  }
  $entry.indexFile = $_
}

# process all entries
$registry.Values | ForEach-Object {
  Write-Host ("Processing: " + $_.name)
  if (-not $_.registryFile) {
    Write-Host "Index entry not in registry, removing."
    Remove-Item $_.indexFile
  }
  $registration = $_.registryFile | Get-Content -Raw | ConvertFrom-Yaml -Ordered
  if ($_.indexFile) {
    Write-Host "Reading index entry."
    $index = $_.indexFile | Get-Content -Raw | ConvertFrom-Yaml -Ordered
  }
  else {
    Write-Host "Reading registry entry."
    $index = $registration
  }
  $repository = $index.location.github
  $owner, $repoName = $repository -split '/'
  Write-Host "Getting latest release info."
  $index.'latest-release' = Get-LatestReleaseInfo $repository -SavedRelease $index.'latest-release' -Token $token
  
  Write-Host "Saving latest release info."
  $indexYmlPath = (Join-Path $indexPath $_.name)
  $index | ConvertTo-Yaml | Set-Content $indexYmlPath -Force
  Write-Host "Saved."
}
