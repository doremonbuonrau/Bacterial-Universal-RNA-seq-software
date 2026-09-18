using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace BacterialRNAAnalysis
{
    // Keep all display-time work inside WinForms. PowerShell paint delegates can
    // interrupt an in-progress initial paint; Refresh/timers do not fix that.
    // Examples are formatting ONLY: Value, editing, clipboard and exports stay
    // empty until the user supplies data.
    public sealed class ManualWorkbookGrid : DataGridView
    {
        private readonly Dictionary<int, string[]> examples = new Dictionary<int, string[]>();
        private Font exampleFont;
        private Font headerFont;
        private bool showExamples = true;
        private int suppressExamples;
        private int editingRow = -1;
        private int editingColumn = -1;

        public ManualWorkbookGrid()
        {
            DoubleBuffered = true;
            AutoGenerateColumns = false;
            AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None;
            RowTemplate.Height = 25;
            ColumnHeadersHeight = 30;
            ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
            EnableHeadersVisualStyles = false;
            ColumnHeadersDefaultCellStyle.BackColor = ColorTranslator.FromHtml("#E6F2E8");
            ColumnHeadersDefaultCellStyle.ForeColor = ColorTranslator.FromHtml("#1F2B24");
            ColumnHeadersDefaultCellStyle.SelectionBackColor = ColorTranslator.FromHtml("#DCEADF");
            ColumnHeadersDefaultCellStyle.SelectionForeColor = ColorTranslator.FromHtml("#173426");
            ColumnHeadersDefaultCellStyle.WrapMode = DataGridViewTriState.False;
            DefaultCellStyle.NullValue = "";
            DefaultCellStyle.ForeColor = ColorTranslator.FromHtml("#1F2B24");
            DefaultCellStyle.SelectionBackColor = ColorTranslator.FromHtml("#DCEADF");
            DefaultCellStyle.SelectionForeColor = ColorTranslator.FromHtml("#173426");
            DefaultCellStyle.WrapMode = DataGridViewTriState.False;
            BackgroundColor = Color.White;
            GridColor = ColorTranslator.FromHtml("#CDD5D0");
            BorderStyle = BorderStyle.FixedSingle;
            AllowUserToOrderColumns = false;
            AllowUserToAddRows = true;
            AllowUserToDeleteRows = true;
            SelectionMode = DataGridViewSelectionMode.CellSelect;
            ClipboardCopyMode = DataGridViewClipboardCopyMode.EnableWithoutHeaderText;
            RowHeadersWidth = 58;
            MultiSelect = true;
        }

        public bool ShowExamples
        {
            get { return showExamples; }
            set { showExamples = value; Invalidate(); }
        }

        public int DataRowCount
        {
            get { return Rows.Count - (NewRowIndex >= 0 ? 1 : 0); }
        }

        public void ResetSheet(string[] headers, int minimumRows)
        {
            SuspendLayout();
            try
            {
                CancelEdit();
                CurrentCell = null;
                AllowUserToAddRows = false;
                Rows.Clear();
                Columns.Clear();
                examples.Clear();
                editingRow = editingColumn = -1;
                if (headers == null || headers.Length == 0)
                    headers = new string[] { "column_1" };
                foreach (string header in headers) AddInputColumn(header);
                EnsureDataRows(Math.Max(12, minimumRows));
            }
            finally
            {
                AllowUserToAddRows = true;
                ResumeLayout(true);
            }
        }

        public void AddInputColumn(string header)
        {
            int index = Columns.Count;
            DataGridViewTextBoxColumn column = new DataGridViewTextBoxColumn();
            column.Name = "col" + index;
            column.HeaderText = String.IsNullOrWhiteSpace(header) ? "column_" + (index + 1) : header;
            column.Width = 150;
            column.MinimumWidth = 75;
            column.SortMode = DataGridViewColumnSortMode.NotSortable;
            column.ToolTipText = "Double-click this column name to rename it.";
            Columns.Add(column);
        }

        public void EnsureDataRows(int count)
        {
            int missing = count - DataRowCount;
            if (missing > 0) Rows.Add(missing);
        }

        public void SetDataRow(int index, string[] values)
        {
            if (index < 0 || values == null) return;
            while (Columns.Count < values.Length) AddInputColumn(null);
            EnsureDataRows(index + 1);
            for (int col = 0; col < values.Length; col++)
                Rows[index].Cells[col].Value = values[col];
        }

        public int AppendInputRow(string[] values)
        {
            if (values == null) return -1;
            int target = DataRowCount;
            for (int row = 0; row < DataRowCount; row++)
            {
                bool empty = true;
                for (int col = 0; col < Columns.Count; col++)
                {
                    if (!String.IsNullOrEmpty(Convert.ToString(Rows[row].Cells[col].Value)))
                    {
                        empty = false;
                        break;
                    }
                }
                if (empty) { target = row; break; }
            }
            SetDataRow(target, values);
            return target;
        }

        public void SetExampleRow(int index, string[] values)
        {
            if (index < 0 || values == null) return;
            examples[index] = (string[])values.Clone();
            EnsureDataRows(index + 1);
        }

        public void FinishLoading()
        {
            ClearSelection();
            if (DataRowCount > 0 && Columns.Count > 0) CurrentCell = Rows[0].Cells[0];
            Invalidate();
        }

        public string[] GetInputHeaders()
        {
            string[] headers = new string[Columns.Count];
            for (int col = 0; col < headers.Length; col++) headers[col] = Columns[col].HeaderText;
            return headers;
        }

        public string[][] GetInputRows()
        {
            List<string[]> result = new List<string[]>();
            foreach (DataGridViewRow row in Rows)
            {
                if (row.IsNewRow) continue;
                string[] values = new string[Columns.Count];
                bool hasData = false;
                for (int col = 0; col < values.Length; col++)
                {
                    // Never use FormattedValue here: it may be an example.
                    values[col] = Convert.ToString(row.Cells[col].Value);
                    hasData |= !String.IsNullOrEmpty(values[col]);
                }
                if (hasData) result.Add(values);
            }
            return result.ToArray();
        }

        protected override void OnCellFormatting(DataGridViewCellFormattingEventArgs e)
        {
            base.OnCellFormatting(e);
            if (!showExamples || suppressExamples != 0 || e.RowIndex < 0 || e.ColumnIndex < 0 ||
                e.RowIndex == NewRowIndex || (e.RowIndex == editingRow && e.ColumnIndex == editingColumn) ||
                !String.IsNullOrEmpty(Convert.ToString(e.Value))) return;
            string[] row;
            if (!examples.TryGetValue(e.RowIndex, out row) || e.ColumnIndex >= row.Length ||
                String.IsNullOrEmpty(row[e.ColumnIndex])) return;
            if (exampleFont == null) exampleFont = new Font(Font, FontStyle.Italic);
            e.Value = row[e.ColumnIndex];
            e.CellStyle.ForeColor = ColorTranslator.FromHtml("#A5AFA8");
            e.CellStyle.SelectionForeColor = ColorTranslator.FromHtml("#87928A");
            e.CellStyle.Font = exampleFont;
            e.FormattingApplied = true;
        }

        protected override void OnCellBeginEdit(DataGridViewCellCancelEventArgs e)
        {
            editingRow = e.RowIndex;
            editingColumn = e.ColumnIndex;
            base.OnCellBeginEdit(e);
            if (e.Cancel) editingRow = editingColumn = -1;
        }

        protected override void OnEditingControlShowing(DataGridViewEditingControlShowingEventArgs e)
        {
            base.OnEditingControlShowing(e);
            TextBoxBase editor = e.Control as TextBoxBase;
            if (editor != null && CurrentCell != null && String.IsNullOrEmpty(Convert.ToString(CurrentCell.Value)))
                editor.Text = "";
            e.Control.ForeColor = DefaultCellStyle.ForeColor;
            e.Control.Font = Font;
        }

        protected override void OnCellEndEdit(DataGridViewCellEventArgs e)
        {
            editingRow = editingColumn = -1;
            base.OnCellEndEdit(e);
            InvalidateCell(e.ColumnIndex, e.RowIndex);
        }

        public override DataObject GetClipboardContent()
        {
            // WinForms copies FormattedValue by default. Suppress examples for
            // every clipboard format, including HTML, not just plain text.
            suppressExamples++;
            try { return base.GetClipboardContent(); }
            finally { suppressExamples--; }
        }

        protected override void OnRowsAdded(DataGridViewRowsAddedEventArgs e)
        {
            base.OnRowsAdded(e);
            NumberRows(e.RowIndex);
        }

        protected override void OnRowsRemoved(DataGridViewRowsRemovedEventArgs e)
        {
            base.OnRowsRemoved(e);
            NumberRows(e.RowIndex);
        }

        private void NumberRows(int first)
        {
            for (int index = first; index < Rows.Count; index++)
                Rows[index].HeaderCell.Value = Rows[index].IsNewRow ? "" : (index + 1).ToString();
        }

        protected override void OnFontChanged(EventArgs e)
        {
            if (exampleFont != null) { exampleFont.Dispose(); exampleFont = null; }
            Font previousHeader = headerFont;
            headerFont = new Font(Font, FontStyle.Bold);
            ColumnHeadersDefaultCellStyle.Font = headerFont;
            base.OnFontChanged(e);
            if (previousHeader != null) previousHeader.Dispose();
        }

        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing && exampleFont != null) { exampleFont.Dispose(); exampleFont = null; }
            if (disposing && headerFont != null) { headerFont.Dispose(); headerFont = null; }
        }
    }
}
