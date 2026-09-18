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
method <- tolower(if (!is.null(cfg$enrichment_method) && nzchar(as.character(cfg$enrichment_method))) cfg$enrichment_method else cfg$method)
result_df <- standardize_gene_column(read_table_auto(cfg$result_file), cfg$result_gene_column)
if (tolower(tools::file_ext(cfg$mapping_file)) == "gmt") {
  lines <- readLines(cfg$mapping_file, warn = FALSE)
  pieces <- strsplit(lines[nzchar(lines)], "\t", fixed = FALSE)
  rows <- lapply(pieces, function(x) {
    if (length(x) < 3L) return(NULL)
    data.frame(gene_id = x[-c(1, 2)], term_id = x[1], term_name = x[2],
               source = as.character(cfg$annotation_source), stringsAsFactors = FALSE)
  })
  mapping <- do.call(rbind, rows)
  if (is.null(mapping)) stop("The GMT file did not contain any valid gene sets.")
} else {
  mapping_raw <- read_table_auto(cfg$mapping_file)
  if (ncol(mapping_raw) < 2L) stop("The gene-to-term mapping must contain at least two columns.")
  map_gene_col <- if (!is.null(cfg$mapping_gene_column) && cfg$mapping_gene_column %in% colnames(mapping_raw)) cfg$mapping_gene_column else colnames(mapping_raw)[1]
  map_term_col <- if (!is.null(cfg$mapping_term_column) && cfg$mapping_term_column %in% colnames(mapping_raw)) cfg$mapping_term_column else colnames(mapping_raw)[2]
  map_name_col <- if (!is.null(cfg$mapping_name_column) && nzchar(cfg$mapping_name_column) && cfg$mapping_name_column %in% colnames(mapping_raw)) cfg$mapping_name_column else NULL
  map_source_col <- if (!is.null(cfg$mapping_source_column) && nzchar(cfg$mapping_source_column) && cfg$mapping_source_column %in% colnames(mapping_raw)) cfg$mapping_source_column else NULL
  mapping <- data.frame(
    gene_id = as.character(mapping_raw[[map_gene_col]]),
    term_id = as.character(mapping_raw[[map_term_col]]),
    term_name = if (is.null(map_name_col)) as.character(mapping_raw[[map_term_col]]) else as.character(mapping_raw[[map_name_col]]),
    source = if (is.null(map_source_col)) as.character(cfg$annotation_source) else as.character(mapping_raw[[map_source_col]]),
    stringsAsFactors = FALSE
  )
}
mapping$source[is.na(mapping$source)] <- ""
mapping$term_name[is.na(mapping$term_name) | !nzchar(mapping$term_name)] <- mapping$term_id[is.na(mapping$term_name) | !nzchar(mapping$term_name)]
mapping <- unique(mapping[nzchar(mapping$gene_id) & nzchar(mapping$term_id), c("gene_id", "term_id", "term_name", "source")])
requested_source <- if (!is.null(cfg$annotation_source)) trimws(as.character(cfg$annotation_source)) else "Custom"
if (nzchar(requested_source) && tolower(requested_source) != "custom" && any(nzchar(mapping$source), na.rm = TRUE)) {
  source_match <- tolower(trimws(mapping$source)) == tolower(requested_source)
  if (!any(source_match)) stop("No mapping rows match the selected annotation source: ", requested_source, ". Choose Custom to use all rows.")
  mapping <- mapping[source_match, , drop = FALSE]
}
if (!nrow(mapping)) stop("No valid gene-to-term mappings were found.")

