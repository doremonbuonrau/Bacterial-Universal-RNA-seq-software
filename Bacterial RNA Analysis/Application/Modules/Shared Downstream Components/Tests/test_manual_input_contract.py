"""Portable data-contract tests; native first-paint tests are in the adjacent PS1.

Run with python test_manual_input_contract.py. No sequencing tools are needed.
"""
from __future__ import annotations

import ast
import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SHARED = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("manual_workbook", SHARED / "Python/manual_input_workbook.py")
manual = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manual)


class ManualInputContractTests(unittest.TestCase):
    def test_every_profile_has_examples_separate_from_data(self):
        total = 0
        for profile in manual.PROFILES:
            schema = manual.editor_schema(profile)
            workbook = manual.editor_workbook(profile, schema)
            for sheet in schema["sheets"]:
                self.assertTrue(sheet["example_rows"], (profile, sheet["name"]))
                self.assertEqual(list(workbook[sheet["name"]].values)[0], tuple(sheet["headers"]))
                self.assertEqual(workbook[sheet["name"]].max_row, 1 + len(sheet["rows"]))
                total += 1
            workbook.close()
        self.assertEqual(total, 25)

    def test_blank_de_cannot_run_on_examples(self):
        with tempfile.TemporaryDirectory(prefix="bra-input-test-") as tmp:
            output = Path(tmp) / "rejected"
            with self.assertRaisesRegex(ValueError, "required worksheet"):
                manual.extract_workbook("de", Path(tmp) / "unused.xlsx", output,
                                        editor_data=manual.editor_schema("de"))
            self.assertFalse(output.exists())

    def test_renamed_headers_and_first_data_row_roundtrip(self):
        schema = copy.deepcopy(manual.editor_schema("de"))
        counts, samples = schema["sheets"][:2]
        names = ["Untreated_A", "Untreated_B", "Untreated_C", "Exposed_A", "Exposed_B", "Exposed_C"]
        counts["headers"] = ["gene_id"] + names
        # Deliberately typed values identical to an example are legitimate data.
        counts["rows"] = [["gene_001", "0", "2", "3", "4", "5", "6"],
                          ["0002", "11", "12", "13", "14", "15", "16"]]
        samples["rows"] = [[name, "Control" if i < 3 else "Treatment", ""] for i, name in enumerate(names)]
        with tempfile.TemporaryDirectory(prefix="bra-input-test-") as tmp:
            output = Path(tmp) / "inputs"
            manual.extract_workbook("de", Path(tmp) / "unused.xlsx", output, editor_data=schema)
            rows = (output / "raw_counts.tsv").read_text().splitlines()
            self.assertEqual(rows[0].split("\t"), counts["headers"])
            self.assertEqual(rows[1].split("\t"), counts["rows"][0])
            self.assertEqual(rows[2].split("\t"), counts["rows"][1])
            self.assertEqual(len(rows), 3)

    def test_export_never_serializes_example_rows(self):
        schema = manual.editor_schema("de")
        with tempfile.TemporaryDirectory(prefix="bra-input-test-") as tmp:
            target = Path(tmp) / "empty.xlsx"
            manual.export_editor("de", schema, target)
            workbook = manual.load_workbook(target)
            self.assertEqual(workbook["Raw counts"].max_row, 1)
            self.assertEqual(workbook["Sample metadata"].max_row, 1)
            workbook.close()

    def test_no_script_paint_or_timing_workaround_remains(self):
        source = (SHARED / "App/manual_input_editor.ps1").read_text(encoding="utf-8-sig")
        for obsolete in ("Add_CellPainting", "Add_RowPostPaint", "BRA_EXAMPLE_PLACEHOLDER",
                         "firstPaintTimer", "HeaderText=$letter", "Rows[0].Frozen"):
            self.assertNotIn(obsolete, source)
        self.assertIn("$sheet.headers=$grid.GetInputHeaders()", source)
        self.assertIn("$sheet.rows=$grid.GetInputRows()", source)
        self.assertIn("ColumnHeaderMouseDoubleClick", source)

    def test_native_display_does_not_write_examples_to_values(self):
        source = (SHARED / "App/manual_input_grid.cs").read_text()
        formatting = source.split("protected override void OnCellFormatting", 1)[1].split(
            "protected override void OnCellBeginEdit", 1)[0]
        self.assertIn("e.Value = row[e.ColumnIndex]", formatting)
        self.assertNotIn(".Cells[", formatting)
        self.assertIn("suppressExamples++", source)
        self.assertIn("finally { suppressExamples--; }", source)
        self.assertIn("values[col] = Convert.ToString(row.Cells[col].Value)", source)

    def test_de_editor_can_add_a_complete_treatment_group(self):
        editor = (SHARED / "App/manual_input_editor.ps1").read_text(encoding="utf-8-sig")
        grid = (SHARED / "App/manual_input_grid.cs").read_text()
        self.assertIn("Add treatment group", editor)
        self.assertIn("$addTreatment.Visible = ([string]$Profile -eq 'de')", editor)
        self.assertIn("$counts.AddInputColumn($sampleName)", editor)
        self.assertIn("$metadata.AppendInputRow($values)", editor)
        self.assertIn("public int AppendInputRow(string[] values)", grid)
        # Adding structure must not promote the display-only example layer.
        treatment_block = editor.split("$addTreatment.Add_Click({", 1)[1].split(
            "}.GetNewClosure())", 1
        )[0]
        self.assertNotIn("SetExampleRow", treatment_block)

    def test_interactive_selection_and_control_visibility_contract(self):
        studio = (SHARED / "Python/visualization_studio.py").read_text()
        plots = (SHARED / "Python/interactive_plots.py").read_text()
        gui = (SHARED / "App/downstream_gui.ps1").read_text(encoding="utf-8-sig")
        top_gui = (SHARED.parents[1] / "App/rnaseq_gui.ps1").read_text(encoding="utf-8-sig")
        pathway_gui = (SHARED.parents[1] / "Modules/GO Enrichment and Pathways/App/pathway_expansion_gui.ps1").read_text(encoding="utf-8-sig")
        for marker in ("axisTitleInputs", "selectionInfoControls", "showLabelsControl",
                       "updateSpecializedCapabilityControls", "plotly_deselect",
                       "toolbar-drag-control", "showGridControl",
                       "specializedColorScaleControl", "pdfBlobFromJpegUri"):
            self.assertIn(marker, studio)
        for marker in ("clearSelectionVisuals", "scheduleSelectionHover",
                       "__braSelectionRevision", "__braSelectionWork",
                       "BRA_RANK_SELECTION_OVERLAY", "BRA_SELECTION_OVERLAY",
                       "showSingleGeneBoxInfo",
                       "resetSingleGeneExpression", "applyExclusiveSelection",
                       "gradientPalette", "pdfFromJpeg",
                       "bra-specialized-capabilities", "plotCapabilities"):
            self.assertIn(marker, plots)
        self.assertIn("state.selectedRows.size===1&&state.selectedRows.has(index)", studio)
        self.assertIn("selectionInfoApplicable=isDE&&['Volcano','Scatter'].includes(type)", studio)
        self.assertIn("type!=='Circos'", studio)
        self.assertIn("$('showGridControl').hidden=type==='Circos'", studio)
        self.assertIn("<option value=\"pan\" selected>Pan / move plot</option>", studio)
        self.assertIn("<option value=\"zoom\">Box zoom</option>", studio)
        self.assertIn("<option value=\"select\">Box select</option>", studio)
        self.assertIn("<option value=\"lasso\">Lasso select</option>", studio)
        self.assertIn("const linkedSheet=document.querySelector('.linked-sheet')", studio)
        self.assertIn("state.plotBlankPress", studio)
        self.assertIn("plotDeselectSuppressedUntil", studio)
        self.assertIn("suppressPlotDeselect()", studio)
        self.assertIn("suppressDeselect(g)", plots)
        self.assertIn("eventHitsStudioPlotDatum", studio)
        self.assertIn("eventHitsPlotDatum", plots)
        self.assertIn("state.lastPlotDataClickAt=time", studio)
        self.assertIn("g.__braLastDataClickAt=time", plots)
        # One pointer-up fallback handles true blank space. The former second
        # native-click timer could run after a valid bar/bin click and undo it.
        self.assertNotIn("started-20", studio)
        self.assertNotIn("started-20", plots)
        for filename in ("ma_interactive", "pca_interactive", "sample_pca_3d",
                         "sample_expression_distributions", "sample_dendrogram",
                         "source_of_variation", "de_pvalue_histogram",
                         "single_gene_expression"):
            self.assertIn(filename, studio)
            self.assertIn(filename, plots)
        self.assertIn("byTrace.get(index)||[]", plots)
        self.assertIn("marker:{size:40,symbol:'circle-open',color:'#f0a202'", plots)
        self.assertIn("marker:{size:27,symbol:'circle-open',color:'#7b2cbf'", plots)
        self.assertIn("marker:{size:8,symbol:'diamond',color:'#7b2cbf'", plots)
        self.assertIn("labels:kind==='de_gene_rank'", plots)
        self.assertIn("visible:window.__braShowPlotLabels!==false", plots)
        # The single-gene information layer is persistent and covers every
        # condition. It must not fall back to the old one-condition hover box.
        self.assertIn("BRA_SELECTION_RUNTIME_VERSION: 32", plots)
        self.assertIn("function conditionStatistics(values)", plots)
        self.assertIn("conditions.forEach((condition,index)=>", plots)
        self.assertIn("entries.forEach(([condition,groupValues],conditionIndex)=>", plots)
        self.assertIn("BRA_SELECTION_INFO_BOX_", plots)
        self.assertIn("text=[`<b>${wrappedHtml(condition,24,2)}</b>`", plots)
        self.assertNotIn("BRA_SELECTION_INFO_BOX_${conditionIndex}_${statIndex}", plots)
        self.assertIn("Plotly.relayout(g,{annotations", plots)
        self.assertNotIn("Plotly.Fx.hover(g,{xval:box.pos,yval:box.med,hovermode:'closest'})", plots)
        self.assertIn("hoveron:'boxes',hovertemplate:null,hoverinfo:'all'", plots)
        self.assertIn("'xaxis.type':'category'", plots)
        for statistic in ("'max'", "'upper fence'", "'q3'", "'median'",
                          "'q1'", "'lower fence'", "'min'"):
            self.assertIn(statistic, plots)
        self.assertIn("width:0.55", plots)

        # Ranked-DE and MA selections use appended overlay traces and
        # annotation panels so both remain above the ordinary plot marks.
        point_overlay = plots.split("function pointOverlay(", 1)[1].split(
            "\nfunction ", 1
        )[0]
        self.assertIn("'BRA_RANK_SELECTION_OVERLAY'", point_overlay)
        self.assertIn("'BRA_SELECTION_OVERLAY'", point_overlay)
        self.assertIn("Plotly.addTraces(g,overlays)", point_overlay)
        self.assertIn("topPointMarker(trace,computed,match.pointNumber)", point_overlay)
        self.assertIn("BRA_SELECTION_INFO", plots)
        self.assertIn("kind==='de_gene_rank'||kind==='de_ma'", plots)
        self.assertIn("function bindSelectionPanelDrag(g)", plots)
        self.assertIn("g.__braSelectionPanelPosition", plots)
        self.assertIn("text:'<b>'+safeHtml(gene)+'</b>'", plots)

        # Generic DE Volcano and Scatter selections use a persistent callout,
        # controlled by the same automatic-information checkbox.
        self.assertIn("function studioSelectionInfoAnnotation(reference,rowIndex)", studio)
        self.assertIn("BRA_STUDIO_SELECTION_INFO", studio)
        self.assertIn("['Volcano','Scatter'].includes(type)", studio)
        self.assertIn("refreshStudioSelectionInfo()", studio)
        self.assertIn("bra-selection-info-annotation", studio)
        self.assertIn("Math.min(Number(t.size)||13,12)", studio)
        self.assertIn("function markStudioSelectionInfo()", studio)
        self.assertIn("restoreSelectionRow", studio)
        self.assertIn("focusPlotRows([restoreSelectionRow]", studio)
        self.assertIn("bra-selection-info-annotation", plots)

        studio_overlay = studio.split("function addSelectionOverlay(", 1)[1].split(
            "\n  function ", 1
        )[0]
        self.assertIn("Redraw the actual selected datum last", studio_overlay)
        self.assertIn("marker:{size:cartesian.map(d=>d.size)", studio_overlay)

        # The linked spreadsheet is the authority for function/product text.
        # That exact annotation travels both with highlights and in a dedicated
        # refresh message for an already selected point.
        self.assertIn("function rowGeneAnnotations(rowIndices)", studio)
        self.assertIn("type:'bra-gene-annotations'", studio)
        self.assertIn("p.type==='bra-gene-annotations'", plots)
        self.assertIn("annotations:rowGeneAnnotations(rowIndices)", studio)
        self.assertIn("p.annotations", plots)
        self.assertIn("product", studio)

        # Bar/bin highlighting is color-only for both graph clicks and linked
        # spreadsheet selections; neither path may add a target ring.
        direct_aggregate = studio.split("function focusDirectAggregateMark(", 1)[1].split(
            "\n  function ", 1
        )[0]
        self.assertNotIn("addSelectionOverlay", direct_aggregate)
        direct_specialized = plots.split("function selectPlotPayload(", 1)[1].split(
            "\nfunction ", 1
        )[0]
        spreadsheet_specialized = plots.split("function highlightGenes(", 1)[1].split(
            "\nfunction ", 1
        )[0]
        self.assertNotIn("barTarget:true", direct_specialized)
        self.assertNotIn("barTarget", spreadsheet_specialized)
        self.assertIn("emphasizeBarCategory(g,primary.curveNumber,primary.pointNumber)", spreadsheet_specialized)
        generic_focus = studio.split("function focusPlotRows(", 1)[1].split(
            "\n  function ", 1
        )[0]
        self.assertIn("aggregate=['Bar','Histogram'].includes(type)", generic_focus)
        self.assertIn("if(!aggregate)await addSelectionOverlay", generic_focus)

        # Both the iframe and its pre-load fallback advertise the persistent
        # information control for single-gene, ranked-DE, and MA plots.
        runtime_capabilities = plots.split("function plotCapabilities(", 1)[1].split(
            "\nfunction ", 1
        )[0]
        fallback_capabilities = studio.split(
            "function fallbackSpecializedCapabilities(", 1
        )[1].split("\n  function ", 1)[0]
        for marker in ("single_gene_expression", "de_gene_rank", "de_ma"):
            self.assertIn(marker, runtime_capabilities)
        for marker in ("single_gene_expression", "de_gene_rank", "ma_interactive"):
            self.assertIn(marker, fallback_capabilities)

        # Circos avoids the expensive per-trace selectedpoints loop, while
        # blank-space clearing also rebuilds selection baked into generated
        # Genome-region/Circos traces.
        self.assertIn("fastCircos=type==='Circos'", studio)
        self.assertIn("function rerenderClearedBakedSelection(type)", studio)
        self.assertIn("rerenderClearedBakedSelection(type)", studio)
        self.assertIn("window.addEventListener('pointermove'", studio)
        self.assertIn("window.addEventListener('pointerup'", studio)
        self.assertIn("window.addEventListener('pointercancel'", studio)
        blank_restore = plots.split("function bindBlankSelectionRestore(g)", 1)[1].split(
            "\nfunction ", 1
        )[0]
        self.assertIn("bra_kind==='single_gene_expression'", blank_restore)
        self.assertIn("yPixel<yLength*.32", plots)
        self.assertIn("yPixel<yLength*.32", studio)
        self.assertIn("axis.d2p(value)", plots)

        advanced = (SHARED / "Python/advanced_de_analysis.py").read_text()
        self.assertIn('width=0.55', advanced)
        self.assertIn('xaxis={"type": "category"}', advanced)
        self.assertIn('"tickvals": tick_values', advanced)
        self.assertIn('"ticktext": tick_text', advanced)
        self.assertIn("to_numpy(dtype=float, copy=True)", advanced)
        self.assertIn("compactPlotNumber(minimum+index*step,6)", studio)
        # There is no visible or separately clickable "Hide information"
        # control; disabling automatic information is the single clear action.
        self.assertNotIn('id="hideSelectionInfo"', studio)
        self.assertNotIn("$('hideSelectionInfo').addEventListener('click',hideSelectionInfo)", studio)
        self.assertIn("if(!window.__braShowSelectionInfo)clearTransientInfo(g)", plots)
        self.assertNotIn("< Back to functional methods", gui)
        self.assertNotIn("$backHome = New-ScienceButton", pathway_gui)
        self.assertNotIn("$enrichmentSelector = New-BranchSelectorSurface", top_gui)
        self.assertNotIn("$networkSelector = New-BranchSelectorSurface", top_gui)
        self.assertNotIn("function Show-EnrichmentSelector", top_gui)
        self.assertNotIn("function Show-NetworkSelector", top_gui)
        downstream_host = top_gui.split("function Open-EmbeddedDownstreamModule", 1)[1].split(
            "function Open-EmbeddedOperonModule", 1
        )[0]
        self.assertNotIn("Show-EnrichmentSelector", downstream_host)
        self.assertNotIn("Show-NetworkSelector", downstream_host)
        self.assertIn("Show optional pathway-mapping inputs", gui)
        self.assertIn("Test-KEGGDatabaseConnection", gui)
        self.assertIn("Test-STRINGDatabaseConnection", gui)
        self.assertIn("$integratedMappingPanel.Controls.AddRange", gui)
        self.assertIn("$enrichAnnotationGroup.Controls.Add($integratedMappingPanel)", gui)
        self.assertIn("Busy=$false;LastKey=''", gui)
        for control in ("integratedTerm2Gene", "integratedBioCyc", "integratedMetaCyc"):
            self.assertIn(control, gui)
        self.assertIn("$combinedActionPanel.Height = 48", gui)
        mapping_layout = gui.split("$layoutIntegratedMappingControls={", 1)[1].split(
            "}.GetNewClosure()", 1
        )[0]
        self.assertIn("function Get-OrganismQueryText", gui)
        self.assertIn("$organismMissing=", mapping_layout)
        self.assertNotIn("(Get-OrganismQueryText", mapping_layout)
        set_job_ui = gui.split("function Set-JobUi", 1)[1].split("\n}", 1)[0]
        skipped_control = set_job_ui.index("$runEnrichmentButton")
        functional_guard = set_job_ui.index("if ($script:InitialTab -ne 'de')")
        self.assertLess(functional_guard, skipped_control)
        self.assertIn("pdfOption.disabled = false", studio)
        self.assertNotIn("id=\"toolbarPan\"", studio)
        self.assertNotIn("id=\"toolbarBoxZoom\"", studio)
        self.assertNotIn("Direct vector PDF export requires", studio)
        self.assertNotIn("Offline reports cannot create a true vector PDF", studio)
        self.assertNotIn("pdfOption.disabled = true", studio)

    def test_all_python_and_json_sources_parse(self):
        application = SHARED.parents[1]
        for path in application.rglob("*.py"):
            ast.parse(path.read_text(encoding="utf-8-sig"), filename=str(path))
        for path in application.rglob("*.json"):
            json.loads(path.read_text(encoding="utf-8-sig"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
