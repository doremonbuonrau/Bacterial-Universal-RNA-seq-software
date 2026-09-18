# KEGG pathway expression maps

This Functional/GO sub-operation implements the pathway-ID workflow discussed in the MetaMapR conversation. It overlays transcriptomic differential expression on the original KEGG pathway diagram. It uses KEGG PNG images and KGML coordinates directly; it does not require MetaMapR or the R Pathview package.

## Run it

1. In Functional/GO, select a **full differential-expression result table** in section 1 and choose a results folder.
2. In **2. Gene-to-term mapping**, choose the KEGG organism that matches your transcriptome.
3. Tick **Map expression onto KEGG pathways**. Enter up to 12 pathway IDs separated by spaces, commas or semicolons.
4. Supply **Gene-ID mapping (optional)** if your transcriptome identifiers differ from KEGG identifiers.
5. Click **Map pathways**. This action runs the map operation alone, without GO annotation, an expression matrix, metadata, enrichment, network inference or R package installation. **Run all analyses** also includes the operation when ticked.
6. Open **Functional enrichment and co-expression interactive.html**. Select **KEGG pathway expression maps** in the KEGG/pathway analyses group.

Both the online and offline GO mapping layouts expose these controls. GO's annotation mode and the map's download setting are independent. For a first KEGG map run, leave **Use cached KEGG maps only** clear. Tick it after the requested diagrams have been retrieved successfully.

Custom TERM2GENE, BioCyc and MetaCyc inputs remain together under **Show optional pathway-mapping inputs**. They describe pathway membership for enrichment. They are separate from the gene-ID crosswalk used by the new map operation.

## Pathway IDs

| Input | Interpretation |
|---|---|
| `00010` | Pathway 00010 for the selected organism, for example `eco00010` |
| `map00010` | Same organism-specific resolution; with no organism, use `ko00010` |
| `eco00010` | Explicit E. coli pathway; the selected organism must agree |
| `ko00010` | KO reference map; input genes need explicit KO assignments |
| `path:eco00010` | The `path:` prefix is accepted |

Cross-species pathway IDs are rejected when they disagree with the chosen organism. EC, reaction and BRITE IDs are not accepted as gene-expression maps. Some reference/global diagrams have no suitable KGML; these are reported as unavailable rather than replaced with a different pathway.

## DE input

| Column | Required | Meaning |
|---|---|---|
| `gene_id` | Yes | Your transcriptome's gene identifier; `gene`, `GeneID` and `locus_tag` are also recognized |
| `log2FoldChange` | Yes | Signed DE effect; `logFC` and `log2FC` are also recognized |
| `padj` | No | Adjusted p-value; `FDR`, `adj.P.Val` and `adjusted_p_value` are recognized |
| `contrast` | No | Separates comparisons; do not mix duplicate rows without a contrast column |
| `product`, `function` or `description` | No | Function annotation for the map's gene table |
| `kegg_id`, `kegg_gene_id` | No | Explicit KEGG gene identifier |
| `ko_id`, `ko`, `kegg_ko` | No | Explicit KO assignment, such as `K00001` |

Use TSV, CSV or XLSX/XLSM. The software's DE workbook is read from **All contrast rows**, if available, otherwise **Differential expression**. A custom workbook with exactly one identifiable full DE sheet is also accepted. Ambiguous workbooks should be exported to a full-contrast TSV. A significant-gene list without fold changes cannot be used.

Each gene may have one row per contrast. Duplicate gene/contrast pairs cause an error; effects are never silently averaged. All input rows are considered, including nonsignificant genes. A missing adjusted p-value means unknown significance. A missing or non-finite fold change remains missing and is drawn with hatching in the all-measured view.

Exact organism-qualified IDs and bare locus tags for the chosen organism are matched. KO assignments match KO maps. The program does not guess homologs, infer gene IDs from free-text product names, or borrow IDs from another organism. If columns explicitly identify UniProt, NCBI GeneID or NCBI protein accessions, organism-specific KEGG conversion tables are requested at run time and cached; unresolved IDs remain in the audit.

## Optional gene-ID mapping

Use a table with `gene_id` and at least one of `kegg_id` or `ko_id`. Put one assignment per row; multiple rows for a gene are allowed. Semicolons can also separate multiple IDs in a cell. Map the input `gene_id` exactly; this column is not a gene symbol lookup.

The header-only template is at **Application/Modules/Shared Downstream Components/Examples/KEGG_gene_ID_mapping_template.tsv**. Fill it with verified assignments. A KEGG gene identifier has the form `organism:locus_tag`; a KO identifier has the form `K` followed by five digits. The GUI and command line accept the same table.

## Read the map

The original KEGG PNG is retained, and KGML shapes determine the positions of the overlays. Coloured slices represent separate input genes, so an upregulated and a downregulated gene at one node remain distinguishable. Group nodes collect genes from their component entries. Native compounds, arrows and unmatched nodes remain in the original image.

