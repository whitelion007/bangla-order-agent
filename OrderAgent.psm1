# Bangla F-commerce Order Agent
# Turns Bangla / Banglish / English customer messages into structured orders,
# computes totals from the shop catalog and drafts a Bangla reply.
# Engines: "Rules" (offline, no key needed) and "Claude" (Anthropic Messages API).
# Windows PowerShell 5.1 compatible. Save this file as UTF-8 with BOM.

Set-StrictMode -Version 2

$script:BnDigits = '০১২৩৪৫৬৭৮৯'
$script:NumberWords = @{ 'এক' = 1; 'দুই' = 2; 'তিন' = 3; 'চার' = 4; 'পাঁচ' = 5 }
$script:LatinNumberWords = @{ 'ekta' = 1; 'ekti' = 1; 'one' = 1; 'duita' = 2; 'duto' = 2; 'two' = 2; 'tinta' = 3; 'three' = 3; 'charta' = 4; 'four' = 4; 'pachta' = 5; 'five' = 5 }
$script:Units = '(?:টা|টি|পিস|pcs|pc|piece|pieces|ta|ti)'
$script:Sizes = 'XXL|XL|L|M|S'
$script:FieldNamesBn = @{ customer_name = 'নাম'; phone = 'ফোন নম্বর'; address = 'ঠিকানা'; items = 'কোন পণ্য কয়টা' }

function Import-Catalog {
    param([Parameter(Mandatory)][string]$Path)
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $catalog.products) {
        $p.aliases = @($p.aliases | ForEach-Object { ConvertTo-NormalText $_ })
    }
    $catalog
}

function ConvertTo-NormalText {
    # Unify Bangla nukta forms, Bangla digits and number words so one set of patterns works.
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.Normalize([Text.NormalizationForm]::FormC)
    $t = $t.Replace([string][char]0x09A1 + [char]0x09BC, [string][char]0x09DC)
    $t = $t.Replace([string][char]0x09A2 + [char]0x09BC, [string][char]0x09DD)
    $t = $t.Replace([string][char]0x09AF + [char]0x09BC, [string][char]0x09DF)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        $i = $script:BnDigits.IndexOf($ch)
        if ($i -ge 0) { [void]$sb.Append([string]$i) } else { [void]$sb.Append($ch) }
    }
    $t = $sb.ToString()
    foreach ($w in $script:NumberWords.Keys) {
        $t = [regex]::Replace($t, "(?<![ঀ-৿])$w(টা|টি)?(?![ঀ-৿])", { param($m)
            $suffix = $m.Groups[1].Value
            if (-not $suffix) { $suffix = 'টা' }
            "$($script:NumberWords[$w])$suffix" })
    }
    foreach ($w in $script:LatinNumberWords.Keys) {
        $t = [regex]::Replace($t, "(?i)\b$w\b", "$($script:LatinNumberWords[$w])ta")
    }
    $t
}

function Get-Phone {
    # Accepts 01XXXXXXXXX, +880/880 prefixes and digits split by spaces or dashes.
    param([string]$Text)
    foreach ($m in [regex]::Matches($Text, '(?<!\d)(?:\+?880)?[\s-]*0?1(?:[\s-]?\d){9}(?!\d)')) {
        $digits = $m.Value -replace '\D', ''
        if ($digits.Length -lt 10) { continue }
        $local = '0' + $digits.Substring($digits.Length - 10)
        if ($local -match '^01[3-9]\d{8}$') { return $local }
    }
    $null
}

function Get-LabeledValue {
    param([string]$Text, [string[]]$Labels, [string]$StopPattern)
    $labelPattern = ($Labels | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $m = [regex]::Match($Text, "(?i)(?:$labelPattern)\s*[:：]\s*(.+?)(?=\s*(?:$StopPattern)|$)")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value.Trim(' ', ',', '.', '।')
    if ($v) { $v } else { $null }
}

function Find-Size {
    # Labelled sizes ("সাইজ L", "L size", "(M)") first, then a bare upper-case size token.
    param([string]$Segment, [switch]$LabelledOnly)
    $s = $script:Sizes
    $patterns = @("(?i)(?:সাইজ|size)\s*[:：]?\s*($s)(?![A-Za-z])", "(?i)(?<![A-Za-z])($s)\s*(?:সাইজ|size)", "\(\s*($s)\s*\)")
    if (-not $LabelledOnly) { $patterns += "(?<![A-Za-z])($s)(?![A-Za-z])" }
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($Segment, $pattern)
        if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    }
    $null
}

