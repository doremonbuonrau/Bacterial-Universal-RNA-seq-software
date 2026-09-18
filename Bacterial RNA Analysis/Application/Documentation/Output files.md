# Analysis-ready output contract

During a run, the workflow writes temporary and resumable work beside a stable `analysis_ready` handoff folder. After a successful real run, it verifies the Excel workbook and every BAM/BAI pair, then removes known regenerable work and groups the small retained handoff/provenance set under `Intermediate files`. Failed or stopped runs keep checkpoints for resume. Short-read and long-read assets remain separated by modality.

| Path | Meaning | Typical downstream use |
|---|---|---|
| `RNA-seq counts.xlsx` | Raw integer count matrices, gene coordinates, and sample metadata | primary spreadsheet for downstream differential expression |
| `RNA-seq QC and alignment.xlsx` | Compact read-QC, alignment, strand-audit, and technical-run summaries | primary spreadsheet for QC review |
| `Alignments/short/primary/*.bam` + `.bai` | Coordinate-sorted primary short-read alignments | operon/antisense tools, IGV |
| `Alignments/long/primary/*.bam` + `.bai` | Coordinate-sorted primary long-read alignments | transcript/isoform tools, operon evidence, IGV |
| `Alignments/*/alternative/` | Independent audit alignment | locus-level sensitivity review; never merge blindly |
| `Coverage tracks/` | compact CPM BigWig by default; optional comprehensive raw/CPM BigWig and bedGraph signal | IGV, operon, UTR, and antisense tools |
| `Reference/reference.fasta` + `.fai` | Exact reference used for alignment | every reference-based downstream task |
| `Reference/annotation.normalized.gff3` | Normalized gene annotation | feature-based tools |
| `QC reports/multiqc report.html` | Consolidated QC | accept/reject and troubleshooting |
| `IGV/Analysis ready session.xml` | Relative-path IGV session | visual inspection |
| `Complete pipeline log.txt` | exact packaged source, configuration, commands, runtime output, executable hashes, and bounded third-party package identity metadata | complete audit trail without enormous package file inventories |
| `Intermediate files/Count tables/* raw counts.tsv` | lossless raw-count matrices retained for automatic module handoff | DESeq2, edgeR, or limma-voom preparation |
| `Intermediate files/Metadata/sample metadata.tsv` | one row per biological Sample ID | experimental design handoff |
| `Intermediate files/Metadata/Third-party package provenance.tsv` | package version, build, channel, license, dependencies, binary/upstream URLs, package hash, and complete metadata-record hash | environment audit and reproduction; also included as an Excel worksheet |
| `Intermediate files/Run manifest.json` | status, methods, warnings, outputs | reproducibility and automation |
| `Checksums.sha256` | SHA-256 integrity list | transfer and archival verification |
| `Analysis Ready Report.html` | human-readable run summary | project handoff |

## Counts and normalization

The primary matrix is unnormalized raw integer counts. FPKM and TPM are not substituted for raw counts in later differential-expression significance testing. FADU output is kept separate because its fractional allocation answers a different bacterial-overlap question.

## Coverage strand labels

When the strand is known, `plus_transcript` and `minus_transcript` refer to inferred RNA molecule orientation, not merely the BAM alignment flag. The run report records the declared, inferred, and effective library direction. Treat strand-specific tracks as invalid if the audit reports a contradiction.

## Work and state folders

`work/` contains indexes and run-level BAM intermediates. `.rnaseq_suite/` contains checkpoints, live state, and the safe-stop marker. The application removes these exact pipeline-owned paths only after a successful verified run. It preserves them after failure or safe stop so the run can resume. Never remove them manually while a run is active.

## Downstream result folders

The folder selected in a downstream GUI is treated as a parent location. The software creates a named child folder: `DESeq2 analysis` (or the selected DE engine) or `Functional enrichment and co-expression analysis`. Each child folder is Excel-first and deliberately keeps the root uncluttered.

### Differential expression

| Path | Meaning |
|---|---|
| `DESeq2 analysis results.xlsx` (engine name varies) | primary workbook containing run summary, complete DE statistics, significant genes, normalized/filtered counts, plot matrix, metadata, and the IGV audit when available |
| `Differential expression interactive.html` | unified linked visualization/report beside the workbook; uses the adjacent `Figures` folder for purpose-built analyses |
| `Figures/` | automatic DE diagnostics, sample QC, multi-contrast comparisons, trend clusters, and the shared offline Plotly runtime |
| `BedGraph/` | signed gene-level log2-fold-change tracks, written when 1-based gene coordinates are supplied |
| `Inputs for other modules/` | one parent folder that keeps every downstream handoff together; it contains the four input folders below |
| `Inputs for other modules/GO Enrichment and Pathways Input/` | complete DE table, tested-gene universe, significant-gene list, handoff manifest, and recovered reference/identifier support for GO/enrichment |
| `Inputs for other modules/Co-expression and Networks Input/` | normalized expression matrix, sample metadata, DE reference table, handoff manifest, and recovered reference/identifier support |
| `Inputs for other modules/Pathway Database Analysis Input/` | DE-selected genes, all tested genes as the universe, DE reference table, and handoff manifest |
| `Inputs for other modules/STRING Protein Associations Input/` | DE-selected genes, DE reference table, and handoff manifest |
| `Intermediate files/` | compact lossless DE handoff/provenance tables plus configuration, diagnostics, R session information, and complete code-bearing logs |

### Functional enrichment and co-expression networks

| Path | Meaning |
|---|---|
| `Functional enrichment and co-expression results.xlsx` | one primary workbook containing enrichment, selected genes, annotation mapping, modules, nodes, edges, eigengenes, traits, expression used, metadata, and applicable diagnostics |
| `Functional enrichment and co-expression interactive.html` | one unified interactive report with a shared Specialized analysis dropdown and curated linked result sheets |
| `Functional annotation/` | the single online annotation pass and its identifier/database provenance, when online annotation is selected |
| `Figures/` | all automatic enrichment and network figures |
| `Intermediate files/` | essential enrichment, edge, node, and module-assignment handoff tables plus one configuration, both statistical summaries, R session information, progress state, and complete code-bearing logs |

The Excel workbook is the normal file to open. Only TSV files required for automatic lossless module handoff are retained in `Intermediate files`; other recognized tables are deleted after their workbook worksheets have been reopened and verified. Unknown user files are never moved or deleted.

After a successful run, the top level of `analysis_ready` is intentionally compact: the two Excel workbooks, `Alignments/`, and `Intermediate files/`. Reference copies, coverage tracks, IGV session files, detailed QC, provenance, logs, and lossless handoff tables are grouped under `Intermediate files/`.


### Bowtie2 + HISAT2 dual alignment
When this option is selected, both aligners run independently on the same cleaned short reads. Both BAM/BAI sets are retained. If raw gene counting is enabled, `Counts & Annotation.xlsx` contains separate `Bowtie2 Raw Counts` and `HISAT2 Raw Counts` sheets. These matrices are technical alternatives and must not be merged or treated as biological replicates.
