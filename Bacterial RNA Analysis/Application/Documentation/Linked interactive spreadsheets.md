# Linked interactive spreadsheets

The Differential Expression, GO and Enrichment, and Co-expression and Network visualization studios display a synchronized spreadsheet beneath the interactive graph.

## Opening data

The studio discovers the user-facing Excel workbook and chooses the appropriate worksheet automatically for the selected item in **1. Analysis / visualization**. Technical TSV and CSV tables remain available as fallbacks and for specialized plots. Spreadsheet paging and search work without exposing a separate data-source or browser-row-limit control.

## Spreadsheet to graph

Click any spreadsheet row to locate its graph element. The studio highlights the corresponding point, bar, term, heatmap cell, gene feature, or network node, restores the relevant visible axis range when necessary, scrolls to the graph, and opens its Plotly hover card. Search, column sorting, and paging do not break the underlying row link.

## Graph to spreadsheet

Click a graph element to select its source row and scroll the spreadsheet to that row. Aggregated bars and heatmap cells can select several contributing rows. A network node selects every displayed edge row that contains that node. The primary row is green and additional related rows are blue.

## Notes

- The spreadsheet and graph always refer to the currently selected worksheet or table.
- Hover remains available independently of row selection.
- Use **Clear selection** to restore the normal graph opacity and remove spreadsheet highlighting.
- Very large sheets are paged automatically; search or the page controls can locate rows that are not on the current page.
