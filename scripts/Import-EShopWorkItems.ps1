# EShopOnWeb Work Items Import Script
# Prerequisites: az extension add --name azure-devops

param(
    [string]$Organization = "",
    [string]$Project = ""
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  EShopOnWeb Work Items Import Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ============================================
# VALIDATE AZURE CLI LOGIN
# ============================================
Write-Host "`nChecking Azure CLI login status..." -ForegroundColor Yellow

try {
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if ($account) {
        Write-Host "  Logged in as: $($account.user.name)" -ForegroundColor Green
    } else {
        throw "Not logged in"
    }
} catch {
    Write-Host "  ERROR: You are not logged in to Azure CLI." -ForegroundColor Red
    Write-Host "  Please run 'az login' first and try again." -ForegroundColor Yellow
    exit 1
}

# ============================================
# VALIDATE AZURE DEVOPS EXTENSION
# ============================================
Write-Host "`nChecking Azure DevOps extension..." -ForegroundColor Yellow

$extensions = az extension list --output json | ConvertFrom-Json
$devopsExt = $extensions | Where-Object { $_.name -eq "azure-devops" }

if (-not $devopsExt) {
    Write-Host "  Azure DevOps extension not found. Installing..." -ForegroundColor Yellow
    az extension add --name azure-devops
    Write-Host "  Azure DevOps extension installed." -ForegroundColor Green
} else {
    Write-Host "  Azure DevOps extension is installed." -ForegroundColor Green
}

# ============================================
# GET ORGANIZATION
# ============================================
Write-Host "`n----------------------------------------" -ForegroundColor DarkGray

# Helper function to get configured defaults
function Get-AzDevOpsDefault {
    param([string]$ConfigName)
    $configOutput = az devops configure --list 2>$null
    if ($configOutput) {
        foreach ($line in $configOutput) {
            if ($line -match $ConfigName) {
                # For organization, extract just the org name from the URL
                if ($ConfigName -eq "organization" -and $line -match "dev\.azure\.com/([a-zA-Z0-9_-]+)") {
                    return $Matches[1]
                }
                # For project, extract value after = sign
                if ($ConfigName -eq "project" -and $line -match "=\s*(.+)$") {
                    $value = $Matches[1].Trim()
                    if ($value -and $value -ne "None" -and $value -ne "(not set)") {
                        return $value
                    }
                }
            }
        }
    }
    return $null
}

# If command-line parameter provided, use it
if ($Organization) {
    if ($Organization -notlike "https://*") {
        $Organization = "https://dev.azure.com/$Organization"
    }
    Write-Host "  Using provided organization: $Organization" -ForegroundColor Cyan
} else {
    $defaultOrg = Get-AzDevOpsDefault -ConfigName "organization"
    if ($defaultOrg) {
        $inputOrg = Read-Host "Enter Azure DevOps Organization name [$defaultOrg]"
        if (-not $inputOrg) { 
            $Organization = "https://dev.azure.com/$defaultOrg" 
        } else {
            if ($inputOrg -notlike "https://*") {
                $Organization = "https://dev.azure.com/$inputOrg"
            } else {
                $Organization = $inputOrg
            }
        }
    } else {
        $Organization = Read-Host "Enter Azure DevOps Organization (name or full URL)"
        if (-not $Organization) {
            Write-Host "  ERROR: Organization is required." -ForegroundColor Red
            exit 1
        }
        if ($Organization -notlike "https://*") {
            $Organization = "https://dev.azure.com/$Organization"
        }
    }
}

Write-Host "  Organization: $Organization" -ForegroundColor Cyan

# Set organization for project listing
az devops configure --defaults organization=$Organization 2>$null

# ============================================
# GET PROJECTS IN SELECTED ORGANIZATION
# ============================================
Write-Host "`nFetching projects from organization..." -ForegroundColor Yellow

try {
    $projectsJson = az devops project list --output json 2>$null
    if ($projectsJson) {
        $projects = ($projectsJson | ConvertFrom-Json).value
    } else {
        $projects = @()
    }
} catch {
    $projects = @()
}

# If command-line parameter provided, use it
if ($Project) {
    Write-Host "  Using provided project: $Project" -ForegroundColor Cyan
} elseif ($projects.Count -gt 0) {
    # Display numbered list of projects
    Write-Host "`nAvailable Projects:" -ForegroundColor Cyan
    Write-Host "-------------------" -ForegroundColor DarkGray
    
    $projList = @()
    $index = 1
    foreach ($proj in $projects) {
        $projList += $proj.name
        $processInfo = ""
        if ($proj.capabilities.processTemplate.templateName) {
            $processInfo = " (Process: $($proj.capabilities.processTemplate.templateName))"
        }
        Write-Host "  [$index] $($proj.name)$processInfo" -ForegroundColor White
        $index++
    }
    
    Write-Host ""
    $selection = Read-Host "Select project (1-$($projList.Count))"
    
    if ($selection -match '^\d+$') {
        $selIndex = [int]$selection - 1
        if ($selIndex -ge 0 -and $selIndex -lt $projList.Count) {
            $Project = $projList[$selIndex]
            Write-Host "  Selected: $Project" -ForegroundColor Green
        } else {
            Write-Host "  ERROR: Invalid selection." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  ERROR: Please enter a number." -ForegroundColor Red
        exit 1
    }
} else {
    # Fallback to manual entry
    Write-Host "  Could not retrieve projects automatically." -ForegroundColor Yellow
    $Project = Read-Host "Enter Azure DevOps Project name (e.g., EShopOnWeb)"
    if (-not $Project) {
        Write-Host "  ERROR: Project name is required." -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Project: $Project" -ForegroundColor Cyan

# ============================================
# CONFIGURE DEFAULTS
# ============================================
Write-Host "`nConfiguring Azure DevOps defaults..." -ForegroundColor Yellow
az devops configure --defaults organization=$Organization project=$Project

# ============================================
# VALIDATE PROJECT ACCESS
# ============================================
Write-Host "Validating project access..." -ForegroundColor Yellow

try {
    $projectInfo = az devops project show --project $Project --output json 2>$null | ConvertFrom-Json
    if ($projectInfo) {
        Write-Host "  Project '$($projectInfo.name)' found. Process: $($projectInfo.capabilities.processTemplate.templateName)" -ForegroundColor Green
    } else {
        throw "Project not found"
    }
} catch {
    Write-Host "  ERROR: Cannot access project '$Project'." -ForegroundColor Red
    Write-Host "  Please verify the project exists and you have access." -ForegroundColor Yellow
    exit 1
}

# ============================================
# CONFIRM BEFORE PROCEEDING
# ============================================
Write-Host "`n----------------------------------------" -ForegroundColor DarkGray
Write-Host "Ready to import work items:" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor DarkGray

$confirm = Read-Host "Proceed with import? (Y/n)"
if ($confirm -eq "n" -or $confirm -eq "N") {
    Write-Host "Import cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nStarting EShopOnWeb work items import..." -ForegroundColor Cyan

# ============================================
# UPDATE EXISTING ITERATIONS WITH DATES
# ============================================
Write-Host "`nConfiguring Iterations..." -ForegroundColor Yellow

# Get today's date for iteration planning
$iterationStart = Get-Date
$iterationDuration = 14  # 2-week iterations
$iterationCount = 3
$script:availableIterations = @()

function Get-ProjectIterations {
    $iterationJson = az boards iteration project list --depth 1 --org $Organization --project $Project --detect false --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list project iterations."
    }

    if (-not $iterationJson) {
        throw "Azure DevOps returned no project iteration tree."
    }

    return $iterationJson | ConvertFrom-Json -ErrorAction Stop
}

$iterationRoot = Get-ProjectIterations
if (-not $iterationRoot.name -or -not $iterationRoot.path) {
    throw "Azure DevOps returned an invalid project iteration root."
}

for ($i = 1; $i -le $iterationCount; $i++) {
    $iterationName = "Iteration $i"
    $startDate = $iterationStart.AddDays(($i - 1) * $iterationDuration)
    $endDate = $startDate.AddDays($iterationDuration - 1)
    
    $startDateStr = $startDate.ToString("yyyy-MM-dd")
    $endDateStr = $endDate.ToString("yyyy-MM-dd")

    $existingIteration = $iterationRoot.children | Where-Object {
        $_.name -eq $iterationName
    } | Select-Object -First 1

    if ($existingIteration) {
        $iterationJson = az boards iteration project update --path $existingIteration.path --start-date $startDateStr --finish-date $endDateStr --org $Organization --project $Project --detect false --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update iteration '$iterationName'."
        }
    } else {
        $iterationJson = az boards iteration project create --name $iterationName --start-date $startDateStr --finish-date $endDateStr --org $Organization --project $Project --detect false --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create iteration '$iterationName'."
        }
    }

    $iteration = $iterationJson | ConvertFrom-Json -ErrorAction Stop
    $rootPrefix = "$($iterationRoot.path)\"
    $identifier = [guid]::Empty
    if (-not $iteration -or -not $iteration.path -or
        -not $iteration.path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [guid]::TryParse([string]$iteration.identifier, [ref]$identifier) -or
        $identifier -eq [guid]::Empty) {
        throw "Iteration '$iterationName' returned no valid path or GUID identifier."
    }

    # Classification paths include a synthetic root segment absent from work-item paths.
    $iterationPath = "$($iterationRoot.name)\$($iteration.path.Substring($rootPrefix.Length))"
    $script:availableIterations += [pscustomobject]@{
        Path       = $iterationPath
        Identifier = $identifier.ToString()
    }
    Write-Host "  Configured $iterationPath ($startDateStr to $endDateStr)" -ForegroundColor Green
}

# Add discovered iterations to team backlog
Write-Host "`nAdding Iterations to Team backlog..." -ForegroundColor Yellow
$team = "$Project Team"
$teamIterationsJson = az boards iteration team list --team $team --org $Organization --project $Project --detect false --output json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Failed to list iterations for team '$team'."
}
if (-not $teamIterationsJson) {
    throw "Azure DevOps returned no iteration list for team '$team'."
}
$teamIterations = $teamIterationsJson | ConvertFrom-Json -ErrorAction Stop
foreach ($iteration in $script:availableIterations) {
    if ($teamIterations.id -contains $iteration.Identifier) {
        Write-Host "  $($iteration.Path) is already in team backlog" -ForegroundColor DarkGray
        continue
    }
    az boards iteration team add --id $iteration.Identifier --team $team --org $Organization --project $Project --detect false --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to add iteration '$($iteration.Path)' to team '$team'."
    }
    Write-Host "  Added $($iteration.Path) to team backlog" -ForegroundColor Green
}

