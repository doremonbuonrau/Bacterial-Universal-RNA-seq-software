# Functional Enrichment and Co-expression Networks

This is one coordinated analysis module in Bacterial RNA Analysis. One scan loads the differential-expression result, normalized expression matrix, sample metadata, optional regulator list, mapping, and universe. One shared annotation stage feeds both functional enrichment and module/network interpretation. One Run combined analysis action produces one result folder, one verified Excel workbook, and one offline interactive HTML report containing both workspaces.

Use **Parameter guide** for the combined scientific settings and **Guided package options** to browse documented functions for the selected clusterProfiler, fgsea, or topGO enrichment method and the selected CEMiTool, WGCNA, or GENIE3 network method in one dialog. Workflow-owned inputs and fitted objects remain protected, and every effective call is retained in the persistent run log.

Version 1.9.77 v30 adds **Map expression onto KEGG pathways** in section 2. Enter pathway IDs, select the matching organism, and click **Map pathways** to run this sub-operation directly from the DE table without repeating GO or network analysis. The original KEGG diagrams, expression overlays, mapped-gene tables and audit appear in the combined workbook and interactive HTML. See [KEGG pathway expression maps](../../Documentation/KEGG_pathway_expression_maps.md).
