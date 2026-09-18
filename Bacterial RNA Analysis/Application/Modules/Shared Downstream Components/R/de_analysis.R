#!/usr/bin/env Rscript
script_dir <- Sys.getenv("BACTERIAL_RNA_DOWNSTREAM_R_DIR", unset = "")
if (!nzchar(script_dir) || !file.exists(file.path(script_dir, "common.R"))) {
  script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1]
  script_path <- sub("^--file=", "", script_arg)
  script_path <- gsub("~+~", " ", script_path, fixed = TRUE)
  script_dir <- dirname(normalizePath(script_path, mustWork = TRUE))
}
source(file.path(script_dir, "common.R"))

cfg <- read_config()
out_dir <- cfg$output_dir
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
engine <- tolower(cfg$engine)
condition_col <- cfg$condition_column
batch_col <- if (!is.null(cfg$batch_column) && nzchar(cfg$batch_column)) cfg$batch_column else NULL
reference_level <- as.character(cfg$reference_level)
raw_test_levels <- if (!is.null(cfg$test_levels) && length(cfg$test_levels)) cfg$test_levels else cfg$test_level
test_levels <- unique(trimws(as.character(unlist(raw_test_levels))))
test_levels <- test_levels[nzchar(test_levels)]
min_count <- as.integer(cfg$min_count)
min_samples <- as.integer(cfg$min_samples)
alpha <- as.numeric(cfg$padj_cutoff)
lfc_cutoff <- as.numeric(cfg$lfc_cutoff)
if (is.na(min_samples) || min_samples < 3L) stop("Minimum samples must be at least 3 for differential-expression filtering.")

