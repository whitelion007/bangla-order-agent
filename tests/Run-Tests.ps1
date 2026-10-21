<#
.SYNOPSIS
  Unit checks plus an accuracy report on 30 labelled messages (tests\worker-bot-cases.jsonl).
  Exit code 1 if a unit check fails. Field accuracy is reported, not enforced.
.EXAMPLE
  .\tests\Run-Tests.ps1                 # rules engine
  .\tests\Run-Tests.ps1 -Engine Claude  # needs $env:ANTHROPIC_API_KEY, makes 30 API calls
#>
param([ValidateSet('Rules', 'Claude')][string]$Engine = 'Rules')
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root\OrderAgent.psm1" -Force
$catalog = Import-Catalog "$root\catalog.json"
$failures = 0

function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -ceq "$Actual") { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name : expected '$Expected', got '$Actual'" -ForegroundColor Red; $script:failures++ }
}

Write-Host 'Unit checks'
$o = Get-RuleBasedOrder 'কালো পাঞ্জাবি ২টা চাই, সাইজ L। নাম: রাকিব, ঠিকানা: মিরপুর ১০, ঢাকা। ফোন ০১৭০০-০০০০০১' $catalog
Assert-Equal 'Bangla digits in phone' '01700000001' $o.phone
Assert-Equal 'quantity after product' 2 $o.items[0].qty
Assert-Equal 'size' 'L' $o.items[0].size
Assert-Equal 'phone +880 with spaces' '01900000112' (Get-RuleBasedOrder 'phone: +880 1900 000112' $catalog).phone
Assert-Equal 'number word' 3 (Get-RuleBasedOrder 'শাড়ি তিনটা লাগবে' $catalog).items[0].qty
Assert-Equal 'Banglish number word' 2 (Get-RuleBasedOrder 'panjabi duita lagbe' $catalog).items[0].qty
$r = Complete-Order $o $catalog
Assert-Equal 'total inside Dhaka' 2970 $r.total
Assert-Equal 'ready status' 'ready' $r.status
$r2 = Complete-Order (Get-RuleBasedOrder 'দুইটা টি-শার্ট দেন। ঠিকানা: খুলনা' $catalog) $catalog
Assert-Equal 'missing fields' 'customer_name,phone' ($r2.missing -join ',')
Assert-Equal 'outside Dhaka delivery' 130 $r2.delivery
Assert-Equal 'inquiry has no total' 0 (Complete-Order (Get-RuleBasedOrder 'পাঞ্জাবির দাম কত?' $catalog) $catalog).total

$tmp = Join-Path $env:TEMP "order-agent-test-$PID"
$first = Invoke-OrderPipeline -InputPath "$root\samples\messages.jsonl" -CatalogPath "$root\catalog.json" -OutDir $tmp -Engine Rules
$second = Invoke-OrderPipeline -InputPath "$root\samples\messages.jsonl" -CatalogPath "$root\catalog.json" -OutDir $tmp -Engine Rules
Assert-Equal 'pipeline processes inbox' 7 @($first).Count
Assert-Equal 'pipeline is idempotent' 0 @($second).Count
Remove-Item $tmp -Recurse -Force

Write-Host "`nAccuracy on worker-bot-cases.jsonl ($Engine engine)"
$fields = 'intent', 'customer_name', 'phone', 'address', 'products', 'qty', 'size'
$score = @{}; foreach ($f in $fields) { $score[$f] = 0 }
$cases = @(Get-Content "$PSScriptRoot\worker-bot-cases.jsonl" -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$misses = @()
foreach ($c in $cases) {
    if ($Engine -eq 'Claude') { $got = Invoke-ClaudeOrderExtraction -Text $c.text -Catalog $catalog }
    else { $got = Get-RuleBasedOrder -Text $c.text -Catalog $catalog }
    $e = $c.expected
    $norm = { param($v) if ($null -eq $v) { '' } else { (ConvertTo-NormalText ([string]$v)).Trim() } }
    $check = @{
        intent        = ($e.intent -eq $got.intent)
        customer_name = ((& $norm $e.customer_name) -eq (& $norm $got.customer_name))
        phone         = ((& $norm $e.phone) -eq (& $norm $got.phone))
        address       = ((& $norm $e.address) -eq (& $norm $got.address))
        products      = ((@($e.items | ForEach-Object product_id | Sort-Object -Unique) -join ',') -eq (@($got.items | ForEach-Object product_id | Sort-Object -Unique) -join ','))
        qty           = ((@($e.items | Where-Object { $null -ne $_.qty } | ForEach-Object { "$($_.product_id)$($_.qty)" } | Sort-Object) -join ',') -eq (@($got.items | Where-Object { $e.intent -eq 'order' } | ForEach-Object { "$($_.product_id)$($_.qty)" } | Sort-Object) -join ','))
        size          = ((@($e.items | ForEach-Object { "$($_.product_id)$($_.size)" } | Sort-Object) -join ',') -eq (@($got.items | ForEach-Object { "$($_.product_id)$($_.size)" } | Sort-Object) -join ','))
    }
    foreach ($f in $fields) { if ($check[$f]) { $score[$f]++ } else { $misses += "$($c.id) $f" } }
}
foreach ($f in $fields) { '{0,-14} {1,2}/{2}' -f $f, $score[$f], $cases.Count }
if ($misses) { "`nMisses: " + ($misses -join '; ') }

if ($failures) { Write-Host "`n$failures unit check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll unit checks passed" -ForegroundColor Green