padj_col <- if (!is.null(cfg$padj_column) && cfg$padj_column %in% colnames(result_df)) cfg$padj_column else {
  candidates <- c("padj", "FDR", "adj.P.Val", "p.adjust")
  candidates[candidates %in% colnames(result_df)][1]
}
lfc_col <- if (!is.null(cfg$lfc_column) && cfg$lfc_column %in% colnames(result_df)) cfg$lfc_column else {
  candidates <- c("log2FoldChange", "logFC", "log2fc")
  candidates[candidates %in% colnames(result_df)][1]
}
rank_col <- if (!is.null(cfg$rank_column) && cfg$rank_column %in% colnames(result_df)) cfg$rank_column else {
  candidates <- c("stat", "WaldStatistic", "t", "log2FoldChange", "logFC")
  candidates[candidates %in% colnames(result_df)][1]
}
if (is.na(padj_col) || is.null(padj_col)) stop("An adjusted p-value column was not found in the result table.")
if (is.na(lfc_col) || is.null(lfc_col)) stop("A log2-fold-change column was not found in the result table.")
result_df[[padj_col]] <- suppressWarnings(as.numeric(result_df[[padj_col]]))
result_df[[lfc_col]] <- suppressWarnings(as.numeric(result_df[[lfc_col]]))

universe <- unique(result_df$gene_id)
if (!is.null(cfg$universe_file) && nzchar(cfg$universe_file) && file.exists(cfg$universe_file)) {
  universe_df <- read_table_auto(cfg$universe_file)
  universe <- unique(as.character(universe_df[[1]]))
}
universe <- intersect(universe, unique(mapping$gene_id))
if (length(universe) < 2L) stop("Too few tested genes map to the annotation file. Check gene identifiers and the universe.")

# For genuine GO mappings, retain the ontology structure used only for visualization
# and interpretation.  The enrichment statistics below are unchanged.  GO.db is a
# dependency of topGO/clusterProfiler in the shared downstream environment, so no
# extra online database or per-run download is required.
go_nodes <- data.frame(GO_ID = character(), term = character(), ontology = character(), stringsAsFactors = FALSE)
go_edges <- data.frame(parent_id = character(), child_id = character(), relationship = character(), ontology = character(), stringsAsFactors = FALSE)
go_seed_ids <- unique(mapping$term_id[grepl("^GO:[0-9]{7}$", mapping$term_id)])
if (length(go_seed_ids) && requireNamespace("GO.db", quietly = TRUE) && requireNamespace("AnnotationDbi", quietly = TRUE)) {
  seed_meta <- tryCatch(
    suppressMessages(AnnotationDbi::select(GO.db::GO.db, keys = go_seed_ids, columns = c("TERM", "ONTOLOGY"), keytype = "GOID")),
    error = function(e) {
      message("GO ontology metadata lookup warning: ", conditionMessage(e))
      data.frame(GOID = character(), TERM = character(), ONTOLOGY = character(), stringsAsFactors = FALSE)
    }
  )
  seed_meta <- seed_meta[!duplicated(seed_meta$GOID), , drop = FALSE]
  branch_map <- setNames(as.character(seed_meta$ONTOLOGY), as.character(seed_meta$GOID))
  queue_ids <- as.character(seed_meta$GOID[seed_meta$ONTOLOGY %in% c("BP", "MF", "CC")])
  seen_ids <- character()
  edge_rows <- list()
  edge_index <- 0L
  parent_env <- function(branch) {
    if (identical(branch, "BP")) return(GO.db::GOBPPARENTS)
    if (identical(branch, "MF")) return(GO.db::GOMFPARENTS)
    if (identical(branch, "CC")) return(GO.db::GOCCPARENTS)
    NULL
  }
  while (length(queue_ids)) {
    child <- queue_ids[[1]]
    queue_ids <- queue_ids[-1]
    if (child %in% seen_ids) next
    seen_ids <- c(seen_ids, child)
    branch <- unname(branch_map[[child]])
    if (is.null(branch) || is.na(branch) || !branch %in% c("BP", "MF", "CC")) next
    env <- parent_env(branch)
    parents_raw <- tryCatch(env[[child]], error = function(e) character())
    parents <- as.character(parents_raw)
    relations <- names(parents_raw)
    if (is.null(relations) || length(relations) != length(parents)) relations <- rep("parent", length(parents))
    keep <- grepl("^GO:[0-9]{7}$", parents)
    parents <- parents[keep]
    relations <- relations[keep]
    if (!length(parents)) next
    for (j in seq_along(parents)) {
      parent <- parents[[j]]
      edge_index <- edge_index + 1L
      edge_rows[[edge_index]] <- data.frame(parent_id = parent, child_id = child, relationship = as.character(relations[[j]]), ontology = branch, stringsAsFactors = FALSE)
      if (is.na(unname(branch_map[parent]))) branch_map[parent] <- branch
      if (!parent %in% seen_ids) queue_ids <- c(queue_ids, parent)
    }
  }
  all_go_ids <- unique(c(as.character(seed_meta$GOID), names(branch_map), unlist(lapply(edge_rows, function(x) c(x$parent_id, x$child_id)), use.names = FALSE)))
  all_go_ids <- all_go_ids[grepl("^GO:[0-9]{7}$", all_go_ids)]
  if (length(all_go_ids)) {
    node_meta <- suppressMessages(AnnotationDbi::select(GO.db::GO.db, keys = all_go_ids, columns = c("TERM", "ONTOLOGY"), keytype = "GOID"))
    node_meta <- node_meta[!duplicated(node_meta$GOID), , drop = FALSE]
    go_nodes <- data.frame(
      GO_ID = as.character(node_meta$GOID),
      term = as.character(node_meta$TERM),
      ontology = as.character(node_meta$ONTOLOGY),
      stringsAsFactors = FALSE
    )
    missing_term <- is.na(go_nodes$term) | !nzchar(go_nodes$term)
    go_nodes$term[missing_term] <- go_nodes$GO_ID[missing_term]
    missing_branch <- is.na(go_nodes$ontology) | !go_nodes$ontology %in% c("BP", "MF", "CC")
    go_nodes$ontology[missing_branch] <- unname(branch_map[go_nodes$GO_ID[missing_branch]])
  }
  if (length(edge_rows)) go_edges <- unique(do.call(rbind, edge_rows))
  write_tsv(go_nodes, file.path(out_dir, "go_ontology_nodes.tsv"))
  write_tsv(go_edges, file.path(out_dir, "go_ontology_edges.tsv"))
  message("GO ontology visualization support: ", nrow(go_nodes), " nodes; ", nrow(go_edges), " parent-child edges.")
} else if (length(go_seed_ids)) {
  message("GO ontology visualization support was skipped because GO.db/AnnotationDbi was unavailable. Enrichment statistics are unaffected.")
}