# Helper function to get a random iteration path
function Get-RandomIterationPath {
    if (-not $script:availableIterations -or $script:availableIterations.Count -eq 0) {
        throw "No valid iterations available for assignment."
    }

    # Use a discovered valid project-relative iteration path.
    return (Get-Random -InputObject $script:availableIterations).Path
}

# Helper function to create work item and return ID
function New-WorkItem {
    param(
        [string]$Type,
        [string]$Title,
        [string]$Description,
        [string]$State = "New",
        [int]$Priority = 2,
        [string]$Tags = "",
        [int]$StoryPoints = 0,
        [int]$OriginalEstimate = 0,
        [int]$RemainingWork = 0,
        [int]$CompletedWork = 0,
        [string]$Severity = "",
        [int]$ParentId = 0,
        [string]$IterationPath = ""
    )
    
    # Create work item first (always creates in New state)
    $fields = @("Microsoft.VSTS.Common.Priority=$Priority")
    
    if ($Tags) {
        $fields += "System.Tags=$Tags"
    }
    
    if ($StoryPoints -gt 0) {
        $fields += "Microsoft.VSTS.Scheduling.StoryPoints=$StoryPoints"
    }
    
    if ($OriginalEstimate -gt 0) {
        $fields += "Microsoft.VSTS.Scheduling.OriginalEstimate=$OriginalEstimate"
    }
    
    if ($RemainingWork -gt 0) {
        $fields += "Microsoft.VSTS.Scheduling.RemainingWork=$RemainingWork"
    }
    
    if ($CompletedWork -gt 0) {
        $fields += "Microsoft.VSTS.Scheduling.CompletedWork=$CompletedWork"
    }
    
    if ($Severity) {
        $fields += "Microsoft.VSTS.Common.Severity=$Severity"
    }

    $createArguments = @(
        "--title", $Title,
        "--type", $Type,
        "--description", $Description,
        "--org", $Organization,
        "--project", $Project,
        "--detect", "false",
        "--fields"
    ) + $fields

    if ($IterationPath) {
        $createArguments += "--iteration", $IterationPath
    }
    
    # Debug: show the command being run
    Write-Host "    Debug: Creating with iteration '$IterationPath'" -ForegroundColor DarkGray
    
    $jsonOutput = az boards work-item create @createArguments --output json --only-show-errors
    $createExitCode = $LASTEXITCODE
    
    if ($createExitCode -ne 0) {
        throw "Failed to create $Type : $Title. Import stopped to avoid creating orphaned children."
    }
    
    if (-not $jsonOutput) {
        throw "Failed to create $Type : $Title (no output)."
    }
    
    try {
        $result = $jsonOutput | ConvertFrom-Json -ErrorAction Stop
        $id = $result.id
    } catch {
        throw "Failed to read the created $Type '$Title': $($_.Exception.Message)"
    }
    
    if (-not $id -or $id -le 0) {
        throw "Azure DevOps returned no valid ID for $Type : $Title."
    }
    
    Write-Host "  Created $Type #$id : $Title" -ForegroundColor Green
    
    # Link to parent if specified
    if ($ParentId -gt 0 -and $id -gt 0) {
        az boards work-item relation add --id $id --relation-type Parent --target-id $ParentId --org $Organization --detect false --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Work item #$id was created, but linking to parent #$ParentId failed."
        }
        Write-Host "    Linked to parent #$ParentId" -ForegroundColor DarkGray
    }
    
    # Update state if not "New" (must be done after creation)
    if ($State -ne "New") {
        az boards work-item update --id $id --fields "System.State=$State" --org $Organization --detect false --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Work item #$id was created, but updating its state to '$State' failed."
        }
        Write-Host "    State: $State" -ForegroundColor DarkYellow
    }
    
    return $id
}

