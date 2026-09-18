#!/usr/bin/env Rscript
script_dir <- Sys.getenv("BACTERIAL_RNA_DOWNSTREAM_R_DIR", unset = "")
if (!nzchar(script_dir) || !file.exists(file.path(script_dir, "common.R"))) {
  script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1]
  script_path <- sub("^--file=", "", script_arg)
  # Some Rscript builds represent spaces in --file= as ~+~. Decode that
  # representation before resolving the helper path.
  script_path <- gsub("~+~", " ", script_path, fixed = TRUE)
  script_dir <- dirname(normalizePath(script_path, mustWork = TRUE))
}
source(file.path(script_dir, "common.R"))

cfg <- read_config()
out_dir <- cfg$output_dir
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
method <- tolower(if (!is.null(cfg$network_method) && nzchar(as.character(cfg$network_method))) cfg$network_method else cfg$method)
expr_df <- standardize_gene_column(read_table_auto(cfg$expression_file), cfg$gene_column)
metadata <- standardize_sample_column(read_table_auto(cfg$metadata_file), cfg$sample_column)

sample_cols <- setdiff(colnames(expr_df), "gene_id")
missing_meta <- setdiff(sample_cols, metadata$sample_id)
if (length(missing_meta)) stop("Expression samples missing from metadata: ", paste(missing_meta, collapse = ", "))
metadata <- metadata[match(sample_cols, metadata$sample_id), , drop = FALSE]
if (method %in% c("wgcna", "cemitool") && length(sample_cols) < 15L && !as_flag(cfg$exploratory_override, FALSE)) {
  stop("WGCNA and CEMiTool require at least 15 samples in this interface unless exploratory override is explicitly enabled.")
}
if (length(sample_cols) < 4L) stop("At least four samples are required for network analysis; more independent samples are strongly preferable.")
expr <- as.matrix(expr_df[, sample_cols, drop = FALSE])
mode(expr) <- "numeric"
if (any(!is.finite(expr))) stop("The expression matrix must contain only finite numeric values.")
rownames(expr) <- expr_df$gene_id
if (as_flag(cfg$log_transform, TRUE)) {
  if (any(expr < 0)) stop("Log2(x + 1) cannot be applied to negative expression values. Disable log transformation for VST, rlog, voom, z-score, or other already-transformed matrices.")
  expr <- log2(expr + 1)
}

variances <- apply(expr, 1, var, na.rm = TRUE)
means <- rowMeans(expr, na.rm = TRUE)
keep <- is.finite(variances) & variances > 0 & is.finite(means) & means >= as.numeric(cfg$minimum_mean_expression)
expr <- expr[keep, , drop = FALSE]
if (nrow(expr) < 10L) stop("Too few variable genes remain after filtering.")
max_genes <- as.integer(cfg$maximum_genes)
if (is.finite(max_genes) && max_genes > 0L && nrow(expr) > max_genes) {
  top <- order(apply(expr, 1, var), decreasing = TRUE)[seq_len(max_genes)]
  expr <- expr[top, , drop = FALSE]
}
write_tsv(data.frame(gene_id = rownames(expr), expr, check.names = FALSE), file.path(out_dir, "network_expression_used.tsv"))

cor_method <- if (tolower(cfg$correlation_method) %in% c("spearman", "pearson")) tolower(cfg$correlation_method) else "pearson"
edge_threshold <- as.numeric(cfg$edge_threshold)
max_edges <- as.integer(cfg$max_edges)

edges_from_modules <- function(expression, assignments, threshold, maximum, correlation_method) {
  all_edges <- list()
  counter <- 1L
  for (module in unique(assignments$module)) {
    genes <- assignments$gene_id[assignments$module == module]
    genes <- intersect(genes, rownames(expression))
    if (length(genes) < 2L) next
    cm <- suppressWarnings(cor(t(expression[genes, , drop = FALSE]), method = correlation_method, use = "pairwise.complete.obs"))
    upper <- which(upper.tri(cm) & is.finite(cm) & abs(cm) >= threshold, arr.ind = TRUE)
    if (!nrow(upper)) next
    block <- data.frame(
      source = rownames(cm)[upper[, 1]],
      target = colnames(cm)[upper[, 2]],
      weight = cm[upper],
      module = module,
      edge_type = "undirected co-expression",
      stringsAsFactors = FALSE
    )
    all_edges[[counter]] <- block
    counter <- counter + 1L
  }
  if (!length(all_edges)) return(data.frame(source = character(), target = character(), weight = numeric(), module = character(), edge_type = character()))
  out <- do.call(rbind, all_edges)
  out <- out[order(abs(out$weight), decreasing = TRUE), , drop = FALSE]
  head(out, maximum)
}