safe_slug <- function(value) {
  x <- gsub("[^A-Za-z0-9._-]+", "_", trimws(as.character(value)))
  x <- gsub("_+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  if (!nzchar(x)) x <- "contrast"
  substr(x, 1, 80)
}
contrast_label <- function(test) paste(test, "versus", reference_level)
contrast_slug <- function(test) paste0(safe_slug(test), "_vs_", safe_slug(reference_level))

counts_df <- standardize_gene_column(read_table_auto(cfg$count_file), cfg$gene_column)
metadata <- standardize_sample_column(read_table_auto(cfg$metadata_file), cfg$sample_column)
if (!condition_col %in% colnames(metadata)) stop("Condition column not found in metadata: ", condition_col)
if (!is.null(batch_col) && !batch_col %in% colnames(metadata)) stop("Batch column not found in metadata: ", batch_col)

sample_cols <- setdiff(colnames(counts_df), "gene_id")
missing_meta <- setdiff(sample_cols, metadata$sample_id)
missing_counts <- setdiff(metadata$sample_id, sample_cols)
if (length(missing_meta)) stop("Count columns missing from metadata: ", paste(missing_meta, collapse = ", "))
if (length(missing_counts)) message("Metadata samples not present in the count matrix were ignored: ", paste(missing_counts, collapse = ", "))
metadata <- metadata[match(sample_cols, metadata$sample_id), , drop = FALSE]

count_matrix <- as.matrix(counts_df[, sample_cols, drop = FALSE])
mode(count_matrix) <- "numeric"
if (any(!is.finite(count_matrix)) || any(count_matrix < 0)) stop("Counts must be finite, non-negative numbers.")
if (any(abs(count_matrix - round(count_matrix)) > 1e-8)) stop("DESeq2, edgeR, and limma-voom require raw integer counts. TPM, FPKM, CPM, and other normalized values are not accepted.")
count_matrix <- round(count_matrix)
rownames(count_matrix) <- counts_df$gene_id

if (any(is.na(metadata[[condition_col]]) | !nzchar(trimws(as.character(metadata[[condition_col]]))))) stop("Condition values must be present for every analyzed sample.")
metadata$.condition <- factor(metadata[[condition_col]])
condition_levels <- levels(metadata$.condition)
if (!reference_level %in% condition_levels) stop("Reference level not found: ", reference_level)
if (!length(test_levels)) stop("Select at least one test level.")
if (any(!test_levels %in% condition_levels)) stop("Test level(s) not found: ", paste(test_levels[!test_levels %in% condition_levels], collapse = ", "))
if (reference_level %in% test_levels) stop("The reference level cannot also be selected as a treatment/test level.")
metadata$.condition <- relevel(metadata$.condition, ref = reference_level)

reference_count <- sum(as.character(metadata$.condition) == reference_level)
if (reference_count < 3L) stop("At least three biological samples are required in the reference level '", reference_level, "'.")
for (test_level in test_levels) {
  test_count <- sum(as.character(metadata$.condition) == test_level)
  if (test_count < 3L) stop("At least three biological samples are required in test level '", test_level, "'. Detected ", test_count, ".")
}

if (!is.null(batch_col)) {
  if (any(is.na(metadata[[batch_col]]) | !nzchar(trimws(as.character(metadata[[batch_col]]))))) stop("Batch values must be present for every analyzed sample when a batch column is selected.")
  metadata$.batch <- factor(metadata[[batch_col]])
  if (nlevels(metadata$.batch) < 2L) stop("The selected batch column has fewer than two levels. Choose no batch or a valid batch variable.")
}

keep <- rowSums(count_matrix >= min_count) >= min_samples
if (sum(keep) < 2L) stop("Too few genes passed the low-count filter. Reduce the filtering thresholds or inspect the count matrix.")
filtered <- count_matrix[keep, , drop = FALSE]
write_tsv(data.frame(gene_id = rownames(filtered), filtered, check.names = FALSE), file.path(out_dir, "filtered_raw_counts.tsv"))

design_formula <- if (is.null(batch_col)) ~ .condition else ~ .batch + .condition
design_check <- model.matrix(design_formula, data = metadata)
if (qr(design_check)$rank < ncol(design_check)) stop("The design matrix is not full rank. Condition and batch may be confounded, or one factor level may be redundant.")
message("Engine: ", engine)
message("Design: ", deparse(design_formula))
message("Contrasts: ", paste(vapply(test_levels, contrast_label, character(1)), collapse = "; "))

results <- list()
normalized <- NULL
plot_expression <- NULL
method_label <- NULL

order_result <- function(result) {
  result <- result[order(result$padj, result$pvalue, na.last = TRUE), , drop = FALSE]
  rownames(result) <- NULL
  result
}

if (engine == "deseq2") {
  check_packages(c("DESeq2"))
  suppressPackageStartupMessages(library(DESeq2))
  dds <- call_with_advanced_options(
    DESeq2::DESeqDataSetFromMatrix,
    list(countData = filtered, colData = metadata, design = design_formula),
    cfg, "deseq2_dataset", "DESeq2::DESeqDataSetFromMatrix",
    protected = c("countData", "colData", "design", "tidy")
  )
  dds <- call_with_advanced_options(
    DESeq2::DESeq,
    list(object = dds, quiet = FALSE),
    cfg, "deseq2_deseq", "DESeq2::DESeq",
    protected = c("object", "full", "reduced")
  )
  for (test_level in test_levels) {
    res <- call_with_advanced_options(
      DESeq2::results,
      list(object = dds, contrast = c(".condition", test_level, reference_level), alpha = alpha),
      cfg, "deseq2_results", "DESeq2::results",
      protected = c("object", "contrast", "name", "alpha", "format", "tidy")
    )
    result <- as.data.frame(res)
    # Shrunken fold changes are useful for ranking and visual comparison when
    # low-count genes have unstable maximum-likelihood estimates.  Preserve the
    # analysis-native log2FoldChange used by the established significance rules,
    # and add a separate column so this diagnostic cannot silently change which
    # genes pass the user's threshold.
    shrunken <- tryCatch(
      DESeq2::lfcShrink(
        dds,
        contrast = c(".condition", test_level, reference_level),
        res = res,
        type = "normal",
        quiet = TRUE
      ),
      error = function(error) {
        message("DESeq2 fold-change shrinkage was skipped for ", contrast_label(test_level), ": ", conditionMessage(error))
        NULL
      }
    )
    if (!is.null(shrunken)) {
      result$shrunkenLog2FoldChange <- as.data.frame(shrunken)$log2FoldChange
    }
    result$gene_id <- rownames(result)
    result <- result[, c("gene_id", setdiff(colnames(result), "gene_id")), drop = FALSE]
    results[[test_level]] <- order_result(result)
  }
  normalized <- call_with_advanced_options(
    DESeq2::counts,
    list(object = dds, normalized = TRUE),
    cfg, "deseq2_counts", "DESeq2::counts",
    protected = c("object", "normalized")
  )
  plot_expression <- log2(normalized + 1)
  method_label <- "DESeq2"
  capture.output({
    cat("DESeq2 size factors\n")
    print(sizeFactors(dds))
    cat("\nContrasts\n")
    for (test_level in test_levels) {
      cat("\n", contrast_label(test_level), "\n", sep = "")
      print(summary(DESeq2::results(dds, contrast = c(".condition", test_level, reference_level), alpha = alpha)))
    }
  }, file = file.path(out_dir, "model_diagnostics.txt"))
} else if (engine == "edger") {
  check_packages(c("edgeR"))
  suppressPackageStartupMessages(library(edgeR))
  design <- model.matrix(design_formula, data = metadata)
  y <- call_with_advanced_options(
    edgeR::DGEList, list(counts = filtered), cfg, "edger_dge_list", "edgeR::DGEList",
    protected = c("counts", "group", "lib.size", "norm.factors", "samples", "genes")
  )
  keep_edger <- call_with_advanced_options(
    edgeR::filterByExpr, list(y = y, design = design), cfg, "edger_filter_by_expr", "edgeR::filterByExpr",
    protected = c("y", "design", "group", "lib.size")
  )
  y <- y[keep_edger, , keep.lib.sizes = FALSE]
  y <- call_with_advanced_options(
    edgeR::calcNormFactors, list(object = y, method = "TMM"), cfg,
    "edger_calc_norm_factors", "edgeR::calcNormFactors", protected = "object"
  )
  y <- call_with_advanced_options(
    edgeR::estimateDisp, list(y = y, design = design, robust = TRUE), cfg,
    "edger_estimate_disp", "edgeR::estimateDisp", protected = c("y", "design")
  )
  fit <- call_with_advanced_options(
    edgeR::glmQLFit, list(y = y, design = design, robust = TRUE), cfg,
    "edger_glm_ql_fit", "edgeR::glmQLFit", protected = c("y", "design")
  )
  edge_cpm <- call_with_advanced_options(
    edgeR::cpm, list(y = y, normalized.lib.sizes = TRUE, log = FALSE), cfg,
    "edger_cpm_normalized", "edgeR::cpm [normalized matrix]", protected = c("y", "log")
  )
  for (test_level in test_levels) {
    coef_name <- paste0(".condition", make.names(test_level))
    coef_index <- match(coef_name, colnames(design))
    if (is.na(coef_index)) {
      candidates <- grep("^\\.condition", colnames(design))
      test_match <- candidates[grepl(make.names(test_level), colnames(design)[candidates], fixed = TRUE)]
      if (length(test_match) != 1L) stop("Could not identify the edgeR contrast coefficient for '", test_level, "'. Design columns: ", paste(colnames(design), collapse = ", "))
      coef_index <- test_match
    }
    test <- call_with_advanced_options(
      edgeR::glmQLFTest, list(glmfit = fit, coef = coef_index), cfg,
      "edger_glm_ql_test", "edgeR::glmQLFTest", protected = c("glmfit", "coef", "contrast")
    )
    tab <- call_with_advanced_options(
      edgeR::topTags, list(object = test, n = Inf, sort.by = "none"), cfg,
      "edger_top_tags", "edgeR::topTags", protected = c("object", "n", "sort.by")
    )$table
    result <- data.frame(
      gene_id = rownames(tab),
      baseMean = rowMeans(edge_cpm[rownames(tab), , drop = FALSE]),
      log2FoldChange = tab$logFC,
      stat = sign(tab$logFC) * sqrt(tab$F),
      pvalue = tab$PValue,
      padj = tab$FDR,
      logCPM = tab$logCPM,
      check.names = FALSE
    )
    results[[test_level]] <- order_result(result)
  }
  normalized <- edge_cpm
  plot_expression <- call_with_advanced_options(
    edgeR::cpm, list(y = y, normalized.lib.sizes = TRUE, log = TRUE, prior.count = 2), cfg,
    "edger_cpm_plot", "edgeR::cpm [plot matrix]", protected = c("y", "log")
  )
  method_label <- "edgeR quasi-likelihood"
  capture.output({
    cat("edgeR normalization factors\n")
    print(y$samples)
    cat("\nDesign matrix\n")
    print(design)
    cat("\nDispersion summary\n")
    print(summary(y$tagwise.dispersion))
    cat("\nContrasts\n")
    print(vapply(test_levels, contrast_label, character(1)))
  }, file = file.path(out_dir, "model_diagnostics.txt"))
} else if (engine %in% c("limma", "limma-voom", "voom")) {
  check_packages(c("edgeR", "limma"))
  suppressPackageStartupMessages({library(edgeR); library(limma)})
  design <- model.matrix(design_formula, data = metadata)
  y <- call_with_advanced_options(
    edgeR::DGEList, list(counts = filtered), cfg, "limma_dge_list", "edgeR::DGEList [limma-voom]",
    protected = c("counts", "group", "lib.size", "norm.factors", "samples", "genes")
  )
  keep_voom <- call_with_advanced_options(
    edgeR::filterByExpr, list(y = y, design = design), cfg,
    "limma_filter_by_expr", "edgeR::filterByExpr [limma-voom]", protected = c("y", "design", "group", "lib.size")
  )
  y <- y[keep_voom, , keep.lib.sizes = FALSE]
  y <- call_with_advanced_options(
    edgeR::calcNormFactors, list(object = y), cfg,
    "limma_calc_norm_factors", "edgeR::calcNormFactors [limma-voom]", protected = "object"
  )
  v <- call_with_advanced_options(
    limma::voom, list(counts = y, design = design, plot = FALSE), cfg,
    "limma_voom", "limma::voom", protected = c("counts", "design", "plot")
  )
  fit <- call_with_advanced_options(
    limma::lmFit, list(object = v, design = design), cfg,
    "limma_lm_fit", "limma::lmFit", protected = c("object", "design")
  )
  fit <- call_with_advanced_options(
    limma::eBayes, list(fit = fit, robust = TRUE), cfg,
    "limma_ebayes", "limma::eBayes", protected = "fit"
  )
  limma_cpm <- call_with_advanced_options(
    edgeR::cpm, list(y = y, normalized.lib.sizes = TRUE, log = FALSE), cfg,
    "limma_cpm_normalized", "edgeR::cpm [limma-voom normalized matrix]", protected = c("y", "log")
  )
  for (test_level in test_levels) {
    coef_name <- paste0(".condition", make.names(test_level))
    coef_index <- match(coef_name, colnames(design))
    if (is.na(coef_index)) {
      candidates <- grep("^\\.condition", colnames(design))
      test_match <- candidates[grepl(make.names(test_level), colnames(design)[candidates], fixed = TRUE)]
      if (length(test_match) != 1L) stop("Could not identify the limma contrast coefficient for '", test_level, "'. Design columns: ", paste(colnames(design), collapse = ", "))
      coef_index <- test_match
    }
    tab <- call_with_advanced_options(
      limma::topTable, list(fit = fit, coef = coef_index, number = Inf, sort.by = "none"), cfg,
      "limma_top_table", "limma::topTable", protected = c("fit", "coef", "number", "sort.by")
    )
    result <- data.frame(
      gene_id = rownames(tab),
      baseMean = rowMeans(limma_cpm[rownames(tab), , drop = FALSE]),
      log2FoldChange = tab$logFC,
      lfcSE = if ("t" %in% colnames(tab)) abs(tab$logFC / tab$t) else NA_real_,
      stat = tab$t,
      pvalue = tab$P.Value,
      padj = tab$adj.P.Val,
      AveExpr = tab$AveExpr,
      check.names = FALSE
    )
    results[[test_level]] <- order_result(result)
  }
  normalized <- limma_cpm
  plot_expression <- v$E
  method_label <- "limma-voom"
  capture.output({
    cat("limma-voom design matrix\n")
    print(design)
    cat("\nEmpirical Bayes summary\n")
    print(summary(decideTests(fit)))
    cat("\nContrasts\n")
    print(vapply(test_levels, contrast_label, character(1)))
  }, file = file.path(out_dir, "model_diagnostics.txt"))
} else {
  stop("Unknown differential-expression engine: ", engine)
}

if (!length(results)) stop("No differential-expression contrast was generated.")
first_test <- test_levels[[1]]
first_result <- results[[first_test]]
write_tsv(first_result, file.path(out_dir, "differential_expression.tsv"))
write_tsv(data.frame(gene_id = rownames(normalized), normalized, check.names = FALSE), file.path(out_dir, "normalized_counts.tsv"))
write_tsv(data.frame(gene_id = rownames(plot_expression), plot_expression, check.names = FALSE), file.path(out_dir, "plot_expression_matrix.tsv"))
write_tsv(metadata, file.path(out_dir, "analysis_metadata.tsv"))

# Batch correction is used only for exploratory visualization and sample
# diagnostics.  Differential-expression inference above continues to model the
# batch term directly in the count-based design, which is the statistically
# appropriate source of p-values and fold changes.  The condition design is
# preserved so biological group differences are not deliberately subtracted.
batch_corrected_for_plots <- FALSE
if (!is.null(batch_col)) {
  check_packages(c("limma"))
  preserve_condition <- model.matrix(~ .condition, data = metadata)
  adjusted_plot_expression <- limma::removeBatchEffect(
    plot_expression,
    batch = metadata$.batch,
    design = preserve_condition
  )
  write_tsv(
    data.frame(gene_id = rownames(adjusted_plot_expression), adjusted_plot_expression, check.names = FALSE),
    file.path(out_dir, "batch_corrected_plot_expression.tsv")
  )
  batch_corrected_for_plots <- TRUE
}

contrast_summaries <- list()
long_parts <- list()
manifest_rows <- list()
for (test_level in test_levels) {
  result <- results[[test_level]]
  label <- contrast_label(test_level)
  slug <- contrast_slug(test_level)
  sig <- !is.na(result$padj) & result$padj <= alpha & abs(result$log2FoldChange) >= lfc_cutoff
  contrast_summaries[[length(contrast_summaries) + 1L]] <- list(
    contrast = label,
    test_level = test_level,
    reference_level = reference_level,
    tested_genes = nrow(result),
    significant_genes = sum(sig),
    upregulated = sum(sig & result$log2FoldChange > 0, na.rm = TRUE),
    downregulated = sum(sig & result$log2FoldChange < 0, na.rm = TRUE)
  )
  part <- result
  part$contrast <- label
  part$test_level <- test_level
  part$reference_level <- reference_level
  part <- part[, c("gene_id", "contrast", "test_level", "reference_level", setdiff(colnames(part), c("gene_id", "contrast", "test_level", "reference_level"))), drop = FALSE]
  long_parts[[length(long_parts) + 1L]] <- part
  if (length(test_levels) > 1L) {
    contrast_dir <- file.path(out_dir, "contrasts")
    dir.create(contrast_dir, recursive = TRUE, showWarnings = FALSE)
    filename <- paste0("differential_expression__", slug, ".tsv")
    write_tsv(result, file.path(contrast_dir, filename))
    manifest_rows[[length(manifest_rows) + 1L]] <- data.frame(
      contrast = label, test_level = test_level, reference_level = reference_level,
      contrast_id = slug, file = file.path("contrasts", filename), stringsAsFactors = FALSE
    )
  }
}

if (length(test_levels) > 1L) {
  long_result <- do.call(rbind, long_parts)
  write_tsv(long_result, file.path(out_dir, "differential_expression_long.tsv"))
  manifest <- do.call(rbind, manifest_rows)
  write_tsv(manifest, file.path(out_dir, "contrast_manifest.tsv"))

  base <- results[[first_test]][, intersect(c("gene_id", "baseMean"), colnames(results[[first_test]])), drop = FALSE]
  if (!"gene_id" %in% colnames(base)) base$gene_id <- results[[first_test]]$gene_id
  combined <- base
  metric_names <- c("log2FoldChange", "shrunkenLog2FoldChange", "lfcSE", "stat", "pvalue", "padj")
  for (test_level in test_levels) {
    slug <- contrast_slug(test_level)
    result <- results[[test_level]]
    indexed <- result[match(combined$gene_id, result$gene_id), , drop = FALSE]
    for (metric in metric_names) {
      if (metric %in% colnames(indexed)) combined[[paste0(metric, "__", slug)]] <- indexed[[metric]]
    }
  }
  write_tsv(combined, file.path(out_dir, "differential_expression_all_contrasts.tsv"))
}

summary_obj <- list(
  module = "differential_expression",
  engine = method_label,
  design = deparse(design_formula),
  contrast = contrast_label(first_test),
  multi_contrast = length(test_levels) > 1L,
  reference_level = reference_level,
  test_levels = test_levels,
  contrasts = contrast_summaries,
  input_genes = nrow(count_matrix),
  tested_genes = nrow(first_result),
  samples = ncol(count_matrix),
  significant_genes = contrast_summaries[[1]]$significant_genes,
  upregulated = contrast_summaries[[1]]$upregulated,
  downregulated = contrast_summaries[[1]]$downregulated,
  padj_cutoff = alpha,
  lfc_cutoff = lfc_cutoff,
  deseq2_shrunken_log2fc_column = if (engine == "deseq2") "shrunkenLog2FoldChange (diagnostic; thresholds retain analysis-native log2FoldChange)" else NULL,
  batch_corrected_visualization_matrix = batch_corrected_for_plots,
  advanced_package_options = if (is.null(cfg$advanced_package_options)) list() else cfg$advanced_package_options
)
write_json_file(summary_obj, file.path(out_dir, "analysis_summary.json"))
writeLines(session_lines(), file.path(out_dir, "R_session_info.txt"))
message("DE analysis complete. Contrasts: ", length(test_levels), "; first contrast tested genes: ", nrow(first_result), "; significant: ", contrast_summaries[[1]]$significant_genes)