# ============================================
# EPICS (3 epics with varied states)
# ============================================
Write-Host "`nCreating Epics..." -ForegroundColor Yellow

$epicPlatform = New-WorkItem -Type "Epic" -Title "E-Commerce Platform Modernization" `
    -Description "Modernize the EShopOnWeb platform to improve performance and scalability" `
    -State "Active" -Priority 1 -Tags "modernization;platform" -IterationPath (Get-RandomIterationPath)

$epicMobile = New-WorkItem -Type "Epic" -Title "Mobile Experience Enhancement" `
    -Description "Develop and optimize mobile shopping experience for iOS and Android users" `
    -State "Active" -Priority 2 -Tags "mobile;ux" -IterationPath (Get-RandomIterationPath)

$epicPayment = New-WorkItem -Type "Epic" -Title "Payment & Checkout Optimization" `
    -Description "Streamline payment processing and checkout flow to reduce cart abandonment" `
    -State "New" -Priority 1 -Tags "payments;checkout" -IterationPath (Get-RandomIterationPath)

# ============================================
# FEATURES (5 features linked to epics)
# ============================================
Write-Host "`nCreating Features..." -ForegroundColor Yellow

# Platform Epic Features
$featCatalog = New-WorkItem -Type "Feature" -Title "Product Catalog Redesign" `
    -Description "Redesign product catalog with improved filtering and search capabilities" `
    -State "Active" -Priority 1 -Tags "catalog;search" -StoryPoints 13 -ParentId $epicPlatform -IterationPath (Get-RandomIterationPath)