function Get-Items {
    param([string]$Text, $Catalog)
    $found = @()
    foreach ($p in $Catalog.products) {
        foreach ($alias in $p.aliases) {
            $m = [regex]::Match($Text, "(?i)$([regex]::Escape($alias))")
            if ($m.Success) { $found += [pscustomobject]@{ product = $p; alias = $alias; pos = $m.Index }; break }
        }
    }
    $found = @($found | Sort-Object pos)
    $labels = [regex]::Match($Text, '(?i)নাম\s*[:：]|nam\s*[:：]|name\s*[:：]|ফোন|phone|ঠিকানা|address')
    $items = @()
    for ($i = 0; $i -lt $found.Count; $i++) {
        $f = $found[$i]
        $a = [regex]::Escape($f.alias)
        # The text that belongs to this item: from its name up to the next product or contact label.
        $end = $Text.Length
        if ($i + 1 -lt $found.Count) { $end = $found[$i + 1].pos }
        if ($labels.Success -and $labels.Index -gt $f.pos -and $labels.Index -lt $end) { $end = $labels.Index }
        $segment = $Text.Substring($f.pos, $end - $f.pos)
        $qty = 1
        # "2টা পাঞ্জাবি" (quantity before), "পাঞ্জাবি 2টা" (after), then a bare "2 saree".
        $before = [regex]::Match($Text, "(?i)(\d{1,3})\s*$($script:Units)\s+(?:[\p{L}\p{M}\-]+\s+){0,2}?$a")
        $after = [regex]::Match($segment, "(?i)^$a\S*\s*(?:[\p{L}\p{M}\-]+\s*)?(\d{1,3})\s*$($script:Units)(?![\p{L}])")
        $bare = [regex]::Match($Text, "(?i)(?<![\d\-])(\d{1,2})\s+$a")
        if ($before.Success -and $before.Index -ge ($f.pos - 40)) { $qty = [int]$before.Groups[1].Value }
        elseif ($after.Success) { $qty = [int]$after.Groups[1].Value }
        elseif ($bare.Success) { $qty = [int]$bare.Groups[1].Value }
        $size = Find-Size $segment
        $items += [pscustomobject]@{ product_id = $f.product.id; qty = $qty; size = $size }
    }
    if ($items.Count -eq 1 -and -not $items[0].size) { $items[0].size = Find-Size $Text -LabelledOnly }
    , $items
}

function Get-RuleBasedOrder {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)]$Catalog)
    $t = ConvertTo-NormalText $Text
    $stop = '[।\n]|ফোন|phone|mobile|নাম\s*[:：]|nam\s*[:：]|name\s*[:：]|ঠিকানা\s*[:：]|address\s*[:：]'
    $phone = Get-Phone $t
    $name = Get-LabeledValue $t @('নাম', 'name', 'nam') ($stop + '|,')
    $address = Get-LabeledValue $t @('ঠিকানা', 'address') $stop
    $items = Get-Items $t $Catalog
    $isQuestion = [regex]::IsMatch($t, '(?i)\?|দাম|কত|price|koto|how much|available|ache|আছে')
    $intent = 'other'
    if ($items.Count -gt 0) { $intent = 'order' }
    if ($isQuestion -and -not $phone -and -not $address) { $intent = 'inquiry' }
    [pscustomobject]@{
        intent        = $intent
        customer_name = $name
        phone         = $phone
        address       = $address
        items         = $items
    }
}

function Get-OrderJsonSchema {
    param($Catalog)
    $nullableString = @{ type = @('string', 'null') }
    @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('intent', 'customer_name', 'phone', 'address', 'items')
        properties           = @{
            intent        = @{ type = 'string'; enum = @('order', 'inquiry', 'other') }
            customer_name = $nullableString
            phone         = $nullableString
            address       = $nullableString
            items         = @{
                type  = 'array'
                items = @{
                    type                 = 'object'
                    additionalProperties = $false
                    required             = @('product_id', 'qty', 'size')
                    properties           = @{
                        product_id = @{ type = 'string'; enum = @($Catalog.products | ForEach-Object { $_.id }) }
                        qty        = @{ type = 'integer' }
                        size       = @{ type = @('string', 'null'); enum = @('S', 'M', 'L', 'XL', 'XXL', $null) }
                    }
                }
            }
        }
    }
}

