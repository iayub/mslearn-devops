#Requires -Version 7.0
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "../Import-EShopWorkItems.ps1")
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Get-Argument {
    param([object[]]$CliArguments, [string]$Name)
    $index = [array]::IndexOf($CliArguments, $Name)
    if ($index -lt 0) { return $null }
    return $CliArguments[$index + 1]
}

function New-TestIteration {
    param([int]$Number)
    return [pscustomobject]@{
        id = 100 + $Number
        identifier = "00000000-0000-0000-0000-00000000000$Number"
        name = "Iteration $Number"
        path = "\$($mock.Project)\Iteration\Iteration $Number"
        children = @()
    }
}

function Invoke-TestScenario {
    param(
        [string]$Name,
        [bool]$Existing = $true,
        [string]$ProjectName = "Demo",
        [string]$Failure = "",
        [string]$ExpectedError = ""
    )

    $mock = @{
        Project = $ProjectName
        Existing = $Existing
        Failure = $Failure
        Calls = [System.Collections.Generic.List[object]]::new()
        Created = 0
        Root = [pscustomobject]@{
            name = $ProjectName
            path = "\$ProjectName\Iteration"
            children = @()
        }
    }
    if ($Existing) {
        $mock.Root.children = @(1..3 | ForEach-Object { New-TestIteration $_ })
    }

    function Read-Host { param([string]$Prompt) return "y" }

    function az {
        $cliArguments = @($args)
        $mock.Calls.Add($cliArguments)
        $global:LASTEXITCODE = 0
        $command = $cliArguments[0..([Math]::Min(3, $cliArguments.Count - 1))] -join " "

        if ($command -like "account show *") {
            return '{"user":{"name":"test-user"}}'
        }
        if ($command -like "extension list *") {
            return '[{"name":"azure-devops"}]'
        }
        if ($command -like "devops configure *") { return }
        if ($command -eq "devops project list --output") {
            return '{"value":[]}'
        }
        if ($command -eq "devops project show --project") {
            return @{
                name = $mock.Project
                capabilities = @{ processTemplate = @{ templateName = "Agile" } }
            } | ConvertTo-Json -Depth 5
        }

        $failureCommands = @{
            List = "boards iteration project list"
            Update = "boards iteration project update"
            Create = "boards iteration project create"
            TeamList = "boards iteration team list"
            TeamAdd = "boards iteration team add"
            WorkItemCreate = "boards work-item create --title"
            WorkItemLink = "boards work-item relation add"
            WorkItemState = "boards work-item update --id"
        }
        if ($mock.Failure -and $command -eq $failureCommands[$mock.Failure]) {
            $global:LASTEXITCODE = 1
            return
        }

        if ($command -eq "boards iteration project list") {
            return $mock.Root | ConvertTo-Json -Depth 10
        }
        if ($command -eq "boards iteration project update") {
            $path = Get-Argument $cliArguments "--path"
            $node = $mock.Root.children | Where-Object { $_.path -eq $path }
            Assert-True ($null -ne $node) "Update must use an existing classification path."
            if ($mock.Failure -eq "InvalidIdentifier") {
                $node.identifier = "101"
            }
            return $node | ConvertTo-Json -Depth 5
        }
        if ($command -eq "boards iteration project create") {
            Assert-True ($null -eq (Get-Argument $cliArguments "--path")) "Create must use the project root."
            $name = Get-Argument $cliArguments "--name"
            Assert-True ($name -match '^Iteration [1-3]$') "Do not create a synthetic Iteration parent."
            $node = New-TestIteration ([int]$name.Substring($name.Length - 1))
            $mock.Root.children += $node
            return $node | ConvertTo-Json -Depth 5
        }
        if ($command -eq "boards iteration team list") {
            if ($mock.Failure -eq "EmptyTeamList") { return }
            return '[{"id":"00000000-0000-0000-0000-000000000001"}]'
        }
        if ($command -eq "boards iteration team add") {
            $id = Get-Argument $cliArguments "--id"
            Assert-True ($id -in @("00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003")) "Team add must use a GUID and skip existing membership."
            return
        }
        if ($command -eq "boards work-item create --title") {
            if ($mock.Failure -eq "EmptyItem") { return }
            if ($mock.Failure -eq "InvalidJson") { return "not json" }
            if ($mock.Failure -eq "MissingId") { return '{}' }
            $mock.Created++
            return @{ id = $mock.Created } | ConvertTo-Json
        }
        if ($command -eq "boards work-item relation add" -or $command -eq "boards work-item update --id") {
            return
        }
        throw "Unexpected az command: $($cliArguments -join ' ')"
    }

    $caughtError = $null
    try {
        $output = & $ScriptPath -Organization "https://dev.azure.com/test" -Project $ProjectName *>&1
    } catch {
        $caughtError = $_.Exception.Message
    }

    if ($ExpectedError) {
        Assert-True ($caughtError -like "*$ExpectedError*") "Expected '$ExpectedError', got '$caughtError'."
        $expectedCreated = switch ($Failure) {
            "WorkItemLink" { 4 }
            "WorkItemState" { 1 }
            default { 0 }
        }
        Assert-True ($mock.Created -eq $expectedCreated) "Failed imports must stop immediately; expected $expectedCreated creations, got $($mock.Created)."
    } else {
        Assert-True ($null -eq $caughtError) "Import failed: $caughtError"
        Assert-True ($mock.Created -eq 28) "Expected all 28 work items, got $($mock.Created). Output: $($output -join [Environment]::NewLine)"
        $creates = @($mock.Calls | Where-Object { ($_[0..2] -join " ") -eq "boards work-item create" })
        foreach ($call in $creates) {
            $path = Get-Argument $call "--iteration"
            Assert-True ($path -in @(1..3 | ForEach-Object { "$ProjectName\Iteration $_" })) "Invalid work-item iteration argument: $path"
            Assert-True ((Get-Argument $call "--title") -notmatch '"') "Title must not contain literal quote wrappers."
            Assert-True ((Get-Argument $call "--description") -notmatch '"') "Description must not contain literal quote wrappers."
            Assert-True (@($call | Where-Object { $_ -eq "--fields" }).Count -eq 1) "All custom fields must share one --fields argument."
            Assert-True ($call -contains "Microsoft.VSTS.Common.Priority=1" -or $call -contains "Microsoft.VSTS.Common.Priority=2") "Priority must be retained alongside other fields."
            Assert-True (@($call | Where-Object { $_ -like "System.Tags=*" -and $_ -notmatch '"' }).Count -eq 1) "Tags must be retained without literal quotes."
        }
        $boardCalls = @($mock.Calls | Where-Object { $_[0] -eq "boards" })
        foreach ($call in $boardCalls) {
            Assert-True ((Get-Argument $call "--org") -eq "https://dev.azure.com/test") "Organization must be explicit."
            Assert-True ((Get-Argument $call "--detect") -eq "false") "Git auto-detection must be disabled."
            if (($call[0..1] -join " ") -ne "boards work-item" -or $call[2] -eq "create") {
                Assert-True ((Get-Argument $call "--project") -eq $ProjectName) "Project must be explicit."
            }
        }
        $adds = @($mock.Calls | Where-Object { ($_[0..3] -join " ") -eq "boards iteration team add" })
        Assert-True ($adds.Count -eq 2) "Existing team membership must not be added again."
        $updates = @($mock.Calls | Where-Object { ($_[0..3] -join " ") -eq "boards iteration project update" })
        $iterationCreates = @($mock.Calls | Where-Object { ($_[0..3] -join " ") -eq "boards iteration project create" })
        Assert-True ($updates.Count -eq $(if ($Existing) { 3 } else { 0 })) "Unexpected iteration updates."
        Assert-True ($iterationCreates.Count -eq $(if ($Existing) { 0 } else { 3 })) "Unexpected iteration creations."
    }
    Write-Host "PASS: $Name"
}