$featAuth = New-WorkItem -Type "Feature" -Title "User Authentication & Profile" `
    -Description "Implement modern authentication with social login and enhanced profiles" `
    -State "New" -Priority 1 -Tags "auth;security" -StoryPoints 8 -ParentId $epicPlatform -IterationPath (Get-RandomIterationPath)

# Mobile Epic Features
$featMobileUI = New-WorkItem -Type "Feature" -Title "Responsive Mobile UI" `
    -Description "Create fully responsive UI optimized for mobile devices" `
    -State "New" -Priority 1 -Tags "mobile;responsive" -StoryPoints 13 -ParentId $epicMobile -IterationPath (Get-RandomIterationPath)

# Payment Epic Features
$featPaymentGateway = New-WorkItem -Type "Feature" -Title "Payment Gateway Integration" `
    -Description "Integrate multiple payment gateways including Stripe and PayPal" `
    -State "New" -Priority 1 -Tags "payments;integration" -StoryPoints 13 -ParentId $epicPayment -IterationPath (Get-RandomIterationPath)

$featOneClick = New-WorkItem -Type "Feature" -Title "One-Click Checkout" `
    -Description "Implement streamlined one-click checkout for returning customers" `
    -State "New" -Priority 2 -Tags "checkout;ux" -StoryPoints 8 -ParentId $epicPayment -IterationPath (Get-RandomIterationPath)