padj_cutoff <- as.numeric(cfg$padj_cutoff)
lfc_cutoff <- as.numeric(cfg$lfc_cutoff)
direction <- tolower(cfg$direction)
selected_flag <- !is.na(result_df[[padj_col]]) & result_df[[padj_col]] <= padj_cutoff & !is.na(result_df[[lfc_col]]) & abs(result_df[[lfc_col]]) >= lfc_cutoff
if (direction == "up") selected_flag <- selected_flag & result_df[[lfc_col]] > 0
if (direction == "down") selected_flag <- selected_flag & result_df[[lfc_col]] < 0
selected <- intersect(unique(result_df$gene_id[selected_flag]), universe)
min_size <- as.integer(cfg$min_gene_set_size)
max_size <- as.integer(cfg$max_gene_set_size)
p_adjust <- if (!is.null(cfg$p_adjust_method) && nzchar(cfg$p_adjust_method)) cfg$p_adjust_method else "BH"
term2gene <- unique(mapping[, c("term_id", "gene_id")])
term2name <- unique(mapping[, c("term_id", "term_name")])
colnames(term2gene) <- c("term", "gene")
colnames(term2name) <- c("term", "name")

message("Method: ", method)
message("Universe genes with annotation: ", length(universe))
message("Selected genes with annotation: ", length(selected))