module_eigengenes <- function(expression, assignments) {
  values <- list()
  for (module in unique(assignments$module)) {
    genes <- intersect(assignments$gene_id[assignments$module == module], rownames(expression))
    if (!length(genes)) next
    block <- t(expression[genes, , drop = FALSE])
    if (ncol(block) == 1L) {
      score <- as.numeric(scale(block[, 1]))
    } else {
      score <- prcomp(block, center = TRUE, scale. = TRUE)$x[, 1]
    }
    values[[module]] <- score
  }
  if (!length(values)) return(data.frame(sample_id = colnames(expression)))
  data.frame(sample_id = colnames(expression), as.data.frame(values, check.names = FALSE), check.names = FALSE)
}

trait_associations <- function(eigengenes, sample_metadata) {
  empty_result <- function() {
    data.frame(
      module = character(), trait = character(), correlation = numeric(),
      pvalue = numeric(), padj = numeric(), stringsAsFactors = FALSE
    )
  }
  if (ncol(eigengenes) < 2L || nrow(sample_metadata) < 4L) return(empty_result())
  traits <- sample_metadata[, setdiff(colnames(sample_metadata), "sample_id"), drop = FALSE]
  if (!ncol(traits)) return(empty_result())

  # Do not feed the complete metadata frame directly to model.matrix().  A
  # perfectly valid metadata sheet often contains bookkeeping columns that are
  # constant within the samples selected for one analysis (for example a study
  # name, organism, contrast, or batch after subsetting).  R's contrasts code
  # aborts before we can remove such columns when a factor has only one
  # observed level.  Encode each usable trait independently instead: numeric
  # traits stay numeric, while categorical traits become explicit 0/1 level
  # indicators. Constant/all-missing columns are informative metadata but are
  # not testable traits, so they are skipped rather than failing the network.
  encoded_traits <- list()
  skipped_traits <- character()
  for (trait_name in colnames(traits)) {
    values <- traits[[trait_name]]

    if (is.numeric(values) || is.integer(values)) {
      x <- suppressWarnings(as.numeric(values))
      x[!is.finite(x)] <- NA_real_
      observed <- unique(x[is.finite(x)])
      if (length(observed) > 1L) {
        encoded_traits[[trait_name]] <- x
      } else {
        skipped_traits <- c(skipped_traits, trait_name)
      }
      next
    }

    if (is.logical(values)) {
      x <- as.numeric(values)
      observed <- unique(x[is.finite(x)])
      if (length(observed) > 1L) {
        encoded_traits[[trait_name]] <- x
      } else {
        skipped_traits <- c(skipped_traits, trait_name)
      }
      next
    }

    text_values <- trimws(as.character(values))
    text_values[is.na(values) | !nzchar(text_values)] <- NA_character_

    # Character columns that are genuinely numeric are kept continuous. Factor
    # columns remain categorical even when their labels happen to be numbers.
    if (!is.factor(values)) {
      numeric_candidate <- suppressWarnings(as.numeric(text_values))
      numeric_parse_ok <- all(is.na(text_values) | is.finite(numeric_candidate))
      if (numeric_parse_ok) {
        observed_numeric <- unique(numeric_candidate[is.finite(numeric_candidate)])
        if (length(observed_numeric) > 1L) {
          encoded_traits[[trait_name]] <- numeric_candidate
        } else {
          skipped_traits <- c(skipped_traits, trait_name)
        }
        next
      }
    }

    observed_levels <- unique(text_values[!is.na(text_values)])
    if (length(observed_levels) < 2L) {
      skipped_traits <- c(skipped_traits, trait_name)
      next
    }
    for (level in observed_levels) {
      indicator <- ifelse(is.na(text_values), NA_real_, as.numeric(text_values == level))
      indicator_name <- paste0(trait_name, "=", level)
      encoded_traits[[indicator_name]] <- indicator
    }
  }

  if (length(skipped_traits)) {
    message(
      "Trait-association note: skipped metadata column(s) with fewer than two observed values: ",
      paste(unique(skipped_traits), collapse = ", "), "."
    )
  }
  if (!length(encoded_traits)) {
    message("Trait-association note: no variable metadata traits are available; module detection will still complete and the trait-association table will be empty.")
    return(empty_result())
  }

  numeric_traits <- as.data.frame(encoded_traits, check.names = FALSE, stringsAsFactors = FALSE)
  numeric_traits <- numeric_traits[, vapply(
    numeric_traits,
    function(x) length(unique(x[is.finite(x)])) > 1L,
    logical(1)
  ), drop = FALSE]
  if (!ncol(numeric_traits)) return(empty_result())

  out <- list(); k <- 1L
  for (module in setdiff(colnames(eigengenes), "sample_id")) {
    for (trait in colnames(numeric_traits)) {
      trait_values <- as.numeric(numeric_traits[[trait]])
      module_values <- as.numeric(eigengenes[[module]])
      r <- suppressWarnings(cor(module_values, trait_values, use = "pairwise.complete.obs"))
      n <- sum(is.finite(module_values) & is.finite(trait_values))
      t_value <- if (is.finite(r) && n > 2L && abs(r) < 1) r * sqrt((n - 2) / (1 - r^2)) else NA_real_
      p <- if (is.finite(t_value)) 2 * pt(-abs(t_value), df = n - 2) else NA_real_
      out[[k]] <- data.frame(module = module, trait = trait, correlation = r, pvalue = p, stringsAsFactors = FALSE)
      k <- k + 1L
    }
  }
  if (!length(out)) return(empty_result())
  ans <- do.call(rbind, out)
  ans$padj <- p.adjust(ans$pvalue, method = "BH")
  ans
}

