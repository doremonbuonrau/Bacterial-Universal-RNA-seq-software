# TOmicsVis and Shiny-Seq comparison

This review compares Bacterial RNA Analysis 1.9.77 with the analysis functions described by:

- Miao et al. (2023), *TOmicsVis: An all-in-one transcriptomic analysis and visualization R package with Shinyapp interface*. https://doi.org/10.1002/imt2.137
- Sundararajan et al. (2019), *Shiny-Seq: advanced guided transcriptome analysis*. https://doi.org/10.1186/s13104-019-4471-1

The comparison is scoped to replicated, reference-based bacterial bulk RNA-seq. A similarly named plot was not counted as equivalent unless the underlying analysis and result table were also available.

## Already present before this update

| Paper capability | Bacterial RNA Analysis implementation |
|---|---|
| Count filtering and normalization | Raw-integer validation plus engine-specific DESeq2, edgeR, or limma-voom preprocessing |
| Differential expression | DESeq2, edgeR quasi-likelihood, and limma-voom with known-batch terms and several treatments versus one reference |
| Volcano and MA plots | Interactive, editable, exportable plots with linked result tables |
| 2D PCA | Interactive sample PCA from the most variable expressed genes |
| GO and KEGG enrichment | clusterProfiler ORA, fgsea, topGO, online GO mapping, online KEGG, and custom TERM2GENE/BioCyc/MetaCyc imports |
| Co-expression and hubs | CEMiTool and WGCNA modules, module–trait associations, module trends, networks, and hub summaries |
| Regulatory-network inference | GENIE3 with an optional bacterial regulator list |
| Enrichment networks, chord/Circos-style views, and heatmaps | Dedicated GO/network plots plus a generic linked visualization studio |
| Table filtering, joining, exporting, and reusable input examples | Interactive linked spreadsheets, verified Excel workbooks, and in-application manual-input sheets |

## Added in this update

| New analysis | When it runs | Main outputs |
|---|---|---|
| Sample expression-distribution QC | Every successful DE run | Interactive per-sample box distributions and Excel summary statistics |
| Sample correlation heatmap | Every successful DE run | Pearson correlation before/after visualization-only batch adjustment when applicable |
| Hierarchical sample clustering | Every successful DE run | Average-linkage dendrogram and complete merge table using `1 − correlation` distance |
| Interactive 3D PCA | Every successful DE run | Rotatable PC1–PC3 plot and exact sample coordinates; before/after batch-adjusted views when applicable |
| Source-of-variation analysis | When repeated metadata factors are available | Per-factor distribution of gene-wise eta-squared values, summarized by median and IQR |
| Raw p-value diagnostic | When raw p-values are available | Per-contrast histogram with clickable bins and an Excel bin-count table |
| Gene-rank analysis | Every successful DE run | Signed statistic/rank table and interactive whole-transcriptome ranking plot |
| Top-variable-gene heatmap | Every successful DE run | Z-scored interactive heatmap and source expression sheet |
| Single-gene expression explorer | Every successful DE run | Condition-grouped sample distributions driven by any gene selected in the linked spreadsheet; a compact top-variable source table initializes the view |
| Multi-contrast UpSet and Venn analysis | Two or more contrasts; Venn is shown for two or three | Exclusive intersection sizes, full gene membership matrix, scalable UpSet plot, and an intuitive clickable Venn view for small comparisons |
| Fold-change-versus-fold-change analysis | Two or more contrasts | Pairwise contrast table and concordant/discordant interactive scatter plots |
| Fuzzy condition-trend clustering | Three or more condition levels | Membership strengths, ambiguous-membership flag, condition means, centroids, and interactive pattern panels |
| DESeq2 fold-change shrinkage diagnostic | DESeq2 runs | Separate `shrunkenLog2FoldChange` column; significance thresholds retain the original fitted fold change |
| Known-batch visualization diagnostics | A valid batch term is selected | Condition-preserving limma batch-adjusted plot matrix; statistical testing still models batch in the count-based design |

Every new plot appears in the Differential Expression report's Analysis / visualization selector. Gene-bearing marks link back to the corresponding genes in the embedded spreadsheet. Every numeric source is retained in the result workbook.

The papers motivated the additional diagnostics, but duplicate plots were not retained merely because a paper displayed them. The fixed paper-guided Volcano used the same fold-change and adjusted-p-value evidence as the suite's established configurable Volcano and added no separate statistical result, so it was removed. The duplicate circular-genome DE view was likewise removed because the existing linked Circos already covers the biological purpose. The new MA implementation materially improves the old view through status-aware styling and complete two-way gene linking, so it replaces the former MA plot.

## Paper functions deliberately not copied

| Paper function | Reason |
|---|---|
| Survival analysis | Requires time-to-event phenotypes and is not an RNA-seq-specific analysis or a routine bacterial reference-genome workflow. Phenotype columns remain available for module–trait/source-of-variation analysis. |
| Human/mouse TRANSFAC or JASPAR TF-binding-site enrichment | The Shiny-Seq implementation is species-specific and not valid for arbitrary bacteria. Bacterial users instead have GENIE3, regulator lists, promoter/operon outputs, and custom gene-set mappings. |
| Kallisto transcript/isoform workflow | Primarily addresses spliced transcript isoforms. This suite's bacterial processing uses gene/feature counting and dedicated transcript-discovery/TU tools. |
| t-SNE and UMAP as default bulk-sample analyses | Typical replicated bacterial experiments have too few samples for stable neighborhood embeddings. PCA, hierarchical clustering, correlations, module analysis, and source-of-variation diagnostics are less misleading at these sample sizes. |
| MSigDB/disease ontology defaults | These are predominantly human-focused. Online KEGG, GO, BioCyc/MetaCyc, and arbitrary TERM2GENE files provide species-appropriate bacterial gene sets. |
| Automatic surrogate-variable insertion | Hidden-factor estimates can absorb a real treatment signal in small or confounded designs. The suite instead validates explicit batch terms, models them in DE, and now shows before/after diagnostics without changing the biological contrast. |
| One-click PowerPoint | This is a report format rather than a scientific analysis. The suite keeps exact data in Excel and interactive HTML, with SVG/TIFF/PNG/PDF plot export. |
| RNA-seq variant screening | Explicitly outside this application's expression-analysis scope. |

## Interpretation safeguards

- Batch-adjusted values are for visualization and exploratory pattern analysis only. Differential-expression p-values and fold changes come from the count-based model containing the batch term.
- Fuzzy trend clusters summarize expression patterns; they are not tests of differential expression. Low maximum membership is explicitly flagged.
- UpSet and Venn intersections use the same adjusted-p-value and absolute-log2-fold-change thresholds selected for the DE run.
- A p-value histogram is a diagnostic, not a pass/fail test. Its shape must be interpreted together with replication, model design, dispersion, and effect sizes.
