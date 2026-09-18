# Shared downstream components

Internal shared R, Python, WSL2 environment, plotting, examples, and WinForms implementation used by Differential Expression and the combined functional-analysis application:

- Differential Expression
- Functional Enrichment and Co-expression Networks

The functional application uses one scan, one annotation pass, one environment, one coordinated run, one Excel workbook, and one combined interactive HTML report. Legacy GO and network launchers resolve to this same workflow.

## Result organization

`Python/finalize_results.py` creates and reopens a verified Excel-first package for every completed analysis. The combined functional result root contains one workbook with both enrichment and network worksheets, plus one combined interactive HTML report. Automatic figures are stored in `Figures/`, DE genome-browser tracks in `BedGraph/`, and the complete code-bearing log plus the minimum machine-readable handoff/provenance set in `Intermediate files/`. Redundant recognized TSV tables are deleted only after their workbook worksheets are verified. The combined workflow retains the enrichment result and the edge, node, and module-assignment tables needed for later handoff.

## Interactive visualization studio

`Python/visualization_studio.py` builds offline browser workspaces with drag-and-drop roles, immediate Plotly previews, specialized analysis choices, and publication export. The combined HTML uses one Specialized analysis dropdown, one visible plot region, and one curated linked-sheet selector for functional enrichment, network edges, module–trait associations, module expression heatmaps, and module expression trends. Selecting a spreadsheet row focuses its corresponding graph element, and selecting a graph element reveals the linked row. Typography, biological-label visibility, and export settings apply in the same unified workspace.

## Shared Database Library

Reusable online annotation resources are stored outside project result folders at `/root/.local/share/prok-rnaseq/Database Library`. GO/Enrichment and Co-expression/Networks share the same UniProt/Swiss-Prot/TrEMBL FASTA files, annotation tables, and DIAMOND indexes. Existing valid files from the older `~/.cache/bacterial-rna-analysis/functional-annotation` location are migrated automatically. The update control now performs a real release check first. If the local UniProt cache matches the current online release, it is kept and no protein database is downloaded. If UniProt has a newer release, only the affected cached library is refreshed and its DIAMOND index is rebuilt. A failed integrity check or manual deletion still triggers a download.