# ============================================
# USER STORIES (5 stories linked to features)
# ============================================
Write-Host "`nCreating User Stories..." -ForegroundColor Yellow

# Product Catalog Stories
$storySearch = New-WorkItem -Type "User Story" -Title "Implement advanced product search with filters" `
    -Description "As a customer I want to filter products by price brand and size" `
    -State "Active" -Priority 1 -Tags "search;filters" -StoryPoints 5 -ParentId $featCatalog -IterationPath (Get-RandomIterationPath)

$storyImages = New-WorkItem -Type "User Story" -Title "Add product image gallery with zoom" `
    -Description "As a customer I want to view multiple product images and zoom in for details" `
    -State "Closed" -Priority 2 -Tags "images;ux" -StoryPoints 3 -ParentId $featCatalog -IterationPath (Get-RandomIterationPath)

# Authentication Stories
$storySocialLogin = New-WorkItem -Type "User Story" -Title "Add social login options" `
    -Description "As a customer I want to sign in using Google or Facebook for convenience" `
    -State "Active" -Priority 1 -Tags "auth;social" -StoryPoints 5 -ParentId $featAuth -IterationPath (Get-RandomIterationPath)

# Mobile UI Stories
$storyMobileNav = New-WorkItem -Type "User Story" -Title "Implement mobile-optimized navigation" `
    -Description "As a mobile user I want easy thumb-friendly navigation to browse products" `
    -State "New" -Priority 1 -Tags "mobile;navigation" -StoryPoints 5 -ParentId $featMobileUI -IterationPath (Get-RandomIterationPath)

# Payment Stories
$storyStripe = New-WorkItem -Type "User Story" -Title "Integrate Stripe payment processing" `
    -Description "As a customer I want to pay securely with my credit card through Stripe" `
    -State "New" -Priority 1 -Tags "payments;stripe" -StoryPoints 8 -ParentId $featPaymentGateway -IterationPath (Get-RandomIterationPath)

# ============================================
# TASKS (5 tasks linked to stories)
# ============================================
Write-Host "`nCreating Tasks..." -ForegroundColor Yellow

# Search Tasks - linked to search story
New-WorkItem -Type "Task" -Title "Set up Elasticsearch for product search" `
    -Description "Configure and deploy Elasticsearch cluster for product search" `
    -State "Closed" -Priority 1 -Tags "infrastructure;search" -OriginalEstimate 8 -RemainingWork 0 -CompletedWork 8 `
    -ParentId $storySearch -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Task" -Title "Create product filter UI components" `
    -Description "Develop reusable filter components for price range and categories" `
    -State "Active" -Priority 1 -Tags "frontend;components" -OriginalEstimate 16 -RemainingWork 10 -CompletedWork 6 `
    -ParentId $storySearch -IterationPath (Get-RandomIterationPath)

