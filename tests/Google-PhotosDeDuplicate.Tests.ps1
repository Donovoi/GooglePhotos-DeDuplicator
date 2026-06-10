BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\Google-PhotosDeDuplicate\Google-PhotosDeDuplicate.psd1'
    Import-Module $modulePath -Force

    function New-TestDatabase {
        $path = Join-Path $TestDrive 'google-photos-test.jsonl'
        $items = @(
            [pscustomobject]@{
                RecordType = 'MediaItem'; LocalId = 'a1'; Kind = 'Photo'; ItemUrl = 'https://photos.google.com/photo/a1'; MediaKey = 'a1'; ThumbnailUrl = 'https://lh3.googleusercontent.com/a'; VisualHash64 = 'ffffffffffffffff'; ApproxDate = '2024-01-01'; AriaLabel = 'Photo 2024-01-01'; Width = 1000; Height = 1000; AspectBucket = '1.00'; Deleted = $false
            },
            [pscustomobject]@{
                RecordType = 'MediaItem'; LocalId = 'a2'; Kind = 'Photo'; ItemUrl = 'https://photos.google.com/photo/a2'; MediaKey = 'a2'; ThumbnailUrl = 'https://lh3.googleusercontent.com/b'; VisualHash64 = 'fffffffffffffffe'; ApproxDate = '2024-01-01'; AriaLabel = 'Photo 2024-01-01'; Width = 900; Height = 900; AspectBucket = '1.00'; Deleted = $false
            },
            [pscustomobject]@{
                RecordType = 'MediaItem'; LocalId = 'b1'; Kind = 'Video'; ItemUrl = 'https://photos.google.com/photo/b1'; MediaKey = 'b1'; ThumbnailUrl = 'https://lh3.googleusercontent.com/c'; VisualHash64 = '0000000000000000'; ApproxDate = '2024-01-02'; AriaLabel = 'Video 2024-01-02'; Width = 1920; Height = 1080; AspectBucket = '1.78'; Deleted = $false
            }
        )
        $items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

Describe 'Google-PhotosDeDuplicate module' {
    It 'imports and exposes public commands' {
        Get-Command -Module Google-PhotosDeDuplicate | Select-Object -ExpandProperty Name | Should -Contain 'Resolve-GPDMediaItem'
        Get-Command -Module Google-PhotosDeDuplicate | Select-Object -ExpandProperty Name | Should -Contain 'Remove-GPDMediaItem'
        Get-Command -Module Google-PhotosDeDuplicate | Select-Object -ExpandProperty Name | Should -Contain 'Invoke-GPDDetractorReview'
    }

    It 'resolves a unique item by LocalId' {
        $db = New-TestDatabase
        $result = Resolve-GPDMediaItem -DatabasePath $db -LocalId 'a1'
        $result | Should -HaveCount 1
        $result.LocalId | Should -Be 'a1'
    }

    It 'resolves composite visual hash identity' {
        $db = New-TestDatabase
        $result = Resolve-GPDMediaItem -DatabasePath $db -VisualHash64 'fffffffffffffffe' -ApproxDate '2024-01-01' -Kind Photo
        $result | Should -HaveCount 1
        $result.LocalId | Should -Be 'a2'
    }

    It 'finds conservative visual duplicate groups' {
        $db = New-TestDatabase
        $groups = @(Get-GPDDuplicateGroup -DatabasePath $db -Similarity Conservative)
        $groups.Count | Should -BeGreaterOrEqual 1
        ($groups | Where-Object { $_.Members.LocalId -contains 'a1' -and $_.Members.LocalId -contains 'a2' }) | Should -Not -BeNullOrEmpty
    }

    It 'exports an HTML report' {
        $db = New-TestDatabase
        $report = Join-Path $TestDrive 'report.html'
        $result = Export-GPDReport -DatabasePath $db -Path $report
        Test-Path -LiteralPath $report | Should -BeTrue
        $result.GroupCount | Should -BeGreaterOrEqual 1
        Get-Content -LiteralPath $report -Raw | Should -Match 'Google Photos Duplicate Review'
    }

    It 'passes detractor review' {
        $review = Invoke-GPDDetractorReview
        $review.Passed | Should -BeTrue
    }
}