output <- NULL
if (method %in% c("ora", "clusterprofiler", "enricher")) {
  check_packages(c("clusterProfiler"))
  if (length(selected) < 1L) stop("No genes passed the selected adjusted-p-value, fold-change, and direction thresholds.")
  enr <- call_with_advanced_options(
    clusterProfiler::enricher,
    list(
      gene = selected,
      universe = universe,
      TERM2GENE = term2gene,
      TERM2NAME = term2name,
      pAdjustMethod = p_adjust,
      pvalueCutoff = 1,
      qvalueCutoff = 1,
      minGSSize = min_size,
      maxGSSize = max_size
    ),
    cfg, "clusterprofiler_enricher", "clusterProfiler::enricher",
    protected = c("gene", "universe", "TERM2GENE", "TERM2NAME")
  )
  output <- as.data.frame(enr)
  if (!nrow(output)) {
    output <- data.frame(ID = character(), Description = character(), GeneRatio = character(), BgRatio = character(),
                         pvalue = numeric(), p.adjust = numeric(), qvalue = numeric(), geneID = character(), Count = integer())
  }
  output$method <- rep("clusterProfiler ORA", nrow(output))
} else if (method %in% c("fgsea", "ranked", "gsea")) {
  check_packages(c("fgsea"))
  if (is.na(rank_col) || is.null(rank_col)) stop("A numeric ranking column is required for fgsea.")
  ranks <- suppressWarnings(as.numeric(result_df[[rank_col]]))
  if (all(is.na(ranks))) stop("The selected ranking column is not numeric: ", rank_col)
  names(ranks) <- result_df$gene_id
  ranks <- ranks[names(ranks) %in% universe & is.finite(ranks)]
  if (anyDuplicated(names(ranks))) {
    split_ranks <- split(ranks, names(ranks))
    ranks <- vapply(split_ranks, function(x) x[which.max(abs(x))], numeric(1))
  }
  ranks <- sort(ranks, decreasing = TRUE)
  pathways <- split(term2gene$gene, term2gene$term)
  pathways <- lapply(pathways, unique)
  pathways <- lapply(pathways, intersect, y = names(ranks))
  pathways <- pathways[lengths(pathways) >= min_size & lengths(pathways) <= max_size]
  if (!length(pathways)) stop("No gene sets remain after applying the size filters and identifier mapping.")
  fg <- call_with_advanced_options(
    fgsea::fgseaMultilevel,
    list(pathways = pathways, stats = ranks, minSize = min_size, maxSize = max_size,
         eps = 0, scoreType = "std"),
    cfg, "fgsea_multilevel", "fgsea::fgseaMultilevel",
    protected = c("pathways", "stats")
  )
  fg <- as.data.frame(fg)
  if (nrow(fg)) {
    fg$leadingEdge <- vapply(fg$leadingEdge, paste, collapse = ",", FUN.VALUE = character(1))
    desc_map <- setNames(term2name$name, term2name$term)
    fg$Description <- unname(desc_map[fg$pathway])
    fg$Description[is.na(fg$Description)] <- fg$pathway[is.na(fg$Description)]
    output <- data.frame(
      ID = fg$pathway,
      Description = fg$Description,
      enrichmentScore = fg$ES,
      NES = fg$NES,
      pvalue = fg$pval,
      p.adjust = fg$padj,
      qvalue = fg$padj,
      leadingEdge = fg$leadingEdge,
      setSize = fg$size,
      method = "fgsea ranked enrichment",
      check.names = FALSE
    )
    output <- output[order(output$p.adjust, -abs(output$NES), na.last = TRUE), , drop = FALSE]
  } else {
    output <- data.frame(ID = character(), Description = character(), enrichmentScore = numeric(), NES = numeric(),
                         pvalue = numeric(), p.adjust = numeric(), qvalue = numeric(), leadingEdge = character(),
                         setSize = integer(), method = character())
  }
} else if (method %in% c("topgo", "go-topology")) {
  check_packages(c("topGO"))
  if (length(selected) < 1L) stop("No genes passed the selected thresholds for topGO.")
  if (!all(grepl("^GO:[0-9]+$", mapping$term_id))) stop("topGO requires GO identifiers in the form GO:0000000. Use ORA or fgsea for KEGG, COG, eggNOG, BioCyc, or custom terms.")

  ontology_raw <- cfg$go_ontology
  if (is.null(ontology_raw) || length(ontology_raw) < 1L || is.na(ontology_raw[1]) || !nzchar(trimws(as.character(ontology_raw[1])))) {
    ontology_raw <- "All (BP + MF + CC)"
  }
  ontology_request <- toupper(trimws(as.character(ontology_raw)[1]))
  all_ontology_labels <- c("ALL", "ALL (BP + MF + CC)", "BP + MF + CC", "BP+MF+CC")
  ontologies <- if (ontology_request %in% all_ontology_labels) c("BP", "MF", "CC") else ontology_request
  if (!all(ontologies %in% c("BP", "MF", "CC"))) ontologies <- "BP"
  run_all_ontologies <- length(ontologies) > 1L

  gene2go <- split(mapping$term_id, mapping$gene_id)
  gene2go <- lapply(gene2go, unique)
  all_genes <- factor(as.integer(universe %in% selected))
  names(all_genes) <- universe

  topgo_data_options <- advanced_package_options(cfg, "topgo_data")
  classic_options <- advanced_package_options(cfg, "topgo_classic_test")
  weight_options <- advanced_package_options(cfg, "topgo_weight_test")
  classic_algorithm <- if (!is.null(classic_options$algorithm)) as.character(classic_options$algorithm)[1] else "classic"
  classic_statistic <- if (!is.null(classic_options$statistic)) as.character(classic_options$statistic)[1] else "fisher"
  weight_algorithm <- if (!is.null(weight_options$algorithm)) as.character(weight_options$algorithm)[1] else "weight01"
  weight_statistic <- if (!is.null(weight_options$statistic)) as.character(weight_options$statistic)[1] else "fisher"
  parse_p <- function(x) suppressWarnings(as.numeric(sub("^<\\s*", "", as.character(x))))

  # topGO constructs one ontology graph at a time.  "All" therefore runs BP,
  # MF, and CC independently and then combines the term tables into one result.
  # If an advanced topGOdata ontology override is present, retain it for a
  # single-ontology run but ignore only that override in All mode so each graph
  # is actually tested once.
  topgo_config_for_branch <- function(branch) {
    branch_cfg <- cfg
    if (run_all_ontologies && !is.null(topgo_data_options$ontology)) {
      overrides <- topgo_data_options
      overrides$ontology <- NULL
      if (is.null(branch_cfg$advanced_package_options)) branch_cfg$advanced_package_options <- list()
      branch_cfg$advanced_package_options$topgo_data <- if (length(overrides)) {
        as.character(jsonlite::toJSON(overrides, auto_unbox = TRUE, null = "null", na = "null"))
      } else {
        "{}"
      }
    }
    branch_cfg
  }

  run_topgo_branch <- function(branch) {
    branch_cfg <- topgo_config_for_branch(branch)
    branch_options <- advanced_package_options(branch_cfg, "topgo_data")
    effective_ontology <- if (!is.null(branch_options$ontology)) toupper(as.character(branch_options$ontology)[1]) else branch
    if (!effective_ontology %in% c("BP", "MF", "CC")) effective_ontology <- branch

    message("topGO ontology branch: ", branch)
    go_data <- call_with_advanced_options(
      methods::new,
      list(Class = "topGOdata", ontology = branch, allGenes = all_genes,
           geneSel = function(x) x == 1L, annot = topGO::annFUN.gene2GO,
           gene2GO = gene2go, nodeSize = min_size),
      branch_cfg, "topgo_data", paste0("methods::new [topGOdata ", branch, "]"),
      protected = c("Class", "allGenes", "geneSel", "annot", "gene2GO")
    )

    used_go <- topGO::usedGO(go_data)
    if (!length(used_go)) {
      message("topGO ", branch, ": no terms remain after ontology and node-size filtering; branch skipped.")
      return(NULL)
    }

    classic <- call_with_advanced_options(
      topGO::runTest,
      list(object = go_data, algorithm = "classic", statistic = "fisher"),
      cfg, "topgo_classic_test", paste0("topGO::runTest [secondary test ", branch, "]"), protected = "object"
    )
    weight <- call_with_advanced_options(
      topGO::runTest,
      list(object = go_data, algorithm = "weight01", statistic = "fisher"),
      cfg, "topgo_weight_test", paste0("topGO::runTest [primary test ", branch, "]"), protected = "object"
    )
    tab <- call_with_advanced_options(
      topGO::GenTable,
      list(object = go_data, secondaryResult = classic, primaryResult = weight,
           topNodes = length(used_go)),
      cfg, "topgo_gen_table", paste0("topGO::GenTable [", branch, "]"),
      protected = c("object", "secondaryResult", "primaryResult")
    )
    if (!nrow(tab)) return(NULL)

    pval <- parse_p(tab$primaryResult)
    data.frame(
      ID = tab$GO.ID,
      Description = tab$Term,
      ontology = rep(branch, nrow(tab)),
      Annotated = as.integer(tab$Annotated),
      Significant = as.integer(tab$Significant),
      Expected = as.numeric(tab$Expected),
      secondaryPvalue = parse_p(tab$secondaryResult),
      pvalue = pval,
      geneID = vapply(tab$GO.ID, function(go) paste(intersect(selected, names(Filter(function(x) go %in% x, gene2go))), collapse = "/"), character(1)),
      Count = as.integer(tab$Significant),
      secondary_test = paste(classic_algorithm, classic_statistic, sep = "/"),
      primary_test = paste(weight_algorithm, weight_statistic, sep = "/"),
      method = paste0("topGO ", weight_algorithm, " ", weight_statistic, " ", effective_ontology),
      check.names = FALSE
    )
  }

  branch_results <- lapply(ontologies, run_topgo_branch)
  branch_results <- Filter(function(x) !is.null(x) && nrow(x) > 0L, branch_results)
  if (!length(branch_results)) {
    output <- data.frame(
      ID = character(), Description = character(), ontology = character(), Annotated = integer(),
      Significant = integer(), Expected = numeric(), secondaryPvalue = numeric(), pvalue = numeric(),
      p.adjust = numeric(), qvalue = numeric(), geneID = character(), Count = integer(),
      secondary_test = character(), primary_test = character(), method = character(),
      check.names = FALSE
    )
  } else {
    output <- do.call(rbind, branch_results)
    # When All is selected, control FDR across the combined BP + MF + CC table.
    # With one branch this is identical to the previous within-branch correction.
    output$p.adjust <- p.adjust(output$pvalue, method = p_adjust)
    output$qvalue <- output$p.adjust
    output <- output[order(output$p.adjust, output$pvalue, output$ontology, na.last = TRUE), , drop = FALSE]
    rownames(output) <- NULL
  }

} else {
  stop("Unknown enrichment method: ", method)
}