assignments <- NULL
edges <- NULL
nodes <- NULL
eig <- NULL
traits <- NULL
directed <- FALSE
method_label <- NULL
selected_power <- NA_integer_

if (method == "wgcna") {
  check_packages(c("WGCNA"))
  suppressPackageStartupMessages(library(WGCNA))
  dat_expr <- t(expr)
  qc <- call_with_advanced_options(
    WGCNA::goodSamplesGenes, list(datExpr = dat_expr, verbose = 1), cfg,
    "wgcna_good_samples_genes", "WGCNA::goodSamplesGenes", protected = "datExpr"
  )
  if (!qc$allOK) dat_expr <- dat_expr[qc$goodSamples, qc$goodGenes, drop = FALSE]
  network_type <- if (tolower(cfg$network_type) == "unsigned") "unsigned" else "signed"
  if (tolower(as.character(cfg$soft_power)) == "auto") {
    powers <- c(1:10, seq(12, 20, 2))
    sft <- call_with_advanced_options(
      WGCNA::pickSoftThreshold,
      list(data = dat_expr, powerVector = powers, networkType = network_type, verbose = 1),
      cfg, "wgcna_pick_soft_threshold", "WGCNA::pickSoftThreshold", protected = "data"
    )
    fit <- sft$fitIndices
    candidate <- fit$Power[fit$SFT.R.sq >= as.numeric(cfg$scale_free_r2)]
    selected_power <- if (length(candidate)) candidate[1] else fit$Power[which.max(fit$SFT.R.sq)]
    if (!is.finite(selected_power)) selected_power <- 6L
    write_tsv(fit, file.path(out_dir, "soft_threshold_diagnostics.tsv"))
  } else {
    selected_power <- as.integer(cfg$soft_power)
  }
  message("WGCNA soft-threshold power: ", selected_power)
  net <- call_with_advanced_options(
    WGCNA::blockwiseModules,
    list(
      datExpr = dat_expr,
      power = selected_power,
      networkType = network_type,
      TOMType = network_type,
      minModuleSize = as.integer(cfg$minimum_module_size),
      mergeCutHeight = as.numeric(cfg$merge_cut_height),
      numericLabels = FALSE,
      pamRespectsDendro = FALSE,
      maxBlockSize = ncol(dat_expr),
      verbose = 2
    ),
    cfg, "wgcna_blockwise_modules", "WGCNA::blockwiseModules", protected = "datExpr"
  )
  assignments <- data.frame(gene_id = colnames(dat_expr), module = as.character(net$colors), stringsAsFactors = FALSE)
  eig_raw <- call_with_advanced_options(
    WGCNA::moduleEigengenes, list(expr = dat_expr, colors = net$colors), cfg,
    "wgcna_module_eigengenes", "WGCNA::moduleEigengenes", protected = c("expr", "colors")
  )$eigengenes
  eig <- data.frame(sample_id = rownames(eig_raw), eig_raw, check.names = FALSE)
  edges <- edges_from_modules(t(dat_expr), assignments, edge_threshold, max_edges, cor_method)
  traits <- trait_associations(eig, metadata[match(eig$sample_id, metadata$sample_id), , drop = FALSE])
  method_label <- "WGCNA"
} else if (method == "cemitool") {
  check_packages(c("CEMiTool"))
  suppressPackageStartupMessages(library(CEMiTool))
  # CEMiTool 1.30+ stores the expression input in an S4 slot whose
  # declared class is data.frame.  The shared network preprocessing uses
  # a numeric matrix for WGCNA/GENIE3 and correlation calculations, so
  # convert only the object passed to CEMiTool rather than changing the
  # common representation used by the rest of this module.
  cem_expr <- as.data.frame(expr, check.names = FALSE, stringsAsFactors = FALSE)
  rownames(cem_expr) <- rownames(expr)

  # Keep the GUI's biological choices connected to CEMiTool.  Earlier builds
  # silently used CEMiTool's unsigned/minimum-30 defaults even when the user
  # selected a signed network and a different minimum module size.
  network_type_value <- tolower(as.character(cfg$network_type))
  cemitool_network_type <- if (length(network_type_value) && identical(network_type_value[1], "signed")) "signed" else "unsigned"
  cemitool_min_ngen <- suppressWarnings(as.integer(cfg$minimum_module_size))
  if (!length(cemitool_min_ngen) || !is.finite(cemitool_min_ngen[1]) || cemitool_min_ngen[1] < 2L) cemitool_min_ngen <- 20L
  cemitool_min_ngen <- cemitool_min_ngen[1]
  cem_overrides <- advanced_package_options(cfg, "cemitool_run")
  explicit_beta_choice <- any(c("set_beta", "force_beta") %in% names(cem_overrides))
  exploratory_cemitool <- ncol(expr) < 15L && as_flag(cfg$exploratory_override, FALSE)
  cemitool_beta_mode <- "automatic"
  cemitool_no_modules <- FALSE

  cem_base_args <- list(
    expr = cem_expr,
    filter = TRUE,
    plot = FALSE,
    verbose = TRUE,
    cor_method = cor_method,
    network_type = cemitool_network_type,
    min_ngen = cemitool_min_ngen
  )

  # CEMiTool explicitly provides force_beta for cases where automatic beta
  # selection is unreliable.  Small-sample runs are already labelled
  # exploratory by this GUI, so use that documented fallback automatically
  # unless the user supplied their own beta policy in Advanced options.
  if (exploratory_cemitool && !explicit_beta_choice) {
    cem_base_args$force_beta <- TRUE
    cemitool_beta_mode <- "forced_for_exploratory_sample_count"
    message(
      "CEMiTool exploratory-mode safeguard: only ", ncol(expr),
      " samples are available, so force_beta=TRUE will be used instead of allowing automatic beta selection to abort the run."
    )
  }

  if (requireNamespace("doParallel", quietly = TRUE)) {
    requested_cores <- suppressWarnings(as.integer(cfg$threads))
    if (!length(requested_cores) || !is.finite(requested_cores[1]) || requested_cores[1] < 1L) requested_cores <- 1L
    requested_cores <- requested_cores[1]
    available_cores <- suppressWarnings(parallel::detectCores(logical = TRUE))
    if (!length(available_cores) || !is.finite(available_cores[1]) || available_cores[1] < 1L) available_cores <- 1L
    available_cores <- available_cores[1]
    cemitool_cores <- max(1L, min(requested_cores, available_cores))
    doParallel::registerDoParallel(cores = cemitool_cores)
    message("CEMiTool parallel backend registered with ", cemitool_cores, " worker(s).")
  }

  cem <- call_with_advanced_options(
    CEMiTool::cemitool, cem_base_args, cfg,
    "cemitool_run", "CEMiTool::cemitool", protected = "expr"
  )

  extract_cemitool_modules <- function(cem_object, display_name = "CEMiTool::module_genes") {
    raw <- tryCatch(
      as.data.frame(call_with_advanced_options(
        CEMiTool::module_genes, list(cem = cem_object), cfg,
        "cemitool_module_genes", display_name, protected = "cem"
      )),
      error = function(error) {
        message("CEMiTool module extraction notice: ", conditionMessage(error))
        NULL
      }
    )
    if (is.null(raw) || !nrow(raw)) return(NULL)
    gene_col <- c("gene", "Gene", "genes", "Genes")[c("gene", "Gene", "genes", "Genes") %in% colnames(raw)][1]
    module_col <- c("module", "Module", "modules", "Modules")[c("module", "Module", "modules", "Modules") %in% colnames(raw)][1]
    if (is.na(gene_col) || is.na(module_col)) return(NULL)
    raw
  }

  modules_raw <- extract_cemitool_modules(cem)

  # Automatic beta selection can also fail in larger datasets. Retry once with
  # CEMiTool's own sample-count-aware forced beta when the user did not choose
  # an explicit beta.  This is a bounded retry, not an analysis loop.
  already_forced <- isTRUE(cem_base_args$force_beta)
  if (is.null(modules_raw) && !explicit_beta_choice && !already_forced) {
    message("CEMiTool automatic beta selection produced no modules. Retrying once with force_beta=TRUE.")
    retry_args <- cem_base_args
    retry_args$force_beta <- TRUE
    cemitool_beta_mode <- "forced_after_automatic_beta_failure"
    cem <- call_with_advanced_options(
      CEMiTool::cemitool, retry_args, cfg,
      "cemitool_run", "CEMiTool::cemitool [forced-beta retry]", protected = "expr"
    )
    modules_raw <- extract_cemitool_modules(cem, "CEMiTool::module_genes [forced-beta retry]")
  }

  # Save beta diagnostics whenever available, including successful runs.  This
  # makes small-sample exploratory results auditable and gives the user the
  # exact scale-free fit table behind the beta decision.
  beta_diagnostics <- tryCatch(as.data.frame(CEMiTool::fit_data(cem)), error = function(error) NULL)
  if (!is.null(beta_diagnostics) && nrow(beta_diagnostics)) {
    write_tsv(beta_diagnostics, file.path(out_dir, "CEMiTool_beta_diagnostics.tsv"))
  }
  selected_power <- tryCatch({
    value <- suppressWarnings(as.integer(cem@parameters$beta)[1])
    if (length(value) && is.finite(value)) value else NA_integer_
  }, error = function(error) NA_integer_)

  if (is.null(modules_raw)) {
    # "No modules" is a valid scientific outcome, especially with very few
    # independent samples.  Do not turn it into an application crash. Preserve
    # all genes as explicitly unassigned, write a diagnostic note, and allow
    # finalization/reporting to complete with zero detected modules/edges.
    cemitool_no_modules <- TRUE
    assignments <- data.frame(
      gene_id = rownames(expr),
      module = rep("Not.Correlated", nrow(expr)),
      stringsAsFactors = FALSE
    )
    edges <- data.frame(
      source = character(), target = character(), weight = numeric(),
      module = character(), edge_type = character(), stringsAsFactors = FALSE
    )
    eig <- data.frame(sample_id = colnames(expr), stringsAsFactors = FALSE)
    traits <- data.frame(module = character(), trait = character(), correlation = numeric(), pvalue = numeric(), padj = numeric())
    method_label <- "CEMiTool (no modules detected)"
    writeLines(c(
      "CEMiTool completed but did not detect a defensible co-expression module.",
      paste0("Samples: ", ncol(expr)),
      paste0("Genes entering shared network preprocessing: ", nrow(expr)),
      paste0("Minimum requested module size: ", cemitool_min_ngen),
      paste0("Network type: ", cemitool_network_type),
      paste0("Beta policy: ", cemitool_beta_mode),
      if (ncol(expr) < 15L) "Interpretation: this run is below the software's recommended 15-sample threshold and is exploratory." else "Interpretation: automatic/forced beta did not yield modules for this expression structure.",
      "The run was completed without inventing modules. See CEMiTool_beta_diagnostics.tsv and consider more independent samples, another network method, or an explicitly justified beta in Guided package options."
    ), file.path(out_dir, "CEMiTool_no_modules.txt"))
    message("CEMiTool found no defensible modules after the available beta strategy. The run will complete with zero modules instead of failing.")
  } else {
    gene_col <- c("gene", "Gene", "genes", "Genes")[c("gene", "Gene", "genes", "Genes") %in% colnames(modules_raw)][1]
    module_col <- c("module", "Module", "modules", "Modules")[c("module", "Module", "modules", "Modules") %in% colnames(modules_raw)][1]
    assignments <- data.frame(gene_id = as.character(modules_raw[[gene_col]]), module = as.character(modules_raw[[module_col]]), stringsAsFactors = FALSE)
    assignments <- unique(assignments)
    eig <- module_eigengenes(expr, assignments)
    traits <- trait_associations(eig, metadata[match(eig$sample_id, metadata$sample_id), , drop = FALSE])
    edges <- edges_from_modules(expr, assignments, edge_threshold, max_edges, cor_method)
    method_label <- "CEMiTool"
  }
} else if (method == "genie3") {
  check_packages(c("GENIE3"))
  regulators <- rownames(expr)
  if (!is.null(cfg$regulator_file) && nzchar(cfg$regulator_file) && file.exists(cfg$regulator_file)) {
    regulator_df <- read_table_auto(cfg$regulator_file)
    regulators <- intersect(as.character(regulator_df[[1]]), rownames(expr))
  }
  if (length(regulators) < 1L) stop("No regulator identifiers match the expression matrix.")
  n_trees <- as.integer(cfg$n_trees)
  threads <- as.integer(cfg$threads)
  force_single_core <- identical(Sys.getenv("BRA_GENIE3_FORCE_SINGLE_CORE", ""), "1") || !requireNamespace("doRNG", quietly = TRUE)
  effective_threads <- if (force_single_core) 1L else max(1L, threads)
  if (force_single_core && threads > 1L) {
    message("GENIE3 safety fallback: doRNG is unavailable, so this run will use one CPU core instead of aborting. Use Install or update to enable parallel GENIE3 again.")
  }
  genie_options <- advanced_package_options(cfg, "genie3_run")
  weights <- tryCatch(
    call_with_advanced_options(
      GENIE3::GENIE3,
      list(exprMatr = expr, regulators = regulators, nTrees = n_trees, nCores = effective_threads, verbose = TRUE),
      cfg, "genie3_run", "GENIE3::GENIE3", protected = c("exprMatr", "regulators")
    ),
    error = function(error) {
      if (!is.null(genie_options$nCores) || !grepl("nCores", conditionMessage(error), fixed = TRUE)) stop(error)
      message("GENIE3 compatibility fallback: the installed package rejected nCores; retrying without that pipeline default.")
      call_with_advanced_options(
        GENIE3::GENIE3,
        list(exprMatr = expr, regulators = regulators, nTrees = n_trees, verbose = TRUE),
        cfg, "genie3_run", "GENIE3::GENIE3 [without nCores]", protected = c("exprMatr", "regulators")
      )
    }
  )
  links <- as.data.frame(call_with_advanced_options(
    GENIE3::getLinkList, list(weightMatrix = weights, reportMax = max_edges), cfg,
    "genie3_link_list", "GENIE3::getLinkList", protected = "weightMatrix"
  ))
  colnames(links)[1:3] <- c("source", "target", "weight")
  links$module <- "Predicted regulation"
  links$edge_type <- "directed regulator-target prediction"
  edges <- links
  all_nodes <- unique(c(edges$source, edges$target))
  nodes <- data.frame(
    gene_id = all_nodes,
    module = ifelse(all_nodes %in% regulators, "Regulator", "Target"),
    node_type = ifelse(all_nodes %in% regulators, "regulator", "target"),
    stringsAsFactors = FALSE
  )
  assignments <- nodes[, c("gene_id", "module")]
  eig <- data.frame(sample_id = colnames(expr))
  traits <- data.frame(module = character(), trait = character(), correlation = numeric(), pvalue = numeric(), padj = numeric())
  directed <- TRUE
  method_label <- "GENIE3"
} else {
  stop("Unknown network method: ", method)
}