# Image Gallery Tasks - linked to images story
New-WorkItem -Type "Task" -Title "Implement image zoom component" `
    -Description "Create React component for product image zoom functionality" `
    -State "Closed" -Priority 2 -Tags "frontend;images" -OriginalEstimate 8 -RemainingWork 0 -CompletedWork 8 `
    -ParentId $storyImages -IterationPath (Get-RandomIterationPath)

# OAuth Tasks - linked to social login story
New-WorkItem -Type "Task" -Title "Create OAuth integration for Google" `
    -Description "Implement Google OAuth 2.0 authentication flow" `
    -State "Active" -Priority 1 -Tags "auth;google" -OriginalEstimate 8 -RemainingWork 4 -CompletedWork 4 `
    -ParentId $storySocialLogin -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Task" -Title "Create OAuth integration for Facebook" `
    -Description "Implement Facebook Login authentication flow" `
    -State "New" -Priority 2 -Tags "auth;facebook" -OriginalEstimate 8 -RemainingWork 8 `
    -ParentId $storySocialLogin -IterationPath (Get-RandomIterationPath)

# ============================================
# BUGS (5 bugs with varied states)
# ============================================
Write-Host "`nCreating Bugs..." -ForegroundColor Yellow

New-WorkItem -Type "Bug" -Title "Product images not loading on slow connections" `
    -Description "Product images fail to load or timeout on 3G connections" `
    -State "Resolved" -Priority 1 -Tags "images;performance" -Severity "3 - Medium" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Bug" -Title "Search results showing out-of-stock items" `
    -Description "Search results include products that are out of stock without indication" `
    -State "Active" -Priority 2 -Tags "search;inventory" -Severity "2 - High" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Bug" -Title "Cart total not updating after quantity change" `
    -Description "When changing item quantity in cart the total does not update" `
    -State "Closed" -Priority 1 -Tags "cart;calculation" -Severity "2 - High" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Bug" -Title "Mobile menu overlapping content on iOS Safari" `
    -Description "Navigation menu overlaps page content on iOS Safari orientation change" `
    -State "New" -Priority 2 -Tags "mobile;ios" -Severity "3 - Medium" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Bug" -Title "Social login failing with popup blocker" `
    -Description "Social login popup is blocked by default browser settings" `
    -State "Active" -Priority 2 -Tags "auth;popup" -Severity "2 - High" -IterationPath (Get-RandomIterationPath)

# ============================================
# ISSUES (5 issues with varied states)
# ============================================
Write-Host "`nCreating Issues..." -ForegroundColor Yellow

New-WorkItem -Type "Issue" -Title "Third-party shipping API downtime" `
    -Description "FedEx API experiencing intermittent outages affecting order tracking" `
    -State "Active" -Priority 1 -Tags "integration;shipping" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Issue" -Title "Payment gateway rate limits reached" `
    -Description "Stripe rate limits being hit during peak hours causing failures" `
    -State "Active" -Priority 1 -Tags "payments;performance" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Issue" -Title "CDN cache invalidation delays" `
    -Description "Product updates taking up to 2 hours to reflect due to CDN cache" `
    -State "Closed" -Priority 2 -Tags "infrastructure;cdn" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Issue" -Title "Database connection pool exhaustion" `
    -Description "Database connections being exhausted during traffic spikes" `
    -State "Closed" -Priority 1 -Tags "database;performance" -IterationPath (Get-RandomIterationPath)

New-WorkItem -Type "Issue" -Title "SSL certificate expiring next month" `
    -Description "Production SSL certificate expires in 30 days and needs renewal" `
    -State "Active" -Priority 1 -Tags "security;infrastructure" -IterationPath (Get-RandomIterationPath)

# ============================================
# SUMMARY
# ============================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Import Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Created 28 of 28 work items with full hierarchy and varied states."