if (!"source" %in% colnames(output)) output$source <- rep(as.character(cfg$annotation_source), nrow(output))

# Add transparent per-term summaries used by rich-factor, circular enrichment,
# DAG, and compartment visualizations.  These are descriptive columns only and
# never feed back into the statistical test.
base_selected_flag <- !is.na(result_df[[padj_col]]) & result_df[[padj_col]] <= padj_cutoff & !is.na(result_df[[lfc_col]]) & abs(result_df[[lfc_col]]) >= lfc_cutoff
up_genes <- unique(result_df$gene_id[base_selected_flag & result_df[[lfc_col]] > 0])
down_genes <- unique(result_df$gene_id[base_selected_flag & result_df[[lfc_col]] < 0])
map_universe <- mapping[mapping$gene_id %in% universe, c("gene_id", "term_id"), drop = FALSE]
term_genes <- split(map_universe$gene_id, map_universe$term_id)
term_genes <- lapply(term_genes, unique)
count_term_genes <- function(ids, genes) {
  vapply(ids, function(id) {
    values <- term_genes[[as.character(id)]]
    if (is.null(values)) return(0L)
    as.integer(sum(values %in% genes))
  }, integer(1))
}
if (nrow(output) && "ID" %in% colnames(output)) {
  ids <- as.character(output$ID)
  output$GeneSetSize <- vapply(ids, function(id) length(term_genes[[id]]), integer(1))
  output$SignificantGenes <- count_term_genes(ids, selected)
  output$UpregulatedGenes <- count_term_genes(ids, up_genes)
  output$DownregulatedGenes <- count_term_genes(ids, down_genes)
  if (method %in% c("fgsea", "ranked", "gsea")) {
    leading_n <- if ("leadingEdge" %in% colnames(output)) vapply(output$leadingEdge, function(x) {
      x <- trimws(as.character(x)); if (!nzchar(x)) return(0L); length(unique(strsplit(x, "[,;/|]", perl = TRUE)[[1]][nzchar(trimws(strsplit(x, "[,;/|]", perl = TRUE)[[1]]))]))
    }, integer(1)) else rep(0L, nrow(output))
    denom <- if ("setSize" %in% colnames(output)) suppressWarnings(as.numeric(output$setSize)) else as.numeric(output$GeneSetSize)
    output$RichFactor <- ifelse(is.finite(denom) & denom > 0, leading_n / denom, NA_real_)
    output$RichFactorDefinition <- rep("leading-edge genes / ranked gene-set size", nrow(output))
  } else {
    denom <- as.numeric(output$GeneSetSize)
    output$RichFactor <- ifelse(denom > 0, as.numeric(output$SignificantGenes) / denom, NA_real_)
    output$RichFactorDefinition <- rep("selected significant genes / annotated universe genes", nrow(output))
  }
  if (nrow(go_nodes)) {
    node_branch <- setNames(as.character(go_nodes$ontology), as.character(go_nodes$GO_ID))
    if (!"ontology" %in% colnames(output)) output$ontology <- unname(node_branch[ids])
    else {
      missing <- is.na(output$ontology) | !nzchar(as.character(output$ontology))
      output$ontology[missing] <- unname(node_branch[ids[missing]])
    }
  }
}