function Invoke-ClaudeOrderExtraction {
    # Raw HTTP call to the Anthropic Messages API with structured output.
    # Prices are never taken from the model: the pipeline computes them from the catalog.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Catalog,
        [string]$Model = 'claude-opus-5-5',
        [string]$ApiKey = $env:ANTHROPIC_API_KEY,
        [int]$MaxAttempts = 4
    )
    if (-not $ApiKey) { throw 'ANTHROPIC_API_KEY is not set.' }
    $productList = ($Catalog.products | ForEach-Object { "- $($_.id): $($_.name_bn) (aliases: $($_.aliases -join ', '))" }) -join "`n"
    $system = @"
You extract orders for a Bangladeshi Facebook shop from customer messages written in Bangla, Banglish or English.
Products:
$productList
Rules: use null for any field the customer did not give. Write the phone as 11 ASCII digits starting with 01.
Copy name and address as written (ASCII digits allowed). intent is "inquiry" for price or availability questions
without order details, "order" when the customer wants to buy, otherwise "other". Never invent data.
"@
    $body = @{
        model         = $Model
        max_tokens    = 4000
        system        = $system
        output_config = @{ effort = 'low'; format = @{ type = 'json_schema'; schema = (Get-OrderJsonSchema $Catalog) } }
        fallbacks     = 'default'
        messages      = @(@{ role = 'user'; content = $Text })
    }
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
        'anthropic-beta'    = 'server-side-fallback-2026-07-01'
    }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
                -UseBasicParsing -TimeoutSec 120
            $result = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
            if ($result.stop_reason -ne 'end_turn') { throw "Claude stopped with '$($result.stop_reason)'." }
            $textBlock = $result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
            if (-not $textBlock) { throw 'Claude returned no text block.' }
            $order = $textBlock.text | ConvertFrom-Json
            $order.items = @($order.items)
            return $order
        } catch [System.Net.WebException] {
            $status = 0
            $retryAfter = 0
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                [int]::TryParse([string]$_.Exception.Response.Headers['retry-after'], [ref]$retryAfter) | Out-Null
            }
            $retryable = ($status -eq 0) -or ($status -eq 408) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $retryable -or $attempt -eq $MaxAttempts) { throw "Claude API failed (HTTP $status): $($_.Exception.Message)" }
            $delay = [Math]::Max($retryAfter, [Math]::Pow(2, $attempt))
            Start-Sleep -Seconds $delay
        }
    }
}

function Complete-Order {
    # Validate fields, price the items from the catalog and decide the status.
    param([Parameter(Mandatory)]$Order, [Parameter(Mandatory)]$Catalog)
    $missing = @()
    if ($Order.intent -eq 'order') {
        foreach ($f in 'customer_name', 'phone', 'address') { if (-not $Order.$f) { $missing += $f } }
        if (@($Order.items).Count -eq 0) { $missing += 'items' }
    }
    if ($Order.phone -and $Order.phone -notmatch '^01[3-9]\d{8}$') { $missing += 'phone'; $Order.phone = $null }
    $subtotal = 0
    $lines = @()
    foreach ($it in @($Order.items)) {
        $p = $Catalog.products | Where-Object { $_.id -eq $it.product_id } | Select-Object -First 1
        if (-not $p -or $it.qty -lt 1 -or $Order.intent -ne 'order') { continue }
        $subtotal += $p.price * $it.qty
        $label = "$($p.name_bn) x$($it.qty)"
        if ($it.size) { $label += " ($($it.size))" }
        $lines += $label
    }
    $delivery = 0
    if ($subtotal -gt 0 -and $Order.address) {
        $delivery = $Catalog.delivery.outside_dhaka
        foreach ($k in $Catalog.delivery.dhaka_keywords) {
            if ($Order.address -match [regex]::Escape($k)) { $delivery = $Catalog.delivery.inside_dhaka; break }
        }
    }
    $status = $Order.intent
    if ($Order.intent -eq 'order') { if ($missing.Count -eq 0) { $status = 'ready' } else { $status = 'needs_info' } }
    [pscustomobject]@{
        status        = $status
        customer_name = $Order.customer_name
        phone         = $Order.phone
        address       = $Order.address
        items_text    = $lines -join '; '
        subtotal      = $subtotal
        delivery      = $delivery
        total         = $subtotal + $delivery
        missing       = @($missing | Select-Object -Unique)
    }
}