Invoke-TestScenario -Name "Existing iteration tree and team membership"
Invoke-TestScenario -Name "Missing iterations are created at the project root" -Existing $false
Invoke-TestScenario -Name "Project names with spaces and regex characters" -ProjectName "Demo [QA].Team"
Invoke-TestScenario -Name "List failure" -Failure "List" -ExpectedError "Failed to list project iterations"
Invoke-TestScenario -Name "Update failure" -Failure "Update" -ExpectedError "Failed to update iteration"
Invoke-TestScenario -Name "Create failure" -Existing $false -Failure "Create" -ExpectedError "Failed to create iteration"
Invoke-TestScenario -Name "Invalid GUID" -Failure "InvalidIdentifier" -ExpectedError "no valid path or GUID"
Invoke-TestScenario -Name "Team list failure" -Failure "TeamList" -ExpectedError "Failed to list iterations for team"
Invoke-TestScenario -Name "Empty team list response" -Failure "EmptyTeamList" -ExpectedError "returned no iteration list"
Invoke-TestScenario -Name "Team add failure" -Failure "TeamAdd" -ExpectedError "Failed to add iteration"
Invoke-TestScenario -Name "Work-item create failure" -Failure "WorkItemCreate" -ExpectedError "Failed to create Epic"
Invoke-TestScenario -Name "Empty work-item output" -Failure "EmptyItem" -ExpectedError "no output"
Invoke-TestScenario -Name "Invalid work-item JSON" -Failure "InvalidJson" -ExpectedError "Failed to read the created Epic"
Invoke-TestScenario -Name "Missing work-item ID" -Failure "MissingId" -ExpectedError "no valid ID"
Invoke-TestScenario -Name "State update failure" -Failure "WorkItemState" -ExpectedError "updating its state"
Invoke-TestScenario -Name "Parent link failure" -Failure "WorkItemLink" -ExpectedError "linking to parent"
