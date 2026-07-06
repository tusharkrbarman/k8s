param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [int]$Runs = 5
)

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$chatUrl = "$($Url.TrimEnd('/'))/chat"
$headers = @{
    'X-API-Key' = $ApiKey
}
$rows = @()

for ($run = 1; $run -le $Runs; $run++) {
    $body = @{
        message = 'Explain Kubernetes in one concise paragraph.'
        max_tokens = 48
    } | ConvertTo-Json

    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $chatUrl `
            -ContentType 'application/json' `
            -Headers $headers `
            -Body $body
        $timer.Stop()

        $usage = Get-OptionalProperty -Object $response -Name 'usage'
        $completionTokens = Get-OptionalProperty -Object $usage -Name 'completion_tokens'
        $totalTokens = Get-OptionalProperty -Object $usage -Name 'total_tokens'
        $tokensPerSecond = $null

        if ($null -ne $completionTokens -and $timer.Elapsed.TotalSeconds -gt 0) {
            $tokensPerSecond = [math]::Round(([double]$completionTokens / $timer.Elapsed.TotalSeconds), 2)
        }

        $rows += [pscustomobject]@{
            Run = $run
            Status = 'OK'
            ElapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
            CompletionTokens = $completionTokens
            TotalTokens = $totalTokens
            TokensPerSecond = $tokensPerSecond
            Error = ''
        }
    }
    catch {
        $timer.Stop()

        $rows += [pscustomobject]@{
            Run = $run
            Status = 'FAILED'
            ElapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
            CompletionTokens = $null
            TotalTokens = $null
            TokensPerSecond = $null
            Error = $_.Exception.Message
        }
    }
}

$rows | Format-Table -AutoSize

$successfulRows = @($rows | Where-Object { $_.Status -eq 'OK' })
if ($successfulRows.Count -gt 0) {
    $averageElapsed = ($successfulRows | Measure-Object -Property ElapsedSeconds -Average).Average
    $averageCompletionTokens = ($successfulRows | Where-Object { $null -ne $_.CompletionTokens } | Measure-Object -Property CompletionTokens -Average).Average
    $averageTotalTokens = ($successfulRows | Where-Object { $null -ne $_.TotalTokens } | Measure-Object -Property TotalTokens -Average).Average
    $averageTokensPerSecond = ($successfulRows | Where-Object { $null -ne $_.TokensPerSecond } | Measure-Object -Property TokensPerSecond -Average).Average

    [pscustomobject]@{
        SuccessfulRuns = $successfulRows.Count
        AverageElapsedSeconds = if ($null -ne $averageElapsed) { [math]::Round($averageElapsed, 2) } else { $null }
        AverageCompletionTokens = if ($null -ne $averageCompletionTokens) { [math]::Round($averageCompletionTokens, 2) } else { $null }
        AverageTotalTokens = if ($null -ne $averageTotalTokens) { [math]::Round($averageTotalTokens, 2) } else { $null }
        AverageTokensPerSecond = if ($null -ne $averageTokensPerSecond) { [math]::Round($averageTokensPerSecond, 2) } else { $null }
    } | Format-List
}
else {
    Write-Warning 'No successful runs; averages are unavailable.'
    exit 1
}
