<#
.SYNOPSIS
  Runs the Bangla order agent on the sample inbox and prints the result.
.EXAMPLE
  .\run-demo.ps1                 # offline rules engine
  .\run-demo.ps1 -Engine Claude  # needs $env:ANTHROPIC_API_KEY
#>
param(
    [ValidateSet('Auto', 'Rules', 'Claude')][string]$Engine = 'Rules',
    [string]$InputPath = "$PSScriptRoot\samples\messages.jsonl",
    [string]$OutDir = "$PSScriptRoot\out"
)
Import-Module "$PSScriptRoot\OrderAgent.psm1" -Force
if (Test-Path $OutDir) { Remove-Item "$OutDir\*" -Force }   # fresh demo run
$rows = Invoke-OrderPipeline -InputPath $InputPath -CatalogPath "$PSScriptRoot\catalog.json" -OutDir $OutDir -Engine $Engine -Force
$rows | Format-Table message_id, status, customer_name, phone, items, total, missing -AutoSize -Wrap
"`nReplies:"
$rows | ForEach-Object { "[$($_.message_id)] $($_.reply_bn)" }
"`nSaved: $OutDir\orders.csv (opens in Excel), run.log.jsonl, state.json"
