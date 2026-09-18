param([Parameter(Mandatory=$true)][string]$GuiPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tokens = $null
$errors = $null
$source = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $GuiPath))
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Exercise the actual shared startup callbacks in StrictMode without a Windows
# display. Only the WinForms enum names are replaced by equivalent text values.
$ui = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-JobUi'
}, $true) | Select-Object -First 1
if (-not $ui) { throw 'Set-JobUi is missing.' }
$functionText = $ui.Extent.Text.Replace('[System.Windows.Forms.ProgressBarStyle]::Blocks', "'Blocks'").Replace('[System.Windows.Forms.ProgressBarStyle]::Marquee', "'Marquee'")
Invoke-Expression $functionText

$script:ParameterToolTip = $null
$script:JobMode = 'de'
$script:InitialTab = 'de'
$statusLabel = [pscustomobject]@{ Text = '' }
$progressBar = [pscustomobject]@{ Style = ''; Value = 0; MarqueeAnimationSpeed = 0 }
$stopButton = [pscustomobject]@{ Enabled = $false }
$runDEButton = [pscustomobject]@{ Enabled = $true }
$deAdvancedPackageButton = [pscustomobject]@{ Enabled = $true }
$installEnvironmentButton = [pscustomobject]@{ Enabled = $true }
$checkEnvironmentButton = [pscustomobject]@{ Enabled = $true }
$openDEStudioButton = [pscustomobject]@{ Enabled = $true }

# None of the skipped functional controls is defined in this scope. A stray
# reference would fail here just as it did on the user's DE screen.
Set-JobUi $true 'Running'
if ($runDEButton.Enabled -or -not $stopButton.Enabled) { throw 'DE running controls were not updated.' }
Set-JobUi $false 'Ready'
if (-not $runDEButton.Enabled -or $stopButton.Enabled) { throw 'DE ready controls were not restored.' }

$shown = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -eq '$form' -and
    $node.Member.Value -eq 'Add_Shown'
}, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
if (-not $shown -or $shown.Arguments.Count -ne 1) { throw 'Form Shown handler is missing.' }
$callback = [scriptblock]::Create($shown.Arguments[0].Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
function Set-ResponsiveSplitter { param($Split, $Ratio) $script:SplitCalls++ }
$script:SplitCalls = 0
$deSplit = [pscustomobject]@{}
$deInputPanel = [pscustomobject]@{ Tag = $null }
& $callback
if ($script:SplitCalls -ne 1) { throw 'DE should resize only its own page.' }

# The same callbacks must still manage the functional controls when that page
# is actually built.
$script:InitialTab = 'enrichment'
$script:JobMode = 'combined'
$runEnrichmentButton = [pscustomobject]@{ Enabled = $true }
$runNetworkButton = [pscustomobject]@{ Enabled = $true }
$runKeggMapButton = [pscustomobject]@{ Enabled = $true }
$enrichAdvancedPackageButton = [pscustomobject]@{ Enabled = $true }
$networkAdvancedPackageButton = [pscustomobject]@{ Enabled = $true }
$openEnrichmentStudioButton = [pscustomobject]@{ Enabled = $true }
$openNetworkStudioButton = [pscustomobject]@{ Enabled = $true }
Set-JobUi $true 'Running'
if ($runEnrichmentButton.Enabled -or $runNetworkButton.Enabled) { throw 'Functional running controls were not disabled.' }
$enrichSplit = [pscustomobject]@{}
$networkSplit = [pscustomobject]@{}
$enrichInputPanel = [pscustomobject]@{ Tag = $null }
$script:SplitCalls = 0
& $callback
if ($script:SplitCalls -ne 3) { throw 'Functional page splitters were not resized.' }

Write-Host 'DE and functional startup callbacks pass StrictMode without skipped-control references.'
