Bacterial downstream example data

counts_example.tsv
  240 genes by 24 samples. The first 20 genes are simulated as upregulated and the next 20 as downregulated in Treatment.

metadata_example.tsv
  Sample ID, condition, and batch for the 24 samples.

gene_coordinates_example.tsv
  Gene ID, chromosome, start, end, and strand for the interactive circular genome plot.

term2gene_example.tsv
  Custom gene-to-term mapping containing GO-like, KEGG-like, COG-like, and regulon categories.

regulators_example.tsv
  Example transcription-factor or regulator list for GENIE3.

Suggested first test

1. Differential expression
   Counts: counts_example.tsv
   Metadata: metadata_example.tsv
   Coordinates: gene_coordinates_example.tsv
   Condition: condition
   Reference: Control
   Test: Treatment
   Batch: batch

2. Combined functional analysis
   Click Use latest DE analysis results, Scan DE / functional folder, or Manual Excel input.
   The same scan loads differential_expression.tsv, normalized_counts.tsv, and analysis_metadata.tsv from step 1.
   Mapping: term2gene_example.tsv, or enable online annotation once for both analyses.
   Enrichment method: clusterProfiler ORA, fgsea, or topGO.
   Network method: CEMiTool, WGCNA, or GENIE3.
   Click Run combined analysis once. The result folder contains one Excel workbook and one interactive HTML report with both analysis sections.

Functional Enrichment and Co-expression example inputs.xlsx contains the complete manual-input structure in one workbook.

Guided manual Excel input

The "Manual input workbooks" folder contains one workbook for each supported analysis entry point:
Differential Expression, Functional Enrichment and Co-expression, Co-expression/Network,
STRING PPI, Pathway Database Analysis, Transcript Discovery, and TU Architecture.
Manual Excel input opens these structures directly inside the application. Pale examples appear
immediately inside empty cells and do not become input values. Type or paste real data, then choose
Use data. Excel import/export is optional, and exported workbooks contain no separate example sheets.