write_tsv(output, file.path(out_dir, "enrichment_results.tsv"))
write_tsv(mapping, file.path(out_dir, "annotation_mapping_used.tsv"))
write_tsv(data.frame(gene_id = universe), file.path(out_dir, "gene_universe_used.tsv"))
write_tsv(data.frame(gene_id = selected), file.path(out_dir, "selected_genes_used.tsv"))

significant_terms <- if ("p.adjust" %in% colnames(output)) sum(!is.na(output$p.adjust) & output$p.adjust <= as.numeric(cfg$term_padj_cutoff)) else 0L
summary_obj <- list(
  module = "enrichment",
  method = method,
  annotation_source = cfg$annotation_source,
  go_ontology = if (method %in% c("topgo", "go-topology")) as.character(cfg$go_ontology) else NULL,
  universe_genes = length(universe),
  selected_genes = length(selected),
  mapped_terms = length(unique(mapping$term_id)),
  reported_terms = nrow(output),
  significant_terms = significant_terms,
  direction = direction,
  padj_cutoff = padj_cutoff,
  lfc_cutoff = lfc_cutoff,
  gene_set_size = list(minimum = min_size, maximum = max_size),
  advanced_package_options = if (is.null(cfg$advanced_package_options)) list() else cfg$advanced_package_options
)
write_json_file(summary_obj, file.path(out_dir, "enrichment_summary.json"))
writeLines(session_lines(), file.path(out_dir, "R_session_info.txt"))
message("Enrichment complete. Reported terms: ", nrow(output), "; significant: ", significant_terms)