The colour scale is symmetric around zero. **log₂ FC limit ±** controls colour saturation, not the stored fold changes. The default is ±2. The standalone viewer uses blue for negative and red for positive changes; the combined report uses its primary/secondary colours and updates the legend accordingly. Positive and negative follow the contrast direction in the DE input. The view does not reverse the sign.

**All measured genes** colours every finite mapped effect. **Significant genes only** requires both adjusted p-value ≤ the configured cutoff and absolute log₂ fold change ≥ the configured threshold. These are the existing gene-set settings from the Functional/GO page. Unknown significance is excluded from that filter.

An uncoloured node can mean no measured match or exclusion by the display filter. It is not evidence of unchanged expression. Expression changes do not establish pathway flux or activity, and this display is not a new enrichment test.

Click nodes, box-select or lasso them to populate the shared member-gene spreadsheet. Click a gene row to highlight its map positions. Blank plot or spreadsheet-panel space clears selection. Switch pathway or contrast using the map's selectors; gene search uses exact input IDs. The report's shared toolbar controls drag mode, labels, information visibility and exports. The standalone map also exposes its own controls.

## Outputs

| Output | Contents |
|---|---|
| Combined interactive report | Native map analysis alongside GO, network and pathway enrichment views |
| KEGG map summary worksheet | Per-pathway/contrast coverage and retrieval status |
| KEGG mapped genes worksheet | Matched gene effects, adjusted p-values, functions and node IDs |
| KEGG mapping audit worksheet | Every input gene for each requested pathway, with match/missing/unavailable status |
| KEGG map nodes worksheet | Native node IDs, KEGG IDs and KGML positions |
| Figures/kegg_pathway_maps_interactive.html | Standalone offline map viewer with embedded images and data |
| Intermediate files/KEGG pathway maps/mapping data.json | Full map data, source-table hash, request/cache provenance and warnings |

The map-only action replaces only its four worksheets in the combined workbook and rebuilds the shared report. Existing GO/network worksheets remain. Close the Excel workbook before updating it. Re-running the map operation replaces this operation's previous requested maps; include all pathway IDs you want to retain in that run.

SVG retains the original raster image with vector overlays and labels. PNG, JPEG and WebP export the complete map, contrast and colour key; raster export is bounded to four times native size and 64 million pixels. Use SVG for larger output. **Interactive HTML** exports a standalone copy with embedded data. PDF and TIFF controls are disabled for this native map view. The full result folder can also be copied to another computer for offline use.

## Cache and failures

The shared cache is under `~/.local/share/prok-rnaseq/Database Library/KEGG/Pathway maps` inside WSL/Linux, or under `BRA_DATABASE_LIBRARY` if configured. Maps are fetched only when an analysis is requested. Existing valid files are reused. Remove the particular cached PNG/KGML pair if you intentionally want a fresh database copy.

The client uses bounded timeouts, two attempts, and request spacing. Individual unavailable diagrams do not discard successfully mapped diagrams or the GO/network results. A completely unavailable map-only run reports failure and still writes the status/audit report. Incorrect input tables cause an actionable input error. When no genes match, check the organism, locus-tag namespace and optional crosswalk; try a KO map only when you have KO assignments.

## Command line

Run in the existing downstream environment:

```bash
python kegg_pathway_maps.py configuration.json --standalone
```

Example configuration structure, with placeholder paths to replace:

```json
{
  "result_file": "/path/to/full_DE_results.tsv",
  "output_dir": "/path/to/Functional enrichment and co-expression analysis",
  "integrated_kegg_organism": "eco",
  "kegg_map_enabled": true,
  "kegg_map_pathway_ids": "00010,00020",
  "kegg_map_gene_mapping": "",
  "kegg_map_offline": false,
  "padj_cutoff": 0.05,
  "lfc_cutoff": 1.0
}
```

Optional `kegg_map_result_sheet` selects a custom Excel worksheet. Optional `kegg_map_cache_dir` points to an alternative database-root directory; the program creates `KEGG/Pathway maps` beneath it. `--standalone` updates the combined workbook/report. Without that flag, the operation writes map artifacts for the combined analysis finalizer.

## Source documentation and validation

The API endpoints and identifier namespaces follow the [official KEGG REST API documentation](https://www.kegg.jp/kegg/rest/keggapi.html). Native graphic coordinates, entry types and group components follow the [KGML specification](https://www.kegg.jp/kegg/xml/docs/). KEGG diagrams retain their source attribution and links.

Validation uses clearly marked synthetic PNG/KGML fixtures, not invented biological evidence. Tests cover mapping, cache reuse/failure, mixed signs, missing values, contrast isolation, workbook preservation, combined integration, script injection handling, and actual Chromium gestures/export. The shared DE and Functional/GO browser checks and StrictMode startup checks pass. Live KEGG retrieval timed out in the validation workspace, and native Windows rendering could not be measured here.
