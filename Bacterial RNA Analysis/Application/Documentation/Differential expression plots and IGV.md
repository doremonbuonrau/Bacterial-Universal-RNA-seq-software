# Differential-expression plots and IGV export

## Automatic IGV track

When the Differential Expression input page receives a coordinate table with `gene_id`, `seqid`, `start`, and `end`, the run writes:

- `differential_expression_log2fc.bedGraph`
- `differential_expression_igv_track_data.tsv`

The coordinate table uses 1-based inclusive gene coordinates. The bedGraph exporter converts these to 0-based half-open intervals, sorts by sequence and position, and writes signed gene-level log2 fold change. Positive bars mean higher expression in the test level relative to the reference level; negative bars mean lower expression. All finite fold changes are exported. Use the adjusted p-value and `de_status` fields in the audit table to evaluate significance.

The `seqid` values must exactly match the sequence names in the genome loaded in IGV. Load the bedGraph with **File > Load from File** and keep the graph type set to bars with the data range spanning zero.

## Unified interactive report

The **Analysis / visualization** selector opens the canonical MA, 2D and 3D PCA, normalized-distribution, sample-correlation, sample-dendrogram, source-of-variation, raw-p-value, gene-rank, top-variable/selected-gene heatmap, single-gene, multi-contrast UpSet/Venn, fold-change-comparison, and fuzzy trend-cluster views that are applicable to the completed design. The established configurable Volcano and Circos remain available through the linked-result-table plot builder; duplicate fixed versions were deliberately removed. Two or more contrasts are required for overlap and fold-change comparison; Venn is shown for two or three contrasts, while UpSet scales to larger comparisons. At least three condition levels are required for trend clustering. When a valid batch column is modeled, the sample diagnostics include a condition-preserving before/after view. Batch adjustment is never used as a replacement for the count-based statistical design.

Gene-bearing points, bars, heatmap cells, and cluster centroids are linked to the same annotated spreadsheet beneath the plot. Clicking a plot mark selects the complete gene row, including function/product fields. Selecting one spreadsheet gene focuses its position in MA/rank plots and replaces the single-gene explorer; selecting one or several genes replaces the heatmap rows. Use **Differential-expression result tables · Visualization Studio** to switch to the configurable plotting workspace.

## Configurable Visualization Studio

The Differential Expression page directly exposes these plot types:

1. Volcano
2. Circos
3. Genome region
4. Scatter
5. Violin + box
6. Histogram

Scatter supports optional color and point-size variables, so a separate bubble mode is unnecessary. The controls are plot-aware, the Plotly toolbar is outside the plotting area, and DE fold change can be displayed as raw ratio, log2, log10, or natural log. Histogram views summarize a numeric distribution and do not expose gene labels.

Select **Typography…** under Appearance to apply a common font, 6–72 px text size, theme-aware or custom color, and any combination of bold, italic, and underline to the graph. The same dialog is also available in the GO/enrichment and network visualization studios, and its settings are retained in static and interactive exports.

## Analysis-time plotting engine

The shared plotting backend also supports these preconfigured DE diagnostics:

- one canonical interactive MA plot
- sample PCA
- Genome-region directional gene-arrow track with linked spreadsheet highlighting
- selected-gene-range grouped bar plot by sample or condition mean, with replicate standard-deviation error bars for condition means

The configurable Volcano and Circos are not duplicated in the preconfigured list. This keeps one linked source of truth for each view while retaining the improved MA diagnostic.
