#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

Import-Module $PSScriptRoot/lib/GitHubActionsCore
Import-Module $PSScriptRoot/lib/powershell-yaml

$registryPath = Get-ActionInput 'registry-path'
$indexPath = Get-ActionInput 'index-path'
$token = Get-ActionInput 'token'

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
  $latestRelease = Invoke-RestMethod @latestParams -ErrorAction Ignore
  # check status header
  # TODO should use ResponseStatusCodeVariable when pwsh 7 is available,
  # but we're 'happy' as is, since GitHub sends a 'Status' header as well
  if ($resHeaders.Status -match "^304") {
    # not modified
    Write-Host "Up to date: $Repository"
    return $SavedRelease
  }
  elseif ($resHeaders.Status -match "^200") {
    Write-Host "Update found: $Repository"
    # new content
    $indexJson = Invoke-RestMethod @indexJsonParams "https://github.com/$Repository/releases/latest/download/$repoName.index.catpkg.json"
    $NewRelease = [ordered]@{
      'api-response-headers' = [ordered]@{
        'ETag'          = $resHeaders.ETag | Select-Object -First 1
        'Last-Modified' = $resHeaders.'Last-Modified' | Select-Object -First 1
      }
      'api-response-content' = $latestRelease | Select-Object 'tag_name', 'name', 'published_at'
      'index'                = $indexJson | Select-Object * -ExcludeProperty '$schema', 'repositoryFiles'
    }
    # currently needed because of a couple of fields like battleScribeVersion
    return $NewRelease
  }
  else {
    # error received
    Write-Error $latestRelease
    return $null
  }
}
[string]$regSettingsPath = Join-Path $registryPath settings.yml
$regSettings = Get-Content $regSettingsPath -Raw | ConvertFrom-Yaml

$registrationsPath = Join-Path $registryPath $regSettings.registrations.path

$registry = Get-ChildItem $registrationsPath -Filter *.catpkg.yml | ForEach-Object {
  return @{
    name         = $_.name
    registryFile = $_
  }
} | ConvertTo-HashTable -Key { $_.name }

Get-ChildItem $indexPath *.catpkg.yml | ForEach-Object {
  $entry = $registry[$_.Name]
  if (-not $entry) {
    $entry = @{ name = $_.Name }
    $registry[$_.Name] = $entry
  }
  $entry.indexFile = $_
}

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
  $index.'latest-release' = Get-LatestReleaseInfo $repository $index.'latest-release' -Token $token
  $indexYmlPath = (Join-Path $indexPath $_.name)
  $index | ConvertTo-Yaml -OutFile $indexYmlPath -Force
  Write-Host "Saved."
}


<# TODO

  Compile current index and registry into a new up-to-date index.

  prerequisites:
  - registry of listed repositories/orgs
  - an index containing latest release details
    (index is split across multiple files, one for every "active" repo/pkg)

  1. Combine registry with index (add, update, remove index entries)
  2. For every index entry:
    a. ask for 'latest' release from API (with 'If-Modified-Since' using Last-Updated details if available)
        - if API returns 302 Not Modified, entry is up-to-date
        - if API returns 404 Not Found (no release), set noRelease to true
        - otherwise, entry requires update
    b. update index entry with info from the API response:
      - tag name
      - release name
      - release date
      - Last-Updated and ETag headers from GitHub API
    c. if tag name was the same, end processing this entry
    d. if noRelease == true, end processing this entry
    e. download index.catpkg.json - if failed, set noIndexJson to true
    f. save necessary details from json to index entry

#>

<#
- load reg settings
- load reg entries (? including filenames ?)
- (?) validate filenames match content's id
- patch up registry entries with defaults (recreate index entry when owner changed?)
- apply registry values onto corresponding index entries
- new index entries should be monitored, and those that were removed
- for every patched index entry, call latest release API and update the content with response
- save all index entries as files
#>