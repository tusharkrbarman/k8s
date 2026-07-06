param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$ApiKey
)

$chatUrl = "$($Url.TrimEnd('/'))/chat"
$headers = @{
    'X-API-Key' = $ApiKey
}
$body = @{
    message = 'Say hello in one short sentence.'
    max_tokens = 16
} | ConvertTo-Json

Invoke-RestMethod `
    -Method Post `
    -Uri $chatUrl `
    -ContentType 'application/json' `
    -Headers $headers `
    -Body $body |
    Format-List *
