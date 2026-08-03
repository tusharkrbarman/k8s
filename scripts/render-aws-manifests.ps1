[CmdletBinding()]
param(
  [string]$TerraformDir = ".\terraform\aws",
  [string]$SourceDir = ".\k8s\aws",
  [string]$OutputDir = ".\tmp\rendered-aws"
)

$ErrorActionPreference = "Stop"

$terraformPath = [IO.Path]::GetFullPath($TerraformDir)
$sourcePath = [IO.Path]::GetFullPath($SourceDir)
$outputPath = [IO.Path]::GetFullPath($OutputDir)

if (-not (Test-Path -LiteralPath $terraformPath -PathType Container)) {
  throw "Terraform directory was not found: $terraformPath"
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
  throw "Manifest source directory was not found: $sourcePath"
}

function Get-TerraformOutputValue {
  param([Parameter(Mandatory)][string]$Name)

  Push-Location $terraformPath
  try {
    $value = (& terraform output -raw $Name 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
      throw "Could not read Terraform output '$Name'. Run the AWS Terraform root first."
    }
  }
  finally {
    Pop-Location
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Terraform output '$Name' is empty."
  }

  return $value
}

$region = Get-TerraformOutputValue "cluster_region"
$gatewayImage = Get-TerraformOutputValue "gateway_image_reference"
$modelBucket = Get-TerraformOutputValue "model_bucket_name"
$modelPrefix = Get-TerraformOutputValue "model_prefix"
$secretName = Get-TerraformOutputValue "gateway_api_key_secret_name"
$albSecurityGroup = Get-TerraformOutputValue "internal_alb_security_group_id"

$sourceFiles = Get-ChildItem -LiteralPath $sourcePath -Filter "*.yaml" -File |
  Where-Object { $_.Name -ne "argocd-application.yaml" }

if ($sourceFiles.Count -eq 0) {
  throw "No Kubernetes YAML files were found in $sourcePath"
}

$secretValuePatterns = @(
  "(?i)api-key-value",
  "(?i)sk-[A-Za-z0-9]{20,}",
  "(?i)Bearer\s+[A-Za-z0-9._-]{16,}"
)

foreach ($sourceFile in $sourceFiles) {
  $sourceContent = Get-Content -LiteralPath $sourceFile.FullName -Raw
  foreach ($pattern in $secretValuePatterns) {
    if ($sourceContent -match $pattern) {
      throw "A possible secret value was found in source manifest: $($sourceFile.Name)"
    }
  }
}

$modelMatch = [regex]::Match(
  (($sourceFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"),
  "OpenVINO/[A-Za-z0-9._/-]+"
)

if (-not $modelMatch.Success) {
  throw "Could not find the source OpenVINO model prefix in the manifests."
}

$sourceModelPrefix = $modelMatch.Value
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

foreach ($sourceFile in $sourceFiles) {
  $content = Get-Content -LiteralPath $sourceFile.FullName -Raw
  $content = $content.Replace($sourceModelPrefix, $modelPrefix)

  switch ($sourceFile.Name) {
    "ovms-blue.yaml" {
      $content = $content -replace "s3://[^/\s]+/[^\s\r\n]+", "s3://$modelBucket/$modelPrefix"
    }
    "ovms-green.yaml" {
      $content = $content -replace "s3://[^/\s]+/[^\s\r\n]+", "s3://$modelBucket/$modelPrefix"
    }
    "gateway.yaml" {
      $content = [regex]::Replace($content, "(?m)^(\s+image:\s+).+$", {
        param($match)
        $match.Groups[1].Value + $gatewayImage
      })
    }
    "gateway-secret-provider.yaml" {
      $content = [regex]::Replace($content, "(?m)^(\s+region:\s+).+$", {
        param($match)
        $match.Groups[1].Value + $region
      })
      $content = [regex]::Replace($content, "(?m)^(\s+objectName:\s+).+$", {
        param($match)
        $match.Groups[1].Value + '"' + $secretName + '"'
      })
    }
    "gateway-ingress.yaml" {
      $content = [regex]::Replace($content, "(?m)^(\s+alb\.ingress\.kubernetes\.io/security-groups:\s+).+$", {
        param($match)
        $match.Groups[1].Value + $albSecurityGroup
      })
    }
  }

  if ($content -match "REPLACE_WITH_") {
    throw "Unresolved placeholder found while rendering $($sourceFile.Name)"
  }

  Set-Content -LiteralPath (Join-Path $outputPath $sourceFile.Name) -Value $content -Encoding utf8
}

Write-Output "Rendered $($sourceFiles.Count) Kubernetes manifests to $outputPath"