if (is.null(nodes)) {
  degree_count <- table(c(edges$source, edges$target))
  nodes <- merge(assignments, data.frame(gene_id = names(degree_count), degree = as.integer(degree_count)), by = "gene_id", all.x = TRUE)
  nodes$degree[is.na(nodes$degree)] <- 0L
  nodes$node_type <- "gene"
}

annotation_genes <- 0L
module_go_terms <- 0L
annotation_table_path <- if (!is.null(cfg$annotation_table_file)) as.character(cfg$annotation_table_file) else ""
if (nzchar(annotation_table_path) && file.exists(annotation_table_path)) {
  annotation_table <- read_table_auto(annotation_table_path)
  if ("gene_id" %in% colnames(annotation_table)) {
    annotation_table$gene_id <- as.character(annotation_table$gene_id)
    annotation_table <- annotation_table[!duplicated(annotation_table$gene_id), , drop = FALSE]
    annotation_genes <- sum(nodes$gene_id %in% annotation_table$gene_id)
    index <- match(nodes$gene_id, annotation_table$gene_id)
    for (column in setdiff(colnames(annotation_table), "gene_id")) {
      nodes[[column]] <- annotation_table[[column]][index]
    }
  }
}

annotation_mapping_path <- if (!is.null(cfg$annotation_mapping_file)) as.character(cfg$annotation_mapping_file) else ""
if (nzchar(annotation_mapping_path) && file.exists(annotation_mapping_path) &&
    !(exists("cemitool_no_modules") && isTRUE(cemitool_no_modules))) {
  go_map <- read_table_auto(annotation_mapping_path)
  mapping_gene_column <- if (!is.null(cfg$mapping_gene_column) && nzchar(as.character(cfg$mapping_gene_column))) as.character(cfg$mapping_gene_column) else "gene_id"
  mapping_term_column <- if (!is.null(cfg$mapping_term_column) && nzchar(as.character(cfg$mapping_term_column))) as.character(cfg$mapping_term_column) else "term_id"
  mapping_name_column <- if (!is.null(cfg$mapping_name_column) && nzchar(as.character(cfg$mapping_name_column))) as.character(cfg$mapping_name_column) else "term_name"
  if (!"gene_id" %in% colnames(go_map) && mapping_gene_column %in% colnames(go_map)) colnames(go_map)[colnames(go_map) == mapping_gene_column] <- "gene_id"
  if (!"term_id" %in% colnames(go_map) && mapping_term_column %in% colnames(go_map)) colnames(go_map)[colnames(go_map) == mapping_term_column] <- "term_id"
  if (!"term_name" %in% colnames(go_map) && mapping_name_column %in% colnames(go_map)) colnames(go_map)[colnames(go_map) == mapping_name_column] <- "term_name"
  required_go <- c("gene_id", "term_id")
  if (all(required_go %in% colnames(go_map))) {
    go_map$gene_id <- as.character(go_map$gene_id)
    go_map$term_id <- as.character(go_map$term_id)
    if (!"term_name" %in% colnames(go_map)) go_map$term_name <- go_map$term_id
    go_map <- unique(go_map[nzchar(go_map$gene_id) & nzchar(go_map$term_id), c("gene_id", "term_id", "term_name"), drop = FALSE])
    universe <- intersect(unique(assignments$gene_id), unique(go_map$gene_id))
    enrichment_rows <- list()
    k <- 1L
    if (length(universe) >= 2L && nrow(go_map)) {
      term_members <- split(go_map$gene_id, go_map$term_id)
      term_members <- lapply(term_members, unique)
      name_map <- setNames(as.character(go_map$term_name), go_map$term_id)
      for (module_name in unique(assignments$module)) {
        module_genes <- intersect(unique(assignments$gene_id[assignments$module == module_name]), universe)
        if (!length(module_genes)) next
        for (term_id in names(term_members)) {
          members <- intersect(term_members[[term_id]], universe)
          a <- length(intersect(module_genes, members))
          if (a < 1L) next
          b <- length(module_genes) - a
          c <- length(members) - a
          d <- length(universe) - a - b - c
          if (d < 0L) next
          pvalue <- fisher.test(matrix(c(a, b, c, d), nrow = 2L), alternative = "greater")$p.value
          enrichment_rows[[k]] <- data.frame(
            module = as.character(module_name),
            term_id = term_id,
            term_name = if (!is.na(name_map[[term_id]]) && nzchar(name_map[[term_id]])) name_map[[term_id]] else term_id,
            overlap = a,
            module_annotated_genes = length(module_genes),
            term_genes = length(members),
            annotated_universe = length(universe),
            pvalue = pvalue,
            genes = paste(intersect(module_genes, members), collapse = "/"),
            stringsAsFactors = FALSE
          )
          k <- k + 1L
        }
      }
    }
    if (length(enrichment_rows)) {
      module_go <- do.call(rbind, enrichment_rows)
      module_go$padj <- ave(module_go$pvalue, module_go$module, FUN = function(x) p.adjust(x, method = "BH"))
      module_go <- module_go[order(module_go$module, module_go$padj, module_go$pvalue), , drop = FALSE]
      module_go_terms <- nrow(module_go)
      write_tsv(module_go, file.path(out_dir, "network_module_go_enrichment.tsv"))
    }
  }
}

