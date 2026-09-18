# Visualization typography controls

Differential Expression and the combined Functional Enrichment and Co-expression Networks report share the same typography controls. The combined report applies them across its one unified specialized-analysis workspace.

Under **Appearance**, select **Typography…** to customize the text in the generated graph. The selected settings apply to graph titles, axis titles, tick labels, legends, annotations, and visible data labels.

## Controls

- **Font:** Arial, Times New Roman, Calibri, Segoe UI, Helvetica, Georgia, Verdana, Tahoma, Courier New, or Garamond. Each choice includes sensible fallback fonts when the preferred font is not installed.
- **Text size:** 6–72 pixels.
- **Text color:** use the theme-aware default, pick a color visually, or enter a hexadecimal color such as `#1e2a22`.
- **Text style:** bold, italic, and underline can be selected separately or combined.
- **Preview:** the dialog shows a live text sample before changes are applied.

Select **Apply to graph** to update the live plot. **Cancel** leaves the current graph unchanged. **Reset defaults** prepares Segoe UI, 13 px, theme-aware color, and regular text; select **Apply to graph** to use those defaults.

Typography is stored in the Plotly figure used by the export process, so the current settings are retained in TIFF, JPEG, PNG, SVG, PDF, and interactive HTML exports. A preferred font must be installed on the computer that renders or opens the graph; otherwise its listed fallback is used.

For term-overlap, gene–term, co-expression, and regulatory networks, **Network colors** appears below the biological-label control. It provides one node-color picker for each legend group and a separate **Connection lines** picker. These controls update the live graph and its subsequent image export.
