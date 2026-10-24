@{
    ExcludeRules = @(
        # Console output is part of the product (progress lines, preflight table).
        'PSAvoidUsingWriteHost'
        # PowerShell 7.2+ only; files are UTF-8 without BOM on purpose (the BOM rule targets Windows PowerShell 5.1).
        'PSUseBOMForUnicodeEncodedFile'
        # Internal helpers named Set-/New-/Start- only change in-memory state or build objects. The one tenant object (the audit search in Start-CrAuditQuery) is documented in the README.
        'PSUseShouldProcessForStateChangingFunctions'
        # Names such as Get-CrScores / Get-CrLabels return collections on purpose.
        'PSUseSingularNouns'
    )
}