write_tsv(assignments, file.path(out_dir, "module_assignments.tsv"))
write_tsv(edges, file.path(out_dir, "network_edges.tsv"))
write_tsv(nodes, file.path(out_dir, "network_nodes.tsv"))
write_tsv(eig, file.path(out_dir, "module_eigengenes.tsv"))
write_tsv(traits, file.path(out_dir, "module_trait_associations.tsv"))
write_tsv(metadata, file.path(out_dir, "network_metadata_used.tsv"))

summary_obj <- list(
  module = "coexpression_network",
  method = method_label,
  directed = directed,
  samples = ncol(expr),
  genes_used = nrow(expr),
  modules = if (exists("cemitool_no_modules") && isTRUE(cemitool_no_modules)) 0L else length(unique(assignments$module)),
  exported_edges = nrow(edges),
  edge_threshold = edge_threshold,
  correlation_method = cor_method,
  selected_soft_power = if (is.na(selected_power)) NULL else selected_power,
  exploratory = as_flag(cfg$exploratory_override, FALSE),
  cemitool_beta_mode = if (method == "cemitool" && exists("cemitool_beta_mode")) cemitool_beta_mode else NULL,
  cemitool_no_modules = if (method == "cemitool" && exists("cemitool_no_modules")) cemitool_no_modules else NULL,
  online_annotation_enabled = as_flag(cfg$online_annotation_enabled, FALSE),
  annotated_network_genes = annotation_genes,
  module_go_rows = module_go_terms,
  advanced_package_options = if (is.null(cfg$advanced_package_options)) list() else cfg$advanced_package_options
)
write_json_file(summary_obj, file.path(out_dir, "network_summary.json"))
writeLines(session_lines(), file.path(out_dir, "R_session_info.txt"))
final_module_count <- if (exists("cemitool_no_modules") && isTRUE(cemitool_no_modules)) 0L else length(unique(assignments$module))
message("Network analysis complete. Modules: ", final_module_count, "; edges: ", nrow(edges))
