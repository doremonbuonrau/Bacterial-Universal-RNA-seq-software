param([Parameter(Mandatory=$true)][string]$GuiPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
class MapMockControl {
    [object]$ClientSize=[pscustomobject]@{Width=1000}
    [int]$Height=0
    [int]$Right=0
    [int]$Top=0
    [int]$Bottom=0
    [bool]$Visible=$true
    [bool]$Checked=$false
    [string]$Text=''
    [int]$SetBoundsCalls=0
    [void]SetBounds([int]$x,[int]$y,[int]$width,[int]$height){$this.Right=$x+$width;$this.Top=$y;$this.Bottom=$y+$height;$this.Height=$height;$this.SetBoundsCalls++}
    [void]SuspendLayout(){}
    [void]ResumeLayout([bool]$performLayout){}
}
$source=[System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $GuiPath))
$match=[regex]::Match($source,'(?s)\$integratedMappingLayoutState=\[pscustomobject\].*?\$layoutIntegratedMappingControls=\{.*?\}\s*\.GetNewClosure\(\)')
if(-not $match.Success){throw 'Mapping closure missing.'}
if($match.Value -match '\(Get-OrganismQueryText'){throw 'The v24 dynamic-scope error has returned.'}
$names=@(
'enrichAnnotationGroup','integratedMappingPanel','enrichAnnotationOrganismText','enrichOnlineAnnotation',
'integratedOptionalMappingToggle','integratedKeggEnabled','integratedStringEnabled','integratedKeggOrganism',
'integratedKeggFind','integratedKeggTest','integratedStringOrganism','integratedStringFind','integratedStringTest',
'integratedStringTypeLabel','integratedStringType','integratedStringScoreLabel','integratedStringScore',
'integratedTerm2GeneLabel','integratedTerm2GeneText','integratedTerm2GeneBrowse',
'integratedBioCycLabel','integratedBioCycText','integratedBioCycBrowse','integratedMetaCycLabel','integratedMetaCycText','integratedMetaCycBrowse',
'keggMapEnabled','keggMapOffline','keggMapIdsLabel','keggMapIdsText','runKeggMapButton','keggMapIdsHelp','keggMapGeneLabel','keggMapGeneText','keggMapGeneBrowse')
foreach($name in $names){Set-Variable -Name $name -Value ([MapMockControl]::new())}
$enrichAnnotationOrganismText.Text='No organism / no taxonomy ID'
Invoke-Expression $match.Value
foreach($width in @(760,1000,1600)){
 $enrichAnnotationGroup.ClientSize=[pscustomobject]@{Width=$width}
 foreach($online in @($false,$true)){
  $enrichOnlineAnnotation.Checked=$online
  foreach($optional in @($false,$true)){
   $integratedOptionalMappingToggle.Checked=$optional
   foreach($map in @($false,$true)){
    $keggMapEnabled.Checked=$map
    & $layoutIntegratedMappingControls
    if($integratedMappingPanel.Bottom -gt $enrichAnnotationGroup.Height){throw 'Mapping panel clipped.'}
    if($map){
     foreach($control in @($keggMapIdsText,$runKeggMapButton,$keggMapGeneText,$keggMapGeneBrowse,$keggMapIdsHelp)){
      if(-not $control.Visible -or $control.Bottom -gt $integratedMappingPanel.Height -or $control.Right -gt $width){throw 'A pathway control is hidden or clipped.'}
     }
     if($keggMapGeneText.Top -le $keggMapIdsText.Bottom){throw 'Pathway input rows overlap.'}
    } elseif($runKeggMapButton.Visible -or $keggMapGeneText.Visible){throw 'Disabled map settings should collapse.'}
    foreach($control in @($integratedTerm2GeneText,$integratedBioCycText,$integratedMetaCycText)){
     if($control.Visible -ne $optional){throw 'All three optional pathway files must toggle together.'}
    }
    if($optional -and $keggMapEnabled.Top -le $integratedMetaCycText.Bottom){throw 'Pathway controls cover MetaCyc input.'}
    $before=$keggMapEnabled.SetBoundsCalls
    & $layoutIntegratedMappingControls
    if($keggMapEnabled.SetBoundsCalls -ne $before){throw 'Unchanged layout is not cached.'}
   }
  }
 }
}
Write-Host '24 online/offline, width and expanded/collapsed layouts pass; all optional files remain visible.'
