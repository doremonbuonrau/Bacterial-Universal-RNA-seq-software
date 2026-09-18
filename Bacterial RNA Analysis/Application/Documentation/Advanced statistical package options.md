# Guided statistical package options

Differential Expression and the combined functional-analysis workspace provide **Guided package options...** for documented package and database-API arguments.

## Supported packages

Differential Expression uses guided options for DESeq2, edgeR, and limma-voom. GO/Enrichment uses clusterProfiler, fgsea, and topGO. Network analysis uses WGCNA, CEMiTool, and GENIE3. The combined workspace also retains dedicated KEGG and STRING pages: KEGG accepts an organism code, while STRING accepts its numeric taxonomy ID, physical/functional network type, 0–1000 required score, added-partner count, and an optional verified identifier-alias table.

## Offline manuals

Every package-function page has **Open offline manual**. The manual is bundled inside `Documentation/Offline manuals/Statistical packages` and opens without Internet access. It lists the functions used by this application, the documented arguments exposed in the GUI, their guided defaults, protected workflow arguments, and the official package source.

## Guided-only policy

Free-form unlisted JSON or R arguments are intentionally not exposed. Only the named, documented arguments shown in the guided table can be overridden. Data objects, designs, contrasts, gene sets, mappings, fitted objects, and other workflow-owned arguments remain protected.

The run log still records the effective package/API calls and selected overrides for reproducibility.
