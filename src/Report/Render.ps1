# Render.ps1 — merges run data, catalogue and translations into the single-file offline HTML template.

function ConvertTo-CrReport {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$I18n,
        [Parameter(Mandatory)]$Manifest,
        [ValidateSet('de', 'en')][string]$Language = 'de',
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutFile
    )
    $slim = [ordered]@{}
    foreach ($k in $Data.Keys) { $slim[$k] = $Data[$k] }
    $slim.results = @($Data.results | ForEach-Object {
            [ordered]@{ Id = $_.Id; State = $_.State; Score = $_.Score; Msg = $_.Msg; Args = $_.Args; Summary = $_.Summary; Evidence = @($_.Evidence | Where-Object { $null -ne $_ }); Detail = $_.Detail; DurationMs = $_.DurationMs }
        })
    $payload = [ordered]@{
        lang     = $Language
        product  = $Manifest.product
        scoring  = $Manifest.scoring
        data     = $slim
        catalog  = $Catalog
        i18n     = $I18n
    }
    # '</' is escaped so evidence text can never close the script element
    $json = ($payload | ConvertTo-Json -Depth 16 -Compress).Replace('</', '<\/')
    $html = (Get-Content $TemplatePath -Raw -Encoding utf8).Replace('/*__CR_PAYLOAD__*/null', $json)
    Set-Content -Path $OutFile -Value $html -Encoding utf8
}