function New-BanglaReply {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)]$Catalog)
    switch ($Result.status) {
        'ready' {
            "ধন্যবাদ $($Result.customer_name)! আপনার অর্ডার: $($Result.items_text)। পণ্যের দাম ৳$($Result.subtotal) + ডেলিভারি ৳$($Result.delivery) = মোট ৳$($Result.total) (ক্যাশ অন ডেলিভারি)। নিশ্চিত করতে 'হ্যাঁ' লিখুন।"
        }
        'needs_info' {
            $need = ($Result.missing | ForEach-Object { $script:FieldNamesBn[$_] }) -join ', '
            "ধন্যবাদ! অর্ডারটি নিশ্চিত করতে আপনার $need পাঠাবেন কি?"
        }
        'inquiry' {
            $prices = ($Catalog.products | ForEach-Object { "$($_.name_bn) ৳$($_.price)" }) -join ', '
            "জি, আমাদের দাম: $prices। অর্ডার করতে নাম, ফোন নম্বর আর ঠিকানা পাঠান।"
        }
        default { "আসসালামু আলাইকুম! $($Catalog.shop_name)-এ স্বাগতম। কোন পণ্যটি দেখতে চান জানালে সাহায্য করব।" }
    }
}

function Invoke-OrderPipeline {
    # Process a JSONL inbox once: idempotent per message id, one log line per message.
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$OutDir,
        [ValidateSet('Auto', 'Rules', 'Claude')][string]$Engine = 'Auto',
        [string]$Model = 'claude-opus-5-5',
        [switch]$Force
    )
    $catalog = Import-Catalog $CatalogPath
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $statePath = Join-Path $OutDir 'state.json'
    $logPath = Join-Path $OutDir 'run.log.jsonl'
    $done = @{}
    if ((Test-Path $statePath) -and -not $Force) {
        foreach ($id in (Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json)) { $done[$id] = $true }
    }
    $useClaude = ($Engine -eq 'Claude') -or ($Engine -eq 'Auto' -and $env:ANTHROPIC_API_KEY)
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $InputPath -Encoding UTF8)) {
        if (-not $line.Trim()) { continue }
        $msg = $line | ConvertFrom-Json
        if ($done.ContainsKey($msg.id)) { continue }
        $engineUsed = 'rules'
        $note = ''
        $order = $null
        if ($useClaude) {
            try { $order = Invoke-ClaudeOrderExtraction -Text $msg.text -Catalog $catalog -Model $Model; $engineUsed = 'claude' }
            catch { $note = "claude failed, used rules: $($_.Exception.Message)" }
        }
        if (-not $order) { $order = Get-RuleBasedOrder -Text $msg.text -Catalog $catalog }
        $result = Complete-Order -Order $order -Catalog $catalog
        $reply = New-BanglaReply -Result $result -Catalog $catalog
        $rows += [pscustomobject]@{
            message_id    = $msg.id
            status        = $result.status
            customer_name = $result.customer_name
            phone         = $result.phone
            address       = $result.address
            items         = $result.items_text
            subtotal      = $result.subtotal
            delivery      = $result.delivery
            total         = $result.total
            missing       = $result.missing -join ','
            engine        = $engineUsed
            reply_bn      = $reply
        }
        $done[$msg.id] = $true
        $log = @{ at = (Get-Date).ToString('o'); id = $msg.id; status = $result.status; engine = $engineUsed; note = $note }
        Add-Content -LiteralPath $logPath -Value ($log | ConvertTo-Json -Compress) -Encoding UTF8
    }
    if ($rows.Count -gt 0) {
        $csv = Join-Path $OutDir 'orders.csv'
        $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -Append:(Test-Path $csv)
    }
    ConvertTo-Json -InputObject @($done.Keys) | Set-Content -LiteralPath $statePath -Encoding UTF8
    , $rows
}

Export-ModuleMember -Function Import-Catalog, ConvertTo-NormalText, Get-RuleBasedOrder, Invoke-ClaudeOrderExtraction, `
    Complete-Order, New-BanglaReply, Invoke-OrderPipeline
