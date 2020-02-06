#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

Import-Module $PSScriptRoot/lib/GitHubActionsCore
Import-Module $PSScriptRoot/lib/powershell-yaml

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
    [System.Collections.IDictionary] $SavedRelease,
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
  # ETags, turns out, change all the time in github api (at least for latest releases)
  # if ($savedHeaders.'ETag') {
  #   $requestHeaders['If-None-Match'] = $savedHeaders.'ETag'
  # }
  $latestParams = @{
    Uri                     = "https://api.github.com/repos/$Repository/releases/latest"
    Headers                 = $requestHeaders
    ResponseHeadersVariable = 'resHeaders'
  }
  try {
    $latestRelease = Invoke-RestMethod @latestParams
  }
  catch [Microsoft.PowerShell.Commands.HttpResponseException] {
    if ($_.Exception.Response.StatusCode -eq 304) {
      # not modified
      Write-Host "Up to date: $Repository"
      return $SavedRelease
    }
    # error received
    Write-Error -Exception $_.Exception
    return $null
  }
  Write-Host "Update found: $Repository"
  # new content
  $indexJson = Invoke-RestMethod "https://github.com/$Repository/releases/latest/download/$repoName.catpkg.json"
  $headers = [ordered]@{}
  # if ($resHeaders.ETag) {
  #   $headers.'ETag' = $resHeaders.ETag -as [string]
  # }
  if ($resHeaders.'Last-Modified') {
    $headers.'Last-Modified' = $resHeaders.'Last-Modified' -as [string]
  }
  $NewRelease = [ordered]@{
    'api-response-headers' = $headers
    'api-response-content' = $latestRelease | Select-Object 'tag_name', 'name', 'published_at'
    # currently needed because of a couple of fields like battleScribeVersion:
    'index'                = $indexJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
  }
  if ($headers.Count -eq 0) {
    $NewRelease.Remove('api-response-headers') | Out-Null
  }
  return $NewRelease
}

# read inputs
$registryPath = Get-ActionInput 'registry-path'
$indexPath = Get-ActionInput 'index-path'
$token = Get-ActionInput 'token'

# read settings
[string]$regSettingsPath = Join-Path $registryPath settings.yml
$settings = Get-Content $regSettingsPath -Raw | ConvertFrom-Yaml
$registrationsPath = Join-Path $registryPath $settings.registrations.path

# read registry entries
$registry = Get-ChildItem $registrationsPath -Filter *.catpkg.yml | ForEach-Object {
  return @{
    name         = $_.name
    registryFile = $_
  }
} | ConvertTo-HashTable -Key { $_.name }
# zip entries with existing index entries
Get-ChildItem $indexPath *.catpkg.yml | ForEach-Object {
  $entry = $registry[$_.Name]
  if ($null -eq $entry) {
    $entry = @{ name = $_.Name }
    $registry[$_.Name] = $entry
  }
  $entry.indexFile = $_
}

# process all entries
$entries = $registry.Values | ForEach-Object {
  Write-Host ("Processing: " + $_.name)
  if (-not $_.registryFile) {
    Write-Host "Index entry not in registry, removing."
    Remove-Item $_.indexFile
    return
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
  $latestRelease = Get-LatestReleaseInfo $repository -SavedRelease $index.'latest-release' -Token $token
  if ($latestRelease -ne $index.'latest-release') {
    Write-Host "Saving latest release info."
    $indexYmlPath = (Join-Path $indexPath $_.name)
    $index | ConvertTo-Yaml | Set-Content $indexYmlPath -Force
    Write-Host "Saved."
  }
  return $index
}

$galleryJsonPath = Get-ActionInput gallery-json-path
if (-not $galleryJsonPath) {
  Write-Host "Done"
  exit 0
}

$entriesWithRelease = $entries | Where-Object { $null -ne $_.'latest-release' }
$entryIndexes =  @($entriesWithRelease.'latest-release'.index)
$galleryJsonContent = [ordered]@{
  '$schema' = 'https://raw.githubusercontent.com/BSData/schemas/master/src/catpkg.schema.json'
  name = $settings.gallery.name
  description = $settings.gallery.description
  battleScribeVersion = ($entryIndexes.battleScribeVersion | Sort-Object -Bottom 1) -as [string]
} + $settings.gallery.urls + @{
  repositories = $entryIndexes
}

$galleryJsonContent | ConvertTo-Json | Set-Content $galleryJsonPath -Force