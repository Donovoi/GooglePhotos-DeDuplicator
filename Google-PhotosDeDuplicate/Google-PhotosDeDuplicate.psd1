@{
    RootModule = 'GooglePhotosDeDuplicate.Core.psm1'
    ModuleVersion = '0.1.0'
    GUID = '5a32731a-0c5d-48de-85a3-9e7ac5c3147a'
    Author = 'Donovoi'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Donovoi. All rights reserved.'
    Description = 'Local-first Google Photos duplicate scanner and cautious browser-driven remover for Chrome.'
    PowerShellVersion = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Connect-GPDBrowser',
        'Test-GPDEnvironment',
        'Start-GPDLibraryScan',
        'Get-GPDMediaItem',
        'Resolve-GPDMediaItem',
        'Get-GPDDuplicateGroup',
        'Export-GPDReport',
        'Remove-GPDMediaItem',
        'Invoke-GPDDeduplication',
        'Invoke-GPDDetractorReview'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('GooglePhotos','Deduplication','Chrome','CDP','Photos')
            LicenseUri = 'https://github.com/Donovoi/GooglePhotos-DeDuplicator/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Donovoi/GooglePhotos-DeDuplicator'
            Prerelease = 'alpha1'
        }
    }
}
